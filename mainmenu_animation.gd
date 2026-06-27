extends Node2D

# How fast the background scrolls overall
@export var scroll_speed: float = 30.0

# How far to the left/right the menu should pan before turning back
@export var max_pan_distance: float = 200.0

var direction: int = 1
var current_pan: float = 0.0
var parallax_layers: Array[Parallax2D] = []

func _ready() -> void:
	# Automatically gather all Parallax2D children
	for child in get_children():
		if child is Parallax2D:
			parallax_layers.append(child)

func _process(delta: float) -> void:
	# Calculate the movement for this frame
	var movement = scroll_speed * direction * delta
	current_pan += movement
	
	# Apply the movement to the custom viewport offset of every layer
	for layer in parallax_layers:
		layer.screen_offset.x += movement
	
	# Reverse direction if we hit our maximum panning threshold
	if abs(current_pan) >= max_pan_distance:
		direction *= -1
