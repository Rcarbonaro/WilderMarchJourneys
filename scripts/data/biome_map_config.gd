# res://scripts/data/biome_map_config.gd
#
# Bundles everything MapGenerator needs to build a map for one biome: ground
# texture pool, obstacle pool + weights, and map size. One .tres per biome.
#
# NOTE: this is separate from the full-screen background IMAGE system in
# battle_scene.gd (setup_battle_background/BIOME_BACKGROUNDS) — untouched.
# This controls the actual walkable GRID tiles and obstacles.

class_name BiomeMapConfig
extends Resource

@export var id: String = ""
# e.g. "forest", "desert" — should match RunManager's biome string and the
# biome_order array in run_config.json.

# ── MAP SIZE ──────────────────────────────────────────────────────────────────

@export var width: int = 25
@export var height: int = 10

# ── GROUND TILES ──────────────────────────────────────────────────────────────

@export var ground_tile_pool: Array[TileTypeData] = []
# Random pick per cell for visual variety. None of these should have is_wall
# or blocks_line_of_sight true — that's what obstacles are for. Leave empty
# to fall back to a plain gray ground tile.

# ── OBSTACLES (random maps) ───────────────────────────────────────────────────

@export var obstacle_pool: Array[MapAssetData] = []
@export var obstacle_weights: Array[float] = []
# Keep these two arrays the SAME LENGTH and matching order —
# obstacle_weights[2] is the weight for obstacle_pool[2]. Bigger number =
# more common. Overall density (how much of the map gets obstacles at all)
# is controlled separately in map_density_config.json, not here.

# ── FIXED LAYOUT (for boss arenas — an identical map every time) ─────────────

@export var use_fixed_layout: bool = false
# If true, obstacles/spawns are placed EXACTLY as described below instead of
# randomly. obstacle_pool above is still used as a lookup table by id —
# obstacle_weights is ignored in this mode.

@export var fixed_ally_anchor: Vector2i = Vector2i(-1, -1)
# Leave (-1,-1) to auto-pick like a normal map; set a cell to force it.

@export var fixed_enemy_cells: Array[Vector2i] = []
# Leave empty to auto-scatter; fill in to force exact enemy positions.

@export var fixed_obstacle_cells: Array[Vector2i] = []
@export var fixed_obstacle_ids: Array[String] = []
# Parallel arrays: fixed_obstacle_ids[i] placed at fixed_obstacle_cells[i].
# The id must match a MapAssetData already listed in obstacle_pool above.
