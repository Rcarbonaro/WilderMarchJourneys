# res://scripts/engines/stage_director.gd
#
# STAGE DIRECTOR -- the single authority for "what happens between every
# stage." Two entry points, called from two different moments:
#
#   complete_stage() -- call this the instant a stage's activity finishes
#     (a battle is won, an encounter resolves). It evaluates reward rules
#     for the stage that JUST ended, advances RunManager to the next stage,
#     then sends the player to the shop -- per the design doc, the player
#     shops BETWEEN every stage, regardless of what the next one is.
#
#   enter_current_stage() -- call this from the shop's "Continue" button
#     once it's been built. Looks up whatever stage RunManager is CURRENTLY
#     on (the one complete_stage() already advanced to) and routes to the
#     matching scene.
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

	get_tree().change_scene_to_file(SHOP_SCENE_PATH)


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
