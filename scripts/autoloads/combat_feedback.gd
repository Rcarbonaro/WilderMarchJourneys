# res://scripts/autoloads/combat_feedback.gd
#
# COMBAT FEEDBACK MANAGER
# Centralises all hit-feel effects: floating damage numbers, screen shake,
# impact particles, hit stop, and HP bar flash.
#
# SETUP:
#   1. Add this script as an autoload named "CombatFeedback" in
#      Project → Project Settings → Autoloads.
#   2. In battle_scene.gd's _ready(), call:
#         CombatFeedback.register_camera($YourCamera2DNodePath)
#   3. In unit_node.gd's take_damage(), call:
#         CombatFeedback.show_hit(self, actual_damage, is_crit, damage_type)
#   4. In ui_manager.gd's _refresh_live_values(), call:
#         CombatFeedback.flash_bar(hp_bar_fill)   ← only when HP decreases

extends Node


# ── CONFIGURATION ─────────────────────────────────────────────────────────────
# Change these to tune the feel without touching any other code.

## Seconds the engine is frozen on a critical hit (real time, not game time).
@export var hit_stop_duration:   float = 0.155
## How fast screen shake decays. Higher = shorter rumble.
@export var shake_falloff:       float = 6.0
## Damage as % of target's max HP that triggers each colour tier.
@export var dmg_pct_yellow:      float = 0.10   # >= 10% max HP → yellow
@export var dmg_pct_orange:      float = 0.25   # >= 25% max HP → orange
@export var dmg_pct_red:         float = 0.50   # >= 50% max HP → deep red

## Floating damage-number colours for DOT ticks, keyed by the DOT's
## dot_damage_type string (set per-status on StatusEffectData). Only used
## when show_hit()/spawn_damage_number() are called with is_dot = true —
## normal hits keep using the % of max HP colour tiers above.
##
## TO ADD A NEW DOT TYPE (e.g. "bleed") LATER: add one line here mapping the
## new type name to a Color, then set that same string in dot_damage_type on
## whichever StatusEffectData resource(s) should use it. Nothing else needs
## to change — this is the one central place DOT colours are defined.
## A dot_damage_type with no matching entry here falls back to plain white
## rather than causing an error.
##
## This is a plain (non-@export) Dictionary rather than an exported one
## because Godot 4.6's Inspector doesn't have a clean built-in editor for a
## String → Color dictionary — editing the values directly here is the
## simplest and most reliable place to change them.
var dot_damage_colors: Dictionary = {
	"poison": Color(0.10, 0.45, 0.12),   # dark green
	"fire":   Color(1.00, 0.45, 0.05),   # red/orange — deliberately distinct
										   # from the crit colour below (bright,
										   # saturated red) so a Fire DOT tick
										   # is never confused with a crit.
	"curse":  Color(0.45, 0.08, 0.55),   # dark purple
}

## ── IMPACT PARTICLES (ADDED) ──────────────────────────────────────────────
## Everything about the on-hit particle burst — white for a normal attack,
## red for a crit, count scaled by damage dealt.
##
## HOW MANY PARTICLES SPAWN:
##   count = impact_particle_base_amount
##         + (damage_dealt * impact_particle_amount_per_damage)
##   ...then multiplied by impact_particle_crit_amount_multiplier on a crit,
##   then clamped to impact_particle_amount_max.
##   e.g. defaults below: a 20-damage normal hit spawns 6 + (20*0.6) = 18
##   particles; the same hit as a crit spawns 18 * 1.5 = 27.
@export var impact_particle_base_amount:            int   = 6
@export var impact_particle_amount_per_damage:       float = 0.6
@export var impact_particle_crit_amount_multiplier:  float = 1.5
@export var impact_particle_amount_max:              int   = 40
## How long each particle lives before disappearing (seconds).
@export var impact_particle_lifetime:                float = 0.45
## How fast particles shoot outward (px/sec) — randomized per-particle
## between min and the appropriate max.
@export var impact_particle_speed_min:               float = 60.0
@export var impact_particle_speed_max_normal:        float = 140.0
@export var impact_particle_speed_max_crit:          float = 200.0
## Colours — white for a normal hit, red for a crit.
@export var impact_particle_color_normal: Color = Color(1.00, 1.00, 1.00)
@export var impact_particle_color_crit:   Color = Color(1.00, 0.15, 0.15)

## ── TETHER SPREAD PARTICLES (ADDED) ───────────────────────────────────────
## Purple burst shown on each ally hit by tether-spread damage — see
## spawn_tether_spread_particles() below.
@export var tether_spread_particle_amount:    int   = 14
@export var tether_spread_particle_speed_min: float = 80.0
@export var tether_spread_particle_speed_max: float = 220.0
## Distance travelled before disappearing ≈ speed * lifetime (there's no
## gravity on these), so raise this to make them travel farther before
## vanishing, or shorten it for a tighter, snappier burst.
@export var tether_spread_particle_lifetime:  float = 0.5
@export var tether_spread_particle_color: Color = Color(0.65, 0.2, 0.85, 0.9)   # matches battle_grid.gd's tether_line_color


# ── INTERNAL STATE ─────────────────────────────────────────────────────────────
var _camera:           Camera2D     = null
var _fx_layer:         CanvasLayer  = null
var _shake_amplitude:  float        = 0.0
var _shake_remaining:  float        = 0.0
var _shake_duration:   float        = 0.001   # guard vs divide-by-zero
var _hit_stop_active:  bool         = false


func _ready() -> void:
	# All visual feedback nodes (labels, particles) are added to a high-layer
	# CanvasLayer so they always render above the game world and grid.
	_fx_layer       = CanvasLayer.new()
	_fx_layer.layer = 128
	_fx_layer.name  = "CombatFXLayer"
	add_child(_fx_layer)

	# Debuff feedback — see _on_status_applied() below.
	EventBus.subscribe(EventBus.ON_BUFF_APPLIED, _on_status_applied)


# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ══════════════════════════════════════════════════════════════════════════════

func register_camera(cam: Camera2D) -> void:
	## Call this from BattleScene._ready() so screen shake knows what to move.
	_camera = cam


func show_hit(unit, amount: int, is_crit: bool, damage_type: String, apply_shake: bool = true, is_dot: bool = false) -> void:
		## Master entry point. Call from unit_node.gd's take_damage() once the
	## final damage value is known. Fires all effects in one call.
	## 'apply_shake' defaults to true so every existing caller (normal
	## attacks) behaves exactly as before — hazard damage is the one case
	## that passes false, since a hazard ticking every "enter"/turn is much
	## more frequent than a real hit and the constant rumble gets annoying.
	## 'is_dot' defaults to false so every existing caller keeps using the
	## normal % of max HP damage-number colour tiers; only DOT ticks (see
	## unit_node.gd's _apply_dot_tick()) pass true, which colours the number
	## by damage_type via dot_damage_colors instead.
	if not is_instance_valid(unit):
		return

	var max_hp: int = 1
	if unit.has_method("get_stats"):
		max_hp = max(1, unit.get_stats().hp)

	# ── Floating number ───────────────────────────────────────────────────────
	spawn_damage_number(unit.global_position, amount, is_crit, max_hp, damage_type, is_dot)

	# ── Impact particles ──────────────────────────────────────────────────────
	spawn_impact_particles(unit.global_position, amount, is_crit)
	
	# ── Screen shake — scales with how significant the hit is ─────────────────
	if apply_shake:
		var pct: float = float(amount) / float(max_hp)
		var shake_amp: float = 0.0
		if    is_crit:          shake_amp = 7.0
		elif  pct >= dmg_pct_red:    shake_amp = 5.0
		elif  pct >= dmg_pct_orange: shake_amp = 3.0
		elif  pct >= dmg_pct_yellow: shake_amp = 1.5
		if shake_amp > 0.0:
			screen_shake(shake_amp, 0.5)

	# ── Hit stop — crits only ─────────────────────────────────────────────────
	if is_crit:
		apply_hit_stop()

func _on_status_applied(payload: Dictionary) -> void:
	## Plays a quick VFX + SFX flourish whenever a DEBUFF (not a buff) lands
	## on a unit. Buffs already get their own icon/visual-override feedback
	## elsewhere — this fills in the "you've just been afflicted" feedback
	## that debuffs were missing.
	if payload.get("is_buff", false):
		return

	var unit = payload.get("unit")
	if not is_instance_valid(unit):
		return

	var status_data = payload.get("status_data")

	spawn_debuff_vfx(unit.global_position, status_data)

	if status_data != null and status_data.apply_sfx != null:
		play_sfx(status_data.apply_sfx)


func spawn_debuff_vfx(world_pos: Vector2, status_data = null) -> void:
	## Uses the status's own apply_vfx_scene if it set one; otherwise falls
	## back to a generic sickly-purple particle burst so every debuff gets
	## SOME feedback even before you've made custom art for each one.
	if status_data != null and status_data.apply_vfx_scene != null:
		var custom = status_data.apply_vfx_scene.instantiate()
		_fx_layer.add_child(custom)
		custom.position = _to_screen(world_pos)
		return

	var p := CPUParticles2D.new()
	_fx_layer.add_child(p)
	p.position             = _to_screen(world_pos)
	p.emitting             = false
	p.one_shot             = true
	p.explosiveness        = 0.9
	p.amount               = 14
	p.lifetime             = 0.5
	p.direction            = Vector2(0.0, -1.0)
	p.spread               = 180.0
	p.gravity              = Vector2(0.0, -40.0)   # drifts upward, unlike hit impacts
	p.initial_velocity_min = 30.0
	p.initial_velocity_max = 90.0
	p.scale_amount_min     = 2.0
	p.scale_amount_max     = 4.5
	p.color                = Color(0.55, 0.15, 0.65)   # sickly purple
	p.emitting             = true

	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(
		func():
			if is_instance_valid(p):
				p.queue_free()
	)


func play_sfx(stream: AudioStream) -> void:
	## Fire-and-forget one-shot sound. Spawns a temporary AudioStreamPlayer
	## and frees itself once playback finishes.
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.play()
	player.finished.connect(func():
		if is_instance_valid(player):
			player.queue_free()
	)


func spawn_damage_number(world_pos: Vector2, amount: int,
						  is_crit: bool, max_hp: int,
						  damage_type: String = "", is_dot: bool = false) -> void:
	## Spawns a floating label above the hit unit that floats up and fades out.
	## damage_type/is_dot are both optional so every pre-existing call site
	## (there weren't any others, but just in case something calls this
	## directly rather than through show_hit) keeps working unchanged.
	var label := Label.new()
	_fx_layer.add_child(label)

	# ── Text ──────────────────────────────────────────────────────────────────
	label.text = str(amount) + ("!" if is_crit else "")

	# ── Font size — crits are noticeably larger ───────────────────────────────
	var font_size: int = 32 if is_crit else 22
	label.add_theme_font_size_override("font_size", font_size)

	# ── Colour ────────────────────────────────────────────────────────────────
	# DOT ticks (is_dot = true) use a fixed colour looked up by damage_type
	# from dot_damage_colors above, instead of the usual "% of max HP" tiers
	# — DOT is never a crit (is_crit is always false for a DOT tick, enforced
	# in unit_node.gd's _apply_dot_tick), so this branch and the crit branch
	# below never overlap.
	var color: Color
	if is_dot and dot_damage_colors.has(damage_type):
		color = dot_damage_colors[damage_type]
	else:
		# ── Colour based on damage as % of max HP (normal hits) ────────────────
		var pct: float = float(amount) / float(max_hp)
		if   is_crit:              color = Color(1.00, 0.15, 0.15)   # crit: bright red
		elif pct >= dmg_pct_red:   color = Color(0.95, 0.20, 0.20)   # heavy: deep red
		elif pct >= dmg_pct_orange:color = Color(1.00, 0.55, 0.10)   # moderate: orange
		elif pct >= dmg_pct_yellow:color = Color(1.00, 0.95, 0.20)   # light: yellow
		else:                      color = Color(1.00, 1.00, 1.00)   # tiny: white
	label.add_theme_color_override("font_color", color)

	# ── Black outline so numbers are readable over any background ─────────────
	label.add_theme_constant_override("outline_size", 4)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))

	# ── Position in screen space above the unit, with a slight random drift ───
	var screen_pos: Vector2  = _to_screen(world_pos)
	screen_pos              += Vector2(randf_range(-12.0, 12.0), -28.0)
	label.position           = screen_pos

	# ── Float up, then fade out ───────────────────────────────────────────────
	var rise: float = 75.0 if is_crit else 52.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y",   label.position.y - rise, 0.9) \
		 .set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(label, "modulate:a",   0.0, 0.5).set_delay(0.45)
	tween.chain().tween_callback(label.queue_free)


func spawn_impact_particles(world_pos: Vector2,
							 amount: int, is_crit: bool = false) -> void:
	## Spawns a one-shot burst of CPUParticles2D at the hit location: white
	## for a normal hit, red for a crit. Particle COUNT scales with how much
	## damage was dealt — see the impact_particle_* @export vars above for
	## exactly what to tweak.
	var p := CPUParticles2D.new()
	_fx_layer.add_child(p)
	p.position               = _to_screen(world_pos)
	p.emitting               = false
	p.one_shot               = true
	p.explosiveness          = 0.95

	# ── PARTICLE COUNT — scales with damage ───────────────────────────────────
	var count: int = impact_particle_base_amount + int(round(float(amount) * impact_particle_amount_per_damage))
	if is_crit:
		count = int(round(float(count) * impact_particle_crit_amount_multiplier))
	p.amount                 = clampi(count, 1, impact_particle_amount_max)

	p.lifetime               = impact_particle_lifetime
	p.direction              = Vector2(0.0, -1.0)
	p.spread                 = 180.0   # full 360° coverage — shoots out in every direction
	p.gravity                = Vector2(0.0, 190.0)
	p.initial_velocity_min   = impact_particle_speed_min
	p.initial_velocity_max   = impact_particle_speed_max_crit if is_crit else impact_particle_speed_max_normal
	p.scale_amount_min       = 2.5
	p.scale_amount_max       = 6.0 if is_crit else 4.0

	# ── COLOUR — white for a normal hit, red for a crit ───────────────────────
	p.color = impact_particle_color_crit if is_crit else impact_particle_color_normal

	p.emitting = true

	# Auto-cleanup after the burst finishes.
	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(
		func():
			if is_instance_valid(p):
				p.queue_free()
	)


func spawn_tether_spread_particles(world_pos: Vector2) -> void:
	## Called once per ally that takes tether-spread damage (see
	## ability_executor.gd's TETHER PROPAGATION step). Purple particles
	## shoot outward in every direction from the hit unit.
	##
	## HOW TO EDIT (all in the CONFIGURATION section above):
	##   - tether_spread_particle_amount        → how many particles
	##   - tether_spread_particle_speed_min/max → how fast (px/sec)
	##   - tether_spread_particle_lifetime      → how far before disappearing
	##     (there's no gravity here, so distance ≈ speed * lifetime)
	var p := CPUParticles2D.new()
	_fx_layer.add_child(p)
	p.position               = _to_screen(world_pos)
	p.emitting               = false
	p.one_shot               = true
	p.explosiveness          = 1.0          # all particles fire at once
	p.amount                 = tether_spread_particle_amount
	p.lifetime                = tether_spread_particle_lifetime
	p.direction               = Vector2(0.0, -1.0)
	p.spread                  = 180.0        # every direction
	p.gravity                 = Vector2.ZERO # no gravity -- speed*lifetime IS the travel distance
	p.initial_velocity_min    = tether_spread_particle_speed_min
	p.initial_velocity_max    = tether_spread_particle_speed_max
	p.scale_amount_min        = 2.5
	p.scale_amount_max        = 5.0
	p.color                   = tether_spread_particle_color

	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(
		func():
			if is_instance_valid(p):
				p.queue_free()
	)


func play_dot_hit_effects(unit, effects_by_type: Dictionary) -> void:
	## Called once per DOT-tick batch from unit_node.gd's tick_dot() — NOT
	## once per individual status — so multiple DOTs of the SAME type ticking
	## together only show their effect once, and multiple DIFFERENT types
	## always appear in a fixed, readable order rather than in whatever order
	## active_statuses happens to store them.
	##
	## effects_by_type: Dictionary of dot_damage_type (String) -> PackedScene
	## (or null for "use the built-in placeholder for this type").
	if not is_instance_valid(unit) or effects_by_type.is_empty():
		return

	# Fixed display order for the 3 built-in types. Anything else (a future
	# custom dot_damage_type) plays afterward, in whatever order it appears
	# in the dictionary (Godot dictionaries preserve insertion order).
	var priority_order: Array = ["poison", "fire", "curse"]
	for dot_type in priority_order:
		if effects_by_type.has(dot_type):
			_play_single_dot_effect(unit, dot_type, effects_by_type[dot_type])
	for dot_type in effects_by_type:
		if not priority_order.has(dot_type):
			_play_single_dot_effect(unit, dot_type, effects_by_type[dot_type])


func _play_single_dot_effect(unit, dot_type: String, custom_scene: PackedScene) -> void:
	## Instances custom_scene (if the status designer assigned one) centred on
	## the unit, or falls back to a built-in placeholder particle burst keyed
	## by dot_type. Add a new match arm below (and a matching entry to
	## dot_damage_colors above, if it should also affect the damage number)
	## to give a brand new DOT type its own placeholder look.
	if not is_instance_valid(unit):
		return

	if custom_scene != null:
		var fx := custom_scene.instantiate()
		_fx_layer.add_child(fx)
		if fx is Node2D or fx is Control:
			fx.position = _to_screen(unit.global_position)
		return

	match dot_type:
		"poison":
			_spawn_poison_bubbles(unit.global_position)
		"fire":
			_spawn_fire_burst(unit.global_position)
		"curse":
			_spawn_curse_burst(unit.global_position)
		_:
			pass   # Unknown type, no custom scene assigned — nothing to show yet.


func _spawn_poison_bubbles(world_pos: Vector2) -> void:
	## Placeholder for Poison DOT ticks: slow-rising purple "bubbles".
	## Deliberately purple rather than the green used elsewhere for poison
	## (damage number / flash / impact particles) — this is a separate,
	## explicitly-requested placeholder look for the over-the-unit DOT effect.
	var p := CPUParticles2D.new()
	_fx_layer.add_child(p)
	p.position               = _to_screen(world_pos)
	p.emitting               = false
	p.one_shot               = true
	p.explosiveness          = 0.4          # bubbles drift out over time, not all at once
	p.amount                 = 10
	p.lifetime               = 0.9          # slower and longer-lived than a normal impact hit
	p.direction              = Vector2(0.0, -1.0)
	p.spread                 = 40.0         # narrow upward drift, like rising bubbles
	p.gravity                = Vector2(0.0, -25.0)   # gentle upward drift instead of falling
	p.initial_velocity_min   = 15.0
	p.initial_velocity_max   = 45.0
	p.scale_amount_min       = 3.0
	p.scale_amount_max       = 6.0
	p.color                  = Color(0.55, 0.15, 0.75)   # purple bubbles

	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(
		func():
			if is_instance_valid(p):
				p.queue_free()
	)


func _spawn_fire_burst(world_pos: Vector2) -> void:
	## Placeholder for Fire DOT ticks: a quick fiery orange/red flare-up,
	## similar in feel to spawn_impact_particles()'s "fire" arm.
	var p := CPUParticles2D.new()
	_fx_layer.add_child(p)
	p.position               = _to_screen(world_pos)
	p.emitting               = false
	p.one_shot               = true
	p.explosiveness          = 0.85
	p.amount                 = 14
	p.lifetime               = 0.5
	p.direction              = Vector2(0.0, -1.0)
	p.spread                 = 150.0
	p.gravity                = Vector2(0.0, -60.0)   # licks upward like flame
	p.initial_velocity_min   = 40.0
	p.initial_velocity_max   = 120.0
	p.scale_amount_min       = 3.0
	p.scale_amount_max       = 5.5
	p.color                  = Color(1.00, 0.45, 0.05)   # matches dot_damage_colors["fire"]

	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(
		func():
			if is_instance_valid(p):
				p.queue_free()
	)


func _spawn_curse_burst(world_pos: Vector2) -> void:
	## Placeholder for Curse DOT ticks: sharp black particles shooting
	## outward in every direction, a harsher/faster burst than the other two.
	var p := CPUParticles2D.new()
	_fx_layer.add_child(p)
	p.position               = _to_screen(world_pos)
	p.emitting               = false
	p.one_shot               = true
	p.explosiveness          = 1.0          # all particles fire at once — sharp, not a trickle
	p.amount                 = 16
	p.lifetime               = 0.4
	p.direction              = Vector2(0.0, -1.0)
	p.spread                 = 180.0        # shoots out in every direction
	p.gravity                = Vector2(0.0, 40.0)
	p.initial_velocity_min   = 90.0
	p.initial_velocity_max   = 220.0        # fastest of the three — feels like it's "shooting out"
	p.scale_amount_min       = 2.0
	p.scale_amount_max       = 4.0
	p.color                  = Color(0.05, 0.05, 0.05)   # black

	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(
		func():
			if is_instance_valid(p):
				p.queue_free()
	)


func screen_shake(amplitude: float, duration: float) -> void:
	## Stacks with any ongoing shake — takes the larger amplitude so a crit
	## during an existing shake never feels weaker than the hit that started it.
	_shake_amplitude = max(_shake_amplitude, amplitude)
	if duration > _shake_remaining:
		_shake_duration  = duration
		_shake_remaining = duration


var current_speed_multiplier: float = 1.0

func set_speed_multiplier(mult: float) -> void:
	current_speed_multiplier = mult
	if not _hit_stop_active:
		Engine.time_scale = mult
	# If hit-stop is active right now, don't stomp its 0.0 freeze --
	# apply_hit_stop()'s own timer will pick up current_speed_multiplier
	# when it restores below.


func apply_hit_stop() -> void:
	## Freezes Engine.time_scale to 0 for hit_stop_duration real-time seconds.
	## Only fires for crits. The real-time timer (ignore_time_scale = true)
	## always counts actual wall-clock seconds so the freeze lasts predictably
	## regardless of the current speed multiplier.
	if _hit_stop_active:
		return
	_hit_stop_active  = true
	Engine.time_scale = 0.0
	get_tree().create_timer(hit_stop_duration, true, false, true).timeout.connect(
		func():
			Engine.time_scale = current_speed_multiplier   # ← was hardcoded 1.0
			_hit_stop_active  = false,
		CONNECT_ONE_SHOT
	)

func flash_bar(bar_fill: Control) -> void:
	## Call from ui_manager.gd when HP decreases. Briefly tints the fill red.
	if not is_instance_valid(bar_fill):
		return
	var tween := create_tween()
	tween.tween_property(bar_fill, "modulate", Color(1.0, 0.15, 0.15), 0.0)
	tween.tween_property(bar_fill, "modulate", Color.WHITE, 0.30) \
		 .set_ease(Tween.EASE_OUT)


# ══════════════════════════════════════════════════════════════════════════════
# INTERNAL
# ══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if _shake_remaining <= 0.0:
		return
	var cam := _get_camera()
	if cam == null:
		_shake_remaining = 0.0
		return
	_shake_remaining -= delta
	if _shake_remaining <= 0.0:
		cam.offset       = Vector2.ZERO
		_shake_amplitude = 0.0
		return
	var progress:    float = _shake_remaining / _shake_duration
	var current_amp: float = _shake_amplitude * progress
	cam.offset = Vector2(
		randf_range(-current_amp, current_amp),
		randf_range(-current_amp, current_amp)
	)


func _get_camera() -> Camera2D:
	# Use the registered camera if available and still valid.
	if is_instance_valid(_camera):
		return _camera
	# Fallback: search the current scene so shake works even if
	# register_camera() was never called or the scene was reloaded.
	_camera = _find_camera_in(get_tree().current_scene)
	return _camera


func _find_camera_in(node: Node) -> Camera2D:
	if node is Camera2D:
		return node as Camera2D
	for child in node.get_children():
		var result := _find_camera_in(child)
		if result != null:
			return result
	return null


func _to_screen(world_pos: Vector2) -> Vector2:
	# Converts a world-space 2D position to canvas/screen-space coordinates.
	# Labels and particles on the CanvasLayer use screen space, so anything
	# derived from a unit's global_position must be converted here first.
	return get_viewport().get_canvas_transform() * world_pos
