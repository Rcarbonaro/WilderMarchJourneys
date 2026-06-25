# res://scripts/ui/unit_info_popup.gd
#
# UNIT INFO POPUP -- a reusable "character sheet" overlay showing everything
# about a unit: portrait, battle sprite, name, description, abilities (with
# icons + descriptions), stats, and (optionally) equipped items.
#
# WHY THIS IS ITS OWN FILE: both the Draft screen (picking your starting
# party) and the in-battle "Information" button (inspecting a unit/enemy
# mid-fight) need to show almost exactly the same content. Rather than build
# this panel twice, both screens just instantiate THIS class and feed it
# whatever data makes sense for their situation:
#   - Draft screen: a UnitData with no live stats yet, so it passes the
#     unit's level-1 base numbers and an empty equipped-items list (nobody
#     has equipment during the draft).
#   - Battle screen: a UnitData PLUS that unit's CURRENT live numbers
#     (get_effective_atk(), etc., which already account for equipment,
#     buffs, and auras) and their actual equipped items.
#
# This popup is entirely self-contained:
#   - It builds its own dim backdrop behind the card, full-screen, so the
#     player's attention is pulled to the card and the rest of the screen
#     can't be accidentally interacted with while it's open.
#   - Tapping the backdrop OR the Close button both close and free it.
#   - It's read-only -- there is no "confirm/pick/equip" action here. It's
#     purely an information lookup.
#
# HOW TO USE IT (from any screen):
#   var popup := UnitInfoPopup.new()
#   some_full_rect_parent.add_child(popup)
#   popup.setup(unit_data, stat_lines, equipped_item_entries)
#
# 'stat_lines' is an Array[String] of ready-to-display lines like "ATK: 14"
# -- this popup doesn't know or care whether those numbers are static draft
# numbers or live in-battle numbers, which is exactly the point: that
# decision belongs to whichever screen is calling this.
#
# 'equipped_item_entries' is an Array of Dictionaries shaped like
# { "icon": Texture2D (or null), "name": String }. Leave it as the default
# empty array to skip the "Equipped Items" section entirely.

class_name UnitInfoPopup
extends Control

signal closed

const CARD_SIZE          := Vector2(380, 560)
const PORTRAIT_SIZE      := Vector2i(110, 180)
const BATTLE_SPRITE_SIZE := Vector2i(80, 80)
const ABILITY_ICON_SIZE  := Vector2i(40, 40)
const ITEM_ICON_SIZE     := Vector2i(36, 36)
const BACKDROP_COLOR     := Color(0, 0, 0, .1)

var _card: PanelContainer = null


func _ready() -> void:
	# 1. Setup root properties
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Notify Manager
	PopupManager.open_popup(self)

	# 2. Add the backdrop
	var backdrop := ColorRect.new()
	backdrop.color = BACKDROP_COLOR
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	# 3. Create the layout containers
	var center_container := CenterContainer.new()
	center_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center_container)

	var margin_container := MarginContainer.new()
	# Adjust these to position your card
	margin_container.add_theme_constant_override("margin_left", 100)
	margin_container.add_theme_constant_override("margin_top", 50)
	center_container.add_child(margin_container)

	# 4. Create the card
	_card = PanelContainer.new()
	_card.custom_minimum_size = CARD_SIZE
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	margin_container.add_child(_card)

func setup(unit_data: UnitData, stat_lines: Array, equipped_item_entries: Array = []) -> void:
	# Builds the entire card's contents. Call this once, right after adding
	# this popup to the tree (so _ready() has already built the card shell).
	if unit_data == null:
		push_warning("UnitInfoPopup.setup() called with a null UnitData.")
		return

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = CARD_SIZE
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_card.add_child(scroll)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	# ── CLOSE BUTTON ─────────────────────────────────────────────────────────
	var close_button := Button.new()
	close_button.text = "✖ Close"
	close_button.pressed.connect(_close)
	content.add_child(close_button)

	# ── PORTRAIT + BATTLE SPRITE ──────────────────────────────────────────────
	var image_row := HBoxContainer.new()
	image_row.alignment = BoxContainer.ALIGNMENT_CENTER
	image_row.add_theme_constant_override("separation", 12)
	content.add_child(image_row)

	var portrait_rect := TextureRect.new()
	portrait_rect.custom_minimum_size = Vector2(PORTRAIT_SIZE)
	portrait_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait_rect.texture = texture_or_black_box(unit_data.portrait, PORTRAIT_SIZE)
	image_row.add_child(portrait_rect)

	var sprite_rect := TextureRect.new()
	sprite_rect.custom_minimum_size = Vector2(BATTLE_SPRITE_SIZE)
	sprite_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sprite_rect.texture = texture_or_black_box(unit_data.battle_sprite, BATTLE_SPRITE_SIZE)
	image_row.add_child(sprite_rect)

	# ── NAME ──────────────────────────────────────────────────────────────────
	var name_label := Label.new()
	name_label.text = unit_data.display_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 22)
	content.add_child(name_label)

	# ── DESCRIPTION ───────────────────────────────────────────────────────────
	if unit_data.description != "":
		var description_label := Label.new()
		description_label.text = unit_data.description
		description_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		description_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		content.add_child(description_label)

	content.add_child(HSeparator.new())

	# ── STATS ─────────────────────────────────────────────────────────────────
	var stats_header := Label.new()
	stats_header.text = "Stats"
	stats_header.add_theme_font_size_override("font_size", 16)
	content.add_child(stats_header)

	var stats_grid := GridContainer.new()
	stats_grid.columns = 2
	content.add_child(stats_grid)
	for line in stat_lines:
		var stat_label := Label.new()
		stat_label.text = line
		stats_grid.add_child(stat_label)

	content.add_child(HSeparator.new())

	# ── ABILITIES ─────────────────────────────────────────────────────────────
	var abilities_header := Label.new()
	abilities_header.text = "Abilities"
	abilities_header.add_theme_font_size_override("font_size", 16)
	content.add_child(abilities_header)

	var any_ability_shown := false
	for ability in unit_data.starting_abilities:
		if ability == null:
			continue
		any_ability_shown = true

		var ability_row := HBoxContainer.new()
		ability_row.add_theme_constant_override("separation", 8)
		content.add_child(ability_row)

		var ability_icon := TextureRect.new()
		ability_icon.custom_minimum_size = Vector2(ABILITY_ICON_SIZE)
		ability_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ability_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ability_icon.texture = texture_or_black_box(ability.icon, ABILITY_ICON_SIZE)
		ability_row.add_child(ability_icon)

		var ability_text := VBoxContainer.new()
		ability_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ability_row.add_child(ability_text)

		var ability_name_label := Label.new()
		ability_name_label.text = ability.display_name
		ability_text.add_child(ability_name_label)

		if ability.description != "":
			var ability_desc_label := Label.new()
			ability_desc_label.text = ability.description
			ability_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
			ability_desc_label.add_theme_font_size_override("font_size", 12)
			ability_text.add_child(ability_desc_label)

	if not any_ability_shown:
		var no_abilities_label := Label.new()
		no_abilities_label.text = "No abilities."
		content.add_child(no_abilities_label)

	# ── EQUIPPED ITEMS (only shown when the caller actually has any to show) ──
	if not equipped_item_entries.is_empty():
		content.add_child(HSeparator.new())

		var items_header := Label.new()
		items_header.text = "Equipped Items"
		items_header.add_theme_font_size_override("font_size", 16)
		content.add_child(items_header)

		for item_entry in equipped_item_entries:
			var item_row := HBoxContainer.new()
			item_row.add_theme_constant_override("separation", 8)
			content.add_child(item_row)

			var item_icon := TextureRect.new()
			item_icon.custom_minimum_size = Vector2(ITEM_ICON_SIZE)
			item_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			item_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			item_icon.texture = texture_or_black_box(item_entry.get("icon"), ITEM_ICON_SIZE)
			item_row.add_child(item_icon)

			var item_name_label := Label.new()
			item_name_label.text = item_entry.get("name", "Unknown Item")
			item_row.add_child(item_name_label)


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close()


func _close() -> void:
	if PopupManager.current_popup == self:
		PopupManager.current_popup = null
	closed.emit()
	queue_free()


static func texture_or_black_box(tex: Texture2D, size: Vector2i) -> Texture2D:
	# Shared fallback used everywhere this popup (or anything feeding it)
	# needs to show a texture that might not be set: returns 'tex' if it's
	# valid, otherwise generates a plain black placeholder of the requested
	# size so nothing in the UI is ever left visually blank. Draft_scene.gd's
	# own card-building code uses this exact same helper (call it as
	# UnitInfoPopup.texture_or_black_box(...)) instead of keeping its own copy.
	if tex != null:
		return tex
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	return ImageTexture.create_from_image(img)
	
	
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		# Check if the click is OUTSIDE the card's area
		if not _card.get_global_rect().has_point(event.position):
			_close()
			# Mark the input as handled so other things don't trigger
			get_viewport().set_input_as_handled()
