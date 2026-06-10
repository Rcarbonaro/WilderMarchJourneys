# res://scripts/battle/battle_grid.gd

# 📤 EXPORTS TO: BattleManager (combat reads tile data and unit positions from here)

# 📤 EXPORTS TO: PathfindingSystem (uses movement cost data to find valid moves)

# 📥 CALLS FROM: TileTypeData (each cell references a tile type resource)

extends Node2D

const GRID_WIDTH = 10

const GRID_HEIGHT = 10

const TILE_SIZE = 96  # pixels per tile — adjust for your art

# Stores which TileTypeData is in each grid cell

# Key: Vector2i(col, row), Value: TileTypeData resource

var tile_map: Dictionary = {}

# Stores which hazard (if any) is on each cell

# Key: Vector2i, Value: HazardInstance (see below)

var hazard_map: Dictionary = {}

# 📤 EXPORTS TO: UnitManager — units register their positions here

# Key: Vector2i, Value: UnitNode

var unit_positions: Dictionary = {}

# Called when the scene loads

func setup_grid(map_data: Dictionary) -> void:

	# map_data is a Dictionary: Vector2i -> TileTypeData

	# 📥 CALLS FROM: BattleManager which passes in the map layout

	tile_map = map_data

	_draw_tiles()

func _draw_tiles() -> void:

	# Draws each tile sprite on screen

	for cell in tile_map:

		var tile_type: TileTypeData = tile_map[cell]

		# Place a Sprite2D at the world position of this cell

		var sprite = Sprite2D.new()

		sprite.texture = tile_type.tile_texture

		sprite.position = grid_to_world(cell)

		$GroundLayer.add_child(sprite)

# Convert grid coordinates to screen pixel position

# 📤 EXPORTS TO: UnitNode, HazardVisual — anything that needs to know WHERE on screen a cell is

func grid_to_world(cell: Vector2i) -> Vector2:

	return Vector2(cell.x * TILE_SIZE + TILE_SIZE / 2.0,

				   cell.y * TILE_SIZE + TILE_SIZE / 2.0)

# Convert screen pixel position back to grid cell

func world_to_grid(world_pos: Vector2) -> Vector2i:

	return Vector2i(int(world_pos.x / TILE_SIZE), int(world_pos.y / TILE_SIZE))

# Is this cell within bounds?

func is_valid_cell(cell: Vector2i) -> bool:

	return cell.x >= 0 and cell.x < GRID_WIDTH and cell.y >= 0 and cell.y < GRID_HEIGHT

# Is this cell passable (not a wall, not occupied)?

# 📤 EXPORTS TO: PathfindingSystem — used to check if a cell can be walked through

func is_passable(cell: Vector2i) -> bool:

	if not is_valid_cell(cell): return false

	if not tile_map.has(cell): return false

	var tile: TileTypeData = tile_map[cell]

	if tile.is_wall: return false

	if unit_positions.has(cell): return false  # occupied by a unit

	return true

# Get movement cost of a cell

# 📤 EXPORTS TO: PathfindingSystem

func get_movement_cost(cell: Vector2i) -> int:

	if not tile_map.has(cell): return 9999

	return tile_map[cell].movement_cost

# Does this cell block line of sight?

func blocks_los(cell: Vector2i) -> bool:

	if not tile_map.has(cell): return false

	return tile_map[cell].blocks_line_of_sight or tile_map[cell].is_wall

# Register a unit at a cell (called when a unit moves)

# 📥 CALLS FROM: UnitNode when it moves

func register_unit(unit, cell: Vector2i) -> void:

	unit_positions[cell] = unit

# Unregister a unit from a cell

func unregister_unit(cell: Vector2i) -> void:

	unit_positions.erase(cell)

# Get the unit at a cell (returns null if empty)

# 📤 EXPORTS TO: AbilityExecutor — targeting checks who is on a cell

func get_unit_at(cell: Vector2i):

	return unit_positions.get(cell, null)
