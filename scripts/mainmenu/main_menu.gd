# res://scripts/mainmenu/main_menu.gd
extends Control

# Centralized scene paths for easy editing later
# 📤 EXPORTS TO: SceneTree changes state when buttons are pressed
const GAME_MODE_SELECT_SCENE_PATH: String = "res://scenes/mainmenu/GameModeSelectScene.tscn"
const BATTLE_SCENE_PATH : String = "res://scenes/battle/BattleScene.tscn"
const UPGRADES_SCENE_PATH: String = "res://scenes/meta/UpgradesScene.tscn"
const SETTINGS_SCENE_PATH: String = "res://scenes/meta/SettingsScene.tscn"
const ACHIEVEMENTS_SCENE_PATH: String = "res://scenes/meta/AchievementsScene.tscn"

@onready var continue_button: Button = $CenterContainer/VBoxContainer/ContinueButton
@onready var new_game_button: Button = $CenterContainer/VBoxContainer/NewGameButton
@onready var achievements_button: Button = $CenterContainer/VBoxContainer/AchievementsButton
@onready var upgrades_button: Button = $CenterContainer/VBoxContainer/UpgradesButton
@onready var settings_button: Button = $CenterContainer/VBoxContainer/SettingsButton
@onready var quit_button: Button = $CenterContainer/VBoxContainer/QuitButton


func _ready() -> void:
	# Connect UI signals to our logic functions
	AudioManager.play_menu_music()
	continue_button.pressed.connect(_on_continue_pressed)
	new_game_button.pressed.connect(_on_new_game_pressed)
	achievements_button.pressed.connect(_on_achievements_pressed)
	upgrades_button.pressed.connect(_on_upgrades_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	
	# Determine if there is a save file or active run to continue
	# If not, grey out the Continue button gracefully
	_evaluate_continue_button_state()

func _evaluate_continue_button_state() -> void:
	# Checking if RunManager exists and holds structural data from a previous session
	continue_button.disabled = (RunManager.current_run == null)

func _on_continue_pressed() -> void:
	print("Resuming previous run...")
	# The RunManager data already exists, so we just jump straight to the battle grid
	_change_scene_to(BATTLE_SCENE_PATH)

func _on_new_game_pressed() -> void:
	# "New Game" no longer builds a run by hand here -- it just opens the
	# small Random-vs-Draft choice screen. Game Mode Select is the one that
	# actually calls RunManager.start_new_run(), once the player has either
	# been randomly assigned a party (Random) or finished picking one (Draft).
	print("Opening game mode selection...")
	_change_scene_to(GAME_MODE_SELECT_SCENE_PATH)

func _on_achievements_pressed() -> void:
	print("Opening Achievements panel...")
	# _change_scene_to(ACHIEVEMENTS_SCENE_PATH)

func _on_upgrades_pressed() -> void:
	print("Opening Meta-Progression Upgrades screen...")
	# _change_scene_to(UPGRADES_SCENE_PATH)

func _on_settings_pressed() -> void:
	print("Opening Configuration Options...")
	# _change_scene_to(SETTINGS_SCENE_PATH)

# Helper wrapper function to safely execute scene handoffs
func _change_scene_to(target_scene_path: String) -> void:
	if ResourceLoader.exists(target_scene_path):
		get_tree().change_scene_to_file(target_scene_path)
	else:
		printerr("❌ Scene routing failed: Cannot locate target path: ", target_scene_path)
func _on_quit_pressed() -> void:
	print("Quitting game...")
	get_tree().quit()
