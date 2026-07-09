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
# Expected node tree:
#   ShopScene (Node2D)
#     GoldLabel (Label)
#     HBoxContainer (HBoxContainer)   <- item cards built here at runtime
#     RefreshButton (Button)
#     ContinueButton (Button)

extends Node2D

@onready var gold_label: Label = $GoldLabel
@onready var slot_container: HBoxContainer = $HBoxContainer
@onready var refresh_button: Button = $RefreshButton
@onready var continue_button: Button = $ContinueButton

var _slot_panels: Array = []
var _placeholder_icon: ImageTexture = null


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
	icon_rect.custom_minimum_size = Vector2(64, 64)
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

	return panel


func _get_display_name(entry: Dictionary) -> String:
	var item_type: String = entry.get("item_type", "")
	var item_id: String = entry.get("item_id", "")
	if item_type == "unit":
		var unit_data = _load_unit_data(item_id)
		return unit_data.display_name if unit_data != null and "display_name" in unit_data else item_id
	# Both "equipment" and "consumable" items are stored in ContentLoader's
	# equipment dictionary (content/equipment/*.json) in this project.
	var content: Dictionary = ContentLoader.get_equipment(item_id)
	return content.get("display_name", item_id)


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
	StageDirector.enter_current_stage()
