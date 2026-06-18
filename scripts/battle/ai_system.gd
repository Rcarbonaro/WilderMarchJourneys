# res://scripts/battle/ai_system.gd
# ==============================================================================
# THE AI SYSTEM — decides what each enemy does on their turn.
# ==============================================================================
# Runs through every enemy unit one at a time. For each one it:
#   1. Picks an ability (from the unit's kit, skipping anything on cooldown).
#   2. Finds the best tile to move to (closest position in range of a target).
#   3. Moves there, then attacks.
#
# AURA ADDITION:
#   After an enemy finishes moving, we notify the AuraManager so that any
#   player aura the enemy just walked into deals its entry damage and status
#   effects immediately — instead of waiting until end-of-round.

extends Node

signal ai_turn_complete
# Emitted when every enemy has finished their turn.
# BattleManager listens to this to hand control back to the player.

# ── STATE ─────────────────────────────────────────────────────────────────────

var active_enemies: Array = []
# The list of enemies who still need to act this turn.
# Filtered from the full enemy list at the start of run_enemy_turn().

var current_enemy_index: int = 0
# Which enemy in active_enemies we're currently processing.

var active_done_callback: Callable = Callable()
# The function BattleManager passed in to call when all enemies are done.

# ── MAIN ENTRY POINT ──────────────────────────────────────────────────────────

func run_enemy_turn(enemies: Array, players: Array, grid: Node,
					pathfinder: Node, executor: Node,
					done_callback: Callable) -> void:
	# Called by BattleManager at the start of the enemy phase.
	# Stores the callback and kicks off the enemy-by-enemy processing loop.
	active_done_callback = done_callback

	# Filter out any enemies that are already dead or have already acted.
	active_enemies = enemies.filter(func(e): return is_instance_valid(e) and not e.has_acted)

	if active_enemies.is_empty():
		# No enemies to process — call the callback and finish immediately.
		if active_done_callback.is_valid():
			active_done_callback.call()
		emit_signal("ai_turn_complete")
		return

	current_enemy_index = 0
	_process_next_enemy(players, grid, pathfinder, executor)


func _process_next_enemy(players: Array, grid: Node,
						 pathfinder: Node, executor: Node) -> void:
	# Processes enemies one at a time. When we've gone through all of them,
	# we call the done callback to hand control back to BattleManager.
	if current_enemy_index >= active_enemies.size():
		if active_done_callback.is_valid():
			active_done_callback.call()
		emit_signal("ai_turn_complete")
		return

	var enemy = active_enemies[current_enemy_index]
	if is_instance_valid(enemy) and not enemy.has_acted:
		await _run_single_enemy(enemy, players, grid, pathfinder, executor)

	current_enemy_index += 1
	# Small delay between enemies so the player can follow what's happening.
	await get_tree().create_timer(0.4).timeout
	_process_next_enemy(players, grid, pathfinder, executor)


func _run_single_enemy(enemy, players: Array, grid: Node,
					   pathfinder: Node, executor: Node) -> void:
	# Runs the full turn for one enemy: pick ability → move → attack.
	print("🤖 AI Processing Turn for: ", enemy.unit_data.display_name)

	# 1. Pick a valid ability from this enemy's kit (skipping cooldowns).
	var chosen_ability = _choose_enemy_ability(enemy)
	if chosen_ability == null:
		enemy.has_acted = true
		return

	# 2. Filter out any players that died since the turn started.
	var valid_players = players.filter(func(p): return is_instance_valid(p))
	if valid_players.is_empty():
		enemy.has_acted = true
		return

	# 3. Target selection: find the closest visible player unit.
	var target_player = null
	var closest_dist  = 999999
	for p in valid_players:
		if p.has_status("invisible"):
			continue   # Can't target invisible units.
		var dist = (abs(enemy.grid_position.x - p.grid_position.x)
				  + abs(enemy.grid_position.y - p.grid_position.y))
		if dist < closest_dist:
			closest_dist  = dist
			target_player = p

	if target_player == null:
		enemy.has_acted = true
		return

	# 4. Movement planning: find the best tile to move to.
	var movement_range = 3
	if enemy.has_method("get_effective_mov"):
		movement_range = enemy.get_effective_mov()

	var available_move_cells: Dictionary = pathfinder.get_reachable_cells(
		enemy.grid_position, movement_range, enemy
	)
	var best_move_cell         = enemy.grid_position
	var best_move_dist         = 999999
	var can_attack_from_somewhere = false

	# Evaluate tiles: prefer ones that put us exactly in range of the target.
	for cell in available_move_cells.keys():
		var dist_to_target = (abs(cell.x - target_player.grid_position.x)
							+ abs(cell.y - target_player.grid_position.y))
		if dist_to_target >= chosen_ability.min_range and dist_to_target <= chosen_ability.max_range:
			if chosen_ability.requires_line_of_sight:
				if pathfinder.has_line_of_sight(cell, target_player.grid_position):
					if dist_to_target < best_move_dist:
						best_move_dist             = dist_to_target
						best_move_cell             = cell
						can_attack_from_somewhere  = true
			else:
				if dist_to_target < best_move_dist:
					best_move_dist             = dist_to_target
					best_move_cell             = cell
					can_attack_from_somewhere  = true

	# Fallback: if we can't find an in-range tile, just move as close as possible.
	if not can_attack_from_somewhere:
		best_move_dist = 999999
		for cell in available_move_cells.keys():
			var dist_to_target = (abs(cell.x - target_player.grid_position.x)
								+ abs(cell.y - target_player.grid_position.y))
			if dist_to_target < best_move_dist:
				best_move_dist = dist_to_target
				best_move_cell = cell

	# 5. Execute movement — slide the enemy sprite to the chosen tile.
	if best_move_cell != enemy.grid_position:
		enemy.look_at_target(best_move_cell)
		enemy.move_to(best_move_cell)
		await enemy.movement_finished

		# ── NOTIFY AURA MANAGER AFTER ENEMY MOVES ─────────────────────────────
		# If the enemy just walked into a player's aura zone, apply damage and
		# status effects immediately rather than waiting for end-of-round.
		# We reach the AuraManager through the grid node (it's a child of BattleGrid).
		if is_instance_valid(enemy) and grid.has_node("AuraManager"):
			grid.get_node("AuraManager").on_enemy_unit_moved(enemy)

	# 6. Combat phase — attack if we're now in range with line of sight.
	var final_dist = (abs(enemy.grid_position.x - target_player.grid_position.x)
					+ abs(enemy.grid_position.y - target_player.grid_position.y))
	var los_ok = true
	if chosen_ability.requires_line_of_sight:
		los_ok = pathfinder.has_line_of_sight(enemy.grid_position, target_player.grid_position)

	if final_dist >= chosen_ability.min_range and final_dist <= chosen_ability.max_range and los_ok:
		print("⚔️ AI executing ability: ", chosen_ability.display_name,
			  " on target: ", target_player.grid_position)
		enemy.look_at_target(target_player.grid_position)

		var dy = target_player.grid_position.y - enemy.grid_position.y
		if dy < -1:  enemy.play_animation("attack_up")
		elif dy > 1: enemy.play_animation("attack_down")
		else:        enemy.play_animation("attack")

		await get_tree().create_timer(0.5).timeout

		await executor.execute_ability(
			enemy, chosen_ability,
			[target_player.grid_position], target_player.grid_position
		)

		# Apply cooldown from the ability's cooldown field.
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
	# Picks an ability for the enemy to use this turn.
	# Combines starting_abilities and level-gated abilities, then filters out
	# anything currently on cooldown. Returns a random pick from what's left.

	var usable_abilities: Array = []

	# Grab abilities defined directly on the unit data card.
	if "starting_abilities" in unit.unit_data and unit.unit_data.starting_abilities != null:
		for ability in unit.unit_data.starting_abilities:
			usable_abilities.append(ability)

	# Grab any abilities that unlock at the unit's current level.
	var level_abilities = unit.unit_data.abilities_by_level.get(unit.level, [])
	for ability in level_abilities:
		usable_abilities.append(ability)

	# Filter out abilities that are still on cooldown.
	var filtered_abilities: Array = []
	for ability in usable_abilities:
		var current_cd = unit.ability_cooldowns.get(ability.display_name, 0) \
						 if "ability_cooldowns" in unit else 0
		if current_cd == 0:
			filtered_abilities.append(ability)

	# Return a random pick from what's available.
	if not filtered_abilities.is_empty():
		var chosen = filtered_abilities[randi() % filtered_abilities.size()]
		print("🤖 AI [%s] picked ability: %s" % [unit.unit_data.display_name, chosen.display_name])
		return chosen

	# Every ability was on cooldown — fall back to a basic melee attack.
	var fallback          = AbilityData.new()
	fallback.display_name = "Basic Attack"
	fallback.base_damage_multiplier = 1.0
	fallback.max_range    = 1
	fallback.min_range    = 0
	fallback.ability_type = "basic_attack"
	fallback.affects_team = "enemies"
	fallback.scaling_stat = "atk"
	fallback.damage_type  = "physical"
	return fallback
