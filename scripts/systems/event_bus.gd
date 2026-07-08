# res://scripts/systems/event_bus.gd
#
# AUTOLOAD. Holds signals other systems emit/listen to, so combat scripts
# don't need to know anything about equipment/tarot/etc — they just
# announce "this happened" and anyone interested can react.

extends Node

signal ability_used(caster, ability)
# Emitted once per execute_ability() call, after costs/cooldown are applied.
# (Requires a small addition to ability_executor.gd — see the guide.)

signal critical_hit(caster, target, damage: int)
# Emitted whenever a hit crits, right after the crit is resolved.

signal round_started(unit)
# Emitted once per unit at the start of each of their rounds.

signal combat_won()
# Emitted once, right when a battle ends in victory.
