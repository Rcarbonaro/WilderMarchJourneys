# res://scripts/battle/ai_system.gd

# 📥 CALLS FROM: BattleManager.end_player_turn() triggers enemy AI

# 📥 CALLS FROM: PathfindingSystem for movement decisions

# 📤 EXPORTS TO: AbilityExecutor — AI uses same executor as player

extends Node


# Runs all enemies, then calls the callback when done

func run_enemy_turn(enemies: Array, players: Array, grid: Node, pathfinder: Node, executor: Node, done_callback: Callable) -> void:

	for enemy in enemies:

		if enemy == null: continue

		_run_single_enemy(enemy, players, grid, pathfinder, executor)

	# After all enemies act, call back to BattleManager

	done_callback.call()

func _run_single_enemy(enemy, players: Array, grid: Node, pathfinder: Node, executor: Node) -> void:
	if players.is_empty(): return

	# 1. Target Selection
	var target = _find_closest_player(enemy, players)
	if target == null: return

	# 2. Setup Ability Data
	var basic_attack = _get_basic_attack(enemy)
	
	# 3. MOVEMENT PHASE
	var in_attack_range = pathfinder.get_cells_in_range(enemy.grid_position, basic_attack.min_range, basic_attack.max_range)
	
	# Only move if NOT already in range
	if not target.grid_position in in_attack_range: 
		var reachable = pathfinder.get_reachable_cells(enemy.grid_position, enemy.get_effective_mov())
		var best_cell = _find_best_move_toward(enemy.grid_position, target.grid_position, reachable)
		
		# Only move if there is a valid better tile to stand on
		if best_cell != enemy.grid_position:
			enemy.move_to(best_cell)
			await enemy.movement_finished # Wait for movement animation!

	# 4. ATTACK PHASE
	# Re-calculate range from our NEW position
	in_attack_range = pathfinder.get_cells_in_range(enemy.grid_position, basic_attack.min_range, basic_attack.max_range)
	
	# Check if target is now reachable AND has line of sight
	if target.grid_position in in_attack_range:
		if pathfinder.has_line_of_sight(enemy.grid_position, target.grid_position):
			# 1. Trigger the attack animation on the enemy node
			if enemy.has_method("play_animation"):
				enemy.play_animation("attack")
			
# 2. Add a brief wait so the animation can be seen by the player
		await get_tree().create_timer(0.5).timeout 
		
# 3. Perform the damage math
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
