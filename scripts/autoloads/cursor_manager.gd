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
extends Node

const DEFAULT_CURSOR_PATH: String = "res://sprites/UI/cursor/cursor09_bl.png"
const DEFAULT_CURSOR_HOTSPOT: Vector2 = Vector2(6, 2)  # in ORIGINAL image pixels; tweak once you see it in-game
const CURSOR_SCALE: float = 0.2  # 1/5th size


func _ready() -> void:
	reset_to_default()


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
