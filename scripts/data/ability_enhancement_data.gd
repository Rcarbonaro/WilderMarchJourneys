# res://scripts/data/ability_enhancement_data.gd
#
# ABILITY ENHANCEMENT DATA -- one type of improvement a Skill Scroll can
# unlock on an ability. Create .tres instances of this under
# res://resources/enhancements/, one per distinct enhancement you want
# available (e.g. "more_damage_15.tres", "plus_one_range.tres",
# "guardian_self.tres").
#
# HOW THIS FITS TOGETHER:
#   1. You assign a POOL of these to an ability's own eligible_enhancements
#      array (see ability_data.gd) -- "this ability CAN receive these".
#   2. A Skill Scroll item (a "consumable" equipment JSON with
#      "consumable_type": "skill_scroll") lets the player pick a unit, one
#      of that unit's abilities, then one of ITS eligible_enhancements.
#   3. The chosen enhancement's id gets appended to that party member's
#      party["ability_enhancements"][ability_id] array (see run_state.gd) --
#      this is what actually persists across saves.
#   4. At battle setup, unit_node.gd's _build_enhanced_abilities() sums every
#      applied enhancement for each ability and builds ONE enhanced
#      duplicate per ability -- see that function for exactly how each
#      enhancement_type gets folded into the ability's fields. Multiple
#      enhancements on the same ability ADD together (e.g. two
#      "damage_percent" scrolls each worth +0.15 stack to +0.30 total) --
#      per your explicit design call, nothing here ever OVERWRITES a base
#      ability field, only adds to it.

class_name AbilityEnhancementData
extends Resource

@export var id: String = ""
# Unique machine-readable id, e.g. "more_damage_15". This is what actually
# gets stored in a party member's applied-enhancements list, so once players
# have this applied in a live save, treat the id as permanent -- rename the
# display_name/description freely, but don't change id after release.

@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D

@export_enum(
	"damage_percent",             # base_damage_multiplier += magnitude
	"range",                      # max_range += int(magnitude)
	"post_attack_move",           # post_attack_move_squares += int(magnitude)
	"aoe_size",                   # aoe_size += int(magnitude)
	"isolated_damage",            # bonus_damage_isolated += magnitude
	"double_hit_chance",          # double_hit_chance += magnitude (0.0-1.0)
	"guardian_self",              # applies_guardian_to_self = true (see ability_data.gd)
	"guardian_target",            # applies_guardian = true (reuses the existing ability field/mechanic as-is)
	"thorns_self",                # applies_thorns_to_self = true
	"thorns_target",              # applies_thorns = true (reuses existing field/mechanic)
	"shield_target",              # applies_shield = true (reuses existing field/mechanic)
	"reset_cooldown_on_kill",     # has_on_kill_effect = true, on_kill_reset_cooldowns = true
	"restore_mana_on_kill",       # has_on_kill_effect = true, on_kill_restore_mana_amount += int(magnitude)
	"add_buff",                   # applies_statuses_to_self.append(attached_status)
	"add_debuff",                 # applies_statuses.append(attached_status)
	"bonus_per_target_debuff",    # bonus_per_target_debuff += magnitude (an EXISTING field -- your ".25 -> .35" example)
	"bonus_per_caster_buff",      # bonus_damage_per_caster_buff += magnitude (existing field, same idea)
	"no_friendly_fire"            # affects_team forced to "enemies" if currently "all" (one-time correction, not additive -- see note on this type in unit_node.gd's _build_enhanced_abilities())
) var enhancement_type: String = "damage_percent"

@export var magnitude: float = 0.0
# Meaning depends on enhancement_type -- see the comments next to each enum
# option above. Ignored entirely for guardian_self/guardian_target/
# thorns_self/thorns_target/shield_target/reset_cooldown_on_kill/add_buff/
# add_debuff/no_friendly_fire, which are just on/off or reference a resource
# instead (see below).

@export var attached_status: StatusEffectData = null
# ONLY used when enhancement_type is "add_buff" or "add_debuff". Drag in
# whichever status this scroll should attach. "add_buff" appends it to the
# ability's applies_statuses_to_self (applied to the CASTER on every use);
# "add_debuff" appends to applies_statuses (applied to every hit TARGET).


static func build_enhanced_description(base_description: String, applied_ids: Array,
		eligible_enhancements: Array) -> String:
	# Appends a gold "Enhancements" header + one line per currently-applied
	# enhancement below the ability's own normal description. Shared by the
	# in-battle ability tooltip (ui_manager.gd) and the "More Info" character
	# sheet (unit_info_popup.gd) so applied Skill Scroll enhancements always
	# show up wherever the ability's description is shown. Returns
	# base_description unchanged if nothing is applied.
	var safe_base: String = base_description.replace("[", "[lb]")
	if applied_ids.is_empty():
		return safe_base

	# Count how many times each id appears -- two copies of the same scroll
	# on one ability show as "x2" instead of two duplicate lines.
	var counts: Dictionary = {}
	for eid in applied_ids:
		counts[eid] = int(counts.get(eid, 0)) + 1

	var lines: Array[String] = []
	for eid in counts.keys():
		var display: String = eid   # fallback if it can't be resolved
		for candidate in eligible_enhancements:
			if candidate != null and candidate.id == eid:
				display = candidate.display_name
				break
		display = display.replace("[", "[lb]")
		var count: int = counts[eid]
		lines.append(display + ("  x%d" % count if count > 1 else ""))

	const GOLD := Color(0.831, 0.702, 0.31, 1.0)
	var block := "\n\n[color=#%s]Enhancements[/color]\n%s" % [GOLD.to_html(false), "\n".join(lines)]
	return safe_base + block
	
