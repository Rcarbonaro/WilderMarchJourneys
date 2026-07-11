# res://scripts/battle/ability_executor.gd
#
# THE ABILITY EXECUTOR — the "referee" that applies ability effects.
# BattleManager calls execute_ability() after the player (or AI) confirms a
# target. This script handles damage, healing, status effects, hazards,
# displacement, dash movement, and all special effect architecture.
#
# NEW ADDITIONS:
#   - Mana gate: abilities are blocked if the caster can't afford them
#   - Dash: caster travels to the last valid tile on the line
#   - Displacement: "auto" (away/toward caster) and "manual" (fixed direction)
#   - Knockback: same as displacement_auto — uses displacement system
#   - Tether: damage passes to tethered allies
#   - Thorns: reflect damage to attacker
#   - Shield/Barrier: absorbs flat damage before HP
#   - Guardian: redirect damage from ally to Guardian unit
#   - On-Kill: trigger scenes, reset turns, reset cooldowns, apply self-buff
#   - Post-attack movement: grant extra movement squares after attacking
#   - Conditional bonus damage (target debuffs, caster buffs)
#   - Bonus damage to isolated targets (no allies nearby)
#   - Large-unit deduplication: AOE only damages a multi-tile unit once
#   - Aura activation: abilities marked is_aura activate an AuraData zone
#   - Crit Overload: notifies AuraManager when a crit lands inside an aura
#   - Momentum: notifies AuraManager when a kill happens inside an aura
#   - Cluster-push fix: multi-target push/pull/scatter abilities now resolve
#     ALL of their targets' movement together, in an order that won't leave
#     a unit stuck behind a teammate who's also being pushed in the same
#     cast — see _resolve_pending_displacements for the full explanation.
#   - Wall-drag fix: a diagonal push/pull/scatter that grazes a wall on just
#     ONE axis now slides along the wall using whichever axis is still open,
#     instead of stopping dead the instant the diagonal tile is blocked —
#     see _try_step_with_wall_drag for the full explanation.
#   - Cleanse: abilities marked is_cleanse strip cleansable statuses AND any
#     cleansable aura the target themselves casts/carries from being hit.

extends Node

# ── EXTERNAL REFERENCES ───────────────────────────────────────────────────────

var grid_ref: Node = null
# Set by BattleManager on startup.
# We use grid_ref to look up units at cells, check passability, and access
# the special-effect maps (shield_map, thorns_map, guardian_map, tether_map).

var aura_manager: Node = null
# Set by BattleManager on startup, alongside grid_ref.
# Used to activate auras when an aura ability is used, and to fire
# Crit Overload and Momentum events when crits and kills happen.

var pathfinder_ref: Node = null
# Set by BattleManager on startup, alongside grid_ref. Used by automatic
# Chain Lightning bounces to respect walls/line-of-sight the exact same way
# every other targeting in the game does, instead of reimplementing its own
# distance math with no obstacle awareness.


# ── GLOBAL HP-COST TRACKING ───────────────────────────────────────────────────

var total_hp_consumed: int = 0
# Running total of HP spent as an ability cost across ALL units this battle
# (player and enemy alike — see _check_unleash_threshold below if you want to
# restrict this to player-only spending instead).
# BattleManager reads this after every execute_ability call (the same pattern
# already used for total_mana_spent/ARCANA_THRESHOLD) to decide when to unlock
# the Unleash ability. Reset to 0 by BattleManager at the start of each battle.

# ── INTERNAL STATE ────────────────────────────────────────────────────────────

var _last_hit_was_crit: bool = false
# Set to true inside calculate_damage() whenever a critical hit is rolled.
# Read inside _apply_damage_with_effects() to decide whether to fire Crit Overload.
# Reset to false at the START of every calculate_damage() call so it is always
# accurate for the most recent hit.

# ── MAIN ENTRY POINT ──────────────────────────────────────────────────────────

func execute_ability(caster, ability: AbilityData, target_cells: Array,
					 origin_cell: Vector2i = Vector2i(-1, -1),
					 raw_target_cells: Array = []) -> void:
	# Called by BattleManager (player) and AISystem (enemy).
	#
	# Parameters:
	#   caster       — The UnitNode using the ability.
	#   ability      — The AbilityData resource describing what it does.
	#   target_cells — The list of grid cells to affect (already filtered by team).
	#   origin_cell  — For line/cone shapes, the cell the player aimed at
	#                  (used to determine dash direction).
	#   raw_target_cells — ONLY used for dash abilities. The SAME line, but
	#                  BEFORE team-filtering removed any cells. Dash needs the
	#                  complete, gapless line (including ally-occupied cells)
	#                  to correctly figure out where it physically has to stop
	#                  — team-filtering is appropriate for deciding who takes
	#                  DAMAGE, but it actively breaks distance/obstacle
	#                  calculations if used for the MOVEMENT part of a dash.
	#                  Falls back to target_cells if left empty, which keeps
	#                  every existing non-dash caller working unmodified.

	# ── STEP 0: CASTER VALIDITY + MANA GATE ──────────────────────────────────
	# Check the caster is still alive first. It's possible for an aura's entry
	# damage to kill the caster between when the ability was queued and when this
	# function actually runs (e.g. an enemy walks into a thorns aura and dies).
	if not is_instance_valid(caster):
		return

	# Check BEFORE doing anything else. If the unit can't afford this,
	# and they don't have an Arcana Charge, abort immediately.
	if not caster.has_arcana_charge and not caster.can_afford_ability(ability):
		print("⛔ ", caster.unit_data.display_name, " cannot afford '",
			  ability.display_name, "' (needs ", ability.mana_cost, " mana, has ",
			  caster.current_mana, ")")
		return

	print("🌵 execute_ability called: ", ability.display_name,
		  " | target_cells: ", target_cells,
		  " | caster: ", caster.unit_data.display_name)
	CombatHooks.run_before_ability_used(caster, ability)

	# ── STEP 1: APPLY COSTS ───────────────────────────────────────────────────
	# Deduct mana and HP cost immediately (before damage resolves).
	# If they have an Arcana Charge, consume it instead of mana.
	if caster.has_arcana_charge and ability.consumes_arcana_charge:
		caster.has_arcana_charge = false
		print("✨ Arcana Charge consumed by ", caster.unit_data.display_name)
		caster.play_animation("idle")
	else:
		caster.spend_mana(ability.mana_cost)

	var hp_cost_paid: int = 0
	if ability.hp_cost_percent > 0:
		# Guarantee at least 1 HP is actually spent when hp_cost_percent > 0 —
		# int() truncates toward zero, so a small percent on a low-HP unit
		# (e.g. 0.05 * 12 HP = 0.6 → truncates to 0) previously could compute
		# a cost of 0 and silently cost nothing despite the field being set.
		hp_cost_paid = max(1, int(caster.get_stats().hp * ability.hp_cost_percent))
		caster.take_damage(hp_cost_paid, "true")
		if not is_instance_valid(caster):
			return   # Caster killed themselves with HP cost — nothing more to do.

	# ── GLOBAL CONSUMED-HP TRACKING ───────────────────────────────────────────
	# Report the HP actually spent back through a static accumulator so
	# BattleManager can track the party-wide "consumed HP" total used to
	# unlock the powerful Unleash ability once it crosses the threshold.
	# We use a static var here (rather than routing through BattleManager)
	# so EVERY caller of execute_ability — player abilities, AI abilities,
	# anything — contributes automatically with no extra wiring needed.
	if hp_cost_paid > 0:
		total_hp_consumed += hp_cost_paid
		print("💉 HP cost paid: ", hp_cost_paid, " | Total HP consumed this battle: ", total_hp_consumed)

	# ── STEP 2: DASH ──────────────────────────────────────────────────────────
	# A "dash" is a line AOE where the CASTER physically moves to the last
	# valid tile. We resolve the caster's movement BEFORE applying damage so
	# the caster lands in the correct position first.
	var dash_landing_cell: Vector2i = Vector2i(-1, -1)

	if ability.is_dash and ability.aoe_shape == "line":
		# Use the COMPLETE, unfiltered line for movement (see the
		# raw_target_cells doc above) — team-filtering must never be allowed
		# to put gaps in the line dash physically travels through.
		var dash_line_cells: Array = raw_target_cells if not raw_target_cells.is_empty() else target_cells
		var dash_result: Dictionary = await _execute_dash(caster, ability, dash_line_cells)
		dash_landing_cell = dash_result["landing_cell"]
		var max_reach_cell: Vector2i = dash_result["max_reach_cell"]

		# Bound the DAMAGE-relevant cells to the dash's full PIERCE range
		# (max_reach_cell — stops only at a real wall/hazard), NOT to where
		# the caster's body specifically landed (dash_landing_cell — stops at
		# the first occupied tile, since the caster can't overlap a unit).
		# Using landing_cell here was the bug: a dash through multiple
		# enemies would stop counting damage right after the FIRST one,
		# since that's as far as the caster's own body could go.
		var reach_index: int = dash_line_cells.find(max_reach_cell)
		if reach_index != -1:
			var truncated_cells: Array = []
			for cell in target_cells:
				var cell_index: int = dash_line_cells.find(cell)
				if cell_index != -1 and cell_index <= reach_index:
					truncated_cells.append(cell)
			target_cells = truncated_cells

	# ── STEP 2.5: WALL PLACEMENT ───────────────────────────────────────────────
	# Wall abilities don't damage units or apply statuses through the normal
	# target loop — they place an impassable hazard across target_cells
	# (already computed by battle_manager's two-tap wall placement flow) and
	# then exit early. spawns_hazard must have is_wall_hazard = true.
	if ability.aoe_shape == "wall":
		if ability.spawns_hazard == null:
			printerr("❌ Wall ability '", ability.display_name, "' has no spawns_hazard assigned!")
		elif not ability.spawns_hazard.is_wall_hazard:
			printerr("❌ Wall ability '", ability.display_name,
					 "' spawns_hazard is not flagged is_wall_hazard!")
		else:
			grid_ref.place_wall(target_cells, ability.spawns_hazard, caster)
			print("🧱 Wall placed across ", target_cells.size(), " tiles by ",
				  caster.unit_data.display_name)

		# Cooldown still applies even though we skip the rest of the pipeline.
		# Cooldown still applies even though we skip the rest of the pipeline.
		if ability.cooldown_rounds > 0:
			caster.ability_cooldowns[ability.id] = ability.cooldown_rounds
		return

	# ── STEP 2.6: CHAIN LIGHTNING ──────────────────────────────────────────────
	if ability.aoe_shape == "chain":
		await _execute_chain_lightning(caster, ability, target_cells)
		if ability.cooldown_rounds > 0 and is_instance_valid(caster):
			caster.ability_cooldowns[ability.id] = ability.cooldown_rounds
		return

	# ── STEP 2.7: MULTI-TARGET (Zephyr Strike-style) ───────────────────────────
	if ability.aoe_shape == "multi_target":
		await _execute_multi_target_strike(caster, ability, target_cells)
		if ability.cooldown_rounds > 0 and is_instance_valid(caster):
			caster.ability_cooldowns[ability.id] = ability.cooldown_rounds
		return

	# ── STEP 2.8: LEAP ──────────────────────────────────────────────────────────
	# NOTE: 'origin_cell' is repurposed here to carry the DESTINATION tile
	# chosen in battle_manager's two-tap Leap flow, since target_cells only
	# ever holds the single enemy target cell for this ability type.
	if ability.is_leap:
		await _execute_leap(caster, ability, target_cells, origin_cell)
		if ability.cooldown_rounds > 0 and is_instance_valid(caster):
			caster.ability_cooldowns[ability.id] = ability.cooldown_rounds
		return

	# ── STEP 3: COLLECT UNIQUE UNIT TARGETS AND APPLY EFFECTS ─────────────────

	# ── STEP 3: COLLECT UNIQUE UNIT TARGETS AND APPLY EFFECTS ─────────────────
	# Large units occupy multiple cells. We track which UnitNode references we
	# have already hit so a 2×2 unit doesn't take damage 4 times from one AOE.
	var already_hit: Array = []   # Filled with UnitNode references.

	# Collected during the loop below, then resolved all at once AFTER the
	# loop finishes (see _resolve_pending_displacements) — this is what fixes
	# multi-target pushes/pulls/scatters on a cluster of enemies: we need to
	# know about EVERY target before deciding the safe order to move them in.
	var pending_displacements: Array = []   # [{ "target": UnitNode }, ...]

	# If the caster was invisible, attacking reveals them. remove_status()
	# refreshes sprite transparency itself now, so no separate call needed here.
	if caster.has_status("invisible"):
		caster.remove_status("invisible")
		print("👁️ ", caster.unit_data.display_name, " revealed by attacking!")

	for cell in target_cells:
		var target = grid_ref.get_unit_at(cell)
		print("🔍 cell: ", cell, " | target: ", target)

		# Don't let a unit damage themselves with an enemies-only ability.
		if target == caster and ability.base_damage_multiplier > 0 and ability.affects_team == "enemies":
			continue

		# ── DAMAGE ────────────────────────────────────────────────────────────
		# Only deal damage if the ability has a multiplier and there is a target.
		# Deduplicate: large units occupying multiple cells only take damage once.
		if ability.base_damage_multiplier > 0 and target != null:
			if not target in already_hit:
				already_hit.append(target)
				var damage = calculate_damage(caster, target, ability)
				# _apply_damage_with_effects handles guardian, shield, thorns,
				# tether, and now also Crit Overload via _last_hit_was_crit.
				_apply_damage_with_effects(caster, target, ability, damage)

		# ── STATUS EFFECTS ────────────────────────────────────────────────────
		# Apply status effects to the target (if any) from the ability's list.
		# We pass 'caster' through as source_caster so Taunt knows who to force
		# attacks toward, and DoT can scale damage off the correct unit's stats.
		if target != null:
			for status_data in ability.applies_statuses:
				target.apply_status(status_data, 1, caster)

		# ── TETHER APPLICATION ────────────────────────────────────────────────
		# If this ability applies a tether, register the hit unit in the group.
		# All tethered units share a portion of damage dealt to any one of them.
		if ability.applies_tether and target != null:
			if grid_ref.has_method("register_tether"):
				grid_ref.register_tether(target, ability.tether_id)
				if not ability.tether_id in target.tether_ids:
					target.tether_ids.append(ability.tether_id)

		# ── SHIELD APPLICATION ────────────────────────────────────────────────
		# Gives the target a damage-absorbing barrier of flat HP.
		if ability.applies_shield and target != null:
			grid_ref.apply_shield(target, ability.shield_amount, ability.shield_duration_rounds)

		# ── THORNS APPLICATION ────────────────────────────────────────────────
		# When the target is hit, they reflect a portion of damage back to the attacker.
		if ability.applies_thorns and target != null:
			grid_ref.apply_thorns(target, ability.thorns_reflect_percent,
								  ability.thorns_scaling_stat, ability.thorns_duration_rounds)

		# ── GUARDIAN APPLICATION ──────────────────────────────────────────────
		# "Guardian" makes the CASTER intercept damage aimed at the TARGET ally.
		if ability.applies_guardian and target != null:
			grid_ref.apply_guardian(target, caster,
									ability.guardian_redirect_percent,
									ability.guardian_uses_defense,
									ability.guardian_duration_rounds)

		# ── SPAWN HAZARD ──────────────────────────────────────────────────────
		# Places a hazard tile at the target cell (e.g. fire, poison pool).
		if ability.spawns_hazard != null:
			grid_ref.add_hazard(cell, ability.spawns_hazard, caster)

		# ── DISPLACEMENT / KNOCKBACK / SCATTER ────────────────────────────────
		# Don't move the target yet — just remember that they need to be
		# displaced. We resolve ALL of this cast's displacements together,
		# right after this loop, in an order that won't get units stuck
		# behind each other (see _resolve_pending_displacements for why).
# Don't queue a unit for displacement if the hit that was just applied
		# above already killed them. die() defers actual cleanup a few frames
		# (so the death animation can play), so 'target' can still be a valid,
		# non-null reference here even though it's now mid-death — sliding a
		# dying unit's corpse toward a push tile is both visually wrong AND
		# the root cause of a hang (see _resolve_pending_displacements' final
		# wait loop below) if its death cleanup frees the node before the
		# push's own movement tween finishes.
		if ability.displacement_squares != 0 and target != null and not target._death_started:
			pending_displacements.append({"target": target})
			
		# ── HEALING ───────────────────────────────────────────────────────────
		# Restores a percentage of the target's max HP (or the caster's if no target).
		if ability.heal_percent > 0.0:
			var heal_target = target if target != null else caster
			var max_hp      = heal_target.get_stats().hp
			heal_target.heal(int(max_hp * ability.heal_percent))

		# ── CLEANSE ───────────────────────────────────────────────────────────
		# Strips every cleansable status from the target, and any cleansable
		# aura the target themselves is the caster/owner of (a curse-aura
		# attached to them) — see AbilityData.is_cleanse for the full story.
		if ability.is_cleanse:
			var cleanse_target = target if target != null else caster
			var cleansed_count: int = cleanse_target.cleanse_statuses()
			if aura_manager != null:
				cleansed_count += aura_manager.cleanse_auras_for(cleanse_target)
			if cleansed_count > 0:
				print("✨ Cleansed ", cleansed_count, " effect(s) from ",
					  cleanse_target.unit_data.display_name)

	# ── STEP 3.3: RESOLVE DISPLACEMENT (PUSH/PULL/SCATTER) ────────────────────
	# For displacement abilities: start the VFX at the same moment we begin
# moving the pushed/pulled units so the tornado plays OVER the movement
# instead of appearing after everyone has already slid to their new tiles.
# The VFX is fired without await so it runs concurrently as a coroutine.
	var _concurrent_vfx_started := false
	if not pending_displacements.is_empty() and not ability.is_aura and not ability.is_dash \
			and target_cells.size() > 0:
		_concurrent_vfx_started = true
		if ability.aoe_shape == "single":
			_launch_projectile(caster, ability, target_cells[0])   # fire-and-forget
		else:
			_play_aoe_vfx(caster, ability, target_cells, origin_cell)  # fire-and-forget

	await _resolve_pending_displacements(caster, ability, pending_displacements, target_cells)

	# ── STEP 3.4: SELF-STATUS APPLICATION ─────────────────────────────────────
	# Applies any statuses in applies_statuses_to_self to the CASTER, once per
	# cast (not once per target cell). This runs regardless of affects_team or
	# whether the caster happened to be inside the AOE — it always lands.
	# Use this to combine a taunt-the-enemies effect with a buff-myself effect
	# in a single ability: put the taunt status in applies_statuses (with
	# affects_team = "enemies") and the buff status here.
	if not is_instance_valid(caster):
		return
	for self_status in ability.applies_statuses_to_self:
		if self_status != null:
			caster.apply_status(self_status, 1, caster)

	# ── STEP 3.5: AURA ACTIVATION ─────────────────────────────────────────────
	# If this ability activates an aura, tell the AuraManager to register it.
	# This runs AFTER the normal target loop so any direct hit on the initial
	# target still resolves first (e.g. an ability that both damages and places
	# an aura simultaneously).
	if ability.is_aura and ability.aura_data != null and aura_manager != null:
		aura_manager.activate_aura(caster, ability.aura_data)
		print("🌀 Aura activated: '", ability.aura_data.id,
			  "' by ", caster.unit_data.display_name)

	# ── STEP 4: COOLDOWN ──────────────────────────────────────────────────────
	# Put this ability on cooldown so it cannot be used again immediately.
	if ability.cooldown_rounds > 0:
		caster.ability_cooldowns[ability.id] = ability.cooldown_rounds

	# ── STEP 5: POST-ATTACK MOVEMENT ─────────────────────────────────────────
	# If the ability grants the caster extra movement squares after attacking,
	# set the flag on the unit so BattleManager can handle the input next turn.
	if ability.post_attack_move_squares > 0:
		caster.pending_post_attack_moves = ability.post_attack_move_squares

	# ── STEP 6: LAUNCH PROJECTILE / VFX ─────────────────────────────────────
	# Visual only — all game logic above is already applied.
	# Aura abilities skip projectile VFX (the aura visual handles its own display).
	if ability.is_aura:
		pass   # AuraManager handles aura visuals; no projectile needed.
	elif ability.is_dash and ability.dash_effect_scene != null:
		pass   # Future: trigger a dash trail particle system here.
	elif not ability.is_dash and target_cells.size() > 0 and not _concurrent_vfx_started:
		if ability.aoe_shape == "single":
			await _launch_projectile(caster, ability, target_cells[0])
		else:
			await _play_aoe_vfx(caster, ability, target_cells, origin_cell)
	CombatHooks.run_after_ability_used(caster, ability)

# ── DAMAGE APPLICATION (with Shield / Thorns / Guardian / Tether / Crit Overload) ──

func _apply_damage_with_effects(caster, target, ability: AbilityData, damage: int) -> void:
	# This is the full damage pipeline. Each step can absorb, redirect, or
	# reflect a portion of the damage before it touches the target's HP.
	#
	# We also read _last_hit_was_crit (set by calculate_damage just before this
	# is called) to fire the Crit Overload event when relevant.

	# -- 1. GUARDIAN CHECK ─────────────────────────────────────────────────────
	# If a Guardian is protecting this unit, they intercept a portion of the hit.
	var guardian_entry = grid_ref.get_guardian_for(target)
	if not guardian_entry.is_empty() and is_instance_valid(guardian_entry["guardian"]):
		var guardian = guardian_entry["guardian"]
		var redirect_pct: float = guardian_entry["redirect_percent"]

		# Calculate how much damage the Guardian takes.
		# The "uses_defense" setting decides which stat mitigates the redirected hit.
		var redirected_dmg = int(damage * redirect_pct)
		var remaining_dmg  = damage - redirected_dmg

		var guard_dmg = redirected_dmg
		match guardian_entry["uses_defense"]:
			"caster_def":   guard_dmg = max(1, redirected_dmg - guardian.get_effective_def())
			"caster_mdef":  guard_dmg = max(1, redirected_dmg - guardian.get_effective_mdef())
			"target_def":   guard_dmg = max(1, redirected_dmg - target.get_effective_def())
			"target_mdef":  guard_dmg = max(1, redirected_dmg - target.get_effective_mdef())

		# Guardian's own Thorns/Shield do NOT apply to the redirected portion.
		guardian.take_damage(guard_dmg, ability.damage_type)
		# THE FIX: take_damage() already spawns its own floating damage
		# number via CombatFeedback.show_hit() — this extra call was
		# spawning a SECOND number for the same hit. Same bug as Thorns and
		# Tether below.
		print("🛡️ Guardian intercepted ", guard_dmg, " damage for ", target.unit_data.display_name)
		
		damage = remaining_dmg
		if damage <= 0:
			_last_hit_was_crit = false   # Reset the flag even if we abort early.
			return   # Guardian absorbed everything.

	# -- 2. SHIELD CHECK ───────────────────────────────────────────────────────
	# The target's barrier absorbs incoming damage before it touches HP.
	if grid_ref.has_method("absorb_shield_damage"):
		var damage_before_shield: int = damage
		damage = grid_ref.absorb_shield_damage(target, damage)

		var blocked_amount: int = damage_before_shield - damage
		if blocked_amount > 0:
			# White number = "this damage never touched your HP", distinct
			# from the red/orange/yellow numbers for real HP loss.
			_spawn_damage_number(blocked_amount, target.position, Color.WHITE)

		if damage <= 0:
			print("🛡️ Shield absorbed all damage for ", target.unit_data.display_name)
			_last_hit_was_crit = false   # Reset the flag even if we abort early.
			return


	# -- 3. APPLY DAMAGE TO TARGET ─────────────────────────────────────────────
	var hp_before_damage: int = target.current_hp
	var actual_damage = target.take_damage(damage, ability.damage_type, _last_hit_was_crit)
	CombatHooks.run_damage_applied_reactions(caster, target, actual_damage, _last_hit_was_crit)

	# -- 3.5 CRIT OVERLOAD ─────────────────────────────────────────────────────
	# If this hit was a critical strike AND the caster has an active aura with
	# Crit Overload enabled, notify the AuraManager so it can roll the splash.
	# _last_hit_was_crit is set inside calculate_damage() for the most recent hit.
	if _last_hit_was_crit and aura_manager != null:
		aura_manager.on_critical_hit(caster, target, actual_damage)
	# Always reset after reading so the next non-crit hit doesn't falsely trigger.
	_last_hit_was_crit = false

	# -- 4. THORNS REFLECTION ──────────────────────────────────────────────────
	# After the hit lands, check if the target has Thorns active.
	# If so, reflect a portion of damage back to the CASTER.
	var thorns_entry = grid_ref.get_thorns(target)
	if not thorns_entry.is_empty() and is_instance_valid(caster):
		var stat_name: String = thorns_entry["scaling_stat"]
		var stat_value: int   = 0
		match stat_name:
			"atk":   stat_value = target.get_effective_atk()
			"matk":  stat_value = target.get_effective_matk()
			"def":   stat_value = target.get_effective_def()
			"mdef":  stat_value = target.get_effective_mdef()

		var reflect_dmg = max(1, int(int(float(stat_value)) * thorns_entry["reflect_percent"]
									 * (1.0 + float(stat_value) / 100.0)))
		caster.take_damage(reflect_dmg, "true")   # Thorns use true damage.
		# THE FIX: take_damage() already spawns its own floating damage
		# number via CombatFeedback.show_hit() — this extra call was
		# spawning a duplicate second number for the same reflected hit.
		print("🌵 Thorns reflected ", reflect_dmg, " to ", caster.unit_data.display_name)
		
	# -- 5. TETHER PROPAGATION ─────────────────────────────────────────────────
	# Only for SINGLE-TARGET abilities. If the target is tethered, pass a portion
	# of the damage to every other unit in the same tether group.
	if ability.aoe_shape == "single" and target.tether_ids.size() > 0:
		for tether_id in target.tether_ids:
			var tethered = grid_ref.get_tethered_units(tether_id, target)
			for ally in tethered:
				if not is_instance_valid(ally):
					continue
				# Overkill hits pass a larger percentage to tether-mates.
				var is_overkill = (hp_before_damage - actual_damage) <= 0 and actual_damage > hp_before_damage
				var tether_pct: float   = 0.5
				var overkill_pct: float = 0.75
				var pass_damage = int(actual_damage * (overkill_pct if is_overkill else tether_pct))
				pass_damage = max(1, pass_damage)
				var ally_actual = grid_ref.absorb_shield_damage(ally, pass_damage) \
								  if grid_ref.has_method("absorb_shield_damage") else pass_damage
				ally.take_damage(ally_actual, "true")   # Tether uses true damage.
				# THE FIX: same duplicate-number bug as Guardian/Thorns above —
				# take_damage() already spawns its own number.
	# -- 6. ON-KILL CHECK ──────────────────────────────────────────────────────
	# If the target just died from this hit (HP was above 0 before, now at/below 0),
	# trigger on-kill effects. This also notifies Momentum via _trigger_on_kill.
	if hp_before_damage > 0 and target.current_hp <= 0:
		_trigger_on_kill(caster, ability, target)
		EventBus.publish("on_enemy_defeated", {
			"caster": caster, "target": target,
			"overkill_amount": max(0, actual_damage - hp_before_damage),        })
		print("DEBUG: Kill confirmed for ", target.unit_data.display_name)

# ── ON-KILL HANDLER ───────────────────────────────────────────────────────────

func _trigger_on_kill(caster, ability: AbilityData, dead_target) -> void:
	# Called immediately after a killing blow is confirmed.
	# Handles ability on-kill effects AND notifies the AuraManager for Momentum.
	if not is_instance_valid(caster):
		return

	# ── MOMENTUM NOTIFICATION ──────────────────────────────────────────────────
	# Tell the AuraManager that a kill happened. It will check whether the killed
	# unit was inside any of the caster's Momentum auras, and if so, award the
	# per-kill stat bonuses. We do this BEFORE checking has_on_kill_effect so that
	# Momentum always fires even on abilities without other on-kill effects.
	if aura_manager != null:
		aura_manager.on_unit_killed_inside_aura(caster, dead_target)

	# ── STANDARD ON-KILL EFFECTS ──────────────────────────────────────────────
	# All the logic below only runs if the ability has on-kill effects enabled.
	if not ability.has_on_kill_effect:
		return

	print("💀 On-Kill triggered by ", caster.unit_data.display_name)

	# -- Spawn a trigger ability scene at the kill location or the caster's tile.
	if ability.on_kill_trigger_ability != null:
		var spawn_cell: Vector2i
		if ability.on_kill_trigger_on_caster:
			spawn_cell = caster.grid_position
		else:
			# Use caster position as fallback; improve by storing last_position on die().
			spawn_cell = caster.grid_position
		var trigger_scene = ability.on_kill_trigger_ability.instantiate()
		var spawn_root = _get_spawn_root()
		if spawn_root != null:
			spawn_root.add_child(trigger_scene)
			trigger_scene.position = grid_ref.grid_to_world(spawn_cell)

	# -- Apply a self-buff to the caster on kill.
	if ability.on_kill_apply_status != null:
		caster.apply_status(ability.on_kill_apply_status)
		print("✨ Condition successfully applied to: ", caster.unit_data.display_name)

	# -- Reset action flags so the caster can act again this turn.
	if ability.on_kill_reset_has_acted:
		caster.has_acted = false
		print("   ↺ ", caster.unit_data.display_name, " reset: can act again!")

	if ability.on_kill_reset_has_moved:
		caster.has_moved = false
		print("   ↺ ", caster.unit_data.display_name, " reset: can move again!")

	# -- Reset all cooldowns so the caster can reuse abilities immediately.
	if ability.on_kill_reset_cooldowns:
		caster.ability_cooldowns.clear()
		print("   ↺ All cooldowns cleared for ", caster.unit_data.display_name)

# ── DAMAGE FORMULA ────────────────────────────────────────────────────────────

func calculate_damage(caster, target, ability: AbilityData) -> int:
	# The core formula: (ATK - DEF) * multiplier, modified by conditions.
	# Also sets _last_hit_was_crit = true if a crit is rolled, so that
	# _apply_damage_with_effects can fire Crit Overload immediately after.

	if not is_instance_valid(target) or not is_instance_valid(caster):
		return 0

	# Reset the crit flag at the start of every damage calculation so that a
	# previous crit can never bleed into a different hit.
	_last_hit_was_crit = false

	# -- 1. Base offensive / defensive stats ──────────────────────────────────
	var offensive_stat: int = 0
	var defensive_stat: int = 0

	# The ability's scaling_stat field says which attack stat to use.
	match ability.scaling_stat:
		"atk":
			offensive_stat = caster.get_effective_atk()
		"matk":
			offensive_stat = caster.get_effective_matk()
		_:
			# Default to ATK if an unrecognised stat is set.
			offensive_stat = caster.get_effective_atk()

	match ability.damage_type:
		"physical":  defensive_stat = target.get_effective_def()
		"magical":   defensive_stat = target.get_effective_mdef()
		"hazard":    defensive_stat = target.get_effective_mdef()
		"true":      defensive_stat = 0   # True damage ignores all defense.

	# TEMPORARY DEBUG — remove once the Stonewarden damage mystery is solved.
	print("🔎 DMG DEBUG | ability='", ability.display_name,
		  "' damage_type=", ability.damage_type,
		  " | caster=", caster.unit_data.display_name, " offensive_stat=", offensive_stat,
		  " | target=", target.unit_data.display_name,
		  " base_def=", target.get_stats().def, " get_effective_def=", target.get_effective_def(),
		  " base_mdef=", target.get_stats().mdef, " get_effective_mdef=", target.get_effective_mdef(),
		  " defensive_stat_used=", defensive_stat,
		  " | target statuses: ", target.active_statuses.map(func(s): return "%s(def%+d,mdef%+d)x%d" % [s["data"].display_name, s["data"].def_modifier, s["data"].mdef_modifier, s["stacks"]]),
		  " | target momentum_bonuses: ", target.momentum_bonuses)
		
	# -- 2. Per-buff stat bonuses (only for this attack) ──────────────────────
	# These are bonuses the ability adds to the caster's EFFECTIVE stats for
	# this single hit, based on how many buffs the caster has active.
	var caster_buff_count: int = min(caster.get_buff_count(), ability.buff_bonus_max_stacks)
	offensive_stat += ability.bonus_atk_per_caster_buff  * caster_buff_count
	offensive_stat += ability.bonus_matk_per_caster_buff * caster_buff_count
	defensive_stat -= ability.bonus_def_per_caster_buff  * caster_buff_count
	# (More defence on caster = less net damage dealt; hence the subtraction.)

	# -- 3. Base damage calculation ───────────────────────────────────────────
	var base: float = float(offensive_stat - defensive_stat) * ability.base_damage_multiplier

	# -- # -- 4. Critical hit check ────────────────────────────────────────────────
	var crit_chance: float = caster.get_effective_crit_chance()
	crit_chance += ability.bonus_crit_chance_per_caster_buff * float(caster_buff_count)

	# Crit chance can't push a hit past 100% "more critical" — any excess
	# converts into bonus CRIT DAMAGE instead, at a 1:2 rate (each 1% of
	# crit chance over 100 becomes +2% crit damage).
	var overflow_crit_damage_bonus: float = 0.0
	if crit_chance > 100.0:
		overflow_crit_damage_bonus = (crit_chance - 100.0) * 2.0
		crit_chance = 100.0

	var roll: float = randf() * 100.0

	if roll < crit_chance:
		print("⚡ CRITICAL HIT!")

		# ── SET THE CRIT FLAG ──────────────────────────────────────────────────
		# _apply_damage_with_effects reads this right after we return, so it
		# knows to notify the AuraManager for Crit Overload.
		_last_hit_was_crit = true

		# Use get_effective_crit_damage() so Momentum crit_damage bonuses are
		# included. This replaces the old direct read of get_stats().crit_damage.
		var crit_dmg_pct: float = caster.get_effective_crit_damage()
		crit_dmg_pct += ability.bonus_crit_dmg_per_caster_buff * float(caster_buff_count)
		crit_dmg_pct += overflow_crit_damage_bonus


		# Recalculate base damage using the boosted attack value.
		var crit_atk: int = int(offensive_stat * (crit_dmg_pct / 100.0))
		base = float(crit_atk - defensive_stat) * ability.base_damage_multiplier

	# -- 5. Status modifiers on the TARGET ────────────────────────────────────
	# If the target has debuffs that make them take more damage, apply those here.
	if "active_statuses" in target and target.active_statuses != null:
		for s in target.active_statuses:
			if s.has("data") and "damage_taken_modifier" in s["data"]:
				base *= (1.0 + s["data"].damage_taken_modifier)

	# -- 6. Conditional bonus damage (target debuffs) ─────────────────────────
	# e.g. an ability that does +10% per debuff the enemy has.
	if ability.bonus_per_target_debuff > 0.0:
		var debuff_count: int = target.get_debuff_count()
		var debuff_bonus: float = min(
			float(debuff_count) * ability.bonus_per_target_debuff,
			ability.bonus_per_target_debuff_max
		)
		base *= (1.0 + debuff_bonus)

	# -- 7. Conditional bonus damage (caster buffs) ───────────────────────────
	if ability.bonus_damage_per_caster_buff > 0.0:
		var buff_bonus: float = min(
			float(caster_buff_count) * ability.bonus_damage_per_caster_buff,
			ability.bonus_damage_per_caster_buff_max
		)
		base *= (1.0 + buff_bonus)

	# -- 8. Isolated target bonus ─────────────────────────────────────────────
	# Bonus damage if the target has no allies standing nearby.
	if ability.bonus_damage_isolated > 0.0:
		if _is_target_isolated(target, ability.isolated_range):
			base *= (1.0 + ability.bonus_damage_isolated)
			print("🎯 Isolated target bonus: +", ability.bonus_damage_isolated * 100, "%")

	var final_damage = max(1, int(base))
	final_damage = CombatHooks.run_outgoing_damage_modifiers(caster, target, final_damage, _last_hit_was_crit)
	return final_damage


func _is_target_isolated(target, check_range: int) -> bool:
	# Returns true if no ally of the TARGET is within check_range tiles.
	# "Ally" = a unit on the same team (same is_player_unit flag).
	# Uses Manhattan distance so diagonals count correctly.
	for dx in range(-check_range, check_range + 1):
		for dy in range(-check_range, check_range + 1):
			if dx == 0 and dy == 0:
				continue   # Skip the target's own cell.
			if abs(dx) + abs(dy) > check_range:
				continue   # Outside Manhattan distance range.
			var check_cell = target.grid_position + Vector2i(dx, dy)
			var unit_there = grid_ref.get_unit_at(check_cell)
			if unit_there != null and unit_there != target:
				if unit_there.is_player_unit == target.is_player_unit:
					return false   # Found an ally nearby — NOT isolated.
	return true   # No allies found — the target is isolated!

# ── DASH ──────────────────────────────────────────────────────────────────────

func _execute_dash(caster, ability: AbilityData, line_cells: Array) -> Dictionary:
	# Moves the caster along a line. Returns a Dictionary with TWO different
	# cells, because a dash needs to track two different things at once:
	#
	#   "landing_cell"   — where the caster's BODY actually ends up. This is
	#                      the FARTHEST tile in the line that's both walkable
	#                      AND unoccupied. The caster can never end up
	#                      standing on the same tile as another unit, but it
	#                      CAN keep going past/through units to reach an
	#                      empty tile further down the line (e.g. landing in
	#                      a gap beyond a cluster of enemies).
	#   "max_reach_cell" — how far the dash's effect reaches for DAMAGE
	#                      purposes. This only stops at an actual wall or
	#                      movement-blocking hazard — it completely ignores
	#                      whether units are standing in the way, so the dash
	#                      correctly pierces through and damages every enemy
	#                      along the whole line, not just up to wherever the
	#                      caster's body happens to physically stop.
	#
	# THE BUG THIS FIXES: an earlier fix (for units becoming permanently
	# unclickable when a dash landed on top of them) made the line-walking
	# loop stop dead at the FIRST occupied tile — treating an enemy exactly
	# like a wall. That accidentally also capped the damage range at "right
	# before the first enemy," so a dash with multiple enemies in its line
	# would only ever reach (and not even damage) the very first one. Tracking
	# landing and damage-reach separately fixes both: the caster still never
	# overlaps another unit, but the dash now actually runs THROUGH everyone
	# in the line and damages all of them, same as it's supposed to.
	if line_cells.is_empty():
		return {"landing_cell": caster.grid_position, "max_reach_cell": caster.grid_position}

	var landing_cell: Vector2i = caster.grid_position
	var max_reach_cell: Vector2i = caster.grid_position

	for cell in line_cells:
		# A real wall or movement-blocking hazard stops the line completely
		# — nothing (caster OR damage) can get past this point.
		if not grid_ref.is_terrain_walkable(cell):
			break
		max_reach_cell = cell   # Damage reach extends here regardless of who's standing on it.
		if grid_ref.is_passable(cell):
			landing_cell = cell   # Only update where the caster can LAND if this tile is actually free.
		# (If the tile is occupied, we just don't update landing_cell — but
		# we keep scanning further down the line in case there's empty space
		# beyond this unit to land in instead.)

	var end_world: Vector2 = grid_ref.grid_to_world(landing_cell)
	var start_world: Vector2 = caster.position

	# snap_to() updates BOTH the grid registration (so other game logic
	# already sees the caster as standing at landing_cell — needed before the
	# damage loop runs) AND the visual position (it jumps caster.position
	# straight to end_world as its very last line). We want the grid update
	# right away, but NOT the instant visual jump — that's what the tween
	# below is for. So immediately after snap_to(), we put the VISUAL
	# position back to where the caster actually started, and let the tween
	# carry it the rest of the way. Without this, the tween below would
	# animate from end_world to end_world (since snap_to already moved it)
	# and the dash would just look like an instant teleport with no slide.
	caster.snap_to(landing_cell)
	caster.position = start_world

	# Spawn an optional trail texture along the dash line. Uses 'start_world'
	# and 'end_world' directly (captured above) rather than caster.position,
	# since caster.position only reflects the true starting point for a
	# brief moment here before the tween below starts moving it.
	if ability.dash_trail_texture != null:
		_spawn_dash_trail(start_world, end_world, ability.dash_trail_texture)

	# Animate the caster sprite racing to the destination.
	# Animate the caster sprite racing to the destination.
	# THE FIX: play the dash animation itself for the duration of the
	# slide — this used to only ever get set to "idle" AFTER the tween
	# finished, so whatever animation was already playing before the dash
	# (attack, idle, etc.) just kept running while the sprite visually
	# slid across the map instead of actually playing a dash animation.
	if ability.dash_animation_name != "":
		caster.play_animation(ability.dash_animation_name)

	var distance: float = start_world.distance_to(end_world)
	var duration: float = distance / ability.dash_speed

	var tween = get_tree().create_tween()
	tween.tween_property(caster, "position", end_world, duration)\
		.set_trans(Tween.TRANS_LINEAR)\
		.set_ease(Tween.EASE_IN_OUT)

	await tween.finished
	caster.play_animation("idle")
	return {"landing_cell": landing_cell, "max_reach_cell": max_reach_cell}

func _spawn_dash_trail(from_world: Vector2, to_world: Vector2,
					   trail_texture: Texture2D) -> void:
	# Creates a stretched sprite that covers the entire dash line visually.
	# Auto-deletes after 0.5 seconds.
	var spawn_root = _get_spawn_root()
	if spawn_root == null:
		return

	var trail = Sprite2D.new()
	trail.texture = trail_texture
	trail.position = (from_world + to_world) / 2.0
	trail.rotation = from_world.angle_to_point(to_world)

	# Scale so the trail fills the distance exactly.
	var pixel_length: float = from_world.distance_to(to_world)
	var tex_size: Vector2   = trail_texture.get_size()
	if tex_size.x > 0 and tex_size.y > 0:
		trail.scale = Vector2(pixel_length / tex_size.x, 96.0 / tex_size.y)
	else:
		trail.scale = Vector2(pixel_length / 96.0, 1.0)

	trail.modulate = Color(1, 1, 1, 0.7)
	spawn_root.add_child(trail)

	var tween = get_tree().create_tween()
	tween.tween_property(trail, "modulate:a", 0.0, 0.5)
	tween.tween_callback(trail.queue_free)

# ── CHAIN LIGHTNING ────────────────────────────────────────────────────────────

func _execute_chain_lightning(caster, ability: AbilityData, target_cells: Array) -> void:
	if target_cells.is_empty():
		return
	var first_target = grid_ref.get_unit_at(target_cells[0])
	if first_target == null or not is_instance_valid(first_target):
		return

	# Build the full ordered hit list: the first target, then either the
	# player's own manually-tapped secondary targets (already in
	# target_cells, in tap order) or automatically-found nearest unhit
	# enemies within chain_range of the previous hit, one at a time.
	var chain_targets: Array = [first_target]

	if ability.chain_manual_targets:
		for i in range(1, target_cells.size()):
			var t = grid_ref.get_unit_at(target_cells[i])
			if t != null and is_instance_valid(t) and not t in chain_targets:
				chain_targets.append(t)
	else:
		var previous = first_target
		for _i in range(ability.aoe_size):
			var next_target = _find_nearest_chain_target(
				previous, caster, chain_targets, ability.chain_range, ability.requires_line_of_sight
			)
			if next_target == null:
				break
			chain_targets.append(next_target)
			previous = next_target

	# ── FIRST BOUNCE: caster → first target ───────────────────────────────
	var first_scene: PackedScene = ability.chain_bounce_scene_first if ability.chain_bounce_scene_first != null else ability.effect_scene
	await _play_bounce_scene(caster.position, first_target, first_scene)
	if is_instance_valid(first_target):
		var dmg = calculate_damage(caster, first_target, ability)
		_apply_damage_with_effects(caster, first_target, ability, dmg)

	if chain_targets.size() < 2:
		return

	# ── SECONDARY BOUNCES: first target → each other target ───────────────
	var secondary_targets: Array = chain_targets.slice(1)
	var secondary_scene: PackedScene = ability.chain_bounce_scene_secondary
	if secondary_scene == null:
		secondary_scene = first_scene

	if ability.chain_simultaneous:
		# Fire-and-forget, same pattern already used for displacement VFX
		# elsewhere in this file — each bounce independently times its own
		# damage against the end of ITS OWN animation.
		var started: int = 0
		for t in secondary_targets:
			_play_bounce_and_damage(caster, first_target.position, t, ability, secondary_scene)
			started += 1
		if started > 0:
			await get_tree().create_timer(0.6).timeout
	else:
		for t in secondary_targets:
			await _play_bounce_and_damage(caster, first_target.position, t, ability, secondary_scene)


func _find_nearest_chain_target(previous, caster, already_hit: Array, chain_range: int, requires_los: bool = true):
	# Nearest enemy to 'previous' within chain_range, excluding anyone
	# already hit this cast.
	#
	# THE FIX: this used to scan every unit on the grid with its own
	# hand-rolled Manhattan distance check and NO wall/line-of-sight
	# awareness at all — a bounce could jump straight through a wall to hit
	# something "close" on the other side, which reads as the chain hitting
	# further/through more than it should. Routing through
	# pathfinder_ref.get_cells_in_range() + has_line_of_sight() makes an
	# automatic bounce respect obstacles exactly the same way every other
	# targeting in the game already does (regular ability ranges, and the
	# manual chain-tap highlighting).
	if pathfinder_ref == null:
		printerr("⚠️ ability_executor: pathfinder_ref is null — chain lightning ",
				 "auto-targeting can't check line of sight. Did BattleManager ",
				 "set executor.pathfinder_ref in _ready()?")

	var candidate_cells: Array = []
	if pathfinder_ref != null:
		candidate_cells = pathfinder_ref.get_cells_in_range(previous.grid_position, 1, chain_range)
	else:
		# No pathfinder available — fall back to the old raw-distance scan
		# rather than finding nothing at all.
		for dx in range(-chain_range, chain_range + 1):
			for dy in range(-chain_range, chain_range + 1):
				if abs(dx) + abs(dy) <= chain_range and abs(dx) + abs(dy) > 0:
					candidate_cells.append(previous.grid_position + Vector2i(dx, dy))

	var best = null
	var best_dist: int = 999999
	for cell in candidate_cells:
		var candidate = grid_ref.get_unit_at(cell)
		if candidate == null or not is_instance_valid(candidate):
			continue
		if candidate in already_hit:
			continue
		if candidate.is_player_unit == caster.is_player_unit:
			continue
		if requires_los and pathfinder_ref != null:
			if not pathfinder_ref.has_line_of_sight(previous.grid_position, candidate.grid_position):
				continue

		var dist: int = abs(candidate.grid_position.x - previous.grid_position.x) \
					  + abs(candidate.grid_position.y - previous.grid_position.y)
		if dist < best_dist:
			best_dist = dist
			best = candidate
	return best


func _play_bounce_and_damage(caster, from_world: Vector2, target, ability: AbilityData, scene: PackedScene) -> void:
	if not is_instance_valid(target):
		return
	await _play_bounce_scene(from_world, target, scene)
	if is_instance_valid(target):
		var dmg = calculate_damage(caster, target, ability)
		_apply_damage_with_effects(caster, target, ability, dmg)


func _play_bounce_scene(from_world: Vector2, target, scene: PackedScene) -> void:
	# Stretches a "bounce" scene between from_world and the target's current
	# position — same stretching idea as _spawn_dash_trail, but plays an
	# actual scene with its own animation rather than a static faded sprite.
	var spawn_root = _get_spawn_root()
	if spawn_root == null or not is_instance_valid(target):
		return

	var to_world: Vector2 = target.position
	var node: Node2D
	if scene != null:
		node = scene.instantiate()
	else:
		var sprite := Sprite2D.new()
		var img := Image.create(24, 24, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.6, 0.8, 1.0))
		sprite.texture = ImageTexture.create_from_image(img)
		node = sprite

	spawn_root.add_child(node)
	_stretch_effect_between(node, from_world, to_world)

	# THE FIX: this got dropped when _stretch_effect_between was added —
	# the node was being positioned/scaled correctly but never actually
	# told to PLAY, and never awaited/cleaned up, which is why bounce
	# scenes appeared to do nothing at all.
	if node is AnimatedSprite2D:
		node.play("default")
		await node.animation_finished
	elif node.has_node("AnimatedSprite2D"):
		var s = node.get_node("AnimatedSprite2D") as AnimatedSprite2D
		s.play("default")
		await s.animation_finished
	else:
		await get_tree().create_timer(0.35).timeout

	if is_instance_valid(node):
		node.queue_free()


func _stretch_effect_between(node: Node2D, from_world: Vector2, to_world: Vector2) -> void:
	# Positions, rotates, and SCALES 'node' so it visually spans exactly from
	# from_world to to_world, regardless of how far apart they are or how the
	# node's own art was originally sized. This replaces the old fixed
	# "divide by 96" guess, which only happened to look right at exactly one
	# specific distance.
	#
	# TWO WAYS a scene can be stretched, tried in this order:
	#
	# 1. CUSTOM: if the instantiated scene defines its own
	#    stretch_between(from_global: Vector2, to_global: Vector2) method,
	#    we call that and do NOTHING else — full control for scenes that
	#    need custom logic (e.g. a segmented Line2D lightning arc, or
	#    several independently-positioned child sprites). The scene is
	#    responsible for its own position/rotation/scale entirely in this case.
	#
	# 2. AUTOMATIC (default, no method needed): we measure the scene's own
	#    visual content once (see _measure_node_horizontal_extent below) to
	#    find out how wide it naturally is at scale (1,1), then rotate it to
	#    point from -> to, position it at the midpoint, and set scale.x so
	#    that natural width now exactly equals the real distance. scale.y is
	#    left untouched, so the effect only stretches/condenses along its
	#    length, never gets thinner or fatter vertically.
	#
	# IMPORTANT for path (2): author bounce-effect scenes with their origin
	# at their own centre and their visual content spanning horizontally
	# along the local +x/-x axis — same convention _spawn_dash_trail already
	# assumes elsewhere in this file. If your scene is anchored differently
	# (e.g. origin at the START of the effect rather than the middle),
	# implement stretch_between() on it instead and this function will use
	# that automatically.
	if node.has_method("stretch_between"):
		node.stretch_between(from_world, to_world)
		return

	var distance: float = from_world.distance_to(to_world)
	var natural_width: float = _measure_node_horizontal_extent(node)
	if natural_width <= 0.0:
		natural_width = 96.0   # Same fallback tile-size assumption used elsewhere in this file.

	node.position = (from_world + to_world) / 2.0
	node.rotation = from_world.angle_to_point(to_world)
	node.scale.x  = distance / natural_width


func _measure_node_horizontal_extent(node: Node) -> float:
	# Figures out how "wide" a node's own visual content naturally is (at its
	# CURRENT scale, before we touch it), by checking the most common node
	# types used for VFX and recursing into children. Returns the widest
	# single element found — a bounce scene is usually one dominant sprite,
	# animation, or line, so the widest part is the right thing to treat as
	# "this scene's natural travel length."
	var best: float = 0.0

	if node is Sprite2D and node.texture != null:
		best = max(best, node.texture.get_size().x * node.scale.x)

	elif node is AnimatedSprite2D and node.sprite_frames != null:
		var anim_names: PackedStringArray = node.sprite_frames.get_animation_names()
		if anim_names.size() > 0:
			var anim_name: String = "default" if node.sprite_frames.has_animation("default") else anim_names[0]
			if node.sprite_frames.get_frame_count(anim_name) > 0:
				var tex: Texture2D = node.sprite_frames.get_frame_texture(anim_name, 0)
				if tex != null:
					best = max(best, tex.get_size().x * node.scale.x)

	elif node is Line2D:
		var min_x: float = INF
		var max_x: float = -INF
		for point in node.points:
			min_x = min(min_x, point.x)
			max_x = max(max_x, point.x)
		if max_x > min_x:
			best = max(best, (max_x - min_x) * node.scale.x)

	for child in node.get_children():
		best = max(best, _measure_node_horizontal_extent(child))

	return best

# ── SHARED: TRAVEL + IMPACT ANIMATION HELPERS (Zephyr Strike, Leap) ───────────

func _travel_caster_to(caster, ability: AbilityData, dest_cell: Vector2i) -> void:
	# Slides the caster to dest_cell, playing travel_animation_name (falling
	# back to "walk") for the duration. Same snap_to-then-restore-then-tween
	# pattern _execute_dash uses, so grid registration updates immediately
	# but the visual still slides smoothly.
	if not is_instance_valid(caster):
		return
	var start_world: Vector2 = caster.position
	var end_world: Vector2 = grid_ref.grid_to_world(dest_cell)

	caster.snap_to(dest_cell)
	caster.position = start_world

	var travel_anim: String = ability.travel_animation_name if ability.travel_animation_name != "" else "walk"
	caster.play_animation(travel_anim)

	var distance: float = start_world.distance_to(end_world)
	var speed: float = ability.dash_speed if ability.dash_speed > 0 else 800.0
	var duration: float = distance / speed

	var tween = get_tree().create_tween()
	tween.tween_property(caster, "position", end_world, duration)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	await tween.finished


func _play_caster_animation_and_wait(caster, anim_name: String, fallback_seconds: float = 0.35) -> void:
	# Plays a named animation on the caster and waits for it to ACTUALLY
	# finish (rather than guessing a fixed delay) — this is what makes
	# damage land "when the animation ends" for Zephyr Strike/Leap impacts.
	if not is_instance_valid(caster) or anim_name == "":
		await get_tree().create_timer(fallback_seconds).timeout
		return
	caster.play_named_animation(anim_name)
	if caster.has_node("AnimatedSprite2D"):
		var sprite = caster.get_node("AnimatedSprite2D") as AnimatedSprite2D
		if sprite.sprite_frames != null and sprite.sprite_frames.has_animation(anim_name):
			await sprite.animation_finished
			return
	await get_tree().create_timer(fallback_seconds).timeout


func _find_adjacent_empty_cell(target_cell: Vector2i, prefer_near: Vector2i) -> Vector2i:
	# The empty, passable, orthogonally-adjacent (no diagonals) tile next to
	# target_cell closest to prefer_near — or (-1,-1) if none are free.
	var candidates: Array = [
		target_cell + Vector2i(0, -1), target_cell + Vector2i(0, 1),
		target_cell + Vector2i(-1, 0), target_cell + Vector2i(1, 0),
	]
	var best: Vector2i = Vector2i(-1, -1)
	var best_dist: int = 999999
	for c in candidates:
		if not grid_ref.is_valid_cell(c):
			continue
		if not grid_ref.is_terrain_walkable(c):
			continue
		if grid_ref.unit_positions.has(c):
			continue
		var dist: int = abs(c.x - prefer_near.x) + abs(c.y - prefer_near.y)
		if dist < best_dist:
			best_dist = dist
			best = c
	return best
	
	
func _find_opposite_adjacent_cell(target_cell: Vector2i, from_cell: Vector2i) -> Vector2i:
	# The orthogonally-adjacent tile on the FAR side of target_cell from
	# from_cell — straight through and out the other side. Used when the
	# same target is selected twice in a row in sequential multi-target
	# mode (see _multi_target_sequential above), so the caster visibly
	# passes THROUGH the target instead of recomputing the exact tile it's
	# already standing on.
	var direction: Vector2i = target_cell - from_cell
	var snapped: Vector2i
	if abs(direction.x) >= abs(direction.y):
		snapped = Vector2i(sign(direction.x) if direction.x != 0 else 1, 0)
	else:
		snapped = Vector2i(0, sign(direction.y) if direction.y != 0 else 1)

	var opposite: Vector2i = target_cell + snapped
	if grid_ref.is_valid_cell(opposite) and grid_ref.is_terrain_walkable(opposite) \
			and not grid_ref.unit_positions.has(opposite):
		return opposite
	return Vector2i(-1, -1)

# ── ZEPHYR STRIKE (multi_target) ───────────────────────────────────────────────

func _execute_multi_target_strike(caster, ability: AbilityData, target_cells: Array) -> void:
	var targets: Array = []
	for cell in target_cells:
		var t = grid_ref.get_unit_at(cell)
		# NOTE: duplicates are intentionally kept now — selecting the same
		# target more than once is allowed (see _multi_target_sequential's
		# pass-through handling below), so this no longer dedupes.
		if t != null and is_instance_valid(t):
			targets.append(t)
	if targets.is_empty():
		return

	var origin_cell: Vector2i = caster.grid_position
	var origin_world: Vector2 = caster.position

	if ability.multi_target_simultaneous:
		await _multi_target_simultaneous(caster, ability, targets, origin_cell, origin_world)
	else:
		await _multi_target_sequential(caster, ability, targets, origin_cell, origin_world)


func _multi_target_sequential(caster, ability: AbilityData, targets: Array,
							   origin_cell: Vector2i, origin_world: Vector2) -> void:
	var current_cell: Vector2i = origin_cell
	var previous_target = null

	for target in targets:
		if not is_instance_valid(target):
			continue

		var dest: Vector2i
		if target == previous_target:
			# THE FIX: the same target selected twice in a row used to
			# compute the exact same adjacent tile the caster was already
			# standing on (via _find_adjacent_empty_cell, "closest empty
			# tile to current_cell" — which IS current_cell when they just
			# arrived there), so nothing visibly happened on the repeat hit.
			# Instead, aim for the tile on the FAR side of the target — the
			# caster visibly travels THROUGH them to the other side, then
			# hits, then continues from there.
			dest = _find_opposite_adjacent_cell(target.grid_position, current_cell)
			if dest == Vector2i(-1, -1):
				# No room on the far side — fall back to the normal nearest
				# empty tile rather than skipping the hit entirely.
				dest = _find_adjacent_empty_cell(target.grid_position, current_cell)
		else:
			dest = _find_adjacent_empty_cell(target.grid_position, current_cell)

		if dest == Vector2i(-1, -1):
			continue   # No room to reach this one — skip, keep going to the rest.

		await _travel_caster_to(caster, ability, dest)
		if not is_instance_valid(caster) or not is_instance_valid(target):
			continue

		caster.look_at_target(target.grid_position)
		await _play_caster_animation_and_wait(caster, ability.impact_animation_name, 0.35)

		if is_instance_valid(target):
			var dmg = calculate_damage(caster, target, ability)
			_apply_damage_with_effects(caster, target, ability, dmg)

		current_cell    = dest
		previous_target = target

	if is_instance_valid(caster):
		await _travel_caster_to(caster, ability, origin_cell)
		if is_instance_valid(caster):
			caster.play_animation("idle")


func _multi_target_simultaneous(caster, ability: AbilityData, targets: Array,
								  origin_cell: Vector2i, origin_world: Vector2) -> void:
	if not is_instance_valid(caster):
		return

	if caster.has_node("AnimatedSprite2D"):
		caster.get_node("AnimatedSprite2D").visible = false

	var pending: int = 0
	for target in targets:
		if not is_instance_valid(target):
			continue
		var dest: Vector2i = _find_adjacent_empty_cell(target.grid_position, origin_cell)
		if dest == Vector2i(-1, -1):
			continue
		_duplicate_strike(caster, ability, target, dest)
		pending += 1

	# Rough wait for every duplicate to finish — each one manages its own
	# damage timing internally regardless.
	if pending > 0:
		await get_tree().create_timer(1.2).timeout

	if is_instance_valid(caster):
		caster.position = origin_world
		if caster.has_node("AnimatedSprite2D"):
			caster.get_node("AnimatedSprite2D").visible = true
		caster.play_animation("idle")


func _duplicate_strike(caster, ability: AbilityData, target, dest_cell: Vector2i) -> void:
	# Spawns a temporary visual clone of the caster that flies out to
	# dest_cell, plays the impact animation, deals damage at the end of it,
	# then disappears. The REAL caster never moves during this — it's
	# hidden by _multi_target_simultaneous for the duration.
	var spawn_root = _get_spawn_root()
	if spawn_root == null or not is_instance_valid(caster):
		return

	var clone := AnimatedSprite2D.new()
	if caster.has_node("AnimatedSprite2D"):
		clone.sprite_frames = caster.get_node("AnimatedSprite2D").sprite_frames
	spawn_root.add_child(clone)
	clone.position = caster.position

	var travel_anim: String = ability.travel_animation_name if ability.travel_animation_name != "" else "walk"
	if clone.sprite_frames != null and clone.sprite_frames.has_animation(travel_anim):
		clone.play(travel_anim)

	var end_world: Vector2 = grid_ref.grid_to_world(dest_cell)
	var distance: float = clone.position.distance_to(end_world)
	var speed: float = ability.dash_speed if ability.dash_speed > 0 else 800.0
	var duration: float = distance / speed

	var tween = get_tree().create_tween()
	tween.tween_property(clone, "position", end_world, duration)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	await tween.finished

	if not is_instance_valid(clone):
		return

	var impact_anim: String = ability.impact_animation_name
	if impact_anim != "" and clone.sprite_frames != null and clone.sprite_frames.has_animation(impact_anim):
		clone.play(impact_anim)
		await clone.animation_finished
	else:
		await get_tree().create_timer(0.3).timeout

	if is_instance_valid(target):
		var dmg = calculate_damage(caster, target, ability)
		_apply_damage_with_effects(caster, target, ability, dmg)

	if is_instance_valid(clone):
		clone.queue_free()

# ── LEAP ────────────────────────────────────────────────────────────────────────

func _execute_leap(caster, ability: AbilityData, target_cells: Array, destination_cell: Vector2i) -> void:
	if target_cells.is_empty():
		return
	var target = grid_ref.get_unit_at(target_cells[0])
	if target == null or not is_instance_valid(target):
		return

	caster.look_at_target(target.grid_position)
	await _travel_caster_to(caster, ability, destination_cell)

	if not is_instance_valid(caster) or not is_instance_valid(target):
		return

	caster.look_at_target(target.grid_position)
	await _play_caster_animation_and_wait(caster, ability.impact_animation_name, 0.3)

	if is_instance_valid(target):
		var dmg = calculate_damage(caster, target, ability)
		_apply_damage_with_effects(caster, target, ability, dmg)


# ── DISPLACEMENT HELPERS ──────────────────────────────────────────────────────

func _to_grid_direction(raw: Vector2i) -> Vector2i:
	# Converts an arbitrary offset into one of the 8 grid directions (each
	# component snapped to -1, 0, or +1) — i.e. "which way is this roughly
	# pointing, snapped to the grid". Shared by all three displacement types
	# (auto/scatter/manual) so they all snap directions identically, and also
	# used by _resolve_pending_displacements() below to figure out who's at
	# the "front of the line" for a manual-direction push.
	if raw == Vector2i.ZERO:
		return Vector2i.ZERO

	var dir_f: Vector2 = Vector2(raw.x, raw.y).normalized()
	var snapped: Vector2i = Vector2i(int(round(dir_f.x)), int(round(dir_f.y)))

	if snapped == Vector2i.ZERO:
		# A near-diagonal offset that rounded to zero on both axes — fall
		# back to whichever axis has the larger magnitude.
		if abs(raw.x) > abs(raw.y):
			snapped = Vector2i(sign(raw.x), 0)
		else:
			snapped = Vector2i(0, sign(raw.y))

	return snapped


func _try_step_with_wall_drag(target, current: Vector2i, move_dir: Vector2i) -> Vector2i:
	# THE WALL-DRAG FIX.
	#
	# THE OLD BEHAVIOUR: a diagonal push (e.g. move_dir = (1,-1), meaning
	# "right and up") tried the single diagonal tile each step. The moment
	# THAT exact tile was blocked — even if only ONE of the two axes was
	# actually the problem — the whole displacement stopped dead right there,
	# even though the unit could clearly still slide further along the axis
	# that wasn't blocked.
	#
	# THE FIX: if the diagonal tile is blocked, check whether moving along
	# JUST the x-axis, or JUST the y-axis, is still open, and take whichever
	# one works. This makes a diagonal push "drag" along a wall instead of
	# stopping the instant it grazes one — e.g. pushing 2 tiles (right, up)
	# into a wall on the right: step 1 goes through diagonally as normal;
	# step 2's diagonal is blocked, but "up alone" is still clear, so the unit
	# slides up that last tile instead of just stopping after step 1.
	#
	# For a purely cardinal push (move_dir has only one nonzero axis to begin
	# with), this behaves EXACTLY like the old simple check — there's no
	# second axis to fall back on, so it's a no-op for non-diagonal pushes.
	#
	# Returns the new position, or 'current' unchanged if every option here —
	# diagonal AND both single axes — is blocked (truly stuck, e.g. a corner).
	var diag_next: Vector2i = current + move_dir
	if grid_ref.is_passable_for(target, diag_next):
		return diag_next

	if move_dir.x != 0:
		var x_next: Vector2i = current + Vector2i(move_dir.x, 0)
		if grid_ref.is_passable_for(target, x_next):
			return x_next

	if move_dir.y != 0:
		var y_next: Vector2i = current + Vector2i(0, move_dir.y)
		if grid_ref.is_passable_for(target, y_next):
			return y_next

	return current   # Every option blocked — nowhere left to drag to.


func _displace_unit_auto(caster, target, squares: int) -> bool:
	# Pushes (positive) or pulls (negative) the target relative to the caster.
	# Returns true if the target actually moved (i.e. move_to() was called and
	# will eventually emit movement_finished) — _resolve_pending_displacements
	# uses this to know exactly which targets it needs to wait on afterward.
	var direction: Vector2i = target.grid_position - caster.grid_position
	if direction == Vector2i(0, 0):
		return false

	if squares < 0:
		# PULL: always lands on whichever tile next to the caster is
		# genuinely closest to the target — see _pull_unit_toward_caster for
		# why this needs its own dedicated logic instead of the simple
		# walk below (that walk is what caused diagonal pulls to land on the
		# wrong tile).
		return _pull_unit_toward_caster(caster, target, abs(squares))

	# PUSH: walks straight away from the caster, dragging along any wall it
	# grazes (see _try_step_with_wall_drag). Pushing doesn't need a "snap to
	# the best tile" step the way pulling does — there's no single specific
	# destination tile it's aiming for, just "as far as it can get."
	var move_dir: Vector2i = _to_grid_direction(direction)
	move_dir *= sign(squares)

	var steps: int = abs(squares)
	var current: Vector2i = target.grid_position

	for _i in range(steps):
		var next: Vector2i = _try_step_with_wall_drag(target, current, move_dir)
		if next == current:
			break   # Truly stuck — diagonal AND both single axes all blocked.
		current = next

	if current != target.grid_position:
		target.move_to(current)
		return true
	return false


func _pull_unit_toward_caster(caster, target, max_steps: int) -> bool:
	# THE DIAGONAL PULL FIX.
	#
	# Figures out which of the 8 tiles immediately surrounding the caster is
	# genuinely CLOSEST to the target's current position, then walks the
	# target toward that one specific tile — recalculating direction fresh
	# at every step, rather than committing to a single rounded direction up
	# front and blindly repeating it (which is what used to make diagonal
	# pulls overshoot onto the wrong, cardinal tile — see the explanation
	# above _displace_unit_auto for the full story with a worked example).
	#
	# 'max_steps' is the ability's pull strength (abs(displacement_squares)).
	# If the target starts further away than that, they get pulled max_steps
	# closer toward the best tile without necessarily reaching it yet — same
	# idea as before, just aimed correctly now.
	var caster_cell: Vector2i = caster.grid_position
	var start_cell: Vector2i = target.grid_position

	# All 8 tiles around the caster, ranked by REAL distance (squared
	# Euclidean — avoids a sqrt, and ordering is identical either way) to
	# the target's starting position, closest first. This ranking is what
	# "the closest adjacent square" actually means.
	var candidates: Array = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			candidates.append(caster_cell + Vector2i(dx, dy))

	candidates.sort_custom(func(a, b):
		var da: Vector2i = a - start_cell
		var db: Vector2i = b - start_cell
		return (da.x * da.x + da.y * da.y) < (db.x * db.x + db.y * db.y)
	)

	# Try each candidate tile, closest first. For each one, walk toward IT
	# specifically (not a generic direction) for up to max_steps tiles.
	for destination in candidates:
		if destination == start_cell:
			return false   # Already standing on the best tile — nothing to do.

		var current: Vector2i = start_cell
		for _i in range(max_steps):
			if current == destination:
				break
			# Recalculated every step, aimed at THIS destination specifically
			# — this is what correctly traces the line instead of a single
			# direction computed once at the start.
			var step_dir: Vector2i = _to_grid_direction(destination - current)
			var next: Vector2i = _try_step_with_wall_drag(target, current, step_dir)
			if next == current:
				break   # Stuck on the way to this candidate.
			current = next

		if current != start_cell:
			# Made progress toward this candidate — whether or not it fully
			# reached it. We commit to that rather than abandoning it for a
			# totally different side of the caster just because that other
			# side happened to have a clearer path; getting pulled PARTWAY
			# toward the genuinely closest tile reads better than getting
			# yanked around to somewhere unrelated.
			target.move_to(current)
			return true
		# Zero progress at all toward this candidate (blocked on the very
		# first step) — fall through and try the next-closest one instead.

	return false   # No reachable, passable tile next to the caster at all.

func _displace_unit_scatter(ability: AbilityData, target, squares: int,
							target_cells: Array) -> bool:
	# Scatters the target outward from the centre of the AOE.
	# Returns true if the target actually moved (see _displace_unit_auto's
	# doc comment above for why this matters).
	var sum_x: int = 0
	var sum_y: int = 0
	var count: int = target_cells.size()

	for cell in target_cells:
		sum_x += cell.x
		sum_y += cell.y

	var center: Vector2i = Vector2i(sum_x / count, sum_y / count)
	var direction: Vector2i = target.grid_position - center
	if direction == Vector2i(0, 0):
		return false

	var move_dir: Vector2i = _to_grid_direction(direction)

	var steps: int = squares
	var current: Vector2i = target.grid_position

	for _i in range(steps):
		var next: Vector2i = _try_step_with_wall_drag(target, current, move_dir)
		if next == current:
			break   # Truly stuck — diagonal AND both single axes all blocked.
		current = next

	if current != target.grid_position:
		target.move_to(current)
		return true
	return false


func _displace_unit_manual(target, squares: int, fixed_dir: Vector2i) -> bool:
	# Displaces the target in a fixed designer-chosen direction.
	# Returns true if the target actually moved (see _displace_unit_auto's
	# doc comment above for why this matters).
	if fixed_dir == Vector2i(0, 0):
		return false

	var move_dir: Vector2i = _to_grid_direction(fixed_dir)
	move_dir *= sign(squares)

	var steps: int = abs(squares)
	var current: Vector2i = target.grid_position

	for _i in range(steps):
		var next: Vector2i = _try_step_with_wall_drag(target, current, move_dir)
		if next == current:
			break   # Truly stuck — diagonal AND both single axes all blocked.
		current = next

	if current != target.grid_position:
		target.move_to(current)
		return true
	return false


func _resolve_pending_displacements(caster, ability: AbilityData, pending: Array,
									  target_cells: Array) -> void:
	# THE CLUSTER-PUSH FIX.
	#
	# THE BUG: displacement used to happen immediately while looping over
	# target_cells, one target at a time, in whatever order target_cells
	# happened to list them — NOT necessarily front-to-back along the push
	# direction. If a push lines up several enemies in a row, whichever one
	# happened to be checked first tried to step onto the tile the unit "in
	# front" of it was still standing on. That occupied tile reads exactly
	# like a wall to is_passable_for(), so the push got blocked and that unit
	# never moved at all — even though the unit blocking it was ALSO about to
	# move out of the way moments later in the very same cast.
	#
	# THE FIX: don't displace anyone the instant they're found. Instead,
	# collect every target hit by this cast first (done by the caller, in the
	# main target_cells loop), and only once they're ALL known, sort them so
	# whoever is at the very FRONT of their push line — i.e. has open space
	# ahead and nothing of ours still in the way — gets displaced FIRST. That
	# opens up the tile behind them before we ever try to move the unit that
	# was "stuck" behind them. Each individual displacement call still does
	# its own live grid_ref.is_passable_for() check, completely unchanged —
	# this fix doesn't relax any collision rule, it just makes sure we check
	# those tiles in an order where "the way is clear" actually gets a real
	# chance to be true.
	#
	# NOTE: this resolves the common case — multiple targets pushed along the
	# same or similar lines (the cluster scenario described). It does NOT run
	# a full physics simulation of units crossing paths in unrelated
	# directions; two targets converging on the same tile from very different
	# angles could still rarely contest one tile, same as before.
	if pending.is_empty():
		return

	# "auto" needs a living caster to compute push/pull direction from.
	# "manual" and "scatter" don't depend on the caster at all, so they can
	# still resolve normally even if the caster died mid-cast (e.g. killed by
	# a Thorns reflect off one of the targets earlier in this same loop).
	if ability.displacement_type == "auto" and not is_instance_valid(caster):
		return

	# Large units can occupy multiple target_cells — only displace each
	# unique unit once per cast, exactly like the damage loop's dedup.
	var unique_targets: Array = []
	for entry in pending:
		if not entry["target"] in unique_targets:
			unique_targets.append(entry["target"])

	# Tracks which targets ACTUALLY moved (move_to() was called on them), so
	# we know exactly who to wait on below — see the big comment above
	# _displace_unit_auto for why we can't just await everyone unconditionally.
	var moved_targets: Array = []

	match ability.displacement_type:
		"manual":
			# Push direction is the SAME for every target, so "front of the
			# line" just means "furthest along that direction already" —
			# they go first so the ones behind have somewhere to slide into.
			var move_dir: Vector2i = _to_grid_direction(ability.displacement_manual_dir)
			unique_targets.sort_custom(func(a, b):
				var proj_a = a.grid_position.x * move_dir.x + a.grid_position.y * move_dir.y
				var proj_b = b.grid_position.x * move_dir.x + b.grid_position.y * move_dir.y
				return proj_a > proj_b   # Furthest along move_dir goes first.
			)
			for target in unique_targets:
				var did_move: bool = _displace_unit_manual(target, ability.displacement_squares,
										   ability.displacement_manual_dir)
				if did_move:
					moved_targets.append(target)

		"auto":
			# Direction is computed per-target, radially away from (or toward,
			# for a pull) the caster. Along any shared line, whoever is
			# FARTHEST from the caster is at the front and goes first.
			unique_targets.sort_custom(func(a, b):
				var diff_a: Vector2i = a.grid_position - caster.grid_position
				var diff_b: Vector2i = b.grid_position - caster.grid_position
				var dist_a: int = diff_a.x * diff_a.x + diff_a.y * diff_a.y
				var dist_b: int = diff_b.x * diff_b.x + diff_b.y * diff_b.y
				return dist_a > dist_b   # Farthest from caster goes first.
			)
			for target in unique_targets:
				var did_move: bool = _displace_unit_auto(caster, target, ability.displacement_squares)
				if did_move:
					moved_targets.append(target)

		"scatter":
			# Direction is radially away from the AOE's centre. Whoever is
			# farthest from that centre is at the front of their own line.
			var sum_x: int = 0
			var sum_y: int = 0
			for cell in target_cells:
				sum_x += cell.x
				sum_y += cell.y
			var center_x: float = sum_x / float(target_cells.size())
			var center_y: float = sum_y / float(target_cells.size())
			unique_targets.sort_custom(func(a, b):
				var dx_a: float = a.grid_position.x - center_x
				var dy_a: float = a.grid_position.y - center_y
				var dx_b: float = b.grid_position.x - center_x
				var dy_b: float = b.grid_position.y - center_y
				var dist_a: float = dx_a * dx_a + dy_a * dy_a
				var dist_b: float = dx_b * dx_b + dy_b * dy_b
				return dist_a > dist_b   # Farthest from centre goes first.
			)
			for target in unique_targets:
				var did_move: bool = _displace_unit_scatter(ability, target, ability.displacement_squares,
										target_cells)
				if did_move:
					moved_targets.append(target)

	# ── WAIT FOR EVERY DISPLACEMENT TO VISUALLY FINISH ────────────────────────
	# THE WINDMAGE FIX (PART 2): every _displace_unit_* call above kicks off a
	# move_to() tween but doesn't wait for it — they're all started back to
	# back here, in the same frame, so multiple pushed units visually slide
	# at once instead of one at a time.
	#
	# THE BUG: the original fix awaited "target.movement_finished" for every
	# moved target in a plain sequential loop. Since every move_to() tween
	# uses the SAME fixed move_speed duration and they were all started in
	# the same frame, they also all FINISH at essentially the same real time.
	# That means by the time this loop got around to awaiting the SECOND (or
	# third, etc.) target's movement_finished, that target's tween had often
	# already completed and already emitted the signal — and in GDScript,
	# `await some_signal` only ever catches a FUTURE emission. Awaiting a
	# signal that already fired hangs forever, waiting for an emission that
	# is never coming again. That hang is exactly what showed up as Windmage
	# abilities taking a "really long delay" (or never resolving at all) any
	# time a push/pull/scatter moved more than one unit.
	#
	# THE FIX: check unit_node's _is_moving flag (set true the instant
	# move_to()/move_along_path() starts, false right before movement_finished
	# fires) immediately before deciding to await. If the tween already
	# finished by the time we get here, _is_moving is already false and we
	# skip the await entirely instead of blocking on a signal that's never
	# coming. If it's still mid-tween, we await it normally. Checking the
	# flag right at the top of each loop iteration is safe even though a
	# previous await let frames pass — nothing else runs between the check
	# and the await in the same iteration, so there's no new race introduced.
	for target in moved_targets:
		if is_instance_valid(target) and target._is_moving:
			await _await_movement_finished_safe(target)


func _await_movement_finished_safe(target, timeout_sec: float = 1.5) -> void:
	# Normally resolves within a frame or two of movement_finished firing.
	# Safety net: if the target is freed mid-tween (its death sequence's
	# queue_free() racing this same displacement — e.g. a push that lands a
	# unit on a hazard that kills them), the engine silently invalidates the
	# tween and movement_finished never fires. Without a timeout that hangs
	# this whole coroutine, and with it the player's entire turn, forever.
	# Polling _is_moving with a timeout instead of awaiting the signal
	# directly guarantees this always resolves one way or the other.
	var elapsed := 0.0
	while is_instance_valid(target) and target._is_moving and elapsed < timeout_sec:
		await get_tree().process_frame
		elapsed += get_process_delta_time()

	if is_instance_valid(target) and target._is_moving:
		printerr("Timed out waiting on a displaced unit's movement_finished — continuing the turn instead of hanging forever.")

func _launch_projectile(caster, ability: AbilityData, target_cell: Vector2i) -> void:
	# Spawns a projectile that travels from the caster to the target cell.
	var spawn_root = _get_spawn_root()
	if spawn_root == null:
		return

	var start_pos: Vector2 = caster.position
	var end_pos:   Vector2 = grid_ref.grid_to_world(target_cell)

	var proj_node: Node2D
	if ability.effect_scene != null:
		proj_node = ability.effect_scene.instantiate()
	else:
		var sprite := Sprite2D.new()
		if ability.icon != null:
			sprite.texture = ability.icon
		else:
			var img := Image.create(24, 24, false, Image.FORMAT_RGBA8)
			img.fill(Color.WHITE)
			sprite.texture = ImageTexture.create_from_image(img)
		proj_node = sprite

	proj_node.position = start_pos
	proj_node.rotation = start_pos.angle_to_point(end_pos)
	spawn_root.add_child(proj_node)

	var TRAVEL_SPEED := 600.0
	var distance     := start_pos.distance_to(end_pos)
	var duration     := distance / TRAVEL_SPEED

	var tween = get_tree().create_tween()
	tween.tween_property(proj_node, "position", end_pos, duration)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	proj_node.queue_free()

# ── AOE VFX ───────────────────────────────────────────────────────────────────

func _play_aoe_vfx(caster, ability: AbilityData, target_cells: Array,
				   origin_cell: Vector2i) -> void:
	# Spawns a visual overlay covering all affected cells.
	var spawn_root = _get_spawn_root()
	if spawn_root == null or target_cells.is_empty():
		return

	var TILE_SIZE: float = 96.0
	var min_x = target_cells[0].x;  var max_x = target_cells[0].x
	var min_y = target_cells[0].y;  var max_y = target_cells[0].y
	for cell in target_cells:
		min_x = min(min_x, cell.x);  max_x = max(max_x, cell.x)
		min_y = min(min_y, cell.y);  max_y = max(max_y, cell.y)

	var cell_width  = (max_x - min_x + 1) * TILE_SIZE
	var cell_height = (max_y - min_y + 1) * TILE_SIZE
	var target_size := Vector2(cell_width, cell_height)
	var center_cell := Vector2i(int((min_x + max_x) / 2.0), int((min_y + max_y) / 2.0))
	var center_world: Vector2 = grid_ref.grid_to_world(center_cell)

	var vfx_node: Node2D
	if ability.effect_scene != null:
		vfx_node = ability.effect_scene.instantiate()
		_apply_vfx_scaling(vfx_node, target_size, TILE_SIZE, ability.scale_vfx_to_fit_aoe)
	else:
		var sprite := Sprite2D.new()
		if ability.icon != null:
			sprite.texture = ability.icon
			sprite.region_enabled = true
			sprite.region_rect = Rect2(0, 0, cell_width, cell_height)
			sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		else:
			var img := Image.create(int(cell_width), int(cell_height), false, Image.FORMAT_RGBA8)
			img.fill(Color.WHITE)
			sprite.texture = ImageTexture.create_from_image(img)
		sprite.modulate = Color(1, 1, 1, 0.6)
		vfx_node = sprite

	if ability.aoe_shape in ["line", "cone"] and origin_cell != Vector2i(-1, -1) and caster != null:
		var caster_world: Vector2 = grid_ref.grid_to_world(caster.grid_position)
		var target_world: Vector2 = grid_ref.grid_to_world(origin_cell)
		vfx_node.rotation = caster_world.angle_to_point(target_world)

	vfx_node.position = center_world
	spawn_root.add_child(vfx_node)

	if vfx_node is AnimatedSprite2D:
		vfx_node.play("default")
		await vfx_node.animation_finished
	elif vfx_node.has_node("AnimatedSprite2D"):
		var s = vfx_node.get_node("AnimatedSprite2D") as AnimatedSprite2D
		s.play("default")
		await s.animation_finished
	else:
		await get_tree().create_timer(0.6).timeout

	if is_instance_valid(vfx_node):
		vfx_node.queue_free()

# ── SHARED HELPERS ────────────────────────────────────────────────────────────

func _apply_vfx_scaling(node: Node2D, target_size: Vector2, tile_size: float,
						 stretch_to_fit: bool = true) -> void:
	# Scales a VFX node to fit the target area.
	#
	# stretch_to_fit = true  (old/default behaviour): non-uniform scale —
	#   target_size / original_size on EACH axis independently. This exactly
	#   fills the AOE's bounding box but warps the art's aspect ratio
	#   whenever the AOE isn't square (e.g. a 1x3 line) or the original
	#   texture isn't square to begin with.
	#
	# stretch_to_fit = false: uniform scale — the SAME factor on both axes,
	#   chosen so the art fits entirely within the bounding box (the smaller
	#   of the two axis ratios, like CSS "contain"). The visual stays
	#   proportionally correct and is centred on the AOE; it may not
	#   perfectly fill a very non-square area, but it never looks squashed
	#   or stretched.
	if node is AnimatedSprite2D:
		var sf = node.sprite_frames
		if sf and sf.has_animation("default"):
			var ft = sf.get_frame_texture("default", 0)
			if ft:
				node.scale = _compute_vfx_scale(target_size, ft.get_size(), stretch_to_fit)
				return
	if node.has_node("AnimatedSprite2D"):
		var cs = node.get_node("AnimatedSprite2D") as AnimatedSprite2D
		var sf = cs.sprite_frames
		if sf and sf.has_animation("default"):
			var ft = sf.get_frame_texture("default", 0)
			if ft:
				cs.scale = _compute_vfx_scale(target_size, ft.get_size(), stretch_to_fit)
				return
	node.scale = _compute_vfx_scale(target_size, Vector2(tile_size, tile_size), stretch_to_fit)


func _compute_vfx_scale(target_size: Vector2, original_size: Vector2, stretch_to_fit: bool) -> Vector2:
	if original_size.x == 0 or original_size.y == 0:
		return Vector2.ONE
	var per_axis: Vector2 = target_size / original_size
	if stretch_to_fit:
		return per_axis
	var uniform: float = min(per_axis.x, per_axis.y)
	return Vector2(uniform, uniform)


func _get_spawn_root() -> Node:
	# Finds the best node to parent VFX to.
	# Prefers UnitLayer inside BattleGrid so VFX are in world space.
	var tree = get_tree()
	if tree == null:
		return null
	if grid_ref != null and grid_ref.has_node("UnitLayer"):
		return grid_ref.get_node("UnitLayer")
	if grid_ref != null:
		return grid_ref
	return tree.current_scene


func _spawn_damage_number(amount: int, pos: Vector2, color_override = null) -> void:
	# Floats an animated damage number above the target's head.
	# 'color_override', when given, always wins over the normal red/gold
	# damage colouring — used for things like the WHITE "blocked by shield"
	# number, which should read as clearly different from real HP damage
	# no matter how big the blocked amount is.
	var tree = get_tree()
	if tree == null:
		return
	var spawn_root = _get_spawn_root()
	if spawn_root == null:
		return

	var damage_label = Label.new()
	damage_label.text = str(amount)
	damage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	damage_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	damage_label.position = pos + Vector2(-50, -60)

	var settings = LabelSettings.new()
	settings.font       = SystemFont.new()
	settings.font_size  = 22
	settings.font_color = Color(1.0, 0.1, 0.1)
	settings.set("outline_width", 5)
	settings.outline_color = Color(0, 0, 0)

	# Larger gold text for high-damage hits.
	if amount > 15:
		settings.font_size  = 30
		settings.font_color = Color(1.0, 0.8, 0.0)

	if color_override != null:
		settings.font_color = color_override

	damage_label.label_settings = settings
	spawn_root.add_child(damage_label)


	var tween = tree.create_tween().set_parallel(true)
	tween.tween_property(damage_label, "position:y", damage_label.position.y - 40, 0.75)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(damage_label, "modulate:a", 0.0, 0.75)
	tween.chain().tween_callback(damage_label.queue_free)
