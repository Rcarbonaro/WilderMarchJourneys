#================================================================================
#  D.  res://scripts/data/conditional_stat_bonus.gd                        
#================================================================================
# Sub-resource used inside SpecialEffectData when effect_type = "conditional_stat".
# Defines ONE passive stat bonus that scales with a condition count.
# Re-evaluated at the START of every turn by UnitNode.recalculate_passives().
#
# HOW TO USE:
#   Inside SpecialEffectData with effect_type="conditional_stat",
#   open conditional_bonuses, add a ConditionalStatBonus, set condition_type
#   and stat_to_boost, plus bonus_per_stack and max_bonus.

class_name ConditionalStatBonus
extends Resource

@export_enum(
	"debuffs_on_enemy_target",  # Counts debuffs on the enemy being attacked
	"buffs_on_self"             # Counts buffs currently on this unit
) var condition_type: String = "buffs_on_self"
# What the bonus looks at each turn:
#   "debuffs_on_enemy_target" — at the moment of attacking or being attacked,
#     counts how many debuffs the ENEMY has and adds stat bonus accordingly.
#     This is calculated dynamically during damage resolution, not turn-start.
#   "buffs_on_self" — counts how many buffs THIS unit currently has.
#     Applied as a flat always-on passive recalculated each turn start.

@export_enum("atk","matk","def","mdef","crit_chance","crit_damage","mov") var stat_to_boost: String = "atk"
# Which stat receives the bonus.
# "crit_chance" → adds to the unit's critical hit chance (as a fraction, e.g. 0.05 per stack)
# "crit_damage" → adds to the critical hit damage multiplier
# "mov"         → adds extra movement squares

@export var bonus_per_stack: float = 2.0
# How much to add to the stat for EACH qualifying stack (debuff or buff).
# For "atk"/"def" etc.: added as a flat integer (fractional parts truncated).
# For "crit_chance": treated as a percentage point, e.g. 0.05 = +5% per stack.
# For "crit_damage": treated as a multiplier increment, e.g. 0.1 = +10% per stack.
# For "mov": integer squares per stack.

@export var max_bonus: float = 10.0
# The absolute maximum total bonus regardless of how many stacks are counted.
# Prevents runaway scaling in long battles.
# Example: bonus_per_stack=2, max_bonus=10 → caps at 5 stacks worth of bonus.
