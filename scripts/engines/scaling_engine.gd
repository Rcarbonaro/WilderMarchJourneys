# res://scripts/engines/scaling_engine.gd
#
# SCALING ENGINE -- answers two questions before any combat stage begins:
#   1. WHO shows up?    -> resolve_spawn_table()
#   2. HOW STRONG are they? -> apply_scaling()
# Scaling configs are looked up by ABSOLUTE stage_index (1-30), per project
# decision -- even though each biome internally repeats the same stage 1-10
# pattern of combat/encounter/subboss/etc (see ContentLoader.get_stage_type).

extends Node


func get_stage_type(stage_index: int) -> String:
	return ContentLoader.get_stage_type(stage_index)


func resolve_spawn_table(run_state: RunState) -> Array:
	# Returns an Array of {"enemy_id": String, "count": int} describing the
	# enemy roster for the CURRENT stage. Picks one matching spawn_table at
	# random if more than one qualifies.
	var biome := ""
	if run_state.biome_sequence.size() > 0:
		biome = run_state.biome_sequence[ContentLoader.get_biome_slot(run_state.stage_index)]
	var stage_type := get_stage_type(run_state.stage_index)

	var tables := ContentLoader.find_spawn_tables_for(biome, stage_type, run_state.stage_index)
	if tables.is_empty():
		push_warning("ScalingEngine: no spawn table for biome='" + biome + "' stage_type='" +
					  stage_type + "' stage_index=" + str(run_state.stage_index))
		return []

	var table: Dictionary = tables[randi() % tables.size()]
	var roster := []
	for guaranteed_id in table.get("guaranteed_enemy_ids", []):
		roster.append({"enemy_id": guaranteed_id, "count": 1})

	var total_min := int(table.get("total_enemies_min", 1))
	var total_max := int(table.get("total_enemies_max", total_min))
	var target_total: int = total_min + (randi() % max(1, total_max - total_min + 1))

	var pool: Array = table.get("enemy_pool", [])
	if pool.is_empty():
		return roster
	var weights := []
	for p in pool:
		weights.append(float(p.get("weight", 1.0)))

	var placed := roster.size()
	var attempts := 0
	while placed < target_total and attempts < target_total * 5:
		attempts += 1
		var choice = pool[_weighted_pick(weights)]
		roster.append({"enemy_id": choice.get("enemy_id", ""), "count": 1})
		placed += 1

	return roster


func apply_scaling(base_stats: StatsData, run_state: RunState) -> StatsData:
	# Returns a NEW StatsData with every applicable modifier from this
	# stage's scaling config baked in. base_stats is never mutated directly.
	var scaled := StatsData.new()
	scaled.hp = base_stats.hp
	scaled.atk = base_stats.atk
	scaled.matk = base_stats.matk
	scaled.def = base_stats.def
	scaled.mdef = base_stats.mdef
	scaled.mov = base_stats.mov
	scaled.crit_chance = base_stats.crit_chance
	scaled.crit_damage = base_stats.crit_damage
	scaled.mana = base_stats.mana

	var config := ContentLoader.get_scaling_config(run_state.stage_index)
	if config.is_empty():
		return scaled

	var context := {"run_state": run_state}
	_apply_stat_modifiers(scaled, config.get("base_modifiers", []))

	var difficulty_mods: Dictionary = config.get("difficulty_modifiers", {})
	if difficulty_mods.has(run_state.difficulty):
		_apply_stat_modifiers(scaled, difficulty_mods[run_state.difficulty])

	for conditional in config.get("conditional_modifiers", []):
		if EffectSystem.evaluate_condition(conditional.get("condition", {}), context):
			_apply_stat_modifiers(scaled, conditional.get("effects", []))

	return scaled


func _apply_stat_modifiers(stats: StatsData, modifiers: Array) -> void:
	for mod in modifiers:
		if mod.get("type", "") != "add_stat":
			continue
		var amount = mod.get("amount", 0)
		match mod.get("stat", ""):
			"hp":          stats.hp += amount
			"atk":         stats.atk += amount
			"matk":        stats.matk += amount
			"def":         stats.def += amount
			"mdef":        stats.mdef += amount
			"mov":         stats.mov += amount
			"crit_chance": stats.crit_chance += amount
			"crit_damage": stats.crit_damage += amount
			"mana":        stats.mana += amount


func _weighted_pick(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return randi() % weights.size()
	var roll := randf() * total
	var cumulative := 0.0
	for i in range(weights.size()):
		cumulative += weights[i]
		if roll <= cumulative:
			return i
	return weights.size() - 1
