# res://scripts/data_models/shop_entry_data.gd
class_name ShopEntryData
extends RefCounted

var id: String = ""
var item_type: String = "equipment"   # "equipment" | "unit" | "consumable"
var item_id: String = ""
var base_price: int = 0
var tags: Array = []
var conditions: Array = []
var spawn_weight: float = 1.0

static func from_dict(data: Dictionary) -> ShopEntryData:
    var s := ShopEntryData.new()
    s.id = data.get("id", "")
    s.item_type = data.get("item_type", "equipment")
    s.item_id = data.get("item_id", "")
    s.base_price = data.get("base_price", 0)
    s.tags = data.get("tags", [])
    s.conditions = data.get("conditions", [])
    s.spawn_weight = data.get("spawn_weight", 1.0)
    return s
