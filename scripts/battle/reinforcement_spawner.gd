# res://scripts/battle/reinforcement_spawner.gd
# ==============================================================================
# REINFORCEMENT SPAWNER — generic mid-battle enemy wave spawning. Anything
# that needs to bring more enemies into an ongoing fight (a boss phase
# transition, a hazard, a future "call for backup" ability) hands this a
# ReinforcementWaveData and a summoning unit; this figures out WHERE the new
# units land and calls battle_manager.spawn_unit() for each one.
#
# Add this as a Node (this script attached) under BattleScene. Wired in
# battle_manager.gd's _ready() with a reference back to battle_manager itself
# (needed to reuse spawn_unit(), so new enemies go through the exact same
# registration path as every other enemy — team lists, death signals, etc.)
# ==============================================================================
extends Node

var grid_ref: Node = null
var battle_manager_ref: Node = null

func setup(grid: Node, battle_manager: Node) -> void:
	grid_ref           = grid
	battle_manager_ref = battle_manager


func spawn_wave(wave: ReinforcementWaveData, summoner = null) -> Array:
	if wave == null:
		return []

	var spawned: Array = []
	var occupied_this_call: Dictionary = {}

	for entry in wave.entries:
		if entry.unit_data == null:
			continue
		for _i in range(entry.count):
			var cell = _find_spawn_cell(wave, summoner, occupied_this_call)
			if cell == null:
				push_warning("ReinforcementSpawner: no empty cell found for '%s' — skipped." % entry.unit_data.display_name)
				continue
			occupied_this_call[cell] = true
			battle_manager_ref.spawn_unit(entry.unit_data, cell, false, entry.level)
			var new_unit = battle_manager_ref.enemy_units.back()

			# ADDED — reinforcements sit out the very next enemy turn instead
			# of immediately acting the moment they land. Without this, a
			# unit that spawns mid-round (e.g. from a boss phase transition
			# during the player's turn) gets a full move+attack seconds
			# later when the enemy phase starts — which reads as an unfair
			# "gotcha" hit on whichever player unit happens to be closest/
			# weakest. Marking it acted now excludes it from THIS enemy
			# turn's action snapshot; the normal end-of-turn reset (which
			# runs over ALL enemy_units, this one included) clears the flag
			# right after, so it's fully able to act starting the turn after.
			if new_unit != null:
				new_unit.has_acted = true

			spawned.append(new_unit)

	if wave.announcement_text != "" and EventBus != null:
		EventBus.publish(EventBus.ON_REINFORCEMENTS_SPAWNED, {
			"text": wave.announcement_text, "wave": wave, "summoner": summoner,
		})

	return spawned


func _find_spawn_cell(wave: ReinforcementWaveData, summoner, occupied_this_call: Dictionary):
	match wave.spawn_strategy:
		"designated_cells":
			for cell in wave.designated_cells:
				if _cell_is_free(cell, occupied_this_call):
					return cell
			return null

		"map_edge":
			var edge_cells: Array = MapGenerator.last_result.get("enemy_spawns", [])
			for cell in edge_cells:
				if _cell_is_free(cell, occupied_this_call):
					return cell
			return null

		"near_summoner", _:
			if summoner == null or not is_instance_valid(summoner):
				return null
			# Simple expanding-ring search outward from the summoner.
			for radius in range(1, wave.search_radius + 1):
				for dx in range(-radius, radius + 1):
					for dy in range(-radius, radius + 1):
						if max(abs(dx), abs(dy)) != radius:
							continue   # only check the ring's edge each pass
						var cell = summoner.grid_position + Vector2i(dx, dy)
						if grid_ref.is_valid_cell(cell) and grid_ref.is_terrain_walkable(cell) \
						   and _cell_is_free(cell, occupied_this_call):
							return cell
			return null


func _cell_is_free(cell: Vector2i, occupied_this_call: Dictionary) -> bool:
	if occupied_this_call.has(cell):
		return false
	if not grid_ref.is_valid_cell(cell):
		return false
	if not grid_ref.is_terrain_walkable(cell):
		return false
	return grid_ref.get_unit_at(cell) == null
