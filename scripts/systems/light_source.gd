# res://scripts/systems/light_source.gd
#
# LIGHT SOURCE — a small reusable component that wraps a single PointLight2D
# and configures it from a LightProfileData resource (color, radius, flicker).
#
# USAGE:
#   Attach as a child of anything that should glow (a unit, a hazard visual,
#   a spell VFX root). Since it's a Node2D, if it's a CHILD of a moving
#   unit/hazard, it follows automatically -- no "update the light every time
#   something moves" code needed anywhere.
#
#       var light := LightSource.new()
#       light.profile = my_light_profile_data
#       add_child(light)              # or spawn_root.add_child(light)
#
#   For a one-shot spell flash that should fade out and clean itself up:
#
#       light.fade_in(0.1)
#       ... later ...
#       light.fade_out_and_free(0.4)

extends Node2D
class_name LightSource

@export var profile: LightProfileData
# Can be assigned in the Inspector (if this is placed in a .tscn) or set in
# code right after instantiating (see usage above) -- _ready() applies
# whatever is set by the time it runs. Call set_profile() to swap profiles
# on an already-existing LightSource later.

var _light: PointLight2D
var _base_energy: float = 1.0
var _flicker_time: float = 0.0

# A shared texture cache so every LightSource doesn't generate its own
# duplicate GradientTexture2D -- PointLight2D requires SOME texture assigned
# to render anything at all (unlike Godot 3's Light2D). This builds one soft
# radial falloff "cookie" once; every light reuses it, only adjusting
# texture_scale per-profile to control the actual on-screen radius.
static var _shared_light_texture: GradientTexture2D = null


func _ready() -> void:
	_light = PointLight2D.new()
	_light.texture = _get_shared_light_texture()
	add_child(_light)
	if profile != null:
		set_profile(profile)


func set_profile(new_profile: LightProfileData) -> void:
	profile = new_profile
	if _light == null:
		return   # _ready() hasn't run yet -- it will apply `profile` itself.
	_light.color         = profile.color
	_light.energy        = profile.energy
	_light.texture_scale = profile.radius_px / 128.0
	# 128.0 = half the shared texture's 256px width -- i.e. texture_scale 1.0
	# means "radius_px worth of falloff", so radius_px reads as actual pixels
	# on screen regardless of the underlying texture's native size.
	_base_energy = profile.energy
	set_process(profile.flicker)


func _process(delta: float) -> void:
	# Two overlapping sine waves (rather than one) so the flicker doesn't
	# read as a single metronomic pulse -- closer to how real firelight looks.
	_flicker_time += delta * profile.flicker_speed
	var wobble := sin(_flicker_time) * 0.6 + sin(_flicker_time * 2.7) * 0.4
	_light.energy = _base_energy + wobble * profile.flicker_amount * _base_energy


func fade_in(duration: float = 0.3) -> void:
	if _light == null:
		return
	_light.energy = 0.0
	var tw := create_tween()
	tw.tween_property(_light, "energy", _base_energy, duration)


func fade_out_and_free(duration: float = 0.3) -> void:
	set_process(false)
	if _light == null:
		queue_free()
		return
	var tw := create_tween()
	tw.tween_property(_light, "energy", 0.0, duration)
	tw.tween_callback(queue_free)


func _get_shared_light_texture() -> GradientTexture2D:
	if _shared_light_texture != null:
		return _shared_light_texture
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient  = grad
	tex.fill      = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to   = Vector2(1.0, 0.5)
	tex.width     = 256
	tex.height    = 256
	_shared_light_texture = tex
	return tex
	
