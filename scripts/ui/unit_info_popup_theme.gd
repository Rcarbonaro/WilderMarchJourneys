# res://scripts/ui/unit_info_popup_theme.gd
#
# UNIT INFO POPUP THEME -- a drag-and-drop "skin" for UnitInfoPopup.
#
# HOW TO USE THIS:
#   1. In the Godot editor, right-click in a FileSystem folder → New Resource
#      → search "UnitInfoPopupTheme" → save it as a .tres file, e.g.
#      res://resources/ui/default_unit_info_theme.tres
#   2. Click it, and in the Inspector you'll see every field below. Drag your
#      texture files into whichever slots you want — leave any slot empty to
#      keep today's plain default look for just that piece.
#   3. Hand that .tres resource to a popup BEFORE calling setup():
#         var popup := UnitInfoPopup.new()
#         some_parent.add_child(popup)
#         popup.theme_resource = preload("res://resources/ui/default_unit_info_theme.tres")
#         popup.setup(unit_data, stat_lines)
#      If you never set theme_resource at all, the popup builds its own
#      blank default theme automatically -- every existing caller that
#      doesn't know about this keeps working exactly as before.
#
# NOTE ON "PATCH MARGIN": this is the 9-slice margin (in pixels) used so a
# textured frame/plate's corners and edges don't stretch and distort as the
# card resizes -- the margin is how many pixels in from each edge of your
# texture are "the corner," which get drawn at native size while the
# in-between regions stretch to fill the rest. Leave it at 0 for a texture
# that's fine being stretched uniformly (e.g. a simple flat-color plate).

class_name UnitInfoPopupTheme
extends Resource

@export var backdrop_color: Color = Color(0, 0, 0, 0.55)
# The dim overlay covering the screen behind the popup card. Use the color
# picker's alpha slider (the 4th value) to control transparency directly --
# 0 = fully invisible (no dimming at all), 1 = a solid opaque color.

@export_group("Card Background & Border")

@export var card_background: Texture2D
# Fills the ENTIRE card, behind all of its content (portrait, stats,
# abilities, everything). Leave unset to keep Godot's plain default
# PanelContainer look.
@export var card_background_patch_margin: int = 0

@export var card_border: Texture2D
# Drawn ON TOP of everything else, covering the whole card -- meant for a
# frame/border graphic with a transparent middle, so the actual content
# shows through the hole in the middle. Leave unset for no border overlay.
@export var card_border_patch_margin: int = 0

@export_group("Section Plates")
# Each of these is an OPTIONAL background plate behind just ONE part of the
# popup, instead of the whole card -- e.g. a fancy plate just behind the
# stats grid, or behind each ability row. Leave any of these unset to leave
# that section's background transparent (today's default look).

@export var description_plate: Texture2D
@export var description_plate_patch_margin: int = 0

@export var stats_plate: Texture2D
@export var stats_plate_patch_margin: int = 0

@export var ability_plate: Texture2D
# Applied behind EACH ability row individually (not the abilities list as a
# whole) -- so every ability gets its own little plate.
@export var ability_plate_patch_margin: int = 0

@export var equipped_item_plate: Texture2D
# Applied behind EACH equipped item row individually.
@export var equipped_item_plate_patch_margin: int = 0
