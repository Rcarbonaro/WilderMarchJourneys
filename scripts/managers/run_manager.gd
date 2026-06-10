# res://scripts/managers/run_manager.gd

# This is an AUTOLOAD singleton. Add it in Project > Project Settings > Autoload

# Name it "RunManager". Every scene can access it as RunManager.current_run

# 📤 EXPORTS TO: Every major scene — BattleScene, ShopScene, EncounterScene all read this

extends Node

var current_run: RunData = null

# Stage type lookup — what happens at each stage

const STAGE_TYPES = {

	1: "combat", 2: "combat", 3: "encounter",

	4: "combat", 5: "subboss",

	6: "encounter", 7: "combat",

	8: "special_combat", 9: "encounter", 10: "boss"

}

func start_new_run(difficulty: int = 1) -> void:

	current_run = RunData.new()

	current_run.difficulty = difficulty

	current_run.gold = 10

	current_run.current_stage = 1

	# Give starting party (4 random units)

	# 📥 CALLS FROM: UnitPool which holds all available units

	_assign_starting_party()

func get_current_stage_type() -> String:

	return STAGE_TYPES.get(current_run.current_stage, "combat")

func advance_stage() -> void:

	current_run.current_stage += 1

	if current_run.current_stage > 10:

		# Run is complete!

		_run_complete()

func add_gold(amount: int) -> void:

	current_run.gold += amount

func spend_gold(amount: int) -> bool:

	if current_run.gold >= amount:

		current_run.gold -= amount

		return true

	return false

func _assign_starting_party() -> void:

	# For now, just flag — you'll fill this when you have unit resources made

	pass

func _run_complete() -> void:

	# Go to victory scene

	get_tree().change_scene_to_file("res://scenes/meta/VictoryScreen.tscn")
