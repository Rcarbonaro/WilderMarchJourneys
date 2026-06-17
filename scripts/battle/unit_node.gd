# res://scripts/battle/unit_node.gd
#
# This script lives on EVERY character in battle — heroes and monsters alike.
# Think of it as the unit's "body": it tracks HP, mana, position, status
# effects, animations, and responds to damage or healing.
#
# NEW ADDITIONS:
#   - Multi-tile unit support (occupied_cells, large unit movement & death)
#   - Mana check helpers (can_afford_ability, spend_mana)
#   - Post-attack movement flag
#   - Tether cleanup on death
#   - Shield/Thorns/Guardian applied via battle_grid on death

extends Node2D

# ── DATA LINK ─────────────────────────────────────────────────────────────────

@export var unit_data: UnitData
# The "data card" resource (.tres file) that holds the unit's name, stats, and
# abilities. You drag this in from the Inspector on the scene.

@export var move_speed: float = 1.5
# How many seconds the sliding movement animation takes per tile-to-tile move.

@export var faces_right_by_default: bool = true
# ✅ CHECK for player/ally units (they face right).
# ✅ UNCHECK for enemy units (they face left by default).

# ── MULTI-TILE SUPPORT ────────────────────────────────────────────────────────

@export var tile_footprint: Array = [Vector2i(0,0)]
# The list of OFFSETS (relative to grid_position / the "anchor" cell) that this
# unit occupies. A normal 1×1 unit has just [Vector2i(0,0)].
# A 2×2 unit would have: [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)]
# The anchor cell is the TOP-LEFT corner of the unit.
#
# HOW TO SET THIS IN THE INSPECTOR:
#   1. Open the unit's scene or the unit_data resource.
#   2. Find "Tile Footprint" in the Inspector.
#   3. Add one Vector2i entry per tile the unit occupies.

var occupied_cells: Array = []
# The ACTUAL grid cells this unit currently occupies (computed at runtime by
# applying tile_footprint offsets to grid_position). Updated every time the
# unit moves.

# ── Spellsword Arcana Charges ───────────────────────────────────────────────────────────
@export var is_spellsword: bool = false 
var has_arcana_charge: bool = false

# ── RUNTIME STATS ─────────────────────────────────────────────────────────────

var current_hp:   int = 0
var current_mana: int = 0
var level:        int = 1
var grid_position: Vector2i = Vector2i(0, 0)
# The "anchor" cell (top-left for large units).

var custom_resources:   Dictionary = {}
var active_statuses:    Array      = []
var ability_cooldowns:  Dictionary = {}
var equipped_items:     Array      = []

# ── STATE FLAGS ───────────────────────────────────────────────────────────────

var is_player_unit:   bool = true
var has_acted:        bool = false
var has_moved:        bool = false

var pre_move_position: Vector2i = Vector2i(-1, -1)
# Saved before moving so the player can cancel and undo.

var can_cancel_move: bool = false
# True only between "unit finished moving" and "unit used an ability".

var pending_post_attack_moves: int = 0
# If an ability has post_attack_move_squares > 0, this is set after the attack
# so the battle_manager can grant the unit extra movement.

# ── TETHER TRACKING ───────────────────────────────────────────────────────────

var tether_ids: Array = []
# Stores the tether_id strings this unit is currently linked to.
# Populated by ability_executor when a tether ability is used.
# Cleared from battle_grid on death.

# ── REFERENCES ────────────────────────────────────────────────────────────────

var grid_ref: Node = null
# Filled in by BattleManager when the unit is spawned.

signal unit_died(unit)
# Emitted when HP reaches 0. BattleManager listens so it can update team lists.

signal movement_finished
# Emitted when the slide tween finishes. BattleManager awaits this.

# ── LIFECYCLE ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	play_animation("idle")


func setup(data: UnitData, unit_level: int, is_player: bool) -> void:
	# Called by BattleManager right after instantiating this scene.
	unit_data    = data
	level        = unit_level
	is_player_unit = is_player

	var stats: StatsData = unit_data.stats_by_level[level - 1]
	current_hp   = stats.hp
	current_mana = stats.mana

	_apply_default_facing()
	play_animation("idle")
	_update_hp_label()

	# Compute occupied cells from the default footprint at the starting position.
	_update_occupied_cells()

# ── MULTI-TILE HELPERS ────────────────────────────────────────────────────────

func _update_occupied_cells() -> void:
	# Recomputes which grid cells this unit occupies based on its anchor position
	# and its tile_footprint offsets. Call this after any position change.
	occupied_cells.clear()
	for offset in tile_footprint:
		occupied_cells.append(grid_position + offset)


func get_center_world_position() -> Vector2:
	# Returns the visual center of a large unit in world (pixel) space.
	# For a 1×1 unit this is just its position. For 2×2 it's the midpoint.
	if grid_ref == null:
		return position
	var min_cell = occupied_cells[0]
	var max_cell = occupied_cells[0]
	for c in occupied_cells:
		min_cell.x = min(min_cell.x, c.x)
		min_cell.y = min(min_cell.y, c.y)
		max_cell.x = max(max_cell.x, c.x)
		max_cell.y = max(max_cell.y, c.y)
	var center_cell = Vector2i(
		(min_cell.x + max_cell.x) / 2,
		(min_cell.y + max_cell.y) / 2
	)
	return grid_ref.grid_to_world(center_cell)

# ── ANIMATION HELPERS ─────────────────────────────────────────────────────────

func _apply_default_facing() -> void:
	if has_node("AnimatedSprite2D"):
		$AnimatedSprite2D.flip_h = not faces_right_by_default


func play_animation(anim_name: String) -> void:
	# Safely plays a named animation, falling back gracefully if missing.
	if not has_node("AnimatedSprite2D"):
		return
	var sprite := $AnimatedSprite2D as AnimatedSprite2D
	var actual_anim := anim_name
	match anim_name:
		"attack_up", "attack_down":
			if not sprite.sprite_frames.has_animation(anim_name):
				actual_anim = "attack"
		"walk_up":
			if not sprite.sprite_frames.has_animation(anim_name):
				actual_anim = "walk"
	if sprite.sprite_frames.has_animation(actual_anim):
		sprite.play(actual_anim)
	if anim_name == "idle" and has_arcana_charge:
		sprite.play("arcana_charge")
		return


func _set_facing_for_direction(target_pos: Vector2i) -> void:
	if not has_node("AnimatedSprite2D"):
		return
	var sprite := $AnimatedSprite2D as AnimatedSprite2D
	var target_is_right: bool = target_pos.x > grid_position.x
	sprite.flip_h = (target_is_right != faces_right_by_default)

# ── STAT GETTERS ──────────────────────────────────────────────────────────────

func get_stats() -> StatsData:
	return unit_data.stats_by_level[level - 1]


func get_effective_atk() -> int:
	var base = get_stats().atk
	for s in active_statuses:
		base += s["data"].atk_modifier * s["stacks"]
	return max(0, base)


func get_effective_matk() -> int:
	var base = get_stats().matk
	for s in active_statuses:
		base += s["data"].matk_modifier * s["stacks"]
	return max(0, base)


func get_effective_def() -> int:
	var base = get_stats().def
	for s in active_statuses:
		base += s["data"].def_modifier * s["stacks"]
	return max(0, base)


func get_effective_mdef() -> int:
	var base = get_stats().mdef
	for s in active_statuses:
		base += s["data"].mdef_modifier * s["stacks"]
	return max(0, base)


func get_effective_mov() -> int:
	var base = get_stats().mov
	for s in active_statuses:
		if s["data"].is_root:
			return 0   # Rooted units cannot move at all.
		base += s["data"].mov_modifier * s["stacks"]
	return max(0, base)


func get_effective_crit_chance() -> float:
	var base = get_stats().crit_chance
	for s in active_statuses:
		base += s["data"].crit_chance_modifier * s["stacks"]
	return base

# ── MANA ──────────────────────────────────────────────────────────────────────

func can_afford_ability(ability: AbilityData) -> bool:
	# Returns true if the unit currently has enough mana to use this ability.
	# Also checks HP cost won't kill the unit outright.
	# This is called by ui_manager (to grey buttons) and by ability_executor
	# (as a final safety gate before executing).
	if current_mana < ability.mana_cost:
		return false
	if ability.hp_cost_percent > 0.0:
		var hp_cost = int(get_stats().hp * ability.hp_cost_percent)
		if hp_cost >= current_hp:
			return false   # Would be fatal — block it.
	return true


func spend_mana(amount: int) -> void:
	# Deducts mana, clamped so it never goes below 0.
	current_mana = max(0, current_mana - amount)

# ── COMBAT ────────────────────────────────────────────────────────────────────

func take_damage(amount: int, damage_type: String) -> int:
	# Applies damage to this unit. Always deals at least 1. Returns actual amount.
	#
	# For multi-tile units: damage is applied to the UNIT, not the tile.
	# Even if an AOE hits all 4 tiles of a 2×2 unit, this function is only
	# called ONCE per damage event (ability_executor deduplicates by unit reference).
	var actual = max(1, amount)
	current_hp -= actual
	_update_hp_label()

	if current_hp <= 0:
		die()
	else:
		play_animation("hurt")
		get_tree().create_timer(0.25).timeout.connect(func():
			if is_instance_valid(self) and current_hp > 0:
				play_animation("idle")
		)
	return actual


func heal(amount: int) -> void:
	var max_hp = get_stats().hp
	current_hp = min(current_hp + amount, max_hp)
	_update_hp_label()


func restore_mana(amount: int) -> void:
	# Restores mana up to the stat maximum.
	var max_mana = get_stats().mana
	current_mana = min(current_mana + amount, max_mana)


func die() -> void:
	if not is_inside_tree():
		queue_free()
		return

	print(unit_data.display_name, " has been defeated!")

	# Unregister ALL cells this unit occupied (handles large units).
	if grid_ref != null:
		if tile_footprint.size() > 1:
			# Multi-tile unit: remove every occupied cell.
			grid_ref.unregister_large_unit(self)
		else:
			grid_ref.unregister_unit(grid_position)

	# Remove this unit from every tether group it belonged to.
	if grid_ref != null and grid_ref.has_method("unregister_tether"):
		for tid in tether_ids:
			grid_ref.unregister_tether(self, tid)

	# Remove any guardian or shield entries pointing to this unit.
	if grid_ref != null:
		if grid_ref.shield_map.has(self):
			grid_ref.shield_map.erase(self)
		if grid_ref.guardian_map.has(self):
			grid_ref.guardian_map.erase(self)
		if grid_ref.thorns_map.has(self):
			grid_ref.thorns_map.erase(self)

	unit_died.emit(self)

	if has_node("AnimatedSprite2D"):
		$AnimatedSprite2D.play("die")
	else:
		hide()

	queue_free.call_deferred()

# ── MOVEMENT ──────────────────────────────────────────────────────────────────

func move_to(new_cell: Vector2i) -> void:
	# Moves the unit to a new anchor cell, updating the grid registry and sliding
	# the visual position smoothly using a Tween.
	if grid_ref == null:
		return

	_set_facing_for_direction(new_cell)

	var dy = new_cell.y - grid_position.y
	if dy < 0:
		play_animation("walk_up")
	else:
		play_animation("walk")

	# For multi-tile units: unregister ALL current cells, then register ALL new cells.
	if tile_footprint.size() > 1:
		grid_ref.unregister_large_unit(self)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_large_unit(self, occupied_cells)
	else:
		grid_ref.unregister_unit(grid_position)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_unit(self, new_cell)

	# Slide the visual to the new anchor world position.
	var target_world_pos: Vector2 = grid_ref.grid_to_world(new_cell)
	var tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "position", target_world_pos, move_speed)
	tween.tween_callback(func():
		play_animation("idle")
		movement_finished.emit()
	)


func snap_to(new_cell: Vector2i) -> void:
	# Instantly teleports the unit with no animation (used by dash and cancel-move).
	if grid_ref == null:
		return
	if tile_footprint.size() > 1:
		grid_ref.unregister_large_unit(self)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_large_unit(self, occupied_cells)
	else:
		grid_ref.unregister_unit(grid_position)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_unit(self, new_cell)
	position = grid_ref.grid_to_world(new_cell)


func look_at_target(target_pos: Vector2i) -> void:
	_set_facing_for_direction(target_pos)
	var dy = target_pos.y - grid_position.y
	if dy < -1:
		play_animation("attack_up")
	elif dy > 1:
		play_animation("attack_down")

# ── STATUS EFFECTS ────────────────────────────────────────────────────────────

func apply_status(status_data: StatusEffectData, stacks: int = 1) -> void:
	# Check for immunity first.
	for s in active_statuses:
		if s["data"].grants_immunity:
			print("🛡️ ", unit_data.display_name, " is immune! Status '", status_data.display_name, "' blocked.")
			return

	# If already active, refresh or stack.
	for s in active_statuses:
		if s["data"].id == status_data.id:
			if status_data.can_stack:
				s["stacks"] = min(s["stacks"] + stacks, status_data.max_stacks)
			s["remaining_rounds"] = status_data.duration_rounds
			_debug_print_status_applied(status_data, s["stacks"])
			return

	# New status: add it.
	active_statuses.append({
		"data":             status_data,
		"stacks":           stacks,
		"remaining_rounds": status_data.duration_rounds
	})
	_debug_print_status_applied(status_data, stacks)
	update_visuals()


func remove_status(status_id: String) -> void:
	# Removes a status by its id string. Used for cleanse effects.
	active_statuses = active_statuses.filter(func(s): return s["data"].id != status_id)


func tick_statuses_end_of_round(team_that_just_ended: String) -> void:
	# Called at the end of a round (from BattleManager) to count down durations
	# and remove any that have expired.
	var to_remove = []
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		if data.is_permanent:
			continue
		# Only count down statuses that expire on this team's round.
		if data.expires_at == "end_of_player_round" and team_that_just_ended == "player":
			s["remaining_rounds"] -= 1
		elif data.expires_at == "end_of_enemy_round" and team_that_just_ended == "enemy":
			s["remaining_rounds"] -= 1
		if s["remaining_rounds"] <= 0:
			to_remove.append(s)
	for s in to_remove:
		active_statuses.erase(s)
	


func get_buff_count() -> int:
	# Returns how many BUFF (positive) statuses this unit has.
	# A buff is defined as any status that gives at least one positive stat modifier
	# and none of the negative flags (stun, root, etc.).
	var count = 0
	for s in active_statuses:
		var d: StatusEffectData = s["data"]
		if d.is_stun or d.is_root:
			continue  # These are always debuffs.
		var is_positive = (d.atk_modifier > 0 or d.def_modifier > 0 or
						   d.matk_modifier > 0 or d.mdef_modifier > 0 or
						   d.mov_modifier > 0 or d.crit_chance_modifier > 0 or
						   d.damage_dealt_modifier > 0 or d.damage_taken_modifier < 0 or
						   d.grants_immunity)
		if is_positive:
			count += s["stacks"]
	return count


func get_debuff_count() -> int:
	# Returns how many DEBUFF (negative) statuses this unit has.
	var count = 0
	for s in active_statuses:
		var d: StatusEffectData = s["data"]
		var is_negative = (d.is_stun or d.is_root or d.is_invisible or
						   d.atk_modifier < 0 or d.def_modifier < 0 or
						   d.matk_modifier < 0 or d.mdef_modifier < 0 or
						   d.mov_modifier < 0 or d.damage_taken_modifier > 0 or
						   d.damage_dealt_modifier < 0)
		if is_negative:
			count += s["stacks"]
	return count

# ── UI HELPERS ────────────────────────────────────────────────────────────────

func _update_hp_label() -> void:
	# Updates the floating HP label above the unit's head (if one exists).
	if has_node("HPLabel"):
		$HPLabel.text = str(current_hp)


func _debug_print_status_applied(status_data: StatusEffectData, stacks: int) -> void:
	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	print("📊 STATUS APPLIED: '", status_data.display_name, "' × ", stacks, " → ", unit_data.display_name)
	print("   ATK:  base=", get_stats().atk,  "  effective=", get_effective_atk())
	print("   DEF:  base=", get_stats().def,  "  effective=", get_effective_def())
	print("   MOV:  base=", get_stats().mov,  "  effective=", get_effective_mov())


# Inside res://scripts/battle/unit_node.gd

func has_status(status_id: String) -> bool:
	# Iterate through the actual list being used by your status system
	for s in active_statuses:
		if s["data"].id == status_id:
			return true
	return false


func update_visuals() -> void:
	var sprite = $AnimatedSprite2D # Adjust the path if your sprite is named differently
	if has_status("invisible"):
		sprite.modulate.a = 0.5 # 50% transparency
	else:
		sprite.modulate.a = 1.0 # Fully opaque
