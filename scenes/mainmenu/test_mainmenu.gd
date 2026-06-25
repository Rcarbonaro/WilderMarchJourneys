extends ParallaxBackground

@export var scroll_speed := Vector2(10, 5)

func _process(delta):
	scroll_offset += scroll_speed * delta
