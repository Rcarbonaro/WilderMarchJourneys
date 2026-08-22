# res://scripts/mainmenu/game_mode_select.gd
#
# GAME MODE SELECT -- the small screen shown after pressing "New Game" on
# the main menu. Lets the player choose:
#   "Random"     -> instantly auto-picks 4 units and jumps straight to battle.
#   "Draft Mode" -> hands off to DraftScene, where the player spends a gold
#                   budget to hand-pick their own 4 units.
#   "Tutorial"   -> fixed guided walkthrough -- see tutorial_manager.gd.
#   "Back"       -> returns to the main menu without starting anything.
# Random and Draft both show a difficulty popup first -- see
# _show_difficulty_popup(). Tutorial does not -- it always runs on Easy,
# fixed content.

extends Control

const TAROT_PICK_SCENE_PATH := "res://scenes/meta/TarotPickScene.tscn"
const DRAFT_SCENE_PATH := "res://scenes/meta/DraftScene.tscn"
const TEXT_CRAWL_SCENE_PATH := "res://scenes/intro/TextCrawlScene.tscn"
const MAIN_MENU_SCENE_PATH := "res://scenes/mainmenu/main_menu.tscn"
const TEST_ENCOUNTER_SCENE_PATH := "res://scenes/meta/TestEncounterPickScene.tscn"
const DIFFICULTY_POPUP_SCENE_PATH := "res://scenes/mainmenu/DifficultySelectPopup.tscn"   # ADDED

@onready var random_button: Button = $CenterContainer/VBoxContainer/RandomModeButton
@onready var draft_button: Button = $CenterContainer/VBoxContainer/DraftModeButton
@onready var back_button: Button = $CenterContainer/VBoxContainer/BackButton
@onready var test_button: Button = $CenterContainer/VBoxContainer/TestModeButton
@onready var tutorial_button: Button = $CenterContainer/VBoxContainer/TutorialModeButton   # ADDED
# ^ Requires a Button node named "TutorialModeButton" added as a sibling of
# the other 4 buttons in GameModeSelect.tscn -- this @onready line alone
# does not create it. See the editor steps in the tutorial setup notes.

func _ready() -> void:
	AudioManager.play_menu_music()
	random_button.pressed.connect(_on_random_pressed)
	draft_button.pressed.connect(_on_draft_pressed)
	back_button.pressed.connect(_on_back_pressed)
	test_button.pressed.connect(_on_test_pressed)
	tutorial_button.pressed.connect(_start_tutorial_run)   # ADDED
	AudioManager.wire_all_buttons_in(self)

	# ── MODE TOOLTIPS (ADDED) ─────────────────────────────────────────────────
	random_button.mouse_entered.connect(func(): _show_mode_tooltip("random", random_button))
	random_button.mouse_exited.connect(_hide_mode_tooltip)
	draft_button.mouse_entered.connect(func(): _show_mode_tooltip("draft", draft_button))
	draft_button.mouse_exited.connect(_hide_mode_tooltip)
	test_button.mouse_entered.connect(func(): _show_mode_tooltip("test", test_button))
	test_button.mouse_exited.connect(_hide_mode_tooltip)
	tutorial_button.mouse_entered.connect(func(): _show_mode_tooltip("tutorial", tutorial_button))   # ADDED
	tutorial_button.mouse_exited.connect(_hide_mode_tooltip)   # ADDED
	# BackButton intentionally has no tooltip -- it's not a game mode.


func _show_difficulty_popup(on_chosen: Callable) -> void:   # ADDED
	var popup = load(DIFFICULTY_POPUP_SCENE_PATH).instantiate()
	add_child(popup)
	popup.difficulty_chosen.connect(on_chosen)
	# cancelled is intentionally not connected to anything -- the popup just
	# frees itself and the player's back on this screen, nothing to undo yet.


# ── MODE TOOLTIPS (ADDED) ─────────────────────────────────────────────────────
# Small hover popup describing each mode. Mirrors ui_manager.gd's
# _show_ability_tooltip()/_show_status_tooltip() pattern (same PanelContainer
# + Label + "measure one frame, then clamp inside the viewport" approach) --
# kept as its own small self-contained copy here rather than reaching into
# UIManager, since this screen doesn't otherwise use it at all.

const MODE_DESCRIPTIONS: Dictionary = {
	"random":   "True Roguelike Experience",
	"draft":    "Allows you to select a specific team to play; does not grant progress or achievements",
	"test":     "For testing specific mechanics (Developer tool)",
	"tutorial": "Learn the basics with a guided walkthrough",
}

var _mode_tooltip: PanelContainer = null

func _show_mode_tooltip(mode_key: String, anchor_btn: Control) -> void:
	_hide_mode_tooltip()

	_mode_tooltip              = PanelContainer.new()
	_mode_tooltip.z_index      = 100
	_mode_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_mode_tooltip)

	var desc := Label.new()
	desc.text                = MODE_DESCRIPTIONS.get(mode_key, "")
	desc.custom_minimum_size = Vector2(220, 0)
	desc.autowrap_mode       = TextServer.AUTOWRAP_WORD
	desc.add_theme_font_size_override("font_size", 13)
	_mode_tooltip.add_child(desc)

	# Position above the button, clamped inside the viewport -- same approach
	# as ui_manager.gd's _show_ability_tooltip().
	await get_tree().process_frame   # wait one frame so the tooltip measures itself
	if not is_instance_valid(_mode_tooltip):
		return
	var vp:  Vector2 = get_viewport().get_visible_rect().size
	var pos: Vector2 = anchor_btn.global_position
	pos.y -= _mode_tooltip.size.y + 8.0   # 8px gap above the button
	pos.x  = clamp(pos.x, 4.0, vp.x - _mode_tooltip.size.x - 4.0)
	pos.y  = clamp(pos.y, 4.0, vp.y - _mode_tooltip.size.y - 4.0)
	_mode_tooltip.position = pos


func _hide_mode_tooltip() -> void:
	if is_instance_valid(_mode_tooltip):
		_mode_tooltip.queue_free()
	_mode_tooltip = null


func _on_random_pressed() -> void:
	_show_difficulty_popup(_start_random_run)   # CHANGED -- was the whole body below


func _start_random_run(difficulty: String) -> void:   # CHANGED -- was _on_random_pressed's body, now takes difficulty
	print("Starting a new run in Random mode (difficulty: ", difficulty, ")...")
	var config := ContentLoader.get_game_mode_config("random")

	RunManager.start_new_run(difficulty)  
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

	RunManager.pending_next_scene_path = TAROT_PICK_SCENE_PATH
	SceneTransitions.change_scene(TEXT_CRAWL_SCENE_PATH)   # shows the opening crawl first
	


func _on_draft_pressed() -> void:
	_show_difficulty_popup(_start_draft_run)   # CHANGED -- was the whole body below


func _start_draft_run(difficulty: String) -> void:   # CHANGED -- was _on_draft_pressed's body, now takes difficulty
	print("Opening Draft Mode (difficulty: ", difficulty, ")...")
	# Create the run NOW (rather than letting DraftScene do it later) so its
	# difficulty is already set -- DraftScene's start_new_run_for_mode()
	# reads current_run.difficulty if a run already exists, falling back to
	# "normal" only when it doesn't. Without this, Draft mode would silently
	# always be "normal" regardless of what was picked here.
	RunManager.start_new_run(difficulty)  
	RunManager.pending_next_scene_path = DRAFT_SCENE_PATH
	SceneTransitions.change_scene(TEXT_CRAWL_SCENE_PATH)   # shows the opening crawl first

func _on_back_pressed() -> void:
	# "fade" — see the brief's example: main-menu transitions get their
	# own distinct (calmer) style, matching main_menu.gd's outbound trip.
	SceneTransitions.change_scene(MAIN_MENU_SCENE_PATH, "fade")


func _on_test_pressed() -> void:
	print("Opening Test Mode encounter picker...")
	RunManager.is_test_mode = true
	SceneTransitions.change_scene(TEST_ENCOUNTER_SCENE_PATH)   # default style — task 5


func _start_tutorial_run() -> void:
	RunManager.start_tutorial_run()
	SceneTransitions.change_scene("res://scenes/battle/BattleScene.tscn", "parchment_burn")
