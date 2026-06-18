# res://scripts/data/ability_data.gd
#
# This is a "Resource" — think of it like a data card you fill out in the
# Inspector. Every ability in the game (attacks, spells, buffs) is one of these.
# You create a new .tres file for each ability and fill in the fields.
#
# NEW ADDITIONS:
#   - Dash ability support (is_dash, dash_trail_texture, dash_speed)
#   - Knockback with direction choice (push away vs manual direction)
#   - Mana cost checked before casting
#   - Special effect architecture: Tether, Thorns, Shield, Guardian,
#     On-Kill, Movement-after-attack, Conditional bonus damage
 
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

@export var effect_scene: PackedScene
# Optional scene used for projectile travel or AOE display.
# Falls back to icon, then a white square.

# ── COST ──────────────────────────────────────────────────────────────────────

@export var mana_cost: int = 0
# How much mana this ability costs. Checked BEFORE casting.
# If the unit doesn't have enough, casting is blocked.

@export var hp_cost_percent: float = 0.0
# e.g. 0.2 = costs 20% of max HP when used.

@export var charge_cost: int = 0
@export var custom_resource_cost: int = 0
@export var custom_resource_name: String = ""

# ── COOLDOWN ──────────────────────────────────────────────────────────────────

@export var cooldown_rounds: int = 0
# 0 = no cooldown. After use, this many turns must pass before using again.

# ── TARGETING ─────────────────────────────────────────────────────────────────

@export var min_range: int = 0
@export var max_range: int = 1
@export var requires_line_of_sight: bool = true
@export var can_ignore_los: bool = false

@export_enum("enemies", "allies", "all") var affects_team: String = "enemies"
# "enemies"  — only damages / debuffs enemy units.
# "allies"   — only heals / buffs friendly units.
# "all"      — hits everyone in the area.

# ── AREA OF EFFECT ────────────────────────────────────────────────────────────

@export_enum("single", "line", "cone", "square", "cross") var aoe_shape: String = "single"
@export var aoe_size: int = 1
# For "line": how many tiles long. For "square": radius. For "cone": how far.

# ── DAMAGE ────────────────────────────────────────────────────────────────────

@export var base_damage_multiplier: float = 1.0
@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "physical"
@export var scaling_stat: String = "atk"
# "atk" uses physical attack, "matk" uses magic attack.

@export var hits: int = 1
# Multi-hit abilities strike this many times.

# ── EFFECTS ───────────────────────────────────────────────────────────────────

@export var applies_statuses: Array[StatusEffectData] = []
# Status effects applied to every hit target.

@export var spawns_hazard: HazardData
# If set, places a hazard tile on every affected cell.

@export var heal_percent: float = 0.0
# Fraction of max HP to restore. e.g. 0.3 = heals 30%.

# ── DISPLACEMENT (PUSH / PULL / KNOCKBACK) ─────────────────────────────────
# "Displacement" moves the target relative to the caster.
# Positive = push away. Negative = pull toward.

@export var displacement_squares: int = 0
# How many squares to move the target.
# Positive = push away from caster. Negative = pull toward caster.

@export_enum("auto", "manual", "scatter") var displacement_type: String = "auto"
# "auto"   = always pushes/pulls directly away from / toward the caster.
#            This is the classic knockback behaviour.
# "manual" = uses the displacement_manual_dir vector below instead.
#            Lets you make abilities that always push in a fixed direction
#            (e.g. an uppercut that always knocks upward regardless of facing).

@export var displacement_manual_dir: Vector2i = Vector2i(0, -1)
# Only used when displacement_direction == "manual".
# (0, -1) = always push upward. (1, 0) = always push right. Etc.

# ── DASH ABILITY ──────────────────────────────────────────────────────────────
# A "dash" is a line AOE where the CASTER travels to the last valid tile
# in the line and optionally damages everything along the way.

@export var is_dash: bool = false
# Check this box to make the caster move to the end of the line after casting.
# Only works when aoe_shape == "line".

@export var dash_damages_path: bool = true
# If true, every valid tile the caster dashes THROUGH takes damage.
# If false, only the final landing tile (or nothing) deals damage.

@export var dash_trail_texture: Texture2D
# Optional texture stretched along the full length of the dash line.
# Think of it as the "motion blur" or "slash trail" left behind.
# Leave blank for no trail visual.

@export var dash_speed: float = 800.0
# Pixels per second the caster sprite travels during the dash.
# Higher = faster dash. 800 is a good default.

@export var dash_effect_scene: PackedScene
# Optional scene to instantiate on the caster during the dash
# (e.g. a motion blur particle effect that travels with the unit).

# ── TAGS & TYPE ───────────────────────────────────────────────────────────────

@export var tags: Array[String] = []
# Arbitrary labels used for synergy checks. e.g. ["Fire", "AOE", "Overkill"]

@export_enum("basic_attack", "ability", "spell", "passive") var ability_type: String = "ability"

@export var is_counterattack_immune: bool = false
# If true, this ability cannot trigger counter-attacks.

# ── BONUS DAMAGE ISOLATED TARGETS ─────────────────────────────────────────────
# Deals extra damage to targets who have no allies standing next to them.
# "Alone" is defined as: no friendly unit occupying any of the 4 cardinal
# neighbours of the target.

@export var bonus_damage_isolated: float = 0.0
# Additional damage MULTIPLIER added when the target is isolated.
# e.g. 0.5 means +50% extra damage. 0.0 = disabled.

@export var isolated_range: int = 1
# How far away we check for allies. 1 = only immediate neighbours.

# ─────────────────────────────────────────────────────────────────────────────
# SPECIAL EFFECT ARCHITECTURE
# The fields below let you attach advanced one-off effects to any ability.
# Each group is completely optional — leave them at defaults to ignore them.
# ─────────────────────────────────────────────────────────────────────────────

# ── TETHER ────────────────────────────────────────────────────────────────────
# When a tethered unit is hit by a SINGLE-TARGET attack, a percentage of that
# damage is also dealt to all other units in the tether group.
# Tether only links ENEMIES together (one unit hits another, their allies share pain).

@export var applies_tether: bool = false
# Check this to make the ability apply a tether to the targets it hits.

@export var tether_id: String = ""
# A shared ID string. All units with the same tether_id are linked.
# e.g. "pack_bond" — all wolves in a pack share this string.

@export var tether_damage_percent: float = 0.5
# What fraction of the original damage is passed to each tethered ally.
# 0.5 = 50% of damage dealt to one tethered unit is also dealt to the others.

@export var tether_overkill_percent: float = 0.75
# If the original hit deals MORE damage than the target's remaining HP
# (i.e. the killing blow has "overkill"), tethered allies instead take
# this percentage of the original damage.
# e.g. 0.75 = 75% of the damage passes through on overkill.
# Set equal to tether_damage_percent to disable the overkill distinction.

@export var tether_duration_rounds: int = 2
# How many rounds the tether lasts before it disappears.

# ── THORNS ────────────────────────────────────────────────────────────────────
# When this unit is attacked, a portion of the damage is reflected back
# at the attacker. Thorns is applied as a STATUS on the unit, so it
# persists across turns. This field makes the ABILITY apply that status.

@export var applies_thorns: bool = false
# Check to make the ability apply a thorns status to the targets (or caster
# if affects_team == "allies").

@export var thorns_reflect_percent: float = 0.25
# What fraction of incoming damage is reflected. 0.25 = 25%.

@export_enum("atk", "matk", "def", "mdef") var thorns_scaling_stat: String = "def"
# Which stat the reflection is based on.
# "def"  = defensive thorns (rewards high-defence units for being hit).
# "atk"  = offensive thorns (punishes attackers relative to your raw power).
# "matk" = magic thorns. "mdef" = magic defence thorns.

@export var thorns_duration_rounds: int = 2
# How many rounds the thorns effect lasts.

# ── SHIELD / BARRIER ──────────────────────────────────────────────────────────
# Applies a flat damage-absorbing barrier. Damage hits the barrier first,
# and only the remaining damage (if any) touches HP.

@export var applies_shield: bool = false
# Check to make the ability apply a barrier to the target.

@export var shield_amount: int = 0
# How many points of damage the barrier absorbs before it breaks.
# e.g. 30 = the unit can take 30 damage before their HP is touched.

@export var shield_duration_rounds: int = 2
# How many rounds the shield lasts (even if it hasn't been destroyed).

# ── GUARDIAN ──────────────────────────────────────────────────────────────────
# A unit with the Guardian effect intercepts damage meant for an ally.
# When the PROTECTED unit is attacked, the Guardian takes a portion instead.

@export var applies_guardian: bool = false
# Check to make the ability give the caster a Guardian link to a target ally.

@export var guardian_redirect_percent: float = 1.0
# What fraction of the damage the Guardian absorbs. 1.0 = all of it.
# 0.5 = Guardian takes 50%, original target takes 50%.

@export_enum("caster_def", "caster_mdef", "target_def", "target_mdef") var guardian_uses_defense: String = "caster_def"
# Which def stat is used when calculating the redirected hit against the Guardian.
# "caster_def"   = the Guardian's own physical defence protects them.
# "target_def"   = the original target's physical defence is used instead (unusual).

@export var guardian_duration_rounds: int = 1
# How many rounds the Guardian link lasts.

# ── ON-KILL EFFECTS ───────────────────────────────────────────────────────────
# Something special happens when this unit lands a killing blow.

@export var has_on_kill_effect: bool = false
# Check to enable on-kill logic for this ability.

@export var on_kill_trigger_ability: PackedScene
# Optional: an ability scene spawned at the KILLED ENEMY's tile on kill.
# e.g. an explosion that damages nearby enemies.
# Leave blank if you only want the stat/turn effects below.

@export var on_kill_trigger_on_caster: bool = false
# If true, the on_kill_trigger_ability spawns at the CASTER's tile instead
# of the killed enemy's tile. Useful for "absorb soul" type effects.

@export var on_kill_reset_has_acted: bool = false
# If true, the caster's "has_acted" flag is reset, allowing them to
# use another ability this turn (effectively a bonus action).

@export var on_kill_reset_has_moved: bool = false
# If true, the caster's "has_moved" flag is also reset, letting them move again.

@export var on_kill_reset_cooldowns: bool = false
# If true, ALL of the caster's ability cooldowns are cleared on a kill.
# Great for assassin-style units that chain kills.

@export var on_kill_apply_status: StatusEffectData
# Optional: apply this status to the CASTER when they score a kill.
# e.g. a self-buff, a rage stack, etc.

# ── MOVEMENT AFTER ATTACK ─────────────────────────────────────────────────────
# After the attack resolves, the caster can move some squares.

@export var post_attack_move_squares: int = 0
# How many squares the caster can move after the attack.
# 0 = disabled. Positive = free movement squares granted.
# The player will be shown valid movement tiles after the attack.

# ── CONDITIONAL BONUS DAMAGE / STAT SCALING ───────────────────────────────────
# These let you build abilities whose power scales with the state of the battle.

# --- Bonus based on TARGET's debuff count ---
@export var bonus_per_target_debuff: float = 0.0
# Extra damage ADDED PER DEBUFF the TARGET currently has.
# e.g. 0.1 = each debuff on the enemy gives +10% more damage.

@export var bonus_per_target_debuff_max: float = 1.0
# Maximum total bonus from this source (cap). e.g. 1.0 = never more than +100%.

# --- Bonus based on CASTER's buff count ---
@export var bonus_damage_per_caster_buff: float = 0.0
# Extra damage added per BUFF the CASTER currently has.

@export var bonus_damage_per_caster_buff_max: float = 1.0
# Maximum bonus damage from caster buffs.

# --- Stat bonuses based on caster's own buff count ---
# These boost the caster's effective stats during THIS attack only.
@export var bonus_atk_per_caster_buff: int = 0
@export var bonus_matk_per_caster_buff: int = 0
@export var bonus_def_per_caster_buff: int = 0
@export var bonus_mdef_per_caster_buff: int = 0
@export var bonus_crit_chance_per_caster_buff: float = 0.0
@export var bonus_crit_dmg_per_caster_buff: float = 0.0
@export var bonus_mov_per_caster_buff: int = 0
# Each of these is multiplied by the caster's buff count.
# e.g. bonus_atk_per_caster_buff = 3, and caster has 2 buffs → +6 ATK for this hit.

@export var buff_bonus_max_stacks: int = 10
# Maximum number of buffs counted for the above per-buff bonuses.
# Prevents infinite scaling.

@export var is_aura: bool = false
@export var aura_data: AuraData
