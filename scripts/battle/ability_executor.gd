# res://scripts/battle/ability_executor.gd

# 📥 CALLS FROM: BattleManager when a unit uses an ability

# 📥 CALLS FROM: UnitNode.get_effective_atk() — reads unit's current modified stats

# 📤 EXPORTS TO: UnitNode.take_damage() — sends final damage amount

# 📤 EXPORTS TO: UnitNode.apply_status() — applies status effects from the ability

extends Node

# Reference set by BattleManager

# 📥 CALLS FROM: BattleManager sets this on start

var grid_ref: Node = null

# Execute an ability from a caster aimed at target cells

func execute_ability(caster, ability: AbilityData, target_cells: Array) -> void:

	# 📥 CALLS FROM: BattleManager when player (or AI) selects an ability and confirms target

	for cell in target_cells:

		var target = grid_ref.get_unit_at(cell)

		# --- DAMAGE ---

		if ability.base_damage_multiplier > 0 and target != null:

			var damage = calculate_damage(caster, target, ability)

			target.take_damage(damage, ability.damage_type)

			# Show floating damage number

			_spawn_damage_number(damage, target.position)

		# --- APPLY STATUS EFFECTS ---

		if target != null:

			for status_data in ability.applies_statuses:

				target.apply_status(status_data)

		# --- SPAWN HAZARD ---

		if ability.spawns_hazard != null:

			grid_ref.add_hazard(cell, ability.spawns_hazard)

		# --- DISPLACEMENT (push/pull) ---

		if ability.displacement_squares != 0 and target != null:

			_displace_unit(caster, target, ability.displacement_squares)

		# --- HEALING ---

		if ability.heal_percent > 0.0:

			var target_to_heal = target if target != null else caster

			var max_hp = target_to_heal.get_stats().hp

			target_to_heal.heal(int(max_hp * ability.heal_percent))

	# --- APPLY COOLDOWN ---

	if ability.cooldown_rounds > 0:

		caster.ability_cooldowns[ability.id] = ability.cooldown_rounds

	# --- APPLY COSTS ---

	var stats = caster.get_stats()

	caster.current_mana -= ability.mana_cost

	if ability.hp_cost_percent > 0:

		caster.take_damage(int(stats.hp * ability.hp_cost_percent), "true")


func calculate_damage(caster, target, ability: AbilityData) -> int:

	# The core damage formula: max(1, (ATK - DEF) * multiplier)

	# 📥 CALLS FROM: caster.get_effective_atk/matk() from UnitNode

	# 📥 CALLS FROM: target.get_effective_def() from UnitNode

	# Choose attack stat

	var atk: int = caster.get_effective_atk() if ability.scaling_stat == "atk" else caster.get_stats().matk

	# Choose defense stat

	var def: int = 0

	match ability.damage_type:

		"physical": def = target.get_effective_def()

		"magical": def = target.get_stats().mdef

		"hazard": def = target.get_stats().mdef

		"true": def = 0  # true damage ignores all defense

	# Base damage

	var base = float(atk - def) * ability.base_damage_multiplier

	# Apply damage modifiers from target's status effects

	for s in target.active_statuses:

		var mod = s["data"].damage_taken_modifier

		if mod != 0.0:

			base *= (1.0 + mod)

	# Clamp minimum to 1

	var final_damage = max(1, int(base))

	# --- CRITICAL HIT CHECK ---

	var crit_chance = caster.get_effective_crit_chance()

	var roll = randf() * 100.0

	if roll < crit_chance:

		var crit_dmg_percent = caster.get_stats().crit_damage

		# CritDMG works as: multiply ATK by (crit_damage / 100), then recalculate

		atk = int(atk * (crit_dmg_percent / 100.0))

		base = float(atk - def) * ability.base_damage_multiplier

		for s in target.active_statuses:

			base *= (1.0 + s["data"].damage_taken_modifier)

		final_damage = max(1, int(base))

	return final_damage


func _displace_unit(caster, target, squares: int) -> void:

	# Push (positive) or pull (negative) target relative to caster

	var direction = target.grid_position - caster.grid_position

	if direction == Vector2i(0, 0): return

	# Normalize to 1 step

	if abs(direction.x) > abs(direction.y):

		direction = Vector2i(sign(direction.x), 0)

	else:

		direction = Vector2i(0, sign(direction.y))

	var move_dir = direction * sign(squares)

	var steps = abs(squares)

	var current = target.grid_position

	for _i in range(steps):

		var next = current + move_dir

		if not grid_ref.is_passable(next): break

		current = next

	if current != target.grid_position:

		target.move_to(current)


func _spawn_damage_number(amount: int, position: Vector2) -> void:
	var tree = get_tree()
	if tree == null: 
		return

	# 1. 🎯 FIND THE RIGHT GAME WORLD LAYER
	var spawn_root = null
	if grid_ref != null and grid_ref.has_node("UnitLayer"):
		spawn_root = grid_ref.get_node("UnitLayer")
	elif grid_ref != null:
		spawn_root = grid_ref
	elif tree.current_scene != null:
		spawn_root = tree.current_scene

	if spawn_root == null:
		print("⚠️ Cannot spawn damage number: No valid parent scene found.")
		return 

	# 2. CREATE AND POSITION THE UI LABEL NODE
	var damage_label = Label.new()
	damage_label.text = str(amount) # Uses 'amount' here!
	
	damage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	damage_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	# Position directly at the unit's pixel coordinates (Uses 'position' here!)
	damage_label.position = position + Vector2(-50, -60)

	# 3. HIGH-CONTRAST RETRO RPG STYLING
	var settings = LabelSettings.new()
	settings.font = SystemFont.new()
	settings.font_size = 22
	settings.font_color = Color(1.0, 0.1, 0.1) # Crimson red
	
	# 🟢 FIXED: Using universal set() to bypass strict property assignment bugs
	settings.set("outline_width", 5)
	settings.outline_color = Color(0, 0, 0) 

	# Critical hit styling
	if amount > 15:
		settings.font_size = 60
		settings.font_color = Color(1.0, 0.8, 0.0) # Bright gold

	damage_label.label_settings = settings
	
	# 4. INSTANTLY SPAWN INTO THE WORLD
	spawn_root.add_child(damage_label)

	# 5. SAFE SCENE-TREE TIMED TWEEN ANIMATION
	var tween = tree.create_tween().set_parallel(true)
	
	# Float upwards vertically over 0.75 seconds
	tween.tween_property(damage_label, "position:y", damage_label.position.y - 40, 2)\
		.set_trans(Tween.TRANS_CUBIC)\
		.set_ease(Tween.EASE_OUT)
		
	# Smoothly fade out opacity
	tween.tween_property(damage_label, "modulate:a", 0.0, 0.75)
	
	# Clean up memory completely when done
	tween.chain().tween_callback(damage_label.queue_free)
