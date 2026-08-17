# res://scripts/autoloads/tutorial_manager.gd
#
# TUTORIAL MANAGER -- walks tutorial_steps.json one step at a time. Every
# other system that needs to participate does so through exactly two calls:
#   - register_target(key, node)   -- "here's a Control/Node2D the tutorial
#                                      might want to point an arrow at"
#   - try_consume(event, payload)  -- "this real game action just happened,
#                                      does it satisfy the current step?"
# Nothing else in the project needs to know the tutorial exists beyond that.
#
# ADD THIS AS AN AUTOLOAD: Project Settings > Autoload > add this script,
# name it "TutorialManager". Order relative to other autoloads doesn't
# matter as long as it's before anything that calls it in _ready() (in
# practice, Godot autoloads are all available to every other autoload's
# _ready() regardless of declared order, so this is a non-issue).

extends Node

signal step_started(step: Dictionary)
signal tutorial_ended

var is_active: bool = false
var steps: Array = []
var current_step_index: int = -1

var _targets: Dictionary = {}          # key (String) -> Node, re-registered per-screen
var _wait_for_checkers: Dictionary = {} # condition name (String) -> Callable
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
	# Call this from any screen while the tutorial is active, right after
	# creating a Control/Node2D the tutorial content might reference by this
	# key. Safe to call even when the tutorial isn't running.
	if not is_active:
		return
	_targets[key] = node
	# ADDED: auto-unregister the instant this node starts leaving the tree --
	# without this, a key registered by a popup (e.g. "popup_close_button")
	# keeps pointing at that popup's freed button after it closes, until
	# something re-registers the SAME key later. Anything that queries it
	# in between gets a stale reference. CONNECT_ONE_SHOT means this never
	# needs manual cleanup.
	node.tree_exiting.connect(_on_target_node_exiting.bind(node, key), CONNECT_ONE_SHOT)


func _on_target_node_exiting(node: Node, key: String) -> void:
	# Only clear the entry if it STILL points at the exact node that's
	# exiting -- guards the rare case where the same key was already
	# re-registered to a newer node before this old one's exit fired.
	if _targets.get(key, null) == node:
		_targets.erase(key)


func unregister_target(key: String) -> void:
	_targets.erase(key)

func get_cell_offset_world_pos(unit_id: String, dx: int, dy: int) -> Variant:
	# Used for "cell_offset:<unit_id>:<dx>:<dy>" targets -- resolves to the
	# WORLD position of a cell relative to a unit's CURRENT grid position,
	# e.g. "point at the tile 2 squares right of the Dreadknight" for a
	# movement-step suggestion. Returns null if it can't be resolved yet.
	var unit := _resolve_unit_target(unit_id)
	if unit == null or _battle_manager_ref == null or _battle_manager_ref.grid == null:
		return null
	var target_cell: Vector2i = unit.grid_position + Vector2i(dx, dy)
	return _battle_manager_ref.grid.grid_to_world(target_cell)

func get_target_node(key: String) -> Node:
	if key.begins_with("unit:"):
		return _resolve_unit_target(key.substr(5))
	var node = _targets.get(key, null)
	if node != null and not is_instance_valid(node):
		_targets.erase(key)
		return null
	return node


func register_wait_for_check(condition_name: String, checker: Callable) -> void:
	# `wait_for` steps poll a named condition (e.g. "all_player_units_acted").
	# battle_manager.gd registers that one in its own _ready().
	_wait_for_checkers[condition_name] = checker


func try_consume(event: String, payload: Dictionary = {}) -> bool:
	# Returns true if the caller's action should be ALLOWED to proceed.
	# Returns false if it should be BLOCKED (a gate step is active and this
	# wasn't the required action).
	if not is_active:
		return true
	var step := get_current_step()
	if step.is_empty():
		return true
	if step.get("type", "gate") != "gate":
		return true   # narrate/wait_for/system_action steps don't gate real actions
	if step.get("advance_on", "") != event:
		return true   # this event isn't what THIS step cares about -- don't block unrelated input
	if not _payload_matches(step.get("advance_match", {}), payload):
		_nudge()
		return false
	_advance_to_next_step()
	return true


func advance() -> void:
	# Used by the overlay's "Continue" tap for narrate steps, and by
	# system_action steps once their action is done.
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
	# Poll on a short timer rather than requiring every possible caller to
	# remember to notify us -- these conditions (like "has everyone acted")
	# are cheap Array checks.
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
	# Called when the player clicks something the current gate step doesn't
	# allow. TutorialOverlay listens for this to play a quick "no, not that"
	# shake animation.
	EventBus.publish("tutorial_nudge", {})
