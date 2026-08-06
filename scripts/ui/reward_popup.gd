# res://scripts/ui/reward_popup.gd
#
# REWARD POPUP -- a small, self-sizing popup shown whenever the player gets
# something new: buying from the shop, receiving a reward from an encounter,
# forging a new item, or collecting gold at the end of a stage. It shows an
# icon/portrait (optional) + a description, plus 1-2 action buttons -- and
# it's wrapped in a color-coded "glitter" effect: a one-shot burst of
# particles shoots outward in all directions from the popup's own border the
# instant it appears, then a subtler ongoing sparkle keeps tracing the
# border for as long as the popup stays open. Gold (thick_glitter) popups
# additionally get a soft, slowly-breathing golden glow around the border.
#
# WHY THIS IS A CanvasLayer, NOT A PLAIN Control: every caller of this popup
# (shop_manager.gd, encounter_scene.gd, deployment_manager.gd) is a Node2D
# scene root, and a plain Control childed under a Node2D still inherits that
# Node2D's own canvas transform -- so if the calling scene's root (or any of
# its ancestors) ever sits somewhere other than exactly (0,0), a plain
# full-rect Control popup would drift off-true-center right along with it.
# CanvasLayer resets that inherited transform and always draws in true,
# fixed SCREEN space, so this popup is guaranteed to land dead-center on the
# actual viewport no matter which scene/node adds it as a child.
#
# WHY THIS IS ITS OWN FILE: the shop (buying an item/unit), encounters
# (choice rewards), forging, and the gold-at-end-of-stage reward all need
# basically the same "here's what you got" popup -- just with a different
# glitter color, optional icon, and different buttons. Rather than build
# this 4 times, every caller just instantiates THIS class.
#
# HOW TO USE IT:
#   var popup := RewardPopup.new()
#   some_scene_script.add_child(popup)   # any node works -- see note above
#   popup.setup(
#       icon_or_portrait_texture,   # Texture2D, or null to skip the icon entirely
#       description_text,           # String, can be ""
#       glitter_color,               # Color -- e.g. Color(0.3, 0.6, 1.0) for blue
#       [
#           {"text": "Close", "callback": Callable()},
#           {"text": "More Information", "callback": func(): ... },
#       ],
#       thick_glitter,   # optional bool, default false -- true = denser/bigger
#                        # burst + ambient sparkle, PLUS a slowly-breathing
#                        # glow around the border. Used for the forging
#                        # popup's gold effect.
#   )
#
# Every button's callback (if valid) runs, and THEN the popup closes itself --
# callers never need to call close() by hand. Pass an empty Callable()
# for a plain button that should just dismiss the popup and do nothing else.
# Passing an empty 'buttons' array is fine too (no button row is built).

class_name RewardPopup
extends CanvasLayer

signal closed

const ICON_SIZE := Vector2i(96, 96)
# Size of the icon/portrait image shown at the top of the popup, when one
# is provided (icon == null skips this area entirely -- see the gold-only
# "Obtained X gold" popup, which has no icon).

const DESCRIPTION_MAX_WIDTH := 260.0
# Description text wraps at this width so a long description doesn't make
# the popup absurdly wide -- it still only grows as TALL as it needs to.

const POPUP_CANVAS_LAYER := 100
# High enough to draw above every normal in-scene CanvasItem/CanvasLayer
# without needing to know what layer (if any) each calling scene already
# uses for its own UI.

var _root: Control = null
var _card: PanelContainer = null
var _card_style: StyleBoxFlat = null
var _glitter_color: Color = Color(0.3, 0.6, 1.0)
var _glitter_thick: bool = false
var _glow_tween: Tween = null


func _ready() -> void:
	layer = POPUP_CANVAS_LAYER

	# Everything below lives under this ONE full-rect Control, which is what
	# actually gets positioned/sized -- CanvasLayer itself has no rect of
	# its own to anchor.
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# ── DIM BACKDROP ───────────────────────────────────────────────────────
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.45)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(backdrop)

	# ── AUTO-CENTERING, AUTO-SIZING WRAPPER ────────────────────────────────
	# A CenterContainer always centers its child AND sizes itself around
	# that child's natural ("as small as needed") size -- so we get both
	# "dead-center on screen" and "wrapped snugly around the content" for
	# free, with no manual size math anywhere in this script.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_STOP   # Clicks on the card never close it.
	center.add_child(_card)


func setup(icon: Texture2D, description: String, glitter_color: Color,
		buttons: Array, thick_glitter: bool = false) -> void:
	# Builds the popup's actual content. Call this once, right after adding
	# this popup to the scene tree (so _ready() has already built the shell
	# above).
	_glitter_color = glitter_color
	_glitter_thick = thick_glitter

	_apply_border_style()

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	_card.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# ── ICON / PORTRAIT (skipped entirely if none was given) ───────────────
	if icon != null:
		var icon_rect := TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(ICON_SIZE)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		icon_rect.texture = icon
		vbox.add_child(icon_rect)

	# ── DESCRIPTION ───────────────────────────────────────────────────────
	if description != "":
		var desc_label := Label.new()
		desc_label.text = description
		desc_label.custom_minimum_size = Vector2(DESCRIPTION_MAX_WIDTH, 0)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if icon == null:
			# No icon means this description IS the headline (e.g. "Obtained
			# 40 gold") -- give it a bit more presence.
			desc_label.add_theme_font_size_override("font_size", 20)
		vbox.add_child(desc_label)

	# ── BUTTONS ───────────────────────────────────────────────────────────
	if not buttons.is_empty():
		var button_row := HBoxContainer.new()
		button_row.alignment = BoxContainer.ALIGNMENT_CENTER
		button_row.add_theme_constant_override("separation", 10)
		vbox.add_child(button_row)

		for button_def in buttons:
			var btn := Button.new()
			btn.text = button_def.get("text", "")
			# Capture the callback in a local so each button's closure gets
			# ITS OWN callback, not whichever one happened to be last in the
			# loop.
			var callback: Callable = button_def.get("callback", Callable())
			btn.pressed.connect(func():
				if callback.is_valid():
					callback.call()
				_close()
			)
			button_row.add_child(btn)

	# The card's REAL size isn't known until Godot finishes laying out
	# everything we just added -- wait a couple frames before measuring it
	# for the particle effect below, or size.x/size.y would still read 0.
	_spawn_glitter()


# ── BORDER STYLE (tinted border + gold's breathing glow) ────────────────────

func _apply_border_style() -> void:
	_card_style = StyleBoxFlat.new()
	_card_style.bg_color = Color(0.12, 0.12, 0.15, 0.96)
	_card_style.set_corner_radius_all(8)
	_card_style.border_color = _glitter_color
	_card_style.set_border_width_all(3 if not _glitter_thick else 5)

	# "shadow" here is a soft colored halo bleeding out past the border --
	# used as the actual glow, not a drop-shadow in the usual sense.
	_card_style.shadow_color = Color(_glitter_color.r, _glitter_color.g, _glitter_color.b,
			0.35 if not _glitter_thick else 0.7)
	_card_style.shadow_size = 8 if not _glitter_thick else 22

	_card.add_theme_stylebox_override("panel", _card_style)

	if _glitter_thick:
		# Gold gets a slow, ongoing "breathing" glow on top of the static
		# halo above -- the glow visibly pulses for as long as the popup
		# stays open, on top of the particle sparkle.
		_glow_tween = create_tween()
		_glow_tween.set_loops()
		_glow_tween.tween_property(_card_style, "shadow_size", 34, 1.0).set_trans(Tween.TRANS_SINE)
		_glow_tween.tween_property(_card_style, "shadow_size", 20, 1.0).set_trans(Tween.TRANS_SINE)


# ── GLITTER EFFECT ──────────────────────────────────────────────────────────
# Two layers, both built the same way (4 particle emitters, one per edge of
# the card, each shooting/drifting AWAY from that edge, with a wide spread
# so the four together read as "outward in every direction" rather than
# just 4 narrow beams):
#   1. A one-shot BURST that fires the instant the popup appears and lasts
#      about 1 second before disappearing.
#   2. A continuous, gentler AMBIENT sparkle that keeps going the whole
#      time the popup is open, so the border never looks static.

func _spawn_glitter() -> void:
	await get_tree().process_frame
	if not is_instance_valid(_card):
		return   # Popup was closed again before layout even finished.
	_spawn_burst()
	_spawn_ambient()


func _get_soft_circle_texture() -> ImageTexture:
	# A small soft-edged dot so particles read as "sparkles" instead of
	# hard-edged squares (CPUParticles2D draws plain squares with no
	# texture set).
	var diameter := 10
	var image := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var center := Vector2(diameter / 2.0, diameter / 2.0)
	var radius := diameter / 2.0
	for x in diameter:
		for y in diameter:
			var dist: float = Vector2(x + 0.5, y + 0.5).distance_to(center)
			var alpha: float = clamp(1.0 - (dist / radius), 0.0, 1.0)
			image.set_pixel(x, y, Color(1, 1, 1, alpha))
	return ImageTexture.create_from_image(image)


func _make_edge_emitter(edge_size: Vector2, spawn_pos: Vector2, direction: Vector2,
		one_shot: bool, amount: int, speed_min: float, speed_max: float,
		scale_max: float, spread_degrees: float) -> CPUParticles2D:
	# Builds ONE particle emitter positioned along a single edge of the card,
	# shooting/drifting in 'direction' (straight away from that edge), fanned
	# out across 'spread_degrees' so it covers a wide arc rather than a
	# narrow beam. Shared by both the burst and the ambient sparkle below --
	# only the amount/speed/one_shot numbers differ between the two.
	var p := CPUParticles2D.new()
	p.texture = _get_soft_circle_texture()
	p.position = spawn_pos
	p.emitting = false
	p.one_shot = one_shot
	p.explosiveness = 0.8 if one_shot else 0.0
	p.amount = amount
	p.lifetime = 1.0 if one_shot else 0.9
	p.randomness = 0.3 if one_shot else 0.7
	# EMISSION_SHAPE_RECTANGLE spreads spawn points across the whole edge
	# (not just its center point), so the burst/sparkle covers the full
	# length of that border, not just one spot on it.
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = edge_size / 2.0
	p.direction = direction
	p.spread = spread_degrees
	p.gravity = Vector2.ZERO   # Pure outward motion -- no drift from gravity.
	p.initial_velocity_min = speed_min
	p.initial_velocity_max = speed_max
	p.scale_amount_min = 1.0
	p.scale_amount_max = scale_max
	p.color = _glitter_color
	return p


func _spawn_burst() -> void:
	# One-shot: shoots outward in all directions from all 4 borders (a wide
	# ~110-degree spread per edge means the 4 edges' arcs overlap near the
	# corners, covering the full 360 degrees around the popup), then the
	# whole group frees itself about 1 second later once the particles
	# have finished.
	var size: Vector2 = _card.size
	var amount: int = 16 if not _glitter_thick else 30
	var scale_max: float = 3.0 if not _glitter_thick else 5.0

	var burst_group := Node2D.new()
	_card.add_child(burst_group)

	burst_group.add_child(_make_edge_emitter(
		Vector2(size.x, 4), Vector2(size.x / 2.0, 0), Vector2(0, -1),
		true, amount, 90.0, 180.0, scale_max, 110.0))
	burst_group.add_child(_make_edge_emitter(
		Vector2(size.x, 4), Vector2(size.x / 2.0, size.y), Vector2(0, 1),
		true, amount, 90.0, 180.0, scale_max, 110.0))
	burst_group.add_child(_make_edge_emitter(
		Vector2(4, size.y), Vector2(0, size.y / 2.0), Vector2(-1, 0),
		true, amount, 90.0, 180.0, scale_max, 110.0))
	burst_group.add_child(_make_edge_emitter(
		Vector2(4, size.y), Vector2(size.x, size.y / 2.0), Vector2(1, 0),
		true, amount, 90.0, 180.0, scale_max, 110.0))

	for child in burst_group.get_children():
		child.emitting = true

	get_tree().create_timer(1.3).timeout.connect(func():
		if is_instance_valid(burst_group):
			burst_group.queue_free()
	)


func _spawn_ambient() -> void:
	# Continuous, gentler sparkle that just keeps going -- these are added
	# directly as children of _card, so they're freed automatically
	# whenever the popup itself closes (no manual cleanup needed).
	var size: Vector2 = _card.size
	var scale_max: float = 2.0 if not _glitter_thick else 3.4
	var amount: int = 10 if not _glitter_thick else 20

	var ambient_emitters := [
		_make_edge_emitter(Vector2(size.x, 4), Vector2(size.x / 2.0, 0), Vector2(0, -1),
			false, amount, 4.0, 14.0, scale_max, 60.0),
		_make_edge_emitter(Vector2(size.x, 4), Vector2(size.x / 2.0, size.y), Vector2(0, 1),
			false, amount, 4.0, 14.0, scale_max, 60.0),
		_make_edge_emitter(Vector2(4, size.y), Vector2(0, size.y / 2.0), Vector2(-1, 0),
			false, amount, 4.0, 14.0, scale_max, 60.0),
		_make_edge_emitter(Vector2(4, size.y), Vector2(size.x, size.y / 2.0), Vector2(1, 0),
			false, amount, 4.0, 14.0, scale_max, 60.0),
	]
	for p in ambient_emitters:
		_card.add_child(p)
		p.emitting = true


func _close() -> void:
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	closed.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		# Tapping outside the card closes the popup, same convention as
		# UnitInfoPopup.
		if not _card.get_global_rect().has_point(event.position):
			_close()
			get_viewport().set_input_as_handled()
