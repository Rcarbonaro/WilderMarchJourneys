# res://scripts/battle/unit_node.gd

extends Node2D

# 📥 CALLS FROM: UnitData resource file (.tres)
@export var unit_data: UnitData

@export var move_speed: float = 0.25 # 🟢 NEW: Duration of the tile-to-tile slide

# Runtime stats (these change during battle)
var current_hp: int = 0
var current_mana: int = 0
var level: int = 1
var grid_position: Vector2i = Vector2i(0, 0)

# Custom resources (Rage, Panache, Trick Shots, etc.)
var custom_resources: Dictionary = {}

# Active status effects
var active_statuses: Array = []
var ability_cooldowns: Dictionary = {}
var equipped_items: Array = [] 

# Is this a player unit or enemy?
var is_player_unit: bool = true
var has_acted: bool = false
var has_moved: bool = false

# Reference to the grid (set by BattleManager on spawn)
var grid_ref: Node = null

signal unit_died(unit)

func _ready() -> void:
	# 🟢 NEW: Ensure the unit starts in its idle loop
	play_animation("idle")

func setup(data: UnitData, unit_level: int, is_player: bool) -> void:
	unit_data = data
	level = unit_level
	is_player_unit = is_player

	# Load stats for this level
	var stats: StatsData = unit_data.stats_by_level[level - 1]
	current_hp = stats.hp
	current_mana = stats.mana

	# 🟢 NEW: Instead of setting a static texture, we make sure the animation plays
	play_animation("idle")
	_update_hp_label()

# 🟢 NEW: Helper function to safely trigger animations on the child node
func play_animation(anim_name: String) -> void:
	if has_node("AnimatedSprite2D"):
		var sprite = $AnimatedSprite2D as AnimatedSprite2D
		if sprite.sprite_frames.has_animation(anim_name):
			sprite.play(anim_name)

func get_stats() -> StatsData:
	return unit_data.stats_by_level[level - 1]

func get_effective_atk() -> int:
	var base = get_stats().atk
	for status_instance in active_statuses:
		var data: StatusEffectData = status_instance["data"]
		base += data.atk_modifier * status_instance["stacks"]
	return max(0, base)

func get_effective_def() -> int:
	var base = get_stats().def
	for status_instance in active_statuses:
		var data: StatusEffectData = status_instance["data"]
		base += data.def_modifier * status_instance["stacks"]
	return max(0, base)

func get_effective_mov() -> int:
	var base = get_stats().mov
	for status_instance in active_statuses:
		var data: StatusEffectData = status_instance["data"]
		if status_instance["data"].is_root:
			return 0 
		base += data.mov_modifier * status_instance["stacks"]
	return max(0, base)

func get_effective_crit_chance() -> float:
	var base = get_stats().crit_chance
	for status_instance in active_statuses:
		base += status_instance["data"].crit_chance_modifier * status_instance["stacks"]
	return base

func take_damage(amount: int, damage_type: String) -> int:
	var actual = max(1, amount)
	current_hp -= actual
	_update_hp_label()
	
	if current_hp <= 0:
		die()
	else:
		# 🟢 NEW: Play hurt animation if they survive the hit
		play_animation("hurt")
		# Briefly wait, then go back to idle if they haven't died
		get_tree().create_timer(0.25).timeout.connect(func():
			if current_hp > 0:
				play_animation("idle")
		)
		
	return actual

func heal(amount: int) -> void:
	var max_hp = get_stats().hp
	current_hp = min(current_hp + amount, max_hp)
	_update_hp_label()

func die() -> void:
	# Guard clause: Don't die twice
	if not is_inside_tree():
		queue_free()
		return
		
	print(unit_data.display_name, " has been defeated!")
	
	# 1. Take them off the tactical grid immediately so nobody can target them again
	if grid_ref != null and grid_ref.has_method("unregister_unit"):
		grid_ref.unregister_unit(grid_position)
		
	# 2. Tell the BattleManager right away so team lists update
	unit_died.emit(self)
	
	# 3. Play death animation or hide them visually so they look dead to the player
	if has_node("AnimatedSprite2D"):
		$AnimatedSprite2D.play("death")
	else:
		hide() # Invisible fallback
		
	# 4. Instead of destroying the node code-side right this millisecond,
	# use call_deferred to delete it at the very end of the engine's frame loop.
	# This keeps 'get_tree()' valid for the remainder of this ability execution!
	queue_free.call_deferred()


func move_to(new_cell: Vector2i) -> void:
	if grid_ref != null:
		# 1. Clear the old position on the grid matrix
		grid_ref.unregister_unit(grid_position)
		
		# 2. Update to the new coordinate
		grid_position = new_cell
		
		# 3. Register on the grid matrix at the new location
		grid_ref.register_unit(self, new_cell)
		
		# 4. 🟢 UPDATED: Calculate world pos and slide smoothly with Tweens
		var target_world_position: Vector2 = grid_ref.grid_to_world(new_cell)
		
		play_animation("walk")
		
		var tween = create_tween()
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.set_ease(Tween.EASE_OUT)
		tween.tween_property(self, "position", target_world_position, move_speed)
		
		# Return to idle once the slide completes
		tween.tween_callback(func(): play_animation("idle"))

	has_moved = true

func apply_status(status_data: StatusEffectData, stacks: int = 1) -> void:
	for s in active_statuses:
		if s["data"].grants_immunity: return
	for s in active_statuses:
		if s["data"].id == status_data.id:
			if status_data.can_stack:
				s["stacks"] = min(s["stacks"] + stacks, status_data.max_stacks)
			s["remaining_rounds"] = status_data.duration_rounds
			return

	active_statuses.append({
		"data": status_data,
		"stacks": stacks,
		"remaining_rounds": status_data.duration_rounds
	})

func tick_statuses_end_of_round(round_owner: String) -> void:
	var to_remove = []
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		if data.expires_at == "end_of_" + round_owner + "_round":
			s["remaining_rounds"] -= 1
			if s["remaining_rounds"] <= 0:
				to_remove.append(s)
	for s in to_remove:
		active_statuses.erase(s)

func _update_hp_label() -> void:
	if has_node("HPLabel"):
		$HPLabel.text = str(current_hp) + "/" + str(get_stats().hp)
