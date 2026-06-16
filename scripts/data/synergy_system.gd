# res://scripts/battle/synergy_system.gd
#
# THE SYNERGY SYSTEM — applies passive stat bonuses based on how many allied
# units share a given "synergy tag" (e.g. "WolfPack", "Overkill", "Critical").
#
# HOW IT WORKS:
#   1. At the start of each player turn, BattleManager calls apply_synergies().
#   2. This script counts how many living player units carry each watched tag.
#   3. For each SynergyBuffData resource in synergy_definitions, it checks
#      which threshold the team currently meets.
#   4. It removes any old synergy statuses and applies fresh ones so the
#      bonuses always reflect the current team size.
#
# HOW TO ADD A SYNERGY:
#   1. Create a new .tres file from SynergyBuffData.
#   2. Set tag_required, thresholds, display_name, etc.
#   3. Drag the .tres file into the synergy_definitions array below in the
#      Inspector (or add it in code).
#
# ADDING TO THE SCENE:
#   - Add a Node to BattleScene.tscn and attach this script.
#   - Drag it into BattleManager's "synergy_system" export slot.

extends Node

@export var synergy_definitions: Array = []
# Array of SynergyBuffData resources. Add one entry per synergy in the Inspector.
# e.g. drag wolf_pack_synergy.tres, overkill_synergy.tres, etc. into this list.

# Internal tag used to mark synergy-applied statuses so we can remove them cleanly.
const SYNERGY_STATUS_PREFIX: String = "synergy_"
# Any StatusEffectData whose id starts with "synergy_" is treated as a synergy
# bonus and is removed before re-applying each round.

# ── MAIN ENTRY POINT ──────────────────────────────────────────────────────────

func apply_synergies(player_units: Array) -> void:
	# Called by BattleManager at the start of every player turn.
	# player_units = the list of all living UnitNodes on the player's team.

	if synergy_definitions.is_empty():
		return   # No synergies configured — do nothing.

	# -- Step 1: Count how many players have each tag --------------------------
	var tag_counts: Dictionary = {}
	# Key: tag string  Value: int (number of players with that tag)

	for unit in player_units:
		if not is_instance_valid(unit):
			continue
		if unit.unit_data == null:
			continue
		for tag in unit.unit_data.synergy_tags:
			if not tag_counts.has(tag):
				tag_counts[tag] = 0
			tag_counts[tag] += 1

	# -- Step 2: For each unit, clear old synergy statuses then re-apply -------
	for unit in player_units:
		if not is_instance_valid(unit):
			continue

		# Remove every status whose id starts with "synergy_".
		# We collect them first so we don't modify the array while iterating it.
		var to_remove: Array = []
		for status_entry in unit.active_statuses:
			if status_entry["data"].id.begins_with(SYNERGY_STATUS_PREFIX):
				to_remove.append(status_entry)
		for old in to_remove:
			unit.active_statuses.erase(old)

		# -- Step 3: Apply the highest qualifying threshold for each synergy ---
		for synergy_def in synergy_definitions:
			if not synergy_def is SynergyBuffData:
				continue   # Safety check in case wrong resource was added.

			var tag: String = synergy_def.tag_required

			# Decide whether this unit qualifies to receive the buff.
			var unit_has_tag: bool = tag in unit.unit_data.synergy_tags
			if not unit_has_tag and not synergy_def.apply_to_all_allies:
				continue   # This unit doesn't have the tag and it's not an "all allies" buff.

			var team_count: int = tag_counts.get(tag, 0)

			# Find the highest threshold the team currently meets.
			# Thresholds is an Array of Dictionaries sorted by "count" ascending.
			# We iterate all of them and keep the last (highest) one that fits.
			var best_threshold: Dictionary = {}
			for threshold in synergy_def.thresholds:
				if not threshold.has("count"):
					continue
				if team_count >= int(threshold["count"]):
					best_threshold = threshold

			if best_threshold.is_empty():
				continue   # Team doesn't meet the minimum threshold yet.

			# Build a temporary StatusEffectData on the fly representing the bonus.
			var bonus_status = _build_synergy_status(synergy_def, best_threshold)
			if bonus_status != null:
				unit.apply_status(bonus_status)
				print("✨ Synergy '", synergy_def.display_name, "' (×", team_count,
					  " ", tag, ") applied to ", unit.unit_data.display_name)

# ── STATUS BUILDER ────────────────────────────────────────────────────────────

func _build_synergy_status(synergy_def: SynergyBuffData, threshold: Dictionary) -> StatusEffectData:
	# Creates a StatusEffectData resource at runtime that encodes the
	# stat bonuses defined in the threshold dictionary.
	# This status is ephemeral — it is re-created every round so it always
	# reflects the current team count.

	var status = StatusEffectData.new()

	# Give the status a unique id so it can be removed cleanly next round.
	status.id            = SYNERGY_STATUS_PREFIX + synergy_def.id
	status.display_name  = synergy_def.display_name
	status.duration_rounds = 9999     # Never expires on its own — we remove it manually.
	status.is_permanent  = true       # Tells tick_statuses to ignore it.
	status.can_stack     = false      # Don't stack with itself.

	# Copy every stat bonus from the threshold dictionary into the status.
	# Each key is optional; missing keys stay at the StatusEffectData default (0).

	if threshold.has("atk_bonus"):
		status.atk_modifier = int(threshold["atk_bonus"])

	if threshold.has("matk_bonus"):
		status.matk_modifier = int(threshold["matk_bonus"])

	if threshold.has("def_bonus"):
		status.def_modifier = int(threshold["def_bonus"])

	if threshold.has("mdef_bonus"):
		status.mdef_modifier = int(threshold["mdef_bonus"])

	if threshold.has("mov_bonus"):
		status.mov_modifier = int(threshold["mov_bonus"])

	if threshold.has("crit_chance_bonus"):
		status.crit_chance_modifier = float(threshold["crit_chance_bonus"])

	if threshold.has("crit_dmg_bonus"):
		status.crit_dmg_modifier = float(threshold["crit_dmg_bonus"])

	if threshold.has("damage_dealt_bonus"):
		status.damage_dealt_modifier = float(threshold["damage_dealt_bonus"])

	if threshold.has("damage_taken_bonus"):
		status.damage_taken_modifier = float(threshold["damage_taken_bonus"])

	return status
