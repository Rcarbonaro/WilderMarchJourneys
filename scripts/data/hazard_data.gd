# res://scripts/data/hazard_data.gd

# 📤 EXPORTS TO: AbilityData (abilities spawn these), TileMap (tiles track active hazards)

class_name HazardData

extends Resource

@export var id: String = ""

@export var display_name: String = ""

@export var icon: Texture2D         # small visual shown on the tile

@export var duration_rounds: int = 2

@export var is_permanent: bool = false

# Damage

@export var damage_multiplier: float = 0.4

@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "hazard"

# When does it deal damage?

@export var trigger_on_enter: bool = true     # damages when enemy walks in

@export var trigger_on_start_of_turn: bool = true  # damages at start of enemy's turn

@export var trigger_on_end_of_turn: bool = false

# Does it apply a status?

@export var applies_status: StatusEffectData  # drag a .tres file here in Inspector
