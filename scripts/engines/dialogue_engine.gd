# res://scripts/engines/dialogue_engine.gd
#
# DIALOGUE ENGINE -- walks through a dialogue_graph JSON one node at a time,
# evaluating which choices are currently visible/affordable, and applying
# their effects when chosen.

extends Node

var _graph: Dictionary = {}
var _current_node_id: String = ""
var _run_state: RunState = null


func start(graph_id: String, run_state: RunState) -> Dictionary:
	# Begins a dialogue graph. Returns the first node's display data (the
	# same shape as get_current_node()).
	_graph = ContentLoader.get_dialogue_graph(graph_id)
	_run_state = run_state
	if _graph.is_empty():
		push_warning("DialogueEngine: dialogue graph '" + graph_id + "' not found.")
		return {}
	_current_node_id = _graph.get("start_node", "start")
	return get_current_node()


func get_current_node() -> Dictionary:
	for node in _graph.get("nodes", []):
		if node.get("id", "") == _current_node_id:
			return node
	return {}


func get_visible_choices() -> Array:
	# Returns only the choices on the CURRENT node that pass their
	# conditions AND that the player can currently afford.
	var node := get_current_node()
	var visible := []
	for choice in node.get("choices", []):
		var context := {"run_state": _run_state, "source": "dialogue"}
		if not EffectSystem.evaluate_conditions(choice.get("conditions", []), context):
			continue
		if not _can_afford(choice.get("cost", null)):
			continue
		visible.append(choice)
	return visible


func choose(choice_id: String) -> Dictionary:
	# Applies a choice's cost and effects, advances to its next_node_id, and
	# returns a result Dictionary describing what happened:
	#   { "next_node_id": String|null, "leads_to_combat": bool, "combat_request": Dictionary|null }
	var node := get_current_node()
	var chosen_choice: Dictionary = {}
	for choice in node.get("choices", []):
		if choice.get("id", "") == choice_id:
			chosen_choice = choice
			break
	if chosen_choice.is_empty():
		push_warning("DialogueEngine: choice '" + choice_id + "' not found on current node.")
		return {}

	var context := {"run_state": _run_state, "source": "dialogue:" + choice_id}
	_pay_cost(chosen_choice.get("cost", null))
	EffectSystem.apply_effects(chosen_choice.get("effects", []), context)

	var next_id = chosen_choice.get("next_node_id", null)
	if next_id != null:
		_current_node_id = next_id

	return {
		"next_node_id": next_id,
		"leads_to_combat": chosen_choice.get("leads_to_combat", false),
		"combat_request": chosen_choice.get("combat_request", null),
	}


func _can_afford(cost) -> bool:
	if cost == null:
		return true
	match cost.get("type", "gold"):
		"gold":
			return _run_state.gold >= int(cost.get("amount", 0))
		"equipment":
			return _run_state.equipment_inventory.has(cost.get("equipment_id", ""))
		_:
			return true


func _pay_cost(cost) -> void:
	if cost == null:
		return
	match cost.get("type", "gold"):
		"gold":
			_run_state.gold = max(0, _run_state.gold - int(cost.get("amount", 0)))
		"equipment":
			_run_state.equipment_inventory.erase(cost.get("equipment_id", ""))
