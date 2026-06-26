extends ParallaxBackground

@export var speed := Vector2(40, 0)

@export var min_scroll := Vector2(0, 0)
@export var max_scroll := Vector2(2000, 0)

func _process(delta):
	scroll_offset += speed * delta

	scroll_offset.x = clamp(scroll_offset.x, min_scroll.x, max_scroll.x)
	scroll_offset.y = clamp(scroll_offset.y, min_scroll.y, max_scroll.y)
