# res://scripts/meta/ending_sequence.gd
#
# ENDING SEQUENCE — plays when the player finishes stage 10 (see
# battle_scene.gd's _on_battle_ended()), replacing the old
# show_game_victory_popup() (which had an off-center layout bug — task 8 —
# and was just a static "Victory!" box). This is a full animated sequence:
# a black backdrop, fog rolling across the screen, the WilderMarch logo
# staying on screen throughout, and several lines of text fading in/out in
# sequence below it. (Task 9.)
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
# Assign "Fog Texture" in the Inspector to use your own art (tiled and
# scrolled horizontally at fog_scroll_speed px/sec, in up to fog_layer_count
# parallax layers at different speeds/opacities — see _build_fog()). Leave it
# blank to fall back to a few plain semi-transparent gray bands instead (a
# reasonable placeholder, not a substitute for real art).
#
# ── HOW TO ADJUST THE SUPPORT LINKS ────────────────────────────────────────
# tip_url / kickstarter_url / discord_url below — leave any blank to hide
# that specific button. They appear starting at the 3rd text block (the one
# that mentions them) and stay visible through the rest of the sequence.
extends Control

@export_group("Content")
@export var logo_texture: Texture2D = null
@export var fog_texture: Texture2D = null

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
@export var fog_scroll_speed: float = 18.0
@export var fog_layer_count: int = 3

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
var _fog_layers: Array = []   # Array[TextureRect] or Array[ColorRect], see _build_fog()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_build_backdrop()
	_build_fog()
	_build_content()

	_run_sequence()


func _process(delta: float) -> void:
	# Scrolls each fog layer leftward continuously. Each layer is TWO copies
	# of the same width placed side by side; once the scroll offset reaches
	# one copy's width, it wraps back to 0 — since the two copies are
	# identical, the wrap is invisible, giving a seamless endless scroll.
	for layer_data in _fog_layers:
		var layer: Control = layer_data["node"]
		var speed: float = layer_data["speed"]
		var width: float = layer_data["width"]
		layer_data["offset"] = fmod(layer_data["offset"] + speed * delta, width)
		layer.position.x = -layer_data["offset"]


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
	fog_container.clip_contents = true
	add_child(fog_container)

	for i in range(max(1, fog_layer_count)):
		# Layers further back (higher i) scroll slower and are more transparent,
		# for a simple sense of depth.
		var depth_t: float = float(i) / float(max(1, fog_layer_count - 1))
		var speed: float = fog_scroll_speed * lerp(1.0, 0.4, depth_t)
		var alpha: float = lerp(0.35, 0.14, depth_t)
		var y_pos: float = vp_size.y * lerp(0.55, 0.75, depth_t)
		var band_height: float = vp_size.y * 0.35

		var layer := Control.new()
		layer.name = "FogLayer%d" % i
		layer.position = Vector2(0, y_pos)
		layer.size = Vector2(vp_size.x * 4.0, band_height)
		fog_container.add_child(layer)

		var copy_width: float = vp_size.x * 2.0
		for copy_i in range(2):
			var piece: Control
			if fog_texture != null:
				var tex_rect := TextureRect.new()
				tex_rect.texture = fog_texture
				tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_rect.stretch_mode = TextureRect.STRETCH_TILE
				tex_rect.modulate = Color(1, 1, 1, alpha)
				piece = tex_rect
			else:
				# Fallback with no art assigned: a soft gray band. Not a
				# substitute for real fog art, just keeps the scene looking
				# reasonable out of the box.
				var rect := ColorRect.new()
				rect.color = Color(0.6, 0.6, 0.65, alpha)
				piece = rect
			piece.position = Vector2(copy_width * copy_i, 0)
			piece.size = Vector2(copy_width, band_height)
			piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
			layer.add_child(piece)

		_fog_layers.append({"node": layer, "speed": speed, "width": copy_width, "offset": 0.0})


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
