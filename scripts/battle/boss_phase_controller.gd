# res://scripts/battle/boss_phase_controller.gd
# ==============================================================================
# BOSS PHASE CONTROLLER — owns segmented-HP transition behavior: retreat,
# reinforcement summon, stat/kit changes, and the announcement banner.
#
# unit_node.gd's take_damage() clamps damage at a segment boundary and emits
# `hp_segment_depleted(unit, depleted_segment_index)` — this controller
# listens for that signal (subscribed per-unit at spawn time) and runs the
# actual transition sequence.
#
# Add this as a Node (this script attached) under BattleScene. Wired in
# battle_manager.gd's _ready() and given references to pathfinder,
# reinforcement_spawner, and executor.
# ==============================================================================
extends Node

var pathfinder_ref: Node = null
var reinforcement_spawner_ref: Node = null

func setup(pathfinder: Node, reinforcement_spawner: Node) -> void:
	pathfinder_ref            = pathfinder
	reinforcement_spawner_ref = reinforcement_spawner


func register_unit(unit) -> void:
	# Call this once, right after spawn_unit(), for any unit whose UnitData
	# has hp_segment_count > 1. Wires the signal AND applies phase 0's stat/
	# kit modifiers immediately so it starts the fight in the right state.
	if unit.unit_data.hp_segment_count <= 1:
		return
	if unit.unit_data.boss_phases.size() != unit.unit_data.hp_segment_count:
		push_warning("BossPhaseController: '%s' has hp_segment_count=%d but boss_phases.size()=%d — they must match." %
			[unit.unit_data.display_name, unit.unit_data.hp_segment_count, unit.unit_data.boss_phases.size()])
		return

	unit.hp_segment_depleted.connect(_on_segment_depleted.bind(unit))
	_apply_phase(unit, 0)


func _on_segment_depleted(depleted_index: int, unit) -> void:
	var attacker = unit.last_damage_attacker
	print("🦌 Segment ", depleted_index, " depleted. Attacker: ", attacker, " | pathfinder_ref: ", pathfinder_ref)   # ADDED

	# Guard against a stale/missing attacker reference (shouldn't normally
	# happen since take_damage always sets this right before emitting).
	var phase_data: BossPhaseData = unit.unit_data.boss_phases[depleted_index]
	var next_index: int = depleted_index + 1

	unit.is_phase_transitioning = phase_data.transition_invulnerable
	if phase_data.announcement_text != "":
		EventBus.publish(EventBus.ON_BOSS_PHASE_CHANGED, {
			"unit": unit, "phase_name": phase_data.phase_name,
			"text": phase_data.announcement_text,
		})

	await _run_retreat(unit, attacker, phase_data.retreat_squares)

	if is_instance_valid(unit) and phase_data.summon_wave != null and reinforcement_spawner_ref != null:
		reinforcement_spawner_ref.spawn_wave(phase_data.summon_wave, unit)

	if is_instance_valid(unit):
		_apply_phase(unit, next_index)
		unit.is_phase_transitioning = false


func _run_retreat(unit, attacker, squares: int) -> void:
	print("🏃 _run_retreat called. squares=", squares, " unit valid=", is_instance_valid(unit), " attacker valid=", is_instance_valid(attacker), " pathfinder_ref=", pathfinder_ref)   # DEBUG
	if squares <= 0 or not is_instance_valid(unit) or not is_instance_valid(attacker):
		print("🏃 retreat aborted — squares/unit/attacker check failed")
		return
	if pathfinder_ref == null:
		print("🏃 retreat aborted — pathfinder_ref is null")
		return

	var reachable: Dictionary = pathfinder_ref.get_reachable_cells(unit.grid_position, squares, unit)
	print("🏃 reachable cell count: ", reachable.size())
	if reachable.is_empty():
		return

	# Pick the reachable cell that MAXIMIZES distance from the attacker —
	# this is the "realistic pathfinding" retreat: it may end up closer than
	# `squares` tiles away if terrain/units block a further retreat, but it
	# always picks the best available option.
	var best_cell = unit.grid_position
	var best_dist = -1
	for cell in reachable.keys():
		var d = abs(cell.x - attacker.grid_position.x) + abs(cell.y - attacker.grid_position.y)
		if d > best_dist:
			best_dist = d
			best_cell = cell

	if best_cell == unit.grid_position:
		return

	unit.look_at_target(best_cell)
	var path: Array = pathfinder_ref.reconstruct_path_to(best_cell)
	unit.move_along_path(path)
	await unit.movement_finished


func _apply_phase(unit, phase_index: int) -> void:
	if phase_index >= unit.unit_data.boss_phases.size():
		return   # already in the final phase — nothing further to apply.
	unit.current_boss_phase_index = phase_index
	var phase: BossPhaseData = unit.unit_data.boss_phases[phase_index]
	unit.boss_phase_stat_multipliers = {
		"atk": phase.atk_multiplier, "matk": phase.matk_multiplier,
		"def": phase.def_multiplier, "mdef": phase.mdef_multiplier,
		"mov_bonus": phase.mov_bonus,
	}
	for ability in phase.add_abilities:
		if ability != null and not unit.unit_data.starting_abilities.has(ability):
			unit.phase_granted_abilities.append(ability)
