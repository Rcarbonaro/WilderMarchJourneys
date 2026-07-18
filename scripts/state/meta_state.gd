# res://scripts/state/meta_state.gd
#
# META STATE -- progress that persists ACROSS runs: which difficulties are
# unlocked, achievements earned, and snapshots of fully-built teams saved
# for Endless Abyss mode.

class_name MetaState
extends Resource

@export var player_id: String = ""
@export var difficulty_unlocks: Dictionary = {"normal": true, "hard": true, "nightmare": true}
@export var achievements: Array[String] = []
@export var endless_teams: Array = []
# Each entry: { "team_name": "...", "units": [ <full unit save Dictionary>, ... ], "created_from_run": "run_id" }
# NOTE: "units" stores a full DEEP COPY of each unit's save data (unit_id,
# level, equipped_item_ids, permanent_modifiers) -- not just an id string --
# so the snapshot keeps working even after the original run ends or its
# party changes further. This is how a finished Nightmare run's fully-built
# team gets carried into Endless Abyss.
@export var settings: Dictionary = {"volume": 0.8, "font_size": 14}


func save_endless_team(run_state: RunState, team_name: String) -> void:
	# Snapshots the run's CURRENT party + bench into a reusable Endless
	# Abyss team. Call this when a run is won (wherever your "run complete"
	# logic lives) so the player's fully-built team is available afterward.
	var snapshot := []
	for unit_entry in run_state.party:
		snapshot.append(unit_entry.duplicate(true))   # deep copy, fully decoupled
	for unit_entry in run_state.bench:
		snapshot.append(unit_entry.duplicate(true))
	endless_teams.append({
		"team_name": team_name, "units": snapshot, "created_from_run": run_state.run_id,
	})


func unlock_difficulty(difficulty: String) -> void:
	difficulty_unlocks[difficulty] = true


func to_dict() -> Dictionary:
	return {
		"player_id": player_id, "difficulty_unlocks": difficulty_unlocks,
		"achievements": achievements, "endless_teams": endless_teams,
		"settings": settings,
	}


static func from_dict(data: Dictionary) -> MetaState:
	var ms := MetaState.new()
	ms.player_id = data.get("player_id", "")
	ms.difficulty_unlocks = data.get("difficulty_unlocks", {"normal": true, "hard": false, "nightmare": false})
	ms.achievements.assign(data.get("achievements", []))
	ms.endless_teams = data.get("endless_teams", [])
	ms.settings = data.get("settings", {"volume": 0.8, "font_size": 14})
	return ms
