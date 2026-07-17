# res://scripts/engines/shop_engine.gd
#
# SHOP ENGINE -- generates a randomized shop offer for the player between
# stages, respecting spawn weights, tarot-driven drop-rate modifiers, and
# price modifiers. THIS IS WHAT SHOULD REPLACE THE CURRENT shop_manager.gd
# (which currently contains a misplaced copy of the combat ability_executor
# code and does nothing shop-related at all).
#
# HOW "resource" MATCHING WORKS (this is the answer to "how do I make sure
# I'm affecting basic equipment drop rates"):
#   A modify_drop_rate effect's "resource" string is checked against EVERY
#   one of these, for each shop entry, and applies if ANY of them match:
#     - the exact item id                      e.g. "blade"
#     - the item_type                          "equipment" | "unit" | "consumable"
#     - (equipment only) its own "type" field   "basic" | "advanced"
#     - (equipment only) its own "subtype"      "blade", "armor", "blade_armor", ...
#     - (equipment only) its own "tags" array   ["forgeable","melee"], etc.
#     - (unit only) the unit's synergy_tags     ["Overkill","Critical"], etc.
#     - the shop_entry's OWN "tags" array (a per-slot override, separate
#       from the underlying item's tags)
#   PLUS one special dynamic keyword, "owned_units", which is true whenever
#   the player already has at least one copy of that unit (used by cards
#   like "The Wheel").
#
#   So: { "type": "modify_drop_rate", "resource": "basic", "multiplier": 1.3 }
#   boosts EVERY basic equipment item, with zero JSON content changes needed,
#   because every basic equipment file already has "type": "basic".

extends Node

const BASE_SHOP_SLOTS: int = 5
const MAX_SHOP_SLOTS: int = 7
const REFRESH_BASE_COST: int = 3


func generate_shop(run_state: RunState) -> Array:
	var slot_count: int = clamp(BASE_SHOP_SLOTS + run_state.shop_slot_modifier, 1, MAX_SHOP_SLOTS)
	var offer := _roll_offer(slot_count, run_state)
	run_state.shop_inventory = offer
	EventBus.publish(EventBus.ON_SHOP_OPEN, {"offer": offer})
	return offer


func refresh_shop(run_state: RunState) -> bool:
	# Pays gold to reroll the current offer. Price modifiers with
	# resource=="shop_refresh" apply here (see The Miser's example card).
	var cost := _final_price({"base_price": REFRESH_BASE_COST, "item_type": "shop_refresh"}, run_state)
	if run_state.gold < cost:
		return false
	run_state.gold -= cost
	generate_shop(run_state)
	return true


func _roll_offer(slot_count: int, run_state: RunState) -> Array:
	var offer := []
	var pool := _get_valid_entries(run_state)
	for i in range(slot_count):
		if pool.is_empty():
			break
		var weights := []
		for entry in pool:
			weights.append(_weighted_chance(entry, run_state))
		var picked_entry = pool[_weighted_pick(weights)]
		offer.append({
			"shop_entry_id": picked_entry.get("id", ""),
			"final_price": _final_price(picked_entry, run_state),
		})
	return offer


func purchase(shop_entry_id: String, run_state: RunState) -> bool:
	var entry := ContentLoader.get_shop_entry(shop_entry_id)
	if entry.is_empty():
		return false
	var price := _final_price(entry, run_state)
	if run_state.gold < price:
		return false
	run_state.gold -= price

	var item_type: String = entry.get("item_type", "equipment")
	var item_id: String = entry.get("item_id", "")
	# Checked BEFORE the purchase mutates state, so "The Wheel"-style
	# duplicate-bonus triggers can tell a duplicate apart from a first copy.
	var was_duplicate := item_type == "unit" and _player_already_owns_unit(item_id, run_state)

	var context := {"run_state": run_state, "source": "shop:" + shop_entry_id}
	match item_type:
		"equipment":
			EffectSystem.apply_effect({"type": "add_equipment", "equipment_id": item_id}, context)
		"unit":
			EffectSystem.apply_effect({"type": "add_unit", "unit_id": item_id}, context)
		"consumable":
			run_state.equipment_inventory.append(item_id)

	for i in range(run_state.shop_inventory.size()):
		if run_state.shop_inventory[i].get("shop_entry_id", "") == shop_entry_id:
			run_state.shop_inventory.remove_at(i)
			break

	EventBus.publish(EventBus.ON_SHOP_PURCHASE, {
		"item_type": item_type, "item_id": item_id,
		"is_unit_purchase": item_type == "unit",
		"was_duplicate": was_duplicate,
	})
	return true


func _get_valid_entries(run_state: RunState) -> Array:
	var result := []
	for id in ContentLoader.shop_entries:
		var entry = ContentLoader.shop_entries[id]
		if EffectSystem.evaluate_conditions(entry.get("conditions", []), {"run_state": run_state}):
			result.append(entry)
	return result

# ---- DROP RATE / "resource" MATCHING ------------------------------------------

func _weighted_chance(entry: Dictionary, run_state: RunState) -> float:
	var weight: float = float(entry.get("spawn_weight", 1.0))
	var match_set := _build_match_set(entry)
	for modifier in run_state.drop_rate_modifiers:
		if not EffectSystem.evaluate_conditions(modifier.get("active_while", []), {"run_state": run_state}):
			continue
		var resource: String = modifier.get("resource", "")
		var applies: bool = match_set.has(resource)
		if resource == "owned_units" and entry.get("item_type", "") == "unit":
			applies = _player_already_owns_unit(entry.get("item_id", ""), run_state)
		if applies:
			weight *= float(modifier.get("multiplier", 1.0))
	return max(0.0, weight)


func _build_match_set(entry: Dictionary) -> Array:
	# Every string a modify_drop_rate "resource" can match against for this
	# shop entry -- see the big comment block at the top of this file.
	var tags := [entry.get("item_id", ""), entry.get("item_type", "")]
	for t in entry.get("tags", []):
		tags.append(t)

	match entry.get("item_type", ""):
		"equipment":
			var eq := ContentLoader.get_equipment(entry.get("item_id", ""))
			if not eq.is_empty():
				tags.append(eq.get("type", ""))      # "basic" | "advanced"
				tags.append(eq.get("subtype", ""))
				for t in eq.get("tags", []):
					tags.append(t)
		"unit":
			for t in _load_unit_synergy_tags(entry.get("item_id", "")):
				tags.append(t)
	return tags


func _load_unit_synergy_tags(unit_id: String) -> Array:
	# UnitData lives as a combat-side .tres Resource, not JSON content, so
	# we load it directly using the same path convention battle_manager.gd
	# already uses ("res://resources/units/<unit_id>_data.tres"). If your
	# project's unit resources live somewhere else, update this one path.
	var path := "res://resources/units/" + unit_id + "_data.tres"
	if not ResourceLoader.exists(path):
		return []
	var unit_data = load(path)
	if unit_data != null and "synergy_tags" in unit_data:
		return unit_data.synergy_tags
	return []


func _player_already_owns_unit(unit_id: String, run_state: RunState) -> bool:
	for entry in run_state.party:
		if entry.get("unit_id", "") == unit_id:
			return true
	for entry in run_state.bench:
		if entry.get("unit_id", "") == unit_id:
			return true
	return false

# ---- PRICING -------------------------------------------------------------------

func _final_price(entry: Dictionary, run_state: RunState) -> int:
	var price: float = float(entry.get("base_price", 0))
	if entry.get("item_type", "") == "unit":
		var rarity_price := _get_unit_rarity_price(entry.get("item_id", ""))
		if rarity_price > 0:
			price = float(rarity_price)   # rarity-derived price wins over the JSON's base_price
	for modifier in run_state.shop_price_modifiers:
		if not EffectSystem.evaluate_conditions(modifier.get("active_while", []), {"run_state": run_state}):
			continue
		var resource: String = modifier.get("resource", "all")
		if resource == "all" or resource == entry.get("item_type", ""):
			price *= float(modifier.get("multiplier", 1.0))
			price += float(modifier.get("amount", 0))
	return int(round(price))


func _weighted_pick(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return randi() % weights.size()
	var roll := randf() * total
	var cumulative := 0.0
	for i in range(weights.size()):
		cumulative += weights[i]
		if roll <= cumulative:
			return i
	return weights.size() - 1


const UNIT_PRICE_BY_RARITY: Dictionary = {
	"common":   3,
	"uncommon": 5,
	"rare":     7,
}

func _get_unit_rarity_price(unit_id: String) -> int:
	var path := "res://resources/units/" + unit_id + "_data.tres"
	if not ResourceLoader.exists(path):
		push_warning("ShopEngine: no UnitData found for '" + unit_id + "' at " + path +
			" -- falling back to this shop entry's own base_price.")
		return 0
	var unit_data: UnitData = load(path) as UnitData
	if unit_data == null:
		return 0
	return UNIT_PRICE_BY_RARITY.get(unit_data.rarity, 0)
