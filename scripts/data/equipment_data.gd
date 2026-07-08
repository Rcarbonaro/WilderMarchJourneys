# res://scripts/data/equipment_data.gd
#
# Base class for anything that can go in one of a unit's 3 equipment slots.
# BasicEquipmentData, AdvancedEquipmentData, and ConsumableData all extend this.

class_name EquipmentData
extends Resource

@export var id: String = ""
@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D
# Leave empty for the shop's automatic gray-box placeholder. Drag an image
# in later — no other changes needed. See the README for exact steps.
