# res://scripts/managers/shop_manager.gd
#
# REPLACES the current file at this path, which (per shop_engine.gd's own
# header comment) currently contains a misplaced copy of ability_executor.gd
# and does nothing shop-related. Attach to the ROOT node of ShopScene.tscn.
#
# Pure display layer -- all actual shop logic (odds, pricing, drop-rate
# modifiers) lives in the ShopEngine autoload. This script only builds the
# cards and reacts to button presses.
#
# Expected node tree -- see the README for the full step-by-step walkthrough:
#   ShopScene (Node2D)
#     Background (TextureRect)         <- just assign a texture in the Inspector, no script involvement
#     GoldLabel (Label)
#     HBoxContainer (HBoxContainer)    <- shop item cards built here at runtime
#     RefreshButton (Button)
#     ContinueButton (Button)
#     EquipPanel (VBoxContainer)
#       RosterScroll (ScrollContainer)
#         RosterList (VBoxContainer)   <- one row per party/bench unit, built at runtime
#       SelectedUnitLabel (Label)
#       SlotsContainer (HBoxContainer) <- 3 equip-slot buttons, built at runtime
#       InventoryScroll (ScrollContainer)
#         InventoryList (VBoxContainer) <- one row per unequipped item, built at runtime

extends Node2D

const MAX_EQUIP_SLOTS := 3
# Not enforced anywhere else in the backend (RunState.party's
# equipped_item_ids is just a plain Array with no size cap) -- this is a
# UI-level constraint matching the original 3-slots-per-unit design. Raise
# it here if you want more/fewer slots; nothing else needs to change.

@onready var gold_label: Label = $GoldLabel
@onready var slot_container: HBoxContainer = $HBoxContainer
@onready var refresh_button: Button = $RefreshButton
@onready var continue_button: Button = $ContinueButton

@onready var roster_list: VBoxContainer = $EquipPanel/RosterScroll/RosterList
@onready var selected_unit_label: Label = $EquipPanel/SelectedUnitLabel
@onready var slots_container: HBoxContainer = $EquipPanel/SlotsContainer
@onready var inventory_list: VBoxContainer = $EquipPanel/InventoryScroll/InventoryList

var _slot_panels: Array = []
var _placeholder_icon: ImageTexture = null

var _selected_party_index: int = -1          # index into a combined party+bench list, or -1
var _selected_inventory_item_id: String = ""  # currently-picked-up inventory item, or ""


func _ready() -> void:
	refresh_button.pressed.connect(_on_refresh_pressed)
	continue_button.pressed.connect(_on_continue_pressed)

	if RunManager.current_run == null:
		printerr("❌ ShopScene: RunManager.current_run is null.")
		return

	if RunManager.current_run.shop_inventory.is_empty():
		ShopEngine.generate_shop(RunManager.current_run)

	_refresh_display()


func _refresh_display() -> void:
	_update_gold_label()
	_rebuild_slots()
	_rebuild_roster()
	_rebuild_equip_slots()
	_rebuild_inventory()


func _update_gold_label() -> void:
	gold_label.text = "Gold: %d" % RunManager.current_run.gold


func _rebuild_slots() -> void:
	for panel in _slot_panels:
		panel.queue_free()
	_slot_panels.clear()

	for offer_entry in RunManager.current_run.shop_inventory:
		var panel := _build_slot_panel(offer_entry)
		slot_container.add_child(panel)
		_slot_panels.append(panel)


func _build_slot_panel(offer_entry: Dictionary) -> Control:
	var shop_entry_id: String = offer_entry.get("shop_entry_id", "")
	var final_price: int = offer_entry.get("final_price", 0)
	var entry: Dictionary = ContentLoader.get_shop_entry(shop_entry_id)

	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	panel.add_child(vbox)
	panel.custom_minimum_size = Vector2(140, 180)

	var icon_rect := TextureRect.new()
	icon_rect.custom_minimum_size = Vector2(64, 150)
	icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon_rect.texture = _get_display_icon(entry)
	vbox.add_child(icon_rect)

	var name_label := Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.text = _get_display_name(entry)
	vbox.add_child(name_label)

	var price_label := Label.new()
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_label.text = "%d gold" % final_price
	vbox.add_child(price_label)

	var buy_button := Button.new()
	buy_button.text = "Buy"
	buy_button.pressed.connect(func(): _on_buy_pressed(shop_entry_id))
	vbox.add_child(buy_button)

	# ADDED: "More Info" on every card -- units, equipment, and consumables
	# alike -- so the player can see what they'd actually be buying before
	# spending gold on it.
	var more_info_button := Button.new()
	more_info_button.text = "More Info"
	more_info_button.pressed.connect(func(): _on_shop_more_info_pressed(entry))
	vbox.add_child(more_info_button)

	return panel


# ── MORE INFORMATION POPUP ────────────────────────────────────────────────────
# Same idea as deployment_manager.gd's Info button and battle's in-combat
# "Information" button: reuse UnitInfoPopup rather than building a third
# custom info panel. Units get the full character-sheet popup (level-1 base
# numbers, no equipped items yet -- same convention the Draft screen uses,
# since a unit sitting in the shop isn't equipped or leveled yet either).
# Equipment/consumables get the smaller item-preview popup, matching
# deployment_manager.gd's forge-preview popup.

func _on_shop_more_info_pressed(entry: Dictionary) -> void:
	var item_type: String = entry.get("item_type", "")
	var item_id: String = entry.get("item_id", "")
	if item_type == "unit":
		_show_shop_unit_info_popup(item_id)
	else:
		_show_shop_item_info_popup(item_id)


func _show_shop_unit_info_popup(unit_id: String) -> void:
	var unit_data := _load_unit_data(unit_id)
	if unit_data == null or unit_data.stats_by_level.is_empty():
		return
	var stats: StatsData = unit_data.stats_by_level[0]   # level-1 base numbers, same as the Draft screen.
	var stat_lines: Array[String] = [
		"HP: %d" % stats.hp,
		"Mana: %d" % stats.mana,
		"ATK: %d" % stats.atk,
		"MATK: %d" % stats.matk,
		"DEF: %d" % stats.def,
		"MDEF: %d" % stats.mdef,
		"Crit %%: %.0f%%" % stats.crit_chance,
		"Crit DMG: %.0f%%" % stats.crit_damage,
		"MOV: %d" % stats.mov,
	]
	var popup_instance := UnitInfoPopup.new()
	add_child(popup_instance)
	popup_instance.setup(unit_data, stat_lines, [])


func _show_shop_item_info_popup(item_id: String) -> void:
	var data: Dictionary = ContentLoader.get_equipment(item_id)

	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(280, 0)
	margin.add_child(vbox)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var icon_rect := TextureRect.new()
	icon_rect.custom_minimum_size = Vector2(48, 48)
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.texture = UnitInfoPopup.texture_or_black_box(
		UnitInfoPopup._resolve_icon(data.get("icon")), Vector2i(48, 48))
	header.add_child(icon_rect)

	var name_label := Label.new()
	name_label.text = data.get("name", item_id)
	name_label.add_theme_font_size_override("font_size", 20)
	header.add_child(name_label)

	var effect_lines: Array[String] = []
	for effect in data.get("effects", []):
		var described: String = UnitInfoPopup._describe_effect(effect)
		if described != "":
			effect_lines.append(described)
	if not effect_lines.is_empty():
		var stats_label := Label.new()
		stats_label.text = ", ".join(effect_lines)
		stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(stats_label)

	var description: String = data.get("description", "")
	if description != "":
		var desc_label := Label.new()
		desc_label.text = description
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(desc_label)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(close_btn)

	popup.popup_centered(Vector2(320, 220))


func _get_display_name(entry: Dictionary) -> String:
	var item_type: String = entry.get("item_type", "")
	var item_id: String = entry.get("item_id", "")
	if item_type == "unit":
		var unit_data = _load_unit_data(item_id)
		return unit_data.display_name if unit_data != null and "display_name" in unit_data else item_id
	# Both "equipment" and "consumable" items are stored in ContentLoader's
	# equipment dictionary (content/equipment/*.json) in this project.
	# NOTE: equipment JSON uses "name", not "display_name" (UnitData .tres
	# resources use "display_name" -- these are two different content
	# systems with two different field names for the same concept).
	var content: Dictionary = ContentLoader.get_equipment(item_id)
	return content.get("name", item_id)


func _get_display_icon(entry: Dictionary) -> Texture2D:
	var item_type: String = entry.get("item_type", "")
	var item_id: String = entry.get("item_id", "")
	var icon_path: String = ""

	if item_type == "unit":
		var unit_data = _load_unit_data(item_id)
		if unit_data != null and "portrait" in unit_data and unit_data.portrait != null:
			return unit_data.portrait
	else:
		var content: Dictionary = ContentLoader.get_equipment(item_id)
		icon_path = content.get("icon", "")

	if icon_path != "" and ResourceLoader.exists(icon_path):
		return load(icon_path)

	if _placeholder_icon == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.4, 0.4, 0.4))
		_placeholder_icon = ImageTexture.create_from_image(img)
	return _placeholder_icon


func _load_unit_data(unit_id: String) -> UnitData:
	var path := "res://resources/units/" + unit_id + "_data.tres"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as UnitData


func _on_buy_pressed(shop_entry_id: String) -> void:
	var success := ShopEngine.purchase(shop_entry_id, RunManager.current_run)
	if not success:
		print("⛔ Purchase failed (not enough gold, or entry already sold).")
	RunManager.save_run()
	_refresh_display()


func _on_refresh_pressed() -> void:
	var success := ShopEngine.refresh_shop(RunManager.current_run)
	if not success:
		print("⛔ Not enough gold to refresh.")
	RunManager.save_run()
	_refresh_display()


func _on_continue_pressed() -> void:
	get_tree().change_scene_to_file(StageDirector.DEPLOYMENT_SCENE_PATH)


# ══════════════════════════════════════════════════════════════════════════
# EQUIP MANAGEMENT
#
# A party/bench entry is a plain Dictionary (see run_state.gd):
#   { "unit_id": String, "instance_id": String, "level": int,
#     "equipped_item_ids": Array, "permanent_modifiers": Array }
# Equipping/unequipping just means editing that SAME dictionary's
# equipped_item_ids array in place (Dictionaries are passed by reference in
# GDScript, so mutating the entry you got from _get_full_roster() mutates
# the actual entry sitting inside RunManager.current_run.party/bench).
# Nothing needs to be "written back" separately.
# ══════════════════════════════════════════════════════════════════════════

func _get_full_roster() -> Array:
	var roster: Array = []
	roster.append_array(RunManager.current_run.party)
	roster.append_array(RunManager.current_run.bench)
	return roster


func _rebuild_roster() -> void:
	for child in roster_list.get_children():
		child.queue_free()

	var roster := _get_full_roster()
	for i in range(roster.size()):
		var entry: Dictionary = roster[i]
		var btn := Button.new()
		var unit_data := _load_unit_data(entry.get("unit_id", ""))
		var label : String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")
		btn.text = ("▶ " if i == _selected_party_index else "") + label + " (Lv " + str(entry.get("level", 1)) + ")"
		btn.pressed.connect(func(): _on_roster_entry_pressed(i))
		roster_list.add_child(btn)


func _on_roster_entry_pressed(index: int) -> void:
	_selected_party_index = index
	_rebuild_roster()
	_rebuild_equip_slots()


func _get_selected_entry() -> Dictionary:
	var roster := _get_full_roster()
	if _selected_party_index < 0 or _selected_party_index >= roster.size():
		return {}
	return roster[_selected_party_index]


func _rebuild_equip_slots() -> void:
	for child in slots_container.get_children():
		child.queue_free()

	var entry := _get_selected_entry()
	if entry.is_empty():
		selected_unit_label.text = "Select a unit above to manage equipment."
		return

	var unit_data := _load_unit_data(entry.get("unit_id", ""))
	selected_unit_label.text = "Equipping: " + (unit_data.display_name if unit_data != null else entry.get("unit_id", "?"))

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	for i in range(MAX_EQUIP_SLOTS):
		var item_id = equipped[i]
		var btn := Button.new()
		if item_id == null or item_id == "":
			btn.text = "Empty Slot %d" % (i + 1)
		else:
			btn.text = ContentLoader.get_equipment(item_id).get("name", item_id)
		btn.pressed.connect(func(): _on_equip_slot_pressed(i))
		slots_container.add_child(btn)


func _on_equip_slot_pressed(slot_index: int) -> void:
	var entry := _get_selected_entry()
	if entry.is_empty():
		return

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	if _selected_inventory_item_id != "":
		# Equipping: put the picked-up inventory item into this slot,
		# returning whatever was already there back to the inventory.
		var old_item = equipped[slot_index]
		equipped[slot_index] = _selected_inventory_item_id
		RunManager.current_run.equipment_inventory.erase(_selected_inventory_item_id)
		if old_item != null and old_item != "":
			RunManager.current_run.equipment_inventory.append(old_item)
		_selected_inventory_item_id = ""
	else:
		# No item picked up -- treat this as "unequip": send it back to the bag.
		if equipped[slot_index] != null and equipped[slot_index] != "":
			RunManager.current_run.equipment_inventory.append(equipped[slot_index])
			equipped[slot_index] = null

	entry["equipped_item_ids"] = equipped
	RunManager.save_run()
	_rebuild_equip_slots()
	_rebuild_inventory()


func _rebuild_inventory() -> void:
	for child in inventory_list.get_children():
		child.queue_free()
	# BUGFIX: this used to loop over equipment_inventory a SECOND time right
	# after the first loop, adding every single item again -- including
	# consumables, which the first loop had specifically just excluded. That
	# meant every owned item appeared twice in this list (three times for
	# consumables' non-skip copy, effectively), each copy acting as its own
	# fully-functional (but redundant/confusing) selectable button. The
	# second loop added nothing the first one didn't already do correctly,
	# so it's just removed.
	for item_id in RunManager.current_run.equipment_inventory:
		if ContentLoader.get_equipment(item_id).get("type", "") == "consumable":
			continue   # consumables live in the combat item bar, not the equip screen

		# ADDED: an "Info" button next to each row, matching deployment_
		# manager.gd's equip panel.
		var row := HBoxContainer.new()

		var btn := Button.new()
		var prefix := "[Selected] " if item_id == _selected_inventory_item_id else ""
		btn.text = prefix + ContentLoader.get_equipment(item_id).get("name", item_id)
		btn.pressed.connect(func(): _on_inventory_item_pressed(item_id))
		row.add_child(btn)

		var info_btn := Button.new()
		info_btn.text = "Info"
		info_btn.pressed.connect(func(): _show_shop_item_info_popup(item_id))
		row.add_child(info_btn)

		inventory_list.add_child(row)


func _on_inventory_item_pressed(item_id: String) -> void:
	# Clicking the same item again deselects it; clicking a different one
	# switches the selection. Then click an equip slot above to place it.
	_selected_inventory_item_id = "" if _selected_inventory_item_id == item_id else item_id
	_rebuild_inventory()
