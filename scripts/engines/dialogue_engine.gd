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
	# Returns every choice on the CURRENT node that passes its CONDITIONS
	# (story flags, prior choices, etc. -- these still gate whether a choice
	# exists at all, unchanged from before: a condition-driven alternate
	# branch should stay fully hidden, not show up grayed out).
	#
	# BUGFIX: choices that fail their COST requirement (not enough gold, a
	# missing item) used to be filtered out here too, right alongside
	# condition failures -- so they just silently vanished instead of
	# showing up grayed out with an explanation. Those are included now,
	# with "_affordable" and "_unaffordable_reason" added onto a COPY of the
	# choice dict, so encounter_scene.gd can render them disabled with a
	# reason instead of hiding them.
	var node := get_current_node()
	var visible := []
	for choice in node.get("choices", []):
		var context := {"run_state": _run_state, "source": "dialogue"}
		if not EffectSystem.evaluate_conditions(choice.get("conditions", []), context):
			continue
		var choice_copy: Dictionary = choice.duplicate()
		var reason: String = _describe_unaffordable(choice.get("cost", null))
		choice_copy["_affordable"] = (reason == "")
		choice_copy["_unaffordable_reason"] = reason
		visible.append(choice_copy)
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
	return _describe_unaffordable(cost) == ""


func _describe_unaffordable(cost) -> String:
	# Returns "" when affordable. Otherwise a short, human-readable reason
	# ("lack 3 gold", "missing Iron Shield") meant to be shown right on a
	# grayed-out choice button.
	if cost == null:
		return ""
	match cost.get("type", "gold"):
		"gold":
			var amount: int = int(cost.get("amount", 0))
			var short_by: int = amount - _run_state.gold
			if short_by > 0:
				return "lack %d gold" % short_by
			return ""
		"equipment":
			var equipment_id: String = cost.get("equipment_id", "")
			if not _run_state.equipment_inventory.has(equipment_id):
				var item_name: String = ContentLoader.get_equipment(equipment_id).get("name", equipment_id)
				return "missing %s" % item_name
			return ""
		_:
			return ""


func _pay_cost(cost) -> void:
	if cost == null:
		return
	match cost.get("type", "gold"):
		"gold":
			_run_state.gold = max(0, _run_state.gold - int(cost.get("amount", 0)))
		"equipment":
			_run_state.equipment_inventory.erase(cost.get("equipment_id", ""))
		
