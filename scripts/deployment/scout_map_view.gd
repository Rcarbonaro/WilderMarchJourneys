# res://scripts/ui/scout_map_view.gd
#
# SCOUT MAP VIEW -- a small, read-only visual rendering of a stage's tile
# map + enemy/ally spawn cells, used by DeploymentScene's Scout Ahead panel.
# Draws a simple colored-grid preview (not your real tile art -- just plain
# rects/circles) so the player can see the actual layout and where enemies
# will be before committing, with zero dependency on any specific tileset
# texture existing or matching up.
#
# SCENE SETUP: a Control node with this script attached. custom_minimum_size
# is set automatically in setup() based on the stage's actual grid
# dimensions, so you don't need to size it by hand -- just give it room in
# whatever container holds it (a ScrollContainer works well if the grid ends
# up bigger than the panel).

extends Control
class_name ScoutMapView

const CELL_SIZE := 18.0
const GAP := 1.0

var _tile_map: Dictionary = {}
var _ally_cells: Array = []
var _enemy_cells: Array = []
var _blocking_features: Array = []   # Array[{"cell": Vector2i, "feature": MapFeatureData}], "blocking" category only
var _grid_width: int = 0
var _grid_height: int = 0


func setup(content: Dictionary) -> void:
	_tile_map = content.get("tile_map", {})
	_ally_cells = content.get("ally_cells", [])
	_enemy_cells = content.get("enemy_cells", [])

	# BUGFIX: feature_placements was already present in 'content' (stage_
	# director.gd's get_or_generate_stage_content() puts it there) but this
	# script never read it at all, so the scout preview never showed any map
	# features -- not even ones that actually block movement, which is the
	# single most important thing to know before committing to a fight. Only
	# "blocking" features are kept here on purpose -- "slowing" and
	# "decoration" features don't change where a unit can stand/path through,
	# so showing them would just clutter the preview with irrelevant detail.
	_blocking_features = []
	for placement in content.get("feature_placements", []):
		var feature: MapFeatureData = placement.get("feature")
		if feature != null and feature.category == "blocking":
			_blocking_features.append(placement)

	_grid_width = 0
	_grid_height = 0
	for cell in _tile_map.keys():
		_grid_width = max(_grid_width, cell.x + 1)
		_grid_height = max(_grid_height, cell.y + 1)

	custom_minimum_size = Vector2(
		_grid_width * (CELL_SIZE + GAP),
		_grid_height * (CELL_SIZE + GAP)
	)
	queue_redraw()


func _draw() -> void:
	if _tile_map.is_empty():
		return

	for y in range(_grid_height):
		for x in range(_grid_width):
			var cell := Vector2i(x, y)
			var pos := Vector2(x * (CELL_SIZE + GAP), y * (CELL_SIZE + GAP))
			var color := Color(0.15, 0.15, 0.15)   # fallback for any ungenerated cell

			if _tile_map.has(cell):
				var tile: TileTypeData = _tile_map[cell]
				if tile.is_wall:
					color = Color(0.35, 0.35, 0.38)          # wall
				elif tile.movement_cost > 1 and tile.blocks_line_of_sight:
					color = Color(0.45, 0.32, 0.2)           # slows + blocks sight
				elif tile.movement_cost > 1:
					color = Color(0.55, 0.5, 0.25)           # slows movement
				elif tile.blocks_line_of_sight:
					color = Color(0.25, 0.3, 0.35)           # blocks sight only
				else:
					color = Color(0.2, 0.45, 0.25)           # clear ground

			draw_rect(Rect2(pos, Vector2(CELL_SIZE, CELL_SIZE)), color)

	# Blocking map features (trees, rocks, etc.) -- drawn on top of the base
	# tile grid but BELOW the ally/enemy markers, same stacking order as
	# battle_grid.gd's real FeatureLayer (above ground, below units).
	for placement in _blocking_features:
		_draw_blocking_feature(placement)

	for cell in _ally_cells:
		_draw_marker(cell, Color(0.25, 0.55, 1.0))   # blue = your squad

	for cell in _enemy_cells:
		_draw_marker(cell, Color(0.9, 0.2, 0.2))     # red = enemy


func _draw_marker(cell: Vector2i, color: Color) -> void:
	var pos := Vector2(cell.x * (CELL_SIZE + GAP), cell.y * (CELL_SIZE + GAP))
	var center := pos + Vector2(CELL_SIZE, CELL_SIZE) * 0.5
	draw_circle(center, CELL_SIZE * 0.35, color)


func _draw_blocking_feature(placement: Dictionary) -> void:
	# Same red tint battle_grid.gd's _spawn_feature_visual() uses as its
	# placeholder for category == "blocking", so a scouted map "looks like"
	# what you'll actually see once you're in the real fight.
	const BLOCKING_COLOR := Color(0.8, 0.2, 0.2)
	var anchor_cell: Vector2i = placement.get("cell", Vector2i.ZERO)
	var feature: MapFeatureData = placement.get("feature")
	if feature == null:
		return

	# A feature can cover more than one tile (see MapFeatureData.footprint) --
	# draw a marker on every cell it actually occupies, not just its anchor.
	var footprint: Array = feature.footprint if not feature.footprint.is_empty() else [Vector2i.ZERO]
	for offset in footprint:
		var cell: Vector2i = anchor_cell + offset
		if cell.x < 0 or cell.y < 0 or cell.x >= _grid_width or cell.y >= _grid_height:
			continue   # Off the scouted grid -- nothing to draw.
		var pos := Vector2(cell.x * (CELL_SIZE + GAP), cell.y * (CELL_SIZE + GAP))
		# A slightly inset square (rather than a full-tile fill) so it reads
		# as "an obstacle sitting on this tile" without hiding the terrain
		# color underneath it.
		var inset := CELL_SIZE * 0.15
		draw_rect(Rect2(pos + Vector2(inset, inset), Vector2(CELL_SIZE - inset * 2, CELL_SIZE - inset * 2)), BLOCKING_COLOR)
		
