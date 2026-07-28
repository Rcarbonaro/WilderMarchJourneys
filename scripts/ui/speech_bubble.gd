# res://scripts/ui/speech_bubble.gd
#
# SPEECH BUBBLE -- a small cartoony popup that shows one line of dialogue
# above a unit's head. Its border shape changes based on the line's emotion:
#   "happy" -- smooth, rounded border.
#   "angry" -- jagged, spiky border.
#   "sad"   -- droopy, sagging border.
#
# HOW TO USE THIS:
#   var bubble := SpeechBubble.new()
#   unit_preview.add_child(bubble)      # follows the unit since it's a child
#   bubble.position = Vector2(0, -90)   # sits above the unit's head
#   bubble.show_line(bark_line_data)    # bark_line_data is a BarkLineData

class_name SpeechBubble
extends Node2D

# ── TUNABLE APPEARANCE SETTINGS ─────────────────────────────────────────────
@export var bubble_padding: Vector2 = Vector2(18, 12)
# Empty space (in pixels) kept between the text and the bubble's edge.

@export var max_text_width: float = 220.0
# The text wraps onto a new line once it would exceed this width.

@export var display_duration: float = 2.5
# How many seconds the bubble stays fully visible before fading out.

@export var fade_duration: float = 0.35
# How long the fade-out takes once display_duration has elapsed.

const HAPPY_COLOR: Color = Color(0.3, 0.75, 0.35)
const ANGRY_COLOR: Color = Color(0.85, 0.25, 0.2)
const SAD_COLOR: Color = Color(0.35, 0.5, 0.85)
# Border tint per emotion, so the three shapes also read as distinct
# colors at a glance, not just by outline shape.

# ── INTERNAL STATE ───────────────────────────────────────────────────────────
var _emotion: String = "happy"
var _bubble_size: Vector2 = Vector2(120, 60)   # Recomputed once the label sizes itself.
var _label: Label = null


func _ready() -> void:
	# Start invisible/tiny -- the "pop" tween in show_line() scales this up.
	scale = Vector2(0.05, 0.05)
	modulate.a = 0.0
	z_index = 100   # Draw above the unit's sprite and other deployment UI.


func show_line(line: BarkLineData) -> void:
	if line == null:
		queue_free()
		return

	_emotion = line.emotion

	# ── BUILD THE LABEL FIRST SO WE KNOW HOW BIG THE BUBBLE NEEDS TO BE ─────
	_label = Label.new()
	_label.text = line.text
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_label.custom_minimum_size = Vector2(max_text_width, 0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	add_child(_label)

	# Control nodes only know their real size AFTER a layout pass, so we
	# wait one frame before measuring and drawing the bubble around the text.
	await get_tree().process_frame
	_bubble_size = _label.size + bubble_padding * 2.0
	_label.position = -_bubble_size / 2.0 + bubble_padding

	queue_redraw()   # Runs _draw() below, now that _bubble_size is correct.
	_play_pop_in_animation()
	_start_auto_dismiss_timer()


func _play_pop_in_animation() -> void:
	# Cartoony "bounce out" pop: scale springs past full size and settles
	# back down, using an elastic-out curve for the overshoot/wobble.
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.45) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 1.0, 0.15)


func _start_auto_dismiss_timer() -> void:
	await get_tree().create_timer(display_duration).timeout
	if not is_instance_valid(self):
		return
	var fade_tween: Tween = create_tween()
	fade_tween.tween_property(self, "modulate:a", 0.0, fade_duration)
	fade_tween.tween_callback(queue_free)


func _draw() -> void:
	# Draws the bubble shape itself (the Label is a separate child node,
	# drawn on top automatically since children draw after their parent).
	var half: Vector2 = _bubble_size / 2.0
	var fill_color: Color = Color(1, 1, 1, 0.95)

	match _emotion:
		"angry":
			_draw_jagged_bubble(half, fill_color, ANGRY_COLOR)
		"sad":
			_draw_droopy_bubble(half, fill_color, SAD_COLOR)
		_:   # "happy" and any unrecognised value fall back to the smooth shape.
			_draw_smooth_bubble(half, fill_color, HAPPY_COLOR)


func _draw_smooth_bubble(half: Vector2, fill_color: Color, border_color: Color) -> void:
	# A plain rounded rectangle: built as a polygon of points sampled along
	# 4 corner arcs, plus a small triangular tail pointing down at the unit.
	const CORNER_RADIUS: float = 14.0
	const ARC_SEGMENTS: int = 8

	var points: PackedVector2Array = PackedVector2Array()
	var corners: Array = [
		Vector2(half.x - CORNER_RADIUS, -half.y + CORNER_RADIUS),    # top-right
		Vector2(half.x - CORNER_RADIUS, half.y - CORNER_RADIUS),     # bottom-right
		Vector2(-half.x + CORNER_RADIUS, half.y - CORNER_RADIUS),    # bottom-left
		Vector2(-half.x + CORNER_RADIUS, -half.y + CORNER_RADIUS),   # top-left
	]
	var start_angles: Array = [-PI / 2.0, 0.0, PI / 2.0, PI]

	for i in range(4):
		var center: Vector2 = corners[i]
		var start_angle: float = start_angles[i]
		for s in range(ARC_SEGMENTS + 1):
			var angle: float = start_angle + (PI / 2.0) * (float(s) / ARC_SEGMENTS)
			points.append(center + Vector2(cos(angle), sin(angle)) * CORNER_RADIUS)

	_append_tail_and_draw(points, half, fill_color, border_color, 3.0)


func _draw_jagged_bubble(half: Vector2, fill_color: Color, border_color: Color) -> void:
	# A spiky outline: walks around the rectangle's perimeter, alternating
	# short in/out zig-zag points instead of a straight edge or smooth curve.
	const SPIKE_COUNT_PER_SIDE: int = 5
	const SPIKE_DEPTH: float = 6.0

	var corners: PackedVector2Array = PackedVector2Array([
		Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(half.x, half.y), Vector2(-half.x, half.y),
	])

	var points: PackedVector2Array = PackedVector2Array()
	for side in range(4):
		var a: Vector2 = corners[side]
		var b: Vector2 = corners[(side + 1) % 4]
		var side_dir: Vector2 = b - a
		var normal: Vector2 = side_dir.normalized().rotated(-PI / 2.0)   # Points outward.
		for s in range(SPIKE_COUNT_PER_SIDE):
			var t: float = float(s) / SPIKE_COUNT_PER_SIDE
			var base_point: Vector2 = a + side_dir * t
			# Every other point pokes outward, giving the jagged look.
			var poke: float = SPIKE_DEPTH if s % 2 == 0 else 0.0
			points.append(base_point + normal * poke)

	_append_tail_and_draw(points, half, fill_color, border_color, 3.5)


func _draw_droopy_bubble(half: Vector2, fill_color: Color, border_color: Color) -> void:
	# A sagging outline: the top edge stays straight and crisp, but the
	# right, bottom, and left edges bow outward/downward using a sine
	# curve, like a tired, deflating balloon.
	const SEGMENTS_PER_SIDE: int = 10
	const SAG_AMOUNT: float = 10.0

	var points: PackedVector2Array = PackedVector2Array()

	# Top edge -- stays flat (no droop up top).
	points.append(Vector2(-half.x, -half.y))
	points.append(Vector2(half.x, -half.y))

	# Right, bottom, and left edges each sag following a half-sine bulge,
	# strongest in the middle of each edge and zero at both ends.
	var edges: Array = [
		[Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(1, 0)],
		[Vector2(half.x, half.y), Vector2(-half.x, half.y), Vector2(0, 1)],
		[Vector2(-half.x, half.y), Vector2(-half.x, -half.y), Vector2(-1, 0)],
	]
	for edge in edges:
		var a: Vector2 = edge[0]
		var b: Vector2 = edge[1]
		var outward: Vector2 = edge[2]
		for s in range(1, SEGMENTS_PER_SIDE + 1):
			var t: float = float(s) / SEGMENTS_PER_SIDE
			var base_point: Vector2 = a.lerp(b, t)
			var sag: float = sin(t * PI) * SAG_AMOUNT   # 0 at both ends, peak at the middle.
			points.append(base_point + outward * sag)

	_append_tail_and_draw(points, half, fill_color, border_color, 3.0)


func _append_tail_and_draw(body_points: PackedVector2Array, half: Vector2,
		fill_color: Color, border_color: Color, border_width: float) -> void:
	# Draws the bubble's body (rounded/jagged/droopy) and its downward-
	# pointing tail as TWO SEPARATE shapes that slightly overlap where they
	# meet, rather than one single stitched-together outline.
	#
	# (Why: appending the tail's points onto the end of the body's perimeter
	# array put them in the wrong place along the loop -- the boundary would
	# jump from the top of the shape down to the bottom-center tail and back,
	# crossing over itself. A self-intersecting polygon doesn't fill/
	# triangulate correctly, which is what caused the bubble to render as if
	# it were split in two. Keeping the tail as its own small shape sidesteps
	# that entirely.)
	const TAIL_WIDTH: float = 16.0
	const TAIL_HEIGHT: float = 14.0
	const TAIL_OVERLAP: float = 6.0
	# How far the tail's top edge dips up into the body -- just enough that
	# there's no visible gap/seam between the two filled shapes.

	var base_left: Vector2 = Vector2(-TAIL_WIDTH / 2.0, half.y)
	var base_right: Vector2 = Vector2(TAIL_WIDTH / 2.0, half.y)
	var tip: Vector2 = Vector2(0, half.y + TAIL_HEIGHT)
	var overlap_left: Vector2 = Vector2(-TAIL_WIDTH / 2.0, half.y - TAIL_OVERLAP)
	var overlap_right: Vector2 = Vector2(TAIL_WIDTH / 2.0, half.y - TAIL_OVERLAP)

	# ── FILL ── body first, then the tail drawn on top (its overlap into
	# the body hides the seam between the two shapes).
	draw_colored_polygon(body_points, fill_color)
	draw_colored_polygon(PackedVector2Array([overlap_left, overlap_right, tip]), fill_color)

	# ── OUTLINE ── the body's own border, closed on itself...
	var closed_body: PackedVector2Array = body_points.duplicate()
	closed_body.append(body_points[0])
	draw_polyline(closed_body, border_color, border_width, true)

	# ...plus just the tail's two visible slanted edges. Its base (where it
	# meets the body) is deliberately left undrawn since the body fill
	# covers it anyway.
	draw_line(base_left, tip, border_color, border_width, true)
	draw_line(base_right, tip, border_color, border_width, true)
	
