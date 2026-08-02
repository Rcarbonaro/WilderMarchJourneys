# res://scripts/data/light_profile_data.gd
#
# LIGHT PROFILE — a reusable "recipe" for a LightSource (see light_source.gd).
# Same pattern as StatusEffectData/HazardData/MapFeatureData: a Resource you
# build once in the Inspector and drop into whatever needs a light (a unit's
# torch, a fire hazard, a fire/lightning spell flash), instead of hardcoding
# color/radius/energy values in every script that wants to glow.

extends Resource
class_name LightProfileData

@export var color: Color = Color(1.0, 0.85, 0.6, 1.0)
# Tint of the light. Warm orange-yellow works well for torches/fire;
# try a cool blue-white or violet for lightning.

@export var energy: float = 1.2
# Overall brightness. PointLight2D energies above ~2.0 start blowing out
# to solid white on most tile art -- keep most profiles under that.

@export var radius_px: float = 220.0
# How far the light reaches, in pixels, from its center. For reference,
# TILE_SIZE is 96px, so 220px covers roughly a 2-tile radius.

@export var flicker: bool = false
# Turn on for anything that should feel alive -- fire, lightning arcs.
# Leave off for a steady torch/lantern glow.

@export var flicker_amount: float = 0.15
# How much the energy wobbles up/down when flicker is true, as a fraction
# of `energy`. 0.15 is a subtle candle-like waver; try 0.4+ for something
# more violent (a raging fire, an unstable lightning field).

@export var flicker_speed: float = 8.0
# How fast the flicker oscillates. Higher = jitterier, lower = a slow pulse.
