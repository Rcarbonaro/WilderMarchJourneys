# res://scripts/systems/enemy_selector.gd
#
# AUTOLOAD. Make sure ContentLoader, ScalingEngine, MapGenerator are ABOVE
# it. Picks WHICH enemies spawn for a combat stage — ScalingEngine decides
# "how much budget"/"elite chance"; this spends that budget one enemy at a
# time, respecting tier and pack_tags affinity. Also handles fixed enemy
# groups for encounters AND bosses (get_fixed_group).

extends Node

const ENEMY_FOLDER = "res://content/enemies/"
const ENEMY_GROUP_FOLDER = "res://content/encounters/enemy_groups/"
const BOSS_ENEMY_GROUP_FOLDER = "res://content/bosses/enemy_groups/"
const CONFIG_PATH = "res://content/enemies/enemy_selection_config.json"

var _config: Dictionary = {}


func _ready() -> void:
	_reload_config()


func _reload_config() -> void:
	var loaded = ContentLoader.load_json(CONFIG_PATH, false)
	if loaded == null:
		printerr("❌ EnemySelector: could not load enemy_selection_config.json — using fallback defaults.")
		_config = {"pack_affinity_multiplier": 2.5, "max_enemy_slots": 10}
	else:
		_config = loaded


# ── NORMAL COMBAT: BUDGET-DRIVEN SELECTION ─────────────────────────────────────

func get_enemies_for_stage(stage_index: int, difficulty: String) -> Array:
	var budget: float = ScalingEngine.get_stage_budget(stage_index, difficulty)
	var pool: Array = ContentLoader.load_all_resources_in_folder(ENEMY_FOLDER, "EnemyData")
	pool = pool.filter(func(e): return e.tier != "boss")

	if pool.is_empty():
		printerr("⚠️ EnemySelector: no EnemyData found in ", ENEMY_FOLDER)
		return []

	var max_slots: int = _config.get("max_enemy_slots", 10)
	if MapGenerator.last_enemy_cells.size() > 0:
		max_slots = min(max_slots, MapGenerator.last_enemy_cells.size())

	var chosen: Array = []
	var remaining_budget = budget

	while chosen.size() < max_slots:
		var wants_elite = randf() < ScalingEngine.get_elite_chance(stage_index)
		var tier = "elite" if wants_elite else "normal"

		var candidates = pool.filter(func(e): return e.tier == tier and e.budget_cost <= remaining_budget)
		if candidates.is_empty() and tier == "elite":
			candidates = pool.filter(func(e): return e.tier == "normal" and e.budget_cost <= remaining_budget)
		if candidates.is_empty():
			break

		var picked: EnemyData = _pick_with_pack_affinity(candidates, chosen)
		chosen.append(picked)
		remaining_budget -= picked.budget_cost

	return chosen


func _pick_with_pack_affinity(candidates: Array, already_chosen: Array) -> EnemyData:
	var multiplier: float = _config.get("pack_affinity_multiplier", 2.5)
	var weights: Array = []
	var total: float = 0.0

	for candidate in candidates:
		var w: float = 1.0
		for picked in already_chosen:
			if _shares_pack_tag(candidate, picked):
				w *= multiplier
		weights.append(w)
		total += w

	var roll = randf() * total
	var running = 0.0
	for i in range(candidates.size()):
		running += weights[i]
		if roll <= running:
			return candidates[i]
	return candidates[candidates.size() - 1]


func _shares_pack_tag(a: EnemyData, b: EnemyData) -> bool:
	for tag in a.pack_tags:
		if tag in b.pack_tags:
			return true
	return false


# ── ENCOUNTER/BOSS COMBAT: FIXED GROUPS ─────────────────────────────────────────

func get_fixed_group(group_id: String, folder: String = ENEMY_GROUP_FOLDER) -> Array:
	var path = folder + group_id + ".json"
	var data = ContentLoader.load_json(path)
	if data == null:
		printerr("❌ EnemySelector: enemy group not found: ", path)
		return []

	var result: Array = []
	for enemy_id in data.get("enemies", []):
		var enemy = _find_enemy_by_id(enemy_id)
		if enemy != null:
			result.append(enemy)
		else:
			printerr("⚠️ EnemySelector: enemy id '", enemy_id, "' not found for group '", group_id, "'")
	return result


func _find_enemy_by_id(enemy_id: String) -> EnemyData:
	for enemy in ContentLoader.load_all_resources_in_folder(ENEMY_FOLDER, "EnemyData"):
		if enemy.id == enemy_id:
			return enemy
	return null
