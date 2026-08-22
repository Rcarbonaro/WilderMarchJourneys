# res://scripts/autoloads/effect_system.gd
#
# EFFECT SYSTEM -- the universal interpreter for every "effect" Dictionary in
# the game's JSON content (tarot cards, encounter/dialogue rewards, equipment,
# shop modifiers, etc).
#
# IMPORTANT SCOPE NOTE -- TWO KINDS OF TARGET:
#   "permanent" scope effects (the vast majority -- a tarot card's flat
#   stat bonus, an encounter reward) write into a unit's SAVE DATA
#   (run_state.party entries) as a "permanent_modifier". They get folded
#   into a unit's real stats by EquipmentRuntime at the moment that unit is
#   spawned into combat -- see apply_permanent_modifiers_to_unit() in
#   equipment_runtime.gd. This works everywhere (shop, tarot-pick screen,
#   between battles) because it never needs a live battle to exist.
#
#   "temporary" (lasts N rounds) and "session" (lasts the rest of the
#   battle) scope effects only make sense DURING a live battle -- there's
#   no "round" to count down outside one. These are applied directly to
#   live UnitNode references, which the EVENT PAYLOAD that triggered the
#   effect is expected to supply (see _resolve_live_units below). This is
#   how tarot triggers like "after a kill, the killer gains +1 ATK for the
#   rest of the battle" work.
#
# SUPPORTED EFFECT TYPES (anything not listed here, and not registered via
# register_custom_handler(), prints a warning and does nothing):
#   add_stat, add_gold, add_equipment, add_unit, add_tarot_card,
#   remove_tarot_card, set_flag, unset_flag, modify_drop_rate,
#   modify_shop_slots, modify_shop_price, heal, grant_temp_hp, custom

extends Node

var _custom_handlers: Dictionary = {}
# Key: custom_id (String). Value: Callable(effect: Dictionary, context: Dictionary) -> void
# Equipment AND tarot cards share this same registry -- see
# custom_equipment_handlers.gd and custom_tarot_handlers.gd.

var _battle_trigger_fired: Dictionary = {}
# Key: "<tarot_id>:<trigger id or event name>" -> true. Cleared whenever
# EventBus.ON_BATTLE_START fires. Used to gate "once_per_battle" triggers.


func _ready() -> void:
	EventBus.subscribe(EventBus.ON_BATTLE_START, Callable(self, "_on_battle_start"))


func _on_battle_start(_payload: Dictionary) -> void:
	_battle_trigger_fired.clear()


func register_custom_handler(custom_id: String, handler: Callable) -> void:
	_custom_handlers[custom_id] = handler

# ---- PUBLIC ENTRY POINTS ------------------------------------------------------

func apply_effects(effects: Array, context: Dictionary) -> void:
	for effect in effects:
		apply_effect(effect, context)


func apply_effect(effect: Dictionary, context: Dictionary) -> void:
	# context is expected to contain at least:
	#   "run_state": the RunState this effect should act on
	# and OPTIONALLY:
	#   "unit_entry": the specific unit Dictionary (from run_state.party or
	#                 .bench) this effect concerns, when target_selector is "self"
	#   "event_payload": extra data from whatever EventBus event triggered this
	#                 (used by tarot "triggers" and live-battle effects -- see below)
	#   "source": human-readable string for debugging, e.g. "tarot:the_tide"
	if not evaluate_conditions(effect.get("conditions", []), context):
		return

	var type: String = effect.get("type", "")
	match type:
		"add_stat":          _do_add_stat(effect, context)
		"add_gold":          _do_add_gold(effect, context)
		"add_equipment":     _do_add_equipment(effect, context)
		"add_unit":          _do_add_unit(effect, context)
		"add_tarot_card":    _do_add_tarot_card(effect, context)
		"remove_tarot_card": _do_remove_tarot_card(effect, context)
		"set_flag":          _do_set_flag(effect, context, true)
		"unset_flag":        _do_set_flag(effect, context, false)
		"modify_drop_rate":  _do_modify_drop_rate(effect, context)
		"modify_shop_slots": _do_modify_shop_slots(effect, context)
		"modify_shop_price": _do_modify_shop_price(effect, context)
		"heal":              _do_heal(effect, context)
		"grant_temp_hp":     _do_grant_temp_hp(effect, context)
		"add_camp_recruit":  _do_add_camp_recruit(effect, context)   # ADDED (Mini-Encounters)
		"add_skill_scroll":  _do_add_skill_scroll(effect, context)   # ADDED (Skill Scrolls)
		"random_weighted_flag": _do_random_weighted_flag(effect, context)   # ADDED (weighted RNG outcomes)
		"custom":
			var custom_id: String = effect.get("custom_id", "")
			if _custom_handlers.has(custom_id):
				_custom_handlers[custom_id].call(effect, context)
			else:
				push_warning("EffectSystem: no custom handler registered for custom_id '" + custom_id + "'")
		_:
			push_warning("EffectSystem: unknown effect type '" + type + "' -- ignored.")

# ---- TEMPLATING ("$event_payload.field") --------------------------------------
# A handful of fields (currently unit_id and equipment_id) support a small
# templating convention: a String value of "$event_payload.<field>" gets
# swapped out for that field's value from whatever event triggered this
# effect. This is what lets a card like "The Gemini" duplicate WHATEVER unit
# was just purchased, instead of a hardcoded one.

func _resolve_value(value, context: Dictionary):
	if value is String and value.begins_with("$event_payload."):
		var field: String = value.substr("$event_payload.".length())
		return context.get("event_payload", {}).get(field, value)
	return value

# ---- SAVE-DATA TARGET RESOLUTION (permanent scope only) -----------------------

func resolve_targets(effect: Dictionary, context: Dictionary) -> Array:
	# Returns unit-entry Dictionaries from run_state.party -- used ONLY for
	# "permanent" scope add_stat/heal/grant_temp_hp.
	var run_state = context.get("run_state", null)
	if run_state == null:
		return []
	var target: String = effect.get("target", "unit")
	if target != "unit" and target != "team":
		return []

	var selector: String = effect.get("target_selector", "self")
	match selector:
		"self":
			return [context["unit_entry"]] if context.has("unit_entry") else []
		"all_allies", "all_party":
			return run_state.party.duplicate()
		"random_party_member":
			if run_state.party.is_empty():
				return []
			return [run_state.party[randi() % run_state.party.size()]]
		"specific_id":
			var wanted_id: String = effect.get("target_unit_instance_id", "")
			for u in run_state.party:
				if u.get("instance_id", "") == wanted_id:
					return [u]
			return []
		_:
			push_warning("EffectSystem: unknown target_selector '" + selector + "' for permanent scope.")
			return []

# ---- LIVE-BATTLE TARGET RESOLUTION (temporary / session scope) ----------------

func _resolve_live_units(effect: Dictionary, context: Dictionary) -> Array:
	# Returns actual UnitNode references for "temporary"/"session" scope
	# effects. The publisher of whatever event triggered this effect is
	# expected to put live UnitNode references into its event_payload --
	# see FIELD_REFERENCE.md's "live battle targeting" section for exactly
	# which payload field each target_selector reads.
	var payload: Dictionary = context.get("event_payload", {})
	var selector: String = effect.get("target_selector", "all_allies")
	match selector:
		"all_allies", "all_party":
			return payload.get("live_units", [])
		"event_caster":
			return [payload["caster"]] if payload.has("caster") else []
		"event_target":
			return [payload["target"]] if payload.has("target") else []
		"event_unit":
			return [payload["unit"]] if payload.has("unit") else []
		_:
			push_warning("EffectSystem: unknown target_selector '" + selector + "' for live-battle scope.")
			return []

# ---- BUILT-IN HANDLERS --------------------------------------------------------
var is_processing_logic: bool = false
func _do_add_stat(effect: Dictionary, context: Dictionary) -> void:
	is_processing_logic = true
	var stat: String = effect.get("stat", "atk")
	var amount = effect.get("amount", 0.0)
	var value_mode: String = effect.get("value_mode", "flat")
	var scope: String = effect.get("scope", "permanent")
	var source: String = context.get("source", "unknown")

	if scope == "permanent":
		for unit_entry in resolve_targets(effect, context):
			if not unit_entry.has("permanent_modifiers"):
				unit_entry["permanent_modifiers"] = []
			unit_entry["permanent_modifiers"].append({
				"stat": stat, "amount": amount, "value_mode": value_mode, "source": source,
			})
		return

	# "temporary" / "session" -- apply directly to live units right now,
	# via a dynamically-built StatusEffectData (same trick synergy_system.gd
	# and custom_equipment_handlers.gd already use).
	var live_units := _resolve_live_units(effect, context)
	if live_units.is_empty():
		push_warning("EffectSystem: '" + scope + "' scoped add_stat fired with no live units " +
					 "available -- this only works when triggered during a battle. Skipped.")
		return
	is_processing_logic = false

	for live_unit in live_units:
		if not is_instance_valid(live_unit):
			continue
		var status := StatusEffectData.new()
		status.id = "tarot_temp_" + stat + "_" + str(randi())
		status.is_permanent = (scope == "session")        # "session" = rest of battle, never ticks down
		status.duration_rounds = int(effect.get("duration", 1))
		match stat:
			"atk":         status.atk_modifier = int(amount)
			"matk":        status.matk_modifier = int(amount)
			"def":         status.def_modifier = int(amount)
			"mdef":        status.mdef_modifier = int(amount)
			"mov":         status.mov_modifier = int(amount)
			"crit_chance": status.crit_chance_modifier = float(amount)
			_:
				push_warning("EffectSystem: live-battle add_stat doesn't support stat '" + stat + "' yet.")
				continue
		live_unit.apply_status(status)


func _do_add_gold(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	# ADDED: supports a random range now ("amount_min"/"amount_max"), for
	# things like Mini-Encounters' Rob choice ("instantly gain 4-10 gold").
	# Falls back to the plain fixed "amount" if neither range key is
	# present, so every existing effect using a flat amount keeps working
	# completely unchanged.
	var amount: int
	if effect.has("amount_min") or effect.has("amount_max"):
		var lo: int = int(effect.get("amount_min", 0))
		var hi: int = int(effect.get("amount_max", lo))
		amount = randi_range(min(lo, hi), max(lo, hi))
	else:
		amount = int(effect.get("amount", 0))
	run_state.gold = max(0, run_state.gold + amount)
	EventBus.publish(EventBus.ON_GOLD_CHANGED, {"amount": amount, "new_total": run_state.gold})


func _do_add_camp_recruit(effect: Dictionary, context: Dictionary) -> void:
	# ADDED (Mini-Encounters). Increments the persistent "how many survivors
	# has this run recruited" counter, stored in RunState.runtime_effect_state
	# (the existing generic bucket for exactly this kind of persistent
	# counter -- see run_state.gd). Each recruit:
	#   - adds +1 gold to EVERY future stage's end-of-stage reward, forever,
	#     cumulatively (see stage_director.gd's gold reward calculation)
	#   - adds one more tent to the deployment scene's camp background (see
	#     deployment_manager.gd's _refresh_camp_decorations())
	# Both of those just READ this same counter -- this effect is the only
	# thing that ever increments it.
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var current: int = int(run_state.runtime_effect_state.get("camp_recruit_count", 0))
	run_state.runtime_effect_state["camp_recruit_count"] = current + 1
	print("🏕️ Camp recruit count now ", current + 1)


func _do_add_skill_scroll(effect: Dictionary, context: Dictionary) -> void:
	# ADDED (Skill Scrolls). Grants one (or "amount", if set) more use of the
	# generic Skill Scroll -- a simple persistent counter in
	# RunState.runtime_effect_state, same pattern as camp_recruit_count just
	# above, so this works as a combat/encounter/shop reward with zero JSON
	# item content required. See deployment_manager.gd's
	# _refresh_generic_scroll_button() for where the counter actually gets
	# read/spent.
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var amount: int = int(effect.get("amount", 1))
	var current: int = int(run_state.runtime_effect_state.get("skill_scroll_count", 0))
	run_state.runtime_effect_state["skill_scroll_count"] = current + amount
	print("📜 Skill scroll count now ", current + amount)


func _do_add_equipment(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var equipment_id: String = _resolve_value(effect.get("equipment_id", ""), context)
	if equipment_id == "":
		push_warning("EffectSystem: add_equipment effect missing equipment_id")
		return
	run_state.equipment_inventory.append(equipment_id)
	EventBus.publish(EventBus.ON_EQUIPMENT_ACQUIRED, {"equipment_id": equipment_id})

func _do_add_unit(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var unit_id: String = _resolve_value(effect.get("unit_id", ""), context)
	if unit_id == "":
		push_warning("EffectSystem: add_unit effect missing unit_id")
		return

	# ── DUPLICATE CHECK (ADDED) ────────────────────────────────────────────
	# Mirrors ShopEngine.purchase()'s "buying a copy you already own levels
	# it up instead of adding a second copy" rule -- but here, for EVERY
	# source of a free unit (tarot cards, encounter rewards, etc.), not just
	# shop purchases. If the player already owns this unit, level it up
	# instead of creating a duplicate roster entry. Already max level? Then
	# there's nothing left to level -- the extra copy is simply not granted
	# (same as a maxed unit having nothing left to "sell" at the shop).
	var existing_entry: Dictionary = _find_owned_unit_entry(unit_id, run_state)
	if not existing_entry.is_empty():
		if LevelUpEngine.can_level_up(existing_entry):
			var level_up_results: Array = LevelUpEngine.perform_level_up(existing_entry, _load_unit_data(unit_id))
			EventBus.publish(EventBus.ON_UNIT_LEVELED_UP, {
				"unit_entry": existing_entry, "unit_id": unit_id,
				"new_level": int(existing_entry.get("level", 1)), "level_up_results": level_up_results,
			})
		return

	var new_entry := {
		"unit_id": unit_id,
		"instance_id": unit_id + "_" + str(Time.get_ticks_msec()),
		"level": 1,
		"equipped_item_ids": [null, null, null],
		"permanent_modifiers": [],
	}
	if run_state.party.size() < 4:
		run_state.party.append(new_entry)
	else:
		run_state.bench.append(new_entry)


func _find_owned_unit_entry(unit_id: String, run_state) -> Dictionary:
	# Same lookup ShopEngine._find_owned_unit_entry() / shop_manager.gd's
	# _find_owned_entry() use -- duplicated here (rather than reaching into
	# ShopEngine's private helper) so EffectSystem doesn't need to depend on
	# ShopEngine just to check unit ownership. Returns the actual party/bench
	# Dictionary (party checked first), NOT a copy -- GDScript Dictionaries
	# are passed by reference, so LevelUpEngine.perform_level_up() mutating
	# this return value mutates the real save data directly.
	for entry in run_state.party:
		if entry.get("unit_id", "") == unit_id:
			return entry
	for entry in run_state.bench:
		if entry.get("unit_id", "") == unit_id:
			return entry
	return {}


func _load_unit_data(unit_id: String) -> UnitData:
	# Same path convention ShopEngine._load_unit_data() uses.
	var path := "res://resources/units/" + unit_id + "_data.tres"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as UnitData


func _do_add_tarot_card(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var tarot_id: String = effect.get("tarot_id", "")
	var tarot_def := ContentLoader.get_tarot(tarot_id)

	for entry in run_state.tarot_cards:
		if entry.get("tarot_id", "") == tarot_id:
			if tarot_def.get("stackable", false):
				entry["stacks"] = min(entry.get("stacks", 1) + 1, int(tarot_def.get("max_stacks", 99)))
			return

	run_state.tarot_cards.append({"tarot_id": tarot_id, "stacks": 1})
	EventBus.publish(EventBus.ON_TAROT_ACQUIRED, {"tarot_id": tarot_id})

	apply_effects(tarot_def.get("effects", []), context)
	for trigger in tarot_def.get("triggers", []):
		_subscribe_tarot_trigger(tarot_id, trigger, run_state)


func _subscribe_tarot_trigger(tarot_id: String, trigger: Dictionary, run_state) -> void:
	var event_name: String = trigger.get("event", "")
	if event_name == "":
		return
	var callback := Callable(self, "_on_tarot_trigger_fired").bind(tarot_id, trigger, run_state)
	EventBus.subscribe(event_name, callback)


func _on_tarot_trigger_fired(payload: Dictionary, tarot_id: String, trigger: Dictionary, run_state) -> void:
	# trigger_key identifies THIS specific trigger for once_per_battle/run
	# gating. Give a trigger an explicit "id" field if a single tarot card
	# has more than one trigger on the SAME event -- otherwise the event
	# name alone is a perfectly stable key.
	var trigger_key: String = tarot_id + ":" + trigger.get("id", trigger.get("event", ""))

	if trigger.get("once_per_battle", false) and _battle_trigger_fired.get(trigger_key, false):
		return
	if trigger.get("once_per_run", false) and run_state.flags.has("tarot_trigger_fired:" + trigger_key):
		return

	var context := {
		"run_state": run_state, "event_payload": payload,
		"source": "tarot_trigger:" + tarot_id,
	}
	var condition = trigger.get("condition", null)
	if condition != null and not evaluate_condition(condition, context):
		return

	apply_effects(trigger.get("effects", []), context)

	if trigger.get("once_per_battle", false):
		_battle_trigger_fired[trigger_key] = true
	if trigger.get("once_per_run", false):
		run_state.flags.append("tarot_trigger_fired:" + trigger_key)


func _do_remove_tarot_card(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var tarot_id: String = effect.get("tarot_id", "")
	for entry in run_state.tarot_cards.duplicate():
		if entry.get("tarot_id", "") == tarot_id:
			run_state.tarot_cards.erase(entry)


func _do_set_flag(effect: Dictionary, context: Dictionary, value: bool) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var flag_id: String = effect.get("flag_id", "")
	if flag_id == "":
		return
	if value:
		if not run_state.flags.has(flag_id):
			run_state.flags.append(flag_id)
			EventBus.publish(EventBus.ON_FLAG_SET, {"flag_id": flag_id})
	else:
		run_state.flags.erase(flag_id)


func _do_modify_drop_rate(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	# "resource" is matched (by ShopEngine) against: the exact item id, the
	# item_type ("equipment"/"unit"/"consumable"), and -- for equipment --
	# its own "type" ("basic"/"advanced"), "subtype", and "tags"; for units,
	# against the unit's synergy_tags. The special value "owned_units" is
	# recognized dynamically rather than matched as a tag -- see
	# FIELD_REFERENCE.md's "modify_drop_rate matching rules" section.
	#
	# "active_while" (optional) is a CONDITIONS array re-checked every time
	# ShopEngine actually weighs an item -- unlike the top-level "conditions"
	# field (checked ONCE, when this effect itself runs). Use active_while
	# for things like "only during the first 5 stages."
	run_state.drop_rate_modifiers.append({
		"resource": effect.get("resource", ""),
		"multiplier": effect.get("multiplier", 1.0),
		"active_while": effect.get("active_while", []),
	})


func _do_modify_shop_slots(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	run_state.shop_slot_modifier += int(effect.get("amount", 0))


func _do_modify_shop_price(effect: Dictionary, context: Dictionary) -> void:
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	run_state.shop_price_modifiers.append({
		"resource": effect.get("resource", "all"),
		"multiplier": effect.get("multiplier", 1.0),
		"amount": effect.get("amount", 0),
		"active_while": effect.get("active_while", []),
	})


func _do_heal(effect: Dictionary, context: Dictionary) -> void:
	for unit_entry in resolve_targets(effect, context):
		unit_entry["pending_heal"] = effect.get("amount", 0)


func _do_grant_temp_hp(effect: Dictionary, context: Dictionary) -> void:
	for unit_entry in resolve_targets(effect, context):
		unit_entry["pending_temp_hp"] = effect.get("amount", 0)

# ---- CONDITION EVALUATION -----------------------------------------------------

func evaluate_conditions(conditions: Array, context: Dictionary) -> bool:
	for condition in conditions:
		if not evaluate_condition(condition, context):
			return false
	return true


func evaluate_condition(condition: Dictionary, context: Dictionary) -> bool:
	var run_state = context.get("run_state", null)
	var type: String = condition.get("type", "")

	match type:
		"flag":
			return run_state != null and run_state.flags.has(condition.get("flag_id", ""))
		"not_flag":
			return run_state == null or not run_state.flags.has(condition.get("flag_id", ""))
		"stage_min":
			return run_state != null and run_state.stage_index >= int(condition.get("value", 0))
		"stage_max":
			return run_state != null and run_state.stage_index <= int(condition.get("value", 999))
		"has_tarot":
			if run_state == null:
				return false
			for entry in run_state.tarot_cards:
				if entry.get("tarot_id", "") == condition.get("tarot_id", ""):
					return true
			return false
		"not_has_tarot":
			return not evaluate_condition({"type": "has_tarot", "tarot_id": condition.get("tarot_id", "")}, context)
		"tarot_stacks_min":
			if run_state == null:
				return false
			for entry in run_state.tarot_cards:
				if entry.get("tarot_id", "") == condition.get("tarot_id", "") and \
				   entry.get("stacks", 1) >= int(condition.get("value", 1)):
					return true
			return false
		"random_chance":
			return randf() < float(condition.get("value", 0.0))
		"gold_min":
			return run_state != null and run_state.gold >= int(condition.get("value", 0))
		"has_equipment":
			return run_state != null and run_state.equipment_inventory.has(condition.get("equipment_id", ""))
		"difficulty_is":
			return run_state != null and run_state.difficulty == condition.get("value", "")
		"stage_modulo":
			# True every Nth stage -- e.g. {"divisor": 2, "remainder": 0} is
			# true on stage_index 0, 2, 4, 6... Lets a repeatable encounter
			# gate its reward so it doesn't hand out a free item every visit.
			if run_state == null:
				return false
			var divisor: int = int(condition.get("divisor", 1))
			if divisor <= 0:
				return false
			return run_state.stage_index % divisor == int(condition.get("remainder", 0))
		"stage_type_is":
			# ADDED -- lets a reward rule target ("combat", "encounter",
			# "subboss", "special_combat", "boss") specifically, e.g. the
			# default "gain gold for winning a fight" rule shouldn't also
			# fire when an encounter stage completes.
			return run_state != null and ContentLoader.get_stage_type(run_state.stage_index) == condition.get("value", "")
		"event_payload_true":
			return bool(context.get("event_payload", {}).get(condition.get("field", ""), false))
		"event_payload_min":
			var payload: Dictionary = context.get("event_payload", {})
			return float(payload.get(condition.get("field", ""), 0)) >= float(condition.get("value", 0))
		"all_of":
			return evaluate_conditions(condition.get("conditions", []), context)
		"any_of":
			for sub in condition.get("conditions", []):
				if evaluate_condition(sub, context):
					return true
			return false
		"not":
			return not evaluate_condition(condition.get("condition", {}), context)
		_:
			push_warning("EffectSystem: unknown condition type '" + type + "' -- treated as false.")
			return false
			

func _do_random_weighted_flag(effect: Dictionary, context: Dictionary) -> void:
	# Rolls ONE outcome from a weighted list, then sets THAT outcome's flag --
	# and only that one. Clears every flag named in "outcomes" first, so this
	# works cleanly even on a repeatable encounter re-rolling the same
	# outcome on a later visit (nothing lingers from last time).
	#
	# Combine with a choice's "next_node_id_branches" (see dialogue_engine.gd)
	# to branch the dialogue graph on the result, and with a later effect's
	# own "conditions" (see apply_effect() above -- every effect is already
	# gated by its own conditions) to fire OTHER effects only on a specific
	# outcome, e.g. a gold-loss effect that should only apply on "fail".
	#
	# effect = { "type": "random_weighted_flag", "outcomes": [
	#              { "weight": 50, "flag_id": "my_fail_flag" },
	#              { "weight": 50, "flag_id": "my_success_flag" } ] }
	var run_state = context.get("run_state", null)
	if run_state == null:
		return
	var outcomes: Array = effect.get("outcomes", [])
	if outcomes.is_empty():
		return

	for outcome in outcomes:
		run_state.flags.erase(outcome.get("flag_id", ""))

	var total_weight: float = 0.0
	for outcome in outcomes:
		total_weight += float(outcome.get("weight", 1.0))

	var roll: float = randf() * total_weight
	var running: float = 0.0
	for outcome in outcomes:
		running += float(outcome.get("weight", 1.0))
		if roll < running:
			var flag_id: String = outcome.get("flag_id", "")
			if flag_id != "" and not run_state.flags.has(flag_id):
				run_state.flags.append(flag_id)
			return
