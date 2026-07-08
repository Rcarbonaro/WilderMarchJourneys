# res://scripts/data/map_asset_data.gd
#
# Defines ONE type of obstacle scattered across the battle map (rock, tree,
# mud pit, etc). Leave 'texture' empty to get an automatic placeholder block,
# colour-coded by what the obstacle does:
#   red    = fully impassable (is_wall)
#   yellow = slows movement (movement_cost > 1) but walkable
#   blue   = blocks line of sight only
#   purple = does more than one of the above
#   gray   = no special rules
#
# See the README in this package for the full "how to add a new obstacle"
# walkthrough, including how to swap in real art later.

class_name MapAssetData
extends Resource

@export var id: String = ""
@export var display_name: String = ""

@export var texture: Texture2D
# Leave EMPTY for the automatic placeholder. Drag an image in later — no
# other changes needed anywhere else in the project.

@export var footprint: Array[Vector2i] = [Vector2i(0, 0)]
# Cells this obstacle occupies, relative to its anchor cell. 1x1 default;
# add more offsets (e.g. Vector2i(1,0), Vector2i(0,1), Vector2i(1,1) for a
# 2x2 boulder cluster) for bigger multi-cell obstacles.

@export var is_wall: bool = false
# true = completely impassable. movement_cost is ignored when true.

@export var movement_cost: int = 1
# Only matters if is_wall is false. 1 = normal. 2+ = difficult terrain
# (costs extra movement points to step onto).

@export var blocks_line_of_sight: bool = false
# true = ranged/magic abilities can't target or see through this tile.

@export var tags: Array[String] = []
# Optional labels for filtering/reuse across biomes — not required.
