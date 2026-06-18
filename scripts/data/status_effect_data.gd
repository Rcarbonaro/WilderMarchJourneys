# res://scripts/data/status_effect_data.gd

# 📤 EXPORTS TO: AbilityData (abilities apply these), UnitManager (units track active instances)

class_name StatusEffectData

extends Resource

@export var id: String = ""

@export var display_name: String = ""

@export var description: String = ""

@export var icon: Texture2D  # drag a small icon here in the Inspector

# Duration

@export var duration_rounds: int = 1   # how many rounds it lasts

@export var is_permanent: bool = false

# Stacking

@export var can_stack: bool = false    # check this box if it stacks

@export var max_stacks: int = 1

# When it expires: "end_of_enemy_round" or "end_of_player_round"

@export_enum("end_of_enemy_round", "end_of_player_round") var expires_at: String = "end_of_enemy_round"

# Can it be cleansed?

@export var cleansable: bool = true

# Stat changes while this is active (flat amounts, can be negative)

@export var atk_modifier: int = 0

@export var def_modifier: int = 0

@export var matk_modifier: int = 0

@export var mdef_modifier: int = 0

@export var mov_modifier: int = 0

@export var crit_chance_modifier: float = 0.0

@export var damage_taken_modifier: float = 0.0   # e.g. 0.1 = take 10% more damage

@export var damage_dealt_modifier: float = 0.0   # e.g. -0.25 = deal 25% less damage

# Trigger effects (damage over time, etc.)

@export_enum("none", "start_of_turn", "end_of_turn", "on_enter_tile") var trigger_timing: String = "none"

@export var trigger_damage_multiplier: float = 0.0  # 0 = no trigger damage

@export_enum("physical", "magical", "hazard", "true") var trigger_damage_type: String = "physical"

# Special flags

@export var is_root: bool = false        # movement = 0

@export var is_stun: bool = false        # skip turn entirely

@export var is_invisible: bool = false   # untargetable by ranged

@export var grants_immunity: bool = false # blocks all debuffs

@export_group("Visuals")
@export var animation_suffix: String = "" # e.g., "_armored", "_poisoned"
