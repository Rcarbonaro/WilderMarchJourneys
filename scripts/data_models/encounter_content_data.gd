# res://scripts/data_models/encounter_content_data.gd
#
# Typed wrapper for an Encounter content file. NOTE: named "...ContentData"
# rather than "EncounterData" because res://scripts/data/encounter_data.gd
# already uses that class_name in the existing project -- this is meant to
# eventually replace it, but is kept under a different name to avoid a
# class_name collision until you're ready to delete the old one.
class_name EncounterContentData
extends RefCounted

var id: String = ""
var title: String = ""
var description: String = ""
var biomes: Array = []
var stage_min: int = 1
var stage_max: int = 30
var spawn_weight: float = 1.0
var flags_required: Array = []
var flags_blocked: Array = []
var flags_set_on_completion: Array = []
var dialogue_graph_id: String = ""
var once_per_run: bool = false

static func from_dict(data: Dictionary) -> EncounterContentData:
    var e := EncounterContentData.new()
    e.id = data.get("id", "")
    e.title = data.get("title", "")
    e.description = data.get("description", "")
    e.biomes = data.get("biomes", [])
    e.stage_min = data.get("stage_min", 1)
    e.stage_max = data.get("stage_max", 30)
    e.spawn_weight = data.get("spawn_weight", 1.0)
    e.flags_required = data.get("flags_required", [])
    e.flags_blocked = data.get("flags_blocked", [])
    e.flags_set_on_completion = data.get("flags_set_on_completion", [])
    e.dialogue_graph_id = data.get("dialogue_graph_id", "")
    e.once_per_run = data.get("once_per_run", false)
    return e
