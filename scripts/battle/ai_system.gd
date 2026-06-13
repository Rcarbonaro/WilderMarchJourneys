extends Node
# res://scripts/battle/ai_system.gd

signal ai_turn_complete

var active_enemies: Array = []
var current_enemy_index: int = 0
var active_done_callback: Callable = Callable()

func run_enemy_turn(enemies: Array, players: Array, grid: Node, pathfinder: Node, executor: Node, done_callback: Callable) -> void:
	active_done_callback = done_callback
	
	active_enemies = enemies.filter(func(e): return is_instance_valid(e) and not e.has_acted)
	if active_enemies.is_empty():
		if active_done_callback.is_valid():
			active_done_callback.call()
		emit_signal("ai_turn_complete")
		return
		
	current_enemy_index = 0
	_process_next_enemy(players, grid, pathfinder, executor)

func _process_next_enemy(players: Array, grid: Node, pathfinder: Node, executor: Node) -> void:
	if current_enemy_index >= active_enemies.size():
		if active_done_callback.is_valid():
			active_done_callback.call()
		emit_signal("ai_turn_complete")
		return
		
	var enemy = active_enemies[current_enemy_index]
	if is_instance_valid(enemy) and not enemy.has_acted:
		await _run_single_enemy(enemy, players, grid, pathfinder, executor)
		
	current_enemy_index += 1
	await get_tree().create_timer(0.4).timeout
	_process_next_enemy(players, grid, pathfinder, executor)

func _run_single_enemy(enemy, players: Array, grid: Node, pathfinder: Node, executor: Node) -> void:
	print("🤖 AI Processing Turn for: ", enemy.unit_data.display_name)
	
	# 1. Dynamically choose a valid ability
	var chosen_ability = _choose_enemy_ability(enemy)
	if chosen_ability == null:
		enemy.has_acted = true
		return

	# 2. Filter out any dead target players
	var valid_players = players.filter(func(p): return is_instance_valid(p))
	if valid_players.is_empty():
		enemy.has_acted = true
		return

	# 3. Target Selection: Find closest player unit
	var target_player = null
	var closest_dist = 999999
	for p in valid_players:
		var dist = abs(enemy.grid_position.x - p.grid_position.x) + abs(enemy.grid_position.y - p.grid_position.y)
		if dist < closest_dist:
			closest_dist = dist
			target_player = p

	if target_player == null:
		enemy.has_acted = true
		return

	# 4. Movement Planning using passed pathfinder object
	var movement_range = 3
	if enemy.has_method("get_effective_mov"):
		movement_range = enemy.get_effective_mov()
		
	var available_move_cells: Dictionary = pathfinder.get_reachable_cells(enemy.grid_position, movement_range, enemy)
	var best_move_cell = enemy.grid_position
	var best_move_dist = 999999
	var can_attack_from_somewhere = false

	# Evaluate tiles to fulfill range brackets
	for cell in available_move_cells.keys():
		var dist_to_target = abs(cell.x - target_player.grid_position.x) + abs(cell.y - target_player.grid_position.y)
		
		if dist_to_target >= chosen_ability.min_range and dist_to_target <= chosen_ability.max_range:
			if chosen_ability.requires_line_of_sight:
				if pathfinder.has_line_of_sight(cell, target_player.grid_position):
					if dist_to_target < best_move_dist:
						best_move_dist = dist_to_target
						best_move_cell = cell
						can_attack_from_somewhere = true
			else:
				if dist_to_target < best_move_dist:
					best_move_dist = dist_to_target
					best_move_cell = cell
					can_attack_from_somewhere = true

	# Fallback: migration logic if out of reach
	if not can_attack_from_somewhere:
		best_move_dist = 999999
		for cell in available_move_cells.keys():
			var dist_to_target = abs(cell.x - target_player.grid_position.x) + abs(cell.y - target_player.grid_position.y)
			if dist_to_target < best_move_dist:
				best_move_dist = dist_to_target
				best_move_cell = cell

	# 5. Execute Movement Phase
	if best_move_cell != enemy.grid_position:
		enemy.look_at_target(best_move_cell)
		enemy.move_to(best_move_cell)
		await enemy.movement_finished

	# 6. Combat Phase
	var final_dist = abs(enemy.grid_position.x - target_player.grid_position.x) + abs(enemy.grid_position.y - target_player.grid_position.y)
	var los_ok = true
	if chosen_ability.requires_line_of_sight:
		los_ok = pathfinder.has_line_of_sight(enemy.grid_position, target_player.grid_position)

	if final_dist >= chosen_ability.min_range and final_dist <= chosen_ability.max_range and los_ok:
		print("⚔️ AI executing ability: ", chosen_ability.display_name, " on target: ", target_player.grid_position)
		enemy.look_at_target(target_player.grid_position)
		
		var dy = target_player.grid_position.y - enemy.grid_position.y
		if dy < -1:
			enemy.play_animation("attack_up")
		elif dy > 1:
			enemy.play_animation("attack_down")
		else:
			enemy.play_animation("attack")
			
		await get_tree().create_timer(0.5).timeout
		
		# ✅ The layout now calls the executor exactly ONCE using the proper method arguments
		await executor.execute_ability(enemy, chosen_ability, [target_player.grid_position], target_player.grid_position)
		
		# ⏳ Safe application of cooldown adjustments
		if "ability_cooldowns" in enemy:
			var cd_value = 0
			if "base_cooldown" in chosen_ability:
				cd_value = chosen_ability.base_cooldown
			elif "cooldown_turns" in chosen_ability:
				cd_value = chosen_ability.cooldown_turns
			if cd_value > 0:
				enemy.ability_cooldowns[chosen_ability.display_name] = cd_value
				
		await get_tree().create_timer(0.5).timeout

	if is_instance_valid(enemy) and enemy.has_method("play_animation"):
		enemy.play_animation("idle")
		
	enemy.has_acted = true

func _choose_enemy_ability(unit) -> AbilityData:
	# 🆕 Gather all possible abilities this unit possesses
	var usable_abilities: Array = []
	
	# 1. Grab explicit starting abilities from the UnitData resource
	if "starting_abilities" in unit.unit_data and unit.unit_data.starting_abilities != null:
		for ability in unit.unit_data.starting_abilities:
			usable_abilities.append(ability)
			
	# 2. Grab level-dependent abilities from the progression dictionary
	var level_abilities = unit.unit_data.abilities_by_level.get(unit.level, [])
	for ability in level_abilities:
		usable_abilities.append(ability)
		
	# 3. Filter out any abilities that are currently on cooldown
	var filtered_abilities: Array = []
	for ability in usable_abilities:
		var current_cooldown = unit.ability_cooldowns.get(ability.display_name, 0) if "ability_cooldowns" in unit else 0
		if current_cooldown == 0:
			filtered_abilities.append(ability)
			
	# 4. Pick a valid ability randomly from our true combined kit
	if not filtered_abilities.is_empty():
		var chosen_ability = filtered_abilities[randi() % filtered_abilities.size()]
		print("🤖 AI [%s] successfully picked ability: %s" % [unit.unit_data.display_name, chosen_ability.display_name])
		return chosen_ability
		
	# Fallback if everything is on cooldown
	var fallback = AbilityData.new()
	fallback.display_name = "Basic Attack"
	fallback.base_damage_multiplier = 1.0
	fallback.max_range = 1
	fallback.min_range = 0
	fallback.ability_type = "basic_attack"
	fallback.affects_team = "enemies"
	fallback.scaling_stat = "atk"
	fallback.damage_type = "physical"
	return fallback
