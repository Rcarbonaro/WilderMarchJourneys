# res://scripts/ui/level_up_popup.gd
#
# LEVEL UP POPUP -- shown right after a unit levels up (buying a duplicate
# copy of a unit already in the party/bench). Displays the unit's portrait,
# new level, and one column per stat that increased, each showing:
#   - the stat's name (e.g. "ATK")
#   - its new permanent total (e.g. "13")
#   - an animated "+X" that pops in, in that stat's own color, with a burst
#     of matching-colored sparkles shooting outward in every direction
#
# Unlike reward_popup.gd (which auto-fades and can be dismissed by tapping
# outside it), this popup STAYS UP -- the stat list and every "+X" LINGER
# on screen -- until the player explicitly presses the Continue button.
# Tapping outside the card does nothing here on purpose.
#
# HOW TO USE:
#   var popup := LevelUpPopup.new()
#   some_scene_script.add_child(popup)
#   popup.setup(unit_data, new_level, results)
#   # 'results' is the Array returned by LevelUpEngine.perform_level_up() --
#   # see that file for the exact shape.
#   popup.continued.connect(func(): ...)   # optional -- fires right before
#                                          # the popup frees itself

class_name LevelUpPopup
extends CanvasLayer

signal continued

const POPUP_CANVAS_LAYER := 100
# Matches reward_popup.gd's own layer choice, so a level-up popup and a
# purchase-reward popup never fight over stacking order if both somehow
# end up on screen (they shouldn't, but layers are cheap insurance).

const ICON_SIZE := Vector2i(84, 84)

const STAGGER_DELAY: float = 0.18
# Small delay between each stat's reveal animation -- popping every stat in
# at once reads as a single blur; staggering them makes each "+X" and its
# sparkle burst individually readable.

var _root: Control = null
var _card: PanelContainer = null
var _continue_button: Button = null


func _ready() -> void:
	layer = POPUP_CANVAS_LAYER

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# Dim backdrop -- mouse_filter STOP (unlike reward_popup.gd's IGNORE)
	# means clicks anywhere outside the card are simply swallowed instead
	# of being able to close the popup. Only the Continue button can.
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.55)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.16, 0.97)
	style.set_corner_radius_all(10)
	style.border_color = Color(1.0, 0.85, 0.3)   # warm gold frame -- a level-up is always a "big" moment
	style.set_border_width_all(3)
	style.shadow_color = Color(1.0, 0.85, 0.3, 0.35)
	style.shadow_size = 14
	_card.add_theme_stylebox_override("panel", style)
	center.add_child(_card)


func setup(unit_data: UnitData, new_level: int, results: Array) -> void:
	# Builds the popup's content and kicks off the stat reveal animation.
	# Call this once, right after adding this popup to the scene tree.
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	_card.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	if unit_data.portrait != null:
		var portrait_rect := TextureRect.new()
		portrait_rect.custom_minimum_size = Vector2(ICON_SIZE)
		portrait_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		portrait_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		portrait_rect.texture = unit_data.portrait
		vbox.add_child(portrait_rect)

	var title := Label.new()
	title.text = "%s reached Level %d!" % [unit_data.display_name, new_level]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	var stat_row := HBoxContainer.new()
	stat_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stat_row.add_theme_constant_override("separation", 20)
	vbox.add_child(stat_row)

	# Build one column per stat gained. Each "+X" label starts scaled to
	# zero (invisible) so _animate_stat_reveal() below can pop it in one
	# at a time. Everything ELSE (the stat name, its new total) is shown
	# immediately -- only the "+X" itself is animated.
	var reveal_queue: Array = []   # [{ "label": Label, "color": Color }, ...]
	for result in results:
		var stat: String = result.get("stat", "")
		var color: Color = result.get("color", Color.WHITE)

		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER

		var name_label := Label.new()
		name_label.text = LevelUpEngine.STAT_DISPLAY_NAMES.get(stat, stat)
		# (Looked up live from the LevelUpEngine autoload -- not a local
		# const -- so this can never drift out of sync with the stat names
		# it defines.)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.add_theme_font_size_override("font_size", 14)
		col.add_child(name_label)

		var value_label := Label.new()
		value_label.text = _format_stat_value(stat, result.get("new_total", 0.0))
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value_label.add_theme_font_size_override("font_size", 22)
		col.add_child(value_label)

		var plus_label := Label.new()
		plus_label.text = _format_stat_amount(stat, result.get("amount", 0.0))
		plus_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		plus_label.add_theme_font_size_override("font_size", 20)
		plus_label.add_theme_color_override("font_color", color)
		plus_label.scale = Vector2.ZERO   # invisible until its turn in the reveal queue
		col.add_child(plus_label)

		stat_row.add_child(col)
		reveal_queue.append({"label": plus_label, "color": color})

	_continue_button = Button.new()
	_continue_button.text = "Continue"
	_continue_button.disabled = true   # enabled once every stat has finished revealing
	_continue_button.pressed.connect(_on_continue_pressed)
	vbox.add_child(_continue_button)

	_animate_stat_reveal(reveal_queue)


func _format_stat_value(stat: String, value: float) -> String:
	if stat == "crit_chance" or stat == "crit_damage":
		return "%.0f%%" % value
	return str(int(round(value)))


func _format_stat_amount(stat: String, amount: float) -> String:
	if stat == "crit_chance" or stat == "crit_damage":
		return "+%.0f%%" % amount
	return "+%d" % int(round(amount))


func _animate_stat_reveal(reveal_queue: Array) -> void:
	# Pops each "+X" in, one after another, with a matching-colored sparkle
	# burst the instant it appears. Once every stat has revealed, the
	# Continue button becomes pressable -- until then, everything just
	# LINGERS on screen exactly as revealed (nothing here ever fades away
	# or times out on its own).
	for i in range(reveal_queue.size()):
		var entry: Dictionary = reveal_queue[i]
		var label: Label = entry["label"]
		var color: Color = entry["color"]

		await get_tree().create_timer(STAGGER_DELAY).timeout
		if not is_instance_valid(label):
			continue   # popup was closed early somehow -- don't touch a freed node

		# A little "pop past full size, then settle" bounce reads more like
		# a level-up reward than a flat linear scale-in would.
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_BACK)
		tween.set_ease(Tween.EASE_OUT)
		tween.tween_property(label, "scale", Vector2(1.25, 1.25), 0.22)
		tween.tween_property(label, "scale", Vector2(1.0, 1.0), 0.12)

		_spawn_stat_sparkles(label, color)

	if is_instance_valid(_continue_button):
		_continue_button.disabled = false


# ---- SPARKLE PARTICLES ---------------------------------------------------------

var _sparkle_texture_cache: ImageTexture = null

func _get_soft_circle_texture() -> ImageTexture:
	# Same soft-edged-dot trick reward_popup.gd already uses, so these
	# sparkles read as glowing points instead of CPUParticles2D's default
	# hard-edged squares. Cached since every burst uses the identical dot.
	if _sparkle_texture_cache != null:
		return _sparkle_texture_cache
	var diameter := 10
	var image := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var center := Vector2(diameter / 2.0, diameter / 2.0)
	var radius := diameter / 2.0
	for x in diameter:
		for y in diameter:
			var dist: float = Vector2(x + 0.5, y + 0.5).distance_to(center)
			var alpha: float = clamp(1.0 - (dist / radius), 0.0, 1.0)
			image.set_pixel(x, y, Color(1, 1, 1, alpha))
	_sparkle_texture_cache = ImageTexture.create_from_image(image)
	return _sparkle_texture_cache


func _spawn_stat_sparkles(anchor_label: Control, color: Color) -> void:
	# One-shot burst shooting outward in EVERY direction from the "+X"
	# label -- direction = ZERO with spread = 180 is the same "cover the
	# full 360 degrees" trick battle_grid.gd's tether sparkles already use.
	var p := CPUParticles2D.new()
	p.texture = _get_soft_circle_texture()
	p.position = anchor_label.position + anchor_label.size / 2.0
	p.z_index = 50
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 0.9
	p.amount = 18
	p.lifetime = 0.7
	p.randomness = 0.4
	p.direction = Vector2.ZERO
	p.spread = 180.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 60.0
	p.initial_velocity_max = 140.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.4
	p.color = color

	var parent: Node = anchor_label.get_parent()
	if parent == null:
		return
	parent.add_child(p)
	p.emitting = true

	get_tree().create_timer(1.0).timeout.connect(func():
		if is_instance_valid(p):
			p.queue_free()
	)


func _on_continue_pressed() -> void:
	continued.emit()
	queue_free()
