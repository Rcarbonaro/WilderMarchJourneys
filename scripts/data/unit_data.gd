# res://scripts/data/unit_data.gd

# 📤 EXPORTS TO: UnitNode (the actual game unit reads this), ShopManager (recruits use this)

# 📥 CALLS FROM: StatsData (embeds stats), AbilityData (lists abilities)

class_name UnitData

extends Resource

@export var id: String = ""

@export var display_name: String = ""

@export var description: String = ""

@export var portrait: Texture2D

@export var battle_sprite: Texture2D

@export var cost_gold: int = 3          # 📤 EXPORTS TO: ShopManager for purchase price

# Class identity

@export var class_name_label: String = ""

@export var synergy_tags: Array[String] = []  # e.g. ["Overkill", "Critical"]

# Stats PER LEVEL (index 0 = level 1, index 4 = level 5)

@export var stats_by_level: Array[StatsData] = []

# Abilities unlocked per level (Dictionary: level number -> AbilityData)

# Example: { 1: [basic_attack, enraged_strike], 2: [blood_fury], 3: [unstoppable_fury] }

@export var abilities_by_level: Dictionary = {}

# Rarity for shop weighting

@export_enum("common", "uncommon", "rare") var rarity: String = "common"

# Base stats

@export var base_stats: StatsData

# Ability

@export var starting_abilities: Array[AbilityData] = []

# Ensure this is at the top of unit_node.gd, outside any functions
@export var is_spellsword: bool = false
var has_arcana_charge: bool = false
