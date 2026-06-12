# res://scripts/data/ability_data.gd
#
# This is a "Resource" — think of it like a data card you fill out in the
# Inspector. Every ability in the game (attacks, spells, buffs) is one of these.
# You create a new .tres file for each ability and fill in the fields.

class_name AbilityData
extends Resource

# ── IDENTITY ──────────────────────────────────────────────────────────────────

@export var id: String = ""
# A unique machine-readable name, e.g. "fireball" or "basic_slash".
# No spaces. Used to track cooldowns in dictionaries.

@export var display_name: String = ""
# The human-readable name shown on the ability button in-game.

@export var description: String = ""
# Flavour text / tooltip shown to the player.

@export var icon: Texture2D
# The small image shown on the ability button.
# Also used as the projectile / AOE visual if no effect_scene is set.

# 🆕 NEW FIELD: Optional scene used for projectile travel or AOE display.
# If you leave this empty, the system will fall back to the icon.
# If the icon is also empty, a plain white square is used.
@export var effect_scene: PackedScene

# ── COST ──────────────────────────────────────────────────────────────────────

@export var mana_cost: int = 0
@export var hp_cost_percent: float = 0.0  # e.g. 0.2 = costs 20% of max HP
@export var charge_cost: int = 0
@export var custom_resource_cost: int = 0
@export var custom_resource_name: String = ""

# ── COOLDOWN ──────────────────────────────────────────────────────────────────

@export var cooldown_rounds: int = 0  # 0 = no cooldown

# ── TARGETING ─────────────────────────────────────────────────────────────────

@export var min_range: int = 0
@export var max_range: int = 1
@export var requires_line_of_sight: bool = true
@export var can_ignore_los: bool = false

# 🆕 NEW FIELD: Who does this ability's effects apply to?
# "enemies"  — only damages / debuffs enemy units (safe for players).
# "allies"   — only heals / buffs friendly units (safe for enemies).
# "all"      — hits everyone in the area, friend and foe alike.
# This matters for AOE abilities so a group heal does not accidentally
# hurt your own team, and a fireball does not buff enemies.
@export_enum("enemies", "allies", "all") var affects_team: String = "enemies"

# ── AREA OF EFFECT ────────────────────────────────────────────────────────────

@export_enum("single", "line", "cone", "square", "cross") var aoe_shape: String = "single"
@export var aoe_size: int = 1  # radius or length depending on the shape

# ── DAMAGE ────────────────────────────────────────────────────────────────────

@export var base_damage_multiplier: float = 1.0
@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "physical"
@export var scaling_stat: String = "atk"  # "atk" uses physical attack, "matk" uses magic attack
@export var hits: int = 1  # multi-hit abilities

# ── EFFECTS ───────────────────────────────────────────────────────────────────

@export var applies_statuses: Array[StatusEffectData] = []
@export var spawns_hazard: HazardData
@export var displacement_squares: int = 0  # positive = push, negative = pull
@export var heal_percent: float = 0.0      # fraction of max HP to restore

# ── TAGS & TYPE ───────────────────────────────────────────────────────────────

@export var tags: Array[String] = []
@export_enum("basic_attack", "ability", "spell", "passive") var ability_type: String = "ability"
@export var is_counterattack_immune: bool = false
