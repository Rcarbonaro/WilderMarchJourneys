# res://scripts/data_models/dialogue_node_data.gd
class_name DialogueNodeData
extends RefCounted

var id: String = ""
var text: String = ""
var image: String = ""
var conditions: Array = []
var choices: Array = []   # left as raw Dictionaries -- choices have enough
                           # variety (cost/conditions/effects/combat_request)
                           # that a typed sub-class per choice isn't worth it.

static func from_dict(data: Dictionary) -> DialogueNodeData:
    var n := DialogueNodeData.new()
    n.id = data.get("id", "")
    n.text = data.get("text", "")
    n.image = data.get("image", "")
    n.conditions = data.get("conditions", [])
    n.choices = data.get("choices", [])
    return n
