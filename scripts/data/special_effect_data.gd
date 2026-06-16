#================================================================================
#  B.  res://scripts/data/special_effect_data.gd                           
#================================================================================
# A sub-resource that encodes advanced, non-damage effects on an ability.
# One AbilityData can hold an Array of these, letting you combine effects.
#
# HOW TO USE:
#   1. Open your AbilityData resource in the Inspector.
#   2. In the "special_effects" array, click Add Element.
#   3. Choose "New SpecialEffectData".
#   4. Set the "effect_type" enum to the effect you want.
#   5. Fill in only the fields relevant to that effect type.
#      (Fields for other effect types are simply ignored.)

class_name SpecialEffectData
extends Resource

# ── EFFECT TYPE ───────────────────────────────────────────────────────────────

@export_enum(
	"tether",           # Share incoming single-target damage across chained units
	"thorns",           # Reflect damage back to the attacker
	"shield",           # Absorb a flat amount of damage before HP is touched
	"marked",           # Next hit against this unit deals bonus damage
	"guardian",         # Redirect an ally's incoming damage to self
	"on_kill",          # Trigger effects when the caster lands a killing blow
	"post_attack_move", # Caster may move X squares freely after attacking
	"conditional_stat"  # Passive stat bonus based on buff/debuff counts
) var effect_type: String = "tether"

# ════════════════════════════════════════════════════════════════════════════
#  TETHER FIELDS
#  effect_type = "tether"
#  Apply this ability to a unit to tether them into a damage-sharing chain.
#  When a tethered unit receives a single-target attack, a % of that damage
#  is also dealt to every other unit in the chain.
# ════════════════════════════════════════════════════════════════════════════

@export var tether_damage_share: float = 0.5
# Fraction of damage forwarded to each other tethered unit.
# 0.5 = 50% of the incoming damage is also dealt to each chained ally.
# This is calculated AFTER the original target's defence is applied —
# i.e. it shares the final HP-reducing number, not the raw hit.

@export var tether_overkill_share: float = 0.75
# When the damage dealt EXCEEDS the original target's current HP
# (i.e. the target dies from the hit), the excess "overkill" portion is
# forwarded at this separate rate instead of tether_damage_share.
# Example: target has 10 HP, takes 30 damage.
#   Normal share applies to the 10 that "counted".
#   Overkill share applies to the 20 excess.
# Set equal to tether_damage_share if you don't want different overkill rules.

@export var tether_duration_turns: int = 2
# How many turns the tether lasts before it expires automatically.

# ════════════════════════════════════════════════════════════════════════════
#  THORNS FIELDS
#  effect_type = "thorns"
#  When the unit bearing this effect is hit by an attack, a portion of the
#  damage is reflected back to the attacker.
# ════════════════════════════════════════════════════════════════════════════

@export var thorns_reflect_percent: float = 0.3
# Fraction of the damage received that is reflected.
# 0.3 = 30% of incoming damage is dealt back to the attacker.

@export_enum("atk","matk","def","mdef") var thorns_scaling_stat: String = "def"
# Which stat on the BEARER (the unit with Thorns) determines reflect power.
# The reflected amount = thorns_reflect_percent * bearer's chosen stat.
# Common choices: "def" (physical wall reflects back) or "atk" (aggressive).
# Note: this is additive on top of the percent — you can set
# thorns_reflect_percent = 0 and use purely stat-based reflect if preferred.

@export var thorns_duration_turns: int = 2
# How many turns Thorns stays active on the bearer.

# ════════════════════════════════════════════════════════════════════════════
#  SHIELD / BARRIER FIELDS
#  effect_type = "shield"
#  The unit absorbs up to shield_amount damage before HP is touched.
#  The shield is depleted as damage hits it and disappears when empty.
# ════════════════════════════════════════════════════════════════════════════

@export var shield_amount: int = 20
# Total HP the shield can absorb.  Every incoming hit reduces this first.
# When it hits 0, further damage spills over to actual HP.

@export var shield_duration_turns: int = 2
# How many turns the shield persists.  Removed when duration expires OR
# when shield_amount reaches 0, whichever comes first.

# ════════════════════════════════════════════════════════════════════════════
#  MARKED FIELDS
#  effect_type = "marked"
#  The next single hit against the Marked unit deals bonus damage.
#  The mark is consumed on first hit.
# ════════════════════════════════════════════════════════════════════════════

@export var mark_bonus_damage: int = 0
# Flat bonus damage added on top of the next hit.

@export_enum("atk","matk") var mark_scaling_stat: String = "atk"
# Which stat on the ORIGINAL CASTER (the unit who applied the mark) is
# added to the bonus damage.
# Final bonus = mark_bonus_damage + caster's mark_scaling_stat.

@export var mark_duration_turns: int = 2
# If the Marked unit is never hit, the mark expires after this many turns.

# ════════════════════════════════════════════════════════════════════════════
#  GUARDIAN FIELDS
#  effect_type = "guardian"
#  The Guardian intercepts single-target attacks aimed at a protected ally.
#  The Guardian absorbs the full redirected damage (they can die from it).
# ════════════════════════════════════════════════════════════════════════════

@export var guardian_redirect_percent: float = 1.0
# What fraction of the incoming damage the Guardian absorbs.
# 0.5 = Guardian takes 50% of the hit, protected ally takes the other 50%.
# 1.0 = Guardian absorbs the entire hit (ally takes nothing).

@export_enum("guardian_def","target_def") var guardian_mitigation_source: String = "guardian_def"
# Which unit's defence stats reduce the redirected damage:
#   "guardian_def" → the Guardian's own DEF/MDEF reduces the incoming hit.
#   "target_def"   → the original target's DEF/MDEF is used instead.

@export var guardian_duration_turns: int = 2
# How many turns the Guardian protection lasts.

# ════════════════════════════════════════════════════════════════════════════
#  ON-KILL FIELDS
#  effect_type = "on_kill"
#  Triggers one or more effects when the caster lands a killing blow.
#  Add multiple SpecialEffectData with type "on_kill" to get multiple triggers.
# ════════════════════════════════════════════════════════════════════════════

@export var on_kill_triggers: Array[OnKillTrigger] = []
# An Array of OnKillTrigger sub-resources (see on_kill_trigger.gd).
# Each trigger independently fires when a kill happens.
# Example: [SelfBuff trigger, ExplosionAbility trigger, RefreshTurn trigger]

# ════════════════════════════════════════════════════════════════════════════
#  POST-ATTACK MOVEMENT FIELDS
#  effect_type = "post_attack_move"
#  After using this ability, the caster is allowed to move up to X squares
#  freely in any direction (player chooses, like a normal move action).
# ════════════════════════════════════════════════════════════════════════════

@export var post_attack_move_squares: int = 2
# Maximum number of squares the caster can move after the attack resolves.
# The player is shown a movement range overlay and picks a destination,
# exactly like a normal move action but with this reduced range.
# 0 = no post-attack movement (disable the effect entirely).

# ════════════════════════════════════════════════════════════════════════════
#  CONDITIONAL STAT BONUS FIELDS
#  effect_type = "conditional_stat"
#  Passive bonuses recalculated at the start of every turn.
#  Add multiple SpecialEffectData with this type for multiple conditions.
# ════════════════════════════════════════════════════════════════════════════

@export var conditional_bonuses: Array[ConditionalStatBonus] = []
# An Array of ConditionalStatBonus sub-resources (see conditional_stat_bonus.gd).
# Each bonus independently watches its condition and applies its stat modifier.
