# res://scripts/battle/ability_executor.gd
#
# This script is the "damage calculator and effects applier".
# When a unit uses an ability, BattleManager calls execute_ability() here,
# which runs through every affected tile, applies damage/healing/statuses,
# and spawns the visual effects.

extends Node

var grid_ref: Node = null
# Set by BattleManager on startup so we can look up units on tiles.


func execute_ability(caster, ability: AbilityData, target_cells: Array, origin_cell: Vector2i = Vector2i(-1, -1)) -> void:
	# ── PROJECTILE VFX (single-target ranged) ─────────────────────────────────
	# If the ability is single-target AND has a range greater than 1,
	# we fire a projectile and delay damage until it arrives.
	if ability.aoe_shape == "single" and ability.max_range > 1 and target_cells.size() == 1:
		var target_cell = target_cells[0]
		var target_unit = grid_ref.get_unit_at(target_cell)

		# Spawn the projectile visual and AWAIT its travel.
		await _launch_projectile(caster, ability, target_cell)

		# NOW apply damage (after the projectile hit).
		if target_unit != null and is_instance_valid(target_unit):
			if ability.base_damage_multiplier > 0:
				var damage = calculate_damage(caster, target_unit, ability)
				target_unit.take_damage(damage, ability.damage_type)
				_spawn_damage_number(damage, target_unit.position)

			for status_data in ability.applies_statuses:
				target_unit.apply_status(status_data)

			if ability.displacement_squares != 0:
				_displace_unit(caster, target_unit, ability.displacement_squares)

			if ability.heal_percent > 0.0:
				var max_hp = target_unit.get_stats().hp
				target_unit.heal(int(max_hp * ability.heal_percent))

	else:
		# ── AOE / MELEE — play VFX then apply damage ──────────────────────────
		# For AOE shapes, show the impact visual first, then apply effects.
		if ability.aoe_shape != "single":

			await _play_aoe_vfx(caster, ability, target_cells, origin_cell)
			await get_tree().create_timer(0.1).timeout
			
		# Apply effects to every cell in the (already team-filtered) list.
		for cell in target_cells:
			var target = grid_ref.get_unit_at(cell)

			# ── DAMAGE ────────────────────────────────────────────────────────
			if ability.base_damage_multiplier > 0 and target != null:
				var damage = calculate_damage(caster, target, ability)
				target.take_damage(damage, ability.damage_type)
				_spawn_damage_number(damage, target.position)

			# ── APPLY STATUS EFFECTS ──────────────────────────────────────────
			if target != null:
				for status_data in ability.applies_statuses:
					target.apply_status(status_data)

			# ── SPAWN HAZARD ──────────────────────────────────────────────────
			if ability.spawns_hazard != null:
				grid_ref.add_hazard(cell, ability.spawns_hazard)

			# ── DISPLACEMENT (push / pull) ────────────────────────────────────
			if ability.displacement_squares != 0 and target != null:
				_displace_unit(caster, target, ability.displacement_squares)

			# ── HEALING ───────────────────────────────────────────────────────
			if ability.heal_percent > 0.0:
				var target_to_heal = target if target != null else caster
				var max_hp = target_to_heal.get_stats().hp
				target_to_heal.heal(int(max_hp * ability.heal_percent))

	# ── COOLDOWN ──────────────────────────────────────────────────────────────
	if ability.cooldown_rounds > 0:
		caster.ability_cooldowns[ability.id] = ability.cooldown_rounds

	# ── COSTS (mana and HP) ───────────────────────────────────────────────────
	var stats = caster.get_stats()
	caster.current_mana -= ability.mana_cost
	if ability.hp_cost_percent > 0:
		caster.take_damage(int(stats.hp * ability.hp_cost_percent), "true")


# ── DAMAGE FORMULA ────────────────────────────────────────────────────────────

func calculate_damage(caster, target, ability: AbilityData) -> int:
	# 🛑 CRITICAL FIX 1: Check instance validity IMMEDIATELY before doing ANYTHING with 'target' or 'caster'
	if not is_instance_valid(target) or not is_instance_valid(caster):
		print("⚠️ Damage calculation bypassed: Caster or Target vanished from memory!")
		return 0

	# 1. Fetch CURRENT EFFECTIVE STATS instead of base stats
	var offensive_stat: int = 0
	var defensive_stat: int = 0
	var stat_name: String = "ATK"
	var def_name: String = "DEF"
	
	if ability.damage_type == "magical":
		# Use effective Magic Attack / Magic Defense methods if they exist, otherwise fallback
		offensive_stat = caster.get_effective_matk() if caster.has_method("get_effective_matk") else caster.get_stats().matk
		defensive_stat = target.get_effective_mdef() if target.has_method("get_effective_mdef") else target.get_stats().mdef
		stat_name = "MATK"
		def_name = "MDEF"
	else:
		# Use effective Physical Attack / Physical Defense methods
		offensive_stat = caster.get_effective_atk() if caster.has_method("get_effective_atk") else caster.get_stats().atk
		defensive_stat = target.get_effective_def() if target.has_method("get_effective_def") else target.get_stats().def

	# 2. Calculate initial base damage using our modified dynamic stats
	var base: float = float(offensive_stat - defensive_stat) * ability.base_damage_multiplier

	# Step 3: Roll for critical hit and apply stat modifiers before final tracking
	var is_critical: bool = false
	var crit_chance = caster.get_effective_crit_chance() if caster.has_method("get_effective_crit_chance") else 0.0
	var roll = randf() * 100.0
	
	if roll < crit_chance:
		print("⚡ CRITICAL HIT!")
		is_critical = true
		var crit_dmg_percent = caster.get_stats().crit_damage if "crit_damage" in caster.get_stats() else 150.0
		
		var crit_offensive_stat = int(offensive_stat * (crit_dmg_percent / 100.0))
		base = float(crit_offensive_stat - defensive_stat) * ability.base_damage_multiplier

	# 🛑 STRUCTURAL FIX 2: Moved status multipliers out of the crit-only block 
	# so that active statuses are calculated for ALL regular attacks as well.
	if "active_statuses" in target and target.active_statuses != null:
		for s in target.active_statuses:
			if s.has("data") and "damage_taken_modifier" in s["data"]:
				base *= (1.0 + s["data"].damage_taken_modifier)

	# Step 4: Clamp to at least 1 minimum damage so attacks never deal 0 or negative values.
	var final_damage = max(1, int(base))
	return final_damage

	print("💥 Damage calc: %s %s=%d vs %s %s=%d | Type=%s | Multiplier=%.1f" % [
		caster.unit_data.display_name, stat_name, offensive_stat,
		target.unit_data.display_name, def_name, defensive_stat,
		ability.damage_type, ability.base_damage_multiplier
	])
	print("   → Final damage: ", final_damage)

	return final_damage

# ── PROJECTILE VFX ────────────────────────────────────────────────────────────

func _launch_projectile(caster, ability: AbilityData, target_cell: Vector2i) -> void:
	# Creates a travelling projectile from the caster to the target cell.
	# The projectile uses the ability's effect_scene if set, otherwise the icon,
	# otherwise a plain white square.
	# Returns (via await) when the projectile reaches the target.

	var spawn_root = _get_spawn_root()
	if spawn_root == null:
		return

	var start_pos: Vector2 = caster.position
	var end_pos:   Vector2 = grid_ref.grid_to_world(target_cell)

	# ── Build the projectile node ──────────────────────────────────────────────
	var proj_node: Node2D

	if ability.effect_scene != null:
		# Use the custom PackedScene (e.g. an animated arrow or fireball).
		proj_node = ability.effect_scene.instantiate()
	else:
		# Fall back to a sprite showing the ability icon (or a white square).
		var sprite := Sprite2D.new()
		if ability.icon != null:
			sprite.texture = ability.icon
		else:
			# No icon → create a plain white 24×24 square texture.
			var img := Image.create(24, 24, false, Image.FORMAT_RGBA8)
			img.fill(Color.WHITE)
			sprite.texture = ImageTexture.create_from_image(img)
		proj_node = sprite

	# ── Position and rotate toward the target ─────────────────────────────────
	# The default direction is assumed to be "facing right" (angle 0).
	# We calculate the angle from start to end and rotate the sprite accordingly.
	proj_node.position = start_pos
	var angle_to_target := start_pos.angle_to_point(end_pos)
	proj_node.rotation = angle_to_target

	spawn_root.add_child(proj_node)

	# ── Tween across the screen ───────────────────────────────────────────────
	# Travel speed: pixels per second. Adjust this value to taste.
	var TRAVEL_SPEED := 600.0
	var distance     := start_pos.distance_to(end_pos)
	var duration     := distance / TRAVEL_SPEED

	var tween = get_tree().create_tween()
	tween.tween_property(proj_node, "position", end_pos, duration)\
		.set_trans(Tween.TRANS_LINEAR)\
		.set_ease(Tween.EASE_IN_OUT)

	# Wait for the tween to finish before returning control to execute_ability.
	await tween.finished

	# Clean up the projectile node.
	proj_node.queue_free()

# ── AOE VFX ───────────────────────────────────────────────────────────────────

func _play_aoe_vfx(caster, ability: AbilityData, target_cells: Array, origin_cell: Vector2i) -> void:
	# Spawns a visual overlay for AOE shapes (square, cone, line).
	# For directional shapes (cone / line), the visual is rotated to match the angle.
	# Uses effect_scene > icon > white square, in that priority order.

	var spawn_root = _get_spawn_root()
	if spawn_root == null or target_cells.is_empty():
		return

	# Calculate the bounding box of all affected cells so we can size the visual.
	var min_x = target_cells[0].x
	var max_x = target_cells[0].x
	var min_y = target_cells[0].y
	var max_y = target_cells[0].y
	for cell in target_cells:
		min_x = min(min_x, cell.x)
		max_x = max(max_x, cell.x)
		min_y = min(min_y, cell.y)
		max_y = max(max_y, cell.y)

	var TILE_SIZE: float = 96.0  # Must match BattleGrid.TILE_SIZE
	var cell_width  = (max_x - min_x + 1) * TILE_SIZE
	var cell_height = (max_y - min_y + 1) * TILE_SIZE
	var target_size := Vector2(cell_width, cell_height)

	# Center the overlay on the middle of the bounding box.
	var center_cell := Vector2i(
		int((min_x + max_x) / 2.0),
		int((min_y + max_y) / 2.0)
	)
	var center_world: Vector2 = grid_ref.grid_to_world(center_cell)

	var vfx_node: Node2D
	var is_custom_scene: bool = false

	if ability.effect_scene != null:
		vfx_node = ability.effect_scene.instantiate()
		is_custom_scene = true
		_apply_vfx_scaling(vfx_node, target_size, TILE_SIZE)
	else:
		# Build a sprite that exactly covers the bounding box.
		var sprite := Sprite2D.new()
		if ability.icon != null:
			sprite.texture = ability.icon
			# If you want the icon to repeat/tile across the AOE instead of stretching out of proportion:
			sprite.region_enabled = true
			sprite.region_rect = Rect2(0, 0, cell_width, cell_height)
			sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		else:
			# Generate a flat color placeholder fitting the exact pixel dimensions
			var img := Image.create(int(cell_width), int(cell_height), false, Image.FORMAT_RGBA8)
			img.fill(Color.WHITE)
			sprite.texture = ImageTexture.create_from_image(img)
		
		# Make it semi-transparent so the grid is still visible underneath.
		sprite.modulate = Color(1, 1, 1, 0.6)
		vfx_node = sprite

	# ── Rotate for directional AOE shapes ─────────────────────────────────────
	if ability.aoe_shape in ["line", "cone"]:
		if origin_cell != Vector2i(-1, -1) and caster != null:
			var caster_world: Vector2 = grid_ref.grid_to_world(caster.grid_position)
			var target_world: Vector2 = grid_ref.grid_to_world(origin_cell)
			var angle = caster_world.angle_to_point(target_world)
			vfx_node.rotation = angle

	vfx_node.position = center_world
	spawn_root.add_child(vfx_node)

	# ── Handle Dynamic Visual Tracking Lifecycle ──────────────────────────────
	if is_custom_scene:
		if vfx_node is AnimatedSprite2D:
			vfx_node.play("default")
			await vfx_node.animation_finished
		elif vfx_node.has_node("AnimatedSprite2D"):
			var anim_sprite = vfx_node.get_node("AnimatedSprite2D") as AnimatedSprite2D
			anim_sprite.play("default")
			await anim_sprite.animation_finished
		elif vfx_node.has_node("AnimationPlayer"):
			var anim_player = vfx_node.get_node("AnimationPlayer") as AnimationPlayer
			if anim_player.has_animation("play"):
				anim_player.play("play")
			await anim_player.animation_finished
		else:
			await get_tree().create_timer(0.6).timeout
	else:
		await get_tree().create_timer(0.6).timeout

	if is_instance_valid(vfx_node):
		vfx_node.queue_free()


# Helper function to dynamically scale custom scene hierarchies or animated elements
func _apply_vfx_scaling(node: Node2D, target_size: Vector2, tile_size: float) -> void:
	if node is AnimatedSprite2D:
		var sprite_frames = node.sprite_frames
		if sprite_frames and sprite_frames.has_animation("default"):
			var frame_tex = sprite_frames.get_frame_texture("default", 0)
			if frame_tex:
				var tex_size = frame_tex.get_size()
				node.scale = target_size / tex_size
				return
	
	# Check if the scene root is a base Node2D housing an AnimatedSprite2D child
	if node.has_node("AnimatedSprite2D"):
		var child_sprite = node.get_node("AnimatedSprite2D") as AnimatedSprite2D
		var sprite_frames = child_sprite.sprite_frames
		if sprite_frames and sprite_frames.has_animation("default"):
			var frame_tex = sprite_frames.get_frame_texture("default", 0)
			if frame_tex:
				var tex_size = frame_tex.get_size()
				child_sprite.scale = target_size / tex_size
				return

	# Fallback scale: scale the root object uniformly based on relative tile size units
	node.scale = target_size / Vector2(tile_size, tile_size)

# ── SHARED HELPERS ────────────────────────────────────────────────────────────

func _get_spawn_root() -> Node:
	# Returns the best available parent node for spawning VFX.
	var tree = get_tree()
	if tree == null:
		return null
	if grid_ref != null and grid_ref.has_node("UnitLayer"):
		return grid_ref.get_node("UnitLayer")
	if grid_ref != null:
		return grid_ref
	return tree.current_scene


func _displace_unit(caster, target, squares: int) -> void:
	var direction = target.grid_position - caster.grid_position
	if direction == Vector2i(0, 0): return
	if abs(direction.x) > abs(direction.y):
		direction = Vector2i(sign(direction.x), 0)
	else:
		direction = Vector2i(0, sign(direction.y))

	var move_dir = direction * sign(squares)
	var steps    = abs(squares)
	var current  = target.grid_position

	for _i in range(steps):
		var next = current + move_dir
		if not grid_ref.is_passable(next): break
		current = next

	if current != target.grid_position:
		target.move_to(current)


func _spawn_damage_number(amount: int, pos: Vector2) -> void:
	var tree = get_tree()
	if tree == null: return

	var spawn_root = _get_spawn_root()
	if spawn_root == null: return

	var damage_label = Label.new()
	damage_label.text = str(amount)
	damage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	damage_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	damage_label.position = pos + Vector2(-50, -60)

	var settings = LabelSettings.new()
	settings.font      = SystemFont.new()
	settings.font_size = 22
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
