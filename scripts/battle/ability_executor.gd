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
					 origin_cell: Vector2i = Vector2i(-1, -1)) -> void:
	# Called by BattleManager (player) and AISystem (enemy).
	#
	# Parameters:
	#   caster       — The UnitNode using the ability.
	#   ability      — The AbilityData resource describing what it does.
	#   target_cells — The list of grid cells to affect (already filtered by team).
	#   origin_cell  — For line/cone shapes, the cell the player aimed at
	#                  (used to determine dash direction).

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
	if caster.has_arcana_charge:
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
	# A "dash" is a line AOE where the CASTER physically moves to the last valid
	# tile. We resolve the caster's movement BEFORE applying damage so the caster
	# lands in the correct position first.
	var dash_landing_cell: Vector2i = Vector2i(-1, -1)

	if ability.is_dash and ability.aoe_shape == "line":
		dash_landing_cell = await _execute_dash(caster, ability, target_cells)

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
		if ability.cooldown_rounds > 0:
			caster.ability_cooldowns[ability.id] = ability.cooldown_rounds
		return

	# ── STEP 3: COLLECT UNIQUE UNIT TARGETS AND APPLY EFFECTS ─────────────────
	# Large units occupy multiple cells. We track which UnitNode references we
	# have already hit so a 2×2 unit doesn't take damage 4 times from one AOE.
	var already_hit: Array = []   # Filled with UnitNode references.

	# If the caster was invisible, attacking reveals them.
	if caster.has_status("invisible"):
		caster.remove_status("invisible")
		caster.update_visuals()
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
		# Moves the target unit away from, toward, or away from the AOE centre.
		if ability.displacement_squares != 0 and target != null:
			match ability.displacement_type:
				"manual":
					_displace_unit_manual(
						target,
						ability.displacement_squares,
						ability.displacement_manual_dir
					)
				"auto":
					_displace_unit_auto(
						caster,
						target,
						ability.displacement_squares
					)
				"scatter":
					_displace_unit_scatter(
						ability,
						target,
						ability.displacement_squares,
						target_cells
					)

		# ── HEALING ───────────────────────────────────────────────────────────
		# Restores a percentage of the target's max HP (or the caster's if no target).
		if ability.heal_percent > 0.0:
			var heal_target = target if target != null else caster
			var max_hp      = heal_target.get_stats().hp
			heal_target.heal(int(max_hp * ability.heal_percent))

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
	elif not ability.is_dash and target_cells.size() > 0:
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
		_spawn_damage_number(guard_dmg, guardian.position)
		print("🛡️ Guardian intercepted ", guard_dmg, " damage for ", target.unit_data.display_name)

		damage = remaining_dmg
		if damage <= 0:
			_last_hit_was_crit = false   # Reset the flag even if we abort early.
			return   # Guardian absorbed everything.

	# -- 2. SHIELD CHECK ───────────────────────────────────────────────────────
	# The target's barrier absorbs incoming damage before it touches HP.
	if grid_ref.has_method("absorb_shield_damage"):
		damage = grid_ref.absorb_shield_damage(target, damage)
		if damage <= 0:
			print("🛡️ Shield absorbed all damage for ", target.unit_data.display_name)
			_last_hit_was_crit = false   # Reset the flag even if we abort early.
			return

	# -- 3. APPLY DAMAGE TO TARGET ─────────────────────────────────────────────
	var hp_before_damage: int = target.current_hp
	var actual_damage = target.take_damage(damage, ability.damage_type)
	CombatHooks.run_damage_applied_reactions(caster, target, actual_damage, _last_hit_was_crit)
	_spawn_damage_number(actual_damage, target.position)

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
		_spawn_damage_number(reflect_dmg, caster.position)
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
				_spawn_damage_number(ally_actual, ally.position)
				print("🔗 Tether propagated ", ally_actual, " to ", ally.unit_data.display_name)

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

	# -- 4. Critical hit check ────────────────────────────────────────────────
	var crit_chance: float = caster.get_effective_crit_chance()
	crit_chance += ability.bonus_crit_chance_per_caster_buff * float(caster_buff_count)
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

func _execute_dash(caster, ability: AbilityData, line_cells: Array) -> Vector2i:
	# Moves the caster along a line, stopping at the last walkable tile.
	# Returns the final landing cell.
	if line_cells.is_empty():
		return caster.grid_position

	var landing_cell: Vector2i = caster.grid_position

	for cell in line_cells:
		if grid_ref.is_terrain_walkable(cell):
			landing_cell = cell
		else:
			break   # Hit a wall or map edge; stop here.

	var end_world: Vector2 = grid_ref.grid_to_world(landing_cell)
	caster.snap_to(landing_cell)

	# Spawn an optional trail texture along the dash line.
	if ability.dash_trail_texture != null:
		_spawn_dash_trail(caster.position, grid_ref.grid_to_world(landing_cell),
						  ability.dash_trail_texture)

	# Animate the caster sprite racing to the destination.
	var start_world: Vector2 = caster.position
	var distance:    float   = start_world.distance_to(end_world)
	var duration:    float   = distance / ability.dash_speed

	caster.snap_to(landing_cell)   # Grid registry updated before the tween.

	var tween = get_tree().create_tween()
	tween.tween_property(caster, "position", end_world, duration)\
		.set_trans(Tween.TRANS_LINEAR)\
		.set_ease(Tween.EASE_IN_OUT)

	await tween.finished
	caster.play_animation("idle")
	return landing_cell


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

# ── DISPLACEMENT HELPERS ──────────────────────────────────────────────────────

func _displace_unit_auto(caster, target, squares: int) -> void:
	# Pushes (positive) or pulls (negative) the target relative to the caster.
	var direction: Vector2i = target.grid_position - caster.grid_position
	if direction == Vector2i(0, 0):
		return

	# Normalize the direction toward/away from the caster. This naturally
	# produces a diagonal move_dir (e.g. (1,1)) whenever the target isn't
	# perfectly aligned on a single axis with the caster — which is exactly
	# what we want for a "pull to nearest adjacent tile" ability.
	var dir_f: Vector2 = Vector2(direction.x, direction.y).normalized()
	var move_dir: Vector2i = Vector2i(int(round(dir_f.x)), int(round(dir_f.y)))

	if move_dir == Vector2i(0, 0):
		if abs(direction.x) > abs(direction.y):
			move_dir = Vector2i(sign(direction.x), 0)
		else:
			move_dir = Vector2i(0, sign(direction.y))

	move_dir *= sign(squares)

	var steps: int = abs(squares)
	var current: Vector2i = target.grid_position

	for _i in range(steps):
		var next: Vector2i = current + move_dir
		if next == caster.grid_position:
			break   # Never let the target land exactly on the caster's tile.

		# ── ADJACENCY CHECK (FIXED) ────────────────────────────────────────────
		# Stop once we're adjacent to the caster, INCLUDING diagonal adjacency.
		# The old check used Vector2i.distance_to(), which returns the EUCLIDEAN
		# distance (sqrt(2) ≈ 1.41 for a diagonal neighbour) — that never equals
		# exactly 1, so diagonal pulls always failed this check and either
		# overshot or broke out of the loop early. Chebyshev distance (the
		# largest of the x/y offsets) is the correct "grid adjacency" measure:
		# it's exactly 1 for ANY of the 8 surrounding tiles, including diagonals.
		var chebyshev_dist: int = max(abs(next.x - caster.grid_position.x),
									   abs(next.y - caster.grid_position.y))
		if chebyshev_dist <= 1:
			# 'next' is adjacent to the caster (cardinally or diagonally).
			# Only commit to it if it's actually free to stand on; otherwise
			# stay at 'current' (the last confirmed-valid tile) and stop here —
			# this is the "closest available" tile behaviour requested.
			if grid_ref.is_passable_for(target, next):
				current = next
			break

		if not grid_ref.is_passable_for(target, next):
			break
		current = next

	if current != target.grid_position:
		target.move_to(current)


func _displace_unit_scatter(ability: AbilityData, target, squares: int,
							target_cells: Array) -> void:
	# Scatters the target outward from the centre of the AOE.
	var sum_x: int = 0
	var sum_y: int = 0
	var count: int = target_cells.size()

	for cell in target_cells:
		sum_x += cell.x
		sum_y += cell.y

	var center: Vector2i = Vector2i(sum_x / count, sum_y / count)
	var direction: Vector2i = target.grid_position - center
	if direction == Vector2i(0, 0):
		return

	var dir_f: Vector2 = Vector2(direction.x, direction.y).normalized()
	var move_dir: Vector2i = Vector2i(int(round(dir_f.x)), int(round(dir_f.y)))

	if move_dir == Vector2i(0, 0):
		if abs(direction.x) > abs(direction.y):
			move_dir = Vector2i(sign(direction.x), 0)
		else:
			move_dir = Vector2i(0, sign(direction.y))

	var steps: int = squares
	var current: Vector2i = target.grid_position

	for _i in range(steps):
		var next: Vector2i = current + move_dir
		if not grid_ref.is_passable_for(target, next):
			break
		current = next

	if current != target.grid_position:
		target.move_to(current)


func _displace_unit_manual(target, squares: int, fixed_dir: Vector2i) -> void:
	# Displaces the target in a fixed designer-chosen direction.
	if fixed_dir == Vector2i(0, 0):
		return

	var dir_f: Vector2 = Vector2(fixed_dir.x, fixed_dir.y).normalized()
	var move_dir: Vector2i = Vector2i(int(round(dir_f.x)), int(round(dir_f.y)))

	if move_dir == Vector2i(0, 0):
		if abs(fixed_dir.x) >= abs(fixed_dir.y):
			move_dir = Vector2i(sign(fixed_dir.x), 0)
		else:
			move_dir = Vector2i(0, sign(fixed_dir.y))

	move_dir *= sign(squares)

	var steps: int = abs(squares)
	var current: Vector2i = target.grid_position

	for _i in range(steps):
		var next: Vector2i = current + move_dir
		if not grid_ref.is_passable_for(target, next):
			break
		current = next

	if current != target.grid_position:
		target.move_to(current)

# ── PROJECTILE VFX ────────────────────────────────────────────────────────────

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
		_apply_vfx_scaling(vfx_node, target_size, TILE_SIZE)
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

func _apply_vfx_scaling(node: Node2D, target_size: Vector2, tile_size: float) -> void:
	# Scales a VFX node to fit the target area.
	if node is AnimatedSprite2D:
		var sf = node.sprite_frames
		if sf and sf.has_animation("default"):
			var ft = sf.get_frame_texture("default", 0)
			if ft:
				node.scale = target_size / ft.get_size()
				return
	if node.has_node("AnimatedSprite2D"):
		var cs = node.get_node("AnimatedSprite2D") as AnimatedSprite2D
		var sf = cs.sprite_frames
		if sf and sf.has_animation("default"):
			var ft = sf.get_frame_texture("default", 0)
			if ft:
				cs.scale = target_size / ft.get_size()
				return
	node.scale = target_size / Vector2(tile_size, tile_size)


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


func _spawn_damage_number(amount: int, pos: Vector2) -> void:
	# Floats an animated damage number above the target's head.
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

	damage_label.label_settings = settings
	spawn_root.add_child(damage_label)

	var tween = tree.create_tween().set_parallel(true)
	tween.tween_property(damage_label, "position:y", damage_label.position.y - 40, 0.75)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(damage_label, "modulate:a", 0.0, 0.75)
	tween.chain().tween_callback(damage_label.queue_free)
