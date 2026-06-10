# res://scripts/data/ability_data.gd

# 📤 EXPORTS TO: UnitData (units have a list of these), AbilityExecutor (runs the ability logic)

class_name AbilityData

extends Resource

@export var id: String = ""

@export var display_name: String = ""

@export var description: String = ""

@export var icon: Texture2D

# --- COST ---

@export var mana_cost: int = 0

@export var hp_cost_percent: float = 0.0     # e.g. 0.2 = costs 20% of max HP

@export var charge_cost: int = 0             # for abilities that use charges

@export var custom_resource_cost: int = 0    # Rage, Panache, Trick Shots, etc.

@export var custom_resource_name: String = "" # Name of that resource (e.g. "Rage")

# --- COOLDOWN ---

@export var cooldown_rounds: int = 0   # 0 = no cooldown

# --- TARGETING ---

@export var min_range: int = 0

@export var max_range: int = 1

@export var requires_line_of_sight: bool = true

@export var can_ignore_los: bool = false  # some spells bypass LOS

# --- AREA OF EFFECT ---

@export_enum("single", "line", "cone", "square", "cross") var aoe_shape: String = "single"

@export var aoe_size: int = 1  # radius or length depending on shape

# --- DAMAGE ---

@export var base_damage_multiplier: float = 1.0

@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "physical"

@export var scaling_stat: String = "atk"  # "atk" or "matk"

@export var hits: int = 1                 # for multi-hit abilities

# --- EFFECTS ---

# Status effects this ability applies to the target

@export var applies_statuses: Array[StatusEffectData] = []

# Hazard this ability creates on target tile

@export var spawns_hazard: HazardData

# Movement (push/pull): negative = pull toward caster, positive = push away

@export var displacement_squares: int = 0

# Heal: fraction of max HP to restore to target

@export var heal_percent: float = 0.0

# --- TAGS ---

# Used for synergy checks. Add strings like "Fire", "Combo", "Hazard"

@export var tags: Array[String] = []

# --- ABILITY TYPE ---

@export_enum("basic_attack", "ability", "spell", "passive") var ability_type: String = "ability"

@export var is_counterattack_immune: bool = false  # if true, target cannot counter
