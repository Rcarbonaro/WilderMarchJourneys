# res://scripts/autoloads/ui_colors.gd
#
# UI COLORS -- the single source of truth for the "Blue Steel" fantasy
# palette used across Wilder March. Register this as an Autoload named
# "UIColors" (Project Settings > Autoload) so any script can do things like:
#
#   label.add_theme_color_override("font_color", UIColors.MAGIC_GLOW)
#
# If you ever want to retint the whole game (say, a "Crimson Steel" reskin
# for a special mode), change the values here AND in
# resources/theme/wilder_march_theme.tres to match -- the two are kept in
# sync by hand, not generated from each other, so update both together.
extends Node

# ── Core steel palette ──────────────────────────────────────────────────
const STEEL_BG_DARK    := Color(0.043, 0.063, 0.098)  # darkest background (behind everything)
const STEEL_BG         := Color(0.075, 0.106, 0.165)  # main window/background fill
const STEEL_PANEL      := Color(0.098, 0.145, 0.220)  # panel/button base fill
const STEEL_PANEL_HI   := Color(0.133, 0.188, 0.275)  # lighter panel fill (hover)
const STEEL_BORDER     := Color(0.376, 0.573, 0.788)  # standard steel-blue border
const STEEL_BORDER_HI  := Color(0.510, 0.750, 0.980)  # brighter border (hover/focus)
const STEEL_BORDER_DIM := Color(0.220, 0.290, 0.380)  # dim border (disabled)
const MAGIC_GLOW       := Color(0.420, 0.850, 1.000)  # cyan magic accent glow

const TEXT_LIGHT    := Color(0.878, 0.918, 0.965)  # primary text
const TEXT_MUTED    := Color(0.580, 0.650, 0.750)  # secondary/subtitle text
const TEXT_DISABLED := Color(0.360, 0.400, 0.470)  # disabled text
const ACCENT_GOLD   := Color(0.831, 0.702, 0.310)  # sparing use: selection / primary CTA accent

# ── Victory scheme (green) ───────────────────────────────────────────────
const VICTORY_GREEN        := Color(0.243, 0.804, 0.435)
const VICTORY_GREEN_BRIGHT := Color(0.520, 0.960, 0.650)
const VICTORY_PANEL_BG     := Color(0.055, 0.150, 0.085)
const VICTORY_BORDER       := Color(0.290, 0.780, 0.450)

# ── Defeat scheme (red) ──────────────────────────────────────────────────
const DEFEAT_RED        := Color(0.867, 0.243, 0.243)
const DEFEAT_RED_BRIGHT := Color(0.980, 0.450, 0.420)
const DEFEAT_PANEL_BG   := Color(0.150, 0.050, 0.050)
const DEFEAT_BORDER     := Color(0.700, 0.220, 0.220)

# ── Fonts ─────────────────────────────────────────────────────────────────
# Basic font: used everywhere by default (it's baked into
# wilder_march_theme.tres as the theme's default_font, so most UI never
# needs to touch these constants at all).
#
# Decorative font: ONLY for the Victory scene banner, the "Game Victory"
# tutorial-complete screen, and the Defeat screen title. Everything else
# should keep using the theme's default (basic) font.
const FONT_BASIC_PATH := "res://sprites/UI/font/basicfont.otf"
const FONT_DECO_PATH  := "res://sprites/UI/font/decofont.ttf"

static func decorative_font() -> Font:
	return load(FONT_DECO_PATH) as Font

static func basic_font() -> Font:
	return load(FONT_BASIC_PATH) as Font
