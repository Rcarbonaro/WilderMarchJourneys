# res://scripts/mainmenu/game_mode_select.gd
#
# GAME MODE SELECT -- the small screen shown after pressing "New Game" on
# the main menu. Lets the player choose:
#   "Random"     -> instantly auto-picks 4 units and jumps straight to battle.
#   "Draft Mode" -> hands off to DraftScene, where the player spends a gold
#                   budget to hand-pick their own 4 units.
#   "Back"       -> returns to the main menu without starting anything.

extends Control

const TAROT_PICK_SCENE_PATH := "res://scenes/meta/TarotPickScene.tscn"
const DRAFT_SCENE_PATH := "res://scenes/meta/DraftScene.tscn"
const MAIN_MENU_SCENE_PATH := "res://scenes/mainmenu/main_menu.tscn"
const TEST_ENCOUNTER_SCENE_PATH := "res://scenes/meta/TestEncounterPickScene.tscn"

@onready var random_button: Button = $CenterContainer/VBoxContainer/RandomModeButton
@onready var draft_button: Button = $CenterContainer/VBoxContainer/DraftModeButton
@onready var back_button: Button = $CenterContainer/VBoxContainer/BackButton
@onready var test_button: Button = $CenterContainer/VBoxContainer/TestModeButton

func _ready() -> void:
	AudioManager.play_menu_music()
	random_button.pressed.connect(_on_random_pressed)
	draft_button.pressed.connect(_on_draft_pressed)
	back_button.pressed.connect(_on_back_pressed)
	test_button.pressed.connect(_on_test_pressed)
	AudioManager.wire_all_buttons_in(self)


func _on_random_pressed() -> void:
	print("Starting a new run in Random mode...")
	var config := ContentLoader.get_game_mode_config("random")

	RunManager.start_new_run("normal")
	RunManager.current_run.draft_or_random_mode = "random"
	RunManager.current_run.gold = int(config.get("starting_gold", 10))
	for equipment_id in config.get("starting_equipment_ids", []):
		RunManager.current_run.equipment_inventory.append(equipment_id)

	var excluded: Array = config.get("excluded_unit_ids", [])
	var available := UnitRosterUtils.get_available_units(excluded)
	if available.is_empty():
		printerr("❌ GameModeSelect: no unit .tres files found in res://resources/units/ -- nothing to spawn.")
		return
	available.shuffle()

	var party_size: int = int(config.get("party_size", 4))
	var chosen_count: int = min(party_size, available.size())
	for i in range(chosen_count):
		var unit_data: UnitData = available[i]
		RunManager.current_run.party.append({
			"unit_id": unit_data.id,
			"instance_id": unit_data.id + "_" + str(Time.get_ticks_msec()) + "_" + str(i),
			"level": 1,
			"equipped_item_ids": [null, null, null],
			"permanent_modifiers": [],
		})
		print("Random party member added: ", unit_data.display_name)

	get_tree().change_scene_to_file(TAROT_PICK_SCENE_PATH)


func _on_draft_pressed() -> void:
	print("Opening Draft Mode...")
	get_tree().change_scene_to_file(DRAFT_SCENE_PATH)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)


func _on_test_pressed() -> void:
	print("Opening Test Mode encounter picker...")
	RunManager.is_test_mode = true
	get_tree().change_scene_to_file(TEST_ENCOUNTER_SCENE_PATH)
