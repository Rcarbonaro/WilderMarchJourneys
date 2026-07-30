# res://scripts/engines/level_up_engine.gd
#
# LEVEL UP ENGINE -- decides what happens when a party/bench unit levels up
# (buying a duplicate copy of a unit you already own).
#
# HOW A LEVEL-UP WORKS, STEP BY STEP:
#   1. Roll HOW MANY stats increase this level (2-4 by default -- see
#      DEFAULT_COUNT_OPTIONS below, or a unit's own level_up_stat_count_options).
#   2. Roll WHICH stats those are, using each stat's likelihood_weight (a
#      unit's own level_up_stat_rules, or the project default of "every
#      stat equally likely" if a unit hasn't customized anything). A unit
#      with no mana (mana <= 0 in its stats) never rolls mana at all.
#   3. For each chosen stat, roll HOW MUCH it increases by, using that
#      stat's amount_options (or the project default amount -- +1 for most
#      stats, +5 mana, +2% crit chance, +2% crit damage).
#   4. Record every result as a "permanent_modifier" on the unit's saved
#      RunState.party/bench entry -- the SAME mechanism tarot cards and
#      encounter rewards already use (see effect_system.gd's _do_add_stat
#      and equipment_runtime.gd's apply_permanent_modifiers_to_unit). This
#      is what makes the bonus last "for the rest of the run": every time
#      this unit is spawned into a battle, EquipmentRuntime folds all of
#      its permanent_modifiers into its real stats automatically -- nothing
#      else needs to know a level-up ever happened.
#   5. Bump the entry's "level" field by 1 (capped at LEVEL_CAP). This is
#      the SEPARATE, ALREADY-EXISTING number that picks which row of
#      UnitData.stats_by_level a unit uses as its designer-set base stats
#      -- the random bonuses above are ADDITIONAL on top of that.
#
# This script does NOT touch the UI at all -- it only computes numbers and
# writes them into the unit's save-data Dictionary. shop_manager.gd calls
# perform_level_up() and then builds a LevelUpPopup to show the player what
# just happened.
#
# HOW TO ADD THIS TO YOUR PROJECT: Project Settings > Autoload > add this
# script, name it "LevelUpEngine".

extends Node

const LEVEL_CAP: int = 5
# Per the project spec: units cap out at level 5. Change this single
# constant if you ever want a different cap.

const ALL_STATS: Array[String] = [
	"hp", "mana", "atk", "matk", "def", "mdef", "crit_chance", "crit_damage",
]

const DEFAULT_STAT_WEIGHT: float = 1.0
# Used for any stat that doesn't have its own StatLevelUpRule on a unit --
# "equal chance for all stats" per the project spec.

const DEFAULT_TEXT_COLOR: Color = Color(0.3, 0.55, 1.0)
# Plain blue, used for any stat that doesn't have its own StatLevelUpRule
# (or whose rule doesn't override text_color).

const DEFAULT_AMOUNTS: Dictionary = {
	# stat -> the single flat amount used when a unit hasn't customized
	# this stat's amount_options at all. Per the project spec: "+1 for
	# most stats, +5 to mana, +2% crit chance, +2% crit damage".
	"hp": 1.0, "atk": 1.0, "matk": 1.0, "def": 1.0, "mdef": 1.0,
	"mana": 5.0, "crit_chance": 2.0, "crit_damage": 2.0,
}

const DEFAULT_COUNT_OPTIONS: Array = [
	# Equal chance of 2, 3, or 4 stats increasing, per the project spec's
	# example ("sometimes 4 stats, other times only 2").
	{"count": 2, "weight": 1.0},
	{"count": 3, "weight": 1.0},
	{"count": 4, "weight": 1.0},
]

const STAT_DISPLAY_NAMES: Dictionary = {
	"hp": "HP", "mana": "Mana", "atk": "ATK", "matk": "MATK",
	"def": "DEF", "mdef": "MDEF", "crit_chance": "Crit Chance", "crit_damage": "Crit Damage",
}


# ---- PUBLIC ENTRY POINTS ------------------------------------------------------

func can_level_up(unit_entry: Dictionary) -> bool:
	# False once a unit has hit LEVEL_CAP -- shop_manager.gd uses this to
	# grey out / relabel that unit's shop card instead of selling a
	# level-up that wouldn't do anything.
	return int(unit_entry.get("level", 1)) < LEVEL_CAP


func perform_level_up(unit_entry: Dictionary, unit_data: UnitData) -> Array:
	# Rolls a full level-up for 'unit_entry' (a Dictionary living inside
	# RunState.party or .bench -- see run_state.gd) and MUTATES it in place
	# (bumping "level" and appending to "permanent_modifiers"), exactly the
	# same way equipping/unequipping items already mutates these entries
	# in shop_manager.gd. Returns an Array of result Dictionaries, one per
	# stat that increased, shaped like:
	#   { "stat": "atk", "amount": 1.0, "color": Color(...), "new_total": 13.0 }
	# -- everything a LevelUpPopup needs to display, in the order the
	# stats should animate in.
	if not can_level_up(unit_entry):
		push_warning("LevelUpEngine: perform_level_up() called on a unit already at LEVEL_CAP -- no-op.")
		return []

	var new_level: int = int(unit_entry.get("level", 1)) + 1
	unit_entry["level"] = new_level
	if not unit_entry.has("permanent_modifiers"):
		unit_entry["permanent_modifiers"] = []

	var chosen_stats: Array = _roll_stats_to_increase(unit_data)
	var results: Array = []
	for stat in chosen_stats:
		var amount: float = _roll_amount_for_stat(unit_data, stat)
		unit_entry["permanent_modifiers"].append({
			"stat": stat,
			"amount": amount,
			"value_mode": "flat",
			"source": "level_up_%d" % new_level,
		})
		results.append({
			"stat": stat,
			"amount": amount,
			"color": get_stat_color(unit_data, stat),
			"new_total": get_current_stat_value(unit_data, unit_entry, stat),
		})
	return results


func get_current_stat_value(unit_data: UnitData, unit_entry: Dictionary, stat: String) -> float:
	# The unit's current permanent total for 'stat': its designer-set base
	# number for its current level (from UnitData.stats_by_level), plus
	# every flat permanent_modifier for that stat this unit has ever
	# earned (level-ups, tarot cards, encounter rewards, ...). This does
	# NOT include equipment or in-battle buffs -- those are temporary/
	# combat-only and don't belong in a "your permanent stats" popup.
	var level: int = int(unit_entry.get("level", 1))
	var stats_index: int = clamp(level - 1, 0, max(0, unit_data.stats_by_level.size() - 1))

	var total: float = 0.0
	if unit_data.stats_by_level.size() > stats_index:
		var base_stats: StatsData = unit_data.stats_by_level[stats_index]
		if base_stats != null:
			total = float(base_stats.get(stat))

	for mod in unit_entry.get("permanent_modifiers", []):
		if mod.get("stat", "") == stat and mod.get("value_mode", "flat") == "flat":
			total += float(mod.get("amount", 0))
	return total


# ---- STAT AVAILABILITY --------------------------------------------------------

func unit_has_mana(unit_data: UnitData) -> bool:
	# A unit "has mana" if its level-1 base stats show a positive mana
	# pool. Units with 0 mana (most physical classes) never roll mana as
	# a level-up stat at all -- per the project spec, mana is skipped
	# entirely for them rather than just being unlikely.
	if unit_data.stats_by_level.is_empty():
		return unit_data.base_stats != null and unit_data.base_stats.mana > 0
	var first: StatsData = unit_data.stats_by_level[0]
	return first != null and first.mana > 0


func get_available_stats(unit_data: UnitData) -> Array:
	var pool: Array = ALL_STATS.duplicate()
	if not unit_has_mana(unit_data):
		pool.erase("mana")
	return pool


# ---- PER-UNIT RULE LOOKUPS (fall back to project defaults) -------------------

func _get_stat_rule(unit_data: UnitData, stat: String) -> StatLevelUpRule:
	for rule in unit_data.level_up_stat_rules:
		if rule != null and rule.stat == stat:
			return rule
	return null


func get_stat_weight(unit_data: UnitData, stat: String) -> float:
	var rule := _get_stat_rule(unit_data, stat)
	return rule.likelihood_weight if rule != null else DEFAULT_STAT_WEIGHT


func get_stat_color(unit_data: UnitData, stat: String) -> Color:
	var rule := _get_stat_rule(unit_data, stat)
	return rule.text_color if rule != null else DEFAULT_TEXT_COLOR


func _get_amount_options(unit_data: UnitData, stat: String) -> Array:
	# Returns an Array of [amount: float, weight: float] pairs to roll
	# from -- either this unit's own customized options, or a single
	# project-default amount if it hasn't customized this stat.
	var rule := _get_stat_rule(unit_data, stat)
	if rule != null and not rule.amount_options.is_empty():
		var result: Array = []
		for option in rule.amount_options:
			if option != null:
				result.append([option.amount, option.weight])
		if not result.is_empty():
			return result
	return [[DEFAULT_AMOUNTS.get(stat, 1.0), 1.0]]


# ---- WEIGHTED ROLLING ----------------------------------------------------------

func _weighted_pick_index(weights: Array) -> int:
	# Same weighted-random pattern shop_engine.gd's _weighted_pick() and
	# scaling_engine.gd's _weighted_pick() already use.
	var total: float = 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return randi() % weights.size()
	var roll: float = randf() * total
	var cumulative: float = 0.0
	for i in range(weights.size()):
		cumulative += weights[i]
		if roll <= cumulative:
			return i
	return weights.size() - 1


func _roll_stat_count(unit_data: UnitData, pool_size: int) -> int:
	var options: Array = []
	for option in unit_data.level_up_stat_count_options:
		if option != null:
			options.append({"count": option.count, "weight": option.weight})
	if options.is_empty():
		options = DEFAULT_COUNT_OPTIONS

	var weights: Array = []
	for option in options:
		weights.append(float(option.get("weight", 1.0)))
	var chosen: int = int(options[_weighted_pick_index(weights)].get("count", 3))

	# Clamp to how many stats this unit actually has available (e.g. a
	# no-mana unit only has 7 possible stats).
	return clamp(chosen, 1, max(1, pool_size))


func _roll_stats_to_increase(unit_data: UnitData) -> Array:
	var pool: Array = get_available_stats(unit_data)
	var count: int = _roll_stat_count(unit_data, pool.size())

	var chosen: Array = []
	var remaining: Array = pool.duplicate()
	for i in range(count):
		if remaining.is_empty():
			break
		var weights: Array = []
		for stat in remaining:
			weights.append(get_stat_weight(unit_data, stat))
		var idx: int = _weighted_pick_index(weights)
		chosen.append(remaining[idx])
		remaining.remove_at(idx)
	return chosen


func _roll_amount_for_stat(unit_data: UnitData, stat: String) -> float:
	var options: Array = _get_amount_options(unit_data, stat)
	var weights: Array = []
	for option in options:
		weights.append(option[1])
	var idx: int = _weighted_pick_index(weights)
	return options[idx][0]
