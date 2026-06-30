extends Node2D

@onready var battle_grid = get_tree().get_first_node_in_group("battle_grid")
@onready var groups: Node2D = $Groups


func _process(_delta):
	if battle_grid == null:
		return

	update_tethers()


func update_tethers():
	# clear old visuals safely
	for child in groups.get_children():
		child.queue_free()

	# iterate tether groups
	for tether_id in battle_grid.tether_map.keys():

		var units = battle_grid.get_tethered_units(tether_id, null)

		# must have at least 2 units
		if units.size() < 2:
			continue

		# stable order so lines don’t “shuffle”
		units.sort_custom(func(a, b):
			return a.get_instance_id() < b.get_instance_id()
		)

		# build chain segments
		for i in range(units.size() - 1):

			var a = units[i]
			var b = units[i + 1]

			if not is_instance_valid(a) or not is_instance_valid(b):
				continue

			var line = Line2D.new()

			# 🔥 HARD VISIBILITY SETTINGS (no shader dependency)
			line.width = 6.0
			line.default_color = Color(0.7, 0.2, 1.0, 1.0)
			line.antialiased = true

			# IMPORTANT: use GROUP SPACE (not local-to-unit space)
			var origin = groups.global_position

			line.points = [
				a.global_position - origin,
				b.global_position - origin
			]

			groups.add_child(line)
