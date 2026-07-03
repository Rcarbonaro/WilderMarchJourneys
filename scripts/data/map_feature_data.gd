# res://scripts/data/map_feature_data.gd
#
# MAP FEATURE DATA -- a placeable piece of map "dressing": a tree, a large
# stone, a mud patch, a flower clump, etc. MapGenerator scatters these
# across a procedurally generated battle map.
#
# THIS IS A RESOURCE (.tres), NOT A JSON CONTENT FILE -- unlike tarot cards,
# equipment, encounters, etc. (pure data with no asset bindings), a map
# feature's whole job is to carry a TEXTURE/SCENE reference, and Godot's
# Resource system (with the Inspector's drag-and-drop texture picker) is
# the right tool for that -- exactly like UnitData.portrait or
# TileTypeData.tile_texture already work.
#
# HOW TO ADD A NEW ONE: see MAP_GENERATION_SETUP.md's beginner walkthrough.
# Short version: right-click in the FileSystem dock under
# res://resources/map_features/<biome>/ > New Resource > MapFeatureData,
# fill in the fields below, save. MapGenerator picks it up automatically --
# no script changes needed, ever, for a new asset.

class_name MapFeatureData
extends Resource

@export var id: String = ""
@export var display_name: String = ""

@export_enum("decorative", "blocking", "slowing") var category: String = "decorative"
# decorative -- purely visual, no effect on movement or line of sight
#               (flowers, twigs, grass tufts, fallen leaves)
# blocking   -- blocks movement and/or line of sight, per the two checkboxes
#               below (large stones, logs, dense thickets)
# slowing    -- increases the movement cost to enter this tile
#               (deep mud, thick brush, shallow water)

@export var biomes: Array[String] = []
# Which biomes this feature can be scattered in, e.g. ["forest"]. Leave
# empty to allow every biome.

@export var spawn_weight: float = 1.0
# Relative frequency vs other features valid for this biome/category.

# ── VISUAL ──────────────────────────────────────────────────────────────────

@export var texture: Texture2D
# Simple static sprite. Used whenever 'scene' below is left empty.

@export var scene: PackedScene
# Optional: a custom scene (e.g. one with its own AnimatedSprite2D for
# swaying grass) instead of a plain static texture. If set, this takes
# priority over 'texture' entirely.

@export var visual_offset_jitter_px: float = 0.0
# Random pixel offset applied each time this feature is placed, so a field
# of flowers doesn't look snapped to a perfect grid. Leave at 0 for features
# whose visual size should clearly match their grid footprint (e.g. a
# blocking boulder) -- jitter is for pure decoration only.

@export var random_scale_variance: float = 0.0
# e.g. 0.2 = each placed instance is randomly scaled between 80%-120%, for
# extra natural variety. Leave at 0 to always place at scale 1.0.

# ── FOOTPRINT ───────────────────────────────────────────────────────────────

@export var footprint: Array[Vector2i] = [Vector2i(0, 0)]
# Which cells (relative to the anchor cell) this feature occupies. Matches
# the EXACT same pattern as UnitData.tile_footprint -- a 2x2 boulder would
# use [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)].

# ── GAMEPLAY (only relevant for "blocking" / "slowing") ─────────────────────

@export var blocks_movement: bool = false
@export var blocks_line_of_sight: bool = false
@export var movement_cost: int = 1
# For "slowing" features, set this above 1 (e.g. 3 for deep mud). Has no
# effect for "decorative", and is irrelevant for "blocking" (a unit can't
# enter a blocked tile at all, so its movement cost is never read).

@export var min_distance_from_spawns: int = 0
# Don't place this feature within this many tiles of ANY spawn point.
# Mainly useful for "blocking" features, so a big boulder can never
# accidentally wall a unit in right at spawn. 0 = no restriction.
