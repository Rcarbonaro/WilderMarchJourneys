# res://scripts/data/encounter_data.gd

# 📤 EXPORTS TO: EncounterScene — scene reads this to display the event

class_name EncounterData

extends Resource

@export var id: String = ""

@export var title: String = ""

@export var description: String = ""

@export var background_image: Texture2D

# Each choice: { "text": String, "reward_gold": int, "reward_item": ItemData, "risk_description": String }

@export var choices: Array = []
