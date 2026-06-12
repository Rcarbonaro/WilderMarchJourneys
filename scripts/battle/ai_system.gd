# res://scripts/battle/ai_system.gd

# 📥 CALLS FROM: BattleManager.end_player_turn() triggers enemy AI

# 📥 CALLS FROM: PathfindingSystem for movement decisions

# 📤 EXPORTS TO: AbilityExecutor — AI uses same executor as player

extends Node


# Runs all enemies, then calls the callback when done

func run_enemy_turn(enemies: Array, players: Array, grid: Node, pathfinder: Node, executor: Node, done_callback: Callable) -> void:

	for enemy in enemies:
		await _run_single_enemy(enemy, players, grid, pathfinder, executor)

		if enemy == null: continue

	# After all enemies act, call back to BattleManager

	done_callback.call()

func _run_single_enemy(enemy, players: Array, grid: Node, pathfinder: Node, executor: Node) -> void:
	
	if players.is_empty(): return
	
	var target = _find_closest_player(enemy, players)
	if target == null: return
	
	var basic_attack = _get_basic_attack(enemy)
	if basic_attack == null: return
	
	# --- MOVEMENT PHASE ---
	var in_attack_range = pathfinder.get_cells_in_range(enemy.grid_position, basic_attack.min_range, basic_attack.max_range)
	
	# Only move if we aren't already in an optimal attack range
	if not target.grid_position in in_attack_range:
		var reachable = pathfinder.get_reachable_cells(enemy.grid_position, enemy.get_effective_mov())
		
		if not reachable.is_empty():
			var best_cell = _find_best_ranged_position(target.grid_position, reachable, basic_attack)
			
			if best_cell != Vector2i(-1, -1) and best_cell != enemy.grid_position:
				enemy.move_to(best_cell)
				# WAIT here until the movement animation signals completion
				await enemy.movement_finished

	# --- ATTACK PHASE ---
	# Re-calculate range from our NEW position
	in_attack_range = pathfinder.get_cells_in_range(enemy.grid_position, basic_attack.min_range, basic_attack.max_range)
	
	if target.grid_position in in_attack_range:
		if pathfinder.has_line_of_sight(enemy.grid_position, target.grid_position):
			
			# 1. Face the target
			enemy.look_at_target(target.grid_position)
			
			# 2. Trigger animation
			if enemy.has_method("play_animation"):
				enemy.play_animation("attack")
				
			# 3. Wait for the player to see the animation
			await get_tree().create_timer(0.5).timeout
			
			# 4. Perform damage
			executor.execute_ability(enemy, basic_attack, [target.grid_position])
# 4. Return to idle
	if enemy.has_method("play_animation"):
		enemy.play_animation("idle")

func _find_closest_player(enemy, players: Array):

	var closest = null

	var min_dist = 9999

	for p in players:

		if p == null: continue

		var dist = abs(p.grid_position.x - enemy.grid_position.x) + abs(p.grid_position.y - enemy.grid_position.y)

		if dist < min_dist:

			min_dist = dist

			closest = p

	return closest

func _get_basic_attack(unit) -> AbilityData:

	# Gets the unit's basic attack ability

	# 📥 CALLS FROM: UnitData.abilities_by_level from unit's unit_data resource

	var level_abilities = unit.unit_data.abilities_by_level.get(unit.level, [])

	for ability in level_abilities:

		if ability.ability_type == "basic_attack":

			return ability

	# Fallback: if no basic attack defined, create a default one

	var fallback = AbilityData.new()

	fallback.base_damage_multiplier = 1.0

	fallback.max_range = 1

	fallback.ability_type = "basic_attack"

	return fallback

func _find_best_move_toward(from: Vector2i, target: Vector2i, reachable: Dictionary) -> Vector2i:

	var best_cell = from

	var best_dist = abs(target.x - from.x) + abs(target.y - from.y)

	for cell in reachable.keys():

		var dist = abs(target.x - cell.x) + abs(target.y - cell.y)

		if dist < best_dist:

			best_dist = dist

			best_cell = cell

	return best_cell

func _find_best_ranged_position(target_pos: Vector2i, reachable: Dictionary, ability: AbilityData) -> Vector2i:
	var best_cell = Vector2i(-1, -1)
	var closest_dist = 9999
	
	for cell in reachable.keys():
		var dist = abs(target_pos.x - cell.x) + abs(target_pos.y - cell.y)
		
		# Priority 1: Find a tile within the attack range
		if dist >= ability.min_range and dist <= ability.max_range:
			return cell 
		
		# Priority 2: If no attack tile, get as close as possible
		if dist < closest_dist:
			closest_dist = dist
			best_cell = cell
			
	return best_cell
