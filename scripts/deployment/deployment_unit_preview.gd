# res://scripts/deployment/deployment_unit_preview.gd
#
# A lightweight, grid-free stand-in for ONE unit, used only for ambient
# background decoration on DeploymentScene. Stands in place at a random spot
# and occasionally plays an "attack" animation as a purely cosmetic
# flourish -- no real AbilityExecutor, no damage, no targets, no movement.
#
# Deliberately does NOT use UnitNode, grid_ref, or any battle system -- this
# is pure visual dressing, built from scratch so nothing here can
# accidentally depend on (or break) real combat code.
#
# SCENE SETUP: create a new scene with a Node2D root, this script attached,
# and one child named "AnimatedSprite2D" (no frames assigned in the editor --
# setup() below fills them in at runtime from the unit's real battle scene).
# Save it as res://scenes/deployment/DeploymentUnitPreview.tscn.

class_name DeploymentUnitPreview
extends Node2D

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

var bounds: Rect2 = Rect2()

@export_range(0.1, 1.0, 0.05) var sprite_scale: float = 0.4
# Battle sprites are sized for the tactics grid, which reads as oversized
# for background decoration -- shrink it down. Adjust in the Inspector on
# DeploymentUnitPreview.tscn's root, or per-instance after spawning.

var _state: String = "idle"       # "idle" | "acting"
var _state_timer: float = 0.0

# Every distinct attack_animation_name this unit's real abilities use,
# gathered once in setup() -- gives the idle "practicing" flourish at least
# some variety instead of only ever playing one generic animation.
var _ability_anim_names: Array[String] = []

# Never randomly selected for the ambient "practicing" flourish, even if a
# unit's data happens to list one of these as an attack_animation_name --
# reaction/death animations look wrong playing on an idle standing unit.
const EXCLUDED_ANIMATIONS := ["hurt", "die"]


func setup(unit_data: UnitData, spawn_pos: Vector2, wander_bounds: Rect2) -> void:
	# CHANGED: units now just stand at one random spot instead of wandering --
	# bounds is kept only to pick that one spawn point, not for movement.
	bounds = wander_bounds
	position = spawn_pos
	_load_sprite_frames(unit_data)
	_collect_ability_animation_names(unit_data)
	_enter_idle()


func _load_sprite_frames(unit_data: UnitData) -> void:
	# Borrows the real AnimatedSprite2D/SpriteFrames from that unit's actual
	# battle scene -- same path convention battle_manager.gd's spawn_unit()
	# uses -- so this preview shows the exact same art/animations without
	# duplicating any asset references by hand. We only need the
	# SpriteFrames resource, so the temporary instance (with its full
	# UnitNode script, stats, grid logic, etc.) is discarded immediately
	# after we've copied it off.
	var folder_name := unit_data.id.to_lower().replace(" ", "")
	var scene_path := "res://scenes/animations/%s/%s.tscn" % [folder_name, folder_name]
	if not ResourceLoader.exists(scene_path):
		printerr("❌ DeploymentUnitPreview: no battle scene found for '", unit_data.id, "' at ", scene_path)
		return

	var temp_instance = load(scene_path).instantiate()
	if temp_instance.has_node("AnimatedSprite2D"):
		var source_sprite := temp_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
		sprite.sprite_frames = source_sprite.sprite_frames
		# CHANGED: no more movement-direction flipping, so just keep
		# whichever way that unit's battle sprite normally faces by default.
		sprite.flip_h = source_sprite.flip_h
	sprite.scale = Vector2(sprite_scale, sprite_scale)
	temp_instance.queue_free()


func _collect_ability_animation_names(unit_data: UnitData) -> void:
	for level in unit_data.abilities_by_level:
		for ability in unit_data.abilities_by_level[level]:
			if ability != null and ability.attack_animation_name != "" \
			and not EXCLUDED_ANIMATIONS.has(ability.attack_animation_name):
				if not _ability_anim_names.has(ability.attack_animation_name):
					_ability_anim_names.append(ability.attack_animation_name)


func _process(delta: float) -> void:
	# CHANGED: no more "walking" state or position changes at all -- units
	# stand at their spawn point and just alternate between idling and
	# occasionally practicing an ability animation in place.
	_state_timer -= delta
	if _state_timer <= 0.0:
		_pick_next_state()


func _pick_next_state() -> void:
	# ~15% chance to "practice" an ability instead of just idling again,
	# only if this unit actually has an attack animation to show.
	if randf() < 0.15 and not _ability_anim_names.is_empty():
		_enter_acting()
	else:
		_enter_idle()


func _enter_idle() -> void:
	_state = "idle"
	_state_timer = randf_range(1.5, 4.0)
	_play_safe("idle")


func _enter_acting() -> void:
	_state = "acting"
	_state_timer = randf_range(1.0, 1.5)
	_play_safe(_ability_anim_names.pick_random())


func _play_safe(anim_name: String) -> void:
	# Falls back to "idle" if this unit's SpriteFrames don't have the
	# requested animation, instead of erroring or freezing on a bad name.
	# Also refuses to ever play hurt/die here, belt-and-suspenders, even if
	# some future change starts passing one in by accident.
	if sprite == null or sprite.sprite_frames == null:
		return
	if EXCLUDED_ANIMATIONS.has(anim_name):
		anim_name = "idle"
	if sprite.sprite_frames.has_animation(anim_name):
		sprite.play(anim_name)
	elif sprite.sprite_frames.has_animation("idle"):
		sprite.play("idle")
