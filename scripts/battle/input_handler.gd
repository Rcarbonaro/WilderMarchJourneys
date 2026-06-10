# res://scripts/battle/input_handler.gd

# 📤 EXPORTS TO: BattleManager — sends tapped cell coordinates

# Handles both mouse clicks (desktop testing) and touch (mobile)

extends Node

# 📥 CALLS FROM: BattleManager and BattleGrid are both needed here

@export var grid: Node2D          # BattleGrid

@export var battle_manager: Node  # BattleManager

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		
		# 🛑 THE FIX: If the mouse is clicking on a UI container/button, ignore the map grid click!
		if get_viewport().gui_get_hovered_control() != null:
			print("Ignoring grid tap because a UI element is being hovered/clicked.")
			return
			
		var cell = grid.world_to_grid(event.position)
		battle_manager.on_tile_tapped(cell)
