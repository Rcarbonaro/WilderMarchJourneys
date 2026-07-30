# res://scripts/data/level_up_amount_option.gd
#
# LEVEL UP AMOUNT OPTION -- one possible "how much" for a single stat when
# a character levels up. A StatLevelUpRule (see level_up_stat_rule.gd) holds
# an Array of these, so a stat can have several different possible amounts,
# each with its own likelihood.
#
# EXAMPLE -- Mana could increase by 5, 6, 7, or 8, with different odds:
#   [ {amount: 5, weight: 4.0}, {amount: 6, weight: 3.0},
#     {amount: 7, weight: 2.0}, {amount: 8, weight: 1.0} ]
#   -> +5 is the most common roll, +8 is the rarest.
#
# If a StatLevelUpRule has NO amount_options at all, LevelUpEngine falls
# back to a sensible per-stat default (see level_up_engine.gd's
# DEFAULT_AMOUNTS) -- so you only need to fill this in for stats you
# actually want to customize.

class_name LevelUpAmountOption
extends Resource

@export var amount: float = 1.0
# How much the stat increases by if this option is rolled. Most stats use
# whole numbers (1, 2, 5...); crit_chance/crit_damage are percentages
# (e.g. 2.0 = +2%), so decimals are fine there too.

@export var weight: float = 1.0
# Relative likelihood of THIS amount being picked, compared to the other
# amount_options on the same stat. Higher = more common. These don't need
# to add up to any particular total -- only the ratio between them matters.
# e.g. weight 4.0 next to weight 1.0 means the first option is 4x as likely.
