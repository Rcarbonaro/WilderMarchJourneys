# res://scripts/data_models/forging_recipe_data.gd
class_name ForgingRecipeData
extends RefCounted

var id: String = ""
var inputs: Array = []              # always exactly 2 basic-equipment subtypes
var output_equipment_id: String = ""

static func from_dict(data: Dictionary) -> ForgingRecipeData:
    var f := ForgingRecipeData.new()
    f.id = data.get("id", "")
    f.inputs = data.get("inputs", [])
    f.output_equipment_id = data.get("output_equipment_id", "")
    return f
