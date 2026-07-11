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
