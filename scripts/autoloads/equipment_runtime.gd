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
		# "hp"/"mana" added here too now — flat (non-percent) HP/mana
		# bonuses used to be silently dropped, since this dict had no key
		# for them to land in at all.
		var flat_bonus := {"atk": 0, "matk": 0, "def": 0, "mdef": 0, "mov": 0,
			"crit_chance": 0.0, "crit_damage": 0.0, "hp": 0, "mana": 0}
		var any_flat_bonus := false

		for effect in item_data.get("effects", []):
			if effect.get("type", "") != "add_stat" or effect.get("scope", "permanent") != "permanent":
				continue
			var stat: String = effect.get("stat", "")
			var amount = effect.get("amount", 0)
			var value_mode: String = effect.get("value_mode", "flat")
			if value_mode == "percent" and (stat == "hp" or stat == "mana"):
				# THE FIX: percent HP/mana bonuses used to just bump
				# current_hp/current_mana directly, one time, with nothing
				# tracking a permanently higher MAX anywhere — so current
				# could end up reading as "more than 100%" on every bar.
				# Converting the percentage to a flat number and folding it
				# into this same per-item flat_bonus dict means
				# get_effective_max_hp()/get_effective_max_mana() (see
				# unit_node.gd) now count it as part of the real max, the
				# same way atk/def/etc. bonuses already work.
				var base_value: int = unit.get_stats().hp if stat == "hp" else unit.get_stats().mana
				flat_bonus[stat] += int(base_value * (amount / 100.0))
				any_flat_bonus = true
			elif value_mode == "percent":
				_apply_percent_bonus(unit, stat, amount)
			elif flat_bonus.has(stat):
				flat_bonus[stat] += amount
				any_flat_bonus = true

		if any_flat_bonus:
			unit.momentum_bonuses[bonus_key] = flat_bonus

		# Top current HP/mana up to match the unit's new (possibly higher)
		# max, so equipping the item reads as "bigger pool, starting full"
		# instead of leaving current_hp sitting at whatever fraction of the
		# OLD max it happened to be.
		if flat_bonus.get("hp", 0) != 0:
			unit.current_hp = unit.get_effective_max_hp()
		if flat_bonus.get("mana", 0) != 0:
			unit.current_mana = unit.get_effective_max_mana()

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

	# Unequipping could just have LOWERED this unit's actual max HP/mana —
	# clamp current down so it can't keep sitting above the new max.
	unit.current_hp   = min(unit.current_hp,   unit.get_effective_max_hp())
	unit.current_mana = min(unit.current_mana, unit.get_effective_max_mana())


func apply_permanent_modifiers_to_unit(unit, permanent_modifiers: Array) -> void:
	# Applies a unit's permanent_modifiers (built up over the run by tarot
	# cards, encounter rewards, "+1 ATK per level" effects, etc -- see the
	# "permanent_modifiers" field on RunState.party entries) to a freshly
	# spawned live UnitNode. Uses the exact same momentum_bonuses reuse
	# trick as equipment (see the big comment at the top of this file) --
	# call this alongside apply_equipment_to_unit(), right after unit.setup().
	var flat_bonus := {"atk": 0, "matk": 0, "def": 0, "mdef": 0, "mov": 0,
		"crit_chance": 0.0, "crit_damage": 0.0, "hp": 0, "mana": 0}
	var any_flat := false
	for mod in permanent_modifiers:
		var stat: String = mod.get("stat", "")
		var amount = mod.get("amount", 0)
		var value_mode: String = mod.get("value_mode", "flat")
		if value_mode == "percent" and (stat == "hp" or stat == "mana"):
			# Same fix as equipment above: fold this into flat_bonus so it
			# raises the unit's real max instead of just bumping current.
			var base_value: int = unit.get_stats().hp if stat == "hp" else unit.get_stats().mana
			flat_bonus[stat] += int(base_value * (amount / 100.0))
			any_flat = true
		elif value_mode == "percent":
			push_warning("EquipmentRuntime: percent permanent_modifier not supported for stat '" + stat + "'")
		elif flat_bonus.has(stat):
			flat_bonus[stat] += amount
			any_flat = true
	if any_flat:
		unit.momentum_bonuses["run_permanent_modifiers"] = flat_bonus

	if flat_bonus.get("hp", 0) != 0:
		unit.current_hp = unit.get_effective_max_hp()
	if flat_bonus.get("mana", 0) != 0:
		unit.current_mana = unit.get_effective_max_mana()


func _apply_percent_bonus(unit, stat: String, percent_amount: float) -> void:
	# NOTE: percent hp/mana bonuses are now handled directly inside
	# apply_equipment_to_unit() itself (folded into the per-item flat_bonus
	# dict so they raise the unit's actual MAX, not just current) — this
	# function only handles the remaining stat types now.
	match stat:
		"crit_chance", "crit_damage":
			unit.momentum_bonuses["equip_percent_" + stat] = {stat: percent_amount}
		_:
			push_warning("EquipmentRuntime: percent value_mode not supported for stat '" + stat + "'")
