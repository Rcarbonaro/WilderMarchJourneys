# res://scripts/autoloads/custom_equipment_handlers.gd
#
# CUSTOM EQUIPMENT HANDLERS -- the unique mechanic behind every Advanced
# Equipment item. Each piece of gear that needs more than a flat stat bonus
# (which is most of them) gets ONE block of functions here.
#
# HOW THIS CONNECTS TO THE REST OF THE SYSTEM:
#   - equipment_runtime.gd calls on_equip(custom_id, unit) the moment a unit
#     wearing this item is spawned into a battle.
#   - on_equip() registers whatever CombatHooks callback this item needs
#     (a damage modifier, a round-tick, a death reaction, etc.)
#   - on_unequip() removes that callback again, so gear that's taken off (or
#     a unit that dies) doesn't keep affecting the game forever.
#
# SIGNATURE CHANGE (this pass): combat_hooks.gd's on_damage_applied_reactions
# now also passes damage_type, and after_ability_used now also passes
# target_cells, origin_cell, and the AbilityExecutor itself. Every handler
# registered to either of those two hooks below has an updated function
# signature to match -- even the ones that don't use the new parameter still
# need to ACCEPT it, or Callable.call() errors with "too many arguments."
#
# A NOTE ON SIMPLE ITEMS: Barbed Arrow is just flat/percent stat bonuses with
# no special behaviour -- it has no entry here at all. Its bonuses are
# handled entirely by equipment_runtime.gd reading its plain "add_stat"
# effects, which is why has_handler() below doesn't list it.
#
# CONVENTION USED THROUGHOUT THIS FILE: every ATK bonus is mirrored to MATK,
# and every DEF bonus is mirrored to MDEF, exactly like the base items. That
# mirroring is baked directly into each item's JSON (two add_stat effects)
# rather than hidden in code, so it stays visible and editable as content.
#
# RENAME NOTE: "Bloody Mantle" was renamed to "Bloody Vial" -- same subtype
# pair (Monocle + Talisman), same effect, just a new name/id to match the
# item's actual JSON (bloody_vial.json).

extends Node

# ---- PER-UNIT RUNTIME STATE --------------------------------------------------
var _bloodthirster_stacks: Dictionary = {}   # unit -> int (0-4)
var _bloodthirster_acted: Dictionary  = {}   # unit -> bool (attacked this round?)
var _stoneheart_triggered: Dictionary = {}   # unit -> bool (one-time per battle)
var _oracle_lens_used: Dictionary     = {}   # unit -> bool (one-time per battle)

var _arcblade_pending: Dictionary  = {}   # unit -> {"type": String, "multiplier": float} or {}
var _arcblade_active: Dictionary   = {}   # unit -> float (damage multiplier active for the ability resolving RIGHT NOW; 1.0 = none)
var _archons_grimoire_used: Dictionary = {}   # unit -> bool (one-time per battle)
var _wardens_cloak_triggered: Dictionary = {} # unit -> bool (resets every round tick)
var _starcall_prism_used_this_round: Dictionary = {} # unit -> bool (resets every round tick)

var _registered_callbacks: Dictionary = {}   # "<custom_id>:<unit instance id>" -> Array of {list, callback}


func has_handler(custom_id: String) -> bool:
	return custom_id in [
		"bloodthirster", "vanguards_edge", "heartpiercer", "spellforged_blade",
		"heavy_plate", "stoneheart_mail", "aegis_codex", "mirrorplate",
		"vital_bloom", "soulweaver_charm", "bloody_vial", "soul_jar",
		"oracles_lens", "crystal_sight",
		"archmages_bulwark", "arcblade_focus", "veilstaff", "starcall_prism",
		"archons_grimoire", "worldroot_staff", "lifebinders_staff", "wardens_cloak",
		"shadowcloak", "ethereal_shroud", "guardian_mantle", "phantom_veil",
		"whispercloak",
	]


func on_equip(custom_id: String, unit) -> void:
	match custom_id:
		"bloodthirster":     _equip_bloodthirster(unit)
		"vanguards_edge":    _equip_vanguards_edge(unit)
		"heartpiercer":      _equip_heartpiercer(unit)
		"spellforged_blade": _equip_spellforged_blade(unit)
		"heavy_plate":       _equip_heavy_plate(unit)
		"stoneheart_mail":   _equip_stoneheart_mail(unit)
		"aegis_codex":       _equip_aegis_codex(unit)
		"mirrorplate":       _equip_mirrorplate(unit)
		"vital_bloom":       _equip_vital_bloom(unit)
		"soulweaver_charm":  _equip_soulweaver_charm(unit)
		"bloody_vial":       _equip_bloody_vial(unit)
		"soul_jar":          _equip_soul_jar(unit)
		"oracles_lens":      _equip_oracles_lens(unit)
		"crystal_sight":     _equip_crystal_sight(unit)
		"archmages_bulwark": _equip_archmages_bulwark(unit)
		"arcblade_focus":    _equip_arcblade_focus(unit)
		"veilstaff":         _equip_veilstaff(unit)
		"starcall_prism":    _equip_starcall_prism(unit)
		"archons_grimoire":  _equip_archons_grimoire(unit)
		"worldroot_staff":   _equip_worldroot_staff(unit)
		"lifebinders_staff": _equip_lifebinders_staff(unit)
		"wardens_cloak":     _equip_wardens_cloak(unit)
		"shadowcloak":       _equip_shadowcloak(unit)
		"ethereal_shroud":   _equip_ethereal_shroud(unit)
		"guardian_mantle":   _equip_guardian_mantle(unit)
		"phantom_veil":      _equip_phantom_veil(unit)
		"whispercloak":      _equip_whispercloak(unit)


func on_unequip(custom_id: String, unit) -> void:
	var key := custom_id + ":" + str(unit.get_instance_id())
	if _registered_callbacks.has(key):
		for entry in _registered_callbacks[key]:
			var list: Array = entry["list"]
			list.erase(entry["callback"])
		_registered_callbacks.erase(key)
	_bloodthirster_stacks.erase(unit)
	_bloodthirster_acted.erase(unit)
	_stoneheart_triggered.erase(unit)
	_oracle_lens_used.erase(unit)
	_arcblade_pending.erase(unit)
	_arcblade_active.erase(unit)
	_archons_grimoire_used.erase(unit)
	_wardens_cloak_triggered.erase(unit)
	_starcall_prism_used_this_round.erase(unit)
	unit.momentum_bonuses.erase("equip_custom_" + custom_id)


func _track(custom_id: String, unit, list: Array, callback: Callable) -> void:
	list.append(callback)
	var key := custom_id + ":" + str(unit.get_instance_id())
	if not _registered_callbacks.has(key):
		_registered_callbacks[key] = []
	_registered_callbacks[key].append({"list": list, "callback": callback})

# ==============================================================================
# 1. BLOODTHIRSTER (Blade + Blade)
# ==============================================================================

func _equip_bloodthirster(unit) -> void:
	_bloodthirster_stacks[unit] = 0
	_bloodthirster_acted[unit] = false
	_track("bloodthirster", unit, CombatHooks.after_ability_used,
		Callable(self, "_bloodthirster_on_ability_used").bind(unit))
	_track("bloodthirster", unit, CombatHooks.on_unit_round_tick,
		Callable(self, "_bloodthirster_round_tick").bind(unit))


func _bloodthirster_on_ability_used(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster == unit and ability.base_damage_multiplier > 0:
		_bloodthirster_acted[unit] = true


func _bloodthirster_round_tick(tick_unit, unit) -> void:
	if tick_unit != unit:
		return
	if _bloodthirster_acted.get(unit, false):
		_bloodthirster_stacks[unit] = min(_bloodthirster_stacks.get(unit, 0) + 1, 4)
	else:
		_bloodthirster_stacks[unit] = 0
	_bloodthirster_acted[unit] = false
	var stacks: int = _bloodthirster_stacks[unit]
	unit.momentum_bonuses["equip_custom_bloodthirster"] = {"atk": stacks, "matk": stacks}

# ==============================================================================
# 2. VANGUARD'S EDGE (Blade + Armor)
# ==============================================================================

func _equip_vanguards_edge(unit) -> void:
	_track("vanguards_edge", unit, CombatHooks.outgoing_damage_modifiers,
		Callable(self, "_vanguards_edge_modify_damage").bind(unit))


func _vanguards_edge_modify_damage(attacker, target, damage: int, is_crit: bool, damage_type: String, unit) -> int:
	if attacker != unit:
		return damage
	var def_diff: int = unit.get_effective_def() - target.get_effective_def()
	if def_diff <= 0:
		return damage
	return damage + int(ceil(def_diff * 0.33))

# ==============================================================================
# 3. HEARTPIERCER (Blade + Talisman)
# ==============================================================================

func _equip_heartpiercer(unit) -> void:
	_track("heartpiercer", unit, CombatHooks.on_unit_round_tick,
		Callable(self, "_heartpiercer_round_tick").bind(unit))
	_heartpiercer_recalculate(unit)


func _heartpiercer_round_tick(tick_unit, unit) -> void:
	if tick_unit == unit:
		_heartpiercer_recalculate(unit)


func _heartpiercer_recalculate(unit) -> void:
	var missing_hp: int = unit.get_stats().hp - unit.current_hp
	var bonus: int = max(0, int(floor(missing_hp / 10.0)))
	unit.momentum_bonuses["equip_custom_heartpiercer"] = {"atk": bonus, "matk": bonus}

# ==============================================================================
# 4. SPELLFORGED BLADE (Blade + Spellbook)
# ==============================================================================

func _equip_spellforged_blade(unit) -> void:
	_track("spellforged_blade", unit, CombatHooks.outgoing_damage_modifiers,
		Callable(self, "_spellforged_blade_modify_damage").bind(unit))


func _spellforged_blade_modify_damage(attacker, target, damage: int, is_crit: bool, damage_type: String, unit) -> int:
	if attacker != unit:
		return damage
	var missing_mana: int = unit.get_stats().mana - unit.current_mana
	var chunks: int = max(0, int(floor(missing_mana / 20.0)))
	if chunks <= 0:
		return damage
	return int(damage * (1.0 + chunks * 0.10))

# ==============================================================================
# 5. BARBED ARROW (Blade + Monocle) -- no handler, plain add_stat effects only.
# ==============================================================================

# ==============================================================================
# 6. HEAVY PLATE (Armor + Armor)
# ==============================================================================

func _equip_heavy_plate(unit) -> void:
	_track("heavy_plate", unit, CombatHooks.on_unit_round_tick,
		Callable(self, "_heavy_plate_round_tick").bind(unit))


func _heavy_plate_round_tick(tick_unit, unit) -> void:
	if tick_unit != unit or unit.grid_ref == null:
		return
	var bonus_key := "equip_custom_heavy_plate_" + str(unit.get_instance_id())
	var nearby_allies := []
	for cell in unit.grid_ref.unit_positions:
		var other = unit.grid_ref.unit_positions[cell]
		if other == unit or not is_instance_valid(other) or other.is_player_unit != unit.is_player_unit:
			continue
		var dist = max(abs(other.grid_position.x - unit.grid_position.x),
						abs(other.grid_position.y - unit.grid_position.y))
		if dist <= 1:
			nearby_allies.append(other)
			other.momentum_bonuses[bonus_key] = {"def": 2, "mdef": 2}
	for other in unit.grid_ref.unit_positions.values():
		if is_instance_valid(other) and other != unit and not other in nearby_allies:
			other.momentum_bonuses.erase(bonus_key)

# ==============================================================================
# 7. STONEHEART MAIL (Armor + Talisman)
# ==============================================================================

func _equip_stoneheart_mail(unit) -> void:
	_stoneheart_triggered[unit] = false
	_track("stoneheart_mail", unit, CombatHooks.on_damage_applied_reactions,
		Callable(self, "_stoneheart_mail_on_damage_applied").bind(unit))


func _stoneheart_mail_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, damage_type: String, unit) -> void:
	if target != unit or _stoneheart_triggered.get(unit, false):
		return
	var max_hp: int = unit.get_stats().hp
	if float(unit.current_hp) / float(max_hp) <= 0.25:
		_stoneheart_triggered[unit] = true
		if unit.grid_ref != null:
			unit.grid_ref.apply_shield(unit, int(max_hp * 0.5), 2)

# ==============================================================================
# 8. AEGIS CODEX (Armor + Spellbook)
# ==============================================================================

func _equip_aegis_codex(unit) -> void:
	_track("aegis_codex", unit, CombatHooks.after_ability_used,
		Callable(self, "_aegis_codex_after_ability").bind(unit))


func _aegis_codex_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit or ability.cooldown_rounds <= 0:
		return
	var status := StatusEffectData.new()
	status.id = "aegis_codex_buff"
	status.display_name = "Aegis Codex"
	status.duration_rounds = 1
	status.can_stack = false
	status.def_modifier = 2
	status.mdef_modifier = 2
	unit.apply_status(status)

# ==============================================================================
# 9. MIRRORPLATE (Armor + Monocle)
# ==============================================================================

func _equip_mirrorplate(unit) -> void:
	_track("mirrorplate", unit, CombatHooks.on_damage_applied_reactions,
		Callable(self, "_mirrorplate_on_damage_applied").bind(unit))


func _mirrorplate_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, damage_type: String, unit) -> void:
	if target != unit or attacker == null or not is_instance_valid(attacker):
		return
	if randf() * 100.0 >= unit.get_effective_crit_chance():
		return
	var crit_mult: float = unit.get_effective_crit_damage() / 100.0
	var reflect := int(actual_damage * 0.10 * crit_mult)
	reflect = min(reflect, attacker.current_hp - 1)
	if reflect > 0:
		attacker.take_damage(reflect, "true")

# ==============================================================================
# 10. VITAL BLOOM (Talisman + Talisman)
# ==============================================================================

func _equip_vital_bloom(unit) -> void:
	_track("vital_bloom", unit, CombatHooks.on_unit_round_tick,
		Callable(self, "_vital_bloom_round_tick").bind(unit))


func _vital_bloom_round_tick(tick_unit, unit) -> void:
	if tick_unit != unit or unit.grid_ref == null:
		return
	unit.grid_ref.apply_shield(unit, int(ceil(unit.get_stats().hp * 0.02)), 1)

# ==============================================================================
# 11. SOULWEAVER CHARM (Talisman + Spellbook)
# ==============================================================================

func _equip_soulweaver_charm(unit) -> void:
	_track("soulweaver_charm", unit, CombatHooks.on_mana_spent,
		Callable(self, "_soulweaver_charm_on_mana_spent").bind(unit))


func _soulweaver_charm_on_mana_spent(spender, amount: int, unit) -> void:
	if spender != unit or amount <= 0:
		return
	var chunks: int = int(ceil(amount / 10.0))
	unit.heal(chunks * int(ceil(unit.get_stats().hp * 0.02)))

# ==============================================================================
# 12. BLOODY VIAL (Talisman + Monocle) -- renamed from "Bloody Mantle".
# ==============================================================================

func _equip_bloody_vial(unit) -> void:
	_track("bloody_vial", unit, CombatHooks.on_damage_applied_reactions,
		Callable(self, "_bloody_vial_on_damage_applied").bind(unit))


func _bloody_vial_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, damage_type: String, unit) -> void:
	if attacker != unit or not is_crit:
		return
	var temp_hp := int(floor(unit.get_effective_atk() * 0.25))
	if temp_hp > 0 and unit.grid_ref != null:
		unit.grid_ref.apply_shield(unit, temp_hp, 1)

# ==============================================================================
# 13. SOUL JAR (Spellbook + Spellbook)
# ==============================================================================

func _equip_soul_jar(unit) -> void:
	_track("soul_jar", unit, CombatHooks.on_unit_died,
		Callable(self, "_soul_jar_on_unit_died").bind(unit))


func _soul_jar_on_unit_died(dead_unit, unit) -> void:
	if not is_instance_valid(unit) or dead_unit.is_player_unit == unit.is_player_unit:
		return
	var dist = abs(dead_unit.grid_position.x - unit.grid_position.x) + \
			   abs(dead_unit.grid_position.y - unit.grid_position.y)
	if dist <= 5:
		unit.restore_mana(int(ceil(unit.get_stats().mana * 0.05)))

# ==============================================================================
# 14. ORACLE'S LENS (Spellbook + Monocle)
# ==============================================================================

func _equip_oracles_lens(unit) -> void:
	_oracle_lens_used[unit] = false
	_track("oracles_lens", unit, CombatHooks.before_ability_used,
		Callable(self, "_oracles_lens_before_ability").bind(unit))
	_track("oracles_lens", unit, CombatHooks.after_ability_used,
		Callable(self, "_oracles_lens_after_ability").bind(unit))


func _oracles_lens_before_ability(caster, ability, unit) -> void:
	if caster != unit or _oracle_lens_used.get(unit, false) or ability.ability_type != "spell":
		return
	unit.momentum_bonuses["equip_custom_oracles_lens_temp"] = {"crit_chance": 50.0}


func _oracles_lens_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit:
		return
	if unit.momentum_bonuses.has("equip_custom_oracles_lens_temp"):
		unit.momentum_bonuses.erase("equip_custom_oracles_lens_temp")
		_oracle_lens_used[unit] = true

# ==============================================================================
# 15. CRYSTAL SIGHT (Monocle + Monocle)
# ==============================================================================

func _equip_crystal_sight(unit) -> void:
	_track("crystal_sight", unit, CombatHooks.outgoing_damage_modifiers,
		Callable(self, "_crystal_sight_modify_damage").bind(unit))


func _crystal_sight_modify_damage(attacker, target, damage: int, is_crit: bool, damage_type: String, unit) -> int:
	if attacker != unit or not is_crit:
		return damage
	return damage + int(target.get_effective_def() * 0.25)

# ==============================================================================
# 16. ARCHMAGE'S BULWARK (Armor + Staff)
# ==============================================================================

func _equip_archmages_bulwark(unit) -> void:
	_track("archmages_bulwark", unit, CombatHooks.on_mana_spent,
		Callable(self, "_archmages_bulwark_on_mana_spent").bind(unit))


func _archmages_bulwark_on_mana_spent(spender, amount: int, unit) -> void:
	if spender != unit or amount <= 0:
		return
	if unit.grid_ref != null:
		unit.grid_ref.apply_shield(unit, int(ceil(amount * 0.25)), 1)

# ==============================================================================
# 17. ARCBLADE FOCUS (Blade + Staff)
# ==============================================================================

func _equip_arcblade_focus(unit) -> void:
	_arcblade_pending[unit] = {}
	_arcblade_active[unit] = 1.0
	_track("arcblade_focus", unit, CombatHooks.before_ability_used,
		Callable(self, "_arcblade_focus_before_ability").bind(unit))
	_track("arcblade_focus", unit, CombatHooks.after_ability_used,
		Callable(self, "_arcblade_focus_after_ability").bind(unit))
	_track("arcblade_focus", unit, CombatHooks.outgoing_damage_modifiers,
		Callable(self, "_arcblade_focus_modify_damage").bind(unit))


func _arcblade_focus_before_ability(caster, ability, unit) -> void:
	if caster != unit:
		return
	var pending: Dictionary = _arcblade_pending.get(unit, {})
	if pending.get("type", "") == ability.ability_type:
		_arcblade_active[unit] = float(pending.get("multiplier", 1.0))
		_arcblade_pending[unit] = {}
	else:
		_arcblade_active[unit] = 1.0


func _arcblade_focus_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit:
		return
	_arcblade_active[unit] = 1.0
	if ability.ability_type == "spell":
		_arcblade_pending[unit] = {"type": "basic_attack", "multiplier": 1.5}
	elif ability.ability_type == "basic_attack":
		_arcblade_pending[unit] = {"type": "spell", "multiplier": 1.25}


func _arcblade_focus_modify_damage(attacker, target, damage: int, is_crit: bool, damage_type: String, unit) -> int:
	if attacker != unit:
		return damage
	var mult: float = _arcblade_active.get(unit, 1.0)
	if mult == 1.0:
		return damage
	return int(damage * mult)

# ==============================================================================
# 18. VEILSTAFF (Staff + Mantle)
# +2 MATK, +3 MDEF flat. Whenever the wearer takes MAGIC damage, restore
# mana equal to 50% of the attacker's MATK (rounded up).
# Now exact: damage_type is checked directly instead of firing on any hit.
# ==============================================================================

func _equip_veilstaff(unit) -> void:
	_track("veilstaff", unit, CombatHooks.on_damage_applied_reactions,
		Callable(self, "_veilstaff_on_damage_applied").bind(unit))


func _veilstaff_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, damage_type: String, unit) -> void:
	if target != unit or attacker == null or not is_instance_valid(attacker):
		return
	if damage_type != "magical":
		return
	unit.restore_mana(int(ceil(attacker.get_effective_matk() * 0.5)))

# ==============================================================================
# 19. STARCALL PRISM (Staff + Monocle)
# +2 MATK, +15% crit chance flat. When casting a spell or ability, a chance
# equal to half the wearer's crit chance to immediately cast it again on the
# same target/area at no cost. Once per round.
# Now exact: genuinely re-invokes AbilityExecutor.execute_ability() with the
# same target_cells, then refunds whatever mana that recast spent (so it
# nets out to free). Recursion is safe: the "used this round" flag is set
# BEFORE the recast runs, so the recast's own after_ability_used firing
# can't proc Starcall Prism a second time.
# ==============================================================================

func _equip_starcall_prism(unit) -> void:
	_starcall_prism_used_this_round[unit] = false
	_track("starcall_prism", unit, CombatHooks.on_unit_round_tick,
		Callable(self, "_starcall_prism_round_tick").bind(unit))
	_track("starcall_prism", unit, CombatHooks.after_ability_used,
		Callable(self, "_starcall_prism_after_ability").bind(unit))


func _starcall_prism_round_tick(tick_unit, unit) -> void:
	if tick_unit == unit:
		_starcall_prism_used_this_round[unit] = false


func _starcall_prism_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit or _starcall_prism_used_this_round.get(unit, false):
		return
	if ability.ability_type != "spell" and ability.ability_type != "ability":
		return
	if executor == null or not executor.has_method("execute_ability"):
		return
	if randf() * 100.0 >= unit.get_effective_crit_chance() * 0.5:
		return

	_starcall_prism_used_this_round[unit] = true   # set BEFORE recasting -- see note above

	var mana_before_recast: int = unit.current_mana
	executor.execute_ability(caster, ability, target_cells, origin_cell)
	if is_instance_valid(unit):
		var spent: int = mana_before_recast - unit.current_mana
		if spent > 0:
			unit.restore_mana(spent)

# ==============================================================================
# 20. ARCHON'S GRIMOIRE (Staff + Spellbook)
# ==============================================================================

func _equip_archons_grimoire(unit) -> void:
	_archons_grimoire_used[unit] = false
	_track("archons_grimoire", unit, CombatHooks.after_ability_used,
		Callable(self, "_archons_grimoire_after_ability").bind(unit))


func _archons_grimoire_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit or _archons_grimoire_used.get(unit, false):
		return
	if ability.mana_cost > 0:
		unit.restore_mana(ability.mana_cost)
	_archons_grimoire_used[unit] = true

# ==============================================================================
# 21. WORLDROOT STAFF (Staff + Staff)
# ==============================================================================

func _equip_worldroot_staff(unit) -> void:
	_track("worldroot_staff", unit, CombatHooks.after_ability_used,
		Callable(self, "_worldroot_staff_after_ability").bind(unit))


func _worldroot_staff_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit or ability.ability_type != "spell" or ability.mana_cost <= 0:
		return
	if randf() < 0.5:
		unit.restore_mana(ability.mana_cost)

# ==============================================================================
# 22. LIFEBINDER'S STAFF (Staff + Talisman)
# +2 MATK, +6 HP flat. Whenever the wearer spends mana to target an ally
# with a spell, that ally gains 5 temporary HP for 1 round.
# Now exact: resolves the REAL units hit via target_cells + grid_ref,
# instead of guessing from adjacency.
# ==============================================================================

func _equip_lifebinders_staff(unit) -> void:
	_track("lifebinders_staff", unit, CombatHooks.after_ability_used,
		Callable(self, "_lifebinders_staff_after_ability").bind(unit))


func _lifebinders_staff_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit or ability.ability_type != "spell" or ability.mana_cost <= 0:
		return
	if ability.affects_team != "allies" and ability.affects_team != "all":
		return
	if unit.grid_ref == null:
		return
	for cell in target_cells:
		var target = unit.grid_ref.get_unit_at(cell)
		if target != null and is_instance_valid(target) and target.is_player_unit == unit.is_player_unit:
			unit.grid_ref.apply_shield(target, 5, 1)

# ==============================================================================
# 23. WARDEN'S CLOAK (Armor + Mantle)
# ==============================================================================

func _equip_wardens_cloak(unit) -> void:
	_wardens_cloak_triggered[unit] = false
	_track("wardens_cloak", unit, CombatHooks.on_unit_round_tick,
		Callable(self, "_wardens_cloak_round_tick").bind(unit))
	_track("wardens_cloak", unit, CombatHooks.on_damage_applied_reactions,
		Callable(self, "_wardens_cloak_on_damage_applied").bind(unit))


func _wardens_cloak_round_tick(tick_unit, unit) -> void:
	if tick_unit == unit:
		_wardens_cloak_triggered[unit] = false


func _wardens_cloak_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, damage_type: String, unit) -> void:
	if target != unit or _wardens_cloak_triggered.get(unit, false):
		return
	_wardens_cloak_triggered[unit] = true

	var refund := int(ceil(actual_damage * 0.25))
	if refund > 0:
		unit.heal(refund)

	var status := StatusEffectData.new()
	status.id = "wardens_cloak_buff"
	status.display_name = "Warden's Cloak"
	status.duration_rounds = 1
	status.can_stack = false
	status.def_modifier = 3
	status.mdef_modifier = 3
	unit.apply_status(status)

# ==============================================================================
# 24. SHADOWCLOAK (Blade + Mantle)  -- NEW
# +2 ATK, +2 MDEF flat. After defeating an enemy, gain +33% damage dealt and
# +1 MOV for 1 round.
#
# IMPLEMENTATION NOTE: rather than using the on_unit_died hook (which only
# passes the dead unit, not who killed it), this checks target.current_hp
# right inside the wearer's OWN outgoing_damage_modifiers callback --
# if the hit we just dealt brought the target to 0 or below, that's a kill,
# with no extra hook wiring needed.
# ==============================================================================

func _equip_shadowcloak(unit) -> void:
	_track("shadowcloak", unit, CombatHooks.outgoing_damage_modifiers,
		Callable(self, "_shadowcloak_modify_damage").bind(unit))


func _shadowcloak_modify_damage(attacker, target, damage: int, is_crit: bool, damage_type: String, unit) -> int:
	if attacker != unit or not is_instance_valid(target):
		return damage
	if target.current_hp - damage <= 0:
		var status := StatusEffectData.new()
		status.id = "shadowcloak_buff"
		status.display_name = "Shadowcloak"
		status.duration_rounds = 1
		status.can_stack = false
		status.damage_dealt_modifier = 0.33
		status.mov_modifier = 1
		unit.apply_status(status)
	return damage

# ==============================================================================
# 25. ETHEREAL SHROUD (Mantle + Mantle)  -- NEW
# +5 MDEF flat. Whenever targeted by a magical attack, 25% chance to absorb
# it entirely (take no damage) and gain 10 temporary HP for 2 rounds.
# ==============================================================================

func _equip_ethereal_shroud(unit) -> void:
	_track("ethereal_shroud", unit, CombatHooks.outgoing_damage_modifiers,
		Callable(self, "_ethereal_shroud_modify_damage").bind(unit))


func _ethereal_shroud_modify_damage(attacker, target, damage: int, is_crit: bool, damage_type: String, unit) -> int:
	if target != unit or damage_type != "magical":
		return damage
	if randf() < 0.25:
		if unit.grid_ref != null:
			unit.grid_ref.apply_shield(unit, 10, 2)
		return 0
	return damage

# ==============================================================================
# 26. GUARDIAN MANTLE (Mantle + Talisman)  -- NEW
# +2 MDEF, +8 HP flat. Whenever an adjacent ally would take magical damage,
# redirect 50% of that damage to the wearer instead.
#
# IMPLEMENTATION NOTE: the redirected half is applied straight to the wearer
# via take_damage(), bypassing outgoing_damage_modifiers/
# on_damage_applied_reactions for that redirected chunk (those two hooks are
# only invoked from ability_executor.gd's explicit call sites, not from
# take_damage() itself) -- so other gear the wearer has (Mirrorplate,
# Stoneheart Mail, etc.) won't react to this specific redirected damage.
# Safe either way: no risk of a hook-recursion loop.
# ==============================================================================

func _equip_guardian_mantle(unit) -> void:
	_track("guardian_mantle", unit, CombatHooks.outgoing_damage_modifiers,
		Callable(self, "_guardian_mantle_modify_damage").bind(unit))


func _guardian_mantle_modify_damage(attacker, target, damage: int, is_crit: bool, damage_type: String, unit) -> int:
	if target == unit or damage_type != "magical" or not is_instance_valid(target):
		return damage
	if target.is_player_unit != unit.is_player_unit or unit.grid_ref == null:
		return damage
	var dist = max(abs(target.grid_position.x - unit.grid_position.x),
					abs(target.grid_position.y - unit.grid_position.y))
	if dist > 1:
		return damage

	var redirected := int(damage * 0.5)
	if redirected > 0:
		unit.take_damage(redirected, damage_type)
	return damage - redirected

# ==============================================================================
# 27. PHANTOM VEIL (Mantle + Monocle)  -- NEW
# +2 MDEF, +15% crit chance flat. Whenever the wearer lands a critical hit,
# the target deals 20% less damage for 1 round.
# ==============================================================================

func _equip_phantom_veil(unit) -> void:
	_track("phantom_veil", unit, CombatHooks.on_damage_applied_reactions,
		Callable(self, "_phantom_veil_on_damage_applied").bind(unit))


func _phantom_veil_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, damage_type: String, unit) -> void:
	if attacker != unit or not is_crit or not is_instance_valid(target):
		return
	var status := StatusEffectData.new()
	status.id = "phantom_veil_debuff"
	status.display_name = "Phantom Veil"
	status.duration_rounds = 1
	status.can_stack = false
	status.damage_dealt_modifier = -0.20
	target.apply_status(status)

# ==============================================================================
# 28. WHISPERCLOAK (Mantle + Spellbook)  -- NEW
# +2 MDEF, +15 mana flat. Whenever the wearer casts a spell that costs mana,
# every enemy within 3 tiles deals 20% less damage for 3 rounds.
# ==============================================================================

func _equip_whispercloak(unit) -> void:
	_track("whispercloak", unit, CombatHooks.after_ability_used,
		Callable(self, "_whispercloak_after_ability").bind(unit))


func _whispercloak_after_ability(caster, ability, target_cells: Array, origin_cell: Vector2i, executor, unit) -> void:
	if caster != unit or ability.ability_type != "spell" or ability.mana_cost <= 0:
		return
	if unit.grid_ref == null:
		return
	for cell in unit.grid_ref.unit_positions:
		var other = unit.grid_ref.unit_positions[cell]
		if not is_instance_valid(other) or other.is_player_unit == unit.is_player_unit:
			continue
		var dist = max(abs(other.grid_position.x - unit.grid_position.x),
						abs(other.grid_position.y - unit.grid_position.y))
		if dist <= 3:
			var status := StatusEffectData.new()
			status.id = "whispercloak_debuff"
			status.display_name = "Whispercloak"
			status.duration_rounds = 3
			status.can_stack = false
			status.damage_dealt_modifier = -0.20
			other.apply_status(status)
