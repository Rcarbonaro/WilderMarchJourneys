# res://scripts/systems/encounter_engine.gd
#
# AUTOLOAD. Make sure ContentLoader, RunManager, EffectSystem are ABOVE it.
# Owns "which encounter/dialogue node are we currently looking at" and all
# logic for moving through a graph.

extends Node

const ENCOUNTER_FOLDER = "res://content/encounters/"
const DIALOGUE_FOLDER  = "res://content/dialogue/"

var current_encounter: Dictionary = {}
var current_graph: Dictionary = {}
var current_node_id: String = ""

var pending_combat_request: Dictionary = {}
# Set by choose() when a choice has leads_to_combat = true. Read by
# battle_manager.gd to spawn a FIXED enemy group, and by battle_scene.gd's
# _on_battle_ended to route back here instead of the normal flow.
# Shape: {"enemy_group_id": String, "victory_node_id": String, "defeat_node_id": String}


func pick_encounter_for_stage(stage_index: int) -> Dictionary:
	var pool: Array = []
	var dir = DirAccess.open(ENCOUNTER_FOLDER)
	if dir == null:
		printerr("❌ EncounterEngine: folder not found: ", ENCOUNTER_FOLDER)
		return {}

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			var data = ContentLoader.load_json(ENCOUNTER_FOLDER + file_name)
			if data != null and _encounter_is_eligible(data, stage_index):
				pool.append(data)
		file_name = dir.get_next()

	if pool.is_empty():
		printerr("⚠️ EncounterEngine: no eligible encounters for stage ", stage_index)
		return {}
	return pool[randi() % pool.size()]


func _encounter_is_eligible(data: Dictionary, stage_index: int) -> bool:
	if stage_index < data.get("stage_min", 1):
		return false
	if stage_index > data.get("stage_max", 30):
		return false
	if data.get("once_per_run", false) and RunManager.has_flag("completed_" + data.get("id", "")):
		return false
	for flag in data.get("flags_required", []):
		if not RunManager.has_flag(flag):
			return false
	for flag in data.get("flags_blocked", []):
		if RunManager.has_flag(flag):
			return false
	return true


func start_encounter(stage_index: int) -> bool:
	var encounter = pick_encounter_for_stage(stage_index)
	if encounter.is_empty():
		return false

	current_encounter = encounter
	var graph = ContentLoader.load_json(DIALOGUE_FOLDER + encounter.get("dialogue_graph_id", "") + ".json")
	if graph == null:
		printerr("❌ EncounterEngine: dialogue graph not found: ", encounter.get("dialogue_graph_id", ""))
		current_encounter = {}
		return false

	current_graph = graph
	current_node_id = graph.get("start_node", "start")
	return true


func get_current_node() -> Dictionary:
	for node in current_graph.get("nodes", []):
		if node.get("id", "") == current_node_id:
			return node
	return {}


func choose(choice: Dictionary) -> void:
	var cost: Dictionary = choice.get("cost", {})
	if cost.get("type", "") == "gold":
		if not RunManager.spend_gold(int(cost.get("amount", 0))):
			print("⛔ Not enough gold for this choice.")
			return

	for effect in choice.get("effects", []):
		EffectSystem.apply_effect(effect)

	if choice.get("leads_to_combat", false):
		var request = choice.get("combat_request", {})
		pending_combat_request = {
			"enemy_group_id": request.get("enemy_group_id", ""),
			"victory_node_id": choice.get("victory_node_id", ""),
			"defeat_node_id": choice.get("defeat_node_id", ""),
		}
		return

	var next_id = choice.get("next_node_id", "")
	if next_id != null and next_id != "":
		current_node_id = next_id


func complete_encounter() -> void:
	if current_encounter.get("once_per_run", false):
		RunManager.set_flag("completed_" + current_encounter.get("id", ""))
	for effect in current_encounter.get("rewards", []):
		EffectSystem.apply_effect(effect)
	RunManager.save_run()


func resolve_combat_result(victory: bool) -> void:
	var target_node: String = pending_combat_request.get("victory_node_id", "") if victory else pending_combat_request.get("defeat_node_id", "")
	pending_combat_request = {}

	if not victory and target_node == "":
		# No defeat_node_id authored — normal Game Over (default).
		get_tree().change_scene_to_file("res://scenes/meta/GameOverScreen.tscn")
		return

	if target_node == "":
		complete_encounter()
		current_encounter = {}
		RunManager.mark_stage_content_completed()
		get_tree().change_scene_to_file("res://scenes/deployment/DeploymentScene.tscn")
		return

	current_node_id = target_node
	get_tree().change_scene_to_file("res://scenes/encounter/EncounterScene.tscn")
