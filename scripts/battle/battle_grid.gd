# res://scripts/battle/battle_grid.gd
#
# THE BATTLE GRID — the game board.
# Tracks tile types, unit positions, hazards, and all special effect maps
# (tethers, shields, guardian links, thorns).
#
# WHAT'S NEW:
#   - Hazards now enforced max 3 turns; only one of each type per tile
#     (walls are EXEMPT from the 3-turn cap — see add_hazard).
#   - Multi-tile unit support: large units (2×2, etc.) occupy multiple cells.
#   - Tether tracking: a dictionary mapping tether_id → list of unit nodes.
#   - Shield / Guardian / Thorns data stored per unit so ability_executor
#     can look them up during damage resolution.
#   - Animated hazard visuals: entrance → idle (looping) → exit, instead of
#     static sprites. Falls back to a static icon if no scenes are provided.
#   - Wall hazards: a hazard spanning multiple cells, placed in a straight
#     line. Whether it blocks movement is now its OWN switch
#     (HazardData.blocks_movement) instead of being automatic — so a wall
#     hazard can deal damage to anyone who walks onto it instead of physically
#     stopping them, while STILL independently choosing whether it blocks
#     line of sight (HazardData.wall_blocks_line_of_sight). The two are no
#     longer linked: a wall can block movement, block LOS, both, or neither.
#   - Stacked-unit safety net: register_unit()/register_large_unit() now
#     automatically detect when they're about to silently overwrite another
#     unit's spot in unit_positions (which used to leave that unit standing
#     on screen but permanently unclickable for the rest of the battle — no
#     cell anywhere pointed back to them anymore). They now relocate
#     whoever was there to the nearest free tile first. This is a safety
#     net, not the primary fix — see ability_executor.gd's dash code for the
#     actual root cause it was guarding against.

extends Node2D

const GRID_WIDTH  = 19
const GRID_HEIGHT = 9
const TILE_SIZE   = 96   # pixels per tile — must match highlight_manager.gd

# ── TILE DATA ─────────────────────────────────────────────────────────────────

var tile_map: Dictionary = {}
# Key: Vector2i(col, row)  Value: TileTypeData resource
# Every cell on the board has exactly one TileTypeData.

var feature_map: Dictionary = {}
# ADDED. Key: Vector2i  Value: MapFeatureData. Populated by
# spawn_scatter_features() (see the bottom of this file). Cleared implicitly
# whenever setup_grid() is called for a new battle since this dictionary
# lives on this same BattleGrid instance, which is torn down between scenes.

# ── UNIT POSITIONS ────────────────────────────────────────────────────────────

var unit_positions: Dictionary = {}
# Key: Vector2i  Value: UnitNode
# A single-cell-to-unit lookup. For large (multi-tile) units, EVERY cell
# they occupy is entered here pointing to the same unit node.

# ── HAZARD MAP ────────────────────────────────────────────────────────────────

var hazard_map: Dictionary = {}
# Key: Vector2i
# Value: Dictionary with keys:
#   "data"            : HazardData resource (the template)
#   "remaining"       : int  (turns left before expiry)
#   "caster"          : UnitNode that placed this hazard (may be null)
#   "visual"          : Node2D currently displayed (entrance, idle, or exit instance)
#   "visual_state"    : String — "entrance", "idle", or "exit" (tracks animation phase)
#   "wall_group_id"   : String — shared id linking all cells of the same wall
#                       placement together (so removing one tile can find its
#                       siblings if needed). Empty string for non-wall hazards.
# Only ONE hazard of each id is allowed per tile. A second placement of
# the same type refreshes the duration instead of stacking.

const HAZARD_MAX_TURNS: int = 3
# Hard cap: no NON-WALL hazard can last more than 3 turns, regardless of HazardData.
# Walls are exempt from this cap since they're often meant to persist as
# battlefield-shaping terrain for the whole encounter. This exemption applies
# to ANY wall-placed hazard, whether or not it blocks movement.

# ── SPECIAL EFFECT MAPS ───────────────────────────────────────────────────────
# These dictionaries are the "lookup tables" ability_executor reads during
# damage resolution to apply Tether, Thorns, Shield, and Guardian effects.

var tether_map: Dictionary = {}
# Key: tether_id (String)
# Value: Array of UnitNodes that share this tether.
# e.g. { "pack_bond": [wolf_a, wolf_b, wolf_c] }

var shield_map: Dictionary = {}
# Key: UnitNode
# Value: Dictionary { "amount": int, "remaining_rounds": int }
# Tracks how much barrier HP a unit has left.

var thorns_map: Dictionary = {}
# Key: UnitNode
# Value: Dictionary { "reflect_percent": float, "scaling_stat": String,
#                     "remaining_rounds": int }
# When this unit is hit, reflect (reflect_percent * scaling_stat) back.

var guardian_map: Dictionary = {}
# Key: UnitNode (the PROTECTED unit)
# Value: Dictionary { "guardian": UnitNode, "redirect_percent": float,
#                     "uses_defense": String, "remaining_rounds": int }
# When the PROTECTED unit takes damage, the Guardian intercepts a portion.

# ── LIFECYCLE ─────────────────────────────────────────────────────────────────

func setup_grid(map_data: Dictionary) -> void:
	# Called by BattleScene to lay out the map.
	# map_data = { Vector2i: TileTypeData, ... }
	tile_map = map_data
	_draw_tiles()
	_build_grid_lines()


func _draw_tiles() -> void:
	# Spawns a Sprite2D for each tile so the map is visible on screen.
	for cell in tile_map:
		var tile_type: TileTypeData = tile_map[cell]
		var sprite = Sprite2D.new()
		sprite.texture = tile_type.tile_texture
		sprite.position = grid_to_world(cell)
		$GroundLayer.add_child(sprite)

# ── GRID LINES OVERLAY (toggleable) ──────────────────────────────────────────
# A simple grid of thin line rectangles drawn over every tile in tile_map.
# Hidden by default; toggled on/off via the UI button (ui_manager.gd calls
# set_grid_lines_visible()). Built once at setup time so toggling is just a
# visibility flip with no redraw cost.

var _grid_lines_layer: Node2D = null

const GRID_LINE_THICKNESS: float = 1.5
const GRID_LINE_COLOR: Color = Color(1, 1, 1, 0.15)   # Faint white lines.

func _build_grid_lines() -> void:
	if _grid_lines_layer != null and is_instance_valid(_grid_lines_layer):
		_grid_lines_layer.queue_free()

	_grid_lines_layer = Node2D.new()
	_grid_lines_layer.name = "GridLinesLayer"
	_grid_lines_layer.visible = false   # Off by default — player toggles it on.
	_grid_lines_layer.z_index = 1       # Sits just above GroundLayer's tiles.
	add_child(_grid_lines_layer)

	# Draw one rectangle OUTLINE per tile that actually exists in tile_map,
	# rather than a fixed-size grid, so irregular/non-rectangular maps still
	# get correct grid lines only where there's actual playable terrain.
	for cell in tile_map:
		var top_left: Vector2 = grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		var outline := _make_tile_outline(top_left)
		_grid_lines_layer.add_child(outline)


func _make_tile_outline(top_left: Vector2) -> Node2D:
	# Builds a single tile's outline out of 4 thin ColorRects (top/bottom/left/right).
	# Using ColorRects (instead of a single Line2D loop) keeps this consistent
	# with the rest of the project's highlight/visual approach, which is
	# entirely ColorRect-based already (see highlight_manager.gd).
	var holder := Node2D.new()
	holder.position = top_left

	var top := ColorRect.new()
	top.color = GRID_LINE_COLOR
	top.size = Vector2(TILE_SIZE, GRID_LINE_THICKNESS)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(top)

	var bottom := ColorRect.new()
	bottom.color = GRID_LINE_COLOR
	bottom.size = Vector2(TILE_SIZE, GRID_LINE_THICKNESS)
	bottom.position = Vector2(0, TILE_SIZE - GRID_LINE_THICKNESS)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(bottom)

	var left := ColorRect.new()
	left.color = GRID_LINE_COLOR
	left.size = Vector2(GRID_LINE_THICKNESS, TILE_SIZE)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(left)

	var right := ColorRect.new()
	right.color = GRID_LINE_COLOR
	right.size = Vector2(GRID_LINE_THICKNESS, TILE_SIZE)
	right.position = Vector2(TILE_SIZE - GRID_LINE_THICKNESS, 0)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(right)

	return holder


func set_grid_lines_visible(should_show: bool) -> void:
	# Called by ui_manager.gd's grid toggle button.
	if _grid_lines_layer != null and is_instance_valid(_grid_lines_layer):
		_grid_lines_layer.visible = should_show

# ── COORDINATE HELPERS ────────────────────────────────────────────────────────

func grid_to_world(cell: Vector2i) -> Vector2:
	# Converts a grid coordinate to the CENTER pixel position on screen.
	return Vector2(cell.x * TILE_SIZE + TILE_SIZE / 2.0,
				   cell.y * TILE_SIZE + TILE_SIZE / 2.0)


func world_to_grid(world_pos: Vector2) -> Vector2i:
	# Converts a pixel position back to the grid cell it falls in.
	return Vector2i(int(world_pos.x / TILE_SIZE), int(world_pos.y / TILE_SIZE))

# ── CELL VALIDITY ─────────────────────────────────────────────────────────────

func is_valid_cell(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < GRID_WIDTH and cell.y >= 0 and cell.y < GRID_HEIGHT


func is_passable(cell: Vector2i) -> bool:
	# Returns true if a unit CAN stand on this cell (not a wall, not occupied).
	# This is the team-agnostic version used by general pathfinding queries
	# that don't know which unit is asking. For wall-aware checks during actual
	# movement, callers should prefer is_passable_for(unit, cell) below.
	if not is_valid_cell(cell): return false
	if not tile_map.has(cell):  return false
	var tile: TileTypeData = tile_map[cell]
	if tile.is_wall:            return false
	if unit_positions.has(cell): return false
	if _is_blocked_by_wall_hazard(cell, null): return false
	if _is_blocked_by_feature(cell): return false   # ADDED
	return true


func is_passable_for(unit, cell: Vector2i) -> bool:
	# Team-aware passability check. Use this from pathfinding so wall hazards
	# correctly respect their wall_blocks filter ("player", "enemies", "all")
	# AND their blocks_movement switch (a wall hazard with blocks_movement =
	# false never blocks anyone, regardless of the team filter).
	if not is_valid_cell(cell): return false
	if not tile_map.has(cell):  return false
	var tile: TileTypeData = tile_map[cell]
	if tile.is_wall:             return false
	if unit_positions.has(cell): return false
	if _is_blocked_by_wall_hazard(cell, unit): return false
	if _is_blocked_by_feature(cell): return false   # ADDED
	return true


func is_terrain_walkable(cell: Vector2i) -> bool:
	# 1. Check if the cell is valid/inside the map
	if not is_valid_cell(cell): return false
	# 2. Check if the tile exists in our data
	if not tile_map.has(cell):  return false

	# 3. ONLY check if it is a wall (terrain) or a movement-blocking wall HAZARD.
	# We purposefully exclude the 'unit_positions' check here, since this is
	# used for things like dash paths that care about terrain, not occupancy.
	var tile: TileTypeData = tile_map[cell]
	if tile.is_wall:           return false
	if _is_blocked_by_wall_hazard(cell, null): return false
	if _is_blocked_by_feature(cell): return false   # ADDED

	return true


func get_movement_cost(cell: Vector2i) -> int:
	if feature_map.has(cell):   # ADDED
		return feature_map[cell].movement_cost
	if not tile_map.has(cell): return 9999
	return tile_map[cell].movement_cost


func blocks_los(cell: Vector2i) -> bool:
	if feature_map.has(cell) and feature_map[cell].blocks_line_of_sight:   # ADDED
		return true
	if not tile_map.has(cell): return false
	if tile_map[cell].blocks_line_of_sight or tile_map[cell].is_wall:
		return true
	# Wall hazards optionally block line of sight too, per their HazardData
	# flag. This check is INDEPENDENT of blocks_movement — a wall hazard can
	# block LOS whether or not it also blocks movement, so we don't look at
	# blocks_movement here at all.
	if hazard_map.has(cell):
		for hazard_id in hazard_map[cell]:
			var entry = hazard_map[cell][hazard_id]
			var hdata: HazardData = entry["data"]
			if hdata.is_wall_hazard and hdata.wall_blocks_line_of_sight:
				return true
	return false


func _is_blocked_by_feature(cell: Vector2i) -> bool:
	# ADDED. Team-agnostic on purpose -- MapFeatureData has no per-team
	# filter (unlike wall hazards), a blocking scatter feature blocks
	# everyone equally.
	if not feature_map.has(cell):
		return false
	return feature_map[cell].blocks_movement


func _is_blocked_by_wall_hazard(cell: Vector2i, unit) -> bool:
	# Internal helper: checks if a wall hazard at this cell PHYSICALLY blocks
	# the given unit from entering. 'unit' may be null (team-agnostic check —
	# blocks if ANY team would be blocked).
	if not hazard_map.has(cell):
		return false
	for hazard_id in hazard_map[cell]:
		var entry = hazard_map[cell][hazard_id]
		var hdata: HazardData = entry["data"]
		if not hdata.is_wall_hazard:
			continue
		# NEW: a wall hazard only blocks movement at all if blocks_movement is
		# true. If it's false, this is a "damaging wall" (it hurts units but
		# never stops them) — skip straight to the next hazard without even
		# looking at the wall_blocks team filter, since nothing is blocked.
		if not hdata.blocks_movement:
			continue
		match hdata.wall_blocks:
			"all":
				return true
			"player":
				if unit == null or unit.is_player_unit:
					return true
			"enemies":
				if unit == null or not unit.is_player_unit:
					return true
	return false

# ── UNIT REGISTRY ─────────────────────────────────────────────────────────────

func register_unit(unit, cell: Vector2i) -> void:
	# Marks a cell as occupied by this unit.
	# For multi-tile units, call this for EVERY cell they occupy.
	#
	# SAFETY NET: if some OTHER unit is already registered at this exact
	# cell, just overwriting that dictionary entry would silently orphan
	# them — unit_positions would no longer point back to them from ANYWHERE
	# on the board, making them permanently unclickable for the rest of the
	# battle even though they're still standing right there on screen. This
	# can happen if something moves a unit onto a cell without first
	# checking it's actually free (a dash that stopped on the wrong tile, or
	# a cancelled move snapping back onto a tile an ally has since moved
	# into). Rather than let that happen, we rescue the unit that was
	# already here to the nearest free tile FIRST.
	var displaced = unit_positions.get(cell)
	if displaced != null and displaced != unit:
		_rescue_displaced_unit(displaced, cell)
	unit_positions[cell] = unit
	_refresh_tether_lines()


func unregister_unit(cell: Vector2i, unit = null) -> void:
	# Frees a single cell -- but ONLY if 'unit' is actually who's registered
	# there. Without this check, a unit that's overlapping another (e.g. via
	# snap_to_allow_overlap()'s deliberate Cancel-Move overlap, where THIS
	# unit was never the cell's official resident) would erase the OTHER
	# unit's legitimate registration when it later moves away normally --
	# leaving that other unit's grid_position correct but unit_positions
	# pointing at nothing, making them permanently unclickable and their
	# tile permanently misreported as empty.
	# 'unit' defaults to null for backward compatibility with old call sites,
	# but every call site should pass it -- an unconditional erase() is
	# exactly the bug described above.
	if unit != null and unit_positions.get(cell) != unit:
		return
	unit_positions.erase(cell)
	_refresh_tether_lines()

func get_unit_at(cell: Vector2i):
	# Returns the unit at this cell, or null if empty.
	return unit_positions.get(cell, null)


func register_large_unit(unit, cells: Array) -> void:
	# Convenience: registers a unit across ALL cells it occupies.
	# unit.occupied_cells should already be set before calling this.
	# Same safety net as register_unit() above, applied per-cell.
	for cell in cells:
		var displaced = unit_positions.get(cell)
		if displaced != null and displaced != unit:
			_rescue_displaced_unit(displaced, cell)
		unit_positions[cell] = unit
	_refresh_tether_lines()


func unregister_large_unit(unit) -> void:
	# Removes ALL of a large unit's cells from the registry -- but only the
	# ones actually registered to THIS unit (same reasoning as
	# unregister_unit() above).
	if "occupied_cells" in unit:
		for cell in unit.occupied_cells:
			if unit_positions.get(cell) == unit:
				unit_positions.erase(cell)
	_refresh_tether_lines()


var _units_currently_being_rescued: Array = []
# THE INFINITE RECURSION FIX.
#
# THE BUG: _rescue_displaced_unit() below picks "the nearest free cell" via
# _find_nearest_free_cell() and snaps the displaced unit there. snap_to()
# then calls register_unit()/register_large_unit() again to claim that new
# cell — which, if THAT cell is occupied too, calls _rescue_displaced_unit()
# again, and so on. For a 1×1 unit this was nearly always harmless, because
# _find_nearest_free_cell() only ever returns a cell with NOTHING registered
# on it.
#
# But for a multi-tile (e.g. 2x2) unit, _find_nearest_free_cell() used to
# only check the SINGLE anchor cell for occupancy — not the unit's whole
# footprint. A large unit could get "rescued" onto an anchor cell that's
# itself empty but whose other 3 footprint cells overlap a different unit
# (possibly ALSO a large unit). That triggers another rescue, which can
# overlap back onto cells near the first unit's new spot, and so on — on a
# crowded map with multiple large units this could chain indefinitely and
# blow the call stack, which is what showed up as an occasional "infinite
# recursion" crash.
#
# THE FIX is two-pronged:
#   1. _find_nearest_free_cell() now takes the displaced unit's FULL
#      footprint and only accepts a candidate anchor cell if EVERY cell of
#      the footprint is genuinely free there — so a rescue can no longer
#      land a unit somewhere that immediately conflicts with someone else.
#   2. As a defence-in-depth backstop (in case some other unrelated path
#      ever produces a genuine cycle), this array tracks which units are
#      mid-rescue RIGHT NOW. If a rescue is asked to rescue a unit that's
#      already being rescued further up the call stack, we know we've
#      looped back on ourselves — stop immediately with a warning instead
#      of recursing again.

func _rescue_displaced_unit(displaced, conflicting_cell: Vector2i) -> void:
	# Called automatically by register_unit/register_large_unit above. Moves
	# 'displaced' to the nearest free tile so they're never left as an
	# unclickable "ghost" — still rendered on screen, but with no cell
	# anywhere pointing back to them. This is a LAST-RESORT safety net, not
	# meant to be relied on as the normal way units move — anything that
	# deliberately moves a unit should already be checking the destination
	# is free beforehand (see is_passable/is_passable_for).
	if displaced in _units_currently_being_rescued:
		push_warning("BattleGrid: rescue loop detected for a unit already mid-rescue — " +
					 "aborting this nested rescue instead of recursing further.")
		return
	_units_currently_being_rescued.append(displaced)

	var footprint: Array = [Vector2i(0, 0)]
	if "tile_footprint" in displaced and displaced.tile_footprint.size() > 0:
		footprint = displaced.tile_footprint

	var free_anchor = _find_nearest_free_cell(conflicting_cell, conflicting_cell, footprint)
	if free_anchor == Vector2i(-1, -1):
		push_warning("BattleGrid: no free tile anywhere to rescue a displaced unit — they may stay unclickable!")
		_units_currently_being_rescued.erase(displaced)
		return

	var displaced_name = "a unit"
	if "unit_data" in displaced and displaced.unit_data != null:
		displaced_name = displaced.unit_data.display_name

	print("⚠️ ", displaced_name, " was about to be silently overwritten at ", conflicting_cell,
		  " by something else landing on the same tile — relocating them to ", free_anchor,
		  " instead so they stay clickable.")
	displaced.snap_to(free_anchor)

	_units_currently_being_rescued.erase(displaced)


func _find_nearest_free_cell(from: Vector2i, exclude_cell: Vector2i = Vector2i(-1, -1),
							  footprint: Array = [Vector2i(0, 0)]) -> Vector2i:
	# Expanding-ring search outward from 'from' for the nearest ANCHOR cell
	# where the unit's ENTIRE footprint (every offset in 'footprint', as used
	# by multi-tile units) would land on fully passable, unoccupied tiles —
	# not just the single anchor cell. 'exclude_cell' is treated as occupied
	# regardless of its actual contents (used to stop a unit being "rescued"
	# right back onto the cell that displaced it). Returns Vector2i(-1, -1)
	# if no valid anchor position exists anywhere on the map.
	var max_radius: int = max(GRID_WIDTH, GRID_HEIGHT)
	for radius in range(0, max_radius + 1):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if max(abs(dx), abs(dy)) != radius:
					continue   # Only check the OUTER ring at this radius — smaller rings were already checked.
				var anchor = from + Vector2i(dx, dy)
				if anchor == exclude_cell:
					continue
				if _footprint_fully_free(anchor, footprint, exclude_cell):
					return anchor
	return Vector2i(-1, -1)


func _footprint_fully_free(anchor: Vector2i, footprint: Array, exclude_cell: Vector2i) -> bool:
	# True only if EVERY cell of the footprint, anchored at 'anchor', is a
	# valid, passable, unoccupied tile. exclude_cell is always treated as
	# occupied (see _find_nearest_free_cell above).
	for offset in footprint:
		var c: Vector2i = anchor + offset
		if c == exclude_cell:
			return false
		if not is_valid_cell(c) or not is_passable(c):
			return false
	return true

# ── HAZARD SYSTEM ─────────────────────────────────────────────────────────────

func add_hazard(cell: Vector2i, hazard_data: HazardData, caster = null,
				wall_group_id: String = "") -> void:
	# Places (or refreshes) a hazard on a tile.
	# Rules:
	#   - Only one hazard of each TYPE (id) per tile.
	#   - Duration is clamped to HAZARD_MAX_TURNS (3) UNLESS it's a wall hazard.
	#   - If the same hazard id already exists here, we refresh duration only.
	#
	# wall_group_id links multiple cells together as one wall placement.
	# Pass the SAME string for every cell in a single wall so they can be
	# tracked/removed as a unit if needed later. Leave blank for normal hazards.

	if not hazard_map.has(cell):
		hazard_map[cell] = {}

	var slot = hazard_map[cell]

	# Check if this exact hazard type already exists at this cell.
	if slot.has(hazard_data.id):
		# Refresh duration — do NOT stack a second copy.
		var refreshed_duration = hazard_data.duration_rounds
		if not hazard_data.is_wall_hazard:
			refreshed_duration = min(refreshed_duration, HAZARD_MAX_TURNS)
		slot[hazard_data.id]["remaining"] = refreshed_duration
		return

	# New hazard type: calculate duration.
	# Wall hazards are EXEMPT from the 3-turn cap (regardless of whether they
	# block movement — even a non-blocking "damaging wall" is still placed
	# via the wall flow and is meant to persist as a battlefield feature).
	var duration = hazard_data.duration_rounds if not hazard_data.is_permanent else 9999
	if not hazard_data.is_wall_hazard:
		duration = min(duration, HAZARD_MAX_TURNS)

	slot[hazard_data.id] = {
		"data":          hazard_data,
		"remaining":     duration,
		"caster":        caster,
		"visual":        null,
		"visual_state":  "none",
		"wall_group_id": wall_group_id,
	}

	_spawn_hazard_visual(cell, hazard_data.id)


func _spawn_hazard_visual(cell: Vector2i, hazard_id: String) -> void:
	# Spawns the ENTRANCE animation if one is defined, otherwise jumps straight
	# to the looping idle visual, otherwise falls back to a static icon sprite.
	if not hazard_map.has(cell) or not hazard_map[cell].has(hazard_id):
		return
	var entry = hazard_map[cell][hazard_id]
	var hdata: HazardData = entry["data"]

	if not has_node("HazardLayer"):
		return

	if hdata.entrance_scene != null:
		var instance = hdata.entrance_scene.instantiate()
		instance.position = grid_to_world(cell)
		$HazardLayer.add_child(instance)
		entry["visual"]       = instance
		entry["visual_state"] = "entrance"

		# Wait for the entrance animation to finish, then swap to idle.
		# Supports either AnimatedSprite2D (animation_finished signal) or
		# AnimationPlayer (animation_finished signal) as the root/child node.
		_await_entrance_then_idle(cell, hazard_id, instance)

	elif hdata.idle_scene != null:
		_spawn_idle_visual(cell, hazard_id)

	elif hdata.icon != null:
		# Fallback: static sprite, exactly like the old behaviour.
		var sprite = Sprite2D.new()
		sprite.texture = hdata.icon
		sprite.position = grid_to_world(cell)
		sprite.modulate = Color(1, 1, 1, 0.75)
		$HazardLayer.add_child(sprite)
		entry["visual"]       = sprite
		entry["visual_state"] = "idle"


func _await_entrance_then_idle(cell: Vector2i, hazard_id: String, instance: Node) -> void:
	# Waits for the entrance animation to complete, then transitions to idle.
	# Uses a generic signal-detection approach so it works whether the hazard
	# scene's root is an AnimatedSprite2D, an AnimationPlayer, or a custom node
	# that exposes either of those as a child.
	var finished_signal: Signal
	if instance is AnimatedSprite2D:
		(instance as AnimatedSprite2D).play("default")
		finished_signal = (instance as AnimatedSprite2D).animation_finished
	elif instance.has_node("AnimatedSprite2D"):
		var s = instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
		s.play("default")
		finished_signal = s.animation_finished
	elif instance is AnimationPlayer:
		(instance as AnimationPlayer).play("default")
		finished_signal = (instance as AnimationPlayer).animation_finished
	elif instance.has_node("AnimationPlayer"):
		var ap = instance.get_node("AnimationPlayer") as AnimationPlayer
		ap.play("default")
		finished_signal = ap.animation_finished
	else:
		# No recognisable animation node — fall back to a fixed delay.
		await get_tree().create_timer(0.6).timeout
		_finish_entrance_transition(cell, hazard_id, instance)
		return

	await finished_signal
	_finish_entrance_transition(cell, hazard_id, instance)


func _finish_entrance_transition(cell: Vector2i, hazard_id: String, old_instance: Node) -> void:
	# Removes the entrance instance and spawns the looping idle visual.
	if is_instance_valid(old_instance):
		old_instance.queue_free()
	if not hazard_map.has(cell) or not hazard_map[cell].has(hazard_id):
		return   # Hazard was removed mid-animation — nothing more to do.
	_spawn_idle_visual(cell, hazard_id)


func _spawn_idle_visual(cell: Vector2i, hazard_id: String) -> void:
	# Spawns the looping idle scene for a hazard. If no idle_scene is set,
	# falls back to the static icon (or nothing, if neither is set).
	if not hazard_map.has(cell) or not hazard_map[cell].has(hazard_id):
		return
	var entry = hazard_map[cell][hazard_id]
	var hdata: HazardData = entry["data"]

	if hdata.idle_scene != null:
		var instance = hdata.idle_scene.instantiate()
		instance.position = grid_to_world(cell)
		$HazardLayer.add_child(instance)
		# Start the loop, if it's an AnimatedSprite2D-based scene.
		if instance is AnimatedSprite2D:
			(instance as AnimatedSprite2D).play("default")
		elif instance.has_node("AnimatedSprite2D"):
			instance.get_node("AnimatedSprite2D").play("default")
		entry["visual"]       = instance
		entry["visual_state"] = "idle"
	elif hdata.icon != null:
		var sprite = Sprite2D.new()
		sprite.texture = hdata.icon
		sprite.position = grid_to_world(cell)
		sprite.modulate = Color(1, 1, 1, 0.75)
		$HazardLayer.add_child(sprite)
		entry["visual"]       = sprite
		entry["visual_state"] = "idle"
	else:
		entry["visual"]       = null
		entry["visual_state"] = "idle"


func remove_hazard(cell: Vector2i, hazard_id: String) -> void:
	# Removes a specific hazard type from a tile. If an exit_scene is defined,
	# plays it first and only erases the grid entry once it finishes.
	if not hazard_map.has(cell): return
	var slot = hazard_map[cell]
	if not slot.has(hazard_id): return

	var entry = slot[hazard_id]
	var hdata: HazardData = entry["data"]
	var old_visual = entry["visual"]

	# Remove the grid-logic entry immediately — gameplay effects (passability,
	# damage triggers) end right away even if a visual is still playing out.
	slot.erase(hazard_id)
	if slot.is_empty():
		hazard_map.erase(cell)

	if hdata.exit_scene != null:
		_play_exit_animation(cell, hdata, old_visual)
	else:
		# No exit animation — remove the idle visual instantly, same as before.
		if old_visual != null and is_instance_valid(old_visual):
			old_visual.queue_free()


func _play_exit_animation(cell: Vector2i, hdata: HazardData, old_visual: Node) -> void:
	# Plays the one-shot exit animation, then frees both the old idle visual
	# and the exit instance once finished.
	if old_visual != null and is_instance_valid(old_visual):
		old_visual.queue_free()

	if not has_node("HazardLayer"):
		return

	var instance = hdata.exit_scene.instantiate()
	instance.position = grid_to_world(cell)
	$HazardLayer.add_child(instance)

	var finished_signal: Signal
	if instance is AnimatedSprite2D:
		(instance as AnimatedSprite2D).play("default")
		finished_signal = (instance as AnimatedSprite2D).animation_finished
	elif instance.has_node("AnimatedSprite2D"):
		var s = instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
		s.play("default")
		finished_signal = s.animation_finished
	elif instance is AnimationPlayer:
		(instance as AnimationPlayer).play("default")
		finished_signal = (instance as AnimationPlayer).animation_finished
	elif instance.has_node("AnimationPlayer"):
		var ap = instance.get_node("AnimationPlayer") as AnimationPlayer
		ap.play("default")
		finished_signal = ap.animation_finished
	else:
		await get_tree().create_timer(0.6).timeout
		if is_instance_valid(instance):
			instance.queue_free()
		return

	await finished_signal
	if is_instance_valid(instance):
		instance.queue_free()


func get_hazards_at(cell: Vector2i) -> Array:
	# Returns a list of all active hazard entries at this cell.
	# Each entry is a Dictionary with keys: data, remaining, caster, visual, visual_state.
	if not hazard_map.has(cell): return []
	return hazard_map[cell].values()


func tick_hazards() -> void:
	# Called once per round (by BattleManager) to count down hazard durations.
	# Any hazard that reaches 0 remaining turns is removed automatically
	# (which triggers its exit animation, if any).
	var to_remove: Array = []  # [ [cell, hazard_id], ... ]

	for cell in hazard_map:
		for hazard_id in hazard_map[cell]:
			var entry = hazard_map[cell][hazard_id]
			if entry["data"].is_permanent:
				continue  # Permanent hazards never tick.
			entry["remaining"] -= 1
			if entry["remaining"] <= 0:
				to_remove.append([cell, hazard_id])

	for pair in to_remove:
		remove_hazard(pair[0], pair[1])


func apply_hazard_to_unit(unit, cell: Vector2i, trigger: String) -> void:
	# Applies damage and status from ALL eligible hazards at 'cell' to 'unit',
	# but ONLY if the hazard's trigger condition matches 'trigger'.
	#
	# trigger can be:
	#   "enter"        — unit just stepped onto the tile
	#   "start_of_turn"— it is the start of the unit's turn
	#   "end_of_turn"  — it is the end of the unit's turn
	#
	# A TRUE impassable wall (is_wall_hazard=true AND blocks_movement=true)
	# never reaches this function in practice (units can't enter a tile that
	# blocks movement), but we skip it defensively anyway in case of edge
	# cases. A "damaging wall" (is_wall_hazard=true AND blocks_movement=false)
	# is NOT skipped — it deals damage exactly like a normal hazard, since
	# units genuinely can stand on its tiles.

	if not hazard_map.has(cell): return

	for hazard_id in hazard_map[cell]:
		var entry = hazard_map[cell][hazard_id]
		var hdata: HazardData = entry["data"]

		# Only skip damage for walls that ACTUALLY block movement. A wall
		# hazard with blocks_movement = false has no one physically stopped
		# from standing here, so it should hurt them like any other hazard —
		# this is the whole point of a "damaging wall".
		if hdata.is_wall_hazard and hdata.blocks_movement:
			continue   # Impassable walls don't deal damage — they only block movement.

		# Check if this hazard triggers for this timing.
		var should_trigger = false
		match trigger:
			"enter":          should_trigger = hdata.trigger_on_enter
			"start_of_turn":  should_trigger = hdata.trigger_on_start_of_turn
			"end_of_turn":    should_trigger = hdata.trigger_on_end_of_turn

		if not should_trigger: continue

		# Calculate damage. Use the caster's ATK if we have one, otherwise flat 5.
		var raw_damage: int = 5
		if entry["caster"] != null and is_instance_valid(entry["caster"]):
			var caster_atk = entry["caster"].get_effective_atk()
			raw_damage = max(1, int(caster_atk * hdata.damage_multiplier))

		unit.take_damage(raw_damage, hdata.damage_type, false, false)
		
		# Apply optional status.
		if hdata.applies_status != null:
			unit.apply_status(hdata.applies_status)

# ── WALL HAZARD PLACEMENT ─────────────────────────────────────────────────────

func place_wall(cells: Array, hazard_data: HazardData, caster = null) -> void:
	# Places a wall hazard across every cell in 'cells'. All cells share the
	# same wall_group_id so they're recognisably part of one wall placement.
	# Called by ability_executor after it has calculated the wall's cell line
	# (see _calculate_wall_cells in ability_executor.gd for orientation logic).
	if cells.is_empty():
		return
	var wall_group_id = "wall_%d" % Time.get_ticks_msec()
	for cell in cells:
		if not is_valid_cell(cell):
			continue
		# A TRUE impassable wall (blocks_movement = true) cannot be placed on
		# top of an existing unit — that unit would have nowhere valid to be.
		# A "damaging wall" (blocks_movement = false) has no such problem: it
		# never physically blocks anyone, so it's fine to drop it on a tile a
		# unit is already standing on, exactly like a normal hazard would be.
		if hazard_data.blocks_movement and unit_positions.has(cell):
			continue
		# A wall (of either kind) still can't be placed on top of solid
		# terrain — that tile is already impassable for an unrelated reason.
		if tile_map.has(cell) and tile_map[cell].is_wall:
			continue
		add_hazard(cell, hazard_data, caster, wall_group_id)


func tick_shields() -> void:
	# Counts down shield durations. Called each round.
	var to_remove = []
	for unit in shield_map:
		shield_map[unit]["remaining_rounds"] -= 1
		if shield_map[unit]["remaining_rounds"] <= 0:
			to_remove.append(unit)
	for u in to_remove:
		shield_map.erase(u)

# ── TETHER SYSTEM ─────────────────────────────────────────────────────────────

func register_tether(unit, tether_id: String) -> void:
	# Adds a unit to a tether group.
	# All units sharing the same tether_id share damage on single-target hits.
	if not tether_map.has(tether_id):
		tether_map[tether_id] = []
	if not unit in tether_map[tether_id]:
		tether_map[tether_id].append(unit)
	_refresh_tether_lines()


func unregister_tether(unit, tether_id: String) -> void:
	# Removes a unit from a tether group (on death or expiry).
	if tether_map.has(tether_id):
		tether_map[tether_id].erase(unit)
		if tether_map[tether_id].is_empty():
			tether_map.erase(tether_id)
	_refresh_tether_lines()


func get_tethered_units(tether_id: String, exclude_unit) -> Array:
	# Returns all OTHER units in the tether group (not including exclude_unit).
	if not tether_map.has(tether_id): return []
	var result = []
	for u in tether_map[tether_id]:
		if is_instance_valid(u) and u != exclude_unit:
			result.append(u)
	return result

# ── TETHER LINE VISUALS ───────────────────────────────────────────────────────
# Draws a glowing, gently-waving purple line (with drifting particles) for
# EVERY connection in a tether group's minimum spanning tree — i.e. each
# tethered unit links to whichever of its allies is actually closest, rather
# than being drawn in arbitrary registration order. For a 2-unit tether
# that's just the one obvious connection; for 3+ units it means each unit
# reaches its nearest tethered neighbor(s) instead of a fixed A→B→C chain
# that might connect two units that happen to be far apart while ignoring a
# much closer third unit.
#
# Connections are recomputed from tether_map + live unit positions every
# time _refresh_tether_lines() runs (register_unit/unregister_unit/
# register_large_unit/unregister_large_unit/register_tether/
# unregister_tether — i.e. every movement path AND every death already goes
# through this), so a unit dying, or units simply walking around and
# changing who's nearest to whom, both correctly redraw the connections.
# Nothing here is tracked independently of that live data.

var _tether_line_layer: Node2D = null
var _tether_lines: Dictionary       = {}   # line_key (String) -> Line2D
var _tether_glow_lines: Dictionary  = {}   # line_key -> Line2D
var _tether_particles: Dictionary   = {}   # line_key -> CPUParticles2D (purple drift)
var _tether_sparkles: Dictionary    = {}   # line_key -> CPUParticles2D (white sparkle)
var _tether_base_points: Dictionary = {}   # line_key -> PackedVector2Array([unit_a.position, unit_b.position])
var _tether_time: float = 0.0

@export var tether_line_color: Color = Color(0.65, 0.2, 0.85, 0.85)   # purple
@export var tether_line_width: float = 4.0

@export var tether_glow_color: Color = Color(0.65, 0.2, 0.85, 0.35)
@export var tether_glow_width_multiplier: float = 3.0

@export var tether_wave_amplitude: float = 6.0
@export var tether_wave_speed: float = 3.0
@export var tether_wave_count: float = 1.5

@export var tether_particle_color: Color = Color(0.75, 0.35, 0.95, 0.8)
@export var tether_sparkle_color: Color = Color(1.0, 1.0, 1.0, 0.9)
@export var tether_sparkle_amount: int = 14


func _ensure_tether_line_layer() -> void:
	if _tether_line_layer != null and is_instance_valid(_tether_line_layer):
		return
	_tether_line_layer = Node2D.new()
	_tether_line_layer.name = "TetherLineLayer"
	_tether_line_layer.z_index = 4
	add_child(_tether_line_layer)


func _process(delta: float) -> void:
	if _tether_base_points.is_empty():
		return
	_tether_time += delta
	for line_key in _tether_base_points.keys():
		_update_tether_visual_frame(line_key)


func _compute_mst_edges(units: Array) -> Array:
	# Returns an Array of [unit_a, unit_b] pairs forming a MINIMUM SPANNING
	# TREE over 'units' — the shortest possible total set of connections
	# that still links every unit into one group. This is what makes each
	# unit connect to its nearest tethered neighbor(s) rather than whatever
	# order they happened to be registered in. Simple O(n²) Prim's — fine
	# for the small unit counts a tether group will ever realistically have.
	var edges: Array = []
	if units.size() < 2:
		return edges

	var in_tree: Array = [units[0]]
	var remaining: Array = units.slice(1)

	while remaining.size() > 0:
		var best_dist: float = INF
		var best_tree_unit = null
		var best_remaining_unit = null
		for t in in_tree:
			for r in remaining:
				var d: float = t.position.distance_squared_to(r.position)
				if d < best_dist:
					best_dist = d
					best_tree_unit = t
					best_remaining_unit = r
		edges.append([best_tree_unit, best_remaining_unit])
		in_tree.append(best_remaining_unit)
		remaining.erase(best_remaining_unit)

	return edges


func _refresh_tether_lines() -> void:
	_ensure_tether_line_layer()

	# Build the full set of line_keys that SHOULD exist this refresh, one
	# per MST edge across every active tether group.
	var desired_keys: Dictionary = {}   # line_key -> [unit_a, unit_b]

	for tether_id in tether_map:
		var live_units: Array = []
		for u in tether_map[tether_id]:
			if is_instance_valid(u):
				live_units.append(u)
		if live_units.size() < 2:
			continue

		var edges: Array = _compute_mst_edges(live_units)
		for i in range(edges.size()):
			var line_key: String = "%s#%d" % [tether_id, i]
			desired_keys[line_key] = edges[i]

	# Tear down any line_key that no longer applies — group broke up, a unit
	# died, or the MST simply reshuffled its connections as units moved.
	for existing_key in _tether_base_points.keys():
		if not desired_keys.has(existing_key):
			_teardown_tether_visual(existing_key)

	# Create/refresh anchor points for every currently-desired connection.
	for line_key in desired_keys:
		var pair: Array = desired_keys[line_key]
		var anchor_points: PackedVector2Array = PackedVector2Array([pair[0].position, pair[1].position])
		_tether_base_points[line_key] = anchor_points
		_ensure_tether_visual_nodes(line_key)

	for line_key in _tether_base_points.keys():
		_update_tether_visual_frame(line_key)


func _ensure_tether_visual_nodes(line_key: String) -> void:
	if _tether_lines.has(line_key):
		return   # Already built — every connection here is a single segment.

	var glow := Line2D.new()
	glow.width           = tether_line_width * tether_glow_width_multiplier
	glow.default_color   = tether_glow_color
	glow.z_index         = 3
	glow.joint_mode      = Line2D.LINE_JOINT_ROUND
	glow.begin_cap_mode  = Line2D.LINE_CAP_ROUND
	glow.end_cap_mode    = Line2D.LINE_CAP_ROUND
	_tether_line_layer.add_child(glow)
	_tether_glow_lines[line_key] = glow

	var line := Line2D.new()
	line.width           = tether_line_width
	line.default_color   = tether_line_color
	line.z_index         = 4
	line.joint_mode      = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode  = Line2D.LINE_CAP_ROUND
	line.end_cap_mode    = Line2D.LINE_CAP_ROUND
	_tether_line_layer.add_child(line)
	_tether_lines[line_key] = line

	var p := CPUParticles2D.new()
	p.emitting              = true
	p.amount                = 6
	p.lifetime              = 1.0
	p.preprocess            = 1.0
	p.emission_shape        = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction             = Vector2(0, -1)
	p.spread                = 180.0
	p.gravity               = Vector2.ZERO
	p.initial_velocity_min  = 4.0
	p.initial_velocity_max  = 14.0
	p.scale_amount_min      = 1.0
	p.scale_amount_max      = 2.2
	p.color                 = tether_particle_color
	p.z_index               = 5
	_tether_line_layer.add_child(p)
	_tether_particles[line_key] = p

	var sp := CPUParticles2D.new()
	sp.emitting              = true
	sp.amount                = tether_sparkle_amount
	sp.lifetime              = 1.6
	sp.preprocess            = 1.6
	sp.emission_shape        = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	sp.direction             = Vector2.ZERO
	sp.spread                = 180.0
	sp.gravity               = Vector2.ZERO
	sp.initial_velocity_min  = 1.0
	sp.initial_velocity_max  = 6.0
	sp.scale_amount_min      = 0.3
	sp.scale_amount_max      = 0.7
	sp.color                 = tether_sparkle_color
	sp.z_index               = 6
	_tether_line_layer.add_child(sp)
	_tether_sparkles[line_key] = sp


func _teardown_tether_visual(line_key: String) -> void:
	if _tether_lines.has(line_key):
		var l: Line2D = _tether_lines[line_key]
		if is_instance_valid(l): l.queue_free()
		_tether_lines.erase(line_key)
	if _tether_glow_lines.has(line_key):
		var g: Line2D = _tether_glow_lines[line_key]
		if is_instance_valid(g): g.queue_free()
		_tether_glow_lines.erase(line_key)
	if _tether_particles.has(line_key):
		var p = _tether_particles[line_key]
		if is_instance_valid(p): p.queue_free()
		_tether_particles.erase(line_key)
	if _tether_sparkles.has(line_key):
		var sp = _tether_sparkles[line_key]
		if is_instance_valid(sp): sp.queue_free()
		_tether_sparkles.erase(line_key)
	_tether_base_points.erase(line_key)


func _update_tether_visual_frame(line_key: String) -> void:
	var anchor_points: PackedVector2Array = _tether_base_points.get(line_key, PackedVector2Array())
	if anchor_points.size() < 2:
		return
	var line: Line2D = _tether_lines.get(line_key)
	var glow: Line2D = _tether_glow_lines.get(line_key)
	if line == null or not is_instance_valid(line):
		return

	var phase_offset: float = float(line_key.hash() % 1000) / 1000.0 * TAU
	var wavy_points: PackedVector2Array = _build_wavy_points(anchor_points, phase_offset)
	line.points = wavy_points
	if glow != null and is_instance_valid(glow):
		glow.points = wavy_points
		var pulse: float = 0.75 + 0.25 * sin(_tether_time * tether_wave_speed * 0.5 + phase_offset)
		glow.default_color.a = tether_glow_color.a * pulse

	var seg_start: Vector2 = anchor_points[0]
	var seg_end: Vector2   = anchor_points[1]
	var seg_length: float  = seg_start.distance_to(seg_end)
	var seg_mid: Vector2   = (seg_start + seg_end) / 2.0
	var seg_rotation: float = seg_start.angle_to_point(seg_end)

	var p = _tether_particles.get(line_key)
	if p != null and is_instance_valid(p):
		p.position              = seg_mid
		p.rotation              = seg_rotation
		p.emission_rect_extents = Vector2(max(4.0, seg_length / 2.0), 6.0)

	var sp = _tether_sparkles.get(line_key)
	if sp != null and is_instance_valid(sp):
		sp.position              = seg_mid
		sp.rotation              = seg_rotation
		sp.emission_rect_extents = Vector2(max(4.0, seg_length / 2.0), 14.0)


func _build_wavy_points(anchor_points: PackedVector2Array, phase_offset: float) -> PackedVector2Array:
	const SUBDIVISIONS_PER_SEGMENT: int = 10

	var total_length: float = anchor_points[0].distance_to(anchor_points[1])
	if total_length <= 0.0:
		return anchor_points

	var seg_start: Vector2 = anchor_points[0]
	var seg_end: Vector2   = anchor_points[1]
	var seg_dir: Vector2   = (seg_end - seg_start).normalized()
	var perpendicular: Vector2 = Vector2(-seg_dir.y, seg_dir.x)

	var result: PackedVector2Array = PackedVector2Array()
	for s in range(SUBDIVISIONS_PER_SEGMENT + 1):
		var t: float = float(s) / float(SUBDIVISIONS_PER_SEGMENT)
		var wave: float = sin(t * TAU * tether_wave_count + _tether_time * tether_wave_speed + phase_offset)
		var taper: float = sin(t * PI)
		var offset: float = tether_wave_amplitude * wave * taper
		result.append(seg_start.lerp(seg_end, t) + perpendicular * offset)

	return result


# ── SHIELD SYSTEM ─────────────────────────────────────────────────────────────

func apply_shield(unit, amount: int, duration_rounds: int) -> void:
	# Gives a unit a damage-absorbing barrier.
	shield_map[unit] = {
		"amount":            amount,
		"remaining_rounds":  duration_rounds
	}


func get_shield(unit) -> Dictionary:
	# Returns the shield entry for a unit, or an empty dict if none.
	return shield_map.get(unit, {})


func absorb_shield_damage(unit, damage: int) -> int:
	# Runs incoming damage through the unit's shield first.
	# Returns the REMAINING damage after the shield absorbs what it can.
	if not shield_map.has(unit): return damage

	var shield = shield_map[unit]
	var absorbed = min(shield["amount"], damage)
	shield["amount"] -= absorbed

	if shield["amount"] <= 0:
		# Shield is depleted — remove it.
		shield_map.erase(unit)

	return damage - absorbed   # Return what got through.

# ── THORNS SYSTEM ─────────────────────────────────────────────────────────────

func apply_thorns(unit, reflect_percent: float, scaling_stat: String, duration: int) -> void:
	# Gives a unit a thorns effect that reflects damage back to attackers.
	thorns_map[unit] = {
		"reflect_percent":  reflect_percent,
		"scaling_stat":     scaling_stat,   # "atk", "matk", "def", or "mdef"
		"remaining_rounds": duration
	}


func get_thorns(unit) -> Dictionary:
	return thorns_map.get(unit, {})


func tick_thorns() -> void:
	var to_remove = []
	for unit in thorns_map:
		thorns_map[unit]["remaining_rounds"] -= 1
		if thorns_map[unit]["remaining_rounds"] <= 0:
			to_remove.append(unit)
	for u in to_remove:
		thorns_map.erase(u)

# ── GUARDIAN SYSTEM ───────────────────────────────────────────────────────────

func apply_guardian(protected_unit, guardian_unit, redirect_percent: float,
					uses_defense: String, duration: int) -> void:
	# Links a Guardian to a protected ally.
	# When protected_unit is attacked, guardian_unit takes a portion.
	guardian_map[protected_unit] = {
		"guardian":          guardian_unit,
		"redirect_percent":  redirect_percent,
		"uses_defense":      uses_defense,  # "caster_def", "caster_mdef", "target_def", "target_mdef"
		"remaining_rounds":  duration
	}


func get_guardian_for(protected_unit) -> Dictionary:
	return guardian_map.get(protected_unit, {})


func tick_guardians() -> void:
	var to_remove = []
	for unit in guardian_map:
		guardian_map[unit]["remaining_rounds"] -= 1
		if guardian_map[unit]["remaining_rounds"] <= 0:
			to_remove.append(unit)
	for u in to_remove:
		guardian_map.erase(u)


func tick_all_effects() -> void:
	# Convenience function — call this once per round from BattleManager.
	# Ticks down every duration-based system at once.
	tick_hazards()
	tick_shields()
	tick_thorns()
	tick_guardians()


# ── MAP FEATURES (ADDED -- draws MapGenerator's scattered obstacles/decor) ────
# map_generator.gd's own comments reference this exact function name/signature
# (spawn_scatter_features), so this is written to match what it already expects.

func spawn_scatter_features(feature_placements: Array) -> void:
	var layer := _ensure_feature_layer()
	for placement in feature_placements:
		var cell: Vector2i = placement.get("cell", Vector2i.ZERO)
		var feature: MapFeatureData = placement.get("feature")
		if feature == null:
			continue

		for offset in feature.footprint:
			var fc: Vector2i = cell + offset
			_apply_feature_tile_rules(fc, feature)

		_spawn_feature_visual(cell, feature, layer)


func _apply_feature_tile_rules(cell: Vector2i, feature: MapFeatureData) -> void:
	# feature_map is a NEW dictionary (added just below tile_map's own
	# declaration) rather than reusing unit_positions -- get_unit_at() and
	# every AI/targeting call that assumes unit_positions only ever holds
	# real UnitNodes would break if a non-unit value showed up there.
	# is_passable()/is_passable_for()/get_movement_cost()/blocks_los() are
	# all extended below (same pattern as the existing wall-hazard checks)
	# to also consult feature_map.
	feature_map[cell] = feature


func _ensure_feature_layer() -> Node2D:
	if has_node("FeatureLayer"):
		return get_node("FeatureLayer")
	var layer := Node2D.new()
	layer.name = "FeatureLayer"
	add_child(layer)
	# Draw above ground tiles, below hazards/units.
	move_child(layer, 1)
	return layer


var _feature_placeholder_cache: Dictionary = {}

func _get_feature_placeholder_texture(tint: Color) -> ImageTexture:
	if _feature_placeholder_cache.has(tint):
		return _feature_placeholder_cache[tint]
	var img := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(tint)
	var tex := ImageTexture.create_from_image(img)
	_feature_placeholder_cache[tint] = tex
	return tex


func _spawn_feature_visual(cell: Vector2i, feature: MapFeatureData, layer: Node2D) -> void:
	var sprite := Sprite2D.new()
	if feature.texture != null:
		sprite.texture = feature.texture
	else:
		# red = blocking, yellow = slowing, gray = decoration -- see
		# map_feature_data.gd's own header comment for this same key.
		match feature.category:
			"blocking":
				sprite.texture = _get_feature_placeholder_texture(Color(0.8, 0.2, 0.2))
			"slowing":
				sprite.texture = _get_feature_placeholder_texture(Color(0.8, 0.7, 0.2))
			_:
				sprite.texture = _get_feature_placeholder_texture(Color(0.5, 0.5, 0.5))
	sprite.position = grid_to_world(cell)
	layer.add_child(sprite)

func is_dangerous_for(cell: Vector2i, unit) -> bool:
	# Returns true if a unit entering this cell right now would trigger
	# hazard damage (i.e. get hurt for stepping onto it). Used by the
	# pathfinder to PREFER routes that avoid hazards when a safe alternative
	# exists. This does NOT block movement — a unit can still be routed
	# through or onto a hazardous tile if that's the only way to reach
	# their destination, or if the destination itself is hazardous.
	#
	# Mirrors the skip/trigger logic in apply_hazard_to_unit(..., "enter"):
	# a TRUE impassable wall never reaches here anyway (already filtered out
	# earlier by _is_blocked_by_wall_hazard), but a "damaging wall"
	# (is_wall_hazard=true, blocks_movement=false) counts as dangerous just
	# like a normal hazard tile.
	#
	# 'unit' is currently unused (no per-unit hazard immunity exists yet),
	# but is kept in the signature so that hook can be added later without
	# changing every call site.
	if not hazard_map.has(cell):
		return false
	for hazard_id in hazard_map[cell]:
		var entry = hazard_map[cell][hazard_id]
		var hdata: HazardData = entry["data"]
		if hdata.is_wall_hazard and hdata.blocks_movement:
			continue   # Impassable walls don't damage — and can't be entered anyway.
		if hdata.trigger_on_enter:
			return true
	return false
