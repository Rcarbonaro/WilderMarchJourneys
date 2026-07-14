# res://scripts/data/interrupt_ability_data.gd
#
# An InterruptAbilityData describes ONE reactive ability a unit can fire off
# OUTSIDE its normal turn, in response to something happening to it. This is
# the generic building block behind:
#   - A "Counterattack Stance" status that lets a unit hit back at anyone who
#     attacks them while it's active (status-granted, temporary).
#   - A monster with an innate "when hit, lash out" ability (unit_data-granted,
#     always available).
#   - The Barkskin Elk's phase-transition retreat isn't built on this file —
#     see boss_phase_data.gd — but uses the exact same execution path
#     (InterruptSystem → AbilityExecutor) so both features share one engine.
#
# Any unit can carry MULTIPLE of these at once (innate ones from UnitData,
# plus however many active statuses currently grant one) — InterruptSystem
# collects and evaluates all of them independently, so stacking "just works."

class_name InterruptAbilityData
extends Resource

@export var id: String = ""
# Unique id, used for per-unit cooldown tracking (unit_node.interrupt_cooldowns).

@export var display_name: String = ""

@export_enum("on_damaged", "on_attacked") var trigger: String = "on_damaged"
# "on_damaged"  — fires after ANY damage instance lands on this unit,
#                 regardless of whether it was a hit or a graze.
# "on_attacked" — reserved for a future "fires even on a miss/dodge" trigger.
# Only "on_damaged" is wired up right now (see interrupt_system.gd).

@export var ability: AbilityData
# The actual ability executed when this interrupt fires. Its own min_range/
# max_range/requires_line_of_sight are what's checked against the attacker's
# position — no separate range field needed here.

@export var chance: float = 1.0
# 1.0 = always fires when eligible. Lower this for a "sometimes counters" feel.

@export var cooldown_rounds: int = 0
# 0 = can fire every single time it's eligible. >0 = this many of the
# CARRYING UNIT's own rounds must pass between activations.

@export var requires_attacker_alive: bool = true
# UNCHECK only for effects that should still resolve their ability even if
# the attacker died from the same hit that triggered this (e.g. an AOE that
# also hits other nearby enemies) — see how the range check is skipped in
# that case within interrupt_system.gd.

@export var can_trigger_on_own_turn: bool = false
# UNCHECK (default): if the attacker is an ally of the carrying unit (friendly
# fire, self-damage, etc.), this interrupt is ignored — a counterattack
# stance shouldn't make a unit hit their own healer for accidentally
# clipping them with a mistimed AOE.
# CHECK: fires regardless of team relationship. Used for non-retaliation
# behaviors piggybacking on this same system later (e.g. "when hurt, cry
# out and buff allies" wouldn't care who dealt the damage).
