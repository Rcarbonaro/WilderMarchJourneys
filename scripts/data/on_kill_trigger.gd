#================================================================================
#  C.  res://scripts/data/on_kill_trigger.gd                               (NEW)
#================================================================================
# Sub-resource used inside SpecialEffectData when effect_type = "on_kill".
# Each instance defines ONE thing that happens when the caster kills a unit.
# Add multiple of these to SpecialEffectData.on_kill_triggers[] for combos.
#
# HOW TO USE:
#   Inside a SpecialEffectData with effect_type="on_kill", open on_kill_triggers,
#   add a new OnKillTrigger, set trigger_type, and fill in relevant fields.

class_name OnKillTrigger
extends Resource

@export_enum(
	"self_buff",         # Apply a status effect to the caster
	"ability_at_target", # Fire an ability centred on the dead unit's tile
	"ability_at_caster", # Fire an ability centred on the caster's tile
	"refresh_turn"       # Give the caster a fresh turn (move + act again)
) var trigger_type: String = "self_buff"

# ── SELF BUFF ─────────────────────────────────────────────────────────────────

@export var buff_to_apply: StatusEffectData
# The status effect given to the CASTER when they land a kill.
# Only used when trigger_type = "self_buff".

# ── ABILITY TRIGGERS ──────────────────────────────────────────────────────────

@export var ability_to_fire: AbilityData
# The ability that auto-fires upon kill.
# For "ability_at_target": centred on the dead unit's tile (e.g. an explosion).
# For "ability_at_caster": centred on the caster's tile (e.g. a shockwave).
# The ability fires with the caster as the source — their ATK/MATK is used.
# AOE, damage, and effects all resolve normally from AbilityExecutor.

# ── REFRESH TURN ──────────────────────────────────────────────────────────────
# No extra fields needed for trigger_type = "refresh_turn".
# BattleManager will give the caster a full new turn (movement + action)
# immediately after the kill resolves.
# Be careful: refreshed turns can themselves trigger another on-kill,
# allowing kill-chains.  This is intentional but balance with care.
