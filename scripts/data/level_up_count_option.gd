# res://scripts/data/level_up_count_option.gd
#
# LEVEL UP COUNT OPTION -- one possible "how many stats increase this
# level-up" for a unit, e.g. { count: 2, weight: 1.0 }.
#
# A UnitData's "level_up_stat_count_options" array holds several of these,
# so a level-up can sometimes bump 2 stats, sometimes 3, sometimes 4 --
# with whatever odds you want per unit. Leave the array empty on a UnitData
# to use the project default: an equal chance of 2, 3, or 4 stats.

class_name LevelUpCountOption
extends Resource

@export var count: int = 3
# How many DIFFERENT stats get a bonus this level-up, if this option wins.
# Clamped automatically at roll time to however many stats this unit
# actually has available (e.g. a unit with no mana only has 7 possible
# stats, so a count of 8 would never be reachable for it).

@export var weight: float = 1.0
# Relative likelihood of this count being picked, compared to the unit's
# other count options. Higher = more common.
