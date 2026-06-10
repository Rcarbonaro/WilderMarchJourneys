# res://scripts/data/tile_type_data.gd

# 📤 EXPORTS TO: MapData (the map grid uses these), BattleGrid (pathfinding reads movement cost)

class_name TileTypeData

extends Resource

@export var id: String = ""

@export var display_name: String = ""

@export var tile_texture: Texture2D

# Movement

@export var movement_cost: int = 1    # 1 = normal, 2 = difficult, 9999 = impassable

@export var is_wall: bool = false     # blocks LOS and movement entirely

@export var blocks_line_of_sight: bool = false

# Spawn use

@export var is_player_spawn: bool = false

@export var is_enemy_spawn: bool = false

@export var is_reinforcement_spawn: bool = false
