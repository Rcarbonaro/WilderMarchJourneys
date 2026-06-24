# res://scripts/battle/pathfinding_system.gd
# ==============================================================================
# THE PATHFINDING SYSTEM (The Map Navigator)
# ==============================================================================
# This script figures out which tiles a unit can legally walk to, given their
# movement range and the obstacles on the map. It uses a technique called
# Breadth-First Search (BFS) — imagine dropping a stone in water and watching
# the ripples spread outward one ring at a time. Each ring costs more movement.
#
# NEW: _is_passable_for now also respects wall hazards (battle_grid's
# hazard_map entries with is_wall_hazard = true), filtered by the wall's
# wall_blocks team setting ("player", "enemies", or "all").
#
# NEW: get_reachable_cells() now also remembers HOW it reached every tile
# (which neighbor tile it stepped from), so we can retrace the exact
# tile-by-tile route afterwards with reconstruct_path_to(). This is what lets
# unit_node.gd's move_along_path() walk a unit smoothly through each tile of
# their route — including routing AROUND obstacles like other units, and
# crossing through any "damaging wall" hazard tiles along the way (instead of
# only checking the single final destination tile, like the old single-tween
# move_to() system did).
# ==============================================================================

extends Node

# A reference to the game grid, set by BattleManager on startup.
# We need this to ask questions like "is this tile a wall?" or "how much does it cost to walk here?"
var grid_ref: Node = null

# ── PATH RECONSTRUCTION BOOKKEEPING ───────────────────────────────────────────
# These two are filled in fresh every time get_reachable_cells() runs, and are
# read afterwards by reconstruct_path_to() to rebuild an actual walking route.
# Think of _last_came_from like a trail of breadcrumbs: for every tile we
# found a route to, we remember exactly which neighboring tile we stepped
# FROM to get there. Following those breadcrumbs backwards from any
# destination tile all the way to the start gives us the real path.

var _last_came_from: Dictionary = {}
# Key: Vector2i (a reachable tile). Value: Vector2i (the tile we stepped from
# to reach it most cheaply). The start tile itself has no entry here.

var _last_start: Vector2i = Vector2i.ZERO
# The tile get_reachable_cells() was most recently called FROM. Used as the
# "we've arrived, stop retracing" marker in reconstruct_path_to().

const _MAX_PATH_RETRACE_STEPS: int = 2000
# Safety net only — purely defensive. With a valid breadcrumb trail this loop
# always terminates almost immediately. This just guarantees the game can
# never freeze even if something upstream corrupts the trail unexpectedly.


# ==============================================================================
# get_reachable_cells
# ==============================================================================
# Returns a Dictionary of all tiles this unit can reach.
# Key = Vector2i tile coordinate, Value = movement cost spent to reach it.
#
# Parameters:
#   start    — The tile the unit is currently standing on.
#   movement — How many movement points the unit has to spend this turn.
#   moving_unit — The unit that is moving. We need this so we can IGNORE its
#                 own occupied tile when checking passability. Without this,
#                 the pathfinder sees the unit's starting tile as "blocked by
#                 a unit" and can't spread to any neighbors at all!
func get_reachable_cells(start: Vector2i, movement: int, moving_unit = null) -> Dictionary:
	var reachable = {}

	# Reset the breadcrumb trail for THIS search. reconstruct_path_to() below
	# reads these once the player/AI has picked an actual destination tile.
	_last_came_from = {}
	_last_start      = start

	# The frontier acts as our look-ahead queue. We start with the unit's current tile.
	var frontier: Array = [{"cell": start, "cost": 0}]

	# Mark the starting tile as reachable at a cost of 0.
	reachable[start] = 0

	# Keep searching as long as there are tiles waiting to be checked.
	while frontier.size() > 0:
		# Pull the next tile from the front of the queue.
		var current = frontier.pop_front()
		var cell: Vector2i = current["cell"]
		var cost: int = current["cost"]

		# Check each of the 4 cardinal neighbors (Right, Left, Down, Up).
		var neighbors = [
			cell + Vector2i(1, 0),
			cell + Vector2i(-1, 0),
			cell + Vector2i(0, 1),
			cell + Vector2i(0, -1)
		]

		for neighbor in neighbors:
			# Safety A: Skip tiles that fall outside the map boundaries.
			if not grid_ref.is_valid_cell(neighbor):
				continue

			# ==============================================================================
			# 🔧 MOVEMENT FIX: Custom passability check that ignores the moving unit's tile.
			# ==============================================================================
			# The old code called grid_ref.is_passable(neighbor) directly.
			# That function returns false for any tile with a unit on it — including
			# the starting tile! So the moving unit blocked its own pathfinding.
			#
			# Now we do the same check manually, but we skip the occupancy check for
			# the tile that the moving_unit itself is standing on. We also respect
			# wall hazards, filtered by which team they block.
			if not _is_passable_for(neighbor, moving_unit):
				continue

			# Read how many movement points it costs to step onto this tile (usually 1).
			var move_cost = grid_ref.get_movement_cost(neighbor)
			var new_cost = cost + move_cost

			# Only proceed if we have enough movement points to reach this tile.
			if new_cost <= movement:
				# If we haven't visited this tile yet, OR found a cheaper route to it:
				if not reachable.has(neighbor) or reachable[neighbor] > new_cost:
					# Record the cost to reach this tile.
					reachable[neighbor] = new_cost

					# Drop a breadcrumb: remember we stepped FROM 'cell' to get
					# to 'neighbor' this cheaply. reconstruct_path_to() follows
					# these backwards later to rebuild the real walking route.
					_last_came_from[neighbor] = cell

					# Push this tile into the queue so we check its neighbors next.
					frontier.append({
						"cell": neighbor,
						"cost": new_cost
					})

	print("🗺️ Pathfinder processing complete. Valid tiles found: ", reachable.size())

	return reachable


# ==============================================================================
# reconstruct_path_to
# ==============================================================================
# Rebuilds the actual tile-by-tile walking route from the start tile of the
# MOST RECENT get_reachable_cells() call to 'destination', by following the
# breadcrumb trail (_last_came_from) backwards from the destination to the
# start, then reversing it so it reads in walking order.
#
# Returns an Array of Vector2i in the order the unit should step through them.
# The starting tile itself is NOT included — so for a unit at (2,2) walking
# to (2,5), this returns [(2,3), (2,4), (2,5)]. unit_node.gd's
# move_along_path() consumes this directly.
#
# IMPORTANT: this only gives correct results if 'destination' was reached by
# the SAME get_reachable_cells() call that's still the most recent one on this
# pathfinder instance — always call get_reachable_cells() again first if the
# board might have changed (units moved, a hazard was placed, etc.) since the
# last time it ran. In practice this is never an issue: battle_manager.gd and
# ai_system.gd always call get_reachable_cells() right before showing/using
# movement options, then call reconstruct_path_to() against that same result.
func reconstruct_path_to(destination: Vector2i) -> Array:
	var path: Array = []
	var current: Vector2i = destination

	# Already standing there — nothing to walk.
	if current == _last_start:
		return path

	# Safety: 'destination' was never actually reached by the last search
	# (bad input, or the board changed since) — return an empty path rather
	# than risk retracing garbage.
	if not _last_came_from.has(current):
		return path

	var steps_taken: int = 0
	while current != _last_start:
		path.append(current)
		current = _last_came_from[current]
		steps_taken += 1
		# Defensive safety net against a corrupted breadcrumb trail — should
		# never actually trigger, but guarantees this can never hang the game.
		if steps_taken > _MAX_PATH_RETRACE_STEPS:
			break

	path.reverse()   # We built it backwards (destination → start); flip it.
	return path


# ==============================================================================
# _is_passable_for (private helper)
# ==============================================================================
# A version of grid.is_passable() that allows the moving unit to "pass through"
# its own tile. All other occupancy, terrain wall, and WALL HAZARD rules still
# apply normally — wall hazards are filtered through the moving unit's team.
#
# Parameters:
#   cell         — The tile coordinate we are checking.
#   moving_unit  — The unit doing the moving (can be null if not relevant).
func _is_passable_for(cell: Vector2i, moving_unit) -> bool:
	# First, run the standard passability checks (valid cell, not a wall, etc.)
	# We replicate the logic here instead of calling grid_ref.is_passable() so we
	# can insert our special moving_unit exception in the middle.

	if not grid_ref.is_valid_cell(cell):
		return false

	# Ask the grid for the tile type data at this cell.
	# If there's no tile data, treat it as impassable.
	if not grid_ref.tile_map.has(cell):
		return false

	var tile = grid_ref.tile_map[cell]

	# Terrain walls block all movement, for everyone.
	if tile.is_wall:
		return false

	# ── WALL HAZARD CHECK ───────────────────────────────────────────────────
	# Wall hazards are tracked separately from terrain walls in hazard_map.
	# Whether they block THIS unit depends on the hazard's wall_blocks setting
	# ("player", "enemies", or "all"). We ask the grid directly rather than
	# duplicating the team-filter logic here.
	if grid_ref.has_method("_is_blocked_by_wall_hazard"):
		if grid_ref._is_blocked_by_wall_hazard(cell, moving_unit):
			return false

	# Check if a unit is occupying this cell.
	if grid_ref.unit_positions.has(cell):
		# 🌟 THE KEY FIX: If the unit occupying this tile IS the moving unit,
		# pretend nobody is there. This lets the pathfinder start spreading
		# outward from the unit's own tile without being blocked by itself.
		var occupant = grid_ref.unit_positions[cell]
		if moving_unit != null and occupant == moving_unit:
			return true  # Treat own tile as empty — allow pathfinding to proceed.
		return false      # Someone else is standing here — blocked.

	return true


# ==============================================================================
# get_cells_in_range
# ==============================================================================
# Returns a simple list of all tile coordinates within Manhattan distance range.
# Used for ability targeting (doesn't care about walls or movement cost —
# just raw distance). min_r and max_r create a ring shape (e.g. min 2, max 3).
func get_cells_in_range(origin: Vector2i, min_r: int, max_r: int) -> Array:
	var cells = []

	# Loop over a bounding box and keep only tiles within our distance ring.
	for x in range(-max_r, max_r + 1):
		for y in range(-max_r, max_r + 1):
			# Manhattan distance = how many steps away ignoring diagonals.
			var dist = abs(x) + abs(y)

			if dist >= min_r and dist <= max_r:
				var cell = origin + Vector2i(x, y)

				if grid_ref.is_valid_cell(cell):
					cells.append(cell)

	return cells


# ==============================================================================
# has_line_of_sight
# ==============================================================================
# Checks whether there is a clear, unobstructed line between two tiles.
# Uses linear interpolation to sample tiles along the line and check for walls.
# Returns true if nothing blocks the path between 'from' and 'to'.
# grid_ref.blocks_los() already accounts for terrain walls AND wall hazards
# that have wall_blocks_line_of_sight enabled — no change needed here beyond
# relying on that updated implementation.
func has_line_of_sight(from: Vector2i, to: Vector2i) -> bool:
	var dx = to.x - from.x
	var dy = to.y - from.y
	var steps = max(abs(dx), abs(dy))

	if steps <= 1: # Fixed to instantly cover adjacent targets safely
		return true

	for i in range(1, steps):
		var t = float(i) / float(steps)
		var check_x = roundi(from.x + dx * t)
		var check_y = roundi(from.y + dy * t)
		var check = Vector2i(check_x, check_y)

		if check != to:
			if grid_ref.blocks_los(check):
				# 🟥 DEBUG PRINT: Tells you exactly which tile is causing the block
				print("Line of Sight BLOCKED between ", from, " and ", to, " at tile coordinate: ", check)
				return false

	return true
