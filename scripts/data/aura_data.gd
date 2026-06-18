# res://scripts/data/aura_data.gd
# ==============================================================================
# AURA DATA — The blueprint for a unit's aura effect.
# ==============================================================================
# An AuraData resource defines everything about a single aura:
#   - How big it is, who it affects, how long it lasts
#   - What damage it deals each round (and how)
#   - Which status effects it applies
#   - Which special effects are active (Crit Overload, Momentum)
#   - What it looks like (color overlay, or a custom sprite/scene)
#
# You create one of these as a .tres file in the Inspector, then attach it to
# an AbilityData resource via the "aura_data" field.
# ==============================================================================

class_name AuraData
extends Resource

# ── IDENTITY ──────────────────────────────────────────────────────────────────

@export var id: String = ""
# A unique machine-readable name. e.g. "war_aura", "healing_presence".
# Must be unique across ALL aura resources in your project.

@export var display_name: String = ""
# The human-readable name shown in tooltips.

@export var description: String = ""
# Flavour text / tooltip description.

# ── AURA TYPE ─────────────────────────────────────────────────────────────────

@export_enum("type_1", "type_2") var aura_type: String = "type_1"
# Controls stacking rules.
#
# "type_1" — Exclusive: a caster can only have ONE type_1 aura at a time.
#             Casting a new type_1 aura removes the previous one (with a fade-out).
#
# "type_2" — Stackable: any number of type_2 auras can be active at once,
#             and they also stack with a type_1 aura.
#
# Common design pattern:
#   Type 1 = the unit's "signature" persistent stance/presence.
#   Type 2 = shorter, supplemental aura effects (buffs, curses, etc.).

# ── AREA ──────────────────────────────────────────────────────────────────────

@export var radius: int = 2
# How many squares from the caster's tile the aura covers.
# Uses a square (Chebyshev) pattern — like your "square" AOE shape.
# radius=1 means the 3×3 square centred on the caster (including their tile).
# radius=2 means the 5×5 square, and so on.

# ── MOVEMENT ──────────────────────────────────────────────────────────────────

@export var follows_caster: bool = true
# Controls whether the aura zone moves with its caster (or anchor unit) as they move.
#
# TRUE  (default) — The aura is "attached" to the unit. As the caster moves,
#                   the aura's cells and visuals shift to stay centred on them.
#                   Use this for personal buff auras, war-stance zones, etc.
#
# FALSE           — The aura is "planted" at the tile where it was cast.
#                   It never moves, even if the caster walks away.
#                   The caster can leave the area entirely and it stays behind.
#                   Use this for trap zones, cursed ground, siege effects, etc.
#                   The aura still expires on its normal timer or when the caster dies.

# ── TARGETING ─────────────────────────────────────────────────────────────────

@export_enum("enemies", "allies", "all") var affects_team: String = "enemies"
# Who this aura's damage, status effects, and special effects act upon.
# "enemies" — only affects units on the OPPOSING team.
# "allies"  — only affects units on the SAME team (including the caster).
# "all"     — affects everyone, friend or foe.

# ── DURATION ──────────────────────────────────────────────────────────────────

@export var duration_rounds: int = 3
# How many full rounds the aura lasts before it expires.
# This counts down at the end of each round.
# Ignored if is_permanent_until_replaced is true (type_1) or is_permanent is true.

@export var is_permanent: bool = false
# If true, the aura NEVER expires on its own.
# For type_1 auras, this means it lasts until the caster uses another type_1 ability.
# For type_2 auras, it means it truly lasts until the caster dies or the battle ends.

# ── DAMAGE ────────────────────────────────────────────────────────────────────
# Aura damage is applied at the END of the player's round to all affected enemies
# that were inside the aura at that time.

@export_enum("none", "flat_true", "physical", "magical") var damage_mode: String = "none"
# How the aura deals damage.
#
# "none"       — No damage at all (buff/debuff aura only).
# "flat_true"  — Deals a fixed amount of true damage that bypasses all defences.
# "physical"   — Uses the normal formula: (caster.ATK - target.DEF) * multiplier.
# "magical"    — Uses the magic formula:  (caster.MATK - target.MDEF) * multiplier.

@export var flat_damage: int = 5
# Used ONLY when damage_mode is "flat_true".
# The exact damage dealt each round, no calculation, no defence reduction.

@export var damage_multiplier: float = 0.5
# Used ONLY when damage_mode is "physical" or "magical".
# Scales the stat-based damage. e.g. 0.5 = half of (ATK - DEF).
# Works exactly like ability_data.base_damage_multiplier.

# ── STATUS EFFECTS ────────────────────────────────────────────────────────────

@export var applies_statuses: Array[StatusEffectData] = []
# A list of status effects applied by this aura.
#
# HOW TIMING WORKS:
#   - On ALLIES: statuses are applied immediately when an allied unit enters
#     the aura zone. This means a unit can receive a buff before they attack
#     on the same turn.
#   - On ENEMIES: statuses are applied at the END of the player's round,
#     same timing as damage. This prevents "move aura over enemy → cancel → repeat".

# ── VISUAL ────────────────────────────────────────────────────────────────────

@export_enum("color", "sprite", "scene") var visual_type: String = "color"
# How the aura is displayed on the map.
#
# "color"  — Draws a semi-transparent ColorRect over every tile in the aura.
#             Set aura_color below.
# "sprite" — Tiles the aura area with a repeating Sprite2D.
#             Set aura_sprite below.
# "scene"  — Spawns a looping PackedScene centred on the caster's tile.
#             The scene is expected to loop indefinitely.
#             Set aura_scene below.

@export var aura_color: Color = Color(0.5, 0.0, 1.0, 0.25)
# The fill colour and transparency of the aura overlay.
# Used only when visual_type == "color".
# Alpha (the 4th number) controls how faint it is. 0.25 is a gentle glow.

@export var aura_sprite: Texture2D
# A texture tiled across every aura tile.
# Used only when visual_type == "sprite".

@export var aura_scene: PackedScene
# A looping scene (e.g. a pulsing ring of particles) placed at the caster's position.
# Used only when visual_type == "scene".

# ── SPECIAL EFFECT: CRIT OVERLOAD ─────────────────────────────────────────────
# When an enemy INSIDE this aura is hit with a critical strike, there is a
# chance that a nearby splash explosion deals bonus damage to other enemies.

@export var has_crit_overload: bool = false
# Tick this box to enable the Crit Overload special effect.

@export var crit_overload_chance: float = 30.0
# Percentage chance (0–100) that Crit Overload triggers on a crit.
# e.g. 30.0 = 30% chance.

@export var crit_overload_radius: int = 1
# The splash radius (in squares) of the Crit Overload explosion.
# Uses the same square pattern as the aura radius.
# e.g. 1 = hits the 3×3 area around the target.

@export var crit_overload_damage_percent: float = 0.5
# What fraction of the ORIGINAL crit damage the splash deals.
# e.g. 0.5 = the splash hits nearby enemies for 50% of the crit's damage.
# Damage is true damage (bypasses all defences) so every enemy feels it.

@export var crit_overload_vfx_scene: PackedScene
# Optional: a one-shot PackedScene that plays on each enemy tile hit by the splash.
# Leave blank for no animation.

# ── SPECIAL EFFECT: MOMENTUM ──────────────────────────────────────────────────
# Tracks kills made by the caster while inside this aura.
# Each kill grants permanent, stacking stat bonuses for the rest of the battle.
# If the caster dies, the bonuses are immediately removed from all recipients.

@export var has_momentum: bool = false
# Tick this box to enable the Momentum special effect.

@export_enum("caster_only", "all_allies") var momentum_applies_to: String = "caster_only"
# Who receives the per-kill stat bonuses.
# "caster_only" — only the unit who owns this aura gets the bonus.
# "all_allies"  — every ally on the player's team receives the bonus.

# ── PER-KILL STAT BONUSES ─────────────────────────────────────────────────────
# These are FLOAT values so you can use fractional bonuses.
# Fractions accumulate: e.g. 0.5 per kill → after 2 kills, the bonus is +1.
# The engine tracks the fractional total and applies floor() to get the real stat bonus.

@export var momentum_atk_per_kill: float = 0.0
# Bonus to ATK per enemy killed inside the aura.

@export var momentum_def_per_kill: float = 0.0
# Bonus to DEF per enemy killed inside the aura.

@export var momentum_matk_per_kill: float = 0.0
# Bonus to Magic ATK per enemy killed inside the aura.

@export var momentum_mdef_per_kill: float = 0.0
# Bonus to Magic DEF per enemy killed inside the aura.

@export var momentum_mov_per_kill: float = 0.0
# Bonus to MOV (movement squares) per enemy killed inside the aura.

@export var momentum_crit_chance_per_kill: float = 0.0
# Bonus to crit chance percentage per enemy killed.
# e.g. 2.5 per kill → after 4 kills, +10% crit chance.

@export var momentum_crit_damage_per_kill: float = 0.0
# Bonus to crit damage percentage per enemy killed.
# e.g. 5.0 per kill → after 4 kills, +20% crit damage.
