# res://scripts/battle/plague_system.gd
#
# PLAGUE SYSTEM (task 11) — handles Plaguebringer-style spreading debuffs:
#   • A base "Plague" DOT that jumps to a nearby same-team ally when a
#     carrier ENDS ITS TURN within spread_range_on_turn_end tiles of them
#     (does not stack — a carrier already infected is skipped).
#   • When a carrier DIES, the plague (plus every mutation IT was carrying)
#     spreads to same-team allies within spread_range_on_death tiles, PLUS
#     one freshly-rolled random "Plague Mutation" on each of them.
#   • Mutations CAN stack; the base plague cannot.
#
# All of the tunable numbers (ranges, mutation pool/weights, damage %, DOT
# formulas) live on PlagueData resources — see
# res://scripts/data/plague_data.gd. This script contains no hardcoded
# balance numbers at all; it's pure spreading logic.
#
# ── HOW THIS IS WIRED IN ────────────────────────────────────────────────────
# battle_manager.gd owns one PlagueSystem instance (see its _ready() and
# _on_unit_died()). It gets called from two places:
#   1. Once per unit, right after that unit finishes its individual turn —
#      see the call in battle_manager.gd's _finish_ability() (player units)
#      and ai_system.gd's _process_next_enemy() (enemy units, relayed back
#      through battle_manager._check_plague_spread_for()).
#   2. Once per death, from battle_manager.gd's _on_unit_died().
#
# ── SETTING UP A NEW PLAGUE (e.g. the brief's "affects players instead"
#    mirror version) ─────────────────────────────────────────────────────────
# 1. Create a new PlagueData .tres resource (affects_team = "player", and
#    its own plague_status/mutation_pool StatusEffectData resources — these
#    can be totally separate from the enemy version's, or reuse the same
#    StatusEffectData resources if you want identical numbers on both sides).
# 2. In battle_manager.gd's _ready(), add one more line:
#        plague_system.register_plague(load("res://path/to/your_new_plague.tres"))
# That's it — multiple PlagueData resources (any mix of "enemies"/"player")
# can all be active in the same battle at once.
class_name PlagueSystem
extends RefCounted

var battle_manager: Node = null
var _registered_plagues: Array = []          # Array[PlagueData]
var _checked_this_round: Dictionary = {}     # unit -> true, cleared every round


func _init(p_battle_manager: Node) -> void:
	battle_manager = p_battle_manager


func register_plague(plague_data: PlagueData) -> void:
	if plague_data != null and not _registered_plagues.has(plague_data):
		_registered_plagues.append(plague_data)


func clear_round_tracking() -> void:
	# Called once at the start of every new turn-side reset (see
	# battle_manager.gd's end_player_turn()/_on_enemy_turn_complete()) so
	# every unit can trigger its own turn-end spread check again next round.
	_checked_this_round.clear()


# ── INFECTION HELPERS ────────────────────────────────────────────────────────
func has_plague(unit, plague_data: PlagueData) -> bool:
	return is_instance_valid(unit) and plague_data != null and plague_data.plague_status != null \
		and unit.has_status(plague_data.plague_status.id)


func infect(unit, plague_data: PlagueData, source_caster) -> void:
	if unit == null or not is_instance_valid(unit) or plague_data == null:
		return
	if plague_data.plague_status == null:
		push_warning("PlagueSystem: PlagueData '" + plague_data.id + "' has no plague_status assigned — cannot infect.")
		return
	if has_plague(unit, plague_data):
		return   # Does not stack (per the brief) — already carrying this plague.
	unit.apply_status(plague_data.plague_status, 1, source_caster)


# ── TURN-END PROXIMITY SPREAD ────────────────────────────────────────────────
func on_unit_turn_ended(unit) -> void:
	if not is_instance_valid(unit) or battle_manager == null:
		return
	if _checked_this_round.has(unit):
		return   # Already checked once this round (see the two call sites' comments).
	_checked_this_round[unit] = true

	for plague_data in _registered_plagues:
		if not has_plague(unit, plague_data):
			continue
		var team_list: Array = _team_list_for(plague_data, unit)
		if team_list.is_empty():
			continue
		var source_caster = _get_source_caster(unit, plague_data)
		for other in team_list:
			if other == unit or not is_instance_valid(other):
				continue
			if has_plague(other, plague_data):
				continue   # Doesn't stack — an already-infected ally is skipped.
			if _tile_distance(unit.grid_position, other.grid_position) <= plague_data.spread_range_on_turn_end:
				infect(other, plague_data, source_caster)


# ── DEATH SPREAD (plague + mutations) ───────────────────────────────────────
func on_unit_died(unit) -> void:
	if not is_instance_valid(unit) or battle_manager == null:
		return
	for plague_data in _registered_plagues:
		if not has_plague(unit, plague_data):
			continue
		var dying_mutations: Array = _get_active_mutations_on(unit, plague_data)
		var team_list: Array = _team_list_for(plague_data, unit)
		var source_caster = _get_source_caster(unit, plague_data)
		for other in team_list:
			if other == unit or not is_instance_valid(other) or other.current_hp <= 0:
				continue
			if _tile_distance(unit.grid_position, other.grid_position) > plague_data.spread_range_on_death:
				continue

			# Spread the base plague itself (skipped internally if 'other'
			# already has it — does not stack).
			infect(other, plague_data, source_caster)

			# Spread every mutation the DYING unit was already carrying —
			# but per the brief, only ones the recipient doesn't already
			# have (e.g. unit A has -atk/-def, unit B already has -atk/-matk
			# — only -def spreads to B, not a second copy of -atk).
			for mutation in dying_mutations:
				if not other.has_status(mutation.id):
					other.apply_status(mutation, 1, source_caster)

			# PLUS one brand-new randomly rolled "Plague Mutation" (mutations
			# CAN stack, so this applies even if 'other' already has this
			# exact mutation from the loop above or a prior death).
			_roll_and_apply_mutations(other, plague_data, source_caster)


func _get_active_mutations_on(unit, plague_data: PlagueData) -> Array:
	var found: Array = []
	for mutation in plague_data.mutation_pool:
		if mutation != null and unit.has_status(mutation.id):
			found.append(mutation)
	return found


func _roll_and_apply_mutations(unit, plague_data: PlagueData, source_caster) -> void:
	if plague_data.mutation_pool.is_empty():
		return
	for i in range(max(1, plague_data.mutations_per_death)):
		var mutation: StatusEffectData = _weighted_pick(plague_data)
		if mutation != null:
			unit.apply_status(mutation, 1, source_caster)


func _weighted_pick(plague_data: PlagueData) -> StatusEffectData:
	var pool: Array = plague_data.mutation_pool
	if pool.is_empty():
		return null
	var weights: Array = plague_data.mutation_weights
	var effective_weights: Array = []
	var total: float = 0.0
	for i in range(pool.size()):
		var w: float = weights[i] if i < weights.size() else 1.0
		effective_weights.append(w)
		total += w
	if total <= 0.0:
		return pool[randi() % pool.size()]
	var roll: float = randf() * total
	var running: float = 0.0
	for i in range(pool.size()):
		running += effective_weights[i]
		if roll <= running:
			return pool[i]
	return pool[pool.size() - 1]


# ── HELPERS ──────────────────────────────────────────────────────────────────
func _team_list_for(plague_data: PlagueData, unit) -> Array:
	# A plague never crosses teams — see PlagueData.affects_team. We use the
	# infected UNIT's own side here (not just plague_data.affects_team
	# directly) so this still behaves correctly even if a plague_data somehow
	# got applied to the "wrong" side by mistake — it always spreads within
	# whichever team the carrier is actually on.
	if unit.is_player_unit:
		return battle_manager.player_units
	return battle_manager.enemy_units


func _get_source_caster(unit, plague_data: PlagueData):
	# The "caster" credited for a SPREAD infection/mutation is whoever the
	# unit itself caught the plague FROM (i.e. the original apply_status()
	# source_caster stored on unit's own plague status entry) — so a
	# physical/magical DOT mutation's stat snapshot (see unit_node.gd's
	# apply_status()) is taken from the ORIGINAL Plaguebringer's stats all
	# the way down the chain, not diluted generation over generation. Falls
	# back to the spreading unit's own stats if that chain is ever broken
	# (e.g. a very first infection with no caster at all).
	var entry: Dictionary = unit.get_status_entry(plague_data.plague_status.id)
	if not entry.is_empty():
		var caster = entry.get("source_caster", null)
		if caster != null and is_instance_valid(caster):
			return caster
	return unit


func _tile_distance(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)
