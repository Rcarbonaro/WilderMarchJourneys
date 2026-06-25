# res://scripts/meta/draft_scene.gd
#
# DRAFT SCENE -- lets the player hand-pick their starting party of 4 units,
# spending a limited "draft budget" of gold (separate from the run's actual
# starting gold, EXCEPT that whatever's left over when you confirm gets
# added on top of it -- see _on_confirm_pressed). Each unit's cost comes
# straight from its own UnitData resource (unit_data.cost_gold) -- the same
# field ShopEngine already reads.
#
# HOW THE ROSTER IS BUILT: every *.tres file inside res://resources/units/
# is automatically offered, except any unit id listed in this mode's excluded_unit_ids
# below (see unit_roster_utils.gd). Add a new unit by dropping its .tres
# file in that folder -- no code changes needed unless you want to exclude it.
#
# EACH CARD shows, straight from that unit's UnitData: portrait, battle
# sprite, and display_name. If portrait or battle_sprite is unset (null),
# a plain black box is generated and shown in its place instead -- nothing
# is ever left blank.
#
# DESCRIPTION BUTTON: each card also has a small "Description" button that
# opens a read-only UnitInfoPopup (see unit_info_popup.gd) showing that
# unit's portrait, sprite, name, description, abilities (icons + text), and
# level-1 stats. It's purely informational -- there's no way to draft the
# unit from inside it; close it and tap the card itself to pick them.

extends Control

const TAROT_PICK_SCENE_PATH := "res://scenes/meta/TarotPickScene.tscn"
const BACK_SCENE_PATH := "res://scenes/mainmenu/GameModeSelectScene.tscn"

const CARD_SIZE := Vector2(170, 300)
const PORTRAIT_SIZE := Vector2i(90, 150)
const BATTLE_SPRITE_SIZE := Vector2i(60, 60)

@onready var gold_label: Label = $TopBar/GoldLabel
@onready var roster_grid: GridContainer = $RosterScrollContainer/RosterGrid
@onready var selected_party_container: HBoxContainer = $SelectedPartyContainer
@onready var confirm_button: Button = $BottomBar/ConfirmButton
@onready var back_button: Button = $TopBar/BackButton

var _config: Dictionary = {}
var _party_size: int = 4
var _available_units: Array[UnitData] = []
var _selected_units: Array[UnitData] = []      # up to _party_size, in pick order
var _card_buttons: Dictionary = {}              # unit_data.id -> Button, for refreshing visuals
var _remaining_gold: int = 0


func _ready() -> void:
	_config = ContentLoader.get_game_mode_config("draft")
	_party_size = int(_config.get("party_size", 4))
	_remaining_gold = int(_config.get("draft_budget", 20))
	roster_grid.columns = 7           # Determines columns of units

	back_button.pressed.connect(_on_back_pressed)
	confirm_button.pressed.connect(_on_confirm_pressed)
	_build_roster()
	_refresh_ui()


func _build_roster() -> void:
	var excluded: Array = _config.get("excluded_unit_ids", [])
	_available_units = UnitRosterUtils.get_available_units(excluded)
	if _available_units.is_empty():
		printerr("❌ DraftScene: no unit .tres files found in res://resources/units/.")
	for unit_data in _available_units:
		var card := _build_unit_card(unit_data)
		roster_grid.add_child(card)
		_card_buttons[unit_data.id] = card


func _build_unit_card(unit_data: UnitData) -> Button:
	# A "card" is just a toggle Button with a small VBoxContainer of child
	# Controls laid on top of it -- Godot renders the children fine even
	# though Button normally shows plain text; we just never set card.text.
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.toggle_mode = true
	card.pressed.connect(_on_unit_card_pressed.bind(unit_data))

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE   # let clicks pass through to the card button
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.add_child(vbox)

	var portrait_rect := TextureRect.new()
	portrait_rect.custom_minimum_size = Vector2(PORTRAIT_SIZE)
	portrait_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait_rect.texture = UnitInfoPopup.texture_or_black_box(unit_data.portrait, PORTRAIT_SIZE)
	vbox.add_child(portrait_rect)

	var battle_sprite_rect := TextureRect.new()
	battle_sprite_rect.custom_minimum_size = Vector2(BATTLE_SPRITE_SIZE)
	battle_sprite_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	battle_sprite_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	battle_sprite_rect.texture = UnitInfoPopup.texture_or_black_box(unit_data.battle_sprite, BATTLE_SPRITE_SIZE)
	vbox.add_child(battle_sprite_rect)

	var name_label := Label.new()
	name_label.text = unit_data.display_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(name_label)

	var cost_label := Label.new()
	cost_label.text = str(unit_data.cost_gold) + " Gold"
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(cost_label)

	# A real Button (unlike the rest of this card's children) captures its own
	# clicks by default (mouse_filter = STOP), so tapping it fires ONLY its own
	# pressed signal -- it does NOT also toggle the parent card's selection.
	var description_button := Button.new()
	description_button.text = "📜 Description"
	description_button.add_theme_font_size_override("font_size", 11)
	description_button.pressed.connect(_on_description_pressed.bind(unit_data))
	vbox.add_child(description_button)

	return card


func _on_description_pressed(unit_data: UnitData) -> void:
	_show_description_popup(unit_data)


func _show_description_popup(unit_data: UnitData) -> void:
	# Read-only "character sheet" lookup -- no draft action lives in here.
	# Close it, then tap the card itself if you want to actually pick them.
	var popup := UnitInfoPopup.new()
	add_child(popup)

	# No live UnitNode exists yet during the draft (nobody's equipped
	# anything or leveled up), so "effective stats" here just means this
	# unit's LEVEL 1 base numbers straight from their UnitData -- the exact
	# numbers they'll actually start the run with.
	var stats: StatsData = null
	if not unit_data.stats_by_level.is_empty():
		stats = unit_data.stats_by_level[0]
	elif unit_data.base_stats != null:
		stats = unit_data.base_stats

	var stat_lines: Array = []
	if stats != null:
		stat_lines.append("HP: " + str(stats.hp))
		if stats.mana > 0:
			stat_lines.append("Mana: " + str(stats.mana))
		stat_lines.append("ATK: " + str(stats.atk))
		stat_lines.append("MATK: " + str(stats.matk))
		stat_lines.append("DEF: " + str(stats.def))
		stat_lines.append("MDEF: " + str(stats.mdef))
		stat_lines.append("MOV: " + str(stats.mov))
		stat_lines.append("Crit %%: %.0f%%" % stats.crit_chance)
		stat_lines.append("Crit DMG: %.0f%%" % stats.crit_damage)
	else:
		stat_lines.append("(No stats configured.)")

	# No equipped_item_entries passed -- nobody has equipment yet during the
	# draft, so the popup simply omits that section entirely.
	popup.setup(unit_data, stat_lines)


func _on_unit_card_pressed(unit_data: UnitData) -> void:
	if unit_data in _selected_units:
		# Deselect: refund the cost and remove from the party.
		_selected_units.erase(unit_data)
		_remaining_gold += unit_data.cost_gold
	else:
		if _selected_units.size() >= _party_size:
			print("⚠️ Party is already full (", _party_size, " units).")
			_card_buttons[unit_data.id].button_pressed = false
			return
		if unit_data.cost_gold > _remaining_gold:
			print("⚠️ Not enough draft gold for ", unit_data.display_name, ".")
			_card_buttons[unit_data.id].button_pressed = false
			return
		_selected_units.append(unit_data)
		_remaining_gold -= unit_data.cost_gold

	_refresh_ui()


func _refresh_ui() -> void:
	gold_label.text = "Draft Gold: " + str(_remaining_gold)

	# Keep every card's pressed/disabled state in sync with selection + affordability.
	for unit_data in _available_units:
		var card: Button = _card_buttons[unit_data.id]
		var is_selected := unit_data in _selected_units
		card.button_pressed = is_selected
		if not is_selected:
			card.disabled = (_selected_units.size() >= _party_size) or (unit_data.cost_gold > _remaining_gold)
		else:
			card.disabled = false

	# Rebuild the 4 selected-party slot previews.
	for child in selected_party_container.get_children():
		child.queue_free()
	for i in range(_party_size):
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(100, 110)
		if i < _selected_units.size():
			var unit_data: UnitData = _selected_units[i]
			var vbox := VBoxContainer.new()
			var portrait_rect := TextureRect.new()
			portrait_rect.custom_minimum_size = Vector2(PORTRAIT_SIZE)
			portrait_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			portrait_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			portrait_rect.texture = UnitInfoPopup.texture_or_black_box(unit_data.portrait, PORTRAIT_SIZE)
			vbox.add_child(portrait_rect)
			var name_label := Label.new()
			name_label.text = unit_data.display_name
			name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			vbox.add_child(name_label)
			slot.add_child(vbox)
		else:
			var empty_label := Label.new()
			empty_label.text = "Empty"
			empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			slot.add_child(empty_label)
		selected_party_container.add_child(slot)

	confirm_button.disabled = (_selected_units.size() != _party_size)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(BACK_SCENE_PATH)


func _on_confirm_pressed() -> void:
	if _selected_units.size() != _party_size:
		return

	RunManager.start_new_run("normal")
	RunManager.current_run.draft_or_random_mode = "draft"
	# starting_gold (from draft.json) PLUS whatever draft budget is left
	# over -- per project decision, leftover draft gold becomes part of the
	# run's starting gold rather than being thrown away.
	RunManager.current_run.gold = int(_config.get("starting_gold", 10)) + _remaining_gold
	for equipment_id in _config.get("starting_equipment_ids", []):
		RunManager.current_run.equipment_inventory.append(equipment_id)

	for i in range(_selected_units.size()):
		var unit_data: UnitData = _selected_units[i]
		RunManager.current_run.party.append({
			"unit_id": unit_data.id,
			"instance_id": unit_data.id + "_" + str(Time.get_ticks_msec()) + "_" + str(i),
			"level": 1,
			"equipped_item_ids": [null, null, null],
			"permanent_modifiers": [],
		})

	get_tree().change_scene_to_file(TAROT_PICK_SCENE_PATH)
