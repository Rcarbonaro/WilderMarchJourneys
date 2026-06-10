# res://scripts/data/stats_data.gd

# 📤 EXPORTS TO: UnitData, EnemyData — every unit resource uses this to define their numbers

class_name StatsData

extends Resource

@export var hp: int = 10

@export var atk: int = 10

@export var matk: int = 0          # Magic Attack

@export var def: int = 5

@export var mdef: int = 5          # Magic Defense

@export var mov: int = 3           # Movement squares per turn

@export var crit_chance: float = 5.0   # Percentage, e.g. 5.0 = 5%

@export var crit_damage: float = 150.0 # Percentage, e.g. 150 = 1.5x damage

@export var mana: int = 0
