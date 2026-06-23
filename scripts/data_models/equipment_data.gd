# res://scripts/data_models/equipment_data.gd
class_name EquipmentData
extends RefCounted

var id: String = ""
var name: String = ""
var description: String = ""
var type: String = "basic"      # "basic" | "advanced" | "consumable"
var subtype: String = ""
var tags: Array = []
var effects: Array = []
var stackable: bool = false
var consumable: bool = false

static func from_dict(data: Dictionary) -> EquipmentData:
    var e := EquipmentData.new()
    e.id = data.get("id", "")
    e.name = data.get("name", "")
    e.description = data.get("description", "")
    e.type = data.get("type", "basic")
    e.subtype = data.get("subtype", "")
    e.tags = data.get("tags", [])
    e.effects = data.get("effects", [])
    e.stackable = data.get("stackable", false)
    e.consumable = data.get("consumable", false)
    return e
