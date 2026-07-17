# res://scripts/autoloads/combat_hooks.gd
#
# COMBAT HOOKS -- ordered "modifier chains" for moments in combat where a
# plain announcement (EventBus) isn't enough, because something needs to
# CHANGE A NUMBER and hand it back, not just be notified.
#
# CHANGED (this pass): two signatures were widened so gear effects that need
# more context than they used to get can be implemented EXACTLY instead of
# approximated:
#   - on_damage_applied_reactions now also receives damage_type (String), so
#     a handler can tell "was this magic damage?" instead of reacting to
#     every hit regardless of type. Needed for Veilstaff.
#   - after_ability_used now also receives target_cells (the exact grid
#     cells the ability just hit) and a reference to the AbilityExecutor
#     itself, so a handler can (a) resolve exactly which units were hit via
#     grid_ref.get_unit_at(cell), and (b) genuinely re-invoke
#     executor.execute_ability(...) for a true "cast it again" effect.
#     Needed for Lifebinder's Staff and Starcall Prism.
#
# Every EXISTING handler that used either of these two hooks has been
# updated in custom_equipment_handlers.gd to match -- if you have any other
# custom code registered into these two hooks, it needs the extra
# parameter(s) added to its function signature too, even if it ignores them,
# or Callable.call() will error with "too many arguments."
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

# func(attacker, target, actual_damage: int, is_crit: bool, damage_type: String) -> void
# Runs AFTER damage has already been applied -- for reactions like
# Mirrorplate's reflect, Bloody Vial's temp HP, Stoneheart Mail's shield,
# Warden's Cloak, and Veilstaff (which needs damage_type to check for magic).
var on_damage_applied_reactions: Array[Callable] = []

# func(unit) -> void -- called once per unit at the start of every round
# (both player and enemy rounds). Used for "ticking" mechanics like
# Bloodthirster's streak counter, Heartpiercer's recalculation, Vital Bloom,
# and Heavy Plate's adjacency refresh.
var on_unit_round_tick: Array[Callable] = []

# func(caster, ability) -> void -- called right before an ability resolves.
var before_ability_used: Array[Callable] = []

# func(caster, ability, target_cells: Array, origin_cell: Vector2i, executor) -> void
# Called right after an ability fully resolves. 'target_cells' is the exact
# same cell list execute_ability() was called with, so a handler can resolve
# precisely which units were hit (grid_ref.get_unit_at(cell) per cell) instead
# of guessing from adjacency. 'executor' is the AbilityExecutor instance
# itself, passed through so a handler can genuinely re-invoke
# execute_ability() for a true "recast" effect (see Starcall Prism).
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


func run_damage_applied_reactions(attacker, target, actual_damage: int, is_crit: bool, damage_type: String) -> void:
	for reaction in on_damage_applied_reactions:
		if reaction.is_valid():
			reaction.call(attacker, target, actual_damage, is_crit, damage_type)


func run_round_tick(unit) -> void:
	for fn in on_unit_round_tick:
		if fn.is_valid():
			fn.call(unit)


func run_before_ability_used(caster, ability) -> void:
	for fn in before_ability_used:
		if fn.is_valid():
			fn.call(caster, ability)


func run_after_ability_used(caster, ability, target_cells: Array, origin_cell: Vector2i, executor) -> void:
	for fn in after_ability_used:
		if fn.is_valid():
			fn.call(caster, ability, target_cells, origin_cell, executor)


func notify_mana_spent(unit, amount: int) -> void:
	for fn in on_mana_spent:
		if fn.is_valid():
			fn.call(unit, amount)


func notify_unit_died(dead_unit) -> void:
	for fn in on_unit_died:
		if fn.is_valid():
			fn.call(dead_unit)
