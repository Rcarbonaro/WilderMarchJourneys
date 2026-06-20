# res://scripts/data/hazard_data.gd
#
# A HazardData resource defines the TEMPLATE for a hazard tile effect —
# things like poison pools, fire patches, ice slicks, or impassable walls.
# The actual live hazard on the grid is tracked as a Dictionary in battle_grid.gd.
#
# NEW ADDITIONS:
#   - Animated scene support (entrance / idle / exit) instead of static sprites.
#   - Wall hazards: a hazard that blocks movement (and optionally line of sight)
#     across a straight line of tiles, placed with a start/end point.

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
# Walls are NOT clamped to 3 — see is_wall_hazard below.

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
# Ignored entirely for wall hazards (walls don't deal damage by default — use
# applies_status if you want a wall that also has a side effect).

@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "hazard"

# ── TRIGGER CONDITIONS ────────────────────────────────────────────────────────

@export var trigger_on_enter: bool = true
# If true: damages a unit the moment they step onto this tile.
# Not applicable to walls since units cannot enter a wall tile at all.

@export var trigger_on_start_of_turn: bool = true
# If true: damages any unit that STARTS their turn standing on this tile.

@export var trigger_on_end_of_turn: bool = false
# If true: damages any unit that ENDS their turn on this tile.

# ── STATUS APPLICATION ────────────────────────────────────────────────────────

@export var applies_status: StatusEffectData
# Optional status effect applied whenever the hazard triggers.
# e.g. a fire hazard could apply a "Burning" debuff.

# ── WALL HAZARD ───────────────────────────────────────────────────────────────
# A wall hazard is fundamentally different from a normal hazard tile: instead
# of damaging units who stand on it, it BLOCKS units from standing on or moving
# through its tiles entirely. Walls are placed as a straight line (horizontal
# or vertical only — no diagonals) using a start point and end point chosen
# by the player.

@export var is_wall_hazard: bool = false
# Check this box to make this hazard behave as an impassable wall instead of
# a damage/status tile. When true, damage and status fields above are ignored
# (unless you specifically want a wall that ALSO damages anyone standing
# adjacent — that would require a separate aura, not this hazard).

@export var wall_length: int = 3
# The number of tiles this wall spans, INCLUDING the tile most central to
# the placement. e.g. 3 = a 3-tile-long wall. 4 = a 4-tile-long wall.
# The wall is built outward from the caster-relative direction at cast time —
# see ability_executor.gd's wall-placement logic for how this is centred.

@export_enum("player", "enemies", "all") var wall_blocks: String = "all"
# Who is physically blocked from entering wall tiles.
# "player"  — only player units are blocked; enemies pass through freely.
# "enemies" — only enemy units are blocked; player units pass through freely.
# "all"     — nobody can enter wall tiles, including the caster's own team.

@export var wall_blocks_line_of_sight: bool = false
# If true, wall tiles also block line-of-sight checks (pathfinder.has_line_of_sight),
# preventing ranged/magic abilities from targeting through the wall.
# If false, the wall only blocks movement — ranged attacks can still pass over it.
