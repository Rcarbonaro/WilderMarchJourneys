# res://scripts/data/run_data.gd

# 📤 EXPORTS TO: ShopScene, EncounterScene, BattleManager — everything reads run state

# 📥 CALLS FROM: All major scenes update this when something changes

class_name RunData

extends Resource

@export var current_stage: int = 1        # 1 through 10

@export var gold: int = 10

@export var party: Array = []             # Array of UnitData resources (active 4)

@export var bench: Array = []             # Array of UnitData resources (bench, max 6)

@export var unit_levels: Dictionary = {}  # unit_data.id -> current level

@export var equipped_items: Dictionary = {} # unit_data.id -> Array[ItemData]

@export var tarot_cards: Array = []       # Array of TarotCardData resources

@export var difficulty: String = "normal"
