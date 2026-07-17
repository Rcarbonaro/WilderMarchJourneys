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
#   - momentum_bonuses dictionary for Momentum aura stat tracking
#   - get_effective_crit_damage() so Momentum crit bonuses apply
#   - die() notifies AuraManager to strip bonuses and remove caster's auras
#   - move_along_path(): walks the unit through a whole list of tiles, one at
#     a time, with a smooth animation for each step — instead of move_to()'s
#     single straight-line slide from A to B. This is what's used for normal
#     turn movement now (tapping a destination, AI movement), so units
#     actually walk AROUND obstacles tile-by-tile, and hazards (including
#     "damaging wall" hazards that don't block movement) correctly hurt them
#     as they cross each tile, not only if they land on the very last one.
#     move_to() itself is unchanged and still used for instant forced
#     shoves (knockback, pull, scatter), which should still feel like one
#     continuous push rather than a tile-by-tile walk.

extends Node2D

# ── DATA LINK ─────────────────────────────────────────────────────────────────

@export var unit_data: UnitData
# The "data card" resource (.tres file) holding this unit's name, stats, and
# abilities. Drag it in from the Inspector when placing the unit in the scene.

@export var move_speed: float = 1.5
# How many seconds move_to()'s sliding animation takes for the ENTIRE move,
# no matter how many tiles away the destination is. Used ONLY by move_to() —
# i.e. instant forced shoves like knockback, pull, and scatter, which are
# meant to feel like one continuous push, not a tile-by-tile walk.

@export var move_speed_per_tile: float = 0.28
# How many seconds move_along_path() spends animating EACH individual tile
# step during normal turn movement (tap-to-move, post-attack moves, and AI
# movement). A 4-tile walk takes roughly 4x as long as a 1-tile walk, instead
# of always taking the same fixed amount of time no matter the distance.
# Tune this to taste — lower = snappier/faster walking, higher = slower and
# more deliberate.

@export var faces_right_by_default: bool = true
# CHECK for player/ally units (they face right toward the enemy side).
# UNCHECK for enemy units (they face left by default).

# ── MULTI-TILE SUPPORT ────────────────────────────────────────────────────────

@export var tile_footprint: Array = [Vector2i(0,0)]
# The list of OFFSETS (relative to grid_position, the "anchor" cell) this unit
# occupies. A normal 1×1 unit has just [Vector2i(0,0)].
# A 2×2 unit would have: [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)].

var occupied_cells: Array = []
# The ACTUAL grid cells this unit currently occupies (computed at runtime by
# adding tile_footprint offsets to grid_position). Updated every time the unit moves.

# ── SPELLSWORD ARCANA CHARGES ─────────────────────────────────────────────────

@export var is_spellsword: bool = false
# Check this box on the Spellsword unit to enable Arcana Charge behaviour.

var has_arcana_charge: bool = false
# Set to true by BattleManager when the mana pool threshold is reached.

# ── RUNTIME STATS ─────────────────────────────────────────────────────────────

var current_hp:   int = 0
var current_mana: int = 0
var level:        int = 1

var grid_position: Vector2i = Vector2i(0, 0)
# The "anchor" cell (top-left corner for large units).

var custom_resources:  Dictionary = {}
var active_statuses:   Array      = []
# List of active status effects. Each entry is a Dictionary:
# { "data": StatusEffectData, "stacks": int, "remaining_rounds": int,
#   "source_caster": UnitNode or null,
#   "visual_phase": String — "none" | "entering" | "active" | "exiting" }
#
# source_caster is WHO applied this status. It's used for:
#   - Taunt: source_caster is who the taunted unit must attack.
#   - DoT: source_caster's ATK/MATK is used for physical/magical damage scaling.
# It may be null if the status was applied with no clear caster (e.g. a hazard
# with no tracked placer).

var ability_cooldowns: Dictionary = {}
# Maps ability id → rounds remaining on cooldown.

var equipped_items: Array = []
var equipped_item_ids: Array = []
# Same array object as this unit's RunState party entry's "equipped_item_ids"
# (see spawn_unit() below) -- NOT a copy. Mutating a slot here (e.g. setting
# it to null when a consumable is used) automatically updates the saved run
# data too, since GDScript Arrays are passed by reference.

# Help break recursion loop
var _apply_status_depth: int = 0

# ── MOMENTUM BONUSES ──────────────────────────────────────────────────────────

var momentum_bonuses: Dictionary = {}
# Stores permanent stat bonuses granted by Momentum auras.
# Structure: { "aura_id": { "atk": int, "def": int, "matk": int, "mdef": int,
#                           "mov": int, "crit_chance": float, "crit_damage": float } }
#
# AuraManager WRITES to this dictionary when a kill is scored inside a Momentum aura.
# AuraManager ERASES the matching key when the caster of that aura dies.
# The stat getter functions (get_effective_atk, etc.) READ this to add the bonus
# on top of the base stat + status modifiers.
#
# Fractional bonuses (e.g. 0.5 per kill) are tracked as floats by AuraManager
# and floor()'d before writing here as integers (except crit values which stay float).

# ── STATE FLAGS ───────────────────────────────────────────────────────────────

var is_player_unit:   bool = true
var has_acted:        bool = false
var has_moved:        bool = false

var pre_move_position: Vector2i = Vector2i(-1, -1)
# Saved before moving so the player can cancel and snap back.

var can_cancel_move: bool = false
# True only between "unit finished moving" and "unit used an ability".

var has_used_item_this_turn: bool = false

var _is_moving: bool = false
# True from the moment move_to()/move_along_path() starts until the instant
# movement_finished actually fires. Lets callers that kick off SEVERAL units'
# movement back-to-back (see ability_executor.gd's _resolve_pending_displacements)
# check "is this unit's tween still running RIGHT NOW" before deciding whether
# to await movement_finished — awaiting a signal that already fired hangs
# forever in GDScript, which is what caused the long delay on multi-target
# Windmage pushes. See move_to()/move_along_path() for where this flips.

var pending_post_attack_moves: int = 0
# If an ability has post_attack_move_squares > 0, this is set after the attack
# so BattleManager can grant the unit extra movement.

# ── TETHER TRACKING ───────────────────────────────────────────────────────────

var tether_ids: Array = []
# Stores the tether_id strings this unit is currently linked to.
# Populated by AbilityExecutor when a tether ability hits this unit.
# Cleaned up in battle_grid on death.

# ── REFERENCES ────────────────────────────────────────────────────────────────

var grid_ref: Node = null
# Filled in by BattleManager when the unit is spawned.
# Used to look up the grid, register/unregister tiles, find AuraManager, etc.

# ── SIGNALS ───────────────────────────────────────────────────────────────────

signal unit_died(unit)
# Emitted when HP reaches 0. BattleManager listens to update team lists.

signal movement_finished
# Emitted once when movement fully completes — either move_to()'s single
# slide, or move_along_path()'s full walk through every tile in its path.
# BattleManager/AISystem await this exactly the same way either way.

#Var for when a character is dying:
var _death_started: bool = false

signal hp_segment_depleted(depleted_segment_index: int)
# Emitted by take_damage() the instant a segmented-HP unit's current segment
# hits its floor. BossPhaseController listens for this to run retreat +
# summon + phase-advance. Harmless no-op for any unit with hp_segment_count == 1
# (never fires).

var current_segment_index: int = 0
# Which segment (0 = first/topmost) a segmented-HP unit is currently in.
# Unused for normal units.

var is_phase_transitioning: bool = false
# While true, take_damage() is a no-op — set/cleared by BossPhaseController
# around its retreat+summon sequence so multi-hit abilities can't finish
# damaging a boss that's already mid-transition (bleed-through prevention
# across the WHOLE transition, not just the triggering hit).

var last_damage_attacker = null
# The most recent unit to deal damage to this unit. Set at the top of
# take_damage(). Used by BossPhaseController to know who to retreat from.

var interrupt_cooldowns: Dictionary = {}
# Maps InterruptAbilityData.id -> rounds remaining before it can fire again.
# Ticked down by CombatHooks.run_round_tick — see the wiring note below.

var boss_phase_stat_multipliers: Dictionary = {}
# { "atk": float, "matk": float, "def": float, "mdef": float, "mov_bonus": int }
# Written by BossPhaseController._apply_phase(). Empty dict = no multiplier
# (every existing get_effective_*() stays unchanged for non-boss units).

var phase_granted_abilities: Array = []
# Abilities unlocked by boss phases so far, on top of unit_data.starting_abilities.
# Read by ai_system.gd's _choose_enemy_ability() — see the one-line addition below.

var current_boss_phase_index: int = 0

# ── LIFECYCLE ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	play_animation("idle")


func setup(data: UnitData, unit_level: int, is_player: bool) -> void:
	# Called by BattleManager right after instantiating this scene.
	# Initialises all runtime state from the data card.
	unit_data      = data
	level          = unit_level
	is_player_unit = is_player

	var stats: StatsData = unit_data.stats_by_level[level - 1]
	current_hp   = stats.hp
	current_mana = stats.mana

	_apply_default_facing()
	play_animation("idle")
	_update_hp_label()

	# Compute occupied cells from the starting position and footprint.
	_update_occupied_cells()

# ── MULTI-TILE HELPERS ────────────────────────────────────────────────────────

func _update_occupied_cells() -> void:
	# Recomputes which grid cells this unit occupies based on its anchor position
	# and its tile_footprint offsets. Call this after any position change.
	occupied_cells.clear()
	for offset in tile_footprint:
		occupied_cells.append(grid_position + offset)


func get_center_world_position() -> Vector2:
	# Returns the visual centre of the unit in world (pixel) space.
	# For 1×1 units this is just its position. For 2×2 it's the midpoint.
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

# ── VISUAL OVERRIDE STATE ─────────────────────────────────────────────────────

var _active_visual_override: StatusEffectData = null
# Tracks which status (if any) is currently overriding this unit's animation
# set. Only one visual override can be active at a time — if a second
# has_visual_override status is applied while one is already active, the
# newer one takes priority once its enter_animation finishes.

var _visual_override_transitioning: bool = false
# True while an enter_animation or exit_animation is playing. While true,
# play_animation() calls are ignored so the transition can't be interrupted
# by a stray idle/attack call from elsewhere in the codebase.

var _override_scene_instance: Node = null
# The live instance of StatusEffectData.override_scene, when
# visual_override_mode == "override_scene". Null whenever no scene-based
# override is currently showing. The unit's own AnimatedSprite2D is hidden
# while this is active and shown again once it's cleared.

# ── ANIMATION HELPERS ─────────────────────────────────────────────────────────

func _apply_default_facing() -> void:
	if not has_node("AnimatedSprite2D"):
		return
	# Player units default to facing RIGHT (toward enemies).
	# Enemy units default to facing LEFT (toward the player).
	var should_face_right: bool = is_player_unit
	$AnimatedSprite2D.flip_h = (should_face_right != faces_right_by_default)

func play_animation(anim_name: String) -> void:
	# Safely plays a named animation, falling back gracefully if it's missing.
	# If a visual-override status is currently active (e.g. Bark Armor), the
	# normal anim_name is redirected to that status's override_* animation
	# instead, so the unit keeps its special look until the status ends.
	if not has_node("AnimatedSprite2D"):
		return

	# While an enter/exit transition is playing, ignore all other animation
	# requests so the transition always plays out fully and uninterrupted.
	if _visual_override_transitioning:
		return

	var sprite := $AnimatedSprite2D as AnimatedSprite2D
	var actual_anim := anim_name

	# ── VISUAL OVERRIDE REDIRECT ───────────────────────────────────────────────
	# Only redirect by NAME when the active override uses animation_names mode.
	# Scene-based overrides manage their own idle/attack looping independently
	# and don't redirect through this function at all.
	if _active_visual_override != null and _active_visual_override.visual_override_mode == "animation_names":
		var override_data := _active_visual_override
		match anim_name:
			"idle":
				if override_data.override_idle_animation != "":
					actual_anim = override_data.override_idle_animation
			"walk", "walk_up":
				if override_data.override_walk_animation != "":
					actual_anim = override_data.override_walk_animation
			"attack", "attack_up", "attack_down":
				if override_data.override_attack_animation != "":
					actual_anim = override_data.override_attack_animation
			"hurt":
				if override_data.override_hurt_animation != "":
					actual_anim = override_data.override_hurt_animation
		if sprite.sprite_frames.has_animation(actual_anim):
			sprite.play(actual_anim)
			return
		# If the override didn't define a replacement for this specific anim,
		# fall through to the normal fallback logic below using the original name.
		actual_anim = anim_name

	match anim_name:
		"attack_up", "attack_down":
			if not sprite.sprite_frames.has_animation(anim_name):
				actual_anim = "attack"   # Fall back to the generic attack anim.
		"walk_up":
			if not sprite.sprite_frames.has_animation(anim_name):
				actual_anim = "walk"
	if sprite.sprite_frames.has_animation(actual_anim):
		sprite.play(actual_anim)
	if anim_name == "idle" and has_arcana_charge:
		sprite.play("arcana_charge")   # Arcana charge replaces idle visually.
		return


func play_named_animation(anim_name: String) -> void:
	# Plays an EXACT named animation with no fallback redirection and no
	# visual-override redirection. Used for per-ability custom attack
	# animations (ability_data.attack_animation_name), since those are
	# meant to play exactly as specified regardless of override status.
	# Falls back to the normal play_animation("attack") if the named
	# animation doesn't exist on this unit's sprite frames.
	if not has_node("AnimatedSprite2D"):
		return
	if _visual_override_transitioning:
		return
	var sprite := $AnimatedSprite2D as AnimatedSprite2D
	if anim_name != "" and sprite.sprite_frames.has_animation(anim_name):
		sprite.play(anim_name)
	else:
		play_animation("attack")

func _flash_on_hit(damage_type: String, is_crit: bool) -> void:
	if not has_node("AnimatedSprite2D"):
		return
	var sprite := $AnimatedSprite2D as AnimatedSprite2D

	# self_modulate tints the sprite without affecting other modulate effects
	# (e.g. the invisible-status transparency). Physical hits go red;
	# elemental hits pick up the element's colour.
	var flash: Color
	match damage_type:
		"fire":              flash = Color(1.0, 0.35, 0.10)
		"ice", "frost":      flash = Color(0.30, 0.80, 1.00)
		"lightning":         flash = Color(1.0, 1.00, 0.20)
		"poison", "nature":  flash = Color(0.25, 0.90, 0.20)
		"magic", "arcane":   flash = Color(0.70, 0.30, 1.00)
		"holy", "light":     flash = Color(1.0, 0.95, 0.50)
		_:                   flash = Color(1.0, 0.85, 0.85)  # physical: warm white

	if is_crit:
		flash = Color(1.0, 0.10, 0.10)   # override everything with red on crit

	var tween := create_tween()
	tween.tween_property(sprite, "self_modulate", flash,        0.0 )
	tween.tween_property(sprite, "self_modulate", Color.WHITE,  0.18) \
		 .set_ease(Tween.EASE_OUT)

func _set_facing_for_direction(target_pos: Vector2i) -> void:
	if not has_node("AnimatedSprite2D"):
		return
	var sprite := $AnimatedSprite2D as AnimatedSprite2D

	# Self-targeted abilities (target_pos == grid_position): there's no real
	# direction to face, since target_pos.x > grid_position.x is FALSE when
	# they're equal. Snap back to this unit's default facing (the same flip
	# _apply_default_facing() uses) so a unit buffing/healing itself faces
	# right by default instead of always flipping left.
	if target_pos == grid_position:
		sprite.flip_h = not faces_right_by_default
		return

	# BUGFIX ("backward animations"): a PURELY VERTICAL move or attack (same
	# column — target_pos.x == grid_position.x) used to fall into the "face
	# left" branch below, because target_pos.x > grid_position.x is false
	# when the two x's are equal. That silently flipped the unit to face
	# left every time it walked or attacked straight up/down, regardless of
	# which way it was actually already facing — reading as the sprite
	# playing backward. Vertical-only movement/targeting shouldn't touch
	# left/right facing at all, so just leave flip_h exactly as it was.
	if target_pos.x == grid_position.x:
		return

	var target_is_right: bool = target_pos.x > grid_position.x
	sprite.flip_h = (target_is_right != faces_right_by_default)

# ── STAT GETTERS ──────────────────────────────────────────────────────────────
# Each getter adds up: base stat + status effect modifiers + momentum bonuses.
# Status modifiers come from active_statuses (buffs/debuffs).
# Momentum bonuses come from the momentum_bonuses dictionary, which is written
# by AuraManager when kills occur inside a Momentum aura.

func get_stats() -> StatsData:
	# Returns the raw stats data card for this unit's current level.
	return unit_data.stats_by_level[level - 1]


func get_effective_atk() -> int:
	var base = get_stats().atk
	# Add/subtract modifiers from all active status effects.
	for s in active_statuses:
		base += s["data"].atk_modifier * s["stacks"]
	# Add permanent Momentum bonuses from any aura this unit benefits from.
	# Each key in momentum_bonuses is an aura_id; we sum all the atk values.
	if boss_phase_stat_multipliers.has("atk"):
		base = int(round(base * boss_phase_stat_multipliers["atk"]))	
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("atk", 0)
	return max(0, base)


func get_effective_matk() -> int:
	var base = get_stats().matk
	for s in active_statuses:
		base += s["data"].matk_modifier * s["stacks"]
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("matk", 0)
	if boss_phase_stat_multipliers.has("matk"):
		base = int(round(base * boss_phase_stat_multipliers["matk"]))
	return max(0, base)


func get_effective_def() -> int:
	var base = get_stats().def
	for s in active_statuses:
		base += s["data"].def_modifier * s["stacks"]
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("def", 0)
	if boss_phase_stat_multipliers.has("def"):
		base = int(round(base * boss_phase_stat_multipliers["def"]))
	return max(0, base)


func get_effective_mdef() -> int:
	var base = get_stats().mdef
	for s in active_statuses:
		base += s["data"].mdef_modifier * s["stacks"]
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("mdef", 0)
	if boss_phase_stat_multipliers.has("mdef"):
		base = int(round(base * boss_phase_stat_multipliers["mdef"]))
	return max(0, base)


func get_effective_mov() -> int:
	var base = get_stats().mov
	for s in active_statuses:
		# A root effect overrides everything — rooted units cannot move at all.
		if s["data"].is_root:
			return 0
		base += s["data"].mov_modifier * s["stacks"]
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("mov", 0)
	if boss_phase_stat_multipliers.has("mov"):
		base = int(round(base * boss_phase_stat_multipliers["mov"]))
	return max(0, base)


func get_effective_crit_chance() -> float:
	# Returns the unit's effective crit chance, including status and momentum bonuses.
	var base = get_stats().crit_chance
	for s in active_statuses:
		base += s["data"].crit_chance_modifier * s["stacks"]
	# Momentum crit_chance is already a float percentage — add it directly.
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("crit_chance", 0.0)
	if boss_phase_stat_multipliers.has("crit_chance"):
		base = int(round(base * boss_phase_stat_multipliers["crit_chance"]))
	return base


func get_effective_crit_damage() -> float:
	# Returns the unit's effective crit damage percentage, including momentum bonuses.
	# This replaces the old direct read of get_stats().crit_damage in ability_executor
	# so that Momentum crit_damage bonuses are factored in.
	# e.g. base 150% + 10% from Momentum = 160% crit damage.
	var base: float = get_stats().crit_damage
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("crit_damage", 0.0)
	if boss_phase_stat_multipliers.has("crit_damage"):
		base = int(round(base * boss_phase_stat_multipliers["crit_damage"]))
	return base
	
func get_effective_max_hp() -> int:
	# Same pattern as get_effective_atk()/get_effective_def()/etc. above —
	# adds up every "hp" bonus tucked inside momentum_bonuses (equipment,
	# permanent tarot modifiers, auras — anything that writes an "hp" key
	# into its own sub-dictionary there) on top of this unit's base max HP.
	var base = get_stats().hp
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("hp", 0)
	return max(1, base)


func get_effective_max_mana() -> int:
	var base = get_stats().mana
	for aura_id in momentum_bonuses:
		base += momentum_bonuses[aura_id].get("mana", 0)
	return max(0, base)

# ── MANA ──────────────────────────────────────────────────────────────────────

func can_afford_ability(ability: AbilityData) -> bool:
	# Returns true if the unit currently has enough mana to use this ability.
	# Also checks the HP cost won't kill the unit outright.
	# Called by ui_manager (to grey out buttons) and ability_executor (safety gate).
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
	CombatHooks.notify_mana_spent(self, amount)


func restore_mana(amount: int) -> void:
	# Restores mana up to the stat maximum.
	var max_mana = get_effective_max_mana()
	current_mana = min(current_mana + amount, max_mana)
	
# ── COMBAT ────────────────────────────────────────────────────────────────────

func take_damage(amount: int, damage_type: String, is_crit: bool = false, apply_shake: bool = true, attacker = null) -> int:
	if is_phase_transitioning:
		return 0   # Fully invulnerable during a boss retreat/summon sequence.

	if attacker != null:
		last_damage_attacker = attacker

	var requested: int = max(1, amount)
	var actual: int = requested

	# ── SEGMENTED HP CLAMP (no bleed-through) ─────────────────────────────────
	var segment_count: int = 1
	if unit_data != null and "hp_segment_count" in unit_data:
		segment_count = unit_data.hp_segment_count

	var crossed_segment: bool = false
	if segment_count > 1:
		var max_hp: int = get_effective_max_hp()
		var remaining_segments: int = segment_count - current_segment_index
		# The floor is the HP value at the BOTTOM of the current segment —
		# i.e. the top of the NEXT segment down. 0 for the final segment
		# (normal death applies there, no special clamping).
		var floor_hp: int = 0
		if remaining_segments > 1:
			floor_hp = int(round(float(max_hp) * float(remaining_segments - 1) / float(segment_count)))

		if floor_hp > 0 and current_hp - actual < floor_hp:
			actual = current_hp - floor_hp   # clamp — discard any extra damage
			crossed_segment = true

	current_hp -= actual
	_update_hp_label()

	_flash_on_hit(damage_type, is_crit)
	CombatFeedback.show_hit(self, actual, is_crit, damage_type, apply_shake)

	if crossed_segment:
		var depleted_index: int = current_segment_index
		current_segment_index += 1
		if unit_data != null and unit_data.hurt_sfx != null:   # ADDED
			AudioManager.play_sfx(unit_data.hurt_sfx)           # ADDED
		hp_segment_depleted.emit(depleted_index)
	elif current_hp <= 0:
		die()
	else:
		if unit_data != null and unit_data.hurt_sfx != null:   # ADDED
			AudioManager.play_sfx(unit_data.hurt_sfx)           # ADDED
		play_animation("hurt")
		get_tree().create_timer(0.25).timeout.connect(func():
			if is_instance_valid(self) and current_hp > 0:
				play_animation("idle")
		)
	return actual

func heal(amount: int) -> void:
	var max_hp = get_effective_max_hp()
	current_hp = min(current_hp + amount, max_hp)
	_update_hp_label()


func die() -> void:
	if unit_data != null and unit_data.death_sfx != null:  
		AudioManager.play_sfx(unit_data.death_sfx)
	if _death_started:
		return
	_death_started = true
	if not is_inside_tree():
		queue_free()
		return

	print(unit_data.display_name, " has been defeated!")

	# ── NOTIFY AURA MANAGER ───────────────────────────────────────────────────
	# Strip momentum bonuses and remove this unit's auras immediately, before
	# anything else, so no downstream code sees stale aura state.
	if grid_ref != null and grid_ref.has_node("AuraManager"):
		grid_ref.get_node("AuraManager").remove_all_auras_for(self)
	CombatHooks.notify_unit_died(self)


	# Unregister ALL cells this unit occupied so pathfinding opens up immediately.
	# We do this NOW (not after the animation) so other units can path through
	# the tile while the death animation is still playing.
	if grid_ref != null:
		if tile_footprint.size() > 1:
			grid_ref.unregister_large_unit(self)
		else:
			grid_ref.unregister_unit(grid_position, self)

	# Remove from tether, guardian, shield, thorns maps immediately.
	if grid_ref != null and grid_ref.has_method("unregister_tether"):
		for tid in tether_ids:
			grid_ref.unregister_tether(self, tid)
	if grid_ref != null:
		if grid_ref.shield_map.has(self):   grid_ref.shield_map.erase(self)
		if grid_ref.guardian_map.has(self): grid_ref.guardian_map.erase(self)
		if grid_ref.thorns_map.has(self):   grid_ref.thorns_map.erase(self)

	# ── PLAY DEATH ANIMATION THEN CLEAN UP ────────────────────────────────────
	# We use call_deferred to push the rest of the death sequence (signal + free)
	# one frame forward. This gives:
	#   • The damage number float-up tween time to start visually
	#   • The AI's current await to resume and finish gracefully before the node
	#     is freed (avoiding "previously freed" errors on the next line)
	#   • The die animation time to play before the node disappears
	_finish_death.call_deferred()


func _finish_death() -> void:
	# Called one frame after die() via call_deferred.
	# Plays the death animation, waits for it to finish, then emits the signal
	# and frees the node. Separating this from die() ensures all in-flight
	# awaits in ai_system and ability_executor have had a chance to resume first.
	if not is_inside_tree():
		return

	if has_node("AnimatedSprite2D"):
		var sprite := $AnimatedSprite2D as AnimatedSprite2D
		sprite.play("die")
		# If the sprite has a "die" animation, wait for it to finish naturally.
		# If the animation loops or doesn't exist we fall back to a fixed delay.
		if sprite.sprite_frames != null and sprite.sprite_frames.has_animation("die"):
			await sprite.animation_finished
		else:
			await get_tree().create_timer(0.4).timeout
	else:
		hide()
		await get_tree().create_timer(0.4).timeout

	# Emit the death signal AFTER the animation so BattleManager updates team
	# lists (and potentially triggers victory/defeat) only once the unit has
	# visually disappeared.
	unit_died.emit(self)
	queue_free()

# ── MOVEMENT ──────────────────────────────────────────────────────────────────

func move_to(new_cell: Vector2i) -> void:
	# Moves the unit DIRECTLY to a new anchor cell in one continuous slide,
	# updating the grid registry and animating the visual position smoothly
	# with a single Tween over move_speed seconds, no matter how far away
	# new_cell is. This is the right tool for instant forced shoves — knockback,
	# pull, and scatter (see ability_executor.gd) — which should feel like one
	# continuous push, not a tile-by-tile walk.
	#
	# For NORMAL turn movement (tapping a destination tile, or AI movement),
	# use move_along_path() below instead — it walks the unit through every
	# tile of the actual route one at a time, which looks right when routing
	# around obstacles and correctly triggers hazards on every tile crossed,
	# not just the final one.
	if grid_ref == null:
		return

	_is_moving = true
	_start_walk_particles()
	_set_facing_for_direction(new_cell)

	var dy = new_cell.y - grid_position.y
	if dy < 0:
		play_animation("walk_up")
	else:
		play_animation("walk")

	# For large units: unregister ALL current cells, then register ALL new cells.
	if tile_footprint.size() > 1:
		grid_ref.unregister_large_unit(self)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_large_unit(self, occupied_cells)
	else:
		grid_ref.unregister_unit(grid_position, self)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_unit(self, new_cell)

	# Slide the visual sprite to the new anchor world position.
	var target_world_pos: Vector2 = grid_ref.grid_to_world(new_cell)

	# ── NOTIFY AURA MANAGER — start visual tween NOW, before our own tween ────
	# begin_caster_move() starts the aura overlay tween with the SAME duration
	# and easing as our tween below (we pass move_speed explicitly), so both
	# slide in perfect lockstep.
	if grid_ref.has_node("AuraManager"):
		grid_ref.get_node("AuraManager").begin_caster_move(self, new_cell, move_speed)

	var tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "position", target_world_pos, move_speed)
	tween.tween_callback(func():
		# BUGFIX: forced displacement (knockback/pull/scatter) used to never
		# trigger hazard "enter" damage, since only move_along_path() checked
		# it before. A shove into fire/poison/etc. should hurt on landing,
		# exactly like walking there normally would.
		if is_instance_valid(self) and grid_ref != null:
			grid_ref.apply_hazard_to_unit(self, new_cell, "enter")

		# THE FIX: _is_moving, _stop_walk_particles(), and movement_finished
		# used to be nested INSIDE the "still alive" check below, right next
		# to play_animation("idle") — meaning if the hazard damage above
		# killed the unit, _is_moving was never cleared and
		# movement_finished never fired. Anything awaiting that signal
		# (BattleManager, AI, _resolve_pending_displacements) would then hang
		# forever, exactly like the earlier Wind Mage push-death freeze —
		# just triggered here by a plain knockback/dash landing on a hazard
		# instead of a multi-target push. play_animation("idle") is the only
		# part that should stay conditional on being alive; everything else
		# needs to run unconditionally so the move always properly finishes.
		if is_instance_valid(self) and current_hp > 0:
			play_animation("idle")
		_is_moving = false
		_stop_walk_particles()
		movement_finished.emit()
	)

# ── WALK PARTICLES (dust) ────────────────────────────────────────────────────
var _walk_particles: CPUParticles2D = null

@export var walk_particle_offset: Vector2 = Vector2(0, 40)
# How far below the unit's anchor point the dust puffs spawn — tweak per
# sprite if your art's "feet" sit somewhere other than the sprite origin.
# NOTE: the unit's anchor is usually roughly its CENTER (see HP_BAR_Y_OFFSET
# above, which uses 48px as "half a 96px tile" for the same unit) — so this
# needs to be a good chunk further down than you'd first guess, or it spawns
# on top of/behind the torso instead of at the feet.

static var _dust_circle_texture: ImageTexture = null
# Generated once and shared by every unit's dust particles — CPUParticles2D
# draws plain squares by default, so this gives it an actual round shape.

static func _get_dust_circle_texture() -> ImageTexture:
	if _dust_circle_texture != null:
		return _dust_circle_texture

	var diameter := 16
	var image := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var center := Vector2(diameter / 2.0, diameter / 2.0)
	var radius := diameter / 2.0
	for x in diameter:
		for y in diameter:
			var dist: float = Vector2(x + 0.5, y + 0.5).distance_to(center)
			if dist <= radius:
				# Soft falloff toward the edge so it reads as a soft puff
				# instead of a hard-edged dot.
				var alpha: float = clamp(1.0 - (dist / radius), 0.0, 1.0)
				image.set_pixel(x, y, Color(1, 1, 1, alpha))
			else:
				image.set_pixel(x, y, Color(1, 1, 1, 0.0))

	_dust_circle_texture = ImageTexture.create_from_image(image)
	return _dust_circle_texture


func _ensure_walk_particles() -> void:
	if _walk_particles != null and is_instance_valid(_walk_particles):
		return
	_walk_particles = CPUParticles2D.new()
	add_child(_walk_particles)
	_walk_particles.texture              = _get_dust_circle_texture()
	_walk_particles.position             = walk_particle_offset
	_walk_particles.emitting             = false
	_walk_particles.one_shot             = false
	_walk_particles.amount               = 10
	_walk_particles.lifetime             = 1.1
	_walk_particles.randomness           = 0.6
	_walk_particles.direction            = Vector2(0, -1)
	_walk_particles.spread               = 50.0
	_walk_particles.gravity              = Vector2(0, 60.0)
	_walk_particles.initial_velocity_min = 6.0
	_walk_particles.initial_velocity_max = 1
	_walk_particles.scale_amount_min     = 1.5
	_walk_particles.scale_amount_max     = 3.5
	_walk_particles.color                = Color(0.72, 0.65, 0.52, 0.55)   # dusty tan
	# z_index left at default (0) — see prior fix: -1 hid these behind the
	# unit's own AnimatedSprite2D.
	
func _start_walk_particles() -> void:
	_ensure_walk_particles()
	_walk_particles.emitting = true


func _stop_walk_particles() -> void:
	if is_instance_valid(_walk_particles):
		_walk_particles.emitting = false


func move_along_path(path: Array) -> void:
	# NEW: walks the unit smoothly through EVERY tile in 'path', one at a time,
	# instead of move_to()'s single straight-line slide from start to finish.
	# This is the normal-movement counterpart to move_to() — use this for
	# tap-to-move, post-attack movement, and AI movement. 'path' should come
	# from pathfinding_system.gd's reconstruct_path_to(), which already walks
	# AROUND obstacles (other units, terrain walls, movement-blocking wall
	# hazards) rather than cutting straight through them.
	#
	# 'path' is an Array of Vector2i, in walking order, NOT including the
	# unit's current tile — e.g. if standing at (2,2) and walking to (2,5),
	# path = [(2,3), (2,4), (2,5)].
	#
	# Why this matters for hazards: we register the unit onto EACH tile and
	# fire its "enter" hazard trigger as we genuinely arrive there — so a
	# "damaging wall" hazard (HazardData.is_wall_hazard = true with
	# blocks_movement = false) correctly hurts the unit while CROSSING it,
	# not just if they happen to end their move standing on it. The old
	# move_to()-based movement only ever checked the single final tile,
	# which is fine for a forced shove but was never correct for a hazard a
	# unit is meant to be able to walk straight through.
	if grid_ref == null or path.is_empty():
		return

	_is_moving = true
	_start_walk_particles()
	for step_cell in path:
		# Bail out cleanly if we were freed mid-walk for some unrelated reason.
		if not is_instance_valid(self):
			return

		# ── FACE + ANIMATE TOWARD THIS STEP ────────────────────────────────────
		_set_facing_for_direction(step_cell)
		var dy = step_cell.y - grid_position.y
		if dy < 0:
			play_animation("walk_up")
		else:
			play_animation("walk")

		# ── UPDATE GRID REGISTRATION FOR THIS STEP ─────────────────────────────
		# Done BEFORE the visual tween (same order as move_to()) so anything
		# that looks up unit_positions mid-step sees the unit at its new tile.
		if tile_footprint.size() > 1:
			grid_ref.unregister_large_unit(self)
			grid_position = step_cell
			_update_occupied_cells()
			grid_ref.register_large_unit(self, occupied_cells)
		else:
			grid_ref.unregister_unit(grid_position, self)
			grid_position = step_cell
			_update_occupied_cells()
			grid_ref.register_unit(self, step_cell)

		var step_world_pos: Vector2 = grid_ref.grid_to_world(step_cell)

		# Keep any aura this unit owns sliding in lockstep, one tile at a time,
		# using the SAME per-tile duration as the body sprite below.
		if grid_ref.has_node("AuraManager"):
			grid_ref.get_node("AuraManager").begin_caster_move(self, step_cell, move_speed_per_tile)

		# ── SLIDE TO THIS TILE ──────────────────────────────────────────────────
		# Linear trans/ease keeps consecutive tile-steps flowing into each
		# other smoothly (no decelerate-then-reaccelerate stutter between
		# tiles like a cubic ease-out would cause if repeated every step).
		var tween = create_tween()
		tween.set_trans(Tween.TRANS_LINEAR)
		tween.set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(self, "position", step_world_pos, move_speed_per_tile)
		await tween.finished

		if not is_instance_valid(self):
			return

		# ── HAZARD CHECK FOR THIS TILE ───────────────────────────────────────────
		# Fires the instant we actually arrive on this tile — works for both a
		# normal hazard tile AND a non-blocking "damaging wall" hazard, since
		# the unit genuinely stands here now, whether it's an intermediate
		# step or the final destination.
		grid_ref.apply_hazard_to_unit(self, step_cell, "enter")

		# If that hazard was lethal, stop walking any further tiles — but we
		# still fall through to emit movement_finished below so anything
		# awaiting it (BattleManager, AI, post-move aura sync) doesn't hang.
		if current_hp <= 0:
			break

	if is_instance_valid(self) and current_hp > 0:
		play_animation("idle")
	_is_moving = false
	_stop_walk_particles()
	movement_finished.emit()


# ── BUFF / DEBUFF STATUS GLOW ─────────────────────────────────────────────────
# A small persistent sparkle sitting just above the HP bar — gold whenever
# the unit has at least one active buff, purple whenever it has at least one
# active debuff. Both can show at once (a unit can be buffed AND debuffed
# simultaneously) — they're two independent particle emitters, not one that
# swaps color.

var _buff_glow: CPUParticles2D = null
var _debuff_glow: CPUParticles2D = null

const STATUS_GLOW_TILE_HALF: float = 48.0
# Half of TILE_SIZE (96px). Units are positioned at their tile's CENTER, so
# +/- this value from the unit's own position lands exactly on the tile's
# bottom/top edge.

const STATUS_GLOW_EDGE_MARGIN: float = 6.0
# Keeps each stream's spawn point just inside the tile edge, rather than
# exactly on the boundary line, so sparkles don't look like they're
# spawning half-outside the tile.

func _make_fade_gradient(base_color: Color) -> Gradient:
	# Fades each sparkle to fully transparent over its lifetime, so it
	# dissolves smoothly instead of just popping out of existence.
	var g := Gradient.new()
	g.set_color(0, base_color)
	g.set_color(1, Color(base_color.r, base_color.g, base_color.b, 0.0))
	return g

func _ensure_status_glow(which: String) -> CPUParticles2D:
	var existing: CPUParticles2D = _buff_glow if which == "buff" else _debuff_glow
	if existing != null and is_instance_valid(existing):
		return existing

	var glow := CPUParticles2D.new()
	add_child(glow)
	glow.texture               = _get_dust_circle_texture()
	glow.emitting              = false
	glow.one_shot              = false
	glow.amount                = 35
	glow.lifetime              = .8
	glow.randomness            = 0.6
	glow.emission_shape        = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	glow.emission_rect_extents = Vector2(26.0, 2.0)
	glow.spread                = 6.0
	glow.scale_amount_min      = 1.0
	glow.scale_amount_max      = 1.8

	if which == "buff":
		glow.position              = Vector2(0, STATUS_GLOW_TILE_HALF - STATUS_GLOW_EDGE_MARGIN)
		glow.direction             = Vector2(0, -1)
		glow.gravity               = Vector2(0, -16.0)
		glow.initial_velocity_min  = 5.0
		glow.initial_velocity_max  = 10.0
		var buff_color = Color(1.0, 0.85, 0.25, 0.85)
		glow.color      = buff_color
		glow.color_ramp = _make_fade_gradient(buff_color)
		_buff_glow = glow
	else:
		glow.position              = Vector2(0, -(STATUS_GLOW_TILE_HALF - STATUS_GLOW_EDGE_MARGIN))
		glow.direction             = Vector2(0, 1)
		glow.gravity               = Vector2(0, 16.0)
		glow.initial_velocity_min  = 24.0
		glow.initial_velocity_max  = 32.0
		var debuff_color = Color(0.55, 0.15, 0.75, 0.55)
		glow.color      = debuff_color
		glow.color_ramp = _make_fade_gradient(debuff_color)
		_debuff_glow = glow

	return glow

func _refresh_status_glow() -> void:
	# Called any time active_statuses changes — apply, remove, or a natural
	# expiry — so this never drifts out of sync with what's actually active.
	for s in active_statuses:
		var d: StatusEffectData = s["data"]
		print("STATUS: ", d.display_name,
			  " | classification=", d.visual_classification,
			  " | is_buff=", d.classifies_as_buff(),
			  " | is_debuff=", d.classifies_as_debuff())
	# ── END TEMP DEBUG ──────────────────────────────────────────────────────
	
	var has_buff: bool   = get_buff_count()   > 0
	var has_debuff: bool = get_debuff_count() > 0

	if has_buff:
		_ensure_status_glow("buff").emitting = true
	elif _buff_glow != null and is_instance_valid(_buff_glow):
		_buff_glow.emitting = false

	if has_debuff:
		_ensure_status_glow("debuff").emitting = true
	elif _debuff_glow != null and is_instance_valid(_debuff_glow):
		_debuff_glow.emitting = false

func snap_to(new_cell: Vector2i) -> void:
	# Instantly teleports the unit with no animation. Used by dash and cancel-move.
	if grid_ref == null:
		return
	if tile_footprint.size() > 1:
		grid_ref.unregister_large_unit(self)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_large_unit(self, occupied_cells)
	else:
		grid_ref.unregister_unit(grid_position, self)
		grid_position = new_cell
		_update_occupied_cells()
		grid_ref.register_unit(self, new_cell)
	position = grid_ref.grid_to_world(new_cell)

func snap_to_allow_overlap(new_cell: Vector2i) -> void:
	# Like snap_to(), but if new_cell is already occupied by ANOTHER unit,
	# this does NOT trigger register_unit()'s "rescue displaced unit" safety
	# net — it lets this unit's grid_position/visual overlap them instead.
	# Used specifically by Cancel Move snapping back to a tile an ally has
	# since moved into. battle_manager.gd blocks ending the turn while any
	# such overlap exists (see _check_for_occupancy_conflicts), forcing the
	# player to resolve it themselves rather than an ally silently getting
	# bumped somewhere they didn't choose.
	#
	# NOTE: while overlapping, this unit is NOT the grid's "official"
	# resident of that cell — tapping that tile will find the OTHER unit,
	# not this one, until the overlap is resolved by moving one of them.
	if grid_ref == null:
		return

	if tile_footprint.size() > 1:
		grid_ref.unregister_large_unit(self)
		grid_position = new_cell
		_update_occupied_cells()
		var any_occupied: bool = false
		for c in occupied_cells:
			if grid_ref.unit_positions.has(c):
				any_occupied = true
				break
		if not any_occupied:
			grid_ref.register_large_unit(self, occupied_cells)
	else:
		grid_ref.unregister_unit(grid_position, self)
		grid_position = new_cell
		_update_occupied_cells()
		if not grid_ref.unit_positions.has(new_cell):
			grid_ref.register_unit(self, new_cell)
		# else: leave unit_positions pointing at the existing occupant —
		# grid_position above still correctly reflects where THIS unit
		# visually is, for _check_for_occupancy_conflicts() to detect.

	position = grid_ref.grid_to_world(new_cell)


func look_at_target(target_pos: Vector2i, custom_animation_name: String = "") -> void:
	# Faces the unit toward target_pos, then plays either:
	#   - the exact custom_animation_name if one was provided (for per-ability
	#     attack animations like "attack_fire_sword"), or
	#   - the normal directional attack_up/attack_down/attack fallback.
	_set_facing_for_direction(target_pos)
	if custom_animation_name != "":
		play_named_animation(custom_animation_name)
		return
	var dy = target_pos.y - grid_position.y
	if dy < -1:
		play_animation("attack_up")
	elif dy > 1:
		play_animation("attack_down")

# ── STATUS EFFECTS ────────────────────────────────────────────────────────────

func apply_status(status_data: StatusEffectData, stacks: int = 1, source_caster = null) -> void:
	#This helps prevent recursion loops
	_apply_status_depth += 1
	if _apply_status_depth > 8:
		push_warning("apply_status: recursion depth exceeded for '" +
			status_data.display_name + "' on " + unit_data.display_name +
			" — something is triggering a status chain. Skipping to prevent crash.")
		_apply_status_depth -= 1
		return

	# If the unit has an immunity status, block all incoming status applications.
	for s in active_statuses:
		if s["data"].grants_immunity:
			print("🛡️ ", unit_data.display_name, " is immune! Status '",
				  status_data.display_name, "' blocked.")
			_apply_status_depth -= 1
			return

	# If this status is already active, refresh its duration and optionally stack.
	for s in active_statuses:
		if s["data"].id == status_data.id:
			if status_data.can_stack:
				s["stacks"] = min(s["stacks"] + stacks, status_data.max_stacks)
			s["remaining_rounds"] = status_data.duration_rounds
			s["source_caster"] = source_caster
			_debug_print_status_applied(status_data, s["stacks"])
			_apply_status_depth -= 1
			return

	# Brand new status — add it to the list.
	active_statuses.append({
		"data":             status_data,
		"stacks":           stacks,
		"remaining_rounds": status_data.duration_rounds,
		"source_caster":    source_caster,
		"visual_phase":     "none",
	})
	_debug_print_status_applied(status_data, stacks)
	update_visuals()

	var is_buff: bool = status_data.classifies_as_buff()
	EventBus.publish.call_deferred(EventBus.ON_BUFF_APPLIED, {
		"unit": self, "status_id": status_data.id, "is_buff": is_buff,
		"status_data": status_data,
	})

	if status_data.has_visual_override:
		_begin_visual_override(status_data)

	_refresh_status_glow()
	_apply_status_depth -= 1


func remove_status(status_id: String) -> void:
	# Removes a status by its id string. Used for cleanse/dispel effects, and
	# for one-off reveals like "attacking breaks invisibility".
	var removed_entry = null
	for s in active_statuses:
		if s["data"].id == status_id:
			removed_entry = s
			break
	if removed_entry == null:
		return
	active_statuses.erase(removed_entry)

	# If the removed status was driving a visual override, play its exit
	# animation and restore the unit's normal look.
	if removed_entry["data"].has_visual_override and _active_visual_override == removed_entry["data"]:
		_end_visual_override(removed_entry["data"])

	# Always refresh sprite transparency here — NOT just at the call sites
	# that happen to remember to do it. This is what was missing for natural
	# invisibility expiry: tick_statuses_end_of_round() below removes expired
	# statuses through its own array logic rather than calling remove_status()
	# (for performance, since it's iterating already), so it ALSO calls
	# update_visuals() directly in its own cleanup loop — see below.
	update_visuals()
	_refresh_status_glow()


func cleanse_statuses() -> int:
	# Called by ability_executor.gd when an ability with is_cleanse = true
	# hits this unit. Removes every CURRENTLY ACTIVE status whose cleansable
	# flag is checked (see status_effect_data.gd) — buffs and debuffs alike,
	# since cleansable is a flag the designer sets per-status, not a hardcoded
	# "debuffs only" rule. A status with cleansable = false survives no matter
	# what (e.g. a stun specifically meant to be un-cleansable).
	#
	# Routes through remove_status() for each one, so visual override exit
	# animations and sprite transparency (e.g. invisibility) are all handled
	# automatically and consistently with every other removal path.
	#
	# Returns how many statuses were actually removed, in case a UI or combat
	# log wants to report it (e.g. "Cleansed 2 effects from Sylvaris!").
	var ids_to_cleanse: Array = []
	for s in active_statuses:
		if s["data"].cleansable:
			ids_to_cleanse.append(s["data"].id)

	for status_id in ids_to_cleanse:
		remove_status(status_id)

	return ids_to_cleanse.size()
	update_visuals()
	_refresh_status_glow()
func tick_statuses_end_of_round(team_that_just_ended: String) -> void:
	var to_remove = []
	for s in active_statuses:
		var data: StatusEffectData = s["data"]

		# ── DAMAGE OVER TIME ────────────────────────────────────────────────
		if data.has_dot and team_that_just_ended == "enemy":
			_apply_dot_tick(s)
			if not is_instance_valid(self):
				return   # The DoT tick killed this unit — stop processing.

		if data.is_permanent:
			continue   # Permanent statuses never count down toward expiry.

		# ── DURATION COUNTDOWN ──────────────────────────────────────────────
		# Gate the countdown so it only ticks down when this unit's OWN team 
		# finishes their turn, preventing the double-count.
		var my_team = "player" if is_player_unit else "enemy"
		if team_that_just_ended == my_team:
			s["remaining_rounds"] -= 1
			if s["remaining_rounds"] <= 0:
				to_remove.append(s)

	for s in to_remove:
		active_statuses.erase(s)
		print("⏱️ Status '", s["data"].display_name, "' expired on ", unit_data.display_name)
		
		# If the expiring status was driving a visual override, play its exit
		# animation and restore the unit's normal look.
		if s["data"].has_visual_override and _active_visual_override == s["data"]:
			_end_visual_override(s["data"])

	# Refresh sprite transparency if anything actually expired this round.
	if not to_remove.is_empty():
		update_visuals()
		_refresh_status_glow()

func _apply_dot_tick(status_entry: Dictionary) -> void:
	# Deals one tick of damage-over-time damage based on the status's
	# dot_damage_mode, scaled by stacks (each stack deals damage independently
	# — a stacked DoT of 3 stacks ticks 3 times the per-tick damage).
	var data: StatusEffectData = status_entry["data"]
	var caster = status_entry["source_caster"]
	var stacks: int = status_entry["stacks"]

	var per_tick_damage: int = 0
	match data.dot_damage_mode:
		"flat":
			per_tick_damage = data.dot_flat_amount
		"physical":
			if caster != null and is_instance_valid(caster):
				var atk = caster.get_effective_atk()
				var def = get_effective_def()
				per_tick_damage = max(1, int(float(atk - def) * data.dot_damage_percent))
			else:
				per_tick_damage = max(1, int(get_stats().atk * data.dot_damage_percent))
		"magical":
			if caster != null and is_instance_valid(caster):
				var matk = caster.get_effective_matk()
				var mdef = get_effective_mdef()
				per_tick_damage = max(1, int(float(matk - mdef) * data.dot_damage_percent))
			else:
				per_tick_damage = max(1, int(get_stats().matk * data.dot_damage_percent))

	var total_damage = per_tick_damage * max(1, stacks)
	var dmg_type = "true" if data.dot_damage_mode == "flat" else data.dot_damage_mode
	print("☣️ DoT '", data.display_name, "' ticks for ", total_damage, " on ", unit_data.display_name)
	take_damage(total_damage, dmg_type)

# ── TAUNT HELPERS ─────────────────────────────────────────────────────────────

func get_taunt_source():
	# Returns the UnitNode this unit is currently taunted by, or null if not
	# taunted (or if the taunter has since died/become invalid).
	# If multiple taunts are somehow active at once, the most recently applied
	# one wins (last in active_statuses with applies_taunt = true).
	var result = null
	for s in active_statuses:
		var data: StatusEffectData = s["data"]
		if data.applies_taunt:
			var src = s["source_caster"]
			if src != null and is_instance_valid(src):
				result = src
	return result


func is_taunted() -> bool:
	return get_taunt_source() != null


func get_active_interrupts() -> Array:
	# Collects every interrupt this unit currently carries: innate ones from
	# UnitData, plus one from EVERY active status that grants one. This is
	# what makes multiple simultaneous reaction sources stack — each entry
	# is evaluated completely independently by InterruptSystem.
	var result: Array = []
	if unit_data != null and "innate_interrupts" in unit_data:
		for data in unit_data.innate_interrupts:
			if data != null:
				result.append({"data": data, "source": "innate"})
	for s in active_statuses:
		var status_data: StatusEffectData = s["data"]
		if "grants_interrupt" in status_data and status_data.grants_interrupt != null:
			result.append({"data": status_data.grants_interrupt, "source": "status", "status": status_data})
	return result
# ── VISUAL OVERRIDE TRANSITIONS ───────────────────────────────────────────────

func _begin_visual_override(status_data: StatusEffectData) -> void:
	# Starts the visual override sequence. Branches on visual_override_mode:
	#   "animation_names" — plays enter_animation on the unit's OWN
	#       AnimatedSprite2D, then redirects idle/walk/attack/hurt calls to
	#       the override_* names for the duration.
	#   "override_scene" — hides the unit's own sprite and instantiates
	#       override_scene as a child, playing its "enter" animation once,
	#       then its "idle" animation looping for the duration.
	if not has_node("AnimatedSprite2D"):
		return

	_active_visual_override = status_data

	if status_data.visual_override_mode == "override_scene":
		_begin_scene_override(status_data)
		return

	# ── ANIMATION-NAMES MODE (existing behaviour) ─────────────────────────────
	if status_data.enter_animation == "":
		# No transition animation — jump straight to the override idle look.
		play_animation("idle")
		return

	_visual_override_transitioning = true
	var sprite := $AnimatedSprite2D as AnimatedSprite2D
	if sprite.sprite_frames != null and sprite.sprite_frames.has_animation(status_data.enter_animation):
		sprite.play(status_data.enter_animation)
		await sprite.animation_finished
	else:
		printerr("⚠️ Status '", status_data.display_name, "': enter_animation '",
				 status_data.enter_animation, "' not found on this unit's own ",
				 "AnimatedSprite2D. If this animation lives in a separate scene file, ",
				 "set visual_override_mode to 'override_scene' and use override_scene instead.")
	_visual_override_transitioning = false

	# Only settle into the override idle if this status is STILL the active
	# override (it's possible it was removed mid-transition).
	if is_instance_valid(self) and _active_visual_override == status_data:
		play_animation("idle")


func _end_visual_override(status_data: StatusEffectData) -> void:
	# Plays exit_animation/exit phase once (if set), then restores the unit's
	# normal animation set or sprite visibility.
	if status_data.visual_override_mode == "override_scene":
		await _end_scene_override(status_data)
		return

	if not has_node("AnimatedSprite2D"):
		_active_visual_override = null
		return

	if status_data.exit_animation == "":
		_active_visual_override = null
		if is_instance_valid(self):
			play_animation("idle")
		return

	_visual_override_transitioning = true
	var sprite := $AnimatedSprite2D as AnimatedSprite2D
	if sprite.sprite_frames != null and sprite.sprite_frames.has_animation(status_data.exit_animation):
		sprite.play(status_data.exit_animation)
		await sprite.animation_finished
	else:
		printerr("⚠️ Status '", status_data.display_name, "': exit_animation '",
				 status_data.exit_animation, "' not found on this unit's own AnimatedSprite2D.")
	_visual_override_transitioning = false

	# Clear the override AFTER the exit plays so play_animation() redirection
	# was correctly disabled during the exit animation itself (the exit anim
	# plays as its own named clip, not redirected through idle/attack/etc).
	_active_visual_override = null
	if is_instance_valid(self):
		play_animation("idle")

# ── SCENE-BASED VISUAL OVERRIDE ───────────────────────────────────────────────
# Used when StatusEffectData.visual_override_mode == "override_scene". Instead
# of redirecting animation names within the unit's existing AnimatedSprite2D,
# an entirely separate scene (with its own SpriteFrames/AnimationPlayer) is
# instantiated as a child of the unit and shown in its place. That scene is
# expected to contain animations named exactly "enter", "idle", and "exit".

func _begin_scene_override(status_data: StatusEffectData) -> void:
	if status_data.override_scene == null:
		printerr("⚠️ Status '", status_data.display_name,
				 "' has visual_override_mode = override_scene but no override_scene assigned.")
		_active_visual_override = null
		return

	# Hide the unit's normal sprite while the override scene is shown.
	if has_node("AnimatedSprite2D"):
		$AnimatedSprite2D.visible = false

	_override_scene_instance = status_data.override_scene.instantiate()
	add_child(_override_scene_instance)

	var anim_node = _find_animation_node(_override_scene_instance)
	if anim_node == null:
		printerr("⚠️ override_scene for '", status_data.display_name,
				 "' has no AnimatedSprite2D or AnimationPlayer — cannot play enter/idle.")
		return

	if _has_anim(anim_node, "enter"):
		_visual_override_transitioning = true
		_play_anim(anim_node, "enter")
		await _anim_finished_signal(anim_node)
		_visual_override_transitioning = false

	# Only settle into idle if this status is STILL the active override —
	# it may have been removed while "enter" was playing.
	if is_instance_valid(self) and _active_visual_override == status_data:
		if is_instance_valid(_override_scene_instance) and _has_anim(anim_node, "idle"):
			_play_anim(anim_node, "idle", true)


func _end_scene_override(status_data: StatusEffectData) -> void:
	var instance = _override_scene_instance
	if instance == null or not is_instance_valid(instance):
		_active_visual_override = null
		_override_scene_instance = null
		if has_node("AnimatedSprite2D") and is_instance_valid(self):
			$AnimatedSprite2D.visible = true
		return

	var anim_node = _find_animation_node(instance)
	if anim_node != null and _has_anim(anim_node, "exit"):
		_visual_override_transitioning = true
		_play_anim(anim_node, "exit")
		await _anim_finished_signal(anim_node)
		_visual_override_transitioning = false

	if is_instance_valid(instance):
		instance.queue_free()
	_override_scene_instance = null
	_active_visual_override = null

	if is_instance_valid(self):
		if has_node("AnimatedSprite2D"):
			$AnimatedSprite2D.visible = true
		play_animation("idle")


func _find_animation_node(scene_instance: Node):
	# Locates the node that drives animation within an override scene — either
	# the root itself or a direct/nested child named AnimatedSprite2D or
	# AnimationPlayer. Returns null if neither is found anywhere in the scene.
	if scene_instance is AnimatedSprite2D or scene_instance is AnimationPlayer:
		return scene_instance
	if scene_instance.has_node("AnimatedSprite2D"):
		return scene_instance.get_node("AnimatedSprite2D")
	if scene_instance.has_node("AnimationPlayer"):
		return scene_instance.get_node("AnimationPlayer")
	# Fall back to a recursive search in case it's nested deeper.
	for child in scene_instance.get_children():
		var found = _find_animation_node(child)
		if found != null:
			return found
	return null


func _has_anim(anim_node, anim_name: String) -> bool:
	if anim_node is AnimatedSprite2D:
		var sf = (anim_node as AnimatedSprite2D).sprite_frames
		return sf != null and sf.has_animation(anim_name)
	if anim_node is AnimationPlayer:
		return (anim_node as AnimationPlayer).has_animation(anim_name)
	return false


func _play_anim(anim_node, anim_name: String, loop_idle: bool = false) -> void:
	if anim_node is AnimatedSprite2D:
		(anim_node as AnimatedSprite2D).play(anim_name)
	elif anim_node is AnimationPlayer:
		(anim_node as AnimationPlayer).play(anim_name)


func _anim_finished_signal(anim_node) -> Signal:
	if anim_node is AnimatedSprite2D:
		return (anim_node as AnimatedSprite2D).animation_finished
	return (anim_node as AnimationPlayer).animation_finished

# ── STATUS QUERY HELPERS ──────────────────────────────────────────────────────

func has_status(status_id: String) -> bool:
	# Returns true if the unit currently has a status with the given id.
	for s in active_statuses:
		if s["data"].id == status_id:
			return true
	return false


func get_buff_count() -> int:
	var count = 0
	for s in active_statuses:
		var d: StatusEffectData = s["data"]
		if d.is_hidden():
			continue
		if d.classifies_as_buff():
			count += s["stacks"]
	return count


func get_debuff_count() -> int:
	var count = 0
	for s in active_statuses:
		var d: StatusEffectData = s["data"]
		if d.is_hidden():
			continue
		if d.classifies_as_debuff():
			count += s["stacks"]
	return count

# ── UI HELPERS ────────────────────────────────────────────────────────────────

const HP_BAR_WIDTH: float  = 64.0
const HP_BAR_HEIGHT: float = 8.0

# Positions the bar at the very BOTTOM EDGE of the unit's own tile.
# Units are positioned at the CENTER of their tile (grid_to_world returns the
# tile's center point), and TILE_SIZE is 96px, so the bottom edge is exactly
# half a tile (48px) below the unit's origin. Subtracting a couple pixels for
# HP_BAR_HEIGHT keeps the bar fully inside the tile rather than straddling
# the boundary into the tile below.
const HP_BAR_Y_OFFSET: float = 48.0 - HP_BAR_HEIGHT

const HP_BAR_BG_TEXTURE_PATH: String = "res://sprites/UI/Health & Mana Bars/hpbar_background.png"
# Your background/frame art. Drawn as a Sprite2D sized to fit the bar area —
# the colored fill ColorRect sits on top of it and is clipped to show progress.

var _hp_bar_bg_sprite: Sprite2D = null
var _hp_bar_fill: ColorRect = null
# Built lazily on first use so existing unit scenes don't need any manual
# scene-tree changes — the bar is constructed entirely in code.


func _ensure_hp_bar_exists() -> void:
	# Creates the HP bar's background sprite + fill rect once, the first time
	# they're needed. Safe to call repeatedly — does nothing after the first time.
	if _hp_bar_bg_sprite != null and is_instance_valid(_hp_bar_bg_sprite):
		return

	_hp_bar_bg_sprite = Sprite2D.new()
	var bg_texture: Texture2D = load(HP_BAR_BG_TEXTURE_PATH)
	if bg_texture != null:
		_hp_bar_bg_sprite.texture = bg_texture
		# Scale the art to exactly HP_BAR_WIDTH x HP_BAR_HEIGHT regardless of
		# the source image's native pixel size, so swapping in a different-sized
		# PNG later doesn't require touching any code.
		var tex_size: Vector2 = bg_texture.get_size()
		if tex_size.x > 0 and tex_size.y > 0:
			_hp_bar_bg_sprite.scale = Vector2(HP_BAR_WIDTH / tex_size.x, HP_BAR_HEIGHT / tex_size.y)
	else:
		printerr("⚠️ Could not load HP bar background at: ", HP_BAR_BG_TEXTURE_PATH)

	# Sprite2D draws centered on its position by default, so offset by half
	# the bar size to align its top-left corner the same way the old
	# ColorRect-based bar did.
	_hp_bar_bg_sprite.position = Vector2(0, HP_BAR_Y_OFFSET + HP_BAR_HEIGHT / 2.0)
	_hp_bar_bg_sprite.centered = true
	_hp_bar_bg_sprite.z_index = 5
	add_child(_hp_bar_bg_sprite)

	_hp_bar_fill = ColorRect.new()
	_hp_bar_fill.size = Vector2(HP_BAR_WIDTH - 4.0, HP_BAR_HEIGHT - 4.0)
	# Positioned relative to the unit's origin (NOT relative to the sprite,
	# since ColorRect and Sprite2D measure position differently) — top-left
	# corner inset by 2px on each side so the fill sits just inside the
	# background art's border.
	_hp_bar_fill.position = Vector2(-HP_BAR_WIDTH / 2.0 + 2.0, HP_BAR_Y_OFFSET + 2.0)
	_hp_bar_fill.color = Color(0.2, 0.9, 0.2, 1.0)   # Green fill — updated per-HP below.
	_hp_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_bar_fill.z_index = 6
	add_child(_hp_bar_fill)


func _update_hp_label() -> void:
	# Updates the HP bar below the unit's sprite. Name kept as "_update_hp_label"
	# since it's called from many existing places (setup, take_damage, heal),
	# but it now drives a visual bar instead of a text label.
	_ensure_hp_bar_exists()

	var max_hp: int = 1
	if unit_data != null:
		max_hp = get_effective_max_hp()

	var pct: float = clamp(float(current_hp) / float(max_hp), 0.0, 1.0)
	var full_width: float = HP_BAR_WIDTH - 4.0
	_hp_bar_fill.size.x = full_width * pct

	# Color shifts from green → yellow → red as HP drops, for an at-a-glance read.
	if pct > 0.5:
		_hp_bar_fill.color = Color(0.2, 0.9, 0.2, 1.0)
	elif pct > 0.25:
		_hp_bar_fill.color = Color(0.95, 0.85, 0.1, 1.0)
	else:
		_hp_bar_fill.color = Color(0.9, 0.15, 0.15, 1.0)

var _is_updating_visuals: bool = false
func update_visuals() -> void:
	if _is_updating_visuals: 
		print("Recursion blocked!")
		return 
	
	_is_updating_visuals = true
	
	var sprite = $AnimatedSprite2D
	# Wrap this in a try-catch equivalent or debug print to see if it's the trigger
	print("Checking status...")
	var is_invisible = has_status("invisible") 
	
	sprite.modulate.a = 0.5 if is_invisible else 1.0
	
	_is_updating_visuals = false


func _debug_print_status_applied(status_data: StatusEffectData, stacks: int) -> void:
	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	print("📊 STATUS APPLIED: '", status_data.display_name, "' × ", stacks,
		  " → ", unit_data.display_name)
	#print("   ATK:  base=", get_stats().atk,  "  effective=", get_effective_atk())
	#print("   DEF:  base=", get_stats().def,  "  effective=", get_effective_def())
	#print("   MOV:  base=", get_stats().mov,  "  effective=", get_effective_mov())

# Replace 'reset_unit_state' and 'is_attacking' with the actual names in your script
func _on_attack_animation_finished():
	# Look for a function in your script that handles resetting the unit
	# Example: end_turn(), set_state(IDLE), or deselect()
	call_deferred("your_actual_reset_function_name") 

func force_idle_state() -> void:
	if has_node("AnimatedSprite2D"):
		play_animation("idle")
	# If your grid manager or battle manager needs to know the attack is done:
	# (Look in your BattleManager for a function like "deselect_unit" or "clear_selection")
	# If you aren't sure, calling play_animation("idle") is the safest first step.
