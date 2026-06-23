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

extends Node2D

const GRID_WIDTH  = 100
const GRID_HEIGHT = 9
const TILE_SIZE   = 96   # pixels per tile — must match highlight_manager.gd

# ── TILE DATA ─────────────────────────────────────────────────────────────────

var tile_map: Dictionary = {}
# Key: Vector2i(col, row)  Value: TileTypeData resource
# Every cell on the board has exactly one TileTypeData.

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

	return true


func get_movement_cost(cell: Vector2i) -> int:
	if not tile_map.has(cell): return 9999
	return tile_map[cell].movement_cost


func blocks_los(cell: Vector2i) -> bool:
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
	unit_positions[cell] = unit


func unregister_unit(cell: Vector2i) -> void:
	# Frees a single cell. For multi-tile units, call for each occupied cell.
	unit_positions.erase(cell)


func get_unit_at(cell: Vector2i):
	# Returns the unit at this cell, or null if empty.
	return unit_positions.get(cell, null)


func register_large_unit(unit, cells: Array) -> void:
	# Convenience: registers a unit across ALL cells it occupies.
	# unit.occupied_cells should already be set before calling this.
	for cell in cells:
		unit_positions[cell] = unit


func unregister_large_unit(unit) -> void:
	# Removes ALL of a large unit's cells from the registry.
	# Reads from unit.occupied_cells (set in unit_node.gd).
	if "occupied_cells" in unit:
		for cell in unit.occupied_cells:
			unit_positions.erase(cell)

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

		unit.take_damage(raw_damage, hdata.damage_type)

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


func unregister_tether(unit, tether_id: String) -> void:
	# Removes a unit from a tether group (on death or expiry).
	if tether_map.has(tether_id):
		tether_map[tether_id].erase(unit)
		if tether_map[tether_id].is_empty():
			tether_map.erase(tether_id)


func get_tethered_units(tether_id: String, exclude_unit) -> Array:
	# Returns all OTHER units in the tether group (not including exclude_unit).
	if not tether_map.has(tether_id): return []
	var result = []
	for u in tether_map[tether_id]:
		if is_instance_valid(u) and u != exclude_unit:
			result.append(u)
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
