# res://scripts/global/magic_particles_overlay.gd
#
# Magical CURSOR TRAIL. A single GPUParticles2D follows the mouse every
# frame; because local_coords = false, particles that have already been
# emitted stay put in screen space once spawned instead of following the
# emitter -- so as the emitter chases the cursor, it leaves a trail of
# sparks that burst outward in every direction and fade out fast
# (lifetime is only 0.45s). This is intentionally light on particle count
# and screen coverage (a handful of small sparks near the cursor, not a
# full-viewport effect) so it doesn't cost meaningful frame time.
#
# Registered as an Autoload named "MagicParticlesOverlay" so it persists
# across every scene change and sits above menus, battle, and popups alike.
extends CanvasLayer

@onready var _trail: GPUParticles2D = $CursorTrail


func _process(_delta: float) -> void:
	_trail.position = get_viewport().get_mouse_position()


# ── TUNING ────────────────────────────────────────────────────────────────
# Open MagicParticlesOverlay.tscn, select "CursorTrail", and adjust in the
# Inspector:
#   - Amount: how many sparks exist at once (density of the trail)
#   - Lifetime: how long each spark lasts before fading (lower = shorter
#     trail that clings tighter to the cursor; higher = longer trail)
#   - Process Material > Initial Velocity Min/Max: how fast sparks fly
#     outward from the cursor
#   - Process Material > Damping Min/Max: how quickly sparks decelerate --
#     higher damping keeps sparks clustered close to the cursor even at
#     high initial velocity
#   - Process Material > Scale Min/Max: spark size
# Want it OFF for a specific screen? Call:
#   MagicParticlesOverlay.hide()
#   MagicParticlesOverlay.show()   # to bring it back
