# res://scripts/data/level_up_stat_rule.gd
#
# LEVEL UP STAT RULE -- describes ONE stat's behavior when THIS unit levels
# up: how likely that stat is to be chosen at all, and (if chosen) how much
# it increases by, and what color its "+X" popup text/sparkles should be.
#
# HOW TO USE: on a UnitData resource, add one of these per stat you want to
# customize to its "level_up_stat_rules" array (in the Inspector: click the
# array, "Add Element", choose "New StatLevelUpRule"). Any stat you DON'T
# add a rule for uses the project-wide defaults instead (equal chance vs.
# every other stat, +1 for most stats, +5 mana, +2% crit chance, +2% crit
# damage, and a default blue text color) -- see level_up_engine.gd.
#
# EXAMPLE -- a unit whose ATK is much more likely to level up than its DEF,
# and whose ATK bonus should show up gold instead of the default blue:
#   Rule 1: stat = "atk", likelihood_weight = 3.0, text_color = gold
#   Rule 2: stat = "def", likelihood_weight = 1.0
#   (Every other stat not listed here still uses the equal-chance default.)

class_name StatLevelUpRule
extends Resource

@export_enum("hp", "mana", "atk", "matk", "def", "mdef", "crit_chance", "crit_damage") var stat: String = "atk"
# Which stat this rule configures. Must exactly match one of these strings.

@export var likelihood_weight: float = 1.0
# How likely THIS stat is to be picked as one of the stats that increases
# this level-up, relative to every OTHER stat's likelihood_weight (either
# from its own rule, or the default weight of 1.0 for any stat that has no
# rule at all). Higher = more likely to be chosen. Set to 0 to make this
# stat impossible to roll for this unit (e.g. a unit with no crit kit at
# all could set crit_chance/crit_damage likelihood_weight to 0).

@export var text_color: Color = Color(0.3, 0.55, 1.0)
# The color of the "+X" popup text (and its matching sparkle particles)
# for this stat, when it's this unit that leveled up. Per the project
# spec, this is meant to be set to blue or gold per stat -- e.g. gold for
# a unit's signature stat, blue for everything else -- but any color works.

@export var amount_options: Array[LevelUpAmountOption] = []
# How much this stat increases by, if chosen. Leave empty to use this
# stat's project-wide default amount (see level_up_engine.gd's
# DEFAULT_AMOUNTS) -- fill in your own array here to override it for just
# THIS unit (e.g. give this specific unit's mana a bigger possible range).
