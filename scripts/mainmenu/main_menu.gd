# res://scripts/meta/main_menu.gd
extends Control

# Centralized scene paths for easy editing later
# 📤 EXPORTS TO: SceneTree changes state when buttons are pressed
const BATTLE_SCENE_PATH : String = "res://scenes/battle/BattleScene.tscn"
const UPGRADES_SCENE_PATH: String = "res://scenes/meta/UpgradesScene.tscn"
const SETTINGS_SCENE_PATH: String = "res://scenes/meta/SettingsScene.tscn"
const ACHIEVEMENTS_SCENE_PATH: String = "res://scenes/meta/AchievementsScene.tscn"

@onready var continue_button: Button = $CenterContainer/VBoxContainer/ContinueButton
@onready var new_game_button: Button = $CenterContainer/VBoxContainer/NewGameButton
@onready var achievements_button: Button = $CenterContainer/VBoxContainer/AchievementsButton
@onready var upgrades_button: Button = $CenterContainer/VBoxContainer/UpgradesButton
@onready var settings_button: Button = $CenterContainer/VBoxContainer/SettingsButton

func _ready() -> void:
	# Connect UI signals to our logic functions
	continue_button.pressed.connect(_on_continue_pressed)
	new_game_button.pressed.connect(_on_new_game_pressed)
	achievements_button.pressed.connect(_on_achievements_pressed)
	upgrades_button.pressed.connect(_on_upgrades_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	
	# Determine if there is a save file or active run to continue
	# If not, grey out the Continue button gracefully
	_evaluate_continue_button_state()

func _evaluate_continue_button_state() -> void:
	# Checking if RunManager exists and holds structural data from a previous session
	if RunManager.current_run != null:
		continue_button.disabled = false
	else:
		continue_button.disabled = true

func _on_continue_pressed() -> void:
	print("Resuming previous run...")
	# The RunManager data already exists, so we just jump straight to the battle grid
	_change_scene_to(BATTLE_SCENE_PATH)

# res://scripts/mainmenu/main_menu.gd

func _on_new_game_pressed() -> void:
	print("Starting a completely fresh run! Initializing RunData...")
	RunManager.current_run = RunData.new()
	
	# 1. Load your different unit blueprints
	var berserker_hero = load("res://resources/units/berserker.tres")
	var windmage = load("res://resources/units/windmage.tres")
	
	var starting_party: Array = []
	
	# 2. Safely add them to your squad list if they exist
	if berserker_hero: starting_party.append(berserker_hero)
	if windmage:       starting_party.append(windmage)
	
	# Assign the party array to your run session
	RunManager.current_run.party = starting_party
	
	# 3. Setup individual levels for each hero ID tracking map
	RunManager.current_run.unit_levels = {}
	for hero in starting_party:
		var hero_id = hero.id if "id" in hero else "unknown_hero"
		RunManager.current_run.unit_levels[hero_id] = 1
		
	_change_scene_to(BATTLE_SCENE_PATH)

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
