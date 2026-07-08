# res://scripts/systems/shop_engine.gd
#
# AUTOLOAD. Make sure ContentLoader and RunManager are ABOVE it. Holds ALL
# the shop's decision-making: odds, rolling new slots, handling a purchase.
# shop_manager.gd (the scene script) just displays whatever this returns.

extends Node

const CONFIG_PATH = "res://content/shop/shop_config.json"
var _config: Dictionary = {}


func _ready() -> void:
	_reload_config()


func _reload_config() -> void:
	var loaded = ContentLoader.load_json(CONFIG_PATH, false)
	if loaded == null:
		printerr("❌ ShopEngine: could not load shop_config.json — using fallback defaults.")
		_config = {
			"slot_count": 3, "refresh_cost": 3, "max_generation_attempts_per_slot": 5,
			"category_weights": {"unit": 75, "consumable": 22.5, "equipment": 2.5},
			"rarity_weights": {"common": 97.5, "uncommon": 30, "rare": 15, "very_rare": 4, "legendary": 2.5}
		}
	else:
		_config = loaded


# ── PUBLIC: GET CURRENT SLOTS (resolved to real resources for display) ────────

func get_current_slots() -> Array:
	if RunManager.current_shop_slots.is_empty():
		generate_new_slots()

	var resolved: Array = []
	for entry in RunManager.current_shop_slots:
		resolved.append(_resolve_slot_entry(entry))
	return resolved


func _resolve_slot_entry(entry):
	if entry == null:
		return null
	match entry.get("category", ""):
		"unit":
			return ContentLoader.find_unit_by_id(entry["id"])
		"equipment", "consumable":
			return ContentLoader.find_equipment_by_id(entry["id"])
	return null


# ── GENERATING NEW SLOTS ────────────────────────────────────────────────────────

func generate_new_slots() -> void:
	var slot_count: int = _config.get("slot_count", 3)
	var new_slots: Array = []
	for i in range(slot_count):
		new_slots.append(_roll_one_slot())
	RunManager.current_shop_slots = new_slots


func _roll_one_slot() -> Variant:
	var max_attempts: int = _config.get("max_generation_attempts_per_slot", 5)
	for attempt in range(max_attempts):
		var category = _pick_weighted_category()
		var pool = _get_pool_for_category(category)
		if pool.is_empty():
			continue
		var item = _pick_weighted_item(pool)
		return {"category": category, "id": item.id}
	return null


func _pick_weighted_category() -> String:
	var weights: Dictionary = _config.get("category_weights", {})
	var total = 0.0
	for w in weights.values():
		total += w
	var roll = randf() * total
	var running = 0.0
	for category in weights:
		running += weights[category]
		if roll <= running:
			return category
	return weights.keys()[0]


func _get_pool_for_category(category: String) -> Array:
	match category:
		"unit":
			return ContentLoader.load_all_resources_in_folder("res://resources/units/", "UnitData")
		"equipment":
			return ContentLoader.load_all_resources_in_folder("res://content/equipment/basic/", "BasicEquipmentData")
		"consumable":
			return ContentLoader.load_all_resources_in_folder("res://content/equipment/consumables/", "ConsumableData")
	return []


func _pick_weighted_item(pool: Array):
	var rarity_weights: Dictionary = _config.get("rarity_weights", {})
	var total = 0.0
	var weights_by_item: Array = []
	for item in pool:
		var w: float
		if "shop_weight_override" in item and item.shop_weight_override >= 0.0:
			w = item.shop_weight_override
		else:
			w = rarity_weights.get(item.get("rarity") if item.has_method("get") else item.rarity, 1.0)
		# TAROT HOOK: multiplies by any active drop-rate tarot cards (e.g.
		# The Star boosting rare items, The Hermit boosting Isolation-tagged
		# units). Returns 1.0 if nothing relevant is owned.
		w *= TarotSystem.get_shop_weight_multiplier(item)
		# ENCOUNTER-EFFECT HOOK: multiplies by any temporary "modify_drop_rate"
		# effects granted by encounters (auto-cleared on advance_stage()).
		w *= RunManager.get_drop_rate_modifier(item)
		weights_by_item.append(w)
		total += w

	var roll = randf() * total
	var running = 0.0
	for i in range(pool.size()):
		running += weights_by_item[i]
		if roll <= running:
			return pool[i]
	return pool[pool.size() - 1]


# ── PRICING ──────────────────────────────────────────────────────────────────

func get_price(item) -> int:
	if item is UnitData:
		return item.cost_gold
	if "shop_price" in item:
		return item.shop_price
	return 0


func get_refresh_cost() -> int:
	# TAROT HOOK: cards like The Miser can add a temporary surcharge.
	return _config.get("refresh_cost", 3) + TarotSystem.get_refresh_cost_modifier()


# ── ICONS (with gray-box placeholder fallback) ────────────────────────────────

var _placeholder_icon_cache: ImageTexture = null

func get_display_icon(item) -> Texture2D:
	if item is UnitData and item.portrait != null:
		return item.portrait
	if "icon" in item and item.icon != null:
		return item.icon
	if _placeholder_icon_cache == null:
		var img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.4, 0.4, 0.4))
		_placeholder_icon_cache = ImageTexture.create_from_image(img)
	return _placeholder_icon_cache


func get_display_name(item) -> String:
	return item.display_name if "display_name" in item else "???"


# ── PURCHASING ─────────────────────────────────────────────────────────────────

func purchase_slot(slot_index: int) -> Dictionary:
	if slot_index < 0 or slot_index >= RunManager.current_shop_slots.size():
		return {"success": false, "message": "Invalid slot."}

	var entry = RunManager.current_shop_slots[slot_index]
	if entry == null:
		return {"success": false, "message": "This slot is already sold."}

	var item = _resolve_slot_entry(entry)
	if item == null:
		return {"success": false, "message": "Item data missing."}

	var price = get_price(item)
	if not RunManager.spend_gold(price):
		return {"success": false, "message": "Not enough gold."}

	if item is UnitData:
		if RunManager.current_run.party.size() < 4:
			RunManager.current_run.party.append(item)
		elif RunManager.current_run.bench.size() < 6:
			RunManager.current_run.bench.append(item)
		else:
			RunManager.add_gold(price)
			return {"success": false, "message": "Party and bench are both full."}
	else:
		RunManager.current_run.inventory.append(item)

	RunManager.current_shop_slots[slot_index] = null
	RunManager.save_run()
	return {"success": true, "message": "Purchased " + get_display_name(item) + "."}


func refresh_shop() -> Dictionary:
	var cost = get_refresh_cost()
	if not RunManager.spend_gold(cost):
		return {"success": false, "message": "Not enough gold to refresh."}
	generate_new_slots()
	RunManager.save_run()
	return {"success": true, "message": "Shop refreshed."}
