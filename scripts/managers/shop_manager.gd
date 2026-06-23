# res://scripts/engines/shop_engine.gd
#
# SHOP ENGINE -- generates a randomized shop offer for the player between
# stages, respecting spawn weights, tarot-driven drop-rate modifiers, and
# price modifiers. THIS IS WHAT SHOULD REPLACE THE CURRENT shop_manager.gd
# (which currently contains a misplaced copy of the combat ability_executor
# code and does nothing shop-related at all).

extends Node

const BASE_SHOP_SLOTS: int = 3
const MAX_SHOP_SLOTS: int = 5


func generate_shop(run_state: RunState) -> Array:
	var slot_count: int = clamp(BASE_SHOP_SLOTS + run_state.shop_slot_modifier, 1, MAX_SHOP_SLOTS)
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

	run_state.shop_inventory = offer
	EventBus.publish(EventBus.ON_SHOP_OPEN, {"offer": offer})
	return offer


func purchase(shop_entry_id: String, run_state: RunState) -> bool:
	var entry := ContentLoader.get_shop_entry(shop_entry_id)
	if entry.is_empty():
		return false
	var price := _final_price(entry, run_state)
	if run_state.gold < price:
		return false
	run_state.gold -= price

	var context := {"run_state": run_state, "source": "shop:" + shop_entry_id}
	match entry.get("item_type", "equipment"):
		"equipment":
			EffectSystem.apply_effect({"type": "add_equipment", "equipment_id": entry.get("item_id", "")}, context)
		"unit":
			EffectSystem.apply_effect({"type": "add_unit", "unit_id": entry.get("item_id", "")}, context)
		"consumable":
			run_state.equipment_inventory.append(entry.get("item_id", ""))

	# Remove this entry from the current offer so it can't be bought twice
	# from the same shop visit.
	for i in range(run_state.shop_inventory.size()):
		if run_state.shop_inventory[i].get("shop_entry_id", "") == shop_entry_id:
			run_state.shop_inventory.remove_at(i)
			break
	return true


func _get_valid_entries(run_state: RunState) -> Array:
	var result := []
	for id in ContentLoader.shop_entries:
		var entry = ContentLoader.shop_entries[id]
		if EffectSystem.evaluate_conditions(entry.get("conditions", []), {"run_state": run_state}):
			result.append(entry)
	return result


func _weighted_chance(entry: Dictionary, run_state: RunState) -> float:
	# NOTE: rarity/spawn_weight live on the equipment/unit definition itself
	# via ContentLoader.get_equipment()/etc -- shop_entry.spawn_weight is a
	# per-SLOT override on top of that base weight, not a duplicate source
	# of truth for "how rare is this item overall".
	var weight: float = float(entry.get("spawn_weight", 1.0))
	for modifier in run_state.drop_rate_modifiers:
		var resource: String = modifier.get("resource", "")
		if resource == entry.get("item_id", "") or entry.get("tags", []).has(resource):
			weight *= float(modifier.get("multiplier", 1.0))
	return weight


func _final_price(entry: Dictionary, run_state: RunState) -> int:
	var price: float = float(entry.get("base_price", 0))
	for modifier in run_state.shop_price_modifiers:
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
