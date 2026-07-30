# res://scripts/autoloads/scene_transitions.gd
#
# SCENE TRANSITIONS — a full-screen wipe overlay that plays every time the
# game changes scenes, instead of a hard cut. (Task 5.)
#
# ── HOW TO USE ────────────────────────────────────────────────────────────
# Anywhere in the project that used to call:
#     get_tree().change_scene_to_file(SOME_PATH)
# now calls:
#     SceneTransitions.change_scene(SOME_PATH)
# ...optionally with a specific style as the second argument:
#     SceneTransitions.change_scene(SOME_PATH, "parchment_burn")
#
# If you omit the style argument (or pass ""), default_style below is used —
# so everything gets the SAME transition by default, but any individual call
# site can override it. Search this project for "SceneTransitions.change_scene"
# to see every current call site and which style (if any) each one passes.
#
# ── AVAILABLE STYLES ──────────────────────────────────────────────────────
#   "page_turn"      (default) — a diagonal wipe with a bright highlight
#                      riding the edge, like a page turning. Shader:
#                      res://shaders/transition_page_turn.gdshader
#   "parchment_burn" — a noise-based dissolve with a warm ember glow at the
#                      edge, like parchment burning away. Shader:
#                      res://shaders/transition_parchment_burn.gdshader
#   "fade"           — a plain fade to a solid color and back. No shader —
#                      this is the simplest possible option, useful as a
#                      calmer choice (currently used for main-menu-related
#                      transitions) or as a guaranteed-safe fallback if you
#                      ever want to rule out a shader issue.
#
# ── HOW TO ADJUST SPEED ───────────────────────────────────────────────────
# cover_duration / reveal_duration / hold_duration below control every
# style's timing. Lower = faster. The brief asked for "smooth and fast" —
# these default to a quick ~0.5s total. Per-style-only speed isn't
# currently exposed as separate numbers; if you want e.g. parchment_burn to
# be slower than page_turn, that's a one-line change — duplicate
# cover_duration/reveal_duration into a small Dictionary keyed by style name
# and look them up in _play_cover()/_play_reveal() instead of using the
# single exported values directly.
#
# ── HOW TO ADJUST LOOK ────────────────────────────────────────────────────
# Every visual knob (angle, colors, noise, edge softness/width, burn
# direction) is a uniform on the two .gdshader files above — open either one
# directly, each has its own "HOW TO ADJUST" notes at the top. The "fade"
# style's color is fade_color below.
#
# ── ADDING A NEW STYLE ────────────────────────────────────────────────────
# 1. Write a new canvas_item shader following the same 'progress' convention
#    used by the two existing ones (progress <= 0 = fully revealed,
#    progress >= 1 = fully covered, with PROGRESS_PAD of headroom on both
#    ends baked into how far this script animates 'progress').
# 2. preload() it below next to PAGE_TURN_SHADER/PARCHMENT_BURN_SHADER, make
#    a ShaderMaterial for it in _ready(), and add a branch for its name in
#    _material_for_style().
extends CanvasLayer

@export var default_style: String = "page_turn"

@export var cover_duration:  float = 0.30
@export var reveal_duration: float = 0.28
@export var hold_duration:   float = 0.05
# Brief pause while fully covered — gives the new scene's _ready() a moment
# to finish building itself before the reveal starts, so the player doesn't
# see a half-initialized frame.

@export var fade_color: Color = Color(0, 0, 0, 1)
# Only used by the "fade" style.

const PAGE_TURN_SHADER: Shader = preload("res://shaders/transition_page_turn.gdshader")
const PARCHMENT_BURN_SHADER: Shader = preload("res://shaders/transition_parchment_burn.gdshader")

# How far past the logical 0..1 range 'progress' animates on each end, so a
# shader's own edge-softness/edge-width never leaves a visible sliver of gap
# at full cover or a stray line at full reveal. Must be >= the largest
# edge_softness/edge_width either shader exposes (both cap at 0.3/0.35) —
# see each shader's own uniform hint_range if you raise those caps.
const PROGRESS_PAD: float = 0.4

var _overlay: ColorRect = null
var _page_turn_material: ShaderMaterial = null
var _parchment_burn_material: ShaderMaterial = null
var _busy: bool = false


func _ready() -> void:
	layer = 999   # draw above absolutely everything, including other CanvasLayers (BattleUI, pause menus, etc.)
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep working even if something pauses the tree mid-transition

	_overlay = ColorRect.new()
	_overlay.name = "SceneTransitionOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color(0, 0, 0, 0)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	add_child(_overlay)

	_page_turn_material = ShaderMaterial.new()
	_page_turn_material.shader = PAGE_TURN_SHADER

	_parchment_burn_material = ShaderMaterial.new()
	_parchment_burn_material.shader = PARCHMENT_BURN_SHADER


func change_scene(path: String, style: String = "") -> void:
	# The main entry point — replaces get_tree().change_scene_to_file(path)
	# everywhere in the project. See the file header above for style names.
	if _busy:
		# A transition is already mid-flight (shouldn't normally happen —
		# scene changes aren't usually triggered back-to-back). Rather than
		# leave the overlay stuck, just go straight to the new scene.
		push_warning("SceneTransitions.change_scene() called while already transitioning — changing scene immediately without a wipe.")
		get_tree().change_scene_to_file(path)
		return

	if not ResourceLoader.exists(path):
		push_warning("SceneTransitions.change_scene(): scene not found at '" + path + "' — not transitioning.")
		return

	_busy = true
	var use_style: String = style if style != "" else default_style

	await _play_cover(use_style)
	get_tree().change_scene_to_file(path)

	# Give the new scene's _ready() a couple of frames (plus hold_duration)
	# to finish before revealing it.
	await get_tree().process_frame
	await get_tree().process_frame
	if hold_duration > 0.0:
		await get_tree().create_timer(hold_duration).timeout

	await _play_reveal(use_style)
	_busy = false


func _material_for_style(style: String) -> ShaderMaterial:
	match style:
		"parchment_burn":
			return _parchment_burn_material
		"page_turn":
			return _page_turn_material
		_:
			return null   # "fade" (or anything unrecognized) uses no shader.


func _play_cover(style: String) -> void:
	_overlay.visible = true
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP   # block clicks through mid-transition

	if style == "fade":
		_overlay.material = null
		_overlay.color = Color(fade_color.r, fade_color.g, fade_color.b, 0.0)
		var tween := create_tween()
		tween.tween_property(_overlay, "color:a", 1.0, cover_duration)
		await tween.finished
		return

	var mat := _material_for_style(style)
	if mat == null:
		mat = _page_turn_material   # unrecognized style name — fall back safely rather than no-op.
	_overlay.material = mat
	_overlay.color = Color(1, 1, 1, 1)   # shader fully controls visible color/alpha; this just needs to be opaque.
	mat.set_shader_parameter("progress", -PROGRESS_PAD)

	var tween := create_tween()
	tween.tween_method(
		func(v): mat.set_shader_parameter("progress", v),
		-PROGRESS_PAD, 1.0 + PROGRESS_PAD, cover_duration
	)
	await tween.finished


func _play_reveal(style: String) -> void:
	if style == "fade":
		var tween := create_tween()
		tween.tween_property(_overlay, "color:a", 0.0, reveal_duration)
		await tween.finished
		_overlay.visible = false
		_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return

	var mat := _material_for_style(style)
	if mat == null:
		mat = _page_turn_material
	var tween := create_tween()
	tween.tween_method(
		func(v): mat.set_shader_parameter("progress", v),
		1.0 + PROGRESS_PAD, -PROGRESS_PAD, reveal_duration
	)
	await tween.finished

	_overlay.visible = false
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.material = null
