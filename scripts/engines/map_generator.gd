# res://scripts/engines/map_generator.gd
#
# MAP GENERATOR -- builds a procedurally generated battle map: where the
# player party spawns, where enemies spawn, and which cells get scattered
# decoration/obstacles/difficult terrain.
#
# THE BIG GUARANTEE: player spawn cells and enemy spawn cells can NEVER end
# up fully sealed off from each other. This works in two layers:
#   1. PREVENTION -- before scattering any blocking features, a winding
#      "corridor" of cells connecting the two spawn areas is reserved, and
#      blocking features are simply never allowed to land on a reserved cell.
#   2. VERIFICATION -- after everything is placed, a flood-fill check
#      confirms the two sides are actually connected. If something
#      unexpected broke that (it shouldn't, given step 1, but better safe
#      than stuck), a straight-line fallback path is forcibly cleared.
#
# SPAWN SHAPE: player spawns are picked to be as CLOSE TOGETHER as possible
# near the left edge; enemy spawns are picked to be as SPREAD OUT as
# possible near the right edge -- both by explicit distance-based selection,
# not just "different random ranges."
#
# Register this as an autoload named "MapGenerator".

extends Node

# ── TUNABLE CONSTANTS ─────────────────────────────────────────────────────────
const PLAYER_ZONE_COLUMNS: int = 3
# How many columns in from the LEFT edge player spawns are allowed to use.

const ENEMY_ZONE_COLUMNS: int = 4
# How many columns in from the RIGHT edge enemy spawns are allowed to use.

const FEATURE_DENSITY: float = 0.12
# Roughly what fraction of the grid's cells end up with a scattered feature.
# 0.12 = about 1 in 8 cells. Tune freely.

const MAP_FEATURES_DIR := "res://resources/map_features/"
# Scanned recursively -- organize into biome subfolders for your own
# convenience (res://resources/map_features/forest/oak_tree.tres etc.), but
# matching is always based on each resource's OWN "biomes" field, not its
# folder location.


var last_result: Dictionary = {}
# ADDED: battle_scene.gd generates the map in _enter_tree() (which runs
# BEFORE battle_manager.gd's own _ready(), since Godot calls _enter_tree()
# parent-first but _ready() child-first) and hands $BattleGrid the tile_map.
# battle_manager.gd's _spawn_player_party_from_run()/_spawn_stage_enemies()
# then read player_spawns/enemy_spawns back out of THIS cache, so both
# scripts see the exact same generated layout without needing a direct
# reference to each other.

func generate_map(width: int, height: int, biome: String, party_size: int, enemy_count: int) -> Dictionary:
	# Returns:
	# {
	#   "tile_map": Dictionary[Vector2i, TileTypeData]  -- feed straight into BattleGrid.setup_grid()
	#   "player_spawns": Array[Vector2i]
	#   "enemy_spawns": Array[Vector2i]
	#   "feature_placements": Array[{"cell": Vector2i, "feature": MapFeatureData}]
	# }
	party_size = max(1, party_size)
	enemy_count = max(1, enemy_count)

	var player_spawns := _generate_player_spawns(width, height, party_size)
	var enemy_spawns := _generate_enemy_spawns(width, height, enemy_count)

	# ── GUARANTEED FULL CONNECTIVITY (reservation step) ───────────────────────
	# The requirement is stronger than "the two sides are connected somehow":
	# EVERY ally spawn cell must be able to reach EVERY enemy spawn cell.
	# Player spawns are already clustered tightly together by design, so one
	# representative "hub" cell on that side is enough to stand in for the
	# whole cluster. Enemy spawns are deliberately spread apart, so each one
	# gets its OWN dedicated corridor back to that hub -- this creates a
	# guaranteed-connected "spine with branches" touching every single spawn
	# cell, before a single blocking feature is ever placed.
	var hub: Vector2i = _closest_to_centroid(player_spawns)
	var reserved_corridor: Dictionary = {}
	for enemy_cell in enemy_spawns:
		for cell in _carve_guaranteed_corridor(hub, enemy_cell, width, height):
			reserved_corridor[cell] = true

	# On top of the corridors, reserve a small clear halo directly around
	# EVERY spawn cell (both sides) -- this is what guarantees a unit can
	# never spawn already boxed in, even in a spot no corridor happened to
	# pass through.
	for spawn_cell in player_spawns + enemy_spawns:
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			reserved_corridor[spawn_cell + offset] = true

	var tile_map: Dictionary = {}
	for x in range(width):
		for y in range(height):
			tile_map[Vector2i(x, y)] = _make_open_tile()

	var occupied: Dictionary = {}   # cells already used by a spawn or a placed feature
	for cell in player_spawns:
		occupied[cell] = true
	for cell in enemy_spawns:
		occupied[cell] = true

	var feature_placements: Array = []
	var pool := _get_feature_pool(biome)
	if pool.is_empty():
		push_warning("MapGenerator: no MapFeatureData resources found for biome '" + biome +
					 "' -- map will be entirely open ground.")
	else:
		var target_feature_count := int(width * height * FEATURE_DENSITY)
		var attempts := 0
		var max_attempts := target_feature_count * 8
		while feature_placements.size() < target_feature_count and attempts < max_attempts:
			attempts += 1
			var cell := Vector2i(randi() % width, randi() % height)
			if occupied.has(cell):
				continue

			var feature: MapFeatureData = _weighted_pick(pool)
			if feature.category == "blocking" and reserved_corridor.has(cell):
				continue   # Never allow a blocker on a guaranteed-clear cell.
			if not _footprint_is_free(cell, feature.footprint, occupied, width, height):
				continue
			if feature.min_distance_from_spawns > 0 and \
			   _too_close_to_spawns(cell, player_spawns, enemy_spawns, feature.min_distance_from_spawns):
				continue

			for offset in feature.footprint:
				var fp_cell: Vector2i = cell + offset
				occupied[fp_cell] = true
				tile_map[fp_cell] = _make_tile_for_feature(feature)
			feature_placements.append({"cell": cell, "feature": feature})

	_ensure_full_connectivity(tile_map, player_spawns, enemy_spawns, width, height)

	last_result = {
		"tile_map": tile_map,
		"player_spawns": player_spawns,
		"enemy_spawns": enemy_spawns,
		"feature_placements": feature_placements,
	}
	return last_result

# ── SPAWN PLACEMENT ────────────────────────────────────────────────────────────

func _generate_player_spawns(width: int, height: int, party_size: int) -> Array[Vector2i]:
	# Picks cells from a thin strip along the LEFT edge, chosen to be as
	# CLOSE TOGETHER as possible (sorted by distance to a single anchor
	# point, then taking the closest N) -- this is what makes the party
	# cluster tightly rather than spread across the whole left side.
	var center_row: int = clampi(height / 2 + (randi() % 3 - 1), 0, height - 1)
	var anchor := Vector2(1, center_row)

	var candidates: Array[Vector2i] = []
	for x in range(0, min(PLAYER_ZONE_COLUMNS, width)):
		for y in range(height):
			candidates.append(Vector2i(x, y))

	candidates.sort_custom(func(a, b): return Vector2(a).distance_to(anchor) < Vector2(b).distance_to(anchor))
	var count: int = min(party_size, candidates.size())
	var result: Array[Vector2i] = []
	result.assign(candidates.slice(0, count))
	return result


func _generate_enemy_spawns(width: int, height: int, enemy_count: int) -> Array[Vector2i]:
	# Picks cells from a thin strip along the RIGHT edge, chosen to be as
	# SPREAD OUT as possible via greedy farthest-point selection -- this is
	# what makes enemies land "further apart" rather than just "somewhere
	# on the right," even though both sides draw from a similarly-shaped zone.
	var candidates: Array[Vector2i] = []
	for x in range(max(0, width - ENEMY_ZONE_COLUMNS), width):
		for y in range(height):
			candidates.append(Vector2i(x, y))
	return _pick_spread_cells(candidates, enemy_count)


func _pick_spread_cells(candidates: Array[Vector2i], count: int) -> Array[Vector2i]:
	var chosen: Array[Vector2i] = []
	if candidates.is_empty() or count <= 0:
		return chosen
	var pool := candidates.duplicate()
	pool.shuffle()
	chosen.append(pool.pop_back())
	while chosen.size() < count and pool.size() > 0:
		var best_cell: Vector2i = pool[0]
		var best_min_dist: float = -1.0
		for cell in pool:
			var min_dist: float = INF
			for picked in chosen:
				min_dist = min(min_dist, Vector2(cell).distance_to(Vector2(picked)))
			if min_dist > best_min_dist:
				best_min_dist = min_dist
				best_cell = cell
		chosen.append(best_cell)
		pool.erase(best_cell)
	return chosen

# ── GUARANTEED CONNECTIVITY ────────────────────────────────────────────────────

func _closest_to_centroid(cells: Array) -> Vector2i:
	# Returns whichever cell in 'cells' sits closest to their shared average
	# position -- used to pick a single representative "hub" cell for the
	# player spawn cluster, since carving a corridor from every single
	# player spawn individually would be redundant (they're already close
	# together by design).
	var sum := Vector2.ZERO
	for c in cells:
		sum += Vector2(c)
	var centroid: Vector2 = sum / cells.size()

	var best: Vector2i = cells[0]
	var best_dist: float = INF
	for c in cells:
		var d: float = Vector2(c).distance_to(centroid)
		if d < best_dist:
			best_dist = d
			best = c
	return best


func _carve_guaranteed_corridor(start: Vector2i, end: Vector2i, width: int, height: int) -> Array:
	# A biased random walk from start to end -- mostly steps toward the
	# target with occasional wobble, so the reserved corridor looks organic
	# rather than a perfectly straight line. Every visited cell PLUS its 4
	# neighbours gets reserved (a corridor roughly 3 tiles wide), and
	# "blocking" features are never allowed to land on a reserved cell.
	var reserved: Dictionary = {}
	var current := start
	var max_steps: int = (width + height) * 3   # generous safety cap, this is a small grid
	var steps := 0

	while current != end and steps < max_steps:
		steps += 1
		reserved[current] = true
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			reserved[current + offset] = true

		var dx : int = sign(end.x - current.x)
		var dy : int = sign(end.y - current.y)
		if randf() < 0.7:
			# Mostly move toward the target.
			if absi(end.x - current.x) >= absi(end.y - current.y) and dx != 0:
				current += Vector2i(dx, 0)
			elif dy != 0:
				current += Vector2i(0, dy)
			else:
				current += Vector2i(dx, 0)
		else:
			# Occasional wobble for an organic, hand-drawn feel.
			var wobble_options := [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]
			current += wobble_options[randi() % wobble_options.size()]
		current.x = clampi(current.x, 0, width - 1)
		current.y = clampi(current.y, 0, height - 1)

	reserved[end] = true
	return reserved.keys()


func _flood_fill_reachable(tile_map: Dictionary, start_cells: Array, width: int, height: int) -> Dictionary:
	var visited: Dictionary = {}
	var frontier: Array = []
	for cell in start_cells:
		if tile_map.has(cell) and not tile_map[cell].is_wall:
			visited[cell] = true
			frontier.append(cell)

	while frontier.size() > 0:
		var cell: Vector2i = frontier.pop_back()
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbor: Vector2i = cell + offset
			if neighbor.x < 0 or neighbor.x >= width or neighbor.y < 0 or neighbor.y >= height:
				continue
			if visited.has(neighbor):
				continue
			if tile_map.has(neighbor) and tile_map[neighbor].is_wall:
				continue
			visited[neighbor] = true
			frontier.append(neighbor)
	return visited


func _ensure_full_connectivity(tile_map: Dictionary, player_spawns: Array, enemy_spawns: Array, width: int, height: int) -> void:
	# Verifies EVERY spawn cell (both teams) belongs to the same connected
	# region -- which is exactly equivalent to "every ally can reach every
	# enemy cell" (and every ally can reach every other ally cell too, as a
	# side benefit). This should almost never need to fix anything, given
	# the reserved corridors carved before any blocking feature was placed
	# -- it exists as a verified guarantee, not a hope.
	var all_spawns: Array = player_spawns + enemy_spawns
	if all_spawns.is_empty():
		return

	var reachable := _flood_fill_reachable(tile_map, [all_spawns[0]], width, height)
	for spawn_cell in all_spawns:
		if reachable.has(spawn_cell):
			continue

		push_warning("MapGenerator: spawn cell " + str(spawn_cell) + " was isolated after generation " +
					 "-- clearing a fallback path. (Should be rare given the reserved corridors.)")
		var fallback_path := _carve_guaranteed_corridor(all_spawns[0], spawn_cell, width, height)
		for cell in fallback_path:
			if tile_map.has(cell) and tile_map[cell].is_wall:
				tile_map[cell] = _make_open_tile()
		# Re-run the flood fill since we just opened new cells -- later
		# spawn cells in this loop benefit from the freshly cleared path too.
		reachable = _flood_fill_reachable(tile_map, [all_spawns[0]], width, height)

# ── FEATURE SCATTERING HELPERS ─────────────────────────────────────────────────

func _get_feature_pool(biome: String) -> Array[MapFeatureData]:
	var result: Array[MapFeatureData] = []
	_scan_features_recursive(MAP_FEATURES_DIR, biome, result)
	return result


func _scan_features_recursive(path: String, biome: String, result: Array[MapFeatureData]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		var full_path := path + entry_name
		if dir.current_is_dir() and entry_name != "." and entry_name != "..":
			_scan_features_recursive(full_path + "/", biome, result)
		elif entry_name.ends_with(".tres"):
			var feature := load(full_path) as MapFeatureData
			if feature != null and (feature.biomes.is_empty() or feature.biomes.has(biome)):
				result.append(feature)
		entry_name = dir.get_next()
	dir.list_dir_end()


func _weighted_pick(pool: Array[MapFeatureData]) -> MapFeatureData:
	var total := 0.0
	for f in pool:
		total += f.spawn_weight
	var roll := randf() * total
	var cumulative := 0.0
	for f in pool:
		cumulative += f.spawn_weight
		if roll <= cumulative:
			return f
	return pool[pool.size() - 1]


func _footprint_is_free(anchor: Vector2i, footprint: Array, occupied: Dictionary, width: int, height: int) -> bool:
	for offset in footprint:
		var cell: Vector2i = anchor + offset
		if cell.x < 0 or cell.x >= width or cell.y < 0 or cell.y >= height:
			return false
		if occupied.has(cell):
			return false
	return true


func _too_close_to_spawns(cell: Vector2i, player_spawns: Array, enemy_spawns: Array, min_dist: int) -> bool:
	for s in player_spawns:
		if Vector2(cell).distance_to(Vector2(s)) < min_dist:
			return true
	for s in enemy_spawns:
		if Vector2(cell).distance_to(Vector2(s)) < min_dist:
			return true
	return false

# ── TILE CONSTRUCTION ──────────────────────────────────────────────────────────

var _open_tile_cache: TileTypeData = null

func _make_open_tile() -> TileTypeData:
	# Shared by every open cell -- no need for a unique instance per cell.
	if _open_tile_cache == null:
		_open_tile_cache = TileTypeData.new()
		_open_tile_cache.id = "generated_open"
		_open_tile_cache.movement_cost = 1
		_open_tile_cache.is_wall = false
		_open_tile_cache.blocks_line_of_sight = false
	return _open_tile_cache


func _make_tile_for_feature(feature: MapFeatureData) -> TileTypeData:
	var tile := TileTypeData.new()
	tile.id = "generated_" + feature.id
	tile.is_wall = feature.blocks_movement
	tile.blocks_line_of_sight = feature.blocks_line_of_sight
	tile.movement_cost = feature.movement_cost if feature.category == "slowing" else 1
	# tile_texture is deliberately left blank -- the feature's actual visual
	# is drawn on FeatureLayer instead (see battle_grid.gd's
	# spawn_scatter_features), not via this TileTypeData's own sprite. This
	# keeps "what the ground looks like" (the background image), "what's
	# gameplay-relevant about this cell" (this TileTypeData), and "what
	# decoration/obstacle is sitting on top" (the FeatureLayer sprite)
	# cleanly separated from each other.
	return tile
