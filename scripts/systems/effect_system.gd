# res://scripts/systems/effect_system.gd
#
# AUTOLOAD. Make sure RunManager, ContentLoader, TarotSystem are ABOVE it.
# This is the ONE place that understands the "Generic Effect" schema
# ({"type": "add_gold", ...} etc). Encounters use it for choice effects and
# completion rewards.

extends Node

func apply_effect(effect: Dictionary) -> void:
	for condition in effect.get("conditions", []):
		if not _condition_met(condition):
			return

	match effect.get("type", ""):
		"add_gold":
			RunManager.add_gold(int(effect.get("amount", 0)))

		"add_equipment":
			var eq = ContentLoader.find_equipment_by_id(effect.get("equipment_id", ""))
			if eq != null:
				RunManager.current_run.inventory.append(eq)
			else:
				printerr("⚠️ EffectSystem: equipment id not found: ", effect.get("equipment_id", ""))

		"add_tarot_card":
			var card = TarotSystem._get_card_data(effect.get("tarot_id", ""))
			if card != null:
				TarotSystem.select_card(card)
			else:
				printerr("⚠️ EffectSystem: tarot id not found: ", effect.get("tarot_id", ""))

		"set_flag":
			RunManager.set_flag(effect.get("flag_id", ""))

		"unset_flag":
			RunManager.unset_flag(effect.get("flag_id", ""))

		"add_stat":
			_apply_add_stat(effect)

		"modify_drop_rate":
			var resource_key: String = effect.get("resource", "")
			var mult: float = effect.get("multiplier", 1.0)
			RunManager.temp_drop_rate_modifiers[resource_key] = RunManager.temp_drop_rate_modifiers.get(resource_key, 1.0) * mult

		"custom":
			printerr("⚠️ EffectSystem: 'custom' effect ('", effect.get("custom_id", ""),
					 "') has no built-in handler — add a matching 'match' case yourself.")

		_:
			printerr("⚠️ EffectSystem: unknown effect type: '", effect.get("type", ""), "'")


func _condition_met(condition: Dictionary) -> bool:
	match condition.get("type", ""):
		"flag":          return RunManager.has_flag(condition.get("flag_id", ""))
		"not_flag":      return not RunManager.has_flag(condition.get("flag_id", ""))
		"stage_min":     return RunManager.get_stage_index() >= condition.get("value", 1)
		"has_tarot":     return RunManager.has_tarot(condition.get("tarot_id", ""))
		"random_chance": return randf() < float(condition.get("value", 1.0))
	return true


func _apply_add_stat(effect: Dictionary) -> void:
	var stat: String = effect.get("stat", "atk")
	var amount = effect.get("amount", 0)
	var scope: String = effect.get("scope", "permanent")
	var target: String = effect.get("target", "unit")

	var unit_ids: Array = []
	if target == "unit":
		var explicit_id: String = effect.get("unit_id", "")
		if explicit_id != "":
			unit_ids = [explicit_id]
		elif RunManager.current_run.party.size() > 0:
			unit_ids = [RunManager.current_run.party[randi() % RunManager.current_run.party.size()].id]
	elif target == "team":
		for u in RunManager.current_run.party:
			unit_ids.append(u.id)

	for unit_id in unit_ids:
		match scope:
			"permanent":
				_add_to_bonus_dict(RunManager.current_run.permanent_unit_stat_bonuses, unit_id, stat, amount)
			"session":
				_add_to_bonus_dict(RunManager.session_unit_stat_bonuses, unit_id, stat, amount)
			"temporary":
				if not RunManager.temporary_unit_stat_bonuses.has(unit_id):
					RunManager.temporary_unit_stat_bonuses[unit_id] = {}
				RunManager.temporary_unit_stat_bonuses[unit_id][stat] = {
					"amount": amount, "duration": effect.get("duration", 1)
				}
	RunManager.save_run()


func _add_to_bonus_dict(dict: Dictionary, unit_id: String, stat: String, amount) -> void:
	if not dict.has(unit_id):
		dict[unit_id] = {}
	dict[unit_id][stat] = dict[unit_id].get(stat, 0) + amount
