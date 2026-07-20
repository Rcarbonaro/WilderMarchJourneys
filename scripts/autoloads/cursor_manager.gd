# res://scripts/autoloads/cursor_manager.gd
#
# CURSOR MANAGER -- applies the custom fantasy mouse cursor project-wide,
# scaled down from the source image (your cursor09_bl.png, like most cursor
# art, is sized larger than a comfortable on-screen cursor). Register this
# as an Autoload named "CursorManager" (Project Settings > Autoload) and it
# takes care of itself; no per-scene setup needed.
#
# ── HOW TO TRY A DIFFERENT CURSOR ───────────────────────────────────────
# 1. Drop the new image into res://sprites/UI/cursor/ (any size works --
#    it gets scaled down automatically, see CURSOR_SCALE below).
# 2. Change DEFAULT_CURSOR_PATH below to point at the new file.
# 3. Adjust DEFAULT_CURSOR_HOTSPOT if the "tip" of the cursor (the exact
#    pixel that should align with the mouse position -- e.g. the point of
#    a sword, or the top-left corner of a gem) isn't at the image's
#    top-left corner. Hotspot is in pixels measured against the ORIGINAL,
#    full-size image -- it gets scaled down automatically along with the
#    cursor itself, so you don't need to re-do the math by hand.
# 4. Run the game -- no restart of the editor needed.
#
# ── SIZE ──────────────────────────────────────────────────────────────
# CURSOR_SCALE controls how much smaller the on-screen cursor is compared
# to the source image. 0.2 = 1/5th size (current setting). Lower = smaller.
#
# NOTE: this requires reading the cursor image's pixels at runtime, which
# only works if the texture's import settings allow CPU access. If the
# cursor doesn't shrink (or you see a warning in the Output panel), select
# cursor09_bl.png in the FileSystem dock, open the Import tab, and make
# sure "Compress > Mode" is NOT set to a VRAM-compressed format (Lossless
# or Lossy both work fine) -- then click Reimport.
#
# ── HOW TO GIVE DIFFERENT UI ELEMENTS DIFFERENT CURSORS ─────────────────
# Call set_cursor() from any script, e.g. on a button's hover signals:
#
#   func _on_confirm_button_mouse_entered() -> void:
#       CursorManager.set_cursor("res://sprites/UI/cursor/cursor_pointer.png", Vector2(2, 2))
#
#   func _on_confirm_button_mouse_exited() -> void:
#       CursorManager.reset_to_default()
#
# ── CLICK SPARKLES ───────────────────────────────────────────────────────
# BUGFIX: the old constant cursor-trail sparkle wasn't controlled by any
# script anywhere in the project -- almost certainly a CPUParticles2D or
# GPUParticles2D node sitting directly in a scene (Main.tscn or similar)
# with `emitting = true` left on in the editor. Find that node and delete
# it (or flip its Emitting property off in the Inspector) -- this file now
# owns cursor-adjacent effects, and the block below replaces the constant
# trail with a short burst that fires once per click and stops itself
# after CLICK_SPARKLE_DURATION, regardless of the particle settings below.
extends Node

const DEFAULT_CURSOR_PATH: String = "res://sprites/UI/cursor/cursor09_bl.png"
const DEFAULT_CURSOR_HOTSPOT: Vector2 = Vector2(6, 2)  # in ORIGINAL image pixels; tweak once you see it in-game
const CURSOR_SCALE: float = 0.2  # 1/5th size

const CLICK_SPARKLE_DURATION: float = 0.5   # seconds the burst is allowed to be visible
const CLICK_SPARKLE_AMOUNT: int = 16
const CLICK_SPARKLE_COLOR: Color = Color(1.0, 0.92, 0.55, 0.9)   # warm gold, matches the buff/status glow elsewhere

var _click_sparkles: CPUParticles2D = null


func _ready() -> void:
	reset_to_default()
	_setup_click_sparkles()


func set_cursor(path: String, hotspot: Vector2 = Vector2.ZERO, shape: Input.CursorShape = Input.CURSOR_ARROW, scale: float = CURSOR_SCALE) -> void:
	var tex := load(path) as Texture2D
	if tex == null:
		push_warning("CursorManager: could not load cursor texture at '%s'" % path)
		return
	var final_tex: Texture2D = tex
	var final_hotspot: Vector2 = hotspot
	if scale != 1.0:
		var img: Image = tex.get_image()
		if img == null:
			push_warning("CursorManager: '%s' import settings don't allow reading pixels (likely VRAM-compressed) -- using original size. See the note at the top of this file." % path)
		else:
			var new_w: int = max(1, roundi(img.get_width() * scale))
			var new_h: int = max(1, roundi(img.get_height() * scale))
			img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
			final_tex = ImageTexture.create_from_image(img)
			final_hotspot = hotspot * scale
	Input.set_custom_mouse_cursor(final_tex, shape, final_hotspot)


func reset_to_default() -> void:
	set_cursor(DEFAULT_CURSOR_PATH, DEFAULT_CURSOR_HOTSPOT)


func _setup_click_sparkles() -> void:
	# A dedicated, always-on-top CanvasLayer so the burst renders above
	# every scene's own UI/HUD, no matter what scene is currently loaded.
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)

	_click_sparkles = CPUParticles2D.new()
	_click_sparkles.amount = CLICK_SPARKLE_AMOUNT
	_click_sparkles.lifetime = CLICK_SPARKLE_DURATION
	_click_sparkles.one_shot = true
	_click_sparkles.explosiveness = 0.9
	_click_sparkles.emitting = false
	_click_sparkles.direction = Vector2(0, -1)
	_click_sparkles.spread = 180.0
	_click_sparkles.initial_velocity_min = 40.0
	_click_sparkles.initial_velocity_max = 90.0
	_click_sparkles.gravity = Vector2(0, 60)
	_click_sparkles.scale_amount_min = 2.0
	_click_sparkles.scale_amount_max = 4.0
	_click_sparkles.color = CLICK_SPARKLE_COLOR
	layer.add_child(_click_sparkles)


func _input(event: InputEvent) -> void:
	# Uses _input() rather than _unhandled_input() on purpose -- Controls
	# (buttons, etc.) mark mouse-button events as handled once they consume
	# them, so _unhandled_input() would miss clicks on any UI element and
	# only fire for clicks on the bare game world. _input() sees every
	# click no matter what's underneath the cursor.
	if event is InputEventMouseButton and event.pressed:
		_trigger_click_sparkles(event.position)


func _trigger_click_sparkles(at_position: Vector2) -> void:
	if _click_sparkles == null:
		return
	_click_sparkles.global_position = at_position
	_click_sparkles.restart()
	_click_sparkles.emitting = true
	# Belt-and-suspenders: force it off after CLICK_SPARKLE_DURATION no
	# matter what, so "half a second" is exact regardless of how one_shot
	# particle lifetimes behave under the hood.
	get_tree().create_timer(CLICK_SPARKLE_DURATION).timeout.connect(func():
		if is_instance_valid(_click_sparkles):
			_click_sparkles.emitting = false
	)
