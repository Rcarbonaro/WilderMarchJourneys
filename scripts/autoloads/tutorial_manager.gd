# res://scripts/autoloads/tutorial_manager.gd
extends Node

signal step_started(step: Dictionary)
signal tutorial_ended

var is_active: bool = false
var steps: Array = []
var current_step_index: int = -1

var _targets: Dictionary = {}
var _wait_for_checkers: Dictionary = {}
var _battle_manager_ref: Node = null


func _ready() -> void:
	var overlay := TutorialOverlay.new()
	add_child(overlay)


func register_battle_manager(node: Node) -> void:
	_battle_manager_ref = node


func start_tutorial() -> void:
	steps = ContentLoader.get_tutorial_steps("tutorial_intro")
	if steps.is_empty():
		push_warning("TutorialManager: no steps loaded -- check content/tutorial/tutorial_steps.json")
		return
	is_active = true
	current_step_index = -1
	_advance_to_next_step()


func end_tutorial() -> void:
	is_active = false
	current_step_index = -1
	_targets.clear()
	tutorial_ended.emit()


func get_current_step() -> Dictionary:
	if current_step_index < 0 or current_step_index >= steps.size():
		return {}
	return steps[current_step_index]


func register_target(key: String, node: Node) -> void:
	if not is_active:
		return
	_targets[key] = node


func unregister_target(key: String) -> void:
	_targets.erase(key)


func get_target_node(key: String) -> Node:
	if key.begins_with("unit:"):
		return _resolve_unit_target(key.substr(5))
	var node = _targets.get(key, null)
	if node != null and not is_instance_valid(node):
		_targets.erase(key)
		return null
	return node


func register_wait_for_check(condition_name: String, checker: Callable) -> void:
	_wait_for_checkers[condition_name] = checker


func try_consume(event: String, payload: Dictionary = {}) -> bool:
	if not is_active:
		return true
	var step := get_current_step()
	if step.is_empty():
		return true
	if step.get("type", "gate") != "gate":
		return true
	if step.get("advance_on", "") != event:
		return true
	if not _payload_matches(step.get("advance_match", {}), payload):
		_nudge()
		return false
	_advance_to_next_step()
	return true


func advance() -> void:
	_advance_to_next_step()


func _advance_to_next_step() -> void:
	current_step_index += 1
	if current_step_index >= steps.size():
		end_tutorial()
		return
	var step := get_current_step()
	if step.get("type", "") == "system_action":
		_run_system_action(step)
		_advance_to_next_step()
		return
	step_started.emit(step)
	if step.get("type", "") == "wait_for":
		_poll_wait_for(step)


func _poll_wait_for(step: Dictionary) -> void:
	var condition_name: String = step.get("condition", "")
	var checker: Callable = _wait_for_checkers.get(condition_name, Callable())
	if not checker.is_valid():
		push_warning("TutorialManager: no wait_for checker registered for '" + condition_name + "'")
		return
	while is_active and current_step_index < steps.size() and get_current_step() == step:
		if checker.call():
			_advance_to_next_step()
			return
		await get_tree().create_timer(0.3).timeout


func _run_system_action(step: Dictionary) -> void:
	match step.get("action", ""):
		"grant_items":
			var run_state = RunManager.current_run
			if run_state == null:
				return
			for item_id in step.get("item_ids", []):
				run_state.equipment_inventory.append(item_id)
		_:
			push_warning("TutorialManager: unknown system_action '" + step.get("action", "") + "'")


func _payload_matches(expected: Dictionary, actual: Dictionary) -> bool:
	for key in expected:
		if not actual.has(key) or actual[key] != expected[key]:
			return false
	return true


func _resolve_unit_target(unit_id: String) -> Node:
	if _battle_manager_ref == null:
		return null
	for unit in _battle_manager_ref.player_units:
		if is_instance_valid(unit) and unit.unit_data != null and unit.unit_data.id == unit_id:
			return unit
	return null


func _nudge() -> void:
	EventBus.publish("tutorial_nudge", {})
