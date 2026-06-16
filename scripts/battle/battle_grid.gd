# res://scripts/battle/battle_grid.gd
#
# THE BATTLE GRID — the game board.
# Tracks tile types, unit positions, hazards, and all special effect maps
# (tethers, shields, guardian links, thorns).
#
# WHAT'S NEW:
#   - Hazards now enforced max 3 turns; only one of each type per tile.
#   - Multi-tile unit support: large units (2×2, etc.) occupy multiple cells.
#   - Tether tracking: a dictionary mapping tether_id → list of unit nodes.
#   - Shield / Guardian / Thorns data stored per unit so ability_executor
#     can look them up during damage resolution.

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
#   "data"           : HazardData resource (the template)
#   "remaining"      : int  (turns left before expiry)
#   "caster"         : UnitNode that placed this hazard (may be null)
#   "visual"         : Node2D visual placed on HazardLayer (may be null)
# Only ONE hazard of each id is allowed per tile. A second placement of
# the same type refreshes the duration instead of stacking.

const HAZARD_MAX_TURNS: int = 3
# Hard cap: no hazard can last more than 3 turns, regardless of HazardData.

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


func _draw_tiles() -> void:
	# Spawns a Sprite2D for each tile so the map is visible on screen.
	for cell in tile_map:
		var tile_type: TileTypeData = tile_map[cell]
		var sprite = Sprite2D.new()
		sprite.texture = tile_type.tile_texture
		sprite.position = grid_to_world(cell)
		$GroundLayer.add_child(sprite)

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
	if not is_valid_cell(cell): return false
	if not tile_map.has(cell):  return false
	var tile: TileTypeData = tile_map[cell]
	if tile.is_wall:            return false
	if unit_positions.has(cell): return false
	return true
	
	
func is_terrain_walkable(cell: Vector2i) -> bool:
	# 1. Check if the cell is valid/inside the map
	if not is_valid_cell(cell): return false
	# 2. Check if the tile exists in our data
	if not tile_map.has(cell):  return false
	
	# 3. ONLY check if it is a wall. 
	# We purposefully exclude the 'unit_positions' check here.
	var tile: TileTypeData = tile_map[cell]
	if tile.is_wall:           return false
	
	return true



func get_movement_cost(cell: Vector2i) -> int:
	if not tile_map.has(cell): return 9999
	return tile_map[cell].movement_cost


func blocks_los(cell: Vector2i) -> bool:
	if not tile_map.has(cell): return false
	return tile_map[cell].blocks_line_of_sight or tile_map[cell].is_wall

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

func add_hazard(cell: Vector2i, hazard_data: HazardData, caster = null) -> void:
	# Places (or refreshes) a hazard on a tile.
	# Rules:
	#   - Only one hazard of each TYPE (id) per tile.
	#   - Duration is clamped to HAZARD_MAX_TURNS (3).
	#   - If the same hazard id already exists here, we refresh duration only.

	if not hazard_map.has(cell):
		hazard_map[cell] = {}

	var slot = hazard_map[cell]

	# Check if this exact hazard type already exists at this cell.
	if slot.has(hazard_data.id):
		# Refresh duration — do NOT stack a second copy.
		slot[hazard_data.id]["remaining"] = min(hazard_data.duration_rounds, HAZARD_MAX_TURNS)
		return

	# New hazard type: calculate duration with the 3-turn cap.
	var duration = hazard_data.duration_rounds if not hazard_data.is_permanent \
				   else 9999
	duration = min(duration, HAZARD_MAX_TURNS)

	# Spawn a visual icon on the HazardLayer so the player can see it.
	var visual: Node2D = null
	if hazard_data.icon != null and has_node("HazardLayer"):
		var sprite = Sprite2D.new()
		sprite.texture = hazard_data.icon
		sprite.position = grid_to_world(cell)
		sprite.modulate = Color(1, 1, 1, 0.75)  # Slightly transparent so tile is visible.
		$HazardLayer.add_child(sprite)
		visual = sprite

	slot[hazard_data.id] = {
		"data":      hazard_data,
		"remaining": duration,
		"caster":    caster,
		"visual":    visual
	}


func remove_hazard(cell: Vector2i, hazard_id: String) -> void:
	# Removes a specific hazard type from a tile and cleans up its visual.
	if not hazard_map.has(cell): return
	var slot = hazard_map[cell]
	if not slot.has(hazard_id): return

	var entry = slot[hazard_id]
	if entry["visual"] != null and is_instance_valid(entry["visual"]):
		entry["visual"].queue_free()

	slot.erase(hazard_id)
	if slot.is_empty():
		hazard_map.erase(cell)


func get_hazards_at(cell: Vector2i) -> Array:
	# Returns a list of all active hazard entries at this cell.
	# Each entry is a Dictionary with keys: data, remaining, caster, visual.
	if not hazard_map.has(cell): return []
	return hazard_map[cell].values()


func tick_hazards() -> void:
	# Called once per round (by BattleManager) to count down hazard durations.
	# Any hazard that reaches 0 remaining turns is removed automatically.
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
	# Applies damage and status from ALL hazards at 'cell' to 'unit',
	# but ONLY if the hazard's trigger condition matches 'trigger'.
	#
	# trigger can be:
	#   "enter"        — unit just stepped onto the tile
	#   "start_of_turn"— it is the start of the unit's turn
	#   "end_of_turn"  — it is the end of the unit's turn

	if not hazard_map.has(cell): return

	for hazard_id in hazard_map[cell]:
		var entry = hazard_map[cell][hazard_id]
		var hdata: HazardData = entry["data"]

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


func tick_shields() -> void:
	# Counts down shield durations. Called each round.
	var to_remove = []
	for unit in shield_map:
		shield_map[unit]["remaining_rounds"] -= 1
		if shield_map[unit]["remaining_rounds"] <= 0:
			to_remove.append(unit)
	for u in to_remove:
		shield_map.erase(u)

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
