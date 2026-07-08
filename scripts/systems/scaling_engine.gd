# res://scripts/systems/scaling_engine.gd
#
# AUTOLOAD. The ONLY place enemy stat scaling happens. Reads numbers from
# difficulty_budget.json and produces either a "budget" number for a stage
# (used by enemy SELECTION) or a scaled StatsData for a given enemy (used by
# enemy SPAWNING). Never modifies the enemy's own .tres — always builds a
# brand new StatsData in memory.

extends Node

const CONFIG_PATH = "res://content/scaling/difficulty_budget.json"

var _config: Dictionary = {}


func _ready() -> void:
	_reload_config()


func _reload_config() -> void:
	var loaded = ContentLoader.load_json(CONFIG_PATH, false)
	if loaded == null:
		printerr("❌ ScalingEngine: could not load difficulty_budget.json — using hardcoded fallback values.")
		_config = {
			"base_budget": 20, "budget_per_stage": 4,
			"difficulty_multipliers": {"normal": 1.0, "hard": 1.3, "nightmare": 1.6},
			"elite_unlock_stage": 4, "elite_chance_per_stage_after_unlock": 0.05,
			"elite_chance_cap": 0.5,
			"stat_scaling": {
				"hp_per_stage": 3, "atk_per_stage": 1, "def_per_stage": 0.5,
				"difficulty_stat_multipliers": {"normal": 1.0, "hard": 1.2, "nightmare": 1.5}
			}
		}
	else:
		_config = loaded


func get_stage_budget(stage_index: int, difficulty: String) -> float:
	var base: float = _config.get("base_budget", 20)
	var per_stage: float = _config.get("budget_per_stage", 4)
	var mult: float = _config.get("difficulty_multipliers", {}).get(difficulty, 1.0)
	return (base + (stage_index * per_stage)) * mult


func get_elite_chance(stage_index: int) -> float:
	var unlock_stage: int = _config.get("elite_unlock_stage", 4)
	if stage_index < unlock_stage:
		return 0.0
	var per_stage: float = _config.get("elite_chance_per_stage_after_unlock", 0.05)
	var cap: float = _config.get("elite_chance_cap", 0.5)
	var chance: float = (stage_index - unlock_stage + 1) * per_stage
	return min(chance, cap)


func get_scaled_stats(enemy_data: EnemyData, stage_index: int = -1, difficulty: String = "") -> StatsData:
	if stage_index == -1:
		stage_index = RunManager.get_stage_index()
	if difficulty == "":
		difficulty = RunManager.get_difficulty()

	var base: StatsData = enemy_data.base_stats
	var scaling: Dictionary = _config.get("stat_scaling", {})
	var stat_mult: float = scaling.get("difficulty_stat_multipliers", {}).get(difficulty, 1.0)

	var result := StatsData.new()
	result.hp          = int((base.hp   + stage_index * scaling.get("hp_per_stage", 0.0))   * stat_mult)
	result.atk         = int((base.atk  + stage_index * scaling.get("atk_per_stage", 0.0))  * stat_mult)
	result.matk        = int((base.matk + stage_index * scaling.get("matk_per_stage", 0.0)) * stat_mult)
	result.def         = int((base.def  + stage_index * scaling.get("def_per_stage", 0.0))  * stat_mult)
	result.mdef        = int((base.mdef + stage_index * scaling.get("mdef_per_stage", 0.0)) * stat_mult)
	result.mov         = base.mov
	result.crit_chance = base.crit_chance
	result.crit_damage = base.crit_damage
	result.mana        = base.mana

	return result
