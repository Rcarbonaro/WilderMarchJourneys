# res://scripts/autoloads/combat_hooks.gd
#
# COMBAT HOOKS -- ordered "modifier chains" for moments in combat where a
# plain announcement (EventBus) isn't enough, because something needs to
# CHANGE A NUMBER and hand it back, not just be notified.
#
# WHY THIS IS SEPARATE FROM EVENT BUS:
#   EventBus is "fire and forget" -- perfect for "a unit just died", where
#   nobody needs to send anything back. But an effect like Vanguard's Edge
#   ("add bonus damage when attacking a weaker-DEF target") needs to take the
#   damage number that's about to be applied and RETURN a bigger number. A
#   plain pub/sub signal can't do that cleanly, so these are ordered lists of
#   Callables that each get a chance to adjust a value before it's used.
#
# HOW TO WIRE THIS INTO THE EXISTING COMBAT SCRIPTS:
#   See the big comment block at the bottom of this file. It lists the exact
#   handful of one-line additions needed in ability_executor.gd, unit_node.gd,
#   and battle_manager.gd. Nothing here does anything until those lines are
#   added -- this file only adds new, optional notifications; it changes no
#   existing behaviour.

extends Node

# func(attacker, target, damage: int, is_crit: bool) -> int
# Receives the damage about to be dealt and returns the (possibly modified)
# damage that should actually be applied. Used by Vanguard's Edge,
# Spellforged Blade, and Crystal Sight.
var outgoing_damage_modifiers: Array[Callable] = []

# func(attacker, target, actual_damage: int, is_crit: bool) -> void
# Runs AFTER damage has already been applied -- for reactions like
# Mirrorplate's reflect, Bloody Mantle's temp HP, Stoneheart Mail's shield.
var on_damage_applied_reactions: Array[Callable] = []

# func(unit) -> void -- called once per unit at the start of every round
# (both player and enemy rounds). Used for "ticking" mechanics like
# Bloodthirster's streak counter, Heartpiercer's recalculation, Vital Bloom,
# and Heavy Plate's adjacency refresh.
var on_unit_round_tick: Array[Callable] = []

# func(caster, ability) -> void -- called right before / after an ability resolves.
var before_ability_used: Array[Callable] = []
var after_ability_used: Array[Callable] = []

# func(unit, amount: int) -> void -- called whenever a unit spends mana.
var on_mana_spent: Array[Callable] = []

# func(dead_unit) -> void -- called whenever any unit dies.
var on_unit_died: Array[Callable] = []


func run_outgoing_damage_modifiers(attacker, target, damage: int, is_crit: bool) -> int:
	var result := damage
	for modifier in outgoing_damage_modifiers:
		if modifier.is_valid():
			result = modifier.call(attacker, target, result, is_crit)
	return result


func run_damage_applied_reactions(attacker, target, actual_damage: int, is_crit: bool) -> void:
	for reaction in on_damage_applied_reactions:
		if reaction.is_valid():
			reaction.call(attacker, target, actual_damage, is_crit)


func run_round_tick(unit) -> void:
	for fn in on_unit_round_tick:
		if fn.is_valid():
			fn.call(unit)


func run_before_ability_used(caster, ability) -> void:
	for fn in before_ability_used:
		if fn.is_valid():
			fn.call(caster, ability)


func run_after_ability_used(caster, ability) -> void:
	for fn in after_ability_used:
		if fn.is_valid():
			fn.call(caster, ability)


func notify_mana_spent(unit, amount: int) -> void:
	for fn in on_mana_spent:
		if fn.is_valid():
			fn.call(unit, amount)


func notify_unit_died(dead_unit) -> void:
	for fn in on_unit_died:
		if fn.is_valid():
			fn.call(dead_unit)



# ==============================================================================
# WIRING CHECKLIST -- add these to the EXISTING combat scripts so the hooks
# above (and a couple of plain EventBus announcements alongside them) actually
# fire during real battles. Every addition is a small, additive change;
# nothing existing needs to be removed or changed.
#
# 1. ability_executor.gd, calculate_damage(): right before the function's
#    final line `return max(1, int(base))`, replace it with:
#        var final_damage = max(1, int(base))
#        final_damage = CombatHooks.run_outgoing_damage_modifiers(caster, target, final_damage, _last_hit_was_crit)
#        return final_damage
#
# 2. ability_executor.gd, _apply_damage_with_effects(): right after the line
#    `var actual_damage = target.take_damage(damage, ability.damage_type)`
#    (BEFORE the Crit Overload check that resets _last_hit_was_crit, so the
#    crit flag is still accurate here), add:
#        CombatHooks.run_damage_applied_reactions(caster, target, actual_damage, _last_hit_was_crit)
#
# 3. ability_executor.gd, execute_ability(): right after the mana/affordability
#    check (just before the "STEP 1: APPLY COSTS" comment), add:
#        CombatHooks.run_before_ability_used(caster, ability)
#    ...and near the bottom of the same function, after the VFX section, add:
#        CombatHooks.run_after_ability_used(caster, ability)
#
# 4. ability_executor.gd, inside _apply_damage_with_effects(), in the
#    "ON-KILL CHECK" section (where it already checks
#    `if hp_before_damage > 0 and target.current_hp <= 0:`), add:
#        EventBus.publish("on_enemy_defeated", {
#            "caster": caster, "target": target,
#            "overkill_amount": max(0, actual_damage - hp_before_damage),
#        })
#    This is what lets tarot cards like "The Execution (Overkill)" react to
#    overkill kills.
#
# 5. unit_node.gd, spend_mana(): add one line after the existing body:
#        CombatHooks.notify_mana_spent(self, amount)
#
# 6. unit_node.gd, die(): add one line right after the existing
#    AuraManager.remove_all_auras_for(self) call:
#        CombatHooks.notify_unit_died(self)
#    (This is the equipment-facing notification -- e.g. Soul Jar listens
#    here. It does NOT carry "who's still alive", which is why item 9 below
#    publishes a SEPARATE, EventBus-based death announcement for tarot cards.)
#
# 7. battle_manager.gd, in BOTH end_player_turn() and _on_enemy_turn_complete(),
#    inside the loop that already calls unit.tick_statuses_end_of_round(...),
#    add one line per unit:
#        CombatHooks.run_round_tick(unit)
#
# 8. battle_manager.gd, spawn_unit(): right after `unit.setup(unit_data, level, is_player)`,
#    add BOTH of these (equipped_item_ids and permanent_modifiers both come
#    from that unit's RunState.party entry):
#        EquipmentRuntime.apply_equipment_to_unit(unit, equipped_item_ids)
#        EquipmentRuntime.apply_permanent_modifiers_to_unit(unit, permanent_modifiers)
#
# 9. battle_manager.gd, _on_unit_died(unit): add this AFTER the existing
#    `player_units.erase(unit)` / `enemy_units.erase(unit)` lines (so the
#    rosters below correctly reflect "who's left"):
#        EventBus.publish(EventBus.ON_UNIT_DIED, {
#            "unit": unit, "is_player_unit": unit.is_player_unit,
#            "live_units": player_units if unit.is_player_unit else enemy_units,
#        })
#    This is what lets tarot cards like "The Pact" grant a battle-wide buff
#    to every surviving ally the moment one of them dies -- "live_units" is
#    exactly what EffectSystem's target_selector "all_allies" reads for
#    "temporary"/"session" scoped effects (see FIELD_REFERENCE.md).
#
# 10. unit_node.gd, apply_status(): in the "Brand new status -- add it to the
#     list" branch (right after the existing _debug_print_status_applied call,
#     before the "VISUAL OVERRIDE ENTRY" section), add:
#         var is_buff := (status_data.atk_modifier > 0 or status_data.def_modifier > 0 or
#                         status_data.matk_modifier > 0 or status_data.mdef_modifier > 0 or
#                         status_data.mov_modifier > 0 or status_data.crit_chance_modifier > 0 or
#                         status_data.damage_dealt_modifier > 0 or status_data.damage_taken_modifier < 0 or
#                         status_data.grants_immunity)
#         EventBus.publish(EventBus.ON_BUFF_APPLIED, {"unit": self, "status_id": status_data.id, "is_buff": is_buff})
#     (This mirrors the existing is_positive check inside get_buff_count() --
#     copy-pasted on purpose, so both stay in sync.) This is what lets "The
#     Sun" react to the first buff cast each battle.
#
# 11. battle_scene.gd, _ready(): add ONE line near the top, before anything
#     else runs:
#         EventBus.publish(EventBus.ON_BATTLE_START, {})
#     This resets every "once_per_battle" tarot trigger guard (see
#     effect_system.gd) and any battle-scoped custom handler state (see
#     custom_equipment_handlers.gd / custom_tarot_handlers.gd) at the start
#     of every fight. Skipping this just means those mechanics behave as if
#     they'd already fired earlier in the run -- nothing crashes.
#
# 12. Wherever your stage-advance logic currently lives (battle_scene.gd's
#     _on_battle_ended(), or RunManager.advance_stage()), add:
#         EventBus.publish(EventBus.ON_STAGE_COMPLETE, {
#             "was_combat": RunManager.get_current_stage_type() in ["combat","subboss","special_combat","boss"],
#         })
#     This is what lets cards like "The Oracle" roll their post-combat
#     chance effects.
# ==============================================================================
