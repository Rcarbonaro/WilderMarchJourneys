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
	AudioManager.wire_all_buttons_in(self)
	_apply_sunrise_theme()   
 
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


const SUNRISE_THEME_PANEL_BG      := Color(0.129, 0.090, 0.055, 0.94)
const SUNRISE_THEME_BORDER        := Color(0.925, 0.706, 0.302, 1.0)   # warm gold
const SUNRISE_THEME_BORDER_BRIGHT := Color(1.000, 0.784, 0.376, 1.0)   # bright gold/orange
const SUNRISE_THEME_ACCENT        := Color(0.945, 0.545, 0.169, 1.0)   # deep sunset orange
const SUNRISE_THEME_GLOW          := Color(0.945, 0.545, 0.169, 0.4)
const SUNRISE_THEME_TEXT          := Color(1.000, 0.940, 0.850, 1.0)   # warm cream
 
 
func _apply_sunrise_theme() -> void:
	for btn in [continue_button, new_game_button, achievements_button,
				upgrades_button, settings_button, quit_button]:
		_style_sunrise_button(btn)
 
 
func _style_sunrise_button(button: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = SUNRISE_THEME_PANEL_BG
	normal.set_border_width_all(2)
	normal.border_color = SUNRISE_THEME_BORDER
	normal.set_corner_radius_all(6)
	normal.content_margin_left = 18
	normal.content_margin_top = 10
	normal.content_margin_right = 18
	normal.content_margin_bottom = 10
 
	var hover: StyleBoxFlat = normal.duplicate()
	hover.border_color = SUNRISE_THEME_BORDER_BRIGHT
	hover.shadow_color = SUNRISE_THEME_GLOW
	hover.shadow_size = 6
 
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.border_color = SUNRISE_THEME_ACCENT
	pressed.bg_color = SUNRISE_THEME_PANEL_BG.darkened(0.25)
 
	# Disabled is a SEPARATE style from normal/hover/pressed -- without this,
	# a disabled button (like Continue with no active run) falls back to the
	# base steel theme's disabled look instead of a dimmed sunrise look.
	var disabled: StyleBoxFlat = normal.duplicate()
	disabled.border_color = SUNRISE_THEME_BORDER.darkened(0.45)
	disabled.bg_color = SUNRISE_THEME_PANEL_BG.darkened(0.35)
	disabled.bg_color.a = 0.6
 
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_color", SUNRISE_THEME_TEXT)
	button.add_theme_color_override("font_hover_color", SUNRISE_THEME_TEXT.lightened(0.15))
	button.add_theme_color_override("font_pressed_color", SUNRISE_THEME_ACCENT)
	button.add_theme_color_override("font_disabled_color", SUNRISE_THEME_TEXT.darkened(0.5))
