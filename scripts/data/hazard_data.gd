# res://scripts/data/hazard_data.gd
#
# A HazardData resource defines the TEMPLATE for a hazard tile effect —
# things like poison pools, fire patches, ice slicks, or impassable walls.
# The actual live hazard on the grid is tracked as a Dictionary in battle_grid.gd.
#
# NEW ADDITIONS:
#   - Animated scene support (entrance / idle / exit) instead of static sprites.
#   - Wall hazards: a hazard placed as a straight line of tiles (start/end point),
#     instead of a single tile. A wall hazard has TWO independent switches:
#       1) blocks_movement  — does it physically stop units from entering?
#       2) wall_blocks_line_of_sight — does it block ranged/magic targeting?
#     You can mix and match these freely. For example:
#       blocks_movement=true,  wall_blocks_line_of_sight=true  → a classic solid
#           wall, like a stone barricade. Nothing can walk through it or see
#           past it.
#       blocks_movement=true,  wall_blocks_line_of_sight=false → a solid wall
#           you can still shoot/cast spells over, like a low fence.
#       blocks_movement=false, wall_blocks_line_of_sight=true  → a "damaging
#           wall" that does NOT stop movement but DOES block sightlines —
#           e.g. a wall of thick smoke or thorny brambles that hurts anyone
#           who walks through it, and also hides what's on the other side.
#       blocks_movement=false, wall_blocks_line_of_sight=false → a "damaging
#           wall" that's purely a damage-over-a-line effect with no blocking
#           at all — e.g. a line of caltrops or a fire trench. Units can walk
#           straight through it (taking damage) and see straight through it.

class_name HazardData
extends Resource

@export var id: String = ""
# A unique machine-readable name. e.g. "fire_pool", "poison_swamp", "stone_wall".

@export var display_name: String = ""
# Name shown in tooltips.

@export var icon: Texture2D
# FALLBACK ONLY. If no animated scenes are set below, this static icon is used
# instead. Once you set entrance/idle scenes, this field is ignored.

@export var duration_rounds: int = 2
# How many turns this hazard stays on the board.
# Maximum allowed is 3 for non-wall hazards (clamped automatically in battle_grid).
# Walls are NOT clamped to 3 — see is_wall_hazard below. This is true regardless
# of blocks_movement; ANY wall-placed hazard (movement-blocking or not) is
# exempt from the 3-turn cap, since it's still placed via the wall flow.

@export var is_permanent: bool = false
# If true, the hazard never expires regardless of duration_rounds.
# Use for map-placed environmental hazards (e.g. lava rivers) or permanent walls.

# ── ANIMATED VISUALS ──────────────────────────────────────────────────────────
# All three are optional. If entrance_scene is set, it plays once when the
# hazard is placed, then idle_scene takes over and loops for the hazard's
# lifetime. If exit_scene is set, it plays once when the hazard expires/is
# removed, and the hazard's node isn't freed until that animation finishes.
# If none of these are set, hazard falls back to the static 'icon' sprite.

@export var entrance_scene: PackedScene
# Plays ONCE when the hazard first appears (e.g. fire igniting, ice forming).
# Expected to free itself or signal completion via AnimatedSprite2D/AnimationPlayer
# "finished" — battle_grid waits for this before showing idle_scene.

@export var idle_scene: PackedScene
# Loops for as long as the hazard exists on the field.
# Spawned immediately if entrance_scene is null, or right after entrance_scene
# finishes playing if one is set.

@export var exit_scene: PackedScene
# Plays ONCE when the hazard expires or is manually removed (e.g. fire dying out,
# wall crumbling). The hazard's grid entry is cleaned up once this finishes.
# If null, the idle visual is just removed instantly with no exit animation.

# ── DAMAGE ────────────────────────────────────────────────────────────────────

@export var damage_multiplier: float = 0.4
# Damage dealt = caster_atk * damage_multiplier (using the unit that PLACED the hazard).
# If no caster is tracked, falls back to a flat 5 true damage.
#
# For a TRUE impassable wall (is_wall_hazard=true AND blocks_movement=true),
# this is ignored — units can never stand on a tile they can't enter, so
# there's never anyone there to damage.
#
# For a wall hazard with blocks_movement=false (a "damaging wall" — see the
# big comment block at the top of this file), this works exactly like a
# normal hazard's damage: set it freely, and units that step on/start their
# turn on/end their turn on the wall's tiles will take damage normally,
# based on whichever trigger_on_* boxes are checked below.

@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "hazard"

# ── TRIGGER CONDITIONS ────────────────────────────────────────────────────────

@export var trigger_on_enter: bool = true
# If true: damages a unit the moment they step onto this tile.
# Not applicable to a TRUE impassable wall (is_wall_hazard=true AND
# blocks_movement=true), since units can never enter those tiles at all.
# Fully applicable to a "damaging wall" (is_wall_hazard=true AND
# blocks_movement=false) — those CAN be entered, so this works normally.

@export var trigger_on_start_of_turn: bool = true
# If true: damages any unit that STARTS their turn standing on this tile.

@export var trigger_on_end_of_turn: bool = false
# If true: damages any unit that ENDS their turn on this tile.

# ── STATUS APPLICATION ────────────────────────────────────────────────────────

@export var applies_status: StatusEffectData
# Optional status effect applied whenever the hazard triggers.
# e.g. a fire hazard could apply a "Burning" debuff.

# ── WALL HAZARD ───────────────────────────────────────────────────────────────
# A wall hazard is placed differently from a normal hazard tile: instead of a
# single targeted tile, it's placed as a straight line (horizontal or vertical
# only — no diagonals) of tiles, using a start point and end point chosen by
# the player. What the wall actually DOES to units standing on its tiles is
# controlled by blocks_movement and wall_blocks_line_of_sight below — both
# are independent switches, so a wall doesn't have to be a solid impassable
# obstacle. See the big comment block at the very top of this file for the
# four possible combinations.

@export var is_wall_hazard: bool = false
# Check this box to make this hazard use the wall PLACEMENT flow (a straight
# line of tiles chosen via two taps) instead of a single-tile placement.
# This by itself does NOT decide whether the wall blocks movement or damages
# units — those are controlled separately by blocks_movement (below),
# damage_multiplier (above), and the trigger_on_* checkboxes (above).

@export var wall_length: int = 3
# The number of tiles this wall spans, INCLUDING the tile most central to
# the placement. e.g. 3 = a 3-tile-long wall. 4 = a 4-tile-long wall.
# The wall is built outward from the caster-relative direction at cast time —
# see ability_executor.gd's wall-placement logic for how this is centred.

@export var blocks_movement: bool = true
# THE KEY SWITCH for whether this wall is a physical obstacle.
#
# If true (the default): this wall behaves like the original "impassable
# wall" — units are physically blocked from entering its tiles, filtered by
# the wall_blocks team setting just below. Because nobody can ever stand on
# it, damage_multiplier and the trigger_on_* boxes above are ignored for
# this wall (there's no one there to hurt).
#
# If false: this wall does NOT block movement at all — wall_blocks (below) is
# ignored entirely, and units of every team can freely walk onto, through, or
# end their turn on its tiles. Instead, the wall behaves like a normal
# damage/status hazard that just happens to be shaped like a straight line —
# damage_multiplier, damage_type, applies_status, and the trigger_on_* boxes
# above all apply normally. Use this for things like a fire trench, a hedge
# of thorns, or a line of caltrops: it hurts you, but it doesn't stop you.
#
# This is completely independent of wall_blocks_line_of_sight below — a
# non-blocking damaging wall can still block sightlines (e.g. a wall of
# smoke) or not (e.g. a line of caltrops you can see clean through).

@export_enum("player", "enemies", "all") var wall_blocks: String = "all"
# Who is physically blocked from entering wall tiles.
# ONLY relevant when blocks_movement is true above — if blocks_movement is
# false, this setting is ignored completely, since nothing is blocked from
# entering either way.
# "player"  — only player units are blocked; enemies pass through freely.
# "enemies" — only enemy units are blocked; player units pass through freely.
# "all"     — nobody can enter wall tiles, including the caster's own team.

@export var wall_blocks_line_of_sight: bool = false
# If true, this wall's tiles also block line-of-sight checks
# (pathfinder.has_line_of_sight), preventing ranged/magic abilities from
# targeting through it — exactly like a terrain wall would.
# If false, the wall never blocks LOS — ranged/magic attacks can still target
# straight through/over it.
#
# IMPORTANT: this is its own independent switch — it has NOTHING to do with
# blocks_movement above. A wall can block movement but not LOS, block LOS but
# not movement, both, or neither. See the comment block at the top of this
# file for all four combinations with examples.
