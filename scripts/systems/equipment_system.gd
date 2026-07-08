# res://scripts/systems/equipment_system.gd
#
# AUTOLOAD. Make sure EventBus and RunManager are ABOVE it in the autoload
# list. Jobs:
#   1. Apply a unit's equipped items' flat stat bonuses at spawn time.
#   2. Run "special effect" logic for advanced equipment.
#   3. Apply a consumable's effect when used in battle, then permanently
#      remove it — including auto-revive on death.
#   4. Forge two basic items into an advanced item if a matching recipe exists.

extends Node

# ── STARTUP ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.ability_used.connect(_on_ability_used)
	EventBus.round_started.connect(_on_round_started)


# ── SECTION 1: APPLYING EQUIPPED STAT BONUSES AT SPAWN ────────────────────────

func apply_equipment_to_unit(unit) -> void:
	if not unit.is_player_unit:
		return
	if unit.unit_data == null or not ("id" in unit.unit_data):
		return
	if RunManager.current_run == null:
		return

	var equipped: Array = RunManager.current_run.equipped_items.get(unit.unit_data.id, [])
	unit.equipped_items = equipped.duplicate()

	var total_hp_bonus: int = 0
	var total_mana_bonus: int = 0
	var base_mana: int = unit.get_stats().mana

	for item in equipped:
		if item == null:
			continue
		if item is BasicEquipmentData or item is AdvancedEquipmentData:
			_apply_flat_stat_status(unit, item)
			total_hp_bonus += item.hp_bonus
			total_mana_bonus += int(base_mana * item.mana_percent_bonus)

	unit.equipment_stat_bonuses = {"hp": total_hp_bonus, "mana": total_mana_bonus}


func _apply_flat_stat_status(unit, item) -> void:
	var status = StatusEffectData.new()
	status.id               = "equip_base_" + item.id
	status.is_permanent     = true
	status.duration_rounds  = 9999
	status.can_stack        = false
	status.atk_modifier          = item.atk_bonus
	status.matk_modifier         = item.matk_bonus
	status.def_modifier          = item.def_bonus
	status.mdef_modifier         = item.mdef_bonus
	status.crit_chance_modifier  = item.crit_chance_bonus
	unit.apply_status(status)


# ── SECTION 2: ADVANCED EQUIPMENT SPECIAL EFFECTS ─────────────────────────────
# To add a NEW effect: give the item's effect_id a new string, add a "match"
# case in _on_ability_used and/or _on_round_started below pointing at a new
# handler function, and use _get_state()/effect_params for any per-unit
# runtime tracking your effect needs. See the 3 worked examples below.

var _effect_state: Dictionary = {}

func _get_state(unit, effect_key: String, defaults: Dictionary) -> Dictionary:
	if not _effect_state.has(unit):
		_effect_state[unit] = {}
	if not _effect_state[unit].has(effect_key):
		_effect_state[unit][effect_key] = defaults.duplicate()
	return _effect_state[unit][effect_key]


func _get_equipped_advanced_with_effects(unit) -> Array:
	var result: Array = []
	if not "equipped_items" in unit:
		return result
	for item in unit.equipped_items:
		if item is AdvancedEquipmentData and item.effect_id != "":
			result.append(item)
	return result


func clear_unit_state(unit) -> void:
	_effect_state.erase(unit)


func _on_ability_used(caster, ability) -> void:
	if not is_instance_valid(caster):
		return
	for item in _get_equipped_advanced_with_effects(caster):
		match item.effect_id:
			"bloodthirster_stack":
				_handle_bloodthirster_attack(caster, item, ability)
			"aegis_codex_cooldown_def":
				_handle_aegis_codex(caster, item, ability)


func _on_round_started(unit) -> void:
	if not is_instance_valid(unit):
		return
	for item in _get_equipped_advanced_with_effects(unit):
		match item.effect_id:
			"bloodthirster_stack":
				_handle_bloodthirster_round_reset(unit, item)
			"heavy_plate_aura":
				_handle_heavy_plate_aura(unit, item)


# -- WORKED EXAMPLE 1: Bloodthirster (on-attack stacking) ----------------------
# "+5 attack. Each subsequent round this unit attacks, gain +1 attack up to
# +4; resets to 0 if the unit does not attack that round."
# effect_params: {"max_stacks": 4}

func _handle_bloodthirster_attack(unit, item, ability) -> void:
	if not (ability.base_damage_multiplier > 0):
		return

	var state = _get_state(unit, item.id, {"stacks": 0, "attacked_this_round": false})
	state["attacked_this_round"] = true
	var max_stacks: int = item.effect_params.get("max_stacks", 4)
	if state["stacks"] < max_stacks:
		state["stacks"] += 1
	_refresh_bloodthirster_status(unit, item, state)


func _handle_bloodthirster_round_reset(unit, item) -> void:
	var state = _get_state(unit, item.id, {"stacks": 0, "attacked_this_round": false})
	if not state["attacked_this_round"]:
		state["stacks"] = 0
	state["attacked_this_round"] = false
	_refresh_bloodthirster_status(unit, item, state)


func _refresh_bloodthirster_status(unit, item, state: Dictionary) -> void:
	unit.remove_status("equip_stack_" + item.id)
	if state["stacks"] <= 0:
		return
	var status = StatusEffectData.new()
	status.id              = "equip_stack_" + item.id
	status.is_permanent    = true
	status.duration_rounds = 9999
	status.atk_modifier    = state["stacks"]
	unit.apply_status(status)


# -- WORKED EXAMPLE 2: Heavy Plate (passive nearby-ally aura) ------------------
# "+5 defense. Increases nearby ally defense by +2"
# effect_params: {"radius": 1, "nearby_def_bonus": 2}
# KNOWN LIMITATION: re-applies each round rather than tracking live movement,
# so a buffed ally keeps the bonus for the rest of the round even if they
# step away mid-turn.

func _handle_heavy_plate_aura(unit, item) -> void:
	if unit.grid_ref == null:
		return
	var radius: int = item.effect_params.get("radius", 1)
	var bonus: int  = item.effect_params.get("nearby_def_bonus", 2)

	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue
			var cell = unit.grid_position + Vector2i(dx, dy)
			var other = unit.grid_ref.get_unit_at(cell)
			if other == null or not is_instance_valid(other):
				continue
			if other.is_player_unit != unit.is_player_unit:
				continue

			var status = StatusEffectData.new()
			status.id              = "equip_aura_" + item.id + "_" + str(unit.get_instance_id())
			status.is_permanent    = true
			status.duration_rounds = 9999
			status.def_modifier    = bonus
			other.apply_status(status)


# -- WORKED EXAMPLE 3: Aegis Codex (on-ability-with-cooldown trigger) ----------
# "+1 DEF, +10% mana. When this unit casts a spell or uses an ability with a
# cooldown, gain +2 DEF for 1 round."
# effect_params: {"def_bonus": 2, "duration_rounds": 1}

func _handle_aegis_codex(unit, item, ability) -> void:
	if ability.cooldown_rounds <= 0:
		return

	var status = StatusEffectData.new()
	status.id              = "equip_temp_" + item.id
	status.duration_rounds = item.effect_params.get("duration_rounds", 1)
	status.def_modifier    = item.effect_params.get("def_bonus", 2)
	unit.apply_status(status)


# ── SECTION 3: CONSUMABLE USE ─────────────────────────────────────────────────

func use_consumable(unit, consumable: ConsumableData) -> void:
	match consumable.effect_type:
		"heal_flat":
			unit.heal(consumable.heal_amount)
		"heal_percent":
			unit.heal(int(unit.get_stats().hp * consumable.heal_percent))
		"restore_mana_flat":
			unit.restore_mana(consumable.mana_amount)
		"restore_mana_percent":
			unit.restore_mana(int(unit.get_stats().mana * consumable.mana_percent))
		"stat_buff":
			var status = StatusEffectData.new()
			status.id              = "consumable_" + consumable.id + "_" + str(Time.get_ticks_msec())
			status.duration_rounds = consumable.buff_duration_rounds
			match consumable.buff_stat:
				"atk":         status.atk_modifier = int(consumable.buff_amount)
				"matk":        status.matk_modifier = int(consumable.buff_amount)
				"def":         status.def_modifier = int(consumable.buff_amount)
				"mdef":        status.mdef_modifier = int(consumable.buff_amount)
				"crit_chance": status.crit_chance_modifier = consumable.buff_amount
				"crit_damage": status.crit_damage_modifier = consumable.buff_amount
				"mov":         status.mov_modifier = int(consumable.buff_amount)
			unit.apply_status(status)

	_remove_consumable(unit, consumable)


func _remove_consumable(unit, consumable: ConsumableData) -> void:
	unit.equipped_items.erase(consumable)
	if unit.unit_data != null and "id" in unit.unit_data and RunManager.current_run != null:
		var list: Array = RunManager.current_run.equipped_items.get(unit.unit_data.id, [])
		list.erase(consumable)
		RunManager.current_run.equipped_items[unit.unit_data.id] = list


# ── SECTION 3b: AUTO-REVIVE (Phoenix Wing) ────────────────────────────────────

func try_auto_revive(unit) -> bool:
	# Called from unit_node.take_damage() the instant a hit would otherwise
	# be fatal. Looks for an equipped "revive" consumable. If found: restores
	# HP, clears all active status effects, permanently removes THAT ONE
	# item, returns true. Never consumes more than one per call.
	if not "equipped_items" in unit:
		return false

	for item in unit.equipped_items:
		if item is ConsumableData and item.effect_type == "revive":
			var max_hp: int = unit.get_stats().hp + unit.equipment_stat_bonuses.get("hp", 0)
			unit.current_hp = max(1, int(max_hp * item.revive_percent))

			for status_entry in unit.active_statuses.duplicate():
				unit.remove_status(status_entry["data"].id)

			unit.update_visuals()
			unit._update_hp_label()
			print("🕊️ ", unit.unit_data.display_name, " was revived by ", item.display_name, "!")

			_remove_consumable(unit, item)
			return true

	return false


# ── SECTION 4: FORGING ─────────────────────────────────────────────────────────

var _advanced_pool_cache: Array = []

func _get_advanced_pool() -> Array:
	if _advanced_pool_cache.is_empty():
		_advanced_pool_cache = ContentLoader.load_all_resources_in_folder(
			"res://content/equipment/advanced/", "AdvancedEquipmentData"
		)
	return _advanced_pool_cache


func forge_equipment(item_a: BasicEquipmentData, item_b: BasicEquipmentData) -> AdvancedEquipmentData:
	for adv in _get_advanced_pool():
		var matches_forward = (adv.required_subtype_a == item_a.subtype and adv.required_subtype_b == item_b.subtype)
		var matches_reverse = (adv.required_subtype_a == item_b.subtype and adv.required_subtype_b == item_a.subtype)
		if matches_forward or matches_reverse:
			return adv
	return null
