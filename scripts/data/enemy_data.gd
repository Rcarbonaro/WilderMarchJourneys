# res://scripts/data/enemy_data.gd
#
# EnemyData is like UnitData, but for enemies specifically. UnitData stores an
# ARRAY of stats (one per level). EnemyData stores ONE flat base_stats set —
# enemies don't level; instead ScalingEngine boosts their stats at spawn time
# based on stage index and difficulty.
#
# Also carries tier/budget_cost (for EnemySelector's budget picker) and
# pack_tags (for the "these enemies like appearing together" system).

class_name EnemyData
extends Resource

# ── IDENTITY ──────────────────────────────────────────────────────────────────

@export var id: String = ""
@export var display_name: String = ""
@export var description: String = ""

# ── TIER & BUDGET ──────────────────────────────────────────────────────────────

@export_enum("normal", "elite", "boss") var tier: String = "normal"
# "normal" — common, always available.
# "elite"  — stronger, only appears once the difficulty budget allows it.
# "boss"   — never drawn randomly; spawned via a fixed enemy group only.

@export var budget_cost: int = 10
# How much of the stage's difficulty budget this enemy consumes if picked.

# ── STATS ──────────────────────────────────────────────────────────────────────

@export var base_stats: StatsData
# UN-SCALED numbers (stage 1, easiest difficulty). ScalingEngine reads this
# and produces the "effective" stats at spawn — this .tres is never modified.

# ── VISUALS & KIT (same fields as UnitData so spawn_unit() can reuse them) ────

@export var portrait: Texture2D
@export var battle_sprite: Texture2D
@export var tile_footprint: Array = [Vector2i(0, 0)]

@export var starting_abilities: Array[AbilityData] = []
@export var abilities_by_level: Dictionary = {}
# Kept for parity with UnitData/ai_system.gd; enemies typically just use
# starting_abilities and leave this empty since enemies don't level.

@export var synergy_tags: Array[String] = []
# Gameplay/tarot hooks, e.g. "Debuff", "Hazard", "Isolation".

@export var pack_tags: Array[String] = []
# Controls which enemies like appearing TOGETHER in the same fight. Give two
# enemy types a shared tag (e.g. Wolf + Sylvaris both get "forest_pack") to
# make them more likely to be picked alongside each other. An enemy can hold
# multiple tags. Tune the strength in enemy_selection_config.json.
