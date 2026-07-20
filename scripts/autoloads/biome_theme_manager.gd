# res://scripts/autoloads/biome_theme_manager.gd
#
# BIOME THEME MANAGER -- retints battle-bar/deployment UI per biome, on top
# of the base "Blue Steel" theme (wilder_march_theme.tres). Register as an
# Autoload named "BiomeThemeManager".
#
# HOW THIS SCALES: BIOME_UI_THEMES below is a plain Dictionary keyed by
# biome name, exactly like the BIOME_MUSIC / BIOME_BACKGROUNDS dictionaries
# you already have in battle_scene.gd -- add a new entry here whenever you
# build out swamp/plains/etc, using forest's entry as the template. Any
# biome NOT listed here (including "" if something goes wrong upstream)
# automatically falls back to DEFAULT_THEME, which is just the base steel
# palette -- so nothing breaks or looks unstyled while a biome is still
# unbuilt.
extends Node

const BIOME_UI_THEMES: Dictionary = {
	"forest": {
		"panel_bg":      Color(0.086, 0.129, 0.098, 0.96),
		"border":        Color(0.522, 0.663, 0.494, 1.0),
		"border_bright": Color(0.663, 0.804, 0.616, 1.0),
		"accent":        Color(0.596, 0.816, 0.545, 1.0),
		"glow":          Color(0.522, 0.663, 0.494, 0.4),
		"text":          Color(0.878, 0.918, 0.965, 1.0),
	},
	# "swamp": { ... }, "plains": { ... }  -- add as you build them.
}

# Falls back to this (the base Blue Steel palette) for any biome not listed
# above, so an unbuilt biome just looks like the default UI instead of broken.
const DEFAULT_THEME: Dictionary = {
	"panel_bg":      Color(0.098, 0.145, 0.220, 0.96),
	"border":        Color(0.376, 0.573, 0.788, 1.0),
	"border_bright": Color(0.510, 0.750, 0.980, 1.0),
	"accent":        Color(0.420, 0.850, 1.000, 1.0),
	"glow":          Color(0.376, 0.573, 0.788, 0.4),
	"text":          Color(0.878, 0.918, 0.965, 1.0),
}


func get_theme(biome: String) -> Dictionary:
	return BIOME_UI_THEMES.get(biome, DEFAULT_THEME)


# ── LOW-LEVEL HELPERS (work with any palette Dictionary) ───────────────────

func apply_panel_themed(panel: Control, t: Dictionary, corner_radius: int = 10) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = t.panel_bg
	style.set_border_width_all(2)
	style.border_color = t.border
	style.set_corner_radius_all(corner_radius)
	style.shadow_color = t.glow
	style.shadow_size = 6
	style.content_margin_left = 14
	style.content_margin_top = 12
	style.content_margin_right = 14
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)


func apply_button_themed(button: Button, t: Dictionary) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = t.panel_bg
	normal.set_border_width_all(2)
	normal.border_color = t.border
	normal.set_corner_radius_all(6)
	normal.content_margin_left = 18
	normal.content_margin_top = 10
	normal.content_margin_right = 18
	normal.content_margin_bottom = 10

	var hover: StyleBoxFlat = normal.duplicate()
	hover.border_color = t.border_bright
	hover.shadow_color = t.glow
	hover.shadow_size = 6

	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.border_color = t.accent
	pressed.bg_color = t.panel_bg.darkened(0.25)

	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", t.text)
	button.add_theme_color_override("font_hover_color", t.text.lightened(0.15))
	button.add_theme_color_override("font_pressed_color", t.accent)


# ── BIOME-KEYED CONVENIENCE WRAPPERS ────────────────────────────────────────

func apply_panel(panel: Control, biome: String, corner_radius: int = 10) -> void:
	apply_panel_themed(panel, get_theme(biome), corner_radius)


func apply_button(button: Button, biome: String) -> void:
	apply_button_themed(button, get_theme(biome))


# ── SCENE-LEVEL ENTRY POINTS ─────────────────────────────────────────────

# Call from battle_scene.gd's _ready(), right after setup_battle_background(biome).
func apply_to_battle_ui(ui_manager: CanvasLayer, biome: String) -> void:
	var t := get_theme(biome)

	var bottom_bar := ui_manager.get_node_or_null("BottomBar")
	if bottom_bar:
		apply_panel_themed(bottom_bar, t)

	var pause_menu := ui_manager.get_node_or_null("PauseMenu")
	if pause_menu:
		apply_panel_themed(pause_menu, t)

	var ability_bar := ui_manager.get_node_or_null(
		"BottomBar/HBoxContainer/ActionColumn/AbilityBar")
	if ability_bar:
		for child in ability_bar.get_children():
			if child is Button:
				apply_button_themed(child, t)

	var end_turn := ui_manager.get_node_or_null("BottomBar/HBoxContainer/EndTurnButton")
	if end_turn:
		apply_button_themed(end_turn, t)


# Call from deployment_manager.gd's _ready(), after figuring out the current
# biome (see the patch file for a _get_current_biome() you can copy in).
#
# NOTE: EquipPanel in your current DeploymentScene.tscn is a plain Control,
# not a Panel/PanelContainer, so it has no "panel" stylebox to retint. If
# you want it visibly reskinned too, wrap its contents in a PanelContainer
# in the editor and point this function at that new node instead.
func apply_to_deployment_scene(root: Node, biome: String) -> void:
	var t := get_theme(biome)

	var scout_panel := root.get_node_or_null("ScoutPanel")
	if scout_panel:
		apply_panel_themed(scout_panel, t)

	for btn_name in ["ShopButton", "ContinueButton", "ScoutButton"]:
		var btn := root.get_node_or_null(btn_name)
		if btn is Button:
			apply_button_themed(btn, t)
