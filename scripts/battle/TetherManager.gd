extends Node2D

# Reference the shader you created earlier
var tether_shader = preload("res://scenes/animations/hexweaver/tether_effect.gdshader")

# A dictionary to track lines: { "tether_id": [Line2D, Line2D, ...] }
var active_lines = {}

func update_tethers(tether_map: Dictionary):
	# 1. Clear or update existing lines based on the current tether_map
	for tether_id in tether_map:
		var units = tether_map[tether_id]
		
		# Only draw if there are at least 2 units
		if units.size() < 2: continue
		
		# Create a visual connection for each pair
		# (This example connects them in a chain: A-B, B-C, etc.)
		for i in range(units.size() - 1):
			var u1 = units[i]
			var u2 = units[i+1]
			
			if is_instance_valid(u1) and is_instance_valid(u2):
				draw_tether_between(u1.global_position, u2.global_position, tether_id)

func draw_tether_between(pos1: Vector2, pos2: Vector2, tether_id: String):
	# Using Draw commands is often more performant than creating hundreds of Line2D nodes
	# Call this in the _draw() function of your manager
	draw_line(pos1, pos2, Color.PURPLE, 4.0) 
	# Note: To use the Shader with raw draw_line, you would typically 
	# use a CanvasItemMaterial or a dedicated Line2D node.
