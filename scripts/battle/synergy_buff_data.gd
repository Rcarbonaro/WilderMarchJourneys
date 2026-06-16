# res://scripts/data/synergy_buff_data.gd
#
# A SynergyBuffData resource defines a passive bonus that activates when
# enough units on the PLAYER's team share a given synergy tag.
#
# HOW IT WORKS:
#   1. You create a .tres file from this resource.
#   2. You fill in the tag to watch (e.g. "Wolf Pack") and the thresholds.
#   3. The SynergySystem (synergy_system.gd) scans the player team at the
#      START of every round and applies the matching stat bonuses to every
#      unit that carries the watched tag.
#
# EXAMPLE — "Wolf Pack" synergy:
#   tag_required: "WolfPack"
#   thresholds: [
#     { "count": 2, "atk_bonus": 3 },
#     { "count": 4, "atk_bonus": 6, "crit_chance_bonus": 5.0 }
#   ]
#   → 2 wolves: each wolf gets +3 ATK
#   → 4 wolves: each wolf gets +6 ATK and +5% crit chance
#
# IMPORTANT: These bonuses are applied as a STATUS EFFECT each round.
#            The SynergySystem removes old synergy statuses and reapplies
#            fresh ones so they always reflect the current team composition.

class_name SynergyBuffData
extends Resource

@export var id: String = ""
# A unique ID string. e.g. "wolf_pack_synergy". No spaces.

@export var display_name: String = ""
# Human-readable name shown in tooltips. e.g. "Wolf Pack".

@export var tag_required: String = ""
# The synergy tag this resource watches.
# Must exactly match a string in unit_data.synergy_tags.
# e.g. "WolfPack", "Overkill", "Critical"

@export var apply_to_all_allies: bool = false
# If false (default): only units that HAVE the tag receive the bonus.
# If true: ALL allied units benefit once the threshold is met,
#          even units without the tag.

# ── THRESHOLDS ────────────────────────────────────────────────────────────────
# This is the core of the synergy system.
# Add one Dictionary entry per threshold level.
#
# Each Dictionary must have a "count" key (how many tagged units are needed)
# plus any stat bonus keys you want. All bonus keys are optional.
#
# Valid bonus keys:
#   "count"              : int   — number of tagged allies needed (REQUIRED)
#   "atk_bonus"          : int
#   "matk_bonus"         : int
#   "def_bonus"          : int
#   "mdef_bonus"         : int
#   "mov_bonus"          : int
#   "crit_chance_bonus"  : float
#   "crit_dmg_bonus"     : float
#   "damage_dealt_bonus" : float  (e.g. 0.1 = +10% damage dealt)
#   "damage_taken_bonus" : float  (e.g. -0.1 = take 10% less damage)
#
# The system picks the HIGHEST threshold the team currently qualifies for.
# e.g. if you have 3 wolves and thresholds at 2 and 4, the 2-wolf bonus applies.

@export var thresholds: Array = []
# Example value you would set in the Inspector (as an Array of Dictionaries):
# [
#   { "count": 2, "atk_bonus": 3 },
#   { "count": 4, "atk_bonus": 6, "crit_chance_bonus": 5.0 }
# ]
#
# NOTE: Godot's Inspector shows arrays of untyped Dictionaries as a list you
# can expand. Add each threshold as a new Dictionary element.
