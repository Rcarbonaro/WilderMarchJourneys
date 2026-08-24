# res://scripts/meta/ending_sequence.gd
#
# ENDING SEQUENCE — plays when the player finishes stage 10 (see
# battle_scene.gd's _on_battle_ended()), replacing the old
# show_game_victory_popup() (which had an off-center layout bug — task 8 —
# and was just a static "Victory!" box). This is a full animated sequence:
# a black backdrop, fog swaying at the bottom of the screen, the WilderMarch
# logo staying on screen throughout, and several lines of text fading in/out
# in sequence below it. (Task 9.)
#
# ── ONE-TIME SETUP (you need to do this once in the Godot editor) ─────────
# This script is NOT paired with a pre-built .tscn in this pass — create the
# scene once, the same way you would for any new screen:
#   1. Godot editor → Scene → New Scene → root node type "Control".
#   2. Rename the root node whatever you like (e.g. "EndingSequence").
#   3. Attach this script to it (drag ending_sequence.gd onto the node, or
#      Scene → Attach Script → browse to this file).
#   4. Select the root Control node → in the Inspector's Layout menu (top
#      toolbar of the 2D viewport) choose "Full Rect" so it fills the screen.
#   5. Save the scene as res://scenes/meta/EndingSequence.tscn (this exact
#      path is what battle_scene.gd's call site expects — see the bottom of
#      this file's comments, or just update that one line if you'd rather
#      save it elsewhere).
#   6. Select the root node again and fill in the exported fields below in
#      the Inspector: at minimum, drag your WilderMarch logo texture (the
#      same image used for the Sprite2D at the bottom of main_menu.tscn) into
#      "Logo Texture". Everything else has a working default.
#
# Nothing else in the project references a node INSIDE this scene by path —
# everything is built procedurally in _ready() below — so you don't need to
# add any child nodes yourself.
#
# ── HOW TO ADJUST TIMING ────────────────────────────────────────────────────
#   fade_in_duration / fade_out_duration — speed of each text block's cross-fade.
#   base_hold_duration — minimum time each block stays fully visible.
#   hold_seconds_per_character — extra hold time added per character in that
#     block's text, so longer paragraphs (like the second one) automatically
#     stay up longer than short ones without you having to hand-tune each.
#   gap_between_blocks — pause between one block fading out and the next
#     fading in.
#   keep_last_text_visible — if true (default), the FINAL text block does not
#     fade out; it stays up (alongside the Return button) instead of ending
#     on an empty screen. Set false to have it fade out like all the others.
#
# ── HOW TO ADJUST THE FOG ───────────────────────────────────────────────────
# The fog is generated ENTIRELY by a shader (res://shaders/cloud_fog.gdshader)
# -- no art asset needed. By default it covers the WHOLE screen with TWO
# layers of motion happening at once: the shader's own internal noise slowly
# churns so the cloud SHAPE billows on its own, while this script separately
# sways the whole thing left and right (see _process()) like a cloud bank
# drifting in a breeze. See that shader file's own header comment for exactly
# how the cloud shapes are generated (fractal noise + a soft threshold).
#   fog_band_height_fraction — how much of the screen's height the fog
#     covers, from the bottom edge upward. 1.0 (default) = the whole
#     screen; lower it (e.g. 0.4) for a band confined to just the bottom.
#   fog_top_fade — how much the TOP of the band fades to transparent.
#     Matters most when fog_band_height_fraction is under 1.0.
#   fog_vertical_squash — how flattened the cloud blobs look. Lower this
#     (e.g. 0.4) if you shrink fog_band_height_fraction back down to a
#     short bottom band, for wide flat puffs instead of round blobs.
#   fog_layer_count — how many overlapping fog layers to blend together.
#     More layers reads as thicker, richer fog, but each extra one is a
#     bit more visual noise. 1-3 usually looks good.
#   fog_sway_amplitude — how many pixels each band drifts left/right from
#     its resting position. Bigger = a wider, more noticeable sway.
#   fog_sway_speed — how fast the back-and-forth motion happens. Bigger =
#     faster swaying, smaller = slower, lazier drifting. Something between
#     0.2 and 0.6 tends to read as natural, cloud-like movement.
#   fog_cloud_scale / fog_density / fog_softness / fog_drift_speed / fog_color
#     — passed straight through to the shader; see cloud_fog.gdshader's own
#     comments for what each one does.
# See _build_fog() / _process() below for how this is actually built and
# animated.
#
# ── HOW TO ADJUST THE SUPPORT LINKS ────────────────────────────────────────
# tip_url / kickstarter_url / discord_url below — leave any blank to hide
# that specific button. They appear starting at the 3rd text block (the one
# that mentions them) and stay visible through the rest of the sequence.
extends Control

const CLOUD_FOG_SHADER := preload("res://shaders/cloud_fog.gdshader")
# Generates the cloud shapes procedurally -- see that file's header comment
# for how it works. Same preload-a-shader pattern already used elsewhere in
# the project for WIND_SWAY_SHADER (battle_grid.gd / unit_node.gd).

@export_group("Content")
@export var logo_texture: Texture2D = null

@export_group("Links (shown from the 3rd text block onward — leave blank to hide)")
@export var tip_url: String = ""
@export var kickstarter_url: String = ""
@export var discord_url: String = ""

@export_group("Timing")
@export var fade_in_duration: float = 1.0
@export var fade_out_duration: float = 0.8
@export var base_hold_duration: float = 2.5
@export var hold_seconds_per_character: float = 0.045
@export var gap_between_blocks: float = 0.4
@export var keep_last_text_visible: bool = true
@export var logo_fade_in_duration: float = 1.5

@export_group("Fog")
@export var fog_layer_count: int = 1
# How many overlapping fog layers to blend together — see the header
# comment above. Layers all share the SAME rectangle at the bottom of the
# screen (see _build_fog() below) so raising this adds richness/texture
# without ever re-introducing the "stacked rows" look. 1 is a clean single
# bar; 2-3 adds a bit more depth if you want it.

@export var fog_band_height_fraction: float = 1.0
# How tall the fog band is, as a fraction of the screen's height (1.0 =
# the entire screen; 0.4 = just the bottom 40%, anchored flush against the
# bottom edge). Anything less than 1.0 leaves the top of the screen clear.

@export var fog_top_fade: float = 0.25
# How much of the band's TOP portion fades to fully transparent, so the
# fog blends softly into whatever's above it instead of ending in a hard
# line. Only really matters when fog_band_height_fraction is well under
# 1.0 (a bottom band fading into clear sky above it) -- with a full-screen
# band you'll likely want this fairly low, or 0 for even coverage
# top-to-bottom.

@export var fog_vertical_squash: float = 1.0
# Passed to the shader's "vertical_squash" -- how flattened the cloud
# blobs look vertically. LOWER (e.g. 0.4) = wide, flat puffs, which suits a
# SHORT band. 1.0 (the default) = natural, unsquashed blobs, which suits a
# TALL or full-screen band -- squashing a tall band the same way a short
# one is squashed stretches the blobs into odd vertical streaks.

@export var fog_sway_amplitude: float = 70.0
# How many pixels each fog layer drifts left and right from its resting
# spot. Bigger number = a wider, more noticeable sway.

@export var fog_sway_speed: float = 0.35
# How fast the back-and-forth motion happens. You don't need to know the
# math behind it (it's fed into sin() as "radians per second") — just know
# that a BIGGER number sways faster, and a SMALLER number sways slower and
# lazier. Somewhere between 0.2 and 0.6 usually looks like natural,
# cloud-like drifting rather than something mechanical.

@export var fog_cloud_scale: float = 8.0
# Passed to the shader's "cloud_scale" -- bigger number = smaller, more
# numerous cloud blobs. Smaller number = fewer, larger, puffier blobs.

@export var fog_density: float = 0.55
# Passed to the shader's "density" -- how much of each band is covered in
# visible cloud vs. empty gaps. Higher = thicker, more solid-looking fog.

@export var fog_softness: float = 0.35
# Passed to the shader's "softness" -- how feathered each cloud blob's edge
# looks. Higher = softer/more diffuse edges, lower = more defined puffs.

@export var fog_drift_speed: float = 0.05
# Passed to the shader's "drift_speed" -- how fast the cloud SHAPE itself
# slowly churns/billows on its own, separate from the whole band's
# left-right sway below. Keep this low; a little goes a long way.

@export var fog_color: Color = Color(0.85, 0.87, 0.9, 1.0)
# Base tint for the fog. Default is a pale, slightly cool white-gray.

@export_group("Colors")
@export var backdrop_color: Color = Color(0, 0, 0, 1)
@export var text_color: Color = Color(0.95, 0.95, 0.92, 1.0)

# The exact copy from the brief, in order. Edit this array directly to
# change wording/order/number of blocks — nothing else needs to change.
var text_blocks: Array[String] = [
	"The refugees are safe, for now…\nCongratulations on completing the Early Release WilderMarch Demo!",
	"Hope you enjoyed this early WilderMarch Demo!\nThe full game is planned to have more characters, customizable skills, encounters, more items and more unique items\nMore enemies, more biomes, more bosses, and unique combats, \nAchievements, unlockables, meta customizability, and 2 variations of endless modes!",
	"If you would like to follow this project,\nplease join our Discord!",
	"We hope to see you when the full game releases!",
]

const LINKS_VISIBLE_FROM_BLOCK_INDEX: int = 2   # 0-based -- index 2 is the 3rd block.

var _text_label: Label = null
var _logo_rect: TextureRect = null
var _links_row: HBoxContainer = null
var _return_button: Button = null

var _fog_layers: Array = []
# One Dictionary per fog band, each holding everything _process() needs to
# animate that band's sway: {"node": Control, "speed": float,
# "amplitude": float, "base_x": float, "phase": float}. Filled in by
# _build_fog() below.

var _fog_time: float = 0.0
# Counts upward every frame (see _process()). We feed this into sin() to
# make the fog sway back and forth smoothly over time, instead of having to
# manually track "am I currently moving left or right" as separate state.


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_build_backdrop()
	_build_fog()
	_build_content()

	_run_sequence()


func _process(delta: float) -> void:
	# Sways each fog layer gently left and right, like a cloud drifting in
	# a breeze, instead of scrolling continuously off in one direction.
	_fog_time += delta
	for layer_data in _fog_layers:
		var layer: Control = layer_data["node"]
		var wave: float = _sway_wave(_fog_time * layer_data["speed"], layer_data["phase"])
		layer.position.x = layer_data["base_x"] + wave * layer_data["amplitude"]


func _sway_wave(t: float, phase: float) -> float:
	# A single sin() wave technically never "stops" -- but simple harmonic
	# motion like that moves FASTEST through the middle of its swing and
	# slows all the way to zero speed at each extreme before reversing, so
	# it visibly LOOKS like it's pausing there for a moment. That dead spot
	# is very noticeable because it happens at the exact same two points,
	# every single cycle.
	#
	# The fix: sum a few sine waves at different (deliberately not-evenly-
	# related) frequencies and phases instead of just one. Each term still
	# individually slows to zero at ITS OWN turning points, but those
	# moments essentially never line up across all three terms at once --
	# so whenever one wave is momentarily stalled, at least one of the
	# others is still moving, and the combined result never visibly stops.
	# The weights (0.55/0.30/0.15) add up to 1.0 so the overall swing still
	# stays close to the "amplitude" you dialed in.
	return (
		0.55 * sin(t * 1.0 + phase)
		+ 0.30 * sin(t * 2.3 + phase * 1.7)
		+ 0.15 * sin(t * 0.6 + phase * 2.4)
	)


# ── BUILD: BACKDROP ─────────────────────────────────────────────────────────
func _build_backdrop() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = backdrop_color
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)


# ── BUILD: FOG ───────────────────────────────────────────────────────────────
func _build_fog() -> void:
	var vp_size: Vector2 = get_viewport_rect().size

	var fog_container := Control.new()
	fog_container.name = "FogContainer"
	fog_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	fog_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Clips anything inside this container to the screen's bounds, so a fog
	# layer swaying rightward never visibly pokes out past the edge of the
	# screen mid-sway.
	fog_container.clip_contents = true
	add_child(fog_container)

	# ── ONE SHARED RECTANGLE FOR EVERY LAYER ─────────────────────────────
	# band_height and y_pos are computed ONCE, here, outside the loop below
	# -- every layer gets the EXACT SAME rectangle at the bottom of the
	# screen. This is what makes multiple layers blend into one cohesive
	# bank of fog instead of reading as separate stacked rows: previously
	# these were recalculated PER LAYER using "depth_t", which spread each
	# layer to a different height/position -- that's what was causing the
	# multiple-rows look, since each layer is its own rectangle with its
	# own independent top-edge fade, so you'd see a seam wherever one
	# layer's rectangle ended and the next began.
	var band_height: float = vp_size.y * fog_band_height_fraction
	var y_pos: float = vp_size.y - band_height

	for i in range(max(1, fog_layer_count)):
		# Layers further back (higher i) sway a bit slower, drift a
		# smaller distance, and are more transparent -- with every layer
		# now sharing the same rectangle, this is the ONLY thing that
		# distinguishes them, which reads as extra texture/depth rather
		# than a visible seam.
		var depth_t: float = float(i) / float(max(1, fog_layer_count - 1))
		var speed: float = fog_sway_speed * lerp(1.0, 0.5, depth_t)
		var amplitude: float = fog_sway_amplitude * lerp(1.0, 0.6, depth_t)
		var alpha: float = lerp(0.35, 0.14, depth_t)

		# Make the band noticeably WIDER than the screen so that when it
		# sways left or right by up to "amplitude" pixels, fog still covers
		# the ENTIRE width of the screen the whole time -- no empty gap of
		# backdrop ever peeks through at either edge mid-sway.
		var layer_width: float = vp_size.x + amplitude * 2.0 + 40.0
		var resting_x: float = -(layer_width - vp_size.x) / 2.0   # centers the oversized band on screen

		var layer := Control.new()
		layer.name = "FogLayer%d" % i
		layer.position = Vector2(resting_x, y_pos)
		layer.size = Vector2(layer_width, band_height)
		fog_container.add_child(layer)

		# The actual cloud shape is 100% generated by the shader below --
		# this ColorRect is just a blank canvas for it to draw onto. Its
		# own .color doesn't matter (the shader overwrites COLOR itself),
		# it just needs to exist and fill the "layer" Control's full rect.
		var piece := ColorRect.new()
		piece.color = Color.WHITE
		piece.set_anchors_preset(Control.PRESET_FULL_RECT)
		piece.mouse_filter = Control.MOUSE_FILTER_IGNORE

		# Each layer gets its OWN ShaderMaterial instance (not one shared
		# resource) since every layer wants different values -- a shared
		# material would mean setting a parameter on one layer changes it
		# for ALL of them, since they'd all be pointing at the same object.
		var fog_material := ShaderMaterial.new()
		fog_material.shader = CLOUD_FOG_SHADER
		# randf_range() on cloud_scale gives each layer a slightly
		# different blob size, so they don't all look like identical
		# copies stamped on top of each other.
		fog_material.set_shader_parameter("cloud_scale", fog_cloud_scale * randf_range(0.85, 1.15))
		fog_material.set_shader_parameter("density", fog_density)
		fog_material.set_shader_parameter("softness", fog_softness)
		# Layers further back churn a little slower, matching how they
		# also sway slower/less in _process() below -- reinforces the
		# "further away = calmer" depth illusion.
		fog_material.set_shader_parameter("drift_speed", fog_drift_speed * lerp(1.0, 0.5, depth_t))
		fog_material.set_shader_parameter("vertical_squash", fog_vertical_squash)
		fog_material.set_shader_parameter("cloud_color", fog_color)
		fog_material.set_shader_parameter("opacity", alpha)
		fog_material.set_shader_parameter("top_fade", fog_top_fade)
		piece.material = fog_material

		layer.add_child(piece)

		# A random starting phase means each layer begins its back-and-forth
		# sway at a different point along the wave -- so all layers don't
		# swing in perfect unison like one rigid slab of fog, which would
		# look far less like natural, drifting clouds.
		var phase: float = randf() * TAU

		_fog_layers.append({
			"node": layer,
			"speed": speed,
			"amplitude": amplitude,
			"base_x": resting_x,
			"phase": phase,
		})


# ── BUILD: LOGO + TEXT + LINKS + RETURN BUTTON ──────────────────────────────
func _build_content() -> void:
	var center := CenterContainer.new()
	center.name = "ContentCenter"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.name = "ContentVBox"
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 28)
	center.add_child(vbox)

	_logo_rect = TextureRect.new()
	_logo_rect.name = "Logo"
	_logo_rect.texture = logo_texture
	_logo_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_logo_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo_rect.custom_minimum_size = Vector2(320, 0)
	_logo_rect.modulate.a = 0.0
	_logo_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_logo_rect)

	_text_label = Label.new()
	_text_label.name = "SequenceText"
	_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.custom_minimum_size = Vector2(760, 0)
	_text_label.add_theme_font_size_override("font_size", 22)
	_text_label.add_theme_color_override("font_color", text_color)
	_text_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_text_label.add_theme_constant_override("outline_size", 4)
	_text_label.modulate.a = 0.0
	_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_text_label)

	_links_row = HBoxContainer.new()
	_links_row.name = "LinksRow"
	_links_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_links_row.add_theme_constant_override("separation", 16)
	_links_row.modulate.a = 0.0
	_links_row.visible = false
	vbox.add_child(_links_row)

	if tip_url != "":
		_links_row.add_child(_make_link_button("Leave a Tip", tip_url))
	if kickstarter_url != "":
		_links_row.add_child(_make_link_button("Kickstarter", kickstarter_url))
	if discord_url != "":
		_links_row.add_child(_make_link_button("Join our Discord", discord_url))

	_return_button = Button.new()
	_return_button.name = "ReturnButton"
	_return_button.text = "Return to Main Menu"
	_return_button.custom_minimum_size = Vector2(240, 50)
	_return_button.modulate.a = 0.0
	_return_button.visible = false
	_return_button.pressed.connect(_on_return_pressed)
	vbox.add_child(_return_button)


func _make_link_button(label: String, url: String) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(func(): OS.shell_open(url))
	return button


# ── SEQUENCE PLAYBACK ────────────────────────────────────────────────────────
func _run_sequence() -> void:
	var logo_tween := create_tween()
	logo_tween.tween_property(_logo_rect, "modulate:a", 1.0, logo_fade_in_duration)

	for i in range(text_blocks.size()):
		var text: String = text_blocks[i]
		var is_last: bool = i == text_blocks.size() - 1
		var hold_time: float = base_hold_duration + text.length() * hold_seconds_per_character

		_text_label.text = text

		var in_tween := create_tween()
		in_tween.tween_property(_text_label, "modulate:a", 1.0, fade_in_duration)
		await in_tween.finished

		if i >= LINKS_VISIBLE_FROM_BLOCK_INDEX and _links_row.get_child_count() > 0 and not _links_row.visible:
			_links_row.visible = true
			var links_tween := create_tween()
			links_tween.tween_property(_links_row, "modulate:a", 1.0, fade_in_duration)

		await get_tree().create_timer(hold_time).timeout

		if is_last and keep_last_text_visible:
			break   # Leave the final line on screen instead of fading it out.

		var out_tween := create_tween()
		out_tween.tween_property(_text_label, "modulate:a", 0.0, fade_out_duration)
		await out_tween.finished

		await get_tree().create_timer(gap_between_blocks).timeout

	_return_button.visible = true
	var button_tween := create_tween()
	button_tween.tween_property(_return_button, "modulate:a", 1.0, fade_in_duration)


func _on_return_pressed() -> void:
	# "fade" — matches every other transition in/out of the main menu (see
	# main_menu.gd / game_mode_select.gd's MAIN_MENU_SCENE_PATH call sites).
	SceneTransitions.change_scene("res://scenes/mainmenu/main_menu.tscn", "fade")
