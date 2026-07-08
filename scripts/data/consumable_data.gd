# res://scripts/data/consumable_data.gd
#
# A one-time-use item that lives in an equipment slot until the player uses
# it during battle (self-target only, free action, one per unit per turn,
# permanently removed once used) — EXCEPT "revive", which is never manually
# used and instead triggers automatically the instant a unit would die.

class_name ConsumableData
extends EquipmentData

@export_enum("common", "uncommon", "rare", "very_rare", "legendary") var rarity: String = "common"
# e.g. tag health/mana/stat potions "common", tag Phoenix Wing "legendary".

@export var shop_price: int = 2
@export var shop_weight_override: float = -1.0

@export_enum("heal_flat", "heal_percent", "restore_mana_flat", "restore_mana_percent", "stat_buff", "revive") var effect_type: String = "heal_flat"

@export var heal_amount: int = 20          # used when effect_type == "heal_flat"
@export var heal_percent: float = 0.3      # used when effect_type == "heal_percent"
@export var mana_amount: int = 20          # used when effect_type == "restore_mana_flat"
@export var mana_percent: float = 0.3      # used when effect_type == "restore_mana_percent"

@export_enum("atk", "matk", "def", "mdef", "crit_chance", "crit_damage", "mov") var buff_stat: String = "atk"
@export var buff_amount: float = 3.0
@export var buff_duration_rounds: int = 3
# Used only when effect_type == "stat_buff".

@export var revive_percent: float = 1.0
# Used only when effect_type == "revive". Fraction of MAX HP (including
# equipment HP bonuses) restored on revival. Default 1.0 = full HP.
