# res://scripts/ui/tutorial_overlay.gd
#
# TUTORIAL OVERLAY -- the actual on-screen popup + arrow + spotlight.
# Spawned automatically by tutorial_manager.gd's _ready() -- you do NOT
# place this in any scene yourself, and it needs no node name. It survives
# every scene change because its parent (TutorialManager) is an autoload.
#
# It listens to TutorialManager.step_started and rebuilds itself for each
# new step; it doesn't know anything about battle, shop, or deployment
# specifically -- it only knows how to point at a registered target.
#
# BLOCKING vs NON-BLOCKING: a step can set "block_input": false (default is
# true) to skip the darkened scrim entirely -- use this when pointing at
# something inside a screen that already protects itself, like the
# read-only UnitInfoPopup (outside clicks just close it, there's nothing
# else in there TO misclick).

class_name TutorialOverlay
extends CanvasLayer

const SCRIM_COLOR       := Color(0, 0, 0, 0.6)
const SPOTLIGHT_PADDING := 10.0     # px of breathing room around the target's rect
const ARROW_COLOR       := Color(1.0, 0.85, 0.2, 1.0)
const TEXTBOX_MAX_WIDTH := 420.0

var _scrim_top: ColorRect
var _scrim_bottom: ColorRect
var _scrim_left: ColorRect
var _scrim_right: ColorRect
var _arrow: Polygon2D
var _textbox: PanelContainer
var _textbox_label: RichTextLabel
var _continue_button: Button

var _current_step: Dictionary = {}
var _current_target_key: String = ""
# NOTE: this is a KEY (String), not a cached Node reference. The target is
# re-resolved fresh every frame in _get_target_screen_rect() -- see that
# function's comment for why caching the resolved node broke step 1 at
# tutorial startup (the target may not exist yet the instant a step begins).


func _ready() -> void:
	layer = 100   # above everything -- popups, HUD, all of it
	TutorialManager.step_started.connect(_on_step_started)
	TutorialManager.tutorial_ended.connect(_on_tutorial_ended)
	EventBus.subscribe("tutorial_nudge", func(_payload): _play_nudge())
	_build_shell()
	visible = false
	set_process(true)


func _build_shell() -> void:
	_scrim_top    = _make_scrim_rect()
	_scrim_bottom = _make_scrim_rect()
	_scrim_left   = _make_scrim_rect()
	_scrim_right  = _make_scrim_rect()

	_arrow = Polygon2D.new()
	_arrow.color = ARROW_COLOR
	# Apex points DOWN by default (rotation 0 = sitting above the target,
	# pointing down into it). _layout() rotates 180 to flip it for
	# below-the-target placement.
	_arrow.polygon = PackedVector2Array([Vector2(0, 14), Vector2(14, -10), Vector2(-14, -10)])
	add_child(_arrow)
	_arrow.visible = false

	_textbox = PanelContainer.new()
	_textbox.custom_minimum_size = Vector2(TEXTBOX_MAX_WIDTH, 0)
	add_child(_textbox)
	var box_v := VBoxContainer.new()
	box_v.add_theme_constant_override("separation", 10)
	_textbox.add_child(box_v)

	_textbox_label = RichTextLabel.new()
	_textbox_label.bbcode_enabled = true
	_textbox_label.fit_content = true
	_textbox_label.scroll_active = false
	_textbox_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_textbox_label.custom_minimum_size = Vector2(TEXTBOX_MAX_WIDTH - 24, 0)
	box_v.add_child(_textbox_label)

	_continue_button = Button.new()
	_continue_button.text = "Continue ▶"
	_continue_button.pressed.connect(func(): TutorialManager.advance())
	box_v.add_child(_continue_button)


func _make_scrim_rect() -> ColorRect:
	var r := ColorRect.new()
	r.color = SCRIM_COLOR
	r.mouse_filter = Control.MOUSE_FILTER_STOP   # blocks clicks -- the whole point of the cutout technique
	add_child(r)
	return r


func _on_step_started(step: Dictionary) -> void:
	_current_step = step
	_current_target_key = step.get("target", "")
	visible = true

	# ADDED: a wait_for step is meant to be fully silent -- no scrim, no
	# arrow, and (this was the missing piece) no floating textbox/button
	# either. Without this, an empty-text wait_for step still showed a bare
	# "Continue ▶" button sitting on screen for as long as it was waiting.
	var is_wait_for: bool = step.get("type", "") == "wait_for"
	_textbox.visible = not is_wait_for

	_textbox_label.text = step.get("text", "")
	var is_gate: bool = step.get("type", "gate") == "gate"
	_continue_button.visible = not is_gate   # gate steps advance from the real action, not a button
	
	var should_block: bool = step.get("block_input", true) and step.get("type", "") != "wait_for"
	_scrim_top.visible = should_block
	_scrim_bottom.visible = should_block
	_scrim_left.visible = should_block
	_scrim_right.visible = should_block

	_layout()


func _on_tutorial_ended() -> void:
	visible = false


func _process(_delta: float) -> void:
	if visible:
		_layout()   # target may be moving (a unit walking), not yet spawned, or the window may have resized


func _layout() -> void:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var target_rect: Rect2 = _get_target_screen_rect()

	if target_rect == Rect2():
		# No target (or it's a pure-narration step, or the target hasn't
		# resolved yet this frame) -- full scrim, textbox centered low.
		_scrim_top.position = Vector2.ZERO
		_scrim_top.size = viewport_size
		_scrim_bottom.size = Vector2.ZERO
		_scrim_left.size = Vector2.ZERO
		_scrim_right.size = Vector2.ZERO
		_arrow.visible = false
		_textbox.position = Vector2(
			(viewport_size.x - _textbox.size.x) / 2.0, viewport_size.y - _textbox.size.y - 60)
		return

	var hole := target_rect.grow(SPOTLIGHT_PADDING)

	_scrim_top.position = Vector2(0, 0)
	_scrim_top.size = Vector2(viewport_size.x, max(0, hole.position.y))

	_scrim_bottom.position = Vector2(0, hole.position.y + hole.size.y)
	_scrim_bottom.size = Vector2(viewport_size.x, max(0, viewport_size.y - (hole.position.y + hole.size.y)))

	_scrim_left.position = Vector2(0, hole.position.y)
	_scrim_left.size = Vector2(max(0, hole.position.x), hole.size.y)

	_scrim_right.position = Vector2(hole.position.x + hole.size.x, hole.position.y)
	_scrim_right.size = Vector2(max(0, viewport_size.x - (hole.position.x + hole.size.x)), hole.size.y)

	# Arrow bobs just above the hole, pointing down at it. Flips to point up
	# from below if the hole is near the top of the screen.
	_arrow.visible = true
	var point_from_above: bool = hole.position.y > 100
	_arrow.position = Vector2(hole.position.x + hole.size.x / 2.0,
		hole.position.y - 24 if point_from_above else hole.position.y + hole.size.y + 24)
	_arrow.rotation = 0.0 if point_from_above else PI

	# Textbox sits below the hole if there's room, otherwise above it.
	var box_size: Vector2 = _textbox.size
	var below_y: float = hole.position.y + hole.size.y + 40
	var fits_below: bool = below_y + box_size.y < viewport_size.y
	var box_y: float = below_y if fits_below else max(20, hole.position.y - box_size.y - 40)
	var box_x: float = clamp(hole.position.x + hole.size.x / 2.0 - box_size.x / 2.0,
		20, viewport_size.x - box_size.x - 20)
	_textbox.position = Vector2(box_x, box_y)

func _get_target_screen_rect() -> Rect2:
	# Re-resolved every call (this runs once a frame via _process -> _layout)
	# instead of cached once when the step started -- a "unit:" target in
	# particular may not exist yet at the exact moment a step begins (the
	# tutorial's very first step fires before BattleScene has even finished
	# loading and spawning units), so this keeps retrying every frame
	# instead of permanently giving up after one failed attempt.
	if _current_target_key.begins_with("cell_offset:"):
		var parts: PackedStringArray = _current_target_key.split(":")
		if parts.size() == 4:
			var world_pos = TutorialManager.get_cell_offset_world_pos(parts[1], int(parts[2]), int(parts[3]))
			if world_pos != null:
				var canvas_transform: Transform2D = get_viewport().get_canvas_transform()
				var screen_pos: Vector2 = canvas_transform * world_pos
				return Rect2(screen_pos - Vector2(28, 28), Vector2(56, 56))
		return Rect2()
	var target: Node = TutorialManager.get_target_node(_current_target_key)
	if target == null:
		return Rect2()
	if target is Control:
		return (target as Control).get_global_rect()
	if target is Node2D:
		# Camera2D has no unproject_position() (that's a Camera3D method) --
		# the canvas transform is what Godot itself uses to draw every 2D
		# node to the screen, and already accounts for the active Camera2D's
		# position/zoom/rotation.
		var canvas_transform: Transform2D = get_viewport().get_canvas_transform()
		var screen_pos: Vector2 = canvas_transform * target.global_position
		return Rect2(screen_pos - Vector2(28, 28), Vector2(56, 56))   # ~1 grid-tile-ish box around a unit
	return Rect2()


func _play_nudge() -> void:
	var tween := create_tween()
	var start_pos: Vector2 = _textbox.position
	tween.tween_property(_textbox, "position:x", start_pos.x - 8, 0.05)
	tween.tween_property(_textbox, "position:x", start_pos.x + 8, 0.05)
	tween.tween_property(_textbox, "position:x", start_pos.x, 0.05)
