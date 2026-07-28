# res://scripts/data/dialogue_bark_data.gd
#
# DIALOGUE BARK DATA -- a pool of lines a unit can randomly say, e.g. when
# tapped during deployment. Later this same resource can back event
# dialogue too, since it's just "a bag of weighted lines."
#
# HOW TO USE THIS:
#   1. In the Godot editor, right-click a FileSystem folder -> New Resource
#      -> search "DialogueBarkData" -> save it, e.g.
#      res://resources/barks/hexweaver_barks.tres
#   2. In the Inspector, expand "Lines" and click "Add Element" for each
#      line of dialogue. Set its Text, Weight, and Emotion.
#   3. Drag this .tres file onto a UnitData resource's "Deployment Barks"
#      field (see the note added to unit_data.gd).

class_name DialogueBarkData
extends Resource

@export var lines: Array[BarkLineData] = []
@export var deployment_barks: DialogueBarkData

func get_random_line() -> BarkLineData:
	# Picks one line at random, weighted by each line's "weight" field.
	# Returns null if there are no usable lines to pick from.
	if lines.is_empty():
		return null

	var total_weight: float = 0.0
	for line in lines:
		if line != null:
			total_weight += max(0.0, line.weight)

	if total_weight <= 0.0:
		# Every line has weight <= 0 (or all entries are null/unset) --
		# fall back to a plain uniform pick so this never silently does
		# nothing just because someone left weights at 0.
		var valid_lines: Array = lines.filter(func(l): return l != null)
		if valid_lines.is_empty():
			return null
		return valid_lines[randi() % valid_lines.size()]

	var roll: float = randf() * total_weight
	var cumulative: float = 0.0
	for line in lines:
		if line == null:
			continue
		cumulative += max(0.0, line.weight)
		if roll <= cumulative:
			return line

	return lines.back()   # Safety net in case float rounding falls just short.
