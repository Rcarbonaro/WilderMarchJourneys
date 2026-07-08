# res://scripts/data/advanced_equipment_data.gd
#
# Forged from two BasicEquipmentData items. Always grants flat stat bonuses;
# MAY also have a special effect, identified by effect_id — a string key
# EquipmentSystem looks up in its own dispatch table (equipment_system.gd).
# Leave effect_id empty for a stats-only advanced item.

class_name AdvancedEquipmentData
extends EquipmentData

# ── FORGE RECIPE ────────────────────────────────────────────────────────────
@export_enum("blade", "staff", "armor", "mantle", "talisman", "spellbook", "monocle") var required_subtype_a: String = "blade"
@export_enum("blade", "staff", "armor", "mantle", "talisman", "spellbook", "monocle") var required_subtype_b: String = "blade"
# Order doesn't matter — forging checks both (a,b) and (b,a).

# ── ALWAYS-ON STAT BONUSES ────────────────────────────────────────────────────
@export var atk_bonus: int = 0
@export var matk_bonus: int = 0
@export var def_bonus: int = 0
@export var mdef_bonus: int = 0
@export var hp_bonus: int = 0
@export var mana_percent_bonus: float = 0.0
@export var crit_chance_bonus: float = 0.0

# ── SPECIAL EFFECT HOOK ────────────────────────────────────────────────────────
@export var effect_id: String = ""
# Matches a handler function inside equipment_system.gd's dispatch table.
# Built-in worked examples: "bloodthirster_stack", "heavy_plate_aura",
# "aegis_codex_cooldown_def". See the README for how to add new ones.

@export var effect_params: Dictionary = {}
# Tunable numbers for whichever effect_id is set, e.g. {"max_stacks": 4}.
# Lets you retune numbers in the Inspector without touching any code.
