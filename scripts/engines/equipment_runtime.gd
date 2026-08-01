# res://scripts/engines/equipment_runtime.gd
#
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
#
# STACKING FIX (this pass): apply_equipment_to_unit() used to write one
# momentum_bonuses key PER ITEM ID, and percent crit_chance/crit_damage went
# into a key based on the stat name alone -- both meant two sources that
# happened to share a key (two copies of the same item, or two different
# items both granting the same percent stat) silently overwrote each other
# instead of stacking. Fixed by summing every equipped item's contribution
# into one shared total up front, then writing that ONE combined key
# ("equip_total_flat"). See the big comment inside apply_equipment_to_unit()
# below for the full explanation. remove_equipment_from_unit() and
# compute_preview_stat_bonuses() updated to match.
#
# One minor note while I had this file open, NOT part of any reported bug:
# remove_equipment_from_unit() below is fully correct but is never actually
# called anywhere in the project (searched the whole codebase) -- there's
# currently no flow where a unit is removed from an in-progress battle
# without the whole battle/scene ending, so this isn't causing any visible
# symptom today. Worth keeping in mind if you ever add mid-battle unit
# swapping/retreat, since that would need to call this to unsubscribe
# custom equipment handlers' CombatHooks cleanly.

extends Node

func apply_equipment_to_unit(unit, equipped_item_ids: Array) -> void:
	# ── STACKING FIX (ADDED) ────────────────────────────────────────────────
	# This used to write ONE momentum_bonuses key PER ITEM ID ("equip_" +
	# item_id), and percent crit_chance/crit_damage bonuses went into a key
	# based on the STAT NAME ALONE ("equip_percent_" + stat). Both collided
	# silently instead of stacking:
	#   - Two copies of the SAME item both wrote "equip_<same id>" -- the
	#     second equip just overwrote the first with an identical value, so
	#     wearing two of one item never actually doubled its bonus.
	#   - TWO DIFFERENT items that both grant, say, +crit_chance both wrote
	#     "equip_percent_crit_chance" -- whichever got processed LAST won,
	#     silently discarding the other item's bonus entirely.
	# Fix: sum every equipped item's contribution into ONE shared total up
	# front (same approach compute_preview_stat_bonuses() below already used
	# correctly), then write that single combined total once. Any number of
	# duplicate or same-stat items now just add together naturally.
	var total_flat := {"atk": 0, "matk": 0, "def": 0, "mdef": 0, "mov": 0,
		"crit_chance": 0.0, "crit_damage": 0.0, "hp": 0, "mana": 0}
	var any_flat_bonus := false

	for item_id in equipped_item_ids:
		if item_id == null or item_id == "":
			continue
		var item_data: Dictionary = ContentLoader.get_equipment(item_id)
		if item_data.is_empty():
			push_warning("EquipmentRuntime: equipped item '" + str(item_id) + "' not found.")
			continue

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
				# into this same shared total_flat dict means
				# get_effective_max_hp()/get_effective_max_mana() (see
				# unit_node.gd) now count it as part of the real max, the
				# same way atk/def/etc. bonuses already work.
				var base_value: int = unit.get_stats().hp if stat == "hp" else unit.get_stats().mana
				total_flat[stat] += int(base_value * (amount / 100.0))
				any_flat_bonus = true
			elif value_mode == "percent" and (stat == "crit_chance" or stat == "crit_damage"):
				# Percent crit bonuses are added directly (not scaled against
				# a base value) -- folded into total_flat now too instead of
				# a separate per-stat key, so they stack across items just
				# like everything else here.
				total_flat[stat] += amount
				any_flat_bonus = true
			elif value_mode == "percent":
				push_warning("EquipmentRuntime: percent value_mode not supported for stat '" + stat + "'")
			elif total_flat.has(stat):
				total_flat[stat] += amount
				any_flat_bonus = true

	if any_flat_bonus:
		unit.momentum_bonuses["equip_total_flat"] = total_flat
	else:
		unit.momentum_bonuses.erase("equip_total_flat")

	# Top current HP/mana up to match the unit's new (possibly higher)
	# max, so equipping the item reads as "bigger pool, starting full"
	# instead of leaving current_hp sitting at whatever fraction of the
	# OLD max it happened to be.
	if total_flat.get("hp", 0) != 0:
		unit.current_hp = unit.get_effective_max_hp()
	if total_flat.get("mana", 0) != 0:
		unit.current_mana = unit.get_effective_max_mana()

	for item_id in equipped_item_ids:
		if item_id == null or item_id == "":
			continue
		var item_data: Dictionary = ContentLoader.get_equipment(item_id)
		if item_data.is_empty():
			continue
		for effect in item_data.get("effects", []):
			if effect.get("type", "") == "custom":
				var custom_id: String = effect.get("custom_id", "")
				if CustomEquipmentHandlers.has_handler(custom_id):
					CustomEquipmentHandlers.on_equip(custom_id, unit)
				else:
					push_warning("EquipmentRuntime: no custom handler for '" + custom_id + "' (item '" + item_id + "')")


func compute_preview_stat_bonuses(base_stats: StatsData, equipped_item_ids: Array) -> Dictionary:
	# Same math as apply_equipment_to_unit() above, but returns a plain summed
	# Dictionary instead of writing into a live UnitNode's momentum_bonuses --
	# for screens that need to PREVIEW a unit's effective stats before combat
	# even exists (e.g. deployment_manager.gd's "More Information" popup,
	# which only has base_stats + a list of equipped_item_ids to work with,
	# no live UnitNode). Keep this in sync with apply_equipment_to_unit()
	# above if the effect schema ever changes.
	#
	# Returns a Dictionary with keys "atk", "matk", "def", "mdef", "mov",
	# "crit_chance", "crit_damage", "hp", "mana" -- the FLAT bonus amounts to
	# add on top of base_stats' own numbers to get the unit's effective stats.
	var totals := {"atk": 0, "matk": 0, "def": 0, "mdef": 0, "mov": 0,
		"crit_chance": 0.0, "crit_damage": 0.0, "hp": 0, "mana": 0}

	for item_id in equipped_item_ids:
		if item_id == null or item_id == "":
			continue
		var item_data: Dictionary = ContentLoader.get_equipment(item_id)
		if item_data.is_empty():
			continue

		for effect in item_data.get("effects", []):
			if effect.get("type", "") != "add_stat" or effect.get("scope", "permanent") != "permanent":
				continue
			var stat: String = effect.get("stat", "")
			var amount = effect.get("amount", 0)
			var value_mode: String = effect.get("value_mode", "flat")

			if value_mode == "percent" and (stat == "hp" or stat == "mana"):
				var base_value: int = base_stats.hp if stat == "hp" else base_stats.mana
				totals[stat] += int(base_value * (amount / 100.0))
			elif value_mode == "percent" and (stat == "crit_chance" or stat == "crit_damage"):
				# Matches _apply_percent_bonus() below — crit percentages are
				# added directly, not scaled against a base_value.
				totals[stat] += amount
			elif value_mode == "percent":
				pass   # Not supported for this stat — same restriction as apply_equipment_to_unit().
			elif totals.has(stat):
				totals[stat] += amount

	return totals


func remove_equipment_from_unit(unit, equipped_item_ids: Array) -> void:
	# Call this when a unit leaves combat, so custom handlers can unsubscribe
	# their CombatHooks callbacks cleanly instead of leaking them.
	# ADDED: also erases "equip_percent_*" keys, which the OLD version of
	# this function never actually cleaned up at all (a separate, smaller
	# bug from the stacking one -- percent crit bonuses just stuck around
	# forever after unequip). Moot now that everything lives in one
	# "equip_total_flat" key, erased once below instead of per item.
	unit.momentum_bonuses.erase("equip_total_flat")
	for item_id in equipped_item_ids:
		if item_id == null or item_id == "":
			continue
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
