# res://scripts/engines/equipment_runtime.gd
#
# EQUIPMENT RUNTIME -- bridges the META layer (a unit's saved
# equipped_item_ids in RunState) and the COMBAT layer (a live UnitNode on
# the battlefield).
#
# WHAT HAPPENS, STEP BY STEP, WHEN A UNIT IS SPAWNED INTO A BATTLE:
#   1. Look up each equipped item's JSON data via ContentLoader.
#   2. Apply every plain stat-boosting effect (the "add_stat" entries) by
#      writing into the unit's EXISTING `momentum_bonuses` dictionary.
#
#      NOTE FOR BEGINNERS: unit_node.gd's get_effective_atk() / get_effective_def()
#      / etc. already loop over EVERY key inside momentum_bonuses and add up
#      whatever "atk"/"def"/etc. numbers they find there. That loop doesn't
#      care whether the key came from a Momentum aura or from a piece of
#      equipment! We reuse that exact mechanism with our own key names
#      (prefixed "equip_") so equipment bonuses show up automatically with
#      ZERO changes needed to unit_node.gd.
#   3. For any effect of type "custom", hand off to CustomEquipmentHandlers
#      so it can register whatever CombatHooks it needs (see that file).
#
# WIRING NOTE: call apply_equipment_to_unit() once, right after
# unit.setup(...) inside battle_manager.gd's spawn_unit() -- see the
# checklist at the bottom of combat_hooks.gd.

extends Node

func apply_equipment_to_unit(unit, equipped_item_ids: Array) -> void:
	for item_id in equipped_item_ids:
		if item_id == null or item_id == "":
			continue
		var item_data: Dictionary = ContentLoader.get_equipment(item_id)
		if item_data.is_empty():
			push_warning("EquipmentRuntime: equipped item '" + str(item_id) + "' not found.")
			continue

		var bonus_key: String = "equip_" + item_id
		var flat_bonus := {"atk": 0, "matk": 0, "def": 0, "mdef": 0, "mov": 0, "crit_chance": 0.0, "crit_damage": 0.0}
		var any_flat_bonus := false

		for effect in item_data.get("effects", []):
			if effect.get("type", "") != "add_stat" or effect.get("scope", "permanent") != "permanent":
				continue
			var stat: String = effect.get("stat", "")
			var amount = effect.get("amount", 0)
			var value_mode: String = effect.get("value_mode", "flat")
			if value_mode == "percent":
				# Percent stat bonuses (e.g. "+10% mana") apply directly
				# against the unit's current pool rather than the flat dict.
				_apply_percent_bonus(unit, stat, amount)
			elif flat_bonus.has(stat):
				flat_bonus[stat] += amount
				any_flat_bonus = true

		if any_flat_bonus:
			unit.momentum_bonuses[bonus_key] = flat_bonus

		for effect in item_data.get("effects", []):
			if effect.get("type", "") == "custom":
				var custom_id: String = effect.get("custom_id", "")
				if CustomEquipmentHandlers.has_handler(custom_id):
					CustomEquipmentHandlers.on_equip(custom_id, unit)
				else:
					push_warning("EquipmentRuntime: no custom handler for '" + custom_id + "' (item '" + item_id + "')")


func remove_equipment_from_unit(unit, equipped_item_ids: Array) -> void:
	# Call this when a unit leaves combat, so custom handlers can unsubscribe
	# their CombatHooks callbacks cleanly instead of leaking them.
	for item_id in equipped_item_ids:
		if item_id == null or item_id == "":
			continue
		unit.momentum_bonuses.erase("equip_" + item_id)
		var item_data: Dictionary = ContentLoader.get_equipment(item_id)
		for effect in item_data.get("effects", []):
			if effect.get("type", "") == "custom":
				var custom_id: String = effect.get("custom_id", "")
				if CustomEquipmentHandlers.has_handler(custom_id):
					CustomEquipmentHandlers.on_unequip(custom_id, unit)


func apply_permanent_modifiers_to_unit(unit, permanent_modifiers: Array) -> void:
	# Applies a unit's permanent_modifiers (built up over the run by tarot
	# cards, encounter rewards, "+1 ATK per level" effects, etc -- see the
	# "permanent_modifiers" field on RunState.party entries) to a freshly
	# spawned live UnitNode. Uses the exact same momentum_bonuses reuse
	# trick as equipment (see the big comment at the top of this file) --
	# call this alongside apply_equipment_to_unit(), right after unit.setup().
	var flat_bonus := {"atk": 0, "matk": 0, "def": 0, "mdef": 0, "mov": 0, "crit_chance": 0.0, "crit_damage": 0.0}
	var any_flat := false
	for mod in permanent_modifiers:
		var stat: String = mod.get("stat", "")
		var amount = mod.get("amount", 0)
		var value_mode: String = mod.get("value_mode", "flat")
		if value_mode == "percent":
			match stat:
				"hp":   unit.current_hp += int(unit.get_stats().hp * (amount / 100.0))
				"mana": unit.current_mana += int(unit.get_stats().mana * (amount / 100.0))
				_: push_warning("EquipmentRuntime: percent permanent_modifier not supported for stat '" + stat + "'")
		elif flat_bonus.has(stat):
			flat_bonus[stat] += amount
			any_flat = true
	if any_flat:
		unit.momentum_bonuses["run_permanent_modifiers"] = flat_bonus


func _apply_percent_bonus(unit, stat: String, percent_amount: float) -> void:
	# Percent bonuses to mana/HP are applied as a one-time bump to the
	# unit's CURRENT pool at the moment they're spawned in. (If you want
	# this to scale dynamically as the unit levels up mid-run instead, move
	# this logic into get_stats() -- left simple here on purpose.)
	match stat:
		"mana":
			unit.current_mana += int(unit.get_stats().mana * (percent_amount / 100.0))
		"hp":
			unit.current_hp += int(unit.get_stats().hp * (percent_amount / 100.0))
		"crit_chance", "crit_damage":
			unit.momentum_bonuses["equip_percent_" + stat] = {stat: percent_amount}
		_:
			push_warning("EquipmentRuntime: percent value_mode not supported for stat '" + stat + "'")
