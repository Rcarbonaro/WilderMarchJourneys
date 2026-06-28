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
#   - It builds its own dim backdrop behind the card, full-screen.
#   - PopupManager.open_popup(self) is called on _ready() so only one of
#     these (or whatever else uses PopupManager) is ever open at a time.
#   - Tapping anywhere outside the card closes it (handled in
#     _unhandled_input below), and so does the Close button.
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
#
# CUSTOMIZING THE LOOK: set 'theme_resource' to a UnitInfoPopupTheme resource
# (see unit_info_popup_theme.gd) BEFORE calling setup() if you want a custom
# border, background, per-section plates, or backdrop transparency:
#   popup.theme_resource = preload("res://resources/ui/default_unit_info_theme.tres")
#   popup.setup(unit_data, stat_lines)
# Leave theme_resource unset entirely to keep today's plain default look.

class_name UnitInfoPopup
extends Control

signal closed

# ── POSITION & SIZE ────────────────────────────────────────────────────────────
# Adjust these two constants to move or resize the card. The card is always
# centered on whatever this popup is added as a child of (normally the full
# screen) -- CARD_CENTER_OFFSET then nudges it away from dead-center if you
# want, in pixels (positive X = right, positive Y = down; (0, 0) = perfectly
# centered). This is the ONLY place you need to touch for position/size --
# everything below is built relative to these two values.

const CARD_SIZE          := Vector2(380, 860)   # Width, height of the card itself.
const CARD_CENTER_OFFSET := Vector2(450, 450)        # Shift from dead-center, in pixels.

const PORTRAIT_SIZE      := Vector2i(110, 180)
const BATTLE_SPRITE_SIZE := Vector2i(80, 80)
const ABILITY_ICON_SIZE  := Vector2i(40, 40)
const ITEM_ICON_SIZE     := Vector2i(36, 36)

var theme_resource: UnitInfoPopupTheme = null
# Optional. Set this BEFORE calling setup() to customize border/background/
# plates/backdrop transparency -- see the file header above. If left null,
# setup() creates a blank default theme automatically (today's plain look).

var _card: PanelContainer = null
var _backdrop: ColorRect = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	PopupManager.open_popup(self)

	# ── BACKDROP ──────────────────────────────────────────────────────────────
	# Dims the screen behind the card. Its actual color/alpha gets set from
	# theme_resource.backdrop_color in setup() below (or left at this plain
	# fallback if setup() is somehow never called). mouse_filter is IGNORE
	# here -- outside-click-to-close is handled by _unhandled_input at the
	# bottom of this file instead, so the backdrop doesn't need to capture
	# clicks itself.
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.55)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	# ── CARD ──────────────────────────────────────────────────────────────────
	# Centered directly via anchors (PRESET_CENTER anchors all 4 sides to the
	# midpoint of whatever this popup is parented under, then the 4 offsets
	# below carve out an exact CARD_SIZE rectangle around that midpoint). This
	# is what makes the card track to the center of the VISIBLE screen rather
	# than the top-left corner: it's relative to this popup's own parent size,
	# not a fixed pixel position, so it stays centered regardless of
	# resolution. To move or resize the card, edit CARD_SIZE /
	# CARD_CENTER_OFFSET at the top of this file -- don't add extra
	# CenterContainer/MarginContainer wrappers here, they just make this
	# harder to reason about.
	_card = PanelContainer.new()
	_card.set_anchors_preset(Control.PRESET_CENTER)
	_card.offset_left   = -CARD_SIZE.x / 2.0 + CARD_CENTER_OFFSET.x
	_card.offset_top    = -CARD_SIZE.y / 2.0 + CARD_CENTER_OFFSET.y
	_card.offset_right  =  CARD_SIZE.x / 2.0 + CARD_CENTER_OFFSET.x
	_card.offset_bottom =  CARD_SIZE.y / 2.0 + CARD_CENTER_OFFSET.y
	_card.mouse_filter  = Control.MOUSE_FILTER_STOP   # Clicks on the card itself never close it.
	add_child(_card)


func setup(unit_data: UnitData, stat_lines: Array, equipped_item_entries: Array = []) -> void:
	# Builds the entire card's contents. Call this once, right after adding
	# this popup to the tree (so _ready() has already built the card shell).
	if unit_data == null:
		push_warning("UnitInfoPopup.setup() called with a null UnitData.")
		return

	if theme_resource == null:
		theme_resource = UnitInfoPopupTheme.new()   # Blank theme = today's plain default look.

	_backdrop.color = theme_resource.backdrop_color

	# ── CARD BACKGROUND ────────────────────────────────────────────────────────
	# Replaces the card's default flat panel color with a custom texture, if
	# one was provided. Left untouched (today's plain look) otherwise.
	if theme_resource.card_background != null:
		_card.add_theme_stylebox_override("panel", _make_plate_stylebox(
			theme_resource.card_background, theme_resource.card_background_patch_margin))

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
	name_label.add_theme_font_size_override("font_size", 30)
	content.add_child(name_label)

	# ── DESCRIPTION ───────────────────────────────────────────────────────────
	if unit_data.description != "":
		var description_label := Label.new()
		description_label.text = unit_data.description
		description_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		description_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		content.add_child(_wrap_in_plate(description_label,
			theme_resource.description_plate, theme_resource.description_plate_patch_margin))

	content.add_child(HSeparator.new())

	# ── STATS ─────────────────────────────────────────────────────────────────
# ── STATS ─────────────────────────────────────────────────────────────────
	var stats_header := Label.new()
	stats_header.text = "Stats"
	stats_header.add_theme_font_size_override("font_size", 24)
	content.add_child(stats_header)

	var stats_grid := GridContainer.new()
	stats_grid.columns = 2
	stats_grid.add_theme_constant_override("h_separation", 24)
	stats_grid.add_theme_constant_override("v_separation", 22)

	# 1. Map icons cleanly (No colors applied, per requirement)
	var stat_icons := {
		"HP": preload("res://sprites/UI/Icons/hp_icon.png"),     # Add your path here
		"Mana": preload("res://sprites/UI/Icons/mana_icon.png"), # Add your path here
		"ATK": preload("res://sprites/UI/Icons/atk_icon.png"),
		"MATK": preload("res://sprites/UI/Icons/matk_icon.png"),
		"DEF": preload("res://sprites/UI/Icons/def_icon.png"),
		"MDEF": preload("res://sprites/UI/Icons/mdef_icon.png"),
		"Crit %": preload("res://sprites/UI/Icons/crit%_icon.png"),
		"Crit DMG": preload("res://sprites/UI/Icons/critdmg_icon.png"),
		"MOV": preload("res://sprites/UI/Icons/mov_icon.png")
	}

	for line in stat_lines:
		var parts: PackedStringArray = line.split(": ")
		var stat_name: String = parts[0]
		var stat_value: String = parts[1] if parts.size() > 1 else ""

		var stat_row := HBoxContainer.new()
		stat_row.add_theme_constant_override("separation", 6)

		if stat_name == "HP" or stat_name == "Mana":
			stat_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		# Increased from Vector2(16, 16) to matching Vector2(22, 22)
		var icon_rect := TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(42, 42) 
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		
		if stat_icons.has(stat_name):
			icon_rect.texture = stat_icons[stat_name]
		else:
			icon_rect.texture = texture_or_black_box(null, Vector2i(16, 16))
		stat_row.add_child(icon_rect)

		var stat_label := Label.new()
		stat_label.text = line
		stat_label.add_theme_font_size_override("font_size", 19) 
		stat_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		stat_label.add_theme_constant_override("outline_size", 4)

		stat_row.add_child(stat_label)
		stats_grid.add_child(stat_row)

	content.add_child(_wrap_in_plate(stats_grid,
		theme_resource.stats_plate, theme_resource.stats_plate_patch_margin))

	# ── ABILITIES ─────────────────────────────────────────────────────────────
	var abilities_header := Label.new()
	abilities_header.text = "Abilities"
	abilities_header.add_theme_font_size_override("font_size", 19)
	content.add_child(abilities_header)

	var any_ability_shown := false
	for ability in unit_data.starting_abilities:
		if ability == null:
			continue
		any_ability_shown = true

		var ability_row := HBoxContainer.new()
		ability_row.add_theme_constant_override("separation", 8)

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
			ability_desc_label.add_theme_font_size_override("font_size", 14)
			ability_text.add_child(ability_desc_label)

		content.add_child(_wrap_in_plate(ability_row,
			theme_resource.ability_plate, theme_resource.ability_plate_patch_margin))

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

			var item_icon := TextureRect.new()
			item_icon.custom_minimum_size = Vector2(ITEM_ICON_SIZE)
			item_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			item_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			item_icon.texture = texture_or_black_box(item_entry.get("icon"), ITEM_ICON_SIZE)
			item_row.add_child(item_icon)

			var item_name_label := Label.new()
			item_name_label.text = item_entry.get("name", "Unknown Item")
			item_row.add_child(item_name_label)

			content.add_child(_wrap_in_plate(item_row,
				theme_resource.equipped_item_plate, theme_resource.equipped_item_plate_patch_margin))

	# ── CARD BORDER ───────────────────────────────────────────────────────────
	# Drawn LAST so it's the topmost child of _card, on top of 'scroll' and
	# everything in it -- meant for a frame graphic with a transparent middle.
	# mouse_filter = IGNORE so it never blocks clicks/scrolling on the content
	# underneath it.
	if theme_resource.card_border != null:
		var border_rect := NinePatchRect.new()
		border_rect.texture = theme_resource.card_border
		border_rect.patch_margin_left   = theme_resource.card_border_patch_margin
		border_rect.patch_margin_top    = theme_resource.card_border_patch_margin
		border_rect.patch_margin_right  = theme_resource.card_border_patch_margin
		border_rect.patch_margin_bottom = theme_resource.card_border_patch_margin
		border_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_card.add_child(border_rect)


func _make_plate_stylebox(texture: Texture2D, patch_margin: int) -> StyleBox:
	# Turns a plain uploaded texture into a StyleBoxTexture -- Godot's native
	# "use this image as a panel's background, 9-sliced by these margins"
	# resource. This is what every plate/background/border slot in
	# UnitInfoPopupTheme ultimately becomes when applied.
	var sb := StyleBoxTexture.new()
	sb.texture = texture
	sb.texture_margin_left   = patch_margin
	sb.texture_margin_top    = patch_margin
	sb.texture_margin_right  = patch_margin
	sb.texture_margin_bottom = patch_margin
	return sb


func _wrap_in_plate(inner: Control, texture: Texture2D, patch_margin: int) -> Control:
	# Wraps 'inner' in a PanelContainer using 'texture' as its background
	# plate (sized to fit snugly around 'inner', not the whole card) -- or
	# returns 'inner' completely UNWRAPPED if texture is null, which is
	# exactly today's plain look (no visible plate at all) for that section.
	if texture == null:
		return inner
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_plate_stylebox(texture, patch_margin))
	panel.add_child(inner)
	return panel


func _close() -> void:
	if PopupManager.current_popup == self:
		PopupManager.current_popup = null
	closed.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		# Check if the click is OUTSIDE the card's area.
		if not _card.get_global_rect().has_point(event.position):
			_close()
			# Mark the input as handled so it doesn't also trigger whatever's
			# underneath the popup (a draft card, a battle grid tile, etc.).
			get_viewport().set_input_as_handled()


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
