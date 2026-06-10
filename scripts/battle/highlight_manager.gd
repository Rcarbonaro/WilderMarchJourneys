# res://scripts/battle/highlight_manager.gd

# 📥 CALLS FROM: BattleManager — told which cells to highlight

# 📤 EXPORTS TO: (visual only — no other script reads this)

extends Node

# 📥 CALLS FROM: BattleGrid.grid_to_world() to position highlights

@export var grid: Node2D  # drag BattleGrid here in Inspector

var TILE_SIZE = 96  # match BattleGrid.TILE_SIZE

var _highlight_nodes: Array = []

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
		
		# Bright orange warning overlay (Red: 1.0, Green: 0.5, Blue: 0.0, Opacity: 0.4)
		rect.color = Color(1.0, 0.5, 0.0, 0.4)  
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_highlight_nodes.append(rect)
