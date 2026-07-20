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


const TAROT_CARD_BG_PATH := "res://sprites/UI/tarot/tarot_card.png"
 
 
func _build_choice_cards() -> void:
	var card_bg_texture: Texture2D = load(TAROT_CARD_BG_PATH)
 
	for tarot_id in _offered_tarot_ids:
		var def: Dictionary = ContentLoader.get_tarot(tarot_id)
 
		var card := Button.new()
		card.custom_minimum_size = CARD_SIZE
		card.clip_contents = true
		card.pressed.connect(_on_card_pressed.bind(tarot_id))
		_style_tarot_card_button(card)
 
		# Background art -- added FIRST so it renders behind everything else.
		if card_bg_texture != null:
			var bg := TextureRect.new()
			bg.texture = card_bg_texture
			bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			card.add_child(bg)
 
		var vbox := VBoxContainer.new()
		vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		vbox.alignment = BoxContainer.ALIGNMENT_END   # push text to the bottom of the card
		card.add_child(vbox)
 
		# Semi-transparent backdrop behind the text, since it now sits on
		# top of art instead of a flat panel color.
		var backdrop_style := StyleBoxFlat.new()
		backdrop_style.bg_color = Color(0, 0, 0, 0.55)
		backdrop_style.content_margin_left = 8
		backdrop_style.content_margin_right = 8
		backdrop_style.content_margin_top = 6
		backdrop_style.content_margin_bottom = 8
 
		var text_panel := PanelContainer.new()
		text_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_panel.add_theme_stylebox_override("panel", backdrop_style)
		vbox.add_child(text_panel)
 
		var text_box := VBoxContainer.new()
		text_panel.add_child(text_box)
 
		var name_label := Label.new()
		name_label.text = def.get("name", tarot_id)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		name_label.add_theme_constant_override("outline_size", 5)
		text_box.add_child(name_label)
 
		var desc_label := Label.new()
		desc_label.text = def.get("description", "")
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc_label.add_theme_font_size_override("font_size", 19)
		desc_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1))
		desc_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		desc_label.add_theme_constant_override("outline_size", 4)
		text_box.add_child(desc_label)
 
		choice_container.add_child(card)
 
 
func _style_tarot_card_button(card: Button) -> void:
	# Colors inlined here (not read from UIColors) so this works with zero
	# autoload dependencies -- if you DO have UIColors registered, these
	# match UIColors.MAGIC_GLOW and UIColors.ACCENT_GOLD exactly.
	const GLOW_COLOR := Color(0.42, 0.85, 1.0, 1.0)
	const GOLD_COLOR := Color(0.831, 0.702, 0.31, 1.0)
 
	# Transparent normal state so the card art shows through cleanly.
	var normal := StyleBoxFlat.new()
	normal.draw_center = false
	normal.set_border_width_all(0)
 
	var hover := StyleBoxFlat.new()
	hover.draw_center = false
	hover.set_border_width_all(3)
	hover.border_color = GLOW_COLOR
	hover.set_corner_radius_all(10)
	hover.shadow_color = GLOW_COLOR
	hover.shadow_color.a = 0.5
	hover.shadow_size = 10
 
	var pressed := StyleBoxFlat.new()
	pressed.draw_center = false
	pressed.set_border_width_all(3)
	pressed.border_color = GOLD_COLOR
	pressed.set_corner_radius_all(10)
 
	card.add_theme_stylebox_override("normal", normal)
	card.add_theme_stylebox_override("hover", hover)
	card.add_theme_stylebox_override("pressed", pressed)
	card.add_theme_stylebox_override("focus", hover)

func _on_card_pressed(tarot_id: String) -> void:
	EffectSystem.apply_effect(
		{"type": "add_tarot_card", "tarot_id": tarot_id},
		{"run_state": RunManager.current_run, "source": "tarot_pick_screen"}
	)
	print("Tarot card chosen: ", tarot_id)
	get_tree().change_scene_to_file(BATTLE_SCENE_PATH)
