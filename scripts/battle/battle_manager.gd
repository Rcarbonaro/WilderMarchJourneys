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
# 
# 🔴 IMPORTANT: If you get a "nil" crash on startup, it means one of these slots
# was not filled in the Inspector. Open BattleScene.tscn, click BattleManager in
# the scene tree, and check the Inspector on the right — every slot below must
# have a node dragged into it.
@export var grid: Node          # Points to BattleGrid (Handles positioning math)
@export var pathfinder: Node    # Points to PathfindingSystem (Calculates walk ranges)
@export var executor: Node      # Points to AbilityExecutor (Calculates damage hits)
@export var highlight: Node     # Points to HighlightManager (Paints green/red tiles)
@export var ai_system: Node     # Points to AISystem (Controls the enemy brain)
@export var ui_manager: Node    # Points to UIManager (Draws action hotbars)


# _ready() runs automatically the exact millisecond this node boots into the game.
func _ready() -> void:
	# ==============================================================================
	# NULL SAFETY CHECKS
	# ==============================================================================
	# Before we touch any exported node, we verify it was actually assigned in the
	# Inspector. If any slot is empty (null), we print a clear error message and
	# stop here, so you know exactly what is missing instead of getting a cryptic crash.
	
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
	# 'grid_ref' is a variable inside those scripts that they use to look up tile info.
	pathfinder.grid_ref = grid
	executor.grid_ref = grid
	
	# INITIALIZATION FLOW: Drop the characters onto the game board setup.
	_spawn_stage_enemies()
	_spawn_player_party_from_run()


# This handles reading your main menu choices and materializing your team.
func _spawn_player_party_from_run() -> void:
	# Safety Check: If the global RunManager has no run active, stop here to avoid a crash.
	if RunManager.current_run == null:
		print("⚠️ Notice: No active RunData found in RunManager. Skipping party spawn.")
		return

	# Extract the array list of player character resources stored by the main menu.
	var party: Array = RunManager.current_run.party
	
	# A list of safe coordinates on your grid where your team will physically land.
	var spawn_tiles = [
		Vector2i(1, 7), # Slot 1 coordinate
		Vector2i(2, 8), # Slot 2 coordinate
		Vector2i(1, 9)  # Slot 3 coordinate
	]
	
	# Loop over every hero data card found in your party array folder list.
	for i in range(party.size()):
		var unit_data: UnitData = party[i]
		
		# If you have more heroes than spawn tile markers, stop so we don't go out of bounds!
		if i >= spawn_tiles.size(): 
			break
			
		# Look up what level this hero is. If their ID isn't found, default to level 1.
		var level: int = RunManager.current_run.unit_levels.get(unit_data.id, 1)
		var target_tile: Vector2i = spawn_tiles[i]
		
		# Summon the unit onto the grid as a player character (is_player = true).
		spawn_unit(unit_data, target_tile, true, level)
		
		print("🛡️ Spawned player hero: ", unit_data.display_name, " at tile: ", target_tile)


# Automatically pulls enemy cards from your project asset folders and spawns them.
func _spawn_stage_enemies() -> void:
	var wolf_resource = "res://resources/enemies/wolf_data.tres"
	var wolf_data = load(wolf_resource)
	var goblin_resource = "res://resources/enemies/goblin_data.tres"
	var goblin_data = load(wolf_resource)
	
	if wolf_data != null:
		# Arguments: (data card, spawn coordinates, is_player = false, level)
		spawn_unit(wolf_data, Vector2i(7, 2), false, 1)
		spawn_unit(wolf_data, Vector2i(8, 3), false, 1)
		spawn_unit(goblin_data, Vector2i(8, 5), false, 1)
		print("🐺 A wild enemy has entered the battlefield!")
	else:
		printerr("❌ Could not load enemy data from path: ", wolf_resource)


# The master factory tool that instantiates character tokens out of blueprint files.
func spawn_unit(unit_data: UnitData, cell: Vector2i, is_player: bool, level: int = 1) -> void:
	# 1. Fetch your clean character token template scene file.
	var unit_scene = preload("res://scenes/battle/UnitNode.tscn")
	
	# 2. Instantiate makes a physical clone copy of that blueprint setup in system memory.
	var unit = unit_scene.instantiate()
	
	# 3. Drop it into the active UnitLayer node folder so it displays inside your viewport.
	grid.get_node("UnitLayer").add_child(unit)
	
	# 4. Connect references so the unit script can check tile metrics.
	unit.grid_ref = grid
	unit.setup(unit_data, level, is_player)
	
	# 5. Place it on its abstract grid coordinates and convert those to physical screen pixels.
	unit.grid_position = cell
	unit.position = grid.grid_to_world(cell)
	
	# 6. Inform the map grid that this tile coordinate is blocked because a unit is standing on it.
	grid.register_unit(unit, cell)
	
	# 7. Listen to the unit. If its health hits 0, trigger the _on_unit_died hook immediately.
	unit.unit_died.connect(_on_unit_died)

	# 8. Sort the character token into the appropriate referee folder list.
	if is_player:
		player_units.append(unit)
	else:
		enemy_units.append(unit)


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
	battle_ended.emit("victory") # Sends the victory notification out to listeners


func _battle_defeat() -> void:
	print("Defeat!")
	current_phase = TurnPhase.GAME_OVER
	battle_ended.emit("defeat") # Sends the defeat notification out to listeners


# ==============================================================================
# TWO-STEP MOVE-THEN-ACT SELECTION LOOPS
# ==============================================================================

# Input gate: Triggered when you tap a grid coordinate cell on your screen.
func on_tile_tapped(cell: Vector2i) -> void:
	# 🟥 DIAGNOSTIC 1: Did the click actually enter the script?
	print("🎯 Map Grid Tapped at coordinate: ", cell, " | Current Game Phase: ", current_phase)
	
	if current_phase != TurnPhase.PLAYER_TURN: 
		print("❌ Click Ignored: It is not currently the Player's turn phase!")
		return

	# STATE A: You haven't clicked a character yet.
	if selected_unit == null:
		var unit = grid.get_unit_at(cell)
		if unit != null:
			print("👤 Found Unit: ", unit.unit_data.display_name, " | Is Player Team: ", unit.is_player_unit)
			if unit.is_player_unit:
				select_unit(unit)
		else:
			print("🟫 Tapped an empty floor tile with no unit selected.")
			
	# STATE B: Targeting/Casting state
	elif selected_ability != null:
		print("🔮 Casting Ability: ", selected_ability.display_name, " on tile: ", cell)
		_try_use_ability(cell)
		
	# STATE C: Unit selected, waiting for movement instructions
	else:
		print("🧍 Active Hero ", selected_unit.unit_data.display_name, " is waiting for movement. Tapped tile: ", cell)
		if cell == selected_unit.grid_position:
			print("🧍 Unit chose to stand still.")
			selected_unit.has_moved = true
			highlight.clear_highlights()
			reachable_cells = {}
			if ui_manager != null and ui_manager.has_method("show_unit_abilities"):
				ui_manager.show_unit_abilities(selected_unit)
		elif reachable_cells.has(cell):
			print("🚶 Moving unit...")
			selected_unit.move_to(cell)
			selected_unit.has_moved = true
			highlight.clear_highlights()
			reachable_cells = {}
			if ui_manager != null and ui_manager.has_method("show_unit_abilities"):
				ui_manager.show_unit_abilities(selected_unit)
		else:
			print("↩️ Invalid tile path choice. Resetting selection.")
			deselect_unit()


# Step 1: Activates the hero and shows their movement range.
func select_unit(unit) -> void:
	selected_unit = unit
	selected_ability = null
	
	# If the unit already moved this turn, skip straight to showing abilities.
	if unit.has_moved:
		if ui_manager != null and ui_manager.has_method("show_unit_abilities"):
			ui_manager.show_unit_abilities(unit)
		return

	# Read this unit's movement range from their data resource.
	var movement_range: int = 0
	if "unit_data" in unit and unit.unit_data != null:
		var data = unit.unit_data
		if data.base_stats != null and "mov" in data.base_stats:
			movement_range = data.base_stats.mov

	# Safety fallback: if for any reason mov is 0 or unset, default to 3 so the unit isn't frozen.
	if movement_range <= 0:
		movement_range = 3

	print("🚶 Calculating pathfinding grid weights for distance: ", movement_range)

	# ==============================================================================
	# 🔧 MOVEMENT FIX: Pass the moving unit into get_reachable_cells.
	# ==============================================================================
	# Previously, the pathfinder couldn't find any tiles because it uses
	# grid.is_passable() to check neighbors, and is_passable() returns FALSE
	# for any tile that has a unit on it — including the unit's OWN starting tile.
	# That means the pathfinder blocked itself at the very first step and returned
	# no reachable tiles. Passing 'unit' in lets the pathfinder skip over just that
	# one unit when doing the occupancy check.
	reachable_cells = pathfinder.get_reachable_cells(unit.grid_position, movement_range, unit)
	
	# Paint the overlay tiles green on your game board view
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
	
	# Fetch all raw coordinate cells within the min/max range criteria circles.
	var in_range = pathfinder.get_cells_in_range(
		selected_unit.grid_position, ability.min_range, ability.max_range
	)
	
	# Filter targets using Line-Of-Sight raycast requirements.
	var valid_targets = []
	for cell in in_range:
		if ability.requires_line_of_sight:
			if pathfinder.has_line_of_sight(selected_unit.grid_position, cell):
				valid_targets.append(cell)
		else:
			valid_targets.append(cell)
			
	# Tell the layout overlay tool to paint attack ranges bright red.
	highlight.show_attack_range(valid_targets)


# Fires damage and cost updates.
# res://scripts/battle/battle_manager.gd

func _try_use_ability(cell: Vector2i) -> void:
	if selected_unit == null or selected_ability == null: 
		return
		
	# 1. Recalculate the valid cast range cells from the unit's position
	var valid_target_cells: Array = pathfinder.get_cells_in_range(
		selected_unit.grid_position, 
		selected_ability.min_range, 
		selected_ability.max_range
	)
	
	# THE CRITICAL RANGE CHECK: Is the clicked tile actually within cast range?
	if not cell in valid_target_cells:
		print("❌ ATTACK FAILED: Target tile ", cell, " is out of range.")
		# Reset preview if they click completely outside the cast range
		aoe_preview_cell = Vector2i(-1, -1)
		_refresh_ability_highlights(valid_target_cells)
		return 

	# 2. Line of Sight Check
	if selected_ability.requires_line_of_sight:
		if not pathfinder.has_line_of_sight(selected_unit.grid_position, cell):
			print("❌ ATTACK FAILED: Line of sight is blocked to tile ", cell)
			return

	# 🟩 NEW TWO-STEP CONFIRMATION LOGIC FOR AOE
	# Check if this ability hits multiple tiles (is not single target)
	var is_aoe = selected_ability.has_method("get_aoe_type") or selected_ability.max_range > 0 # adjust to your data format
	# A simple check: if the shape returns more than 1 cell, it's an AOE
	var simulated_cells = _get_aoe_cells(cell, selected_ability)
	
	if simulated_cells.size() > 1:
		# If they haven't clicked this specific tile yet to preview it:
		if aoe_preview_cell != cell:
			aoe_preview_cell = cell
			print("🎯 Previewing AOE shape centered at: ", cell)
			
			# Redraw the grid: keep cast range visual, but layer the AOE preview on top
			_draw_aoe_preview(valid_target_cells, simulated_cells)
			return # STOP HERE! Do not execute yet. Wait for confirmation click.

	# 3. CONFIRMED! If it passes preview (or is single target), proceed with execution
	print("⚔️ Confirmed! Executing ability: ", selected_ability.display_name, " on target cell: ", cell)
	
	var target_cells = _get_aoe_cells(cell, selected_ability)
	executor.execute_ability(selected_unit, selected_ability, target_cells)
	selected_unit.has_acted = true
	
	# 🧹 Clean up targeting states
	selected_ability = null
	aoe_preview_cell = Vector2i(-1, -1)
	highlight.clear_highlights()
	deselect_unit()
	
	_check_end_player_turn()


func _draw_aoe_preview(cast_range_cells: Array, aoe_impact_cells: Array) -> void:
	if highlight == null:
		return
		
	highlight.clear_highlights()
	
	# 1. 🟢 CHANGED: Use show_attack_range instead of highlight_ability_cells
	highlight.show_attack_range(cast_range_cells)
	
	# 2. Overlay our orange blast shapes directly on top
	highlight.highlight_aoe_blast_cells(aoe_impact_cells)


# res://scripts/battle/battle_manager.gd

func _refresh_ability_highlights(valid_cells: Array) -> void:
	if highlight != null:
		highlight.clear_highlights()
		# 🟢 CHANGED: Use show_attack_range instead of highlight_ability_cells
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
			cells = [center] # Only damages the exact tile center coordinate tapped.

		"square":
			# Nested loops drawing an outward boundary grid box layout.
			for x in range(-size + 1, size):
				for y in range(-size + 1, size):
					var c = center + Vector2i(x, y)
					if grid.is_valid_cell(c):
						cells.append(c)

		"line":
			# 🟢 UPDATED: Line now originates directly from the casting unit
			if selected_unit:
				var origin = selected_unit.grid_position
				var dir = center - origin
				
				# Get a clean grid step direction (1, 0), (-1, 0), etc.
				var step = Vector2i(sign(dir.x), sign(dir.y))
				if step.x != 0 and step.y != 0:
					# Flatten diagonals to cardinal axes for strict straight lines
					if abs(dir.x) >= abs(dir.y):
						step.y = 0
					else:
						step.x = 0
				
				# If the click is exactly on the caster, default facing right
				if step == Vector2i.ZERO:
					step = Vector2i(1, 0)
				
				# Trace the laser/projectile outward step-by-step from the caster
				for i in range(1, size + 1):
					var c = origin + (step * i)
					if grid.is_valid_cell(c):
						cells.append(c)

		"cross":
			# Targets a plus '+' compass shape around the epicenter.
			cells = [center]
			for i in range(1, size + 1):
				var directions = [
					center + Vector2i(i, 0),   # Right arm
					center + Vector2i(-i, 0),  # Left arm
					center + Vector2i(0, i),   # Down arm
					center + Vector2i(0, -i)   # Up arm
				]
				for c in directions:
					if grid.is_valid_cell(c) and not c in cells:
						cells.append(c)

		"cone":
			# 🟢 NEW: Standard grid-based cone projecting from the caster toward the target
			if selected_unit:
				var origin = selected_unit.grid_position
				var dir = center - origin
				
				# Identify primary direction of fire (Cardinal axis)
				var forward = Vector2i.ZERO
				var side = Vector2i.ZERO
				
				if abs(dir.x) >= abs(dir.y):
					forward = Vector2i(sign(dir.x), 0) # Shooting horizontally
					side = Vector2i(0, 1)              # Width expands vertically
				else:
					forward = Vector2i(0, sign(dir.y)) # Shooting vertically
					side = Vector2i(1, 0)              # Width expands horizontally
					
				if forward == Vector2i.ZERO:
					forward = Vector2i(1, 0) # Fallback facing right
					side = Vector2i(0, 1)

				# Row-by-row cone expansion outward
				# Row 1 is 1 tile wide, Row 2 is 3 tiles wide, Row i is (2*i - 1) wide
				for i in range(1, size + 1):
					var row_center = origin + (forward * i)
					var width_spread = i - 1 # Extends outward sideways by this many tiles on each side
					
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
		deselect_unit() # This usually sets selected_unit = null and clears movement fields
	else:
		selected_unit = null
		reachable_cells = {}
	
	# Force the grid highlights to completely vanish so no red/blue tiles remain
	if highlight != null:
		highlight.clear_highlights()
		
	# Clear the UI buttons so they don't linger into the enemy turn
	if ui_manager != null and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	elif ui_manager != null and ui_manager.has_node("VBoxContainer/AbilityBar"):
		for child in ui_manager.get_node("VBoxContainer/AbilityBar").get_children():
			child.queue_free()
			
	print("--- ENEMY TURN PHASE ACTIVATED ---")
	
	# 1. Process damage status tickers (poison, burn, bleed values) lingering on your heroes.
	for unit in player_units:
		unit.tick_statuses_end_of_round("player")
		unit.has_moved = false # Refresh movement permissions for next round
		unit.has_acted = false # Refresh action permissions for next round
		
	# 2. Tick down cooldown timers tracking on enemy action structures.
	for unit in enemy_units:
		for key in unit.ability_cooldowns:
			unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)
			
	# 3. Fire up the automated enemy state loops. We pass a callback hook link 
	# (_on_enemy_turn_complete) so the AI script can return turn authority to us when done.
	ai_system.run_enemy_turn(enemy_units, player_units, grid, pathfinder, executor, _on_enemy_turn_complete)


# Triggered automatically when AI operations wrap up their loops.
func _on_enemy_turn_complete() -> void:
	print("--- PLAYER TURN PHASE ACTIVATED ---")
	
	# 1. Process damage status tickers lingering on enemy units.
	for unit in enemy_units:
		unit.tick_statuses_end_of_round("enemy")
		
	# 2. Lower active cooldown counter values tracking on your hero hotbar buttons.
	for unit in player_units:
		for key in unit.ability_cooldowns:
			unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)
			
	# 3. Increment the turn index layout tracker and hand controls back to the player.
	round_number += 1
	current_phase = TurnPhase.PLAYER_TURN
