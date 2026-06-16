# res://scripts/data/hazard_data.gd
#
# A HazardData resource defines the TEMPLATE for a hazard tile effect —
# things like poison pools, fire patches, or ice slicks.
# The actual live hazard on the grid is tracked as a Dictionary in battle_grid.gd.
#
# NEW: duration_rounds is now clamped to a maximum of 3 in the battle_grid
#      when the hazard is placed. You can set it to 1, 2, or 3 here.

class_name HazardData
extends Resource

@export var id: String = ""
# A unique machine-readable name. e.g. "fire_pool", "poison_swamp".

@export var display_name: String = ""
# Name shown in tooltips.

@export var icon: Texture2D
# Small image drawn on top of the hazard tile.

@export var duration_rounds: int = 2
# How many turns this hazard stays on the board.
# Maximum allowed is 3. The grid will clamp it automatically.

@export var is_permanent: bool = false
# If true, the hazard never expires regardless of duration_rounds.
# Use for map-placed environmental hazards (e.g. lava rivers).

# ── DAMAGE ────────────────────────────────────────────────────────────────────

@export var damage_multiplier: float = 0.4
# Damage dealt = caster_atk * damage_multiplier (using the unit that PLACED the hazard).
# If no caster is tracked, falls back to a flat 5 true damage.

@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "hazard"

# ── TRIGGER CONDITIONS ────────────────────────────────────────────────────────

@export var trigger_on_enter: bool = true
# If true: damages a unit the moment they step onto this tile.

@export var trigger_on_start_of_turn: bool = true
# If true: damages any unit that STARTS their turn standing on this tile.

@export var trigger_on_end_of_turn: bool = false
# If true: damages any unit that ENDS their turn on this tile.

# ── STATUS APPLICATION ────────────────────────────────────────────────────────

@export var applies_status: StatusEffectData
# Optional status effect applied whenever the hazard triggers.
# e.g. a fire hazard could apply a "Burning" debuff.
