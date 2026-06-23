# res://scripts/data_models/scaling_rule_data.gd
class_name ScalingRuleData
extends RefCounted

var id: String = ""
var stage_index: int = 1
var base_modifiers: Array = []
var difficulty_modifiers: Dictionary = {}
var conditional_modifiers: Array = []

static func from_dict(data: Dictionary) -> ScalingRuleData:
    var s := ScalingRuleData.new()
    s.id = data.get("id", "")
    s.stage_index = data.get("stage_index", 1)
    s.base_modifiers = data.get("base_modifiers", [])
    s.difficulty_modifiers = data.get("difficulty_modifiers", {})
    s.conditional_modifiers = data.get("conditional_modifiers", [])
    return s
