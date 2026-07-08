# res://scripts/data/basic_equipment_data.gd
#
# One piece of basic equipment (Blade, Staff, Armor, etc.) — permanent,
# stats only, no special effect. 'subtype' is what forging checks against
# to find a matching AdvancedEquipmentData recipe.

class_name BasicEquipmentData
extends EquipmentData

@export_enum("blade", "staff", "armor", "mantle", "talisman", "spellbook", "monocle") var subtype: String = "blade"

@export_enum("common", "uncommon", "rare", "very_rare", "legendary") var rarity: String = "common"
# Controls shop appearance odds via shop_config.json's rarity_weights table.

@export var shop_price: int = 4
# Gold cost in the shop. (Advanced equipment is never sold directly — only
# obtained by forging two basic items together.)

@export var shop_weight_override: float = -1.0
# Leave -1 to use the shop's rarity_weights table. Set >= 0 to give THIS
# item an exact custom weight instead, ignoring rarity for shop odds only
# (does not affect shop_price).

@export var atk_bonus: int = 0
@export var matk_bonus: int = 0
@export var def_bonus: int = 0
@export var mdef_bonus: int = 0
@export var hp_bonus: int = 0
@export var mana_percent_bonus: float = 0.0
@export var crit_chance_bonus: float = 0.0
