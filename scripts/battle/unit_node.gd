# res://scripts/battle/unit_node.gd
#
# This script lives on every character in the battle — heroes and monsters alike.
# Think of it as the "body" of the unit: it stores its current health, position,
# active status effects, and handles animations.

extends Node2D

# ── DATA LINK ─────────────────────────────────────────────────────────────────

@export var unit_data: UnitData
# The "data card" resource (.tres file) that holds the unit's name, stats, and
# abilities. You drag this in from the Inspector on the scene.

@export var move_speed: float = 1.5
# How many seconds the sliding movement animation takes per tile-to-tile move.

@export var faces_right_by_default: bool = true
# ✅ CHECK THIS in the Inspector for player/ally units (they face right).
# ✅ UNCHECK THIS for enemy units (they face left by default).
# This single setting drives all the flip logic below.

# ── RUNTIME STATS ─────────────────────────────────────────────────────────────
# These values start from the data card but change during battle (taking damage, etc.)

var current_hp: int = 0
var current_mana: int = 0
var level: int = 1
var grid_position: Vector2i = Vector2i(0, 0)
var custom_resources: Dictionary = {}
var active_statuses: Array = []
var ability_cooldowns: Dictionary = {}
var equipped_items: Array = []

# ── STATE FLAGS ───────────────────────────────────────────────────────────────

var is_player_unit: bool = true
var has_acted: bool = false
var has_moved: bool = false

# 🆕 NEW: Cancel-movement support.
# Before a unit uses an ability, they can undo their movement and return here.
var pre_move_position: Vector2i = Vector2i(-1, -1)
# This flag is true only between "unit finished moving" and "unit used an ability".
# The Cancel Move button is only shown when this is true.
var can_cancel_move: bool = false

# ── REFERENCES ────────────────────────────────────────────────────────────────

var grid_ref: Node = null
# Filled in by BattleManager when the unit is spawned. Lets the unit ask the
# grid questions like "where am I in pixel space?" and "register me at cell X".

signal unit_died(unit)
# Emitted when HP reaches 0. BattleManager listens so it can update team lists.

signal movement_finished
# Emitted when the slide tween finishes. BattleManager awaits this so it does
# not run post-move logic before the animation completes.

# ── LIFECYCLE ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# As soon as this node enters the scene tree, start playing the idle animation.
	play_animation("idle")


func setup(data: UnitData, unit_level: int, is_player: bool) -> void:
	# Called by BattleManager right after instantiating this scene.
	# It passes in the data card, the level, and whether this is a player unit.
	unit_data = data
	level = unit_level
	is_player_unit = is_player

	# Load this level's stats (stats_by_level is a list; level 1 is index 0).
	var stats: StatsData = unit_data.stats_by_level[level - 1]
	current_hp = stats.hp
	current_mana = stats.mana

	# 🆕 Apply the default facing direction immediately on spawn.
	# Enemy units have faces_right_by_default = false, so they start flipped left.
	_apply_default_facing()

	play_animation("idle")
	_update_hp_label()


# ── ANIMATION HELPERS ─────────────────────────────────────────────────────────

func _apply_default_facing() -> void:
	# Reads the faces_right_by_default flag and flips the sprite accordingly.
	# Player units: faces_right_by_default = true  → no flip needed.
	# Enemy units:  faces_right_by_default = false → flip_h = true (mirror left).
	if has_node("AnimatedSprite2D"):
		$AnimatedSprite2D.flip_h = not faces_right_by_default


func play_animation(anim_name: String) -> void:
	# Safely plays a named animation on the AnimatedSprite2D child node.
	# If the animation does not exist in the SpriteFrames, we fall back gracefully
	# rather than crashing.
	if not has_node("AnimatedSprite2D"):
		return  # No sprite node at all — skip silently.

	var sprite := $AnimatedSprite2D as AnimatedSprite2D

	# 🆕 FALLBACK LOGIC:
	# Some units may not have every animation. Rather than crash or play nothing,
	# we redirect to a sensible default.
	var actual_anim := anim_name
	match anim_name:
		"attack_up", "attack_down":
			# If there is no directional attack, use the regular attack animation.
			if not sprite.sprite_frames.has_animation(anim_name):
				actual_anim = "attack"
		"walk_up":
			# If there is no walk_up, use the regular walk animation.
			if not sprite.sprite_frames.has_animation(anim_name):
				actual_anim = "walk"

	# Final safety check: if even the fallback doesn't exist, do nothing.
	if sprite.sprite_frames.has_animation(actual_anim):
		sprite.play(actual_anim)


func _set_facing_for_direction(target_pos: Vector2i) -> void:
	# Determines which way the unit should face based on where it is going / attacking,
	# then applies the correct horizontal flip.
	#
	# HOW THE XOR FLIP LOGIC WORKS:
	#   Imagine two true/false questions:
	#     A = "Is the target to my right?"
	#     B = "Do I face right by default?"
	#   If both are the same (both true, or both false), no flip is needed.
	#   If they differ, a flip is needed.
	#   This is exactly what the != operator does (it acts as XOR here).
	#
	# Examples:
	#   Player (faces right), target is to the right: no flip. ✅
	#   Player (faces right), target is to the left:  flip.   ↔️
	#   Enemy  (faces left),  target is to the right: flip.   ↔️
	#   Enemy  (faces left),  target is to the left:  no flip.✅

	if not has_node("AnimatedSprite2D"):
		return

	var sprite := $AnimatedSprite2D as AnimatedSprite2D
	var target_is_right: bool = target_pos.x > grid_position.x
	sprite.flip_h = (target_is_right != faces_right_by_default)


# ── STAT GETTERS ──────────────────────────────────────────────────────────────
# These functions read base stats and add bonuses from active status effects.

func get_stats() -> StatsData:
	return unit_data.stats_by_level[level - 1]


func get_effective_atk() -> int:
	var base = get_stats().atk
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		base += data.atk_modifier * s["stacks"]
	return max(0, base)


func get_effective_matk() -> int:
	# 🆕 NEW: Magic attack also needs to respect status modifiers.
	var base = get_stats().matk
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		base += data.matk_modifier * s["stacks"]
	return max(0, base)


func get_effective_def() -> int:
	var base = get_stats().def
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		base += data.def_modifier * s["stacks"]
	return max(0, base)


func get_effective_mdef() -> int:
	# 🆕 NEW: Magic defense with status modifiers.
	var base = get_stats().mdef
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		base += data.mdef_modifier * s["stacks"]
	return max(0, base)


func get_effective_mov() -> int:
	var base = get_stats().mov
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		if data.is_root:
			return 0  # Root effect: unit cannot move at all.
		base += data.mov_modifier * s["stacks"]
	return max(0, base)


func get_effective_crit_chance() -> float:
	var base = get_stats().crit_chance
	for s in active_statuses:
		base += s["data"].crit_chance_modifier * s["stacks"]
	return base

# ── COMBAT ────────────────────────────────────────────────────────────────────

func take_damage(amount: int, damage_type: String) -> int:
	# Applies damage to this unit. Always deals at least 1. Returns actual amount.
	var actual = max(1, amount)
	current_hp -= actual
	_update_hp_label()

	if current_hp <= 0:
		die()
	else:
		play_animation("hurt")
		# After a short flash, return to idle if the unit survived.
		get_tree().create_timer(0.25).timeout.connect(func():
			if is_instance_valid(self) and current_hp > 0:
				play_animation("idle")
		)

	return actual


func heal(amount: int) -> void:
	var max_hp = get_stats().hp
	current_hp = min(current_hp + amount, max_hp)
	_update_hp_label()


func die() -> void:
	if not is_inside_tree():
		queue_free()
		return

	print(unit_data.display_name, " has been defeated!")

	if grid_ref != null and grid_ref.has_method("unregister_unit"):
		grid_ref.unregister_unit(grid_position)

	unit_died.emit(self)

	if has_node("AnimatedSprite2D"):
		$AnimatedSprite2D.play("die")
	else:
		hide()

	queue_free.call_deferred()

# ── MOVEMENT ──────────────────────────────────────────────────────────────────

func move_to(new_cell: Vector2i) -> void:
	# Moves the unit to a new grid cell, updating the grid registry and sliding
	# the visual position smoothly using a Tween.
	if grid_ref == null:
		return

	# Determine direction of travel so we can flip the sprite appropriately.
	_set_facing_for_direction(new_cell)

	# Choose the correct walk animation based on the vertical direction.
	var dy = new_cell.y - grid_position.y
	if dy < 0:
		# Moving upward on the grid.
		play_animation("walk_up")  # Falls back to "walk" if not defined.
	else:
		play_animation("walk")

	# Update the grid registry: remove from old tile, add to new tile.
	grid_ref.unregister_unit(grid_position)
	grid_position = new_cell
	grid_ref.register_unit(self, new_cell)

	# Convert the grid coordinate to a screen pixel position.
	var target_world_pos: Vector2 = grid_ref.grid_to_world(new_cell)

	# Tween = a smooth animation between two values over time.
	var tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)  # Cubic easing = fast start, slow finish (natural feel).
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "position", target_world_pos, move_speed)

	# When the tween finishes, return to idle and fire the signal.
	tween.tween_callback(func():
		play_animation("idle")
		movement_finished.emit()
	)


func look_at_target(target_pos: Vector2i) -> void:
	# Faces this unit toward the target tile.
	# Called by the AI before it attacks so enemies look at their victim.
	_set_facing_for_direction(target_pos)

	# Also choose attack animation based on vertical direction.
	var dy = target_pos.y - grid_position.y
	if dy < -1:
		play_animation("attack_up")   # Falls back to "attack" if missing.
	elif dy > 1:
		play_animation("attack_down") # Falls back to "attack" if missing.
	# Horizontal attacks use "attack" which is the default — no call needed here,
	# BattleManager / AISystem calls play_animation("attack") separately.

# ── STATUS EFFECTS ────────────────────────────────────────────────────────────

func apply_status(status_data: StatusEffectData, stacks: int = 1) -> void:
	# First check if the unit has immunity (blocks all new debuffs).
	for s in active_statuses:
		if s["data"].grants_immunity:
			print("🛡️ ", unit_data.display_name, " is immune! Status '", status_data.display_name, "' blocked.")
			return

	# Check if this status is already active on the unit.
	for s in active_statuses:
		if s["data"].id == status_data.id:
			if status_data.can_stack:
				# Add stacks, but don't exceed the maximum.
				s["stacks"] = min(s["stacks"] + stacks, status_data.max_stacks)
			# Refresh the duration regardless.
			s["remaining_rounds"] = status_data.duration_rounds
			_debug_print_status_applied(status_data, s["stacks"])
			return

	# Status is new — add it to the list.
	active_statuses.append({
		"data": status_data,
		"stacks": stacks,
		"remaining_rounds": status_data.duration_rounds
	})
	_debug_print_status_applied(status_data, stacks)


func _debug_print_status_applied(status_data: StatusEffectData, stacks: int) -> void:
	# 🆕 NEW: Prints current stats to the console after a status is applied.
	# This lets you verify that status effects are actually changing the numbers.
	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	print("📊 STATUS APPLIED: '", status_data.display_name, "' × ", stacks, " stack(s) → ", unit_data.display_name)
	print("   ATK:  base=", get_stats().atk, "  effective=", get_effective_atk())
	print("   MATK: base=", get_stats().matk, "  effective=", get_effective_matk())
	print("   DEF:  base=", get_stats().def, "  effective=", get_effective_def())
	print("   MDEF: base=", get_stats().mdef, "  effective=", get_effective_mdef())
	print("   MOV:  base=", get_stats().mov, "  effective=", get_effective_mov())
	print("   Status modifiers this effect provides:")
	print("     atk_modifier=",   status_data.atk_modifier,
		  "  def_modifier=",      status_data.def_modifier,
		  "  matk_modifier=",     status_data.matk_modifier,
		  "  mdef_modifier=",     status_data.mdef_modifier,
		  "  mov_modifier=",      status_data.mov_modifier)
	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")


func tick_statuses_end_of_round(round_owner: String) -> void:
	# Counts down duration on each active status at the end of the appropriate round.
	# round_owner is "player" or "enemy" — only statuses that expire at that time tick.
	var to_remove = []
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		if data.expires_at == "end_of_" + round_owner + "_round":
			s["remaining_rounds"] -= 1
			if s["remaining_rounds"] <= 0:
				to_remove.append(s)
				print("⌛ Status '", data.display_name, "' expired on ", unit_data.display_name)

	for s in to_remove:
		active_statuses.erase(s)

# ── PRIVATE HELPERS ───────────────────────────────────────────────────────────

func _update_hp_label() -> void:
	# Updates the floating HP text above the unit's head.
	if has_node("HPLabel"):
		$HPLabel.text = str(current_hp) + "/" + str(get_stats().hp)
