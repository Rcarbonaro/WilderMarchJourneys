# res://scripts/battle/highlight_manager.gd
#
# Draws colored tile overlays for movement range, attack range, AOE preview,
# and now ENEMY THREAT RANGE (shown when the player taps an enemy unit).
#
# NEW: Threat range uses its OWN separate node/array from the normal
# movement/attack/AOE highlights. This is essential — normal highlighting
# gets cleared constantly during the player's own turn (every time they pick
# a unit, ability, or AOE target), and threat range needs to persist
# independently of that churn, then be cleared only when the player taps
# empty ground or a different unit.

extends Node

@export var grid: Node2D  # drag BattleGrid here in Inspector

var TILE_SIZE = 96  # match BattleGrid.TILE_SIZE

var _highlight_nodes: Array = []
# Normal movement/attack/AOE highlight rects — cleared frequently.

var _threat_highlight_nodes: Array = []
# Enemy threat-range highlight rects (green move + red attack) — cleared only
# when the player deselects (taps empty ground or a different unit).


func show_movement(cells: Array) -> void:
	clear_highlights()
	for cell in cells:
		var rect = ColorRect.new()
		rect.size = Vector2(TILE_SIZE, TILE_SIZE)
		rect.position = grid.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		rect.color = Color(0, 1, 0, 0.3)  # transparent green
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_highlight_nodes.append(rect)


func show_attack_range(cells: Array) -> void:
	clear_highlights()
	for cell in cells:
		var rect = ColorRect.new()
		rect.size = Vector2(TILE_SIZE, TILE_SIZE)
		rect.position = grid.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		rect.color = Color(1, 0, 0, 0.3)  # transparent red
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_highlight_nodes.append(rect)


func clear_highlights() -> void:
	for node in _highlight_nodes:
		node.queue_free()
	_highlight_nodes.clear()


func highlight_aoe_blast_cells(cells: Array) -> void:
	# Note: We do NOT clear highlights here because we want to layer
	# this orange/yellow layout directly on top of the red range tiles!
	for cell in cells:
		var rect = ColorRect.new()
		rect.size = Vector2(TILE_SIZE, TILE_SIZE)
		rect.position = grid.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		rect.color = Color(1.0, 0.5, 0.0, 0.4)  # Bright orange warning overlay
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_highlight_nodes.append(rect)

# ── ENEMY THREAT RANGE ────────────────────────────────────────────────────────

func show_threat_range(move_cells: Array, attack_cells: Array) -> void:
	# Displays an enemy's full threat range: green tiles for where they can
	# move this turn, red tiles for every tile they could then attack from
	# any of those green tiles (the union across all their abilities' ranges).
	#
	# Uses a SEPARATE highlight set from show_movement/show_attack_range so
	# it survives the player continuing to select their own units/abilities —
	# it's only cleared by clear_threat_range(), called explicitly by
	# BattleManager when the player deselects or picks something else.
	clear_threat_range()

	# Draw red attack tiles FIRST so green move tiles layer on top at their
	# shared edges, making the "core" movement area visually distinct from
	# the surrounding threat ring.
	for cell in attack_cells:
		var rect = ColorRect.new()
		rect.size = Vector2(TILE_SIZE, TILE_SIZE)
		rect.position = grid.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		rect.color = Color(1, 0, 0, 0.28)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_threat_highlight_nodes.append(rect)

	for cell in move_cells:
		var rect = ColorRect.new()
		rect.size = Vector2(TILE_SIZE, TILE_SIZE)
		rect.position = grid.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		rect.color = Color(0, 1, 0, 0.28)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_threat_highlight_nodes.append(rect)


func clear_threat_range() -> void:
	for node in _threat_highlight_nodes:
		node.queue_free()
	_threat_highlight_nodes.clear()
