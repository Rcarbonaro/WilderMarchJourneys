# res://scripts/intro/text_crawl_scene.gd
#
# TEXT CRAWL SCENE -- shown once, right when a new run begins (see
# game_mode_select.gd's _start_random_run()/_start_draft_run(), which now
# route here first instead of going straight to the tarot-pick/draft scene).
#
# One paragraph is shown at a time. Each stays up for
# CRAWL_SECONDS_PER_PARAGRAPH seconds before auto-advancing -- unless the
# player presses "Next" (jumps to the next paragraph immediately) or "Skip"
# (ends the WHOLE crawl immediately).
#
# ── FOG (ADDED) ──────────────────────────────────────────────────────────
# A band of cloud-like fog gently sways back and forth, covering the whole
# screen by default, built the same way as the one in ending_sequence.gd
# (see that file's header comment, and res://shaders/cloud_fog.gdshader's
# own header comment, for the full "why" behind how the cloud shapes
# themselves are generated). The difference here is that fog is only shown
# for SOME paragraphs, not the whole scene -- each entry in PARAGRAPHS below
# has its own optional "fog" true/false flag (see that array's comment), and
# _show_paragraph() just flips the whole fog container's visibility on/off
# to match whichever paragraph is currently showing.

extends Control

const CRAWL_SECONDS_PER_PARAGRAPH := 30.0

const CLOUD_FOG_SHADER := preload("res://shaders/cloud_fog.gdshader")
# Generates the cloud shapes procedurally -- no art asset needed. See that
# file's header comment for how it works.

@export_group("Fog")
@export var fog_layer_count: int = 1
# How many overlapping fog layers to blend together. Layers all share the
# SAME rectangle (see _build_fog() below) so raising this adds
# richness/texture without ever causing a "stacked rows" look. 1 is a
# clean single bar; 2-3 adds a bit more depth if you want it.

@export var fog_band_height_fraction: float = 1.0
# How tall the fog band is, as a fraction of the screen's height (1.0 =
# the entire screen; 0.4 = just the bottom 40%, anchored flush against the
# bottom edge). Anything less than 1.0 leaves the top of the screen clear.

@export var fog_top_fade: float = 0.25
# How much of the band's TOP portion fades to fully transparent, so the fog
# blends softly into whatever's above it instead of ending in a hard line.
# Only really matters when fog_band_height_fraction is well under 1.0 (a
# bottom band fading into clear space above it) -- with a full-screen band
# you'll likely want this fairly low, or 0 for even coverage top-to-bottom.

@export var fog_vertical_squash: float = 1.0
# Passed to the shader's "vertical_squash" -- how flattened the cloud blobs
# look vertically. LOWER (e.g. 0.4) = wide, flat puffs, which suits a SHORT
# band. 1.0 (the default) = natural, unsquashed blobs, which suits a TALL
# or full-screen band -- squashing a tall band the same way a short one is
# squashed stretches the blobs into odd vertical streaks.

@export var fog_sway_amplitude: float = 50.0
# How many pixels each fog layer drifts left and right from its resting
# spot. Bigger number = a wider, more noticeable sway.

@export var fog_sway_speed: float = 0.3
# How fast the back-and-forth motion happens (fed into sin() as "radians
# per second" -- you don't need to know what that means to tune it). Bigger
# number = faster swaying, smaller number = slower, lazier drifting.
# Somewhere between 0.2 and 0.6 tends to read as natural cloud movement.

@export var fog_cloud_scale: float = 8.0
# Passed to the shader's "cloud_scale" -- bigger number = smaller, more
# numerous cloud blobs. Smaller number = fewer, larger, puffier blobs.

@export var fog_density: float = 0.5
# Passed to the shader's "density" -- how much of each band is covered in
# visible cloud vs. empty gaps. Higher = thicker, more solid-looking fog.

@export var fog_softness: float = 0.35
# Passed to the shader's "softness" -- how feathered each cloud blob's edge
# looks. Higher = softer/more diffuse edges, lower = more defined puffs.

@export var fog_drift_speed: float = 0.05
# Passed to the shader's "drift_speed" -- how fast the cloud SHAPE itself
# slowly churns/billows on its own, separate from the whole band's
# left-right sway. Keep this low; a little goes a long way.

@export var fog_color: Color = Color(0.85, 0.87, 0.9, 1.0)
# Base tint for the fog. Default is a pale, slightly cool white-gray.

# One entry per paragraph, in order. "background" is OPTIONAL -- leave it out
# (or use "") for the plain black default background (see BackgroundImage,
# which just stays hidden in that case and lets the black ColorRect behind
# it show through). ParagraphLabel wraps long lines automatically.
#
# "fog" is also OPTIONAL, and controls whether the swaying fog band at the
# bottom of the screen is shown while THIS paragraph is up. Leave it out (or
# set it to true) to show fog by default -- set it explicitly to false for
# a paragraph that shouldn't have it, e.g. one with its own busier
# background art where fog would just be visual clutter.
const PARAGRAPHS: Array[Dictionary] = [
	{ "text": "Long ago, Elyndra's Prophecy warned about The Thrice-Forsaken Hour, an apocalyptic ushering in the Last Days. It was said that if we remained faithful, Elyndra would appear in the Last Days to save us. For many years, the Inari fought hard to keep Elyndra's tenants, believing their brutal piety would save the world…" },
	{ "text": "However, as the Rodescian Empire grew in strength, the Inari could not stand against them. The influence of the Inari and Elyndra’s prophecy quickly dwindled as the Rodescians became seen as the primary existential threat to the East…" },
	{ "text": "It was a day like any other in the port city of Epissis. Still recovering from fighting off the Rodescians siege four months prior, the city was caught off guard when a massive creature arose from the depths. The city's bells rang within moments of its arrival, but emergency responses were accustomed to siege warfare, not something of this magnitude…",},
	{ "text": "Its steps alone shook the earth beneath us, the tremors collapsing buildings before the beast even reached them. It’s devastating roar devastated the citizens, masses collapsing in the streets. The only survivors were those whose first instinct was to flee the walls…"},
	{ "text": "You soon found yourself among a small group of survivors, who formed a small caravan to travel east, hoping to make their way to the desert fortress-city Saulimar, where you hoped to make refuge. They look to you for guidance, for refuge. Their protection has fallen onto your shoulders. You must lead the few fighters who remain, and carve a safe path until we can arrive at Saulimar, the city that will save us."},
	{ "text": "Traveler, I trust in you. I believe that you can lead us to safety. Together, we will bend the will of fate.",  "background": "res://sprites/UI/tarot/tarot_pick_background.png" },

]


@onready var paragraph_label:  Label       = $ParagraphLabel
@onready var next_button:      Button      = $ButtonRow/NextButton
@onready var skip_button:      Button      = $ButtonRow/SkipButton
@onready var advance_timer:    Timer       = $AdvanceTimer
@onready var background_image: TextureRect = $BackgroundImage

var _index: int = 0

var _fog_container: Control = null
# The parent node holding all the fog bands. _show_paragraph() toggles this
# node's "visible" on/off per-paragraph -- see the "fog" key on PARAGRAPHS.

var _fog_layers: Array = []
# One Dictionary per fog band, each holding everything _process() needs to
# animate that band's sway: {"node": Control, "speed": float,
# "amplitude": float, "base_x": float, "phase": float}. Filled in by
# _build_fog() below.

var _fog_time: float = 0.0
# Counts upward every frame the fog is visible (see _process()). Fed into
# sin() to make the fog sway back and forth smoothly over time, instead of
# needing to manually track "am I moving left or right right now" by hand.


func _ready() -> void:
	next_button.pressed.connect(_on_next_pressed)
	skip_button.pressed.connect(_on_skip_pressed)
	advance_timer.one_shot = true
	advance_timer.timeout.connect(_on_timer_timeout)
	_build_fog()
	_show_paragraph(0)


func _process(delta: float) -> void:
	# Only bother animating the sway while the fog is actually visible for
	# the CURRENT paragraph (see the "fog" toggle in _show_paragraph()
	# below) -- no sense doing this math every frame while it's hidden.
	if _fog_container == null or not _fog_container.visible:
		return
	_fog_time += delta
	for layer_data in _fog_layers:
		var layer: Control = layer_data["node"]
		var wave: float = _sway_wave(_fog_time * layer_data["speed"], layer_data["phase"])
		layer.position.x = layer_data["base_x"] + wave * layer_data["amplitude"]


func _sway_wave(t: float, phase: float) -> float:
	# A single sin() wave technically never "stops" -- but simple harmonic
	# motion like that moves FASTEST through the middle of its swing and
	# slows all the way to zero speed at each extreme before reversing, so
	# it visibly LOOKS like it's pausing there for a moment, at the same
	# two points every cycle.
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


# ── FOG (bottom-of-screen, back-and-forth sway) ─────────────────────────────
# Built ONCE up front, the same way ending_sequence.gd builds its fog -- each
# paragraph just shows/hides this whole container rather than rebuilding it
# from scratch every time (see _show_paragraph()).
func _build_fog() -> void:
	var vp_size: Vector2 = get_viewport_rect().size

	_fog_container = Control.new()
	_fog_container.name = "FogContainer"
	_fog_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fog_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Clips anything inside to the screen's bounds, so a band swaying
	# rightward never visibly pokes out past the edge of the screen.
	_fog_container.clip_contents = true
	add_child(_fog_container)

	# Slot the fog in right above the background art, but still BELOW the
	# paragraph text and buttons -- so the fog rolls in behind the words on
	# screen instead of drawing over top of them and making them hard to read.
	move_child(_fog_container, background_image.get_index() + 1)

	# ── ONE SHARED RECTANGLE FOR EVERY LAYER ─────────────────────────────
	# band_height and y_pos are computed ONCE, here, outside the loop below
	# -- every layer gets the EXACT SAME rectangle at the bottom of the
	# screen, so multiple layers blend into one cohesive bank of fog
	# instead of reading as separate stacked rows (which is what happened
	# before, when these were recalculated PER LAYER at a different
	# height/position each time).
	var band_height: float = vp_size.y * fog_band_height_fraction
	var y_pos: float = vp_size.y - band_height

	for i in range(max(1, fog_layer_count)):
		# Layers further back (higher i) sway a bit slower, drift a
		# smaller distance, and are more transparent -- with every layer
		# sharing the same rectangle, this is the ONLY thing that tells
		# them apart, which reads as extra texture rather than a seam.
		var depth_t: float = float(i) / float(max(1, fog_layer_count - 1))
		var speed: float = fog_sway_speed * lerp(1.0, 0.5, depth_t)
		var amplitude: float = fog_sway_amplitude * lerp(1.0, 0.6, depth_t)
		var alpha: float = lerp(0.32, 0.12, depth_t)

		# Wider than the screen so swaying left/right by up to "amplitude"
		# pixels never reveals an empty gap at either edge of the screen.
		var layer_width: float = vp_size.x + amplitude * 2.0 + 40.0
		var resting_x: float = -(layer_width - vp_size.x) / 2.0   # centers the oversized band on screen

		var layer := Control.new()
		layer.name = "FogLayer%d" % i
		layer.position = Vector2(resting_x, y_pos)
		layer.size = Vector2(layer_width, band_height)
		_fog_container.add_child(layer)

		# The actual cloud shape is 100% generated by the shader below --
		# this ColorRect is just a blank canvas for it to draw onto. Its
		# own .color doesn't matter (the shader overwrites COLOR itself).
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
		fog_material.set_shader_parameter("cloud_scale", fog_cloud_scale * randf_range(0.85, 1.15))
		fog_material.set_shader_parameter("density", fog_density)
		fog_material.set_shader_parameter("softness", fog_softness)
		fog_material.set_shader_parameter("drift_speed", fog_drift_speed * lerp(1.0, 0.5, depth_t))
		fog_material.set_shader_parameter("vertical_squash", fog_vertical_squash)
		fog_material.set_shader_parameter("cloud_color", fog_color)
		fog_material.set_shader_parameter("opacity", alpha)
		fog_material.set_shader_parameter("top_fade", fog_top_fade)
		piece.material = fog_material

		layer.add_child(piece)

		# Random starting phase so each layer begins its sway at a
		# different point along the wave, instead of all of them swinging
		# in perfect unison like one rigid slab.
		var phase: float = randf() * TAU

		_fog_layers.append({
			"node": layer,
			"speed": speed,
			"amplitude": amplitude,
			"base_x": resting_x,
			"phase": phase,
		})


func _show_paragraph(index: int) -> void:
	if index >= PARAGRAPHS.size():
		_finish_crawl()
		return
	_index = index
	var paragraph: Dictionary = PARAGRAPHS[_index]
	paragraph_label.text = paragraph.get("text", "")

	# Shows this paragraph's background image if it has one, otherwise hides
	# BackgroundImage entirely so the plain black ColorRect behind it is
	# what's visible -- that's the default.
	var background_path: String = paragraph.get("background", "")
	if background_path != "" and ResourceLoader.exists(background_path):
		background_image.texture = load(background_path)
		background_image.visible = true
	else:
		background_image.visible = false

	# Shows/hides the swaying fog band for THIS specific paragraph -- see
	# the "fog" key on the PARAGRAPHS array above. Defaults to true (shown)
	# if a paragraph doesn't set it at all.
	_fog_container.visible = paragraph.get("fog", true)

	advance_timer.start(CRAWL_SECONDS_PER_PARAGRAPH)


func _on_next_pressed() -> void:
	# Instantly shows the next paragraph, same as if the timer had elapsed.
	advance_timer.stop()
	_show_paragraph(_index + 1)


func _on_skip_pressed() -> void:
	# Skips the ENTIRE crawl, not just the current paragraph.
	advance_timer.stop()
	_finish_crawl()


func _on_timer_timeout() -> void:
	_show_paragraph(_index + 1)


func _finish_crawl() -> void:
	SceneTransitions.change_scene(RunManager.pending_next_scene_path)
