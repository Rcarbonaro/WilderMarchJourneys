# res://scripts/data_models/tarot_card_data.gd
#
# Thin TYPED wrapper around a tarot card's JSON Dictionary, for editor
# autocomplete in code that wants it. ContentLoader/EffectSystem work
# directly with the raw Dictionary internally -- you only need this class
# if you're writing UI code that wants typed fields instead.
class_name TarotCardData
extends RefCounted

var id: String = ""
var name: String = ""
var description: String = ""
var category: String = "blessed"   # "blessed" | "cursed"
var rarity: String = "common"
var tags: Array = []
var stackable: bool = false
var max_stacks: int = 1
var effects: Array = []
var triggers: Array = []

static func from_dict(data: Dictionary) -> TarotCardData:
    var t := TarotCardData.new()
    t.id = data.get("id", "")
    t.name = data.get("name", "")
    t.description = data.get("description", "")
    t.category = data.get("category", "blessed")
    t.rarity = data.get("rarity", "common")
    t.tags = data.get("tags", [])
    t.stackable = data.get("stackable", false)
    t.max_stacks = data.get("max_stacks", 1)
    t.effects = data.get("effects", [])
    t.triggers = data.get("triggers", [])
    return t
