# res://scripts/data/map_feature_data.gd
#
# MapFeatureData -- one type of scattered map decoration/obstacle (tree,
# rock, mud patch, etc). Referenced throughout map_generator.gd but not
# included in your upload, so this is a NEW file, written to match every
# field map_generator.gd actually reads.
#
# Store instances under res://resources/map_features/ (map_generator.gd
# scans that folder recursively -- organize into biome subfolders for your
# own convenience, but matching is always based on THIS resource's own
# "biomes" field, not its folder location).
#
# PLACEHOLDER ART: leave 'texture' empty and battle_grid.gd's
# spawn_scatter_features() (see the README) draws a small solid-color
# square instead, tinted by category so you can tell types apart during
# testing: red = blocking, yellow = slowing, gray = decoration only.

class_name MapFeatureData
extends Resource

@export var id: String = ""
@export var display_name: String = ""

@export var texture: Texture2D
# Leave empty for the automatic placeholder square.

@export_enum("blocking", "slowing", "decoration") var category: String = "decoration"
# "blocking"    -- map_generator.gd NEVER allows this to land on a cell
#                  reserved by the guaranteed-connectivity corridor system.
#                  Should almost always pair with blocks_movement = true.
# "slowing"     -- costs extra movement but never blocks a path outright.
#                  Allowed anywhere, including reserved corridor cells.
# "decoration"  -- purely visual, no gameplay effect at all.

@export var blocks_movement: bool = false
# Whether a unit can ever stand on / move through this feature's cells.

@export var blocks_line_of_sight: bool = false
# Independent of blocks_movement -- mix freely (e.g. tall grass: doesn't
# block movement, does block line of sight).

@export var movement_cost: int = 1
# Only read when category == "slowing". Ignored for "blocking"/"decoration".

@export var footprint: Array[Vector2i] = [Vector2i(0, 0)]
# Cells this feature occupies, relative to its anchor cell. Default is a
# single 1x1 tile; add more offsets for a bigger multi-cell feature.

@export var spawn_weight: float = 1.0
# Relative likelihood of being chosen versus every other feature valid for
# the current biome. Bigger number = more common.

@export var min_distance_from_spawns: int = 0
# Minimum tile distance this feature must keep from EVERY player and enemy
# spawn cell. 0 = no restriction.

@export var biomes: Array[String] = []
# Which biome(s) this feature is eligible to appear in, e.g. ["forest"].
# Leave EMPTY to make it eligible in every biome regardless of name.

@export var visual_offset: Vector2 = Vector2.ZERO
# Pure cosmetic nudge in pixels, independent of footprint/blocking -- use
# this for fine art alignment (e.g. a tree trunk that should sit a few
# pixels lower than tile-center), NOT for changing which tiles are blocked.
