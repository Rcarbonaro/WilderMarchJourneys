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
#
# MOVEMENT ADDITION:
#   Enemies now walk their actual route tile-by-tile (move_along_path()) via
#   pathfinder.reconstruct_path_to(), instead of sliding straight to the
#   destination in one shot. This makes them visually route around obstacles
#   and correctly take damage from any "damaging wall" hazard tiles they
#   cross along the way, not just the tile they end up standing on.

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

	# Filter out any enemies that are already dead (current_hp <= 0), already
	# acted, or freed. THE FIX: this used to only check is_instance_valid() and
	# has_acted — but a unit that just died (e.g. from a hazard, DoT, or Thorns
	# reflect) ISN'T freed immediately; unit_node.gd's die() plays a death
	# animation first and only actually removes/frees the unit (and emits
	# unit_died, which is what removes them from enemy_units) AFTER that
	# animation finishes. During that window, is_instance_valid(e) is still
	# true and has_acted is still false, so without checking current_hp here
	# too, a unit that's already functionally dead could still get a full
	# turn — including firing off an attack — before the game catches up and
	# removes them. This was most noticeable as "the last enemy gets one more
	# attack in before finally dying," but could happen to any enemy that
	# dies mid-round before its own turn comes up in this loop.
	active_enemies = enemies.filter(func(e):
		return is_instance_valid(e) and e.current_hp > 0 and not e.has_acted
	)

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
	# Re-check here too (not just in the filter above) — time has passed
	# since that filter ran (earlier enemies in this same loop have already
	# acted, possibly triggering Thorns/hazard/aura damage), so this enemy
	# could have died in the meantime even though it passed the filter
	# originally.
	if is_instance_valid(enemy) and enemy.current_hp > 0 and not enemy.has_acted:
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
	# This is the DEFAULT target used for non-damaging abilities, and the
	# fallback target if this enemy is taunted but can't reach the taunter.
	var default_target = null
	var closest_dist  = 999999
	for p in valid_players:
		if p.has_status("invisible"):
			continue   # Can't target invisible units.
		var dist = (abs(enemy.grid_position.x - p.grid_position.x)
				  + abs(enemy.grid_position.y - p.grid_position.y))
		if dist < closest_dist:
			closest_dist  = dist
			default_target = p

	if default_target == null:
		enemy.has_acted = true
		return

	# ── TAUNT CHECK ─────────────────────────────────────────────────────────
	# If this enemy is taunted AND the chosen ability deals damage to enemies
	# (i.e. it's an attack, not a buff/heal/movement ability), the taunter
	# becomes the PREFERRED target. We don't commit to it yet — first we check
	# in step 4 whether we can actually reach them this turn. If not, we fall
	# back to default_target (closest reachable player) for this turn only.
	var taunt_source = enemy.get_taunt_source() if enemy.has_method("get_taunt_source") else null
	var is_damaging_ability = (chosen_ability.base_damage_multiplier > 0
							  and chosen_ability.affects_team == "enemies")
	var preferred_target = default_target
	if taunt_source != null and is_damaging_ability and is_instance_valid(taunt_source):
		preferred_target = taunt_source

	var target_player = preferred_target

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
		# ── TAUNT FALLBACK ─────────────────────────────────────────────────────
		# If we were trying to reach the taunter specifically and couldn't,
		# retry the whole in-range search against the default (closest) target
		# instead, for this turn only.
		if target_player == taunt_source and taunt_source != default_target:
			print("⚠️ ", enemy.unit_data.display_name, " is taunted but can't reach ",
				  "the taunter — falling back to closest target this turn.")
			target_player = default_target
			best_move_dist = 999999
			for cell in available_move_cells.keys():
				var dist_to_target = (abs(cell.x - target_player.grid_position.x)
									+ abs(cell.y - target_player.grid_position.y))
				if dist_to_target >= chosen_ability.min_range and dist_to_target <= chosen_ability.max_range:
					if chosen_ability.requires_line_of_sight:
						if pathfinder.has_line_of_sight(cell, target_player.grid_position):
							if dist_to_target < best_move_dist:
								best_move_dist            = dist_to_target
								best_move_cell            = cell
								can_attack_from_somewhere = true
					else:
						if dist_to_target < best_move_dist:
							best_move_dist            = dist_to_target
							best_move_cell            = cell
							can_attack_from_somewhere = true

	# Final fallback: if STILL nothing in range (even after a taunt fallback),
	# just move as close as possible to whichever target we ended up on.
	if not can_attack_from_somewhere:
		best_move_dist = 999999
		for cell in available_move_cells.keys():
			var dist_to_target = (abs(cell.x - target_player.grid_position.x)
								+ abs(cell.y - target_player.grid_position.y))
			if dist_to_target < best_move_dist:
				best_move_dist = dist_to_target
				best_move_cell = cell

	# 5. Execute movement — walk the enemy tile-by-tile to the chosen cell.
	if best_move_cell != enemy.grid_position:
		enemy.look_at_target(best_move_cell)

		# Reconstruct the actual walking route from the SAME search we just
		# ran above (get_reachable_cells), so the enemy visually walks the
		# real path — routing around any units/walls in the way — instead of
		# sliding straight through them in one shot.
		var walk_path: Array = pathfinder.reconstruct_path_to(best_move_cell)
		enemy.move_along_path(walk_path)
		await enemy.movement_finished

		# ── ENTRY EFFECTS AFTER ENEMY MOVES ───────────────────────────────────
		# The enemy may have died during the walk (e.g. from a Thorns reflect,
		# an aura tick, or a "damaging wall" hazard crossed partway through).
		# Guard every access from here on.
		if not is_instance_valid(enemy):
			return
		# NOTE: hazard "enter" triggers for every tile along the path are now
		# applied AUTOMATICALLY inside move_along_path() as the enemy crosses
		# each one — no separate call needed here like there used to be.
		# Aura: fire entry damage/status for any player aura they walked into.
		if grid.has_node("AuraManager"):
			grid.get_node("AuraManager").on_enemy_unit_moved(enemy)
		# The entry effects may have just killed them — check again.
		if not is_instance_valid(enemy):
			return

	# Re-check validity before the combat phase — the enemy could have died
	# from entry effects above, or never moved but died some other way.
	if not is_instance_valid(enemy):
		return

	# 6. Combat phase — attack if we're now in range with line of sight.
	var final_dist = (abs(enemy.grid_position.x - target_player.grid_position.x)
					+ abs(enemy.grid_position.y - target_player.grid_position.y))
	var los_ok = true
	if chosen_ability.requires_line_of_sight:
		los_ok = pathfinder.has_line_of_sight(enemy.grid_position, target_player.grid_position)

	if final_dist >= chosen_ability.min_range and final_dist <= chosen_ability.max_range and los_ok:
		print("⚔️ AI executing ability: ", chosen_ability.display_name,
			  " on target: ", target_player.grid_position)

		# Use the ability's custom attack animation if one is set, otherwise
		# fall back to the normal directional attack/attack_up/attack_down logic.
		if chosen_ability.attack_animation_name != "":
			enemy.look_at_target(target_player.grid_position, chosen_ability.attack_animation_name)
		else:
			enemy.look_at_target(target_player.grid_position)
			var dy = target_player.grid_position.y - enemy.grid_position.y
			if dy < -1:  enemy.play_animation("attack_up")
			elif dy > 1: enemy.play_animation("attack_down")
			else:        enemy.play_animation("attack")

		await get_tree().create_timer(0.5).timeout

		# The enemy may have died during the pre-attack delay (e.g. from a DoT
		# status tick). Check before handing to the executor.
		if not is_instance_valid(enemy):
			return

		await executor.execute_ability(
			enemy, chosen_ability,
			[target_player.grid_position], target_player.grid_position
		)

		# Apply cooldown — guard again because execute_ability is async and the
		# enemy could have died from Thorns/tether during their own attack.
		if not is_instance_valid(enemy):
			return
		if "ability_cooldowns" in enemy:
			var cd_value = 0
			if "base_cooldown" in chosen_ability:
				cd_value = chosen_ability.base_cooldown
			elif "cooldown_turns" in chosen_ability:
				cd_value = chosen_ability.cooldown_turns
			if cd_value > 0:
				enemy.ability_cooldowns[chosen_ability.display_name] = cd_value

		await get_tree().create_timer(0.5).timeout

	# Final guard before touching has_acted — by this point the enemy is
	# expected to be alive, but entry effects, Thorns, or tether could have
	# killed them at any await above.
	if not is_instance_valid(enemy):
		return

	if enemy.has_method("play_animation"):
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
