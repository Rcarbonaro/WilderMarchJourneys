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
	var biome := ""
	if run_state.biome_sequence.size() > 0:
		biome = run_state.biome_sequence[ContentLoader.get_biome_slot(run_state.stage_index)]
	var stage_type := get_stage_type(run_state.stage_index)

	var tables := ContentLoader.find_spawn_tables_for(biome, stage_type, run_state.stage_index)
	if tables.is_empty():
		push_warning("ScalingEngine: no spawn table for biome='" + biome + "' stage_type='" +
					  stage_type + "' stage_index=" + str(run_state.stage_index))
		return []

	var shuffled_tables: Array = tables.duplicate()
	shuffled_tables.shuffle()
	for table in shuffled_tables:
		var roster := _build_roster_from_table(table, run_state)
		if not roster.is_empty():
			return roster

	push_warning("ScalingEngine: EVERY spawn table for biome='" + biome + "' stage_type='" +
				  stage_type + "' stage_index=" + str(run_state.stage_index) +
				  " produced an empty roster — check total_enemies_min/max and guaranteed_enemy_ids on those table files.")
	return []


func _build_roster_from_table(table: Dictionary, run_state: RunState) -> Array:
	var roster := []
	for guaranteed_id in table.get("guaranteed_enemy_ids", []):
		roster.append({"enemy_id": guaranteed_id, "count": 1})
	var guaranteed_count := roster.size()

	var scaling_config := ContentLoader.get_scaling_config(run_state.stage_index)

	var total_min := int(table.get("total_enemies_min", 1))
	var total_max := int(table.get("total_enemies_max", total_min))
	var target_total: int = total_min + (randi() % max(1, total_max - total_min + 1))
	target_total += int(scaling_config.get("bonus_enemy_count", 0))

	var pool: Array = table.get("enemy_pool", [])
	if pool.is_empty():
		return roster
	var weights := []
	for p in pool:
		weights.append(float(p.get("weight", 1.0)))

	var elite_chance: float = float(scaling_config.get("elite_chance", 0.0))
	var max_elites: int = int(scaling_config.get("max_elites", -1))
	var min_elites: int = int(scaling_config.get("min_elites", 0))
	var elite_count: int = 0
	for guaranteed_entry in roster:   # ADDED -- guaranteed elites count toward the cap too
		if _get_enemy_tier(guaranteed_entry.get("enemy_id", "")) == "elite":
			elite_count += 1

	var elite_pool_indices: Array = []
	var normal_pool_indices: Array = []
	if elite_chance > 0.0:
		for i in range(pool.size()):
			if _get_enemy_tier(pool[i].get("enemy_id", "")) == "elite":
				elite_pool_indices.append(i)
			else:
				normal_pool_indices.append(i)
	else:
		for i in range(pool.size()):
			normal_pool_indices.append(i)

	var placed := roster.size()
	var attempts := 0
	while placed < target_total and attempts < target_total * 5:
		attempts += 1
		var chosen_entry: Dictionary
		var roll_elite: bool = (elite_chance > 0.0 and not elite_pool_indices.is_empty()
			and randf() < elite_chance
			and (max_elites < 0 or elite_count < max_elites))
		if roll_elite:
			var elite_weights := []
			for i in elite_pool_indices:
				elite_weights.append(weights[i])
			chosen_entry = pool[elite_pool_indices[_weighted_pick(elite_weights)]]
			elite_count += 1
		else:
			if normal_pool_indices.is_empty():
				chosen_entry = pool[_weighted_pick(weights)]
			else:
				var normal_weights := []
				for i in normal_pool_indices:
					normal_weights.append(weights[i])
				chosen_entry = pool[normal_pool_indices[_weighted_pick(normal_weights)]]
		roster.append({"enemy_id": chosen_entry.get("enemy_id", ""), "count": 1})
		placed += 1

	if min_elites > elite_count and not elite_pool_indices.is_empty():
		if max_elites >= 0 and min_elites > max_elites:
			min_elites = max_elites
		var convertible: Array = range(guaranteed_count, roster.size())
		convertible.shuffle()
		for idx in convertible:
			if elite_count >= min_elites:
				break
			var elite_weights := []
			for i in elite_pool_indices:
				elite_weights.append(weights[i])
			var chosen_entry = pool[elite_pool_indices[_weighted_pick(elite_weights)]]
			roster[idx] = {"enemy_id": chosen_entry.get("enemy_id", ""), "count": 1}
			elite_count += 1

	return roster

var _enemy_tier_cache: Dictionary = {}

func _get_enemy_tier(enemy_id: String) -> String:
	if _enemy_tier_cache.has(enemy_id):
		return _enemy_tier_cache[enemy_id]
	var path := "res://resources/enemies/" + enemy_id + "_data.tres"
	var result := "normal"
	if ResourceLoader.exists(path):
		var data: UnitData = load(path) as UnitData
		if data != null and "tier" in data:
			result = data.tier
	_enemy_tier_cache[enemy_id] = result
	return result


func apply_scaling(base_stats: StatsData, run_state: RunState, tier: String = "normal") -> StatsData:
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

	# ---- GLOBAL DIFFICULTY CURVE (ADDED) -------------------------------------
	# A smooth baseline that grows every stage, independent of whether a
	# per-stage scaling file exists for this stage_index and independent of
	# which biome occupies this slot -- so it automatically covers every
	# future stage and every future biome with zero per-stage authoring.
	var global_config: Dictionary = ContentLoader.global_difficulty
	var stages_elapsed: int = max(0, run_state.stage_index - 1)
	if not global_config.is_empty():
		var growth: Dictionary = global_config.get("stat_growth_per_stage", {})
		scaled.hp   += int(round(float(growth.get("hp", 0.0))   * stages_elapsed))
		scaled.atk  += int(round(float(growth.get("atk", 0.0))  * stages_elapsed))
		scaled.matk += int(round(float(growth.get("matk", 0.0)) * stages_elapsed))
		scaled.def  += int(round(float(growth.get("def", 0.0))  * stages_elapsed))
		scaled.mdef += int(round(float(growth.get("mdef", 0.0)) * stages_elapsed))

	# ---- PER-STAGE SCALING CONFIG (unchanged, now optional per-stage) -------
	var config := ContentLoader.get_scaling_config(run_state.stage_index)
	if not config.is_empty():
		var context := {"run_state": run_state}
		_apply_stat_modifiers(scaled, config.get("base_modifiers", []))

		var difficulty_mods: Dictionary = config.get("difficulty_modifiers", {})
		if difficulty_mods.has(run_state.difficulty):
			_apply_stat_modifiers(scaled, difficulty_mods[run_state.difficulty])

		for conditional in config.get("conditional_modifiers", []):
			if EffectSystem.evaluate_condition(conditional.get("condition", {}), context):
				_apply_stat_modifiers(scaled, conditional.get("effects", []))

	# ---- ELITE / BOSS MULTIPLIER ---------------------------------------------
	# Applied AFTER global growth + per-stage modifiers, so it scales the
	# fully-modified total. Per-stage "elite_stat_multiplier" wins if that
	# stage has a config; otherwise falls back to the global config's
	# "default_elite_stat_multiplier"; otherwise 1.5. This means a stage with
	# NO authored scaling file yet still gets a sensible elite multiplier.
	if tier == "elite" or tier == "boss":
		var elite_mult: float = float(config.get(
			"elite_stat_multiplier",
			global_config.get("default_elite_stat_multiplier", 1.5)
		))
		scaled.hp   = int(scaled.hp   * elite_mult)
		scaled.atk  = int(scaled.atk  * elite_mult)
		scaled.matk = int(scaled.matk * elite_mult)
		scaled.def  = int(scaled.def  * elite_mult)
		scaled.mdef = int(scaled.mdef * elite_mult)

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
