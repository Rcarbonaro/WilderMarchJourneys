# res://scripts/data/plague_data.gd
#
# PLAGUE DATA (task 11) — every tunable number for one "family" of plague
# lives in a resource of this type. Create a .tres of this in the editor
# (Right click in FileSystem → New Resource → search "PlagueData"), fill in
# the fields below, and register it with PlagueSystem.register_plague() (see
# battle_manager.gd's _ready() for the wiring example, and
# res://scripts/battle/plague_system.gd for how every field gets used).
#
# You need at least ONE of these per plague "family". The brief asks for two
# families total: one that spreads among enemies (affects_team = "enemies")
# and a mirrored one that spreads among players (affects_team = "player") —
# see the walkthrough doc for the exact steps to set up the second one; it's
# just a second .tres with different statuses/team, no code changes needed.
class_name PlagueData
extends Resource

@export var id: String = "plaguebringer_plague"
@export var display_name: String = "Plague"

@export_group("Base Plague")
@export var plague_status: StatusEffectData = null
# The status applied to the very first infected unit, and to every unit the
# plague spreads to afterward. Build this as a normal permanent DOT
# StatusEffectData resource:
#   is_permanent      = true
#   can_stack         = false   (per the brief: "this plague does not stack")
#   has_dot           = true
#   dot_damage_mode   = "physical"
#   dot_damage_percent = 0.3333   (1/3 of the caster's ATK, per the brief's
#                                  default — see unit_node.gd's apply_status()
#                                  for how the caster's ATK gets snapshotted
#                                  at the moment of infection, same mechanism
#                                  as the task 3 DOT fix)
# Nothing about DOT-ness is hardcoded in PlagueSystem — all of the actual
# damage math is just the normal StatusEffectData/unit_node.gd DOT pipeline,
# reused here.

@export_group("Mutations (rolled on death)")
@export var mutation_pool: Array[StatusEffectData] = []
# The pool of possible "Plague Mutation" debuffs rolled when a plagued unit
# dies. The brief's default is 3-4 entries: a couple of "-1 to two stats"
# combos (build these as permanent, stackable StatusEffectData resources with
# atk_modifier/matk_modifier/def_modifier/mdef_modifier set to -1 on whichever
# two stats that entry covers) plus one HP-damage-over-time entry (permanent,
# stackable, has_dot = true, dot_damage_mode = "magical",
# dot_damage_percent = 0.1 — "1/10th of plaguebringer's MATK" — this reuses
# the SAME caster-stat-snapshot DOT fix from task 3, so it keeps calculating
# correctly and can never crash even if the original Plaguebringer has since
# died, without PlagueSystem needing any special-case code for that).
#
# Add more mutations any time by just dragging another StatusEffectData
# resource into this array — no code changes needed.

@export var mutation_weights: Array[float] = []
# Relative selection odds, SAME INDEX as mutation_pool above (weights[2] is
# the weight for mutation_pool[2]). Leave empty to weight every entry equally.
# The brief asks for the HP-damage mutation to be rolled "50% less often than
# any of the others" — to do that, give every stat-reduction entry a weight
# of 1.0 and the HP-damage entry a weight of 0.5, in the same order as
# mutation_pool.

@export var mutations_per_death: int = 1
# How many DIFFERENT mutations get rolled and applied each time a plagued
# unit dies. The brief's default is 1 ("a randomly selected debuff"); raise
# this to roll more than one at once.

@export_group("Spread Ranges (tiles, Manhattan distance)")
@export var spread_range_on_turn_end: int = 2
# "If a [unit] with the plague ends its turn within N tiles of another
# [unit on the same team], it spreads the plague." Does not carry mutations
# — just the base plague itself, and only to targets that don't already have
# it (plague does not stack).

@export var spread_range_on_death: int = 3
# "If a [unit] with the plague dies, it spreads the plague to [same-team
# units] within N tiles, but also a 'Plague Mutation'." Also re-spreads every
# mutation the DYING unit was already carrying, to any recipient that didn't
# already have that specific mutation (see PlagueSystem.on_unit_died()).

@export_group("Team")
@export_enum("enemies", "player") var affects_team: String = "enemies"
# Which side this plague infects and spreads across. A plague never crosses
# teams — an enemy-side PlagueData only ever looks at other enemies, and a
# player-side one only ever looks at other player units, matching the
# brief's "Plague does not spread to the player's units" rule (and its
# mirror image for a player-affecting plague).
