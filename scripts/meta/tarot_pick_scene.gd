# res://scripts/meta/tarot_pick_scene.gd
#
# TAROT PICK SCENE -- shown once, right at the start of every run (after
# Random or Draft has assembled the party), letting the player choose 1 of
# 3 blessed tarot cards.
#
# RESPECTS:
#   - a tarot card's "available_modes" field, e.g. ["random"] -- some cards
#     are restricted to one game mode, per the design doc ("Some tarot
#     cards will only appear in 'Random' mode playthroughs"). Omit the
#     field (or leave it an empty array) to make a card available in every
#     mode -- that's the default for all the existing example cards.
#   - "category": "blessed" only. Cursed-card selection is a
#     higher-difficulty feature that isn't wired into this screen yet,
#     since difficulty selection itself doesn't exist as a UI step yet
#     (both Random and Draft currently hardcode "normal").

extends Control

const BATTLE_SCENE_PATH := "res://scenes/battle/BattleScene.tscn"
const CHOICE_COUNT: int = 3
const CARD_SIZE := Vector2(220, 280)

@onready var choice_container: HBoxContainer = $ChoiceContainer

var _offered_tarot_ids: Array[String] = []


func _ready() -> void:
	if RunManager.current_run == null:
		printerr("❌ TarotPickScene: RunManager.current_run is null -- nothing to offer.")
		return
	_offered_tarot_ids = _roll_choices()
	_build_choice_cards()


func _roll_choices() -> Array[String]:
	var run_state := RunManager.current_run
	var eligible: Array[String] = []

	for tarot_id in ContentLoader.tarot_cards:
		var def: Dictionary = ContentLoader.tarot_cards[tarot_id]
		if def.get("category", "blessed") != "blessed":
			continue   # Cursed cards aren't offered by this screen.

		var modes: Array = def.get("available_modes", [])
		if modes.size() > 0 and not modes.has(run_state.draft_or_random_mode):
			continue   # This card is restricted to mode(s) that aren't the current one.

		eligible.append(tarot_id)

	eligible.shuffle()
	var count: int = min(CHOICE_COUNT, eligible.size())
	return eligible.slice(0, count)


func _build_choice_cards() -> void:
	for tarot_id in _offered_tarot_ids:
		var def: Dictionary = ContentLoader.get_tarot(tarot_id)

		var card := Button.new()
		card.custom_minimum_size = CARD_SIZE
		card.pressed.connect(_on_card_pressed.bind(tarot_id))

		var vbox := VBoxContainer.new()
		vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		card.add_child(vbox)

		var name_label := Label.new()
		name_label.text = def.get("name", tarot_id)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(name_label)

		var desc_label := Label.new()
		desc_label.text = def.get("description", "")
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(desc_label)

		choice_container.add_child(card)


func _on_card_pressed(tarot_id: String) -> void:
	EffectSystem.apply_effect(
		{"type": "add_tarot_card", "tarot_id": tarot_id},
		{"run_state": RunManager.current_run, "source": "tarot_pick_screen"}
	)
	print("Tarot card chosen: ", tarot_id)
	get_tree().change_scene_to_file(BATTLE_SCENE_PATH)
