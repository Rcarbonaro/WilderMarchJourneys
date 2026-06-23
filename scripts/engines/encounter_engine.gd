# res://scripts/engines/encounter_engine.gd
#
# ENCOUNTER ENGINE -- picks a random valid encounter for the current
# stage/biome, then delegates the actual back-and-forth to DialogueEngine.
#
# DESIGN NOTE: an Encounter's JSON has NO top-level "rewards" or
# "combat_request" field -- those live entirely inside its dialogue graph
# (one per choice), so there's exactly one source of truth for "what does
# picking this choice actually do".

extends Node

# If DialogueEngine is registered as its own autoload in your project
# instead, just reference that autoload directly here and delete this line.

var _active_encounter_id: String = ""


func pick_encounter(run_state: RunState) -> String:
	# Returns an encounter id chosen at random (weighted by spawn_weight,
	# equal weight if unspecified) from every encounter valid for the
	# current biome/stage/flags.
	var biome := ""
	if run_state.biome_sequence.size() > 0:
		biome = run_state.biome_sequence[ContentLoader.get_biome_slot(run_state.stage_index)]

	var candidates := []
	var weights := []
	for id in ContentLoader.encounters:
		var enc = ContentLoader.encounters[id]
		if enc.get("once_per_run", false) and run_state.encounters_completed.has(id):
			continue
		var biomes: Array = enc.get("biomes", [])
		if biomes.size() > 0 and not biomes.has(biome):
			continue
		if run_state.stage_index < int(enc.get("stage_min", 1)):
			continue
		if run_state.stage_index > int(enc.get("stage_max", 999)):
			continue
		var blocked := false
		for flag in enc.get("flags_blocked", []):
			if run_state.flags.has(flag):
				blocked = true
				break
		if blocked:
			continue
		var has_required := true
		for flag in enc.get("flags_required", []):
			if not run_state.flags.has(flag):
				has_required = false
				break
		if not has_required:
			continue
		candidates.append(id)
		weights.append(float(enc.get("spawn_weight", 1.0)))

	if candidates.is_empty():
		return ""
	return candidates[_weighted_pick(weights)]


func start_encounter(encounter_id: String, run_state: RunState) -> Dictionary:
	_active_encounter_id = encounter_id
	var encounter := ContentLoader.get_encounter(encounter_id)
	EventBus.publish(EventBus.ON_ENCOUNTER_START, {"encounter_id": encounter_id})
	return DialogueEngine.start(encounter.get("dialogue_graph_id", ""), run_state)

func complete_encounter(run_state: RunState) -> void:
	if _active_encounter_id == "":
		return
	var encounter := ContentLoader.get_encounter(_active_encounter_id)
	for flag in encounter.get("flags_set_on_completion", []):
		if not run_state.flags.has(flag):
			run_state.flags.append(flag)
	if not run_state.encounters_completed.has(_active_encounter_id):
		run_state.encounters_completed.append(_active_encounter_id)
	EventBus.publish(EventBus.ON_ENCOUNTER_END, {"encounter_id": _active_encounter_id})
	_active_encounter_id = ""


func _weighted_pick(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return randi() % weights.size()
	var roll := randf() * total
	var cumulative := 0.0
	for i in range(weights.size()):
		cumulative += weights[i]
		if roll <= cumulative:
			return i
	return weights.size() - 1
