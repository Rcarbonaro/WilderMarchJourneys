# res://scripts/data/wave_entry_data.gd
#
# One line item in a reinforcement wave: which enemy, how many.
class_name WaveEntryData
extends Resource

@export var unit_data: UnitData
@export var count: int = 1
@export var level: int = 1
