# res://scripts/battle/unit_node.gd

# 📥 CALLS FROM: UnitData resource — reads all base stats from it

# 📤 EXPORTS TO: BattleManager — battle reads current HP, position, status effects

# 📤 EXPORTS TO: AbilityExecutor — executor queries this unit's stats when resolving attacks

# 📤 EXPORTS TO: BattleGrid — registers/unregisters position here

extends Node2D

# The data resource for this unit (set this in the Inspector or via code)

# 📥 CALLS FROM: UnitData resource file (.tres)

@export var unit_data: UnitData

# Runtime stats (these change during battle)

var current_hp: int = 0

var current_mana: int = 0

var level: int = 1

var grid_position: Vector2i = Vector2i(0, 0)

# Custom resources (Rage, Panache, Trick Shots, etc.)

var custom_resources: Dictionary = {}

# Active status effects (list of active instances)

# Each entry: { "data": StatusEffectData, "stacks": int, "remaining_rounds": int }

# 📤 EXPORTS TO: StatusManager which processes these each round

var active_statuses: Array = []

# Ability cooldowns: Dictionary of ability_id -> rounds remaining

var ability_cooldowns: Dictionary = {}

# Equipment slots

var equipped_items: Array = []  # up to 2 items per unit

# Is this a player unit or enemy?

var is_player_unit: bool = true

# Has this unit acted this turn?

var has_acted: bool = false

var has_moved: bool = false

# Reference to the grid (set by BattleManager on spawn)

# 📥 CALLS FROM: BattleManager when it spawns this unit

var grid_ref: Node = null

func setup(data: UnitData, unit_level: int, is_player: bool) -> void:

	# Called by BattleManager when spawning this unit

	# 📥 CALLS FROM: BattleManager.spawn_unit()

	unit_data = data

	level = unit_level

	is_player_unit = is_player

	# Load stats for this level

	var stats: StatsData = unit_data.stats_by_level[level - 1]

	current_hp = stats.hp

	current_mana = stats.mana

	# Set sprite

	$UnitSprite.texture = unit_data.battle_sprite

	_update_hp_label()

func get_stats() -> StatsData:

	# Returns the base stats for this unit's current level

	# 📤 EXPORTS TO: AbilityExecutor — damage calculation reads stats from here

	return unit_data.stats_by_level[level - 1]

func get_effective_atk() -> int:

	# Returns ATK after applying all active status modifiers

	# 📤 EXPORTS TO: AbilityExecutor — actual damage calc uses this, not raw stats

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

			return 0  # Rooted = can't move at all

		base += data.mov_modifier * status_instance["stacks"]

	return max(0, base)

func get_effective_crit_chance() -> float:

	var base = get_stats().crit_chance

	for status_instance in active_statuses:

		base += status_instance["data"].crit_chance_modifier * status_instance["stacks"]

	return base

func take_damage(amount: int, damage_type: String) -> int:

	# Applies damage after defense calculations (defense applied BEFORE calling this)

	# 📥 CALLS FROM: AbilityExecutor after it calculates final damage

	var actual = max(1, amount)

	current_hp -= actual

	_update_hp_label()

	if current_hp <= 0:

		die()

	return actual

func heal(amount: int) -> void:

	var max_hp = get_stats().hp

	current_hp = min(current_hp + amount, max_hp)

	_update_hp_label()

func die() -> void:

	# 📤 EXPORTS TO: BattleManager — manager listens for this to check win/loss

	grid_ref.unregister_unit(grid_position)

	emit_signal("unit_died", self)

	queue_free()

signal unit_died(unit)

func move_to(new_cell: Vector2i) -> void:
	if grid_ref != null:
		# 1. Clear the old position on the grid matrix
		grid_ref.unregister_unit(grid_position)
		
		# 2. Update to the new coordinate
		grid_position = new_cell
		
		# 3. Register on the grid matrix at the new location so others can't phase through you
		grid_ref.register_unit(self, new_cell)
		
		# 4. Physically slide/snap the sprite on screen to the correct position vector
		position = grid_ref.grid_to_world(new_cell)

	has_moved = true

func apply_status(status_data: StatusEffectData, stacks: int = 1) -> void:

	# Applies a status effect to this unit

	# 📥 CALLS FROM: AbilityExecutor after an ability resolves

	# Check immunity

	for s in active_statuses:

		if s["data"].grants_immunity: return  # immune, do nothing

	# Check if already have this status

	for s in active_statuses:

		if s["data"].id == status_data.id:

			if status_data.can_stack:

				s["stacks"] = min(s["stacks"] + stacks, status_data.max_stacks)

			# Refresh duration either way

			s["remaining_rounds"] = status_data.duration_rounds

			return

	# New status — add it

	active_statuses.append({

		"data": status_data,

		"stacks": stacks,

		"remaining_rounds": status_data.duration_rounds

	})

func tick_statuses_end_of_round(round_owner: String) -> void:

	# Called at end of the appropriate team's round to count down durations

	# 📥 CALLS FROM: BattleManager.end_round()

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

	$HPLabel.text = str(current_hp) + "/" + str(get_stats().hp)
