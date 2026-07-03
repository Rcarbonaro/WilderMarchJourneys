# res://scripts/mainmenu/test_encounter_pick.gd
#
# TEST ENCOUNTER PICKER
# Lets you jump straight into a specific hardcoded encounter for development.
# This whole scene (and _spawn_test_enemies in battle_manager.gd) should be
# removed or disabled before shipping the final game.
extends Control

const DRAFT_SCENE_PATH        := "res://scenes/meta/DraftScene.tscn"
const GAME_MODE_SELECT_PATH   := "res://scenes/mainmenu/GameModeSelectScreen.tscn"

# Descriptions shown on each button — update these if you change encounter content.
const ENCOUNTER_LABELS: Array[String] = [
	"Encounter 0: Wolves + Sylvaris",
	"Encounter 1: More Wolves + Ent",
	"Encounter 2: Bears + Sporelings",
	"Encounter 3: Bears + Wolves + Leshy",
	"Encounter 4: Hard Mode",
]

@onready var back_button: Button = $CenterContainer/VBoxContainer/BackButton

func _ready() -> void:
	# Wire up each encounter button by index.
	for i in range(ENCOUNTER_LABELS.size()):
		var btn_name := "Encounter%dButton" % i
		var btn := $CenterContainer/VBoxContainer.get_node_or_null(btn_name) as Button
		if btn == null:
			push_warning("TestEncounterPick: could not find node '%s'." % btn_name)
			continue
		btn.text = ENCOUNTER_LABELS[i]
		btn.pressed.connect(func(): _on_encounter_selected(i))

	back_button.pressed.connect(_on_back_pressed)


func _on_encounter_selected(index: int) -> void:
	print("🧪 Test encounter selected: ", index)
	RunManager.test_encounter_index = index
	# Go to draft so the player can pick their party, then battle_manager
	# will load _spawn_test_enemies() instead of _spawn_stage_enemies().
	get_tree().change_scene_to_file(DRAFT_SCENE_PATH)


func _on_back_pressed() -> void:
	RunManager.is_test_mode = false
	get_tree().change_scene_to_file(GAME_MODE_SELECT_PATH)
