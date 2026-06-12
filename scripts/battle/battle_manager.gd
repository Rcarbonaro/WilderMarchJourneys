# res://scripts/battle/battle_manager.gd
# ==============================================================================
# THE BATTLE MANAGER (The Combat Coordinator)
# ==============================================================================
# Think of this script as the board game rules and the referee. It doesn't draw
# graphics or handle player touches directly; instead, it coordinates the turns,
# keeps track of who is alive, and connects all the separate systems together.
# ==============================================================================

extends Node

# SIGNALS: Custom alarm bells. Other scripts (like battle_scene.gd) listen for 
# this alarm to know when the match ends so they can load victory/defeat screens.
signal battle_ended(result: String)

# ENUMS: Human-readable lists of states. This acts as a safeguard to prevent 
# typo mistakes when setting or checking phases.
enum TurnPhase { PLAYER_TURN, ENEMY_TURN, ANIMATION, GAME_OVER }

# STATE VARIABLES: These variables track the live background rules of the match.
var current_phase: TurnPhase = TurnPhase.PLAYER_TURN # The match starts on Player Turn
var round_number: int = 1                            # Current combat round index
var is_battle_over: bool = false                     # Tracks if the match has concluded without conflicting with our signal name!

# AOE preview cell variable
var aoe_preview_cell: Vector2i = Vector2i(-1, -1)

# TRACKING ARRAYS: Simple storage lists that hold the actual characters on the board.
var player_units: Array = [] # List of active player heroes
var enemy_units: Array = []  # List of active enemy monsters

# SELECTION TRACKING: Remembers exactly what the player clicked on.
var selected_unit = null                 # Stores the UnitNode clicked (null = none)
var selected_ability: AbilityData = null # Stores the Ability card resource clicked

# DICTIONARIES: Storage using Key-Value pairs. 
# Here, the 'Key' is a tile grid coordinate (Vector2i), and the 'Value' is path info.
var reachable_cells: Dictionary = {}


# ==============================================================================
# INSPECTOR LINKS (@export variables)
# ==============================================================================
# The '@export' keyword exposes these slots in your Inspector panel on the right.
# You MUST drag and drop your actual scene nodes into these slots so this script 
# knows how to communicate with them!
@export var grid: Node          # Points to BattleGrid (Handles positioning math)
@export var pathfinder: Node    # Points to PathfindingSystem (Calculates walk ranges)
@export var executor: Node      # Points to AbilityExecutor (Calculates damage hits)
@export var highlight: Node     # Points to HighlightManager (Paints green/red tiles)
@export var ai_system: Node     # Points to AISystem (Controls the enemy brain)
@export var ui_manager: Node    # Points to UIManager (Draws action hotbars)


# _ready() runs automatically the exact millisecond this node boots into the game.
func _ready() -> void:
	# Check the grid first — everything else depends on it.
	if grid == null:
		printerr("❌ BattleManager: 'grid' export slot is empty! Drag BattleGrid into it in the Inspector.")
		return
	
	# Check the pathfinder — needed for movement range calculations.
	if pathfinder == null:
		printerr("❌ BattleManager: 'pathfinder' export slot is empty! Drag PathfindingSystem into it in the Inspector.")
		return
	
	# Check the executor — needed for ability and damage resolution.
	if executor == null:
		printerr("❌ BattleManager: 'executor' export slot is empty! Drag AbilityExecutor into it in the Inspector.")
		return
	
	# All clear! Inform the pathfinder and the damage executor where our tile map lives.
	pathfinder.grid_ref = grid
	executor.grid_ref = grid
	
	# ==============================================================================
	# 📍 DEFINING WHAT UNITS SPAWN
	# ==============================================================================
	# These two functions handle spawning our specific battle line-up when the game starts.
	_spawn_stage_enemies()
	_spawn_player_party_from_run()


# Handles loading and materializing your player party characters
func _spawn_player_party_from_run() -> void:
	print("🧙‍♂️ Spawning Player Party Units...")
	
	# 1. Load the raw .tres data resource files for your heroes
	var mage_data = load("res://resources/units/windmage_data.tres")
	var guardian_data = load("res://resources/units/guardian_data.tres")
	
	# 2. Summon 1 WindMage (Resource, Grid Coordinate, IsPlayer = true, Level = 1)
	if mage_data != null:
		spawn_unit(mage_data, Vector2i(1, 7), true, 1)
	else:
		printerr("❌ Could not load windmage_data.tres! Check your file path.")

	# 3. Summon 1 Guardian
	if guardian_data != null:
		spawn_unit(guardian_data, Vector2i(2, 8), true, 1)
	else:
		printerr("❌ Could not load guardian_data.tres! Check your file path.")


# Handles loading and materializing your enemy monsters
func _spawn_stage_enemies() -> void:
	print("🐺 Spawning Monster Waves...")
	
	# 1. Load the raw .tres data resource file for your wolf enemy
	var wolf_data = load("res://resources/enemies/wolf_data.tres")
	var sylvaris_data = load("res://resources/enemies/sylvaris_data.tres")

	
	if wolf_data == null:
		printerr("❌ Could not load wolf_data.tres! Check your file path.")
		return
		
	# 2. Summon 3 separate Wolf units at unique positions on the right side of the board
	# (Resource, Grid Coordinate, IsPlayer = false, Level = 1)
	spawn_unit(wolf_data, Vector2i(7, 2), false, 1) # Wolf A
	spawn_unit(wolf_data, Vector2i(8, 3), false, 1) # Wolf B
	spawn_unit(wolf_data, Vector2i(8, 5), false, 1) # Wolf C
	spawn_unit(sylvaris_data, Vector2i(8, 3), false, 1) # Wolf B

	
	print("🐺 3 Wild Wolves have surrounded the party!")


# ==============================================================================
# 🛠️ THE MASTER UNIFIED SPAWNING FACTORY
# ==============================================================================
## This function reads a character's data card, dynamically finds their matching 
## visual .tscn scene file, materializes it, positions it, and assigns its team list.
func spawn_unit(unit_data: UnitData, cell: Vector2i, is_player: bool, level: int = 1) -> void:
	
	# 1. 🟢 DYNAMIC PATH GENERATION
	# Strip away spaces and convert the display name to pure lowercase to build our folder string.
	# Example: "Wind Mage" -> "windmage" | "Wolf" -> "wolf"
	var folder_name: String = unit_data.display_name.to_lower().replace(" ", "")
	
	# Assemble our strict layout string directory file path automatically
	var scene_to_load: String = "res://scenes/animations/%s/%s.tscn" % [folder_name, folder_name]
	
	print("📂 [Spawning] Dynamic asset search path: ", scene_to_load)
	
	# 2. 🛡️ FILE CHECK SAFETY GATE
	# Intercept typos before they trigger an unrecoverable hard crash inside the engine.
	if not ResourceLoader.exists(scene_to_load):
		printerr("❌ CRITICAL ERROR: Could not find scene file for ", unit_data.display_name, " at expected path: ", scene_to_load)
		return

	# 3. 🎬 MATERIALIZE AND INITIALIZE THE SCENE NODE
	var unit_scene = load(scene_to_load)
	var unit = unit_scene.instantiate()
	
	# Append our new living unit instance directly inside the map grid scene tree layout
	grid.get_node("UnitLayer").add_child(unit)
	
	# Pass required map metrics down to the script running on the character node
	unit.grid_ref = grid
	unit.setup(unit_data, level, is_player)
	
	# Sync position arrays and snap abstract map matrices into 2D camera pixels
	unit.grid_position = cell
	unit.position = grid.grid_to_world(cell)
	
	# Lock this tile coordinate completely so no other units can occupy it
	grid.register_unit(unit, cell)
	
	# Connect the death signal so the referee knows immediately when this unit falls
	unit.unit_died.connect(_on_unit_died)

	# 4. 🧭 UNIFIED SORTING
	# Filter tracking pointer updates cleanly into Friend or Foe referee lists
	if is_player:
		player_units.append(unit)
		print("🛡️ Success: Connected ", unit_data.display_name, " to the Ally Player Array.")
	else:
		enemy_units.append(unit)
		print("⚔️ Success: Connected ", unit_data.display_name, " to the Enemy Monster Array.")


# Triggers automatically whenever ANY unit emits its death alarm signal.
func _on_unit_died(unit) -> void:
	print(unit.unit_data.display_name, " has fallen!")
	player_units.erase(unit)
	enemy_units.erase(unit)
	_check_battle_end()


# Evaluates win/loss metrics.
func _check_battle_end() -> void:
	if enemy_units.is_empty():
		_battle_victory()
	elif player_units.is_empty():
		_battle_defeat()


func _battle_victory() -> void:
	print("Victory!")
	current_phase = TurnPhase.GAME_OVER
	is_battle_over = true
	battle_ended.emit("victory") 


func _battle_defeat() -> void:
	print("Defeat!")
	current_phase = TurnPhase.GAME_OVER
	is_battle_over = true
	battle_ended.emit("defeat") 


# ==============================================================================
# TWO-STEP MOVE-THEN-ACT SELECTION LOOPS
# ==============================================================================

# Input gate: Triggered when you tap a grid coordinate cell on your screen.
func on_tile_tapped(cell: Vector2i) -> void:
	print("🎯 Map Grid Tapped at coordinate: ", cell, " | Current Game Phase: ", current_phase)
	
	# Ignore clicks if not in player turn
	if current_phase != TurnPhase.PLAYER_TURN: 
		print("❌ Click Ignored: Controls are locked during animations or enemy actions!")
		return

	# STATE A: No unit selected
	if selected_unit == null:
		var unit = grid.get_unit_at(cell)
		if is_instance_valid(unit) and unit.is_player_unit:
			select_unit(unit)
		else:
			print("🟫 Empty tile or non-player unit.")
			
	# STATE B: Targeting/Casting state
	elif selected_ability != null:
		_try_use_ability(cell)
		
	# STATE C: Unit selected, waiting for movement instructions
	else:
		# Check if the unit is still valid before doing anything
		if not is_instance_valid(selected_unit):
			deselect_unit()
			return

		if cell == selected_unit.grid_position:
			selected_unit.has_moved = true
			highlight.clear_highlights()
			reachable_cells = {}
			if ui_manager and ui_manager.has_method("show_unit_abilities"):
				ui_manager.show_unit_abilities(selected_unit)
				
		elif reachable_cells.has(cell):
			# 🟢 LOCK INPUTS: Set phase to ANIMATION so no new inputs trigger logic
			current_phase = TurnPhase.ANIMATION
			
			# Store a local reference to the unit moving
			var moving_unit = selected_unit
			
			highlight.clear_highlights()
			reachable_cells = {}
			
			# Move the unit
			moving_unit.move_to(cell)
			moving_unit.has_moved = true
			
			# 🟢 AWAIT MOVEMENT:
			# We await the signal. Using 'await' makes the execution stop here
			# until the signal is emitted, preventing parallel race conditions.
			await moving_unit.movement_finished
			
			# 🟢 POST-MOVE SAFETY CHECK: 
			# Ensure the unit still exists after the animation
			if is_instance_valid(moving_unit):
				current_phase = TurnPhase.PLAYER_TURN
				# Re-select or update UI
				if ui_manager and ui_manager.has_method("show_unit_abilities"):
					ui_manager.show_unit_abilities(moving_unit)
			else:
				# If the unit was destroyed during move, reset state
				current_phase = TurnPhase.PLAYER_TURN
				deselect_unit()
		else:
			deselect_unit()


# Step 1: Activates the hero and shows their movement range.
func select_unit(unit) -> void:
	selected_unit = unit
	selected_ability = null
	
	if unit.has_moved:
		if ui_manager != null and ui_manager.has_method("show_unit_abilities"):
			ui_manager.show_unit_abilities(unit)
		return

	var movement_range: int = 3
	if unit.has_method("get_effective_mov"):
		movement_range = unit.get_effective_mov()

	print("🚶 Calculating pathfinding grid weights for distance: ", movement_range)

	reachable_cells = pathfinder.get_reachable_cells(unit.grid_position, movement_range, unit)
	highlight.show_movement(reachable_cells.keys())
	
	
# Clears selections and completely wipes out the UI hotbar buttons.
func deselect_unit() -> void:
	selected_unit = null
	selected_ability = null
	reachable_cells = {}
	highlight.clear_highlights()
	aoe_preview_cell = Vector2i(-1, -1)
	if ui_manager != null and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()


# Triggered by UIManager buttons when you tap a skill icon button.
func on_ability_selected(ability: AbilityData) -> void:
	if selected_unit == null: return
	selected_ability = ability
	
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


# Fires ability calculations and charges damage costs
func _try_use_ability(cell: Vector2i) -> void:
	if selected_unit == null or selected_ability == null: 
		return
		
	var valid_target_cells: Array = pathfinder.get_cells_in_range(
		selected_unit.grid_position, 
		selected_ability.min_range, 
		selected_ability.max_range
	)
	
	# STRICT RANGE ENFORCEMENT
	if not cell in valid_target_cells:
		print("❌ ATTACK FAILED: Target tile ", cell, " is out of range.")
		aoe_preview_cell = Vector2i(-1, -1)
		_refresh_ability_highlights(valid_target_cells)
		return 

	if selected_ability.requires_line_of_sight:
		if not pathfinder.has_line_of_sight(selected_unit.grid_position, cell):
			print("❌ ATTACK FAILED: Line of sight is blocked to tile ", cell)
			return

	var simulated_cells = _get_aoe_cells(cell, selected_ability)
	
	# TWO-STEP CONFIRMATION LOGIC FOR AOE
	if selected_ability.aoe_shape != "single":
		if aoe_preview_cell != cell:
			aoe_preview_cell = cell
			print("🎯 Previewing AOE shape centered at: ", cell)
			
			# 🟢 ANIMATION HOOK: Play casting animation loop during targeting selection phase
			if selected_unit.has_method("play_animation"):
				selected_unit.play_animation("charging")
				
			_draw_aoe_preview(valid_target_cells, simulated_cells)
			return 

	# CONFIRMED! Action locked down for computational calculations
	current_phase = TurnPhase.ANIMATION
	print("⚔️ Confirmed! Executing ability: ", selected_ability.display_name, " on target cell: ", cell)
	
	# 🟢 ANIMATION HOOK: Play attack flash frames before execution math fires
	if selected_unit.has_method("play_animation"):
		selected_unit.play_animation("attack")
		await get_tree().create_timer(1).timeout
	
	var target_cells = _get_aoe_cells(cell, selected_ability)
	executor.execute_ability(selected_unit, selected_ability, target_cells)
	selected_unit.has_acted = true
	
	# 🟢 ANIMATION HOOK: Safely restore idle poses once attacks complete
	if selected_unit.has_method("play_animation"):
		selected_unit.play_animation("idle")
	
	# Structural clearing routines
	selected_ability = null
	aoe_preview_cell = Vector2i(-1, -1)
	highlight.clear_highlights()
	deselect_unit()
	
	current_phase = TurnPhase.PLAYER_TURN
	_check_end_player_turn()


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


# Loops through active party components checking for outstanding action tokens.
func _check_end_player_turn() -> void:
	var all_acted = true
	aoe_preview_cell = Vector2i(-1, -1)
	for unit in player_units:
		if not unit.has_acted:
			all_acted = false
			break
	if all_acted:
		end_player_turn()


# MATH ENGINE: Maps Area-Of-Effect shape distributions.
func _get_aoe_cells(center: Vector2i, ability: AbilityData) -> Array:
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
				var dir = center - origin
				
				var step = Vector2i(sign(dir.x), sign(dir.y))
				if step.x != 0 and step.y != 0:
					if abs(dir.x) >= abs(dir.y):
						step.y = 0
					else:
						step.x = 0
				
				if step == Vector2i.ZERO:
					step = Vector2i(1, 0)
				
				for i in range(1, size + 1):
					var c = origin + (step * i)
					if grid.is_valid_cell(c):
						cells.append(c)

		"cross":
			cells = [center]
			for i in range(1, size + 1):
				var directions = [
					center + Vector2i(i, 0),   
					center + Vector2i(-i, 0),  
					center + Vector2i(0, i),   
					center + Vector2i(0, -i)   
				]
				for c in directions:
					if grid.is_valid_cell(c) and not c in cells:
						cells.append(c)

		"cone":
			if selected_unit:
				var origin = selected_unit.grid_position
				var dir = center - origin
				
				var forward = Vector2i.ZERO
				var side = Vector2i.ZERO
				
				if abs(dir.x) >= abs(dir.y):
					forward = Vector2i(sign(dir.x), 0) 
					side = Vector2i(0, 1)              
				else:
					forward = Vector2i(0, sign(dir.y)) 
					side = Vector2i(1, 0)              
					
				if forward == Vector2i.ZERO:
					forward = Vector2i(1, 0) 
					side = Vector2i(0, 1)

				for i in range(1, size + 1):
					var row_center = origin + (forward * i)
					var width_spread = i - 1 
					
					for j in range(-width_spread, width_spread + 1):
						var c = row_center + (side * j)
						if grid.is_valid_cell(c):
							cells.append(c)

	return cells
	

# Handover sequence: Shuts down player commands, updates metrics, wakes up the AI.
func end_player_turn() -> void:
	current_phase = TurnPhase.ENEMY_TURN
	selected_ability = null
	if has_method("deselect_unit"):
		deselect_unit() 
	else:
		selected_unit = null
		reachable_cells = {}
	
	if highlight != null:
		highlight.clear_highlights()
		
	if ui_manager != null and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	elif ui_manager != null and ui_manager.has_node("VBoxContainer/AbilityBar"):
		for child in ui_manager.get_node("VBoxContainer/AbilityBar").get_children():
			child.queue_free()
			
	print("--- ENEMY TURN PHASE ACTIVATED ---")
	
	for unit in player_units:
		unit.tick_statuses_end_of_round("player")
		unit.has_moved = false 
		unit.has_acted = false 
		
	for unit in enemy_units:
		for key in unit.ability_cooldowns:
			unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)
			
	ai_system.run_enemy_turn(enemy_units, player_units, grid, pathfinder, executor, _on_enemy_turn_complete)


# Triggered automatically when AI operations wrap up their loops.
func _on_enemy_turn_complete() -> void:
	print("--- PLAYER TURN PHASE ACTIVATED ---")
	
	for unit in enemy_units:
		unit.tick_statuses_end_of_round("enemy")
		
	for unit in player_units:
		for key in unit.ability_cooldowns:
			unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)
			
	round_number += 1
	current_phase = TurnPhase.PLAYER_TURN
