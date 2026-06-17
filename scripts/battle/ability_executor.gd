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

extends Node

# Set by BattleManager on startup.
var grid_ref: Node = null
# We use grid_ref to look up units at cells, check passability, and access
# the special-effect maps (shield_map, thorns_map, guardian_map, tether_map).

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

	# ── STEP 0: MANA GATE ─────────────────────────────────────────────────────
	# Check BEFORE doing anything else. If the unit can't afford this, 
	# and they don't have an Arcana Charge, abort.
	if not caster.has_arcana_charge and not caster.can_afford_ability(ability):
		print("⛔ ", caster.unit_data.display_name, " cannot afford '",
			  ability.display_name, "' (needs ", ability.mana_cost, " mana, has ",
			  caster.current_mana, ")")
		return
	
	print("🌵 execute_ability called: ", ability.display_name, 
	  " | target_cells: ", target_cells, 
	  " | caster: ", caster.unit_data.display_name)

	# ── STEP 1: APPLY COSTS ───────────────────────────────────────────────────
	# Deduct mana and HP cost immediately (before damage resolves).
	# If they have an Arcana Charge, consume it instead of mana.
	if caster.has_arcana_charge:
		caster.has_arcana_charge = false
		print("✨ Arcana Charge consumed by ", caster.unit_data.display_name)
		# Update animation/status effect here if needed
		caster.play_animation("idle") 
	else:
		caster.spend_mana(ability.mana_cost)

	if ability.hp_cost_percent > 0:
		var hp_cost = int(caster.get_stats().hp * ability.hp_cost_percent)
		caster.take_damage(hp_cost, "true")
		if not is_instance_valid(caster):
			return   # Caster killed themselves with HP cost — nothing more to do.
			
	# ── STEP 2: DASH ──────────────────────────────────────────────────────────
	# A "dash" is a line AOE where the CASTER physically moves to the last valid
	# tile. We resolve the caster's movement BEFORE applying damage so the caster
	# lands in the correct position first.
	var dash_landing_cell: Vector2i = Vector2i(-1, -1)

	if ability.is_dash and ability.aoe_shape == "line":
		dash_landing_cell = await _execute_dash(caster, ability, target_cells)

	# ── STEP 3: COLLECT UNIQUE UNIT TARGETS ───────────────────────────────────
	# Large units occupy multiple cells. We track which UnitNode references we
	# have already hit so a 2×2 unit doesn't take damage 4 times from one AOE.
	var already_hit: Array = []   # Filled with UnitNode references.

	for cell in target_cells:
		var target = grid_ref.get_unit_at(cell)
		print("🔍 cell: ", cell, " | target: ", target)
		if target == caster and ability.base_damage_multiplier > 0 and ability.affects_team == "enemies":
			continue
		
		

		# ── DAMAGE ────────────────────────────────────────────────────────────
		if ability.base_damage_multiplier > 0 and target != null:
			if not target in already_hit:
				already_hit.append(target)
				var damage = calculate_damage(caster, target, ability)
				_apply_damage_with_effects(caster, target, ability, damage)

		# ── STATUS EFFECTS ────────────────────────────────────────────────────
		if target != null:
			for status_data in ability.applies_statuses:
				target.apply_status(status_data)

		# ── TETHER APPLICATION ────────────────────────────────────────────────
		# If this ability applies a tether, register the hit unit in the tether group.
		if ability.applies_tether and target != null:
			if grid_ref.has_method("register_tether"):
				grid_ref.register_tether(target, ability.tether_id)
				if not ability.tether_id in target.tether_ids:
					target.tether_ids.append(ability.tether_id)

		# ── SHIELD APPLICATION ────────────────────────────────────────────────
		if ability.applies_shield and target != null:
			grid_ref.apply_shield(target, ability.shield_amount, ability.shield_duration_rounds)

		# ── THORNS APPLICATION ────────────────────────────────────────────────
		if ability.applies_thorns and target != null:
			grid_ref.apply_thorns(target, ability.thorns_reflect_percent,
								  ability.thorns_scaling_stat, ability.thorns_duration_rounds)


		# ── GUARDIAN APPLICATION ──────────────────────────────────────────────
		# "Guardian" makes the CASTER protect the TARGET. The caster intercepts
		# damage aimed at the target for the duration.
		if ability.applies_guardian and target != null:
			grid_ref.apply_guardian(target, caster,
									ability.guardian_redirect_percent,
									ability.guardian_uses_defense,
									ability.guardian_duration_rounds)

		# ── SPAWN HAZARD ──────────────────────────────────────────────────────
		if ability.spawns_hazard != null:
			grid_ref.add_hazard(cell, ability.spawns_hazard, caster)

		# ── DISPLACEMENT / KNOCKBACK ──────────────────────────────────────────
		# ── DISPLACEMENT / KNOCKBACK / SCATTER ────────────────────────────────
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
		if ability.heal_percent > 0.0:
			var heal_target = target if target != null else caster
			var max_hp      = heal_target.get_stats().hp
			heal_target.heal(int(max_hp * ability.heal_percent))

	# ── STEP 4: COOLDOWN ──────────────────────────────────────────────────────
	if ability.cooldown_rounds > 0:
		caster.ability_cooldowns[ability.id] = ability.cooldown_rounds

	# ── STEP 5: POST-ATTACK MOVEMENT ─────────────────────────────────────────
	# If the ability grants the caster extra movement squares after attacking,
	# set the flag on the unit so BattleManager can handle the input next.
	if ability.post_attack_move_squares > 0:
		caster.pending_post_attack_moves = ability.post_attack_move_squares
		# BattleManager watches for this flag and shows movement tiles again.

	# ── STEP 6: LAUNCH PROJECTILE / VFX ─────────────────────────────────────
	# (Visual only — game logic is already applied above.)
	if ability.is_dash and ability.dash_effect_scene != null:
		# The "projectile" for a dash is the caster themselves travelling the line.
		# We already moved the caster in _execute_dash, so we just play the VFX.
		pass   # Future: trigger a dash trail particle system here.
	elif not ability.is_dash and target_cells.size() > 0:
		if ability.aoe_shape == "single":
			await _launch_projectile(caster, ability, target_cells[0])
		else:
			await _play_aoe_vfx(caster, ability, target_cells, origin_cell)

# ── DAMAGE APPLICATION (with Shield / Thorns / Guardian / Tether) ────────────

func _apply_damage_with_effects(caster, target, ability: AbilityData, damage: int) -> void:
	# This is the full damage pipeline. Each step can absorb, redirect, or
	# reflect a portion of the damage before it touches the target's HP.

	# -- 1. GUARDIAN CHECK ─────────────────────────────────────────────────────
	# If a Guardian is protecting this unit, they intercept a portion of the hit.
	var guardian_entry = grid_ref.get_guardian_for(target)
	if not guardian_entry.is_empty() and is_instance_valid(guardian_entry["guardian"]):
		var guardian = guardian_entry["guardian"]
		var redirect_pct: float = guardian_entry["redirect_percent"]

		# Calculate how much damage the Guardian takes.
		# The "uses_defense" setting decides which stat to use when mitigating
		# the redirected hit against the Guardian.
		var redirected_dmg = int(damage * redirect_pct)
		var remaining_dmg  = damage - redirected_dmg

		# Apply the redirected hit to the Guardian using their chosen defense stat.
		var guard_dmg = redirected_dmg
		match guardian_entry["uses_defense"]:
			"caster_def":   guard_dmg = max(1, redirected_dmg - guardian.get_effective_def())
			"caster_mdef":  guard_dmg = max(1, redirected_dmg - guardian.get_effective_mdef())
			"target_def":   guard_dmg = max(1, redirected_dmg - target.get_effective_def())
			"target_mdef":  guard_dmg = max(1, redirected_dmg - target.get_effective_mdef())

		# Guardian takes the redirected portion (no further special effects —
		# the instructions say Guardian's own Thorns/Shield do NOT apply here).
		guardian.take_damage(guard_dmg, ability.damage_type)
		_spawn_damage_number(guard_dmg, guardian.position)
		print("🛡️ Guardian intercepted ", guard_dmg, " damage for ", target.unit_data.display_name)

		# The original target takes only the remainder.
		damage = remaining_dmg
		if damage <= 0:
			return   # Guardian absorbed everything.

	# -- 2. SHIELD CHECK ───────────────────────────────────────────────────────
	# The target's barrier absorbs damage before it touches HP.
	if grid_ref.has_method("absorb_shield_damage"):
		damage = grid_ref.absorb_shield_damage(target, damage)
		if damage <= 0:
			print("🛡️ Shield absorbed all damage for ", target.unit_data.display_name)
			return

	# -- 3. APPLY DAMAGE TO TARGET ─────────────────────────────────────────────
	var hp_before_damage: int = target.current_hp
	var actual_damage = target.take_damage(damage, ability.damage_type)
	_spawn_damage_number(actual_damage, target.position)

	# -- 4. THORNS REFLECTION ──────────────────────────────────────────────────
	# After the hit lands, check if the target has Thorns.
	# If so, reflect a portion back to the CASTER.
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
	# of the damage to all other units in the same tether group.
	if ability.aoe_shape == "single" and target.tether_ids.size() > 0:
		for tether_id in target.tether_ids:
			# Only propagate from the ABILITY's tether if it matches — or always
			# propagate from the target's existing tethers regardless of what hit them.
			var tethered = grid_ref.get_tethered_units(tether_id, target)
			for ally in tethered:
				if not is_instance_valid(ally):
					continue
				# Determine if this was an overkill hit.
				var is_overkill = (hp_before_damage - actual_damage) <= 0 and actual_damage > hp_before_damage
				# Choose the right tether percent based on overkill.
				# We look up the tether percent from the STATUS on the target unit
				# (stored when the tether was applied). Here we use a simple approach:
				# read from the ability that initially applied the tether, or fall back to 0.5.
				var tether_pct: float = 0.5
				var overkill_pct: float = 0.75
				# If the tether was applied by an ability we can reference, read its values.
				# For now we store tether config on the STATUS or read from a tag; using
				# defaults here and letting designers override via AbilityData on the ORIGIN.
				# (See tether_damage_percent on the ability that created the tether.)
				var pass_damage = int(actual_damage * (overkill_pct if is_overkill else tether_pct))
				pass_damage = max(1, pass_damage)
				var ally_hp_before = ally.current_hp
				var ally_actual = grid_ref.absorb_shield_damage(ally, pass_damage) \
								  if grid_ref.has_method("absorb_shield_damage") else pass_damage
				ally.take_damage(ally_actual, "true")   # Tether uses true damage.
				_spawn_damage_number(ally_actual, ally.position)
				print("🔗 Tether propagated ", ally_actual, " to ", ally.unit_data.display_name)

	# -- 6. ON-KILL CHECK ──────────────────────────────────────────────────────
	# If the target just died (HP was > 0 before this hit), trigger on-kill effects.
	if hp_before_damage > 0 and not is_instance_valid(target):
		_trigger_on_kill(caster, ability, target)

# ── ON-KILL HANDLER ───────────────────────────────────────────────────────────

func _trigger_on_kill(caster, ability: AbilityData, dead_target) -> void:
	# Called immediately after a killing blow is confirmed.
	if not ability.has_on_kill_effect:
		return
	if not is_instance_valid(caster):
		return

	print("💀 On-Kill triggered by ", caster.unit_data.display_name)

	# -- Spawn a trigger ability scene at the kill location or the caster's tile.
	if ability.on_kill_trigger_ability != null:
		var spawn_cell: Vector2i
		if ability.on_kill_trigger_on_caster:
			spawn_cell = caster.grid_position
		else:
			# Use the dead target's LAST known position before it was freed.
			# Since the target may already be freed, we rely on the kill position
			# stored in the calling context. We use caster position as fallback.
			spawn_cell = caster.grid_position   # Improve: store last_position on die().

		var trigger_scene = ability.on_kill_trigger_ability.instantiate()
		var spawn_root = _get_spawn_root()
		if spawn_root != null:
			spawn_root.add_child(trigger_scene)
			trigger_scene.position = grid_ref.grid_to_world(spawn_cell)

	# -- Apply a self-buff to the caster on kill.
	if ability.on_kill_apply_status != null:
		caster.apply_status(ability.on_kill_apply_status)

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
	if not is_instance_valid(target) or not is_instance_valid(caster):
		return 0

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
			offensive_stat = caster.get_effective_atk()

	match ability.damage_type:
		"physical":  defensive_stat = target.get_effective_def()
		"magical":   defensive_stat = target.get_effective_mdef()
		"hazard":    defensive_stat = target.get_effective_mdef()
		"true":      defensive_stat = 0   # True damage ignores all defense.

	# -- 2. Per-buff stat bonuses (only for this attack) ──────────────────────
	# These are bonuses the ability adds to the caster's EFFECTIVE stats for
	# this single hit based on how many buffs the caster has.
	var caster_buff_count: int = min(caster.get_buff_count(), ability.buff_bonus_max_stacks)
	offensive_stat += ability.bonus_atk_per_caster_buff  * caster_buff_count
	offensive_stat += ability.bonus_matk_per_caster_buff * caster_buff_count
	defensive_stat -= ability.bonus_def_per_caster_buff  * caster_buff_count   # more def on caster = less net dmg dealt
	# Note: crit bonuses are handled below.

	# -- 3. Base damage calculation ───────────────────────────────────────────
	var base: float = float(offensive_stat - defensive_stat) * ability.base_damage_multiplier

	# -- 4. Critical hit check ────────────────────────────────────────────────
	var crit_chance: float = caster.get_effective_crit_chance()
	crit_chance += ability.bonus_crit_chance_per_caster_buff * float(caster_buff_count)
	var roll: float = randf() * 100.0

	if roll < crit_chance:
		print("⚡ CRITICAL HIT!")
		var crit_dmg_pct: float = caster.get_stats().crit_damage
		crit_dmg_pct += ability.bonus_crit_dmg_per_caster_buff * float(caster_buff_count)
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

	return max(1, int(base))


func _is_target_isolated(target, check_range: int) -> bool:
	# Returns true if no ally of the TARGET is within check_range tiles.
	# "Ally" = a unit on the same team (same is_player_unit flag).
	for dx in range(-check_range, check_range + 1):
		for dy in range(-check_range, check_range + 1):
			if dx == 0 and dy == 0:
				continue   # Skip the target's own cell.
			if abs(dx) + abs(dy) > check_range:
				continue   # Manhattan distance > range, skip.
			var check_cell = target.grid_position + Vector2i(dx, dy)
			var unit_there = grid_ref.get_unit_at(check_cell)
			if unit_there != null and unit_there != target:
				if unit_there.is_player_unit == target.is_player_unit:
					return false   # Found an ally nearby — NOT isolated.
	return true   # No allies found — the target is isolated!

# ── DASH ──────────────────────────────────────────────────────────────────────

func _execute_dash(caster, ability: AbilityData, line_cells: Array) -> Vector2i:
	if line_cells.is_empty():
		return caster.grid_position

	var landing_cell: Vector2i = caster.grid_position
	
	for cell in line_cells:
		# Now using the function you just created in battle_grid.gd
		if grid_ref.is_terrain_walkable(cell):
			landing_cell = cell
		else:
			# Hit a wall or edge of the map; stop here.
			break

	# Move the caster (visuals and snap)
	var end_world: Vector2 = grid_ref.grid_to_world(landing_cell)
	caster.snap_to(landing_cell)

	# -- Optional trail visual: stretch a texture across all valid tiles -------
	if ability.dash_trail_texture != null:
		_spawn_dash_trail(caster.position, grid_ref.grid_to_world(landing_cell),
						  ability.dash_trail_texture)

	# -- Move the caster sprite along the dash path ---------------------------
	var start_world: Vector2 = caster.position
	var distance:    float   = start_world.distance_to(end_world)
	var duration:    float   = distance / ability.dash_speed

	# Update grid registry BEFORE tweening so pathfinding is accurate.
	caster.snap_to(landing_cell)

	# Now play the visual animation (the sprite races to the destination).
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
	# The sprite is placed at the midpoint and scaled to reach both ends.
	# It auto-deletes after 0.5 seconds.
	var spawn_root = _get_spawn_root()
	if spawn_root == null:
		return

	var trail = Sprite2D.new()
	trail.texture = trail_texture

	# Position at the midpoint of the line.
	trail.position = (from_world + to_world) / 2.0

	# Rotate to point along the dash direction.
	trail.rotation = from_world.angle_to_point(to_world)

	# Scale: the X axis should equal the pixel distance; Y stays as 1 tile.
	var pixel_length: float = from_world.distance_to(to_world)
	var tex_size: Vector2   = trail_texture.get_size()
	if tex_size.x > 0 and tex_size.y > 0:
		trail.scale = Vector2(pixel_length / tex_size.x, 96.0 / tex_size.y)
	else:
		trail.scale = Vector2(pixel_length / 96.0, 1.0)

	trail.modulate = Color(1, 1, 1, 0.7)   # Slightly transparent.
	spawn_root.add_child(trail)

	# Fade out and remove after a short time.
	var tween = get_tree().create_tween()
	tween.tween_property(trail, "modulate:a", 0.0, 0.5)
	tween.tween_callback(trail.queue_free)

# ── DISPLACEMENT HELPERS ──────────────────────────────────────────────────────

func _displace_unit_auto(caster, target, squares: int) -> void:
	var direction: Vector2i = target.grid_position - caster.grid_position
	if direction == Vector2i(0, 0):
		return

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

		# --- NEW: Stop if next tile is the caster (no overshoot)
		if next == caster.grid_position:
			break

		# --- NEW: Stop if next tile is adjacent to caster (pull ends)
		if next.distance_to(caster.grid_position) == 1:
			current = next
			break

		if not grid_ref.is_passable(next):
			break

		current = next

	if current != target.grid_position:
		target.move_to(current)

func _displace_unit_scatter(
	ability: AbilityData,
	target,
	squares: int,
	target_cells: Array
) -> void:

	# Compute center of AOE
	var sum_x: int = 0
	var sum_y: int = 0
	var count: int = target_cells.size()

	for cell in target_cells:
		sum_x += cell.x
		sum_y += cell.y

	var center: Vector2i = Vector2i(sum_x / count, sum_y / count)

	# Direction from center → target
	var direction: Vector2i = target.grid_position - center
	if direction == Vector2i(0, 0):
		return

	# Normalize to diagonal-aware step
	var dir_f: Vector2 = Vector2(direction.x, direction.y).normalized()
	var move_dir: Vector2i = Vector2i(
		int(round(dir_f.x)),
		int(round(dir_f.y))
	)

	# Fallback to cardinal if normalization degenerates
	if move_dir == Vector2i(0, 0):
		if abs(direction.x) > abs(direction.y):
			move_dir = Vector2i(sign(direction.x), 0)
		else:
			move_dir = Vector2i(0, sign(direction.y))

	var steps: int = squares
	var current: Vector2i = target.grid_position

	for _i in range(steps):
		var next: Vector2i = current + move_dir
		if not grid_ref.is_passable(next):
			break
		current = next

	if current != target.grid_position:
		target.move_to(current)



func _displace_unit_manual(target, squares: int, fixed_dir: Vector2i) -> void:
	if fixed_dir == Vector2i(0, 0):
		return

	# Convert to float vector for normalization
	var dir_f: Vector2 = Vector2(fixed_dir.x, fixed_dir.y)
	dir_f = dir_f.normalized()

	# Back to grid step (round to nearest int)
	var move_dir: Vector2i = Vector2i(
		int(round(dir_f.x)),
		int(round(dir_f.y))
	)

	# If normalization produced (0,0), fall back to cardinal
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
		if not grid_ref.is_passable(next):
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

# ── SHARED HELPERS ─────────────────────────────────────────────────────────────

func _apply_vfx_scaling(node: Node2D, target_size: Vector2, tile_size: float) -> void:
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
	var tree = get_tree()
	if tree == null:
		return null
	if grid_ref != null and grid_ref.has_node("UnitLayer"):
		return grid_ref.get_node("UnitLayer")
	if grid_ref != null:
		return grid_ref
	return tree.current_scene


func _spawn_damage_number(amount: int, pos: Vector2) -> void:
	# Floats a damage number above the target's head.
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
