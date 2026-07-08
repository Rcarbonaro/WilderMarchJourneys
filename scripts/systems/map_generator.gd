# res://scripts/systems/map_generator.gd
#
# AUTOLOAD. Builds the tile_map Dictionary battle_grid.gd already knows how
# to read (Vector2i -> TileTypeData), plus suggested spawn cells for allies
# and enemies. Also spawns obstacle SPRITES into their own visual layer.
#
# PLACEMENT (random maps): allies as a compact CLUSTER in the left portion;
# enemies scattered more loosely in the right portion, each guaranteed at
# least min_ally_enemy_distance tiles (Manhattan) from every ally cell. After
# obstacles are placed, a BFS reachability check confirms every enemy is
# reachable from the ally cluster — if not, the whole map is regenerated (up
# to max_generation_attempts times).
#
# FIXED LAYOUT (boss arenas): if BiomeMapConfig.use_fixed_layout is true,
# skips all the random logic below and places exactly what that resource
# specifies instead — see the README for how to author one.

extends Node

const CONFIG_PATH = "res://content/map_gen/map_density_config.json"

var _config: Dictionary = {}

var last_ally_cells: Array = []
var last_enemy_cells: Array = []


func _ready() -> void:
	_reload_config()


func _reload_config() -> void:
	var loaded = ContentLoader.load_json(CONFIG_PATH, false)
	if loaded == null:
		printerr("❌ MapGenerator: could not load map_density_config.json — using fallback defaults.")
		_config = {
			"min_density": 0.15, "max_density": 0.65, "center_bias_strength": 2.0,
			"min_ally_enemy_distance": 5, "max_generation_attempts": 20,
			"default_ally_count": 4, "default_enemy_count": 10
		}
	else:
		_config = loaded


# ── PUBLIC ENTRY POINT ─────────────────────────────────────────────────────────

func generate_map(biome_config: BiomeMapConfig, ally_count: int = -1, enemy_count: int = -1) -> Dictionary:
	if ally_count == -1:
		ally_count = _config.get("default_ally_count", 4)
	if enemy_count == -1:
		enemy_count = _config.get("default_enemy_count", 10)

	var max_attempts: int = _config.get("max_generation_attempts", 20)

	for attempt in range(max_attempts):
		var result = _try_generate_once(biome_config, ally_count, enemy_count)
		if result != null:
			last_ally_cells  = result["ally_cells"]
			last_enemy_cells = result["enemy_cells"]
			print("🗺️ Map generated successfully on attempt ", attempt + 1)
			return result

	printerr("⚠️ MapGenerator: all ", max_attempts, " attempts failed — falling back to an obstacle-free map.")
	var fallback = _build_empty_layout(biome_config, ally_count, enemy_count)
	last_ally_cells  = fallback["ally_cells"]
	last_enemy_cells = fallback["enemy_cells"]
	return fallback


func _try_generate_once(biome_config: BiomeMapConfig, ally_count: int, enemy_count: int):
	if biome_config.use_fixed_layout:
		return _try_generate_fixed_layout(biome_config, ally_count, enemy_count)

	var width  = biome_config.width
	var height = biome_config.height
	var min_distance: int = _config.get("min_ally_enemy_distance", 5)

	var tile_map: Dictionary = _build_ground_layer(biome_config, width, height)

	var ally_cells = _pick_ally_cluster(width, height, ally_count)
	if ally_cells.size() < ally_count:
		return null

	var enemy_cells = _pick_enemy_cells(width, height, enemy_count, ally_cells, min_distance)
	if enemy_cells.size() < enemy_count:
		return null

	var density = _roll_weighted_density()
	var eligible_cells = _get_eligible_cells(width, height, ally_cells, enemy_cells)
	var obstacle_placements = _place_obstacles(eligible_cells, tile_map, biome_config, density, width, height)

	if not _validate_reachability(tile_map, ally_cells, enemy_cells, width, height):
		return null

	_spawn_obstacle_visuals(obstacle_placements)
	return {"tile_map": tile_map, "ally_cells": ally_cells, "enemy_cells": enemy_cells}


func _try_generate_fixed_layout(biome_config: BiomeMapConfig, ally_count: int, enemy_count: int):
	var width = biome_config.width
	var height = biome_config.height
	var tile_map = _build_ground_layer(biome_config, width, height)

	var ally_cells: Array
	if biome_config.fixed_ally_anchor != Vector2i(-1, -1):
		ally_cells = _pick_ally_cluster_at(biome_config.fixed_ally_anchor, ally_count)
	else:
		ally_cells = _pick_ally_cluster(width, height, ally_count)

	var enemy_cells: Array
	if not biome_config.fixed_enemy_cells.is_empty():
		enemy_cells = biome_config.fixed_enemy_cells.duplicate()
	else:
		enemy_cells = _pick_enemy_cells(width, height, enemy_count, ally_cells, 1)

	var placements: Array = []
	if biome_config.fixed_obstacle_cells.size() == biome_config.fixed_obstacle_ids.size():
		for i in range(biome_config.fixed_obstacle_cells.size()):
			var cell = biome_config.fixed_obstacle_cells[i]
			var asset = _find_asset_by_id(biome_config, biome_config.fixed_obstacle_ids[i])
			if asset == null:
				continue
			var base_ground: TileTypeData = tile_map.get(cell)
			var overridden := TileTypeData.new()
			overridden.tile_texture = base_ground.tile_texture if base_ground != null else null
			overridden.is_wall = asset.is_wall
			overridden.movement_cost = 9999 if asset.is_wall else asset.movement_cost
			overridden.blocks_line_of_sight = asset.blocks_line_of_sight
			tile_map[cell] = overridden
			placements.append({"cells": [cell], "asset": asset})
	else:
		printerr("⚠️ MapGenerator: fixed_obstacle_cells/fixed_obstacle_ids length mismatch — skipping obstacles.")

	if not _validate_reachability(tile_map, ally_cells, enemy_cells, width, height):
		printerr("⚠️ MapGenerator: this fixed layout FAILS reachability — check your ",
				 "fixed_obstacle_cells/fixed_ally_anchor/fixed_enemy_cells for mistakes.")
		return null

	_spawn_obstacle_visuals(placements)
	return {"tile_map": tile_map, "ally_cells": ally_cells, "enemy_cells": enemy_cells}


func _pick_ally_cluster_at(anchor: Vector2i, ally_count: int) -> Array:
	var shapes = {
		1: [Vector2i(0, 0)], 2: [Vector2i(0, 0), Vector2i(0, 1)],
		3: [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		4: [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
	}
	var shape: Array = shapes.get(min(ally_count, 4), shapes[4])
	var cells: Array = []
	for offset in shape:
		cells.append(anchor + offset)
	return cells


func _find_asset_by_id(biome_config: BiomeMapConfig, asset_id: String) -> MapAssetData:
	for asset in biome_config.obstacle_pool:
		if asset.id == asset_id:
			return asset
	return null


# ── STEP 1: GROUND LAYER ───────────────────────────────────────────────────────

func _build_ground_layer(biome_config: BiomeMapConfig, width: int, height: int) -> Dictionary:
	var tile_map: Dictionary = {}
	var pool: Array = biome_config.ground_tile_pool

	var fallback_tile: TileTypeData = null
	if pool.is_empty():
		fallback_tile = TileTypeData.new()
		fallback_tile.id = "placeholder_ground"
		fallback_tile.movement_cost = 1
		fallback_tile.is_wall = false
		fallback_tile.blocks_line_of_sight = false
		fallback_tile.tile_texture = _get_placeholder_texture(Color(0.5, 0.5, 0.5))

	for x in range(width):
		for y in range(height):
			if pool.is_empty():
				tile_map[Vector2i(x, y)] = fallback_tile
			else:
				tile_map[Vector2i(x, y)] = pool[randi() % pool.size()]

	return tile_map


# ── STEP 2: ALLY CLUSTER ───────────────────────────────────────────────────────

func _pick_ally_cluster(width: int, height: int, ally_count: int) -> Array:
	var shapes = {
		1: [Vector2i(0, 0)],
		2: [Vector2i(0, 0), Vector2i(0, 1)],
		3: [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		4: [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
	}
	var shape: Array = shapes.get(min(ally_count, 4), shapes[4])

	var max_anchor_x = max(1, int(width * 0.25))
	var max_anchor_y = max(1, height - 2)
	var anchor = Vector2i(randi_range(1, max_anchor_x), randi_range(0, max_anchor_y))

	var cells: Array = []
	for offset in shape:
		var cell = anchor + offset
		if cell.x < 0 or cell.x >= width or cell.y < 0 or cell.y >= height:
			return []
		cells.append(cell)
	return cells


# ── STEP 3: ENEMY SCATTER ──────────────────────────────────────────────────────

func _pick_enemy_cells(width: int, height: int, enemy_count: int,
					   ally_cells: Array, min_distance: int) -> Array:
	var enemy_cells: Array = []
	var min_enemy_x = int(width * 0.5)

	var tries = 0
	var max_tries = enemy_count * 40
	while enemy_cells.size() < enemy_count and tries < max_tries:
		tries += 1
		var candidate = Vector2i(randi_range(min_enemy_x, width - 1), randi_range(0, height - 1))

		if candidate in enemy_cells:
			continue

		var far_enough = true
		for ally_cell in ally_cells:
			var dist = abs(candidate.x - ally_cell.x) + abs(candidate.y - ally_cell.y)
			if dist < min_distance:
				far_enough = false
				break
		if far_enough:
			enemy_cells.append(candidate)

	return enemy_cells


# ── STEP 4: DENSITY ROLL ────────────────────────────────────────────────────────

func _roll_weighted_density() -> float:
	var min_d: float = _config.get("min_density", 0.15)
	var max_d: float = _config.get("max_density", 0.65)
	var t = (randf() + randf() + randf()) / 3.0
	return lerp(min_d, max_d, t)


# ── STEP 5: ELIGIBLE CELLS ─────────────────────────────────────────────────────

func _get_eligible_cells(width: int, height: int, ally_cells: Array, enemy_cells: Array) -> Array:
	var eligible: Array = []
	for x in range(width):
		for y in range(height):
			var cell = Vector2i(x, y)
			if cell in ally_cells or cell in enemy_cells:
				continue
			eligible.append(cell)
	return eligible


# ── STEP 6: OBSTACLE PLACEMENT ─────────────────────────────────────────────────

func _place_obstacles(eligible_cells: Array, tile_map: Dictionary,
					  biome_config: BiomeMapConfig, density: float,
					  width: int, height: int) -> Array:
	var placements: Array = []
	if biome_config.obstacle_pool.is_empty():
		return placements

	var target_count: int = int(eligible_cells.size() * density)
	var center = Vector2(width / 2.0, height / 2.0)
	var max_dist = center.length()
	var bias: float = _config.get("center_bias_strength", 2.0)

	var scored_cells: Array = []
	for cell in eligible_cells:
		var dist_from_center = Vector2(cell.x, cell.y).distance_to(center)
		var normalized = 1.0 - clamp(dist_from_center / max_dist, 0.0, 1.0)
		var weight = 1.0 + bias * normalized
		var score = pow(randf(), 1.0 / weight)
		scored_cells.append({"cell": cell, "score": score})
	scored_cells.sort_custom(func(a, b): return a["score"] > b["score"])

	var used_cells: Dictionary = {}
	var placed_count = 0

	for entry in scored_cells:
		if placed_count >= target_count:
			break
		var anchor: Vector2i = entry["cell"]
		if used_cells.has(anchor):
			continue

		var asset: MapAssetData = _pick_weighted_asset(biome_config)
		if asset == null:
			continue

		var footprint_cells: Array = []
		var fits = true
		for offset in asset.footprint:
			var fc = anchor + offset
			if fc.x < 0 or fc.x >= width or fc.y < 0 or fc.y >= height or used_cells.has(fc):
				fits = false
				break
			footprint_cells.append(fc)
		if not fits:
			continue

		for fc in footprint_cells:
			var base_ground: TileTypeData = tile_map.get(fc)
			var overridden := TileTypeData.new()
			overridden.id = base_ground.id + "_" + asset.id if base_ground != null else asset.id
			overridden.tile_texture = base_ground.tile_texture if base_ground != null else null
			overridden.is_wall = asset.is_wall
			overridden.movement_cost = 9999 if asset.is_wall else asset.movement_cost
			overridden.blocks_line_of_sight = asset.blocks_line_of_sight
			tile_map[fc] = overridden
			used_cells[fc] = true

		placements.append({"cells": footprint_cells, "asset": asset})
		placed_count += footprint_cells.size()

	return placements


func _pick_weighted_asset(biome_config: BiomeMapConfig) -> MapAssetData:
	var pool = biome_config.obstacle_pool
	var weights = biome_config.obstacle_weights
	if pool.is_empty():
		return null
	if weights.size() != pool.size():
		printerr("⚠️ MapGenerator: obstacle_pool and obstacle_weights are different ",
				 "lengths on a BiomeMapConfig — falling back to equal weighting.")
		return pool[randi() % pool.size()]

	var total_weight = 0.0
	for w in weights:
		total_weight += w
	var roll = randf() * total_weight
	var running = 0.0
	for i in range(pool.size()):
		running += weights[i]
		if roll <= running:
			return pool[i]
	return pool[pool.size() - 1]


# ── STEP 7: REACHABILITY VALIDATION ────────────────────────────────────────────

func _validate_reachability(tile_map: Dictionary, ally_cells: Array, enemy_cells: Array,
							width: int, height: int) -> bool:
	var visited: Dictionary = {}
	var frontier: Array = []
	for cell in ally_cells:
		visited[cell] = true
		frontier.append(cell)

	while frontier.size() > 0:
		var current: Vector2i = frontier.pop_front()
		var neighbors = [
			current + Vector2i(1, 0), current + Vector2i(-1, 0),
			current + Vector2i(0, 1), current + Vector2i(0, -1)
		]
		for n in neighbors:
			if n.x < 0 or n.x >= width or n.y < 0 or n.y >= height:
				continue
			if visited.has(n):
				continue
			var tile: TileTypeData = tile_map.get(n)
			if tile != null and tile.is_wall:
				continue
			visited[n] = true
			frontier.append(n)

	for enemy_cell in enemy_cells:
		if not visited.has(enemy_cell):
			return false
	return true


# ── FALLBACK ──────────────────────────────────────────────────────────────────

func _build_empty_layout(biome_config: BiomeMapConfig, ally_count: int, enemy_count: int) -> Dictionary:
	var width  = biome_config.width
	var height = biome_config.height
	var tile_map = _build_ground_layer(biome_config, width, height)
	var ally_cells = _pick_ally_cluster(width, height, ally_count)
	var enemy_cells = _pick_enemy_cells(width, height, enemy_count, ally_cells, 1)
	return {"tile_map": tile_map, "ally_cells": ally_cells, "enemy_cells": enemy_cells}


# ── VISUALS ────────────────────────────────────────────────────────────────────

var _placeholder_texture_cache: Dictionary = {}

func _get_placeholder_texture(tint: Color) -> ImageTexture:
	if _placeholder_texture_cache.has(tint):
		return _placeholder_texture_cache[tint]
	var img = Image.create(96, 96, false, Image.FORMAT_RGBA8)
	img.fill(tint)
	var tex = ImageTexture.create_from_image(img)
	_placeholder_texture_cache[tint] = tex
	return tex


func _get_asset_texture(asset: MapAssetData) -> Texture2D:
	if asset.texture != null:
		return asset.texture
	var blocks_move = asset.is_wall or asset.movement_cost > 1
	var blocks_los  = asset.blocks_line_of_sight
	if blocks_move and blocks_los:
		return _get_placeholder_texture(Color(0.6, 0.3, 0.7))
	elif asset.is_wall:
		return _get_placeholder_texture(Color(0.8, 0.2, 0.2))
	elif asset.movement_cost > 1:
		return _get_placeholder_texture(Color(0.8, 0.7, 0.2))
	elif blocks_los:
		return _get_placeholder_texture(Color(0.3, 0.4, 0.8))
	else:
		return _get_placeholder_texture(Color(0.5, 0.5, 0.5))


func _spawn_obstacle_visuals(placements: Array) -> void:
	var grid = _current_grid
	if grid == null:
		return
	var layer = _ensure_obstacle_layer(grid)

	for placement in placements:
		var cells: Array = placement["cells"]
		var asset: MapAssetData = placement["asset"]
		var tex = _get_asset_texture(asset)

		if cells.size() == 1:
			var sprite = Sprite2D.new()
			sprite.texture = tex
			sprite.position = grid.grid_to_world(cells[0])
			layer.add_child(sprite)
		else:
			var min_x = cells[0].x; var max_x = cells[0].x
			var min_y = cells[0].y; var max_y = cells[0].y
			for c in cells:
				min_x = min(min_x, c.x); max_x = max(max_x, c.x)
				min_y = min(min_y, c.y); max_y = max(max_y, c.y)
			var width_px  = (max_x - min_x + 1) * 96.0
			var height_px = (max_y - min_y + 1) * 96.0
			var center_cell = Vector2i(int((min_x + max_x) / 2.0), int((min_y + max_y) / 2.0))

			var sprite = Sprite2D.new()
			sprite.texture = tex
			sprite.position = grid.grid_to_world(center_cell)
			var tex_size = tex.get_size()
			if tex_size.x > 0 and tex_size.y > 0:
				sprite.scale = Vector2(width_px / tex_size.x, height_px / tex_size.y)
			layer.add_child(sprite)


var _current_grid: Node2D = null

func set_grid_reference(grid: Node2D) -> void:
	_current_grid = grid


func _ensure_obstacle_layer(grid: Node2D) -> Node2D:
	if grid.has_node("ObstacleLayer"):
		return grid.get_node("ObstacleLayer")
	var layer = Node2D.new()
	layer.name = "ObstacleLayer"
	grid.add_child(layer)
	grid.move_child(layer, 1)
	return layer
