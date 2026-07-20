# res://scripts/engines/stage_director.gd
#
# STAGE DIRECTOR -- the single authority for "what happens between every
# stage." Two entry points, called from two different moments:
#
#   complete_stage() -- call this the instant a stage's activity finishes
#     (a battle is won, an encounter resolves). It evaluates reward rules
#     for the stage that JUST ended, advances RunManager to the next stage,
#     then sends the player to DeploymentScene -- the player picks their
#     4-unit team, manages equipment/forging, and can duck into the shop or
#     scout ahead from there before continuing to whatever's next.
#
#   enter_current_stage() -- call this from DeploymentScene's "Continue"
#     button. Looks up whatever stage RunManager is CURRENTLY on (the one
#     complete_stage() already advanced to) and routes to the matching scene.
#
# Register as an autoload named "StageDirector".

extends Node

const SCENE_FOR_STAGE_TYPE: Dictionary = {
	"combat":         "res://scenes/battle/BattleScene.tscn",
	"subboss":        "res://scenes/battle/BattleScene.tscn",
	"special_combat": "res://scenes/battle/BattleScene.tscn",
	"boss":           "res://scenes/battle/BattleScene.tscn",
	"encounter":      "res://scenes/encounter/EncounterScene.tscn",
}
# Every combat-shaped stage type goes to the SAME BattleScene -- what makes
# a normal fight different from a sub-boss, a special-combat reinforcement
# fight, or the final boss is which spawn_table/scaling config
# ScalingEngine resolves for that stage_type, not a different scene. Add an
# entry here only if you introduce a stage type that genuinely needs its
# own dedicated scene.

const SHOP_SCENE_PATH := "res://scenes/meta/ShopScene.tscn"
# Still used by DeploymentScene's own Shop button (see deployment_manager.gd)
# -- ShopScene just isn't the automatic post-stage destination anymore.

const DEPLOYMENT_SCENE_PATH := "res://scenes/meta/DeploymentScene.tscn"
# The default hub complete_stage() now lands the player on. Change this
# constant if you save DeploymentScene.tscn somewhere else -- nothing else
# needs to change to match.

# ── STAGE CONTENT CACHE (Scout Ahead) ─────────────────────────────────────────
# MapGenerator.generate_map() and ScalingEngine.resolve_spawn_table() are both
# pure randomness -- calling either twice for the "same" stage produces a
# DIFFERENT map/roster each time. So generation for a given stage_index
# happens through get_or_generate_stage_content() EXACTLY ONCE per run; both
# the Scout Ahead preview and the real battle later read the same cached
# result, guaranteeing what you scouted is what you actually fight.
#
# In-memory only -- NOT written to disk. If the player saves and reloads
# between scouting a stage and actually playing it, that stage's map/enemies
# get freshly re-rolled instead of matching the old scout report. Acceptable
# for now; persisting this would mean serializing raw TileTypeData/UnitData/
# MapFeatureData Resource references into the save file.
var _stage_content_cache: Dictionary = {}   # stage_index (int) -> content Dictionary
var _cache_run_id: String = ""              # guards against a NEW run reusing a previous run's cache


func get_or_generate_stage_content(stage_index: int) -> Dictionary:
	var run_state := RunManager.current_run
	if run_state == null:
		return {}

	if run_state.run_id != _cache_run_id:
		_stage_content_cache.clear()
		_cache_run_id = run_state.run_id

	if _stage_content_cache.has(stage_index):
		var cached: Dictionary = _stage_content_cache[stage_index]
		# battle_scene.gd/battle_manager.gd both read straight from
		# MapGenerator.last_result -- keep it pointed at THIS stage's cached
		# layout, or scouting stage 6 after already scouting stage 5 would
		# leave stage 6's data sitting there when the player plays stage 5.
		MapGenerator.last_result = {
			"tile_map": cached.get("tile_map", {}),
			"player_spawns": cached.get("ally_cells", []),
			"enemy_spawns": cached.get("enemy_cells", []),
			"feature_placements": cached.get("feature_placements", []),
		}
		return cached

	var stage_type := ContentLoader.get_stage_type(stage_index)
	var biome := "forest"
	if run_state.biome_sequence.size() > 0:
		var slot := ContentLoader.get_biome_slot(stage_index)
		if slot < run_state.biome_sequence.size():
			biome = run_state.biome_sequence[slot]

	# resolve_spawn_table()/get_scaling_config() both read run_state.stage_index
	# internally rather than taking an explicit index -- temporarily point it
	# at the stage being scouted, then restore immediately after. Safe: this
	# is synchronous, nothing else runs between these two lines to observe
	# the temporarily-wrong value.
	var real_stage_index: int = run_state.stage_index
	run_state.stage_index = stage_index
	var roster: Array = ScalingEngine.resolve_spawn_table(run_state)
	var scaling_config: Dictionary = ContentLoader.get_scaling_config(stage_index)
	run_state.stage_index = real_stage_index

	var enemies: Array = []
	for entry in roster:
		var enemy_id: String = entry.get("enemy_id", "")
		var path := "res://resources/enemies/" + enemy_id + "_data.tres"
		if not ResourceLoader.exists(path):
			continue
		var enemy_data: UnitData = load(path) as UnitData
		for _copy_i in range(int(entry.get("count", 1))):
			enemies.append(enemy_data)

	var base_enemy_spawn_cells := 8
	var enemy_spawn_cell_count: int = base_enemy_spawn_cells + int(scaling_config.get("bonus_enemy_count", 0))

	# Same GRID_WIDTH/GRID_HEIGHT battle_scene.gd's _enter_tree() used to read
	# off $BattleGrid directly -- borrowed via the script itself since this
	# autoload has no scene node to reference.
	var battle_grid_script := preload("res://scripts/battle/battle_grid.gd")
	MapGenerator.generate_map(battle_grid_script.GRID_WIDTH, battle_grid_script.GRID_HEIGHT,
		biome, run_state.party.size(), enemy_spawn_cell_count)

	var content := {
		"stage_type": stage_type,
		"biome": biome,
		"enemies": enemies,
		"tile_map": MapGenerator.last_result.get("tile_map", {}),
		"ally_cells": MapGenerator.last_result.get("player_spawns", []),
		"enemy_cells": MapGenerator.last_result.get("enemy_spawns", []),
		"feature_placements": MapGenerator.last_result.get("feature_placements", []),
	}
	_stage_content_cache[stage_index] = content
	return content


func complete_stage() -> void:
	if RunManager.current_run == null:
		push_warning("StageDirector: complete_stage() called with no active run.")
		return

	_apply_reward_rules()
	RunManager.advance_stage()

	if RunManager.current_run == null:
		# The run just ended (stage index went past 30) -- advance_stage()
		# already handled routing to the victory screen, see run_manager.gd.
		return

	# BUGFIX: the shop only ever regenerated when shop_inventory happened to
	# be EMPTY (see shop_manager.gd's _ready()) -- so if the player didn't buy
	# out every single slot, the exact same leftover offer (same items, same
	# prices) just followed them into the next stage's shop visit indefinitely.
	# Clearing it here, every time a stage completes, guarantees a completely
	# fresh ShopEngine.generate_shop() roll the next time ShopScene loads.
	RunManager.current_run.shop_inventory.clear()

	get_tree().change_scene_to_file(DEPLOYMENT_SCENE_PATH)


func enter_current_stage() -> void:
	var stage_type := RunManager.get_current_stage_type()
	var scene_path: String = SCENE_FOR_STAGE_TYPE.get(stage_type, "res://scenes/battle/BattleScene.tscn")
	if not ResourceLoader.exists(scene_path):
		printerr("❌ StageDirector: no scene found at '", scene_path, "' for stage_type '", stage_type, "'.")
		return
	get_tree().change_scene_to_file(scene_path)


func _apply_reward_rules() -> void:
	# Every rule in content/reward_rules/ is checked -- there's no "first
	# match wins." Any rule whose conditions pass against the JUST-FINISHED
	# stage has its effects applied; multiple rules can fire on the same stage.
	var run_state := RunManager.current_run
	var context := {"run_state": run_state, "source": "stage_reward_rule"}
	for rule_id in ContentLoader.reward_rules:
		var rule: Dictionary = ContentLoader.reward_rules[rule_id]
		if EffectSystem.evaluate_conditions(rule.get("conditions", []), context):
			EffectSystem.apply_effects(rule.get("effects", []), context)
			
