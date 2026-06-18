# res://scripts/battle/battle_manager.gd
# ==============================================================================
# THE BATTLE MANAGER (The Combat Coordinator / Referee)
# ==============================================================================
# This script is the "rule book" for combat. It does NOT draw anything and does
# NOT directly accept player input. Instead it:
#   - Tracks whose turn it is (player or enemy)
#   - Maintains lists of living units on each side
#   - Tells the UI what to display
#   - Tells the AI when to take over
#   - Tells the AbilityExecutor to resolve ability effects
#
# AURA ADDITIONS:
#   - Finds and wires AuraManager from BattleGrid on startup
#   - Notifies AuraManager when any unit (player or enemy) finishes moving
#   - Ticks auras at end of player round before the enemy turn starts
#   - Clears all aura state at the start of each battle

extends Node

signal battle_ended(result: String)
# Fires when combat ends. battle_scene.gd listens and transitions to the next screen.

# ── TURN PHASE ENUM ───────────────────────────────────────────────────────────
# An enum is a named list of states. Instead of raw strings or numbers,
# we use readable names that the compiler can check for typos.

enum TurnPhase {
	PLAYER_TURN,   # Player is choosing actions.
	ENEMY_TURN,    # AI is running.
	ANIMATION,     # An animation is playing — block all input until it finishes.
	POST_ATTACK,   # Waiting for the player to pick a tile for post-attack movement.
	GAME_OVER      # Combat is finished — no more input accepted.
}

# ── STATE VARIABLES ───────────────────────────────────────────────────────────

var current_phase: TurnPhase = TurnPhase.PLAYER_TURN
var round_number: int = 1
var is_battle_over: bool = false
var aoe_preview_cell: Vector2i = Vector2i(-1, -1)
# Tracks which cell was last previewed for AOE so we can confirm on the second tap.

var player_units: Array = []   # All living player-side units.
var enemy_units:  Array = []   # All living enemy-side units.

var selected_unit    = null                # The unit the player most recently tapped.
var selected_ability: AbilityData = null   # The ability button the player pressed.
var reachable_cells: Dictionary = {}       # Tiles the selected unit can walk to this turn.

# Spellsword arcana charge accumulator.
var total_mana_spent: int = 0
const ARCANA_THRESHOLD: int = 75

# ── INSPECTOR LINKS ───────────────────────────────────────────────────────────
# Drag each scene node into these slots in the Inspector.
# BattleScene._ready() also sets ui_manager programmatically.

@export var grid:           Node   # BattleGrid — the game board
@export var pathfinder:     Node   # PathfindingSystem
@export var executor:       Node   # AbilityExecutor
@export var highlight:      Node   # HighlightManager
@export var ai_system:      Node   # AISystem
@export var ui_manager:     Node   # UIManager (BattleUI CanvasLayer)
@export var synergy_system: Node   # SynergySystem (can be null if not added yet)

# ── AURA MANAGER REFERENCE ────────────────────────────────────────────────────
# NOT an export — we find and wire it automatically in _ready() by searching
# for the "AuraManager" child node inside BattleGrid.

var aura_manager: Node = null
# All calls to aura_manager are guarded with "if aura_manager != null" so the
# game won't crash if you forget to add the node to the scene tree.

# ── STARTUP ───────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Null-safety first: print a clear error rather than crashing with a vague message.
	if grid == null:
		printerr("❌ BattleManager: 'grid' export slot is empty! Drag BattleGrid in.")
		return
	if pathfinder == null:
		printerr("❌ BattleManager: 'pathfinder' export slot is empty!")
		return
	if executor == null:
		printerr("❌ BattleManager: 'executor' export slot is empty!")
		return

	# Give the pathfinder and executor a reference to the grid so they can look
	# up unit positions, check tile passability, and access effect maps.
	pathfinder.grid_ref = grid
	executor.grid_ref   = grid

	# ── WIRE THE AURA MANAGER ─────────────────────────────────────────────────
	# AuraManager must be a child Node of BattleGrid in the scene tree, with
	# aura_manager.gd attached as its script. AuraLayer must also be a child
	# Node2D of BattleGrid, positioned between GroundLayer and HazardLayer.
	if grid.has_node("AuraManager"):
		aura_manager = grid.get_node("AuraManager")

		if grid.has_node("AuraLayer"):
			# setup() gives AuraManager the grid reference and the visual layer
			# node where it will draw ColorRects, sprites, or scene instances.
			aura_manager.setup(grid, grid.get_node("AuraLayer"))
		else:
			printerr("⚠️ BattleManager: 'AuraLayer' node not found on BattleGrid! ",
					 "Add a Node2D named 'AuraLayer' between GroundLayer and HazardLayer.")

		# Give the executor a reference so it can fire Crit Overload and
		# Momentum events when crits and kills happen during abilities.
		executor.aura_manager = aura_manager

		# Wipe any leftover state from a previous battle (safety measure in case
		# the scene is reused without a full reload).
		aura_manager.clear_all()
		print("✅ AuraManager wired and ready.")
	else:
		printerr("⚠️ BattleManager: 'AuraManager' node not found on BattleGrid! ",
				 "Add a Node (aura_manager.gd script) named 'AuraManager' as a child of BattleGrid.")

	_spawn_stage_enemies()
	_spawn_player_party_from_run()

	# Apply synergy bonuses that are active from the very start of battle.
	_refresh_synergies()


func _spawn_player_party_from_run() -> void:
	print("🧙 Spawning Player Party Units...")
	var windmage_data      = load("res://resources/units/windmage_data.tres")
	var hexweaver_data     = load("res://resources/units/hexweaver_data.tres")
	var guardian_data      = load("res://resources/units/guardian_data.tres")
	var dragoon_data       = load("res://resources/units/dragoon_data.tres")
	var executioner_data   = load("res://resources/units/executioner_data.tres")
	var spellsword_data    = load("res://resources/units/spellsword_data.tres")
	var stonewarden_data   = load("res://resources/units/stonewarden_data.tres")
	var plaguebringer_data = load("res://resources/units/plaguebringer_data.tres")
	var divinator_data     = load("res://resources/units/divinator_data.tres")
	var rogue_data         = load("res://resources/units/rogue_data.tres")
	var dreadknight_data         = load("res://resources/units/dreadknight_data.tres")


	if windmage_data      != null: spawn_unit(windmage_data,      Vector2i(1, 7), true, 1)
	else: printerr("❌ Could not load windmage_data.tres!")
	if hexweaver_data     != null: spawn_unit(hexweaver_data,     Vector2i(2, 6), true, 1)
	else: printerr("❌ Could not load hexweaver_data.tres!")
	if guardian_data      != null: spawn_unit(guardian_data,      Vector2i(2, 8), true, 1)
	else: printerr("❌ Could not load guardian_data.tres!")
	if dragoon_data       != null: spawn_unit(dragoon_data,       Vector2i(3, 6), true, 1)
	else: printerr("❌ Could not load dragoon_data.tres!")
	if spellsword_data    != null: spawn_unit(spellsword_data,    Vector2i(1, 5), true, 1)
	else: printerr("❌ Could not load spellsword_data.tres!")
	if executioner_data   != null: spawn_unit(executioner_data,   Vector2i(1, 6), true, 1)
	else: printerr("❌ Could not load executioner_data.tres!")
	if stonewarden_data   != null: spawn_unit(stonewarden_data,   Vector2i(4, 5), true, 1)
	else: printerr("❌ Could not load stonewarden_data.tres!")
	if plaguebringer_data != null: spawn_unit(plaguebringer_data, Vector2i(2, 5), true, 1)
	else: printerr("❌ Could not load plaguebringer_data.tres!")
	if divinator_data     != null: spawn_unit(divinator_data,     Vector2i(3, 5), true, 1)
	else: printerr("❌ Could not load divinator_data.tres!")
	if rogue_data         != null: spawn_unit(rogue_data,         Vector2i(4, 4), true, 1)
	else: printerr("❌ Could not load rogue_data.tres!")
	if dreadknight_data         != null: spawn_unit(dreadknight_data,         Vector2i(4, 3), true, 1)
	else: printerr("❌ Could not load dreadknight_data.tres!")




func _spawn_stage_enemies() -> void:
	print("🐺 Spawning Monster Waves...")
	var wolf_data     = load("res://resources/enemies/wolf_data.tres")
	var sylvaris_data = load("res://resources/enemies/sylvaris_data.tres")
	var ent_data      = load("res://resources/enemies/ent_data.tres")

	if wolf_data == null:
		printerr("❌ Could not load wolf_data.tres!")
		return

	spawn_unit(wolf_data,     Vector2i(10, 1), false, 1)
	spawn_unit(wolf_data,     Vector2i(10, 2), false, 1)
	spawn_unit(wolf_data,     Vector2i(12, 2), false, 1)
	spawn_unit(wolf_data,     Vector2i(10, 3), false, 1)
	if sylvaris_data != null: spawn_unit(sylvaris_data, Vector2i(13, 3), false, 1)
	if sylvaris_data != null: spawn_unit(sylvaris_data, Vector2i(15, 2), false, 1)
	if ent_data      != null: spawn_unit(ent_data,      Vector2i(18, 8), false, 1)

	print("🐺 Monster waves deployed!")


func spawn_unit(unit_data: UnitData, cell: Vector2i, is_player: bool, level: int = 1) -> void:
	# Instantiates a unit scene, places it on the grid, and registers it.
	# Also handles large units (2×2 etc.) by reading tile_footprint from unit_data.

	var folder_name := unit_data.display_name.to_lower().replace(" ", "")
	var scene_path  := "res://scenes/animations/%s/%s.tscn" % [folder_name, folder_name]

	if not ResourceLoader.exists(scene_path):
		printerr("❌ Scene not found: ", scene_path)
		return

	var unit = load(scene_path).instantiate()
	grid.get_node("UnitLayer").add_child(unit)

	# Every unit node needs a grid reference so it can look up neighbours,
	# check passability, and unregister itself on death.
	unit.grid_ref = grid
	unit.setup(unit_data, level, is_player)

	# If the unit_data resource defines a multi-tile footprint, copy it to
	# the live node so the grid knows all the cells it occupies.
	if "tile_footprint" in unit_data and unit_data.tile_footprint.size() > 1:
		unit.tile_footprint = unit_data.tile_footprint

	unit.grid_position = cell
	unit.position      = grid.grid_to_world(cell)

	# Register all occupied cells in the grid's lookup dictionary.
	if unit.tile_footprint.size() > 1:
		unit._update_occupied_cells()
		grid.register_large_unit(unit, unit.occupied_cells)
	else:
		unit._update_occupied_cells()
		grid.register_unit(unit, cell)

	# Listen for this unit's death signal so we can update team lists.
	unit.unit_died.connect(_on_unit_died)

	if is_player:
		player_units.append(unit)
		print("🛡️ Ally spawned: ", unit_data.display_name)
	else:
		enemy_units.append(unit)
		print("⚔️ Enemy spawned: ", unit_data.display_name)

# ── DEATH HANDLING ────────────────────────────────────────────────────────────

func _on_unit_died(unit) -> void:
	# Connected to every unit's unit_died signal in spawn_unit.
	# Note: AuraManager.remove_all_auras_for() is called INSIDE unit_node.die()
	# BEFORE this signal fires, so momentum bonuses are already stripped by now.
	print(unit.unit_data.display_name, " has fallen!")
	player_units.erase(unit)
	enemy_units.erase(unit)

	# If the dead unit was selected, clean up the selection state.
	if selected_unit == unit:
		deselect_unit()

	_check_battle_end()


func _check_battle_end() -> void:
	# The battle ends when one side runs out of units.
	if enemy_units.is_empty():
		_battle_victory()
	elif player_units.is_empty():
		_battle_defeat()


func _battle_victory() -> void:
	print("🏆 Victory!")
	current_phase  = TurnPhase.GAME_OVER
	is_battle_over = true
	battle_ended.emit("victory")


func _battle_defeat() -> void:
	print("💀 Defeat!")
	current_phase  = TurnPhase.GAME_OVER
	is_battle_over = true
	battle_ended.emit("defeat")

# ── INPUT ROUTING ─────────────────────────────────────────────────────────────

func on_tile_tapped(cell: Vector2i) -> void:
	# Main entry point for all grid taps. Called by input_handler.gd.
	print("🎯 Tile tapped: ", cell, " | Phase: ", current_phase)

	# ── POST-ATTACK MOVEMENT MODE ─────────────────────────────────────────────
	# If we are waiting for the player to choose a tile to step to after an
	# attack, route the tap to that handler and return immediately.
	if current_phase == TurnPhase.POST_ATTACK:
		_try_post_attack_move(cell)
		return

	if current_phase != TurnPhase.PLAYER_TURN:
		print("❌ Input ignored — not player turn.")
		return

	# ── STATE A: Nothing selected → select a unit or show enemy info ──────────
	if selected_unit == null:
		var unit = grid.get_unit_at(cell)
		if is_instance_valid(unit):
			if unit.is_player_unit:
				select_unit(unit)
			else:
				# Tapped an enemy: show their info panel without selecting them.
				_show_unit_info(unit)
		else:
			print("🟫 Empty tile — nothing selected.")

	# ── STATE B: Ability selected → try to cast it on this tile ──────────────
	elif selected_ability != null:
		_try_use_ability(cell)

	# ── STATE C: Unit selected, waiting for move or re-tap ───────────────────
	else:
		if not is_instance_valid(selected_unit):
			deselect_unit()
			return

		# Tapping the unit's own tile: skip movement, show ability choices.
		if cell == selected_unit.grid_position:
			selected_unit.has_moved = true
			highlight.clear_highlights()
			reachable_cells = {}
			_show_abilities_for(selected_unit)

		# Tapping a reachable tile: move there.
		elif reachable_cells.has(cell):
			current_phase = TurnPhase.ANIMATION

			var moving_unit = selected_unit
			moving_unit.pre_move_position = moving_unit.grid_position

			highlight.clear_highlights()
			reachable_cells = {}

			# Apply any enter-tile hazard effect at the destination.
			grid.apply_hazard_to_unit(moving_unit, cell, "enter")

			moving_unit.move_to(cell)
			moving_unit.has_moved = true

			# Wait for the slide animation to finish before doing anything else.
			await moving_unit.movement_finished

			# ── NOTIFY AURA MANAGER AFTER PLAYER UNIT MOVES ───────────────────
			# Two possible cases:
			#   A) The moving unit OWNS an aura → shift the aura's cell coverage
			#      and visuals to follow them at their new position.
			#   B) The moving unit does NOT own an aura but stepped INTO one →
			#      apply any ally entry buffs (status effects) immediately so
			#      they take effect before this unit attacks on the same turn.
			if is_instance_valid(moving_unit) and aura_manager != null:
				if _unit_has_active_aura(moving_unit):
					aura_manager.on_caster_moved(moving_unit)
				else:
					aura_manager.on_unit_moved(moving_unit)

			if is_instance_valid(moving_unit):
				current_phase = TurnPhase.PLAYER_TURN
				moving_unit.can_cancel_move = true
				_show_abilities_for(moving_unit)
			else:
				current_phase = TurnPhase.PLAYER_TURN
				deselect_unit()

		# Tapping anywhere else: deselect.
		else:
			_return_selected_to_idle()
			deselect_unit()


func _show_unit_info(unit) -> void:
	# Shows the HP/Mana/buff panel for a unit without selecting them.
	if ui_manager and ui_manager.has_method("show_unit_info"):
		ui_manager.show_unit_info(unit)


func _show_abilities_for(unit) -> void:
	# Tells the UI to rebuild the ability button row for this unit.
	if ui_manager and ui_manager.has_method("show_unit_abilities"):
		ui_manager.show_unit_abilities(unit)
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(unit.can_cancel_move and not unit.has_acted)

# ── CANCEL MOVE ───────────────────────────────────────────────────────────────

func cancel_unit_move() -> void:
	# Called when the player presses "Cancel Move".
	# Teleports the selected unit back to their pre-move position.
	if selected_unit == null or not is_instance_valid(selected_unit):
		return
	if not selected_unit.can_cancel_move:
		return

	var unit   = selected_unit
	var origin = unit.pre_move_position
	if origin == Vector2i(-1, -1):
		return

	print("↩️ ", unit.unit_data.display_name, " cancels their move. Returning to ", origin)

	# snap_to instantly teleports (no tween) and updates the grid registry.
	unit.snap_to(origin)
	unit.has_moved         = false
	unit.can_cancel_move   = false
	unit.pre_move_position = Vector2i(-1, -1)
	unit.play_animation("idle")

	# If this unit is an aura caster, snap the aura visuals back too.
	if aura_manager != null and _unit_has_active_aura(unit):
		aura_manager.on_caster_moved(unit)

	if ui_manager and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(false)

	select_unit(unit)

# ── UNIT SELECTION ────────────────────────────────────────────────────────────

func select_unit(unit) -> void:
	selected_unit    = unit
	selected_ability = null

	_show_unit_info(unit)

	# If the unit already moved this turn, skip straight to ability selection.
	if unit.has_moved:
		_show_abilities_for(unit)
		return

	var movement_range: int = 3
	if unit.has_method("get_effective_mov"):
		movement_range = unit.get_effective_mov()

	reachable_cells = pathfinder.get_reachable_cells(unit.grid_position, movement_range, unit)
	highlight.show_movement(reachable_cells.keys())


func deselect_unit() -> void:
	selected_unit    = null
	selected_ability = null
	reachable_cells  = {}
	highlight.clear_highlights()
	aoe_preview_cell = Vector2i(-1, -1)

	if ui_manager and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(false)
	if ui_manager and ui_manager.has_method("hide_unit_info"):
		ui_manager.hide_unit_info()

# ── ABILITY SELECTION ─────────────────────────────────────────────────────────

func on_ability_selected(ability: AbilityData) -> void:
	if selected_unit == null:
		return

	# ── MANA GATE ─────────────────────────────────────────────────────────────
	# Check affordability before showing targeting highlights.
	# Spellswords with an Arcana Charge bypass the mana check entirely.
	var is_spellsword: bool = "is_spellsword" in selected_unit and selected_unit.is_spellsword
	var can_bypass: bool    = is_spellsword and selected_unit.has_arcana_charge

	if not can_bypass and not selected_unit.can_afford_ability(ability):
		print("⛔ ", selected_unit.unit_data.display_name, " cannot afford '",
			  ability.display_name, "'")
		if ui_manager and ui_manager.has_method("show_insufficient_mana_popup"):
			ui_manager.show_insufficient_mana_popup()
		return

	selected_ability = ability

	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(
			is_instance_valid(selected_unit) and selected_unit.can_cancel_move
		)

	# Calculate and highlight the valid target tiles for this ability.
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

# ── ABILITY EXECUTION ─────────────────────────────────────────────────────────

func _try_use_ability(cell: Vector2i) -> void:
	if selected_unit == null or selected_ability == null:
		return

	# 1. Range check — is the tapped cell within the ability's targeting range?
	var valid_target_cells = pathfinder.get_cells_in_range(
		selected_unit.grid_position,
		selected_ability.min_range,
		selected_ability.max_range
	)
	if not cell in valid_target_cells:
		aoe_preview_cell = Vector2i(-1, -1)
		_refresh_ability_highlights(valid_target_cells)
		return

	# 2. Line of sight check.
	if selected_ability.requires_line_of_sight:
		if not pathfinder.has_line_of_sight(selected_unit.grid_position, cell):
			print("❌ Line of sight blocked.")
			return

	# 3. AOE double-tap preview.
	# First tap on an AOE ability shows the blast zone overlay and returns.
	# Second tap on the same cell confirms and executes.
	var simulated_cells = _get_aoe_cells(cell, selected_ability)
	if selected_ability.aoe_shape != "single":
		if aoe_preview_cell != cell:
			aoe_preview_cell = cell
			if selected_unit.has_method("play_animation"):
				selected_unit.play_animation("charging")
			_draw_aoe_preview(valid_target_cells, simulated_cells)
			return
		# Second tap on the same cell — fall through to execute.

	# 4. Execute the ability.
	current_phase = TurnPhase.ANIMATION

	selected_unit.look_at_target(cell)
	var dy = cell.y - selected_unit.grid_position.y
	if dy < -1:  selected_unit.play_animation("attack_up")
	elif dy > 1: selected_unit.play_animation("attack_down")
	else:        selected_unit.play_animation("attack")

	await get_tree().create_timer(0.5).timeout

	# Filter out cells belonging to the wrong team before passing to the executor.
	var filtered_cells = _filter_cells_by_team(simulated_cells, selected_ability, selected_unit)

	print("DEBUG: Current Total Mana Spent: ", total_mana_spent, " / Threshold: ", ARCANA_THRESHOLD)

	# execute_ability uses 'await' for VFX, so we await it here too.
	await executor.execute_ability(selected_unit, selected_ability, filtered_cells, cell)

	# ── ARCANA CHARGE TRACKING ────────────────────────────────────────────────
	# Every mana point spent by ANY player unit counts toward the pool.
	# When the pool hits the threshold, the Spellsword gets a free charge.
	if is_instance_valid(selected_unit):
		total_mana_spent += selected_ability.mana_cost
		print("DEBUG: Spent ", selected_ability.mana_cost, " mana. Total: ", total_mana_spent)

		if total_mana_spent >= ARCANA_THRESHOLD:
			total_mana_spent -= ARCANA_THRESHOLD
			_grant_arcana_charge_to_spellsword()

	if not is_instance_valid(selected_unit):
		current_phase = TurnPhase.PLAYER_TURN
		deselect_unit()
		return

	selected_unit.has_acted       = true
	selected_unit.can_cancel_move = false

	if selected_unit.has_method("play_animation"):
		selected_unit.play_animation("idle")

	# ── POST-ATTACK MOVEMENT ──────────────────────────────────────────────────
	# Some abilities grant the caster extra movement squares after attacking.
	# If the flag is set, enter POST_ATTACK mode so the next tap moves the unit.
	if selected_unit.pending_post_attack_moves > 0:
		_start_post_attack_movement(selected_unit)
		return

	# Normal cleanup after the ability fully resolves.
	_finish_ability(selected_unit)


func _finish_ability(unit) -> void:
	# Called after an ability fully resolves, including any post-attack movement.
	selected_ability = null
	aoe_preview_cell = Vector2i(-1, -1)
	highlight.clear_highlights()
	deselect_unit()
	current_phase = TurnPhase.PLAYER_TURN
	_check_end_player_turn()


func _start_post_attack_movement(unit) -> void:
	# Shows movement tiles for extra squares granted after an attack.
	print("🏃 Post-attack movement: ", unit.pending_post_attack_moves, " squares")
	current_phase = TurnPhase.POST_ATTACK

	var extra_moves = unit.pending_post_attack_moves
	unit.pending_post_attack_moves = 0   # Clear immediately so it doesn't repeat.

	var post_move_cells: Dictionary = pathfinder.get_reachable_cells(
		unit.grid_position, extra_moves, unit
	)
	highlight.show_movement(post_move_cells.keys())
	reachable_cells = post_move_cells


func _try_post_attack_move(cell: Vector2i) -> void:
	# Called from on_tile_tapped when current_phase == POST_ATTACK.
	if not is_instance_valid(selected_unit):
		current_phase = TurnPhase.PLAYER_TURN
		deselect_unit()
		return

	if reachable_cells.has(cell):
		current_phase = TurnPhase.ANIMATION
		selected_unit.move_to(cell)
		await selected_unit.movement_finished

		# Shift the aura with the unit after their post-attack step too.
		if is_instance_valid(selected_unit) and aura_manager != null:
			if _unit_has_active_aura(selected_unit):
				aura_manager.on_caster_moved(selected_unit)
			else:
				aura_manager.on_unit_moved(selected_unit)

	# Whether they moved or stayed put, finish the turn sequence.
	_finish_ability(selected_unit)

# ── TEAM FILTERING ────────────────────────────────────────────────────────────

func _filter_cells_by_team(cells: Array, ability: AbilityData, caster) -> Array:
	# Removes cells belonging to the wrong team for this ability.
	# "enemies" → keep cells with opposing-team units (or empty cells for hazards).
	# "allies"  → keep cells with same-team units.
	# "all"     → keep everything.
	var result = []
	for cell in cells:
		var unit_on_cell = grid.get_unit_at(cell)
		if unit_on_cell == null:
			result.append(cell)   # Empty cells always pass through (for hazard placement etc.)
			continue
		match ability.affects_team:
			"enemies":
				if unit_on_cell.is_player_unit != caster.is_player_unit:
					result.append(cell)
			"allies":
				if unit_on_cell.is_player_unit == caster.is_player_unit:
					result.append(cell)
			"all":
				result.append(cell)
	return result

# ── END OF PLAYER TURN ────────────────────────────────────────────────────────

func end_player_turn() -> void:
	# Called by the "End Turn" button, or automatically when all units have acted.
	_return_selected_to_idle()
	current_phase    = TurnPhase.ENEMY_TURN
	selected_ability = null
	deselect_unit()

	if highlight != null: highlight.clear_highlights()
	if ui_manager and ui_manager.has_method("clear_abilities"):
		ui_manager.clear_abilities()
	if ui_manager and ui_manager.has_method("set_cancel_move_visible"):
		ui_manager.set_cancel_move_visible(false)

	print("--- ENEMY TURN (Round ", round_number, ") ---")

	# ── TICK AURAS (end of player round) ──────────────────────────────────────
	# This applies aura damage and status effects to all enemies currently inside
	# any active aura zone. It also counts down aura durations and removes any
	# that have expired. This runs BEFORE hazard ticking so the order each round is:
	#   1. Aura end-of-round effects (damage + statuses on targets in range)
	#   2. Hazard duration countdown (grid.tick_all_effects)
	#   3. Enemy start-of-turn hazard damage
	if aura_manager != null:
		aura_manager.tick_auras_end_of_player_round(player_units, enemy_units)

	# ── TICK HAZARDS ──────────────────────────────────────────────────────────
	# Counts down all hazard durations once per round and removes expired ones.
	grid.tick_all_effects()

	# ── APPLY HAZARD DAMAGE AT START OF EACH ENEMY TURN ──────────────────────
	# Every enemy unit standing on a hazard tile at the start of the enemy turn
	# takes damage from that hazard.
	for unit in enemy_units:
		if is_instance_valid(unit):
			grid.apply_hazard_to_unit(unit, unit.grid_position, "start_of_turn")

	# ── TICK PLAYER STATUSES AND RESET TURN FLAGS ─────────────────────────────
	# Count down player status durations and reset movement/action flags so
	# every player unit can act again on the next player turn.
	for unit in player_units:
		if is_instance_valid(unit):
			unit.tick_statuses_end_of_round("player")
			unit.has_moved       = false
			unit.has_acted       = false
			unit.can_cancel_move = false

	# Count down enemy ability cooldowns so they become available again over time.
	for unit in enemy_units:
		if is_instance_valid(unit):
			for key in unit.ability_cooldowns:
				unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)

	# Hand control to the AI system. It will call _on_enemy_turn_complete when done.
	ai_system.run_enemy_turn(
		enemy_units, player_units, grid, pathfinder, executor,
		_on_enemy_turn_complete
	)


func _on_enemy_turn_complete() -> void:
	print("--- PLAYER TURN (Round ", round_number + 1, ") ---")

	# Apply start-of-turn hazard damage to player units.
	for unit in player_units:
		if is_instance_valid(unit):
			grid.apply_hazard_to_unit(unit, unit.grid_position, "start_of_turn")

	# Reset enemy turn flags and count down their cooldowns.
	for unit in enemy_units:
		if is_instance_valid(unit):
			unit.tick_statuses_end_of_round("enemy")
			unit.has_moved       = false
			unit.has_acted       = false
			unit.can_cancel_move = false
			for key in unit.ability_cooldowns:
				unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)

	# Count down player cooldowns too.
	for unit in player_units:
		if is_instance_valid(unit):
			for key in unit.ability_cooldowns:
				unit.ability_cooldowns[key] = max(0, unit.ability_cooldowns[key] - 1)

	round_number  += 1
	current_phase  = TurnPhase.PLAYER_TURN

	# Re-apply synergy bonuses at the start of each new player round.
	_refresh_synergies()

	# Refresh the ability bar if a unit is still selected from the previous turn.
	if selected_unit != null and is_instance_valid(selected_unit):
		_show_abilities_for(selected_unit)


func _check_end_player_turn() -> void:
	# Automatically ends the player turn once every unit has acted.
	aoe_preview_cell = Vector2i(-1, -1)
	for unit in player_units:
		if is_instance_valid(unit) and not unit.has_acted:
			return   # At least one unit still hasn't acted — keep waiting.
	end_player_turn()


func _return_selected_to_idle() -> void:
	if selected_unit != null and is_instance_valid(selected_unit):
		if not selected_unit.has_acted:
			selected_unit.play_animation("idle")

# ── SYNERGY REFRESH ───────────────────────────────────────────────────────────

func _refresh_synergies() -> void:
	# Asks the SynergySystem to re-scan the player team and re-apply tag-based
	# passive bonuses. Safe to call even if synergy_system is null.
	if synergy_system != null and synergy_system.has_method("apply_synergies"):
		synergy_system.apply_synergies(player_units)

# ── AURA HELPERS ──────────────────────────────────────────────────────────────

func _unit_has_active_aura(unit) -> bool:
	# Returns true if this unit is the caster of any MOVING aura (follows_caster=true).
	# Stationary auras (follows_caster=false) are excluded because there is nothing
	# to update when the caster moves — the zone stays where it was planted.
	if aura_manager == null:
		return false
	for entry in aura_manager._active_auras:
		if entry["caster"] == unit and entry["data"].follows_caster:
			return true
	return false

# ── AOE HELPERS ───────────────────────────────────────────────────────────────

func _draw_aoe_preview(cast_range_cells: Array, aoe_impact_cells: Array) -> void:
	if highlight == null: return
	highlight.clear_highlights()
	highlight.show_attack_range(cast_range_cells)
	highlight.highlight_aoe_blast_cells(aoe_impact_cells)


func _refresh_ability_highlights(valid_cells: Array) -> void:
	if highlight != null:
		highlight.clear_highlights()
		highlight.show_attack_range(valid_cells)


func _get_aoe_cells(center: Vector2i, ability: AbilityData) -> Array:
	# Returns every grid cell inside this ability's AOE pattern.
	var cells = []
	var size  = ability.aoe_size if "aoe_size" in ability else 1

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
					center + Vector2i(i,  0), center + Vector2i(-i, 0),
					center + Vector2i(0,  i), center + Vector2i(0, -i)
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
					var row_center   = origin + (forward * i)
					var width_spread = i - 1
					for j in range(-width_spread, width_spread + 1):
						var c = row_center + (side * j)
						if grid.is_valid_cell(c):
							cells.append(c)

	return cells

# ── SPELLSWORD ARCANA CHARGE ──────────────────────────────────────────────────

func _grant_arcana_charge_to_spellsword() -> void:
	print("DEBUG: Attempting to grant Arcana Charge...")
	for unit in player_units:
		if "is_spellsword" in unit and unit.is_spellsword:
			unit.has_arcana_charge = true
			print("DEBUG: Arcana Charge granted to: ", unit.unit_data.display_name)
			if unit.has_method("play_animation"):
				unit.play_animation("arcana_charge")
