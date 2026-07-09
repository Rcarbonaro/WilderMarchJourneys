# res://scripts/state/run_state.gd
#
# RUN STATE -- everything about the CURRENT run that needs to persist between
# stages (and across a save/quit/reload). This is the upgraded replacement
# for the existing RunData resource, adding the fields the new non-combat
# systems need.
#
# DESIGN NOTE ON UNITS: each unit is stored as a small Dictionary rather than
# a fully computed stat block. We deliberately do NOT store final calculated
# stats -- we store the INGREDIENTS (unit_id, level, equipped items, and any
# permanent stat deltas from tarot/encounters) and let combat recompute the
# real numbers when the unit is spawned. This means future balance changes
# to a unit's base stats automatically apply to old saves too, instead of
# being locked in at save time.

class_name RunState
extends Resource

# ---- IDENTITY / META ----------------------------------------------------------
@export var run_id: String = ""
@export var player_seed: int = 0
@export var draft_or_random_mode: String = "random"   # "random" | "draft"
@export var difficulty: String = "normal"               # "normal" | "hard" | "nightmare"

# ---- PROGRESSION ----------------------------------------------------------------
@export var stage_index: int = 1
# Absolute stage number, 1 through 30 (per project decision: scaling and
# content lookups use this directly, NOT a per-biome relative number).
# Use ContentLoader.get_stage_type(stage_index) and
# ContentLoader.get_biome_slot(stage_index) to translate this into "what
# kind of stage is this" and "which of my 3 biomes am I in right now".

@export var biome_sequence: Array[String] = []
# The 3 biomes this run will visit, in order, e.g. ["forest","swamp","plains"].

# ---- RESOURCES -------------------------------------------------------------------
@export var gold: int = 10
@export var equipment_inventory: Array[String] = []   # equipment ids not currently equipped on anyone

# ---- PARTY ------------------------------------------------------------------------
# Each entry is a Dictionary shaped like:
# {
#   "unit_id": "hexweaver",                  # which UnitData resource this is
#   "instance_id": "hexweaver_173829",       # unique per copy (duplicates from "The Gemini" etc.)
#   "level": 1,
#   "equipped_item_ids": ["blade", null, null],   # 3 slots, null = empty
#   "permanent_modifiers": [ {"stat":"atk","amount":1,"value_mode":"flat","source":"the_blade_strength"} ],
# }
@export var party: Array = []     # max 4 active units
@export var bench: Array = []     # max 6 benched units

# ---- TAROT -------------------------------------------------------------------------
@export var tarot_cards: Array = []
# Each entry: { "tarot_id": "the_execution_overkill", "stacks": 1 }

# ---- RUN FLAGS & HISTORY ------------------------------------------------------------
@export var flags: Array[String] = []
@export var encounters_completed: Array[String] = []

# ---- SHOP MODIFIERS (written by tarot/encounter effects, read by ShopEngine) --------
@export var shop_slot_modifier: int = 0
@export var drop_rate_modifiers: Array = []     # [{"resource": "...", "multiplier": 1.3}]
@export var shop_price_modifiers: Array = []    # [{"resource": "all", "multiplier": 1.0, "amount": 0}]
@export var shop_inventory: Array = []          # currently-offered shop entries, refreshed by ShopEngine

# ---- CROSS-BATTLE RUNTIME STATE -----------------------------------------------------
@export var runtime_effect_state: Dictionary = {}
# A generic bucket for any persistent counter that needs to survive a save,
# e.g. {"famine_gold_owed": 2}. Most equipment/aura mechanics reset every
# battle and don't need anything stored here -- this exists so a FUTURE
# mechanic that DOES need to persist across a save never requires a new field.


func to_dict() -> Dictionary:
    return {
        "run_id": run_id, "player_seed": player_seed,
        "draft_or_random_mode": draft_or_random_mode, "difficulty": difficulty,
        "stage_index": stage_index, "biome_sequence": biome_sequence,
        "gold": gold, "equipment_inventory": equipment_inventory,
        "party": party, "bench": bench, "tarot_cards": tarot_cards,
        "flags": flags, "encounters_completed": encounters_completed,
        "shop_slot_modifier": shop_slot_modifier,
        "drop_rate_modifiers": drop_rate_modifiers,
        "shop_price_modifiers": shop_price_modifiers,
        "shop_inventory": shop_inventory,
        "runtime_effect_state": runtime_effect_state,
    }


static func from_dict(data: Dictionary) -> RunState:
    var rs := RunState.new()
    rs.run_id = data.get("run_id", "")
    rs.player_seed = data.get("player_seed", 0)
    rs.draft_or_random_mode = data.get("draft_or_random_mode", "random")
    rs.difficulty = data.get("difficulty", "normal")
    rs.stage_index = data.get("stage_index", 1)
    rs.biome_sequence.assign(data.get("biome_sequence", []))
    rs.gold = data.get("gold", 10)
    rs.equipment_inventory.assign(data.get("equipment_inventory", []))
    rs.party = data.get("party", [])
    rs.bench = data.get("bench", [])
    rs.tarot_cards = data.get("tarot_cards", [])
    rs.flags.assign(data.get("flags", []))
    rs.encounters_completed.assign(data.get("encounters_completed", []))
    rs.shop_slot_modifier = data.get("shop_slot_modifier", 0)
    rs.drop_rate_modifiers = data.get("drop_rate_modifiers", [])
    rs.shop_price_modifiers = data.get("shop_price_modifiers", [])
    rs.shop_inventory = data.get("shop_inventory", [])
    rs.runtime_effect_state = data.get("runtime_effect_state", {})
    return rs
