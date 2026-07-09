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

	# ADDED -- elite-frequency roll. elite_chance comes from the SAME
	# per-stage scaling config elite_stat_multiplier already lives in
	# (content/scaling/<stage>.json), so "how many elites this far into the
	# run" is entirely data-driven: author elite_chance to be 0 (or just
	# absent) on early stages and rise on later ones, exactly like every
	# other scaling number in this project.
	var scaling_config := ContentLoader.get_scaling_config(run_state.stage_index)
	var elite_chance: float = float(scaling_config.get("elite_chance", 0.0))
	var elite_pool_indices: Array = []
	if elite_chance > 0.0:
		for i in range(pool.size()):
			if _get_enemy_tier(pool[i].get("enemy_id", "")) == "elite":
				elite_pool_indices.append(i)

	var placed := roster.size()
	var attempts := 0
	while placed < target_total and attempts < target_total * 5:
		attempts += 1

		var chosen_entry: Dictionary
		# Roll for elite FIRST, so "no elite-tagged enemy in this table's
		# pool yet" quietly falls back to a normal pick instead of silently
		# doing nothing -- see the elite-authoring note in the README if
		# elites never seem to appear for a table you expect them in.
		if elite_chance > 0.0 and not elite_pool_indices.is_empty() and randf() < elite_chance:
			var elite_weights := []
			for i in elite_pool_indices:
				elite_weights.append(weights[i])
			chosen_entry = pool[elite_pool_indices[_weighted_pick(elite_weights)]]
		else:
			chosen_entry = pool[_weighted_pick(weights)]

		roster.append({"enemy_id": chosen_entry.get("enemy_id", ""), "count": 1})
		placed += 1

	return roster


var _enemy_tier_cache: Dictionary = {}   # enemy_id -> "normal"/"elite"/"boss", avoids re-loading the same .tres every roll

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
	# Returns a NEW StatsData with every applicable modifier from this
	# stage's scaling config baked in. base_stats is never mutated directly.
	# ADDED 'tier' param: when "elite" (or "boss"), an extra flat multiplier
	# is applied on top of everything else -- see the elite_stat_multiplier
	# read below.
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

	# ADDED -- elite/boss multiplier, applied AFTER every other modifier so it
	# scales the fully-modified total rather than just the base stat. Reads
	# "elite_stat_multiplier" from the SAME per-stage scaling config file
	# (defaults to 1.5 if that key isn't set), so you can tune how much
	# stronger elites are on a stage-by-stage (or even per-difficulty) basis
	# right alongside every other scaling number, instead of a separate file.
	if tier == "elite" or tier == "boss":
		var elite_mult: float = float(config.get("elite_stat_multiplier", 1.5))
		scaled.hp   = int(scaled.hp   * elite_mult)
		scaled.atk  = int(scaled.atk  * elite_mult)
		scaled.matk = int(scaled.matk * elite_mult)
		scaled.def  = int(scaled.def  * elite_mult)
		scaled.mdef = int(scaled.mdef * elite_mult)
		# mov/crit_chance/crit_damage/mana deliberately NOT multiplied here --
		# an elite with 3x movement or 3x crit chance usually isn't what
		# "elite" is meant to convey. Add them to this block yourself if you
		# want elites to scale on those too.

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
