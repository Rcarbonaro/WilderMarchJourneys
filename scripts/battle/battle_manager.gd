# res://scripts/battle/battle_manager.gd
# ==============================================================================
# THE BATTLE MANAGER (The Combat Coordinator / Referee)
# ==============================================================================
# This script does NOT draw anything and does NOT directly accept player input.
# Instead it is the "rule book": it tracks turns, unit lists, phases, and tells
# all the other systems (UI, grid, pathfinder, AI, executor) what to do and when.
# ==============================================================================

extends Node

signal battle_ended(result: String)
# This signal fires when combat ends. battle_scene.gd listens for it and then
# loads either the Shop screen (win) or the Game Over screen (loss).

# TurnPhase tracks whose turn it is as a safe enum (no typos possible).
enum TurnPhase { PLAYER_TURN, ENEMY_TURN, ANIMATION, GAME_OVER }

# ── STATE ─────────────────────────────────────────────────────────────────────

var current_phase: TurnPhase = TurnPhase.PLAYER_TURN
var round_number: int = 1
var is_battle_over: bool = false
var aoe_preview_cell: Vector2i = Vector2i(-1, -1)

# Lists of all living units on each side.
var player_units: Array = []
var enemy_units: Array = []

# Currently selected unit and chosen ability.
var selected_unit = null
var selected_ability: AbilityData = null
var reachable_cells: Dictionary = {}

# ── INSPECTOR LINKS ───────────────────────────────────────────────────────────
# These MUST be filled in the Inspector by dragging the scene nodes into the slots.

@export var grid: Node
@export var pathfinder: Node
@export var executor: Node
@export var highlight: Node
@export var ai_system: Node
@export var ui_manager: Node

# ── STARTUP ───────────────────────────────────────────────────────────────────

func _ready() -> void:
	if grid == null:
		printerr("❌ BattleManager: 'grid' export slot is empty!")
		return
	if pathfinder == null:
		printerr("❌ BattleManager: 'pathfinder' export slot is empty!")
		return
	if executor == null:
		printerr("❌ BattleManager: 'executor' export slot is empty!")
		return

	pathfinder.grid_ref = grid
	executor.grid_ref = grid

	_spawn_stage_enemies()
	_spawn_player_party_from_run()


func _spawn_player_party_from_run() -> void:
	print("🧙 Spawning Player Party Units...")
	var mage_data     = load("res://resources/units/windmage_data.tres")
	var guardian_data = load("res://resources/units/guardian_data.tres")

	if mage_data     != null: spawn_unit(mage_data,     Vector2i(1, 7), true,  1)
	else: printerr("❌ Could not load windmage_data.tres!")

	if guardian_data != null: spawn_unit(guardian_data, Vector2i(2, 8), true,  1)
	else: printerr("❌ Could not load guardian_data.tres!")


func _spawn_stage_enemies() -> void:
	print("🐺 Spawning Monster Waves...")
	var wolf_data     = load("res://resources/enemies/wolf_data.tres")
	var sylvaris_data = load("res://resources/enemies/sylvaris_data.tres")

	if wolf_data == null:
		printerr("❌ Could not load wolf_data.tres!")
		return

	spawn_unit(wolf_data,     Vector2i(7, 2), false, 1)
	spawn_unit(wolf_data,     Vector2i(8, 3), false, 1)
	spawn_unit(wolf_data,     Vector2i(8, 5), false, 1)
	if sylvaris_data != null:
		spawn_unit(sylvaris_data, Vector2i(8, 3), false, 1)

	print("🐺 Monster waves deployed!")


func spawn_unit(unit_data: UnitData, cell: Vector2i, is_player: bool, level: int = 1) -> void:
	var folder_name  := unit_data.display_name.to_lower().replace(" ", "")
	var scene_path   := "res://scenes/animations/%s/%s.tscn" % [folder_name, folder_name]

	if not ResourceLoader.exists(scene_path):
		printerr("❌ Scene not found: ", scene_path)
		return

	var unit = load(scene_path).instantiate()
	grid.get_node("UnitLayer").add_child(unit)
	unit.grid_ref = grid
	unit.setup(unit_data, level, is_player)
	unit.grid_position = cell
	unit.position = grid.grid_to_world(cell)
	grid.register_unit(unit, cell)
	unit.unit_died.connect(_on_unit_died)

	if is_player:
		player_units.append(unit)
		print("🛡️ Ally spawned: ", unit_data.display_name)
	else:
		enemy_units.append(unit)
		print("⚔️ Enemy spawned: ", unit_data.display_name)


func _on_unit_died(unit) -> void:
	print(unit.unit_data.display_name, " has fallen!")
	player_units.erase(unit)
	enemy_units.erase(unit)
	_check_battle_end()


func _check_battle_end() -> void:
	if enemy_units.is_empty():
		_battle_victory()
	elif player_units.is_empty():
		_battle_defeat()


func _battle_victory() -> void:
	print("🏆 Victory!")
	current_phase = TurnPhase.GAME_OVER
	is_battle_over = true
	battle_ended.emit("victory")


func _battle_defeat() -> void:
	print("💀 Defeat!")
	current_phase = TurnPhase.GAME_OVER
	is_battle_over = true
	battle_ended.emit("defeat")

# ── INPUT ROUTING ─────────────────────────────────────────────────────────────

func on_tile_tapped(cell: Vector2i) -> void:
	# This is the main entry point for all grid taps (from input_handler.gd).
	print("🎯 Tile tapped: ", cell, " | Phase: ", current_phase)

	if current_phase != TurnPhase.PLAYER_TURN:
		print("❌ Input ignored — not player turn.")
		return

	# STATE A: No unit is selected yet.
	if selected_unit == null:
		var unit = grid.get_unit_at(cell)
		if is_instance_valid(unit) and unit.is_player_unit:
			select_unit(unit)
		else:
			print("🟫 Empty or enemy tile — nothing selected.")

	# STATE B: A unit is selected AND an ability is active → try to cast it.
	elif selected_ability != null:
		_try_use_ability(cell)

	# STATE C: A unit is selected, waiting for movement or confirmation.
	else:
		if not is_instance_valid(selected_unit):
			deselect_unit()
			return

		# Tapping the unit's own tile: skip movement and go straight to ability selection.
		if cell == selected_unit.grid_position:
			selected_unit.has_moved = true
			highlight.clear_highlights()
			reachable_cells = {}
			_show_abilities_for(selected_unit)

		# Tapping a reachable tile: move there.
		elif reachable_cells.has(cell):
			current_phase = TurnPhase.ANIMATION

			var moving_unit = selected_unit

			# 🆕 SAVE pre-move position so we can cancel if needed.
			moving_unit.pre_move_position = moving_unit.grid_position

			highlight.clear_highlights()
			reachable_cells = {}

			moving_unit.move_to(cell)
			moving_unit.has_moved = true

			# Wait for the slide animation to finish before continuing.
			await moving_unit.movement_finished

			if is_instance_valid(moving_unit):
				current_phase = TurnPhase.PLAYER_TURN
				# 🆕 Tell the unit it CAN cancel its move at this point.
				moving_unit.can_cancel_move = true
				_show_abilities_for(moving_unit)
			else:
				current_phase = TurnPhase.PLAYER_TURN
				deselect_unit()

		# Tapping anywhere else: deselect.
		else:
			_return_selected_to_idle()
			deselect_unit()


func _show_abilities_for(unit) -> void:
	# Tells the UIManager to draw the ability buttons for this unit.
	# Also tells the UIManager whether to show the Cancel Move button.
	if ui_manager and ui_manager.has_method("show_unit_abilities"):
		ui_manager.show_unit_abilities(unit)
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		# Show the Cancel Move button only if the unit moved but has not acted yet.
		ui_manager.set_cancel_move_visible(unit.can_cancel_move and not unit.has_acted)

# ── CANCEL MOVE ───────────────────────────────────────────────────────────────

func cancel_unit_move() -> void:
	# 🆕 NEW: Called when the player presses the "Cancel Move" button.
	# Teleports the unit back to where they were before they moved this turn,
	# resets their has_moved flag, and lets them move again freely.

	if selected_unit == null or not is_instance_valid(selected_unit):
		return
	if not selected_unit.can_cancel_move:
		return

	var unit = selected_unit
	var origin: Vector2i = unit.pre_move_position

	# Safety: only cancel if we actually have a saved position.
	if origin == Vector2i(-1, -1):
		return

	print("↩️ ", unit.unit_data.display_name, " cancels their move. Returning to ", origin)

	# Remove the unit from its current cell on the grid.
	unit.grid_ref.unregister_unit(unit.grid_position)

	# Snap the visual position instantly back to the origin tile.
	# (No tween here — instant snap feels correct for "undo".)
	unit.grid_position = origin
	unit.position = unit.grid_ref.grid_to_world(origin)

	# Re-register the unit at the original tile.
	unit.grid_ref.register_unit(unit, origin)

	# Reset movement state completely.
	unit.has_moved = false
	unit.can_cancel_move = false
	unit.pre_move_position = Vector2i(-1, -1)

	# Return to idle animation.
	unit.play_animation("idle")

	# Clear the ability hotbar and re-show the movement range.
	if ui_manager and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(false)

	# Re-select the unit to show movement tiles again.
	select_unit(unit)

# ── UNIT SELECTION ────────────────────────────────────────────────────────────

func select_unit(unit) -> void:
	selected_unit = unit
	selected_ability = null

	# If the unit already moved, skip straight to ability display.
	if unit.has_moved:
		_show_abilities_for(unit)
		return

	var movement_range: int = 3
	if unit.has_method("get_effective_mov"):
		movement_range = unit.get_effective_mov()

	reachable_cells = pathfinder.get_reachable_cells(unit.grid_position, movement_range, unit)
	highlight.show_movement(reachable_cells.keys())


func deselect_unit() -> void:
	selected_unit = null
	selected_ability = null
	reachable_cells = {}
	highlight.clear_highlights()
	aoe_preview_cell = Vector2i(-1, -1)
	if ui_manager and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(false)

# ── ABILITY SELECTION ─────────────────────────────────────────────────────────

func on_ability_selected(ability: AbilityData) -> void:
	if selected_unit == null:
		return
	selected_ability = ability

	# Keep cancel move visible if the unit moved but hasn't confirmed an attack yet.
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(
			is_instance_valid(selected_unit) and selected_unit.can_cancel_move
		)

	var in_range = pathfinder.get_cells_in_range(
		selected_unit.grid_position, ability.min_range, ability.max_range
	)

	var valid_targets = []
	for cell in in_range:
		if ability.requires_line_of_sight:
			if pathfinder.has_line_of_sight(selected_unit.grid_position, cell):
				valid_targets.append(cell)
		else:
			valid_targets.append(cell)

	highlight.show_attack_range(valid_targets)


func _try_use_ability(cell: Vector2i) -> void:
	print("🔥 _try_use_ability called | unit=", selected_unit, " | ability=", selected_ability, " | cell=", cell)
	if selected_unit == null or selected_ability == null:
		print("❌ Bailing early — unit or ability is null")
		return

	# 1. Range Validation
	var valid_target_cells: Array = pathfinder.get_cells_in_range(
		selected_unit.grid_position, 
		selected_ability.min_range, 
		selected_ability.max_range
	)
	
	if not cell in valid_target_cells:
		print("❌ Out of range.")
		aoe_preview_cell = Vector2i(-1, -1)
		_refresh_ability_highlights(valid_target_cells)
		return

	# 2. Line of Sight Validation
	if selected_ability.requires_line_of_sight:
		if not pathfinder.has_line_of_sight(selected_unit.grid_position, cell):
			print("❌ Line of sight blocked.")
			return # Now properly gated inside the conditional block!

	# 3. AOE Double-Tap Confirmation Logic
	var simulated_cells: Array = _get_aoe_cells(cell, selected_ability)
	if selected_ability.aoe_shape != "single":
		if aoe_preview_cell != cell:
			aoe_preview_cell = cell
			print("🎯 First tap — showing AOE preview at: ", cell)
			if selected_unit.has_method("play_animation"):
				selected_unit.play_animation("charging")
			_draw_aoe_preview(valid_target_cells, simulated_cells)
			return
		else:
			print("🔶 Second tap confirmed — executing AOE!")

	# 4. Confirmed! Lock Phase and Execute the Ability
	current_phase = TurnPhase.ANIMATION
	print("⚔️ Executing: ", selected_ability.display_name, " on ", cell)

	# Turn to target
	selected_unit.look_at_target(cell)

	# Handle vertical vs horizontal attack animations
	var dy: int = cell.y - selected_unit.grid_position.y
	if dy < -1:
		selected_unit.play_animation("attack_up")
	elif dy > 1:
		selected_unit.play_animation("attack_down")
	else:
		selected_unit.play_animation("attack")

	# Pause briefly for animation visual impact
	await get_tree().create_timer(0.5).timeout

	# Filter targets by alignment (Enemies / Allies / All)
	var filtered_cells = _filter_cells_by_team(simulated_cells, selected_ability, selected_unit)

	# Execute game-world logic and pass required parameters
	executor.execute_ability(selected_unit, selected_ability, filtered_cells, cell)

	# State upkeep
	selected_unit.has_acted = true
	selected_unit.can_cancel_move = false

	if is_instance_valid(selected_unit) and selected_unit.has_method("play_animation"):
		selected_unit.play_animation("idle")

	selected_ability = null
	aoe_preview_cell = Vector2i(-1, -1)
	highlight.clear_highlights()
	deselect_unit()

	current_phase = TurnPhase.PLAYER_TURN
	_check_end_player_turn()

func _filter_cells_by_team(cells: Array, ability: AbilityData, caster) -> Array:
	# 🆕 NEW: Removes cells from the target list that belong to the wrong team.
	# "enemies" → only cells containing units that are NOT on the caster's team.
	# "allies"  → only cells containing units that ARE on the caster's team.
	# "all"     → no filtering, everyone gets hit.
	var result = []
	for cell in cells:
		var unit_on_cell = grid.get_unit_at(cell)
		if unit_on_cell == null:
			# Empty cell: still include it (hazards, etc. can be placed anywhere).
			result.append(cell)
			continue

		match ability.affects_team:
			"enemies":
				# Keep only cells occupied by the opposing team.
				if unit_on_cell.is_player_unit != caster.is_player_unit:
					result.append(cell)
			"allies":
				# Keep only cells occupied by the same team.
				if unit_on_cell.is_player_unit == caster.is_player_unit:
					result.append(cell)
			"all":
				# Keep everyone.
				result.append(cell)
	return result

# ── END OF PLAYER TURN ────────────────────────────────────────────────────────

func end_player_turn() -> void:
	# Called when the player presses the End Turn button.
	# 🆕 Return all selected units to idle before handing over.
	_return_selected_to_idle()

	current_phase = TurnPhase.ENEMY_TURN
	selected_ability = null
	deselect_unit()

	if highlight != null:
		highlight.clear_highlights()
	if ui_manager and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(false)

	print("--- ENEMY TURN ---")

	# Tick player statuses and reset action flags for the new round.
	for unit in player_units:
		unit.tick_statuses_end_of_round("player")
		unit.has_moved = false
		unit.has_acted = false
		unit.can_cancel_move = false

	# Count down enemy cooldowns.
	for unit in enemy_units:
		for key in unit.ability_cooldowns:
			unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)

	ai_system.run_enemy_turn(enemy_units, player_units, grid, pathfinder, executor, _on_enemy_turn_complete)


func _return_selected_to_idle() -> void:
	# 🆕 Helper: if a unit is selected and did not act yet, return it to idle.
	if selected_unit != null and is_instance_valid(selected_unit):
		if not selected_unit.has_acted:
			selected_unit.play_animation("idle")


func _on_enemy_turn_complete() -> void:
	print("--- PLAYER TURN ---")

	for unit in enemy_units:
		unit.tick_statuses_end_of_round("enemy")
		unit.has_moved = false
		unit.has_acted = false
		
		# 🆕 FIX: Decrement/clear cooldown counters for enemies too!
		if "ability_cooldowns" in unit:
			for key in unit.ability_cooldowns:
				unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)

	for unit in player_units:
		if "ability_cooldowns" in unit:
			for key in unit.ability_cooldowns:
				unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)

	round_number += 1
	current_phase = TurnPhase.PLAYER_TURN


func _check_end_player_turn() -> void:
	var all_acted = true
	aoe_preview_cell = Vector2i(-1, -1)
	for unit in player_units:
		if not unit.has_acted:
			all_acted = false
			break
	if all_acted:
		end_player_turn()

# ── AOE HELPERS ───────────────────────────────────────────────────────────────

func _draw_aoe_preview(cast_range_cells: Array, aoe_impact_cells: Array) -> void:
	if highlight == null:
		return
	highlight.clear_highlights()
	highlight.show_attack_range(cast_range_cells)
	highlight.highlight_aoe_blast_cells(aoe_impact_cells)


func _refresh_ability_highlights(valid_cells: Array) -> void:
	if highlight != null:
		highlight.clear_highlights()
		highlight.show_attack_range(valid_cells)


func _get_aoe_cells(center: Vector2i, ability: AbilityData) -> Array:
	# Returns all grid cells that fall inside this ability's AOE pattern.
	var cells = []
	var size = ability.aoe_size if "aoe_size" in ability else 1

	match ability.aoe_shape:
		"single":
			cells = [center]

		"square":
			for x in range(-size + 1, size):
				for y in range(-size + 1, size):
					var c = center + Vector2i(x, y)
					if grid.is_valid_cell(c):
						cells.append(c)

		"line":
			if selected_unit:
				var origin = selected_unit.grid_position
				var dir    = center - origin
				var step   = Vector2i(sign(dir.x), sign(dir.y))
				if step.x != 0 and step.y != 0:
					if abs(dir.x) >= abs(dir.y): step.y = 0
					else:                         step.x = 0
				if step == Vector2i.ZERO:
					step = Vector2i(1, 0)
				for i in range(1, size + 1):
					var c = origin + (step * i)
					if grid.is_valid_cell(c):
						cells.append(c)

		"cross":
			cells = [center]
			for i in range(1, size + 1):
				for c in [
					center + Vector2i(i, 0),
					center + Vector2i(-i, 0),
					center + Vector2i(0, i),
					center + Vector2i(0, -i)
				]:
					if grid.is_valid_cell(c) and not c in cells:
						cells.append(c)

		"cone":
			if selected_unit:
				var origin  = selected_unit.grid_position
				var dir     = center - origin
				var forward = Vector2i.ZERO
				var side    = Vector2i.ZERO
				if abs(dir.x) >= abs(dir.y):
					forward = Vector2i(sign(dir.x), 0)
					side    = Vector2i(0, 1)
				else:
					forward = Vector2i(0, sign(dir.y))
					side    = Vector2i(1, 0)
				if forward == Vector2i.ZERO:
					forward = Vector2i(1, 0)
					side    = Vector2i(0, 1)
				for i in range(1, size + 1):
					var row_center  = origin + (forward * i)
					var width_spread = i - 1
					for j in range(-width_spread, width_spread + 1):
						var c = row_center + (side * j)
						if grid.is_valid_cell(c):
							cells.append(c)

	return cells
