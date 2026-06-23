# res://scripts/battle/aura_manager.gd
# ==============================================================================
# AURA MANAGER — Owns and processes all active auras in a battle.
# ==============================================================================
# This node lives as a child of BattleGrid (add it in the BattleGrid scene).
# It is the single source of truth for:
#   - Which units have active auras
#   - Which cells each aura covers
#   - The aura visual nodes (ColorRects, sprites, or scene instances)
#   - Momentum kill-count tracking and accumulated stat bonuses
#   - Crit Overload splash handling
#   - Per-round ticking (duration countdown and end-of-round effects)
#
# BattleManager tells it WHEN to tick and when a kill/crit happened.
# It figures out WHO is affected by reading grid_ref for unit positions.
# ==============================================================================

extends Node

# ── EXTERNAL REFERENCES ───────────────────────────────────────────────────────

var grid_ref: Node = null
# Set by BattleManager on startup. Used to look up unit positions and
# convert grid coordinates to world pixel positions.

# ── CONSTANTS ─────────────────────────────────────────────────────────────────

const TILE_SIZE: int = 96
# Must match BattleGrid.TILE_SIZE. Used to size and position visual rects.

const VISUAL_FADE_DURATION: float = 0.4
# How many seconds the aura visual takes to fade in or out.

const VISUAL_MOVE_DURATION: float = 1.5
# How many seconds the aura visuals take to slide to a new position when the
# caster moves. Must match the default move_speed in unit_node.gd (also 1.5)
# so the overlay stays perfectly in sync with the unit sprite underneath.

# ── LIVE AURA REGISTRY ────────────────────────────────────────────────────────
# Each entry in this array is a Dictionary describing one live aura instance.
# Structure:
# {
#   "caster":          UnitNode,      — the unit whose aura this is
#   "data":            AuraData,      — the resource defining the aura's rules
#   "remaining_rounds": int,          — rounds left (-1 = infinite/permanent)
#   "visuals":         Array,         — Node2D visuals for this aura (rects or scene)
#   "aura_cells":      Array[Vector2i], — the grid cells currently covered
#   "enemies_hit_this_round": Array,  — units that already took end-of-round damage
#   "momentum_kills":  int,           — total kills scored inside this aura
#   "momentum_float_totals": Dictionary, — { stat_name: float } accumulated fractions
#   "momentum_recipients": Array,     — units currently receiving momentum bonuses
# }

var _active_auras: Array = []

# ── AURA LAYER NODE ───────────────────────────────────────────────────────────
# Visual rects are added to this node. It must be positioned in the scene tree
# BETWEEN GroundLayer and HazardLayer so auras appear above the map but below units.
# In BattleGrid.tscn, add a Node2D named "AuraLayer" as the second child
# (after GroundLayer, before HazardLayer).

var _aura_layer: Node2D = null

# ── SETUP ─────────────────────────────────────────────────────────────────────

func setup(grid: Node, aura_layer: Node2D) -> void:
	# Called by BattleManager at the start of each battle.
	# grid      — the BattleGrid node
	# aura_layer — the Node2D between GroundLayer and HazardLayer
	grid_ref    = grid
	_aura_layer = aura_layer
	_active_auras.clear()

# ── PUBLIC API — ACTIVATION ───────────────────────────────────────────────────

func activate_aura(caster, aura_data: AuraData) -> void:
	# Called by AbilityExecutor when a unit uses an aura ability.
	# Handles type_1 exclusivity (removes old type_1 with a fade),
	# then registers and visualises the new aura.

	# -- TYPE 1 EXCLUSIVITY ────────────────────────────────────────────────────
	# A caster can only hold one type_1 aura. Find any existing type_1 from this
	# caster and remove it with a fade-out before adding the new one.
	if aura_data.aura_type == "type_1":
		for i in range(_active_auras.size() - 1, -1, -1):
			# Iterate backwards so we can safely remove while looping.
			var entry = _active_auras[i]
			if entry["caster"] == caster and entry["data"].aura_type == "type_1":
				_fade_and_remove_aura(i)
				# There can only be one, so stop after the first match.
				break

	# -- BUILD THE NEW AURA ENTRY ──────────────────────────────────────────────
	var cells = _get_aura_cells(caster.grid_position, aura_data.radius)
	var remaining = -1 if aura_data.is_permanent else aura_data.duration_rounds

	var entry = {
		"caster":                 caster,
		"data":                   aura_data,
		"remaining_rounds":       remaining,
		"visuals":                [],         # Filled in by _spawn_visuals below.
		"aura_cells":             cells,
		"anchor_cell":            caster.grid_position,
		# anchor_cell is the tile the aura was CAST from.
		# For follows_caster=true auras it stays in sync with the caster and is
		# mainly used for scene-type visual positioning.
		# For follows_caster=false auras it NEVER changes — it is the permanent
		# centre of the planted zone for the aura's entire lifetime.
		"enemies_hit_this_round": [],         # Cleared each round.
		"momentum_kills":         0,
		"momentum_float_totals":  {           # Fractional accumulators for each stat.
			"atk":        0.0,
			"def":        0.0,
			"matk":       0.0,
			"mdef":       0.0,
			"mov":        0.0,
			"crit_chance":0.0,
			"crit_damage":0.0,
		},
		"momentum_recipients":    [],         # Units currently boosted by momentum.
	}

	_active_auras.append(entry)

	# -- SPAWN VISUALS with a FADE-IN ──────────────────────────────────────────
	_spawn_visuals(entry, true)

	# -- APPLY ALLY ENTRY EFFECTS IMMEDIATELY ──────────────────────────────────
	# Allies already standing in the aura receive status effects right away
	# (before they act this turn). This is the "buff before attack" behaviour.
	if aura_data.affects_team != "enemies":
		for cell in cells:
			var unit = grid_ref.get_unit_at(cell)
			if unit == null or not is_instance_valid(unit):
				continue
			if _is_ally(caster, unit):
				_apply_statuses_to(unit, aura_data)


func remove_all_auras_for(caster) -> void:
	# Called when a unit DIES. Removes all their auras immediately,
	# and also strips any Momentum bonuses from recipients right away.
	for i in range(_active_auras.size() - 1, -1, -1):
		var entry = _active_auras[i]
		if entry["caster"] == caster:
			_strip_momentum_bonuses(entry)
			_remove_aura_entry(i)


func clear_all() -> void:
	# Called at the start of each new battle to wipe the slate clean.
	for entry in _active_auras:
		for visual in entry["visuals"]:
			if is_instance_valid(visual):
				visual.queue_free()
	_active_auras.clear()

# ── PUBLIC API — UNIT MOVEMENT (ENTRY EFFECTS) ────────────────────────────────

func on_unit_moved(unit) -> void:
	# Called by BattleManager whenever a PLAYER unit finishes moving to a new tile.
	# This is where ally entry buffs are applied.
	# Enemy entry effects are NOT applied here — they are deferred to end of round.
	for entry in _active_auras:
		var data: AuraData = entry["data"]

		# Refresh the aura cells to the caster's current position.
		# (The caster may have moved too, but we recalculate on tick anyway.)
		var cells = entry["aura_cells"]

		if not unit.grid_position in cells:
			continue  # This unit is not inside this aura; skip.

		# Only apply ally-targeted buffs on entry.
		if data.affects_team == "enemies":
			continue  # Enemy effects are end-of-round only.

		var caster = entry["caster"]
		if _is_ally(caster, unit):
			_apply_statuses_to(unit, data)


func on_enemy_unit_moved(unit) -> void:
	# Called by AISystem whenever an ENEMY unit finishes moving to a new tile.
	# Unlike player movement, enemies take aura damage and status effects
	# immediately upon entering a hostile aura — they don't wait for end-of-round.
	#
	# This is intentionally asymmetric:
	#   - Allies get buffs on entry (so they're buffed before they attack).
	#   - Enemies get debuffs/damage on entry during their own phase (so stepping
	#     into a war aura feels dangerous and punishes aggressive movement).
	#
	# End-of-round ticking still applies as normal, so an enemy who was already
	# inside an aura at the start of their turn will also be hit at end of round.
	# Only the ENTRY hit is immediate — no double-dipping on the same move.
	for entry in _active_auras:
		var data: AuraData = entry["data"]
		var cells: Array   = entry["aura_cells"]

		# Is this enemy inside this aura?
		if not unit.grid_position in cells:
			continue

		# Does this aura affect enemies?
		var caster = entry["caster"]
		if not _matches_team(caster, unit, data.affects_team):
			continue

		# Only fire the entry hit if this unit wasn't already marked as hit this
		# round. This prevents double-dipping if on_enemy_unit_moved fires more
		# than once in the same round (shouldn't happen, but defensive check).
		if unit in entry["enemies_hit_this_round"]:
			continue

		# Mark as hit so the end-of-round tick doesn't double-apply this round.
		entry["enemies_hit_this_round"].append(unit)

		# Apply immediate damage on entry.
		if data.damage_mode != "none":
			var dmg = _calculate_aura_damage(caster, unit, data)
			unit.take_damage(dmg, _damage_type_string(data))
			print("🌀 Aura '", data.id, "' entry damage: ", dmg,
				  " → ", unit.unit_data.display_name)

		# Apply status effects immediately on entry.
		_apply_statuses_to(unit, data)


func begin_caster_move(caster, new_cell: Vector2i) -> void:
	# Called by unit_node.move_to() BEFORE the slide tween starts.
	# Fires the aura visual tween at the exact same moment as the unit tween,
	# so the overlay moves in perfect lockstep with the sprite underneath.
	#
	# Cell coverage and ally entry-buff logic are handled AFTER movement finishes
	# in on_caster_moved() — this function is purely visual.
	for entry in _active_auras:
		if entry["caster"] != caster:
			continue
		if not entry["data"].follows_caster:
			continue

		# Compute where each visual needs to end up.
		var data: AuraData   = entry["data"]
		var new_cells: Array = _get_aura_cells(new_cell, data.radius)

		match data.visual_type:
			"color", "sprite":
				if entry["visuals"].size() == new_cells.size():
					for idx in range(new_cells.size()):
						var visual = entry["visuals"][idx]
						if not is_instance_valid(visual):
							continue
						var cell: Vector2i = new_cells[idx]
						var target_pos: Vector2
						if data.visual_type == "color":
							target_pos = grid_ref.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
						else:
							target_pos = grid_ref.grid_to_world(cell)
						var tween = visual.create_tween()
						tween.set_trans(Tween.TRANS_CUBIC)
						tween.set_ease(Tween.EASE_OUT)
						tween.tween_property(visual, "position", target_pos, VISUAL_MOVE_DURATION)
				# If cell count changed (map boundary edge case), do nothing here —
				# _rebuild_visuals in on_caster_moved will handle it after arrival.

			"scene":
				var new_anchor_world: Vector2 = grid_ref.grid_to_world(new_cell)
				for visual in entry["visuals"]:
					if not is_instance_valid(visual):
						continue
					var tween = visual.create_tween()
					tween.set_trans(Tween.TRANS_CUBIC)
					tween.set_ease(Tween.EASE_OUT)
					tween.tween_property(visual, "position", new_anchor_world, VISUAL_MOVE_DURATION)


func on_caster_moved(caster) -> void:
	# Called by BattleManager AFTER the caster's movement tween completes.
	# By this point begin_caster_move() has already handled the visual slide.
	# This function handles the logical side: updating cell coverage, anchor_cell,
	# and applying ally entry buffs to any units now inside the shifted zone.
	# It also rebuilds visuals for the edge case where cell count changed.
	for entry in _active_auras:
		if entry["caster"] != caster:
			continue

		var data: AuraData = entry["data"]

		# Stationary auras never move — skip entirely.
		if not data.follows_caster:
			continue

		var new_cells: Array = _get_aura_cells(caster.grid_position, data.radius)
		var old_cells: Array = entry["aura_cells"]
		entry["aura_cells"]  = new_cells
		entry["anchor_cell"] = caster.grid_position

		# Only rebuild visuals if the cell count changed (map boundary edge case).
		# Normally begin_caster_move already tweened them to the right place.
		if entry["visuals"].size() != new_cells.size():
			_rebuild_visuals(entry)

		# Apply ally entry buffs for cells newly inside the aura.
		for cell in new_cells:
			if cell in old_cells:
				continue
			var unit = grid_ref.get_unit_at(cell)
			if unit == null or not is_instance_valid(unit):
				continue
			if data.affects_team != "enemies" and _is_ally(caster, unit):
				_apply_statuses_to(unit, data)

# ── PUBLIC API — CRIT OVERLOAD ────────────────────────────────────────────────

func on_critical_hit(caster, target, original_crit_damage: int) -> void:
	# Called by AbilityExecutor whenever a critical hit lands.
	# Checks if any of the caster's auras have Crit Overload, and if so,
	# rolls to see if the splash triggers.
	for entry in _active_auras:
		if entry["caster"] != caster:
			continue
		var data: AuraData = entry["data"]
		if not data.has_crit_overload:
			continue

		# Is the target inside this aura?
		if not target.grid_position in entry["aura_cells"]:
			continue

		# Roll the crit overload chance.
		var roll = randf() * 100.0
		if roll >= data.crit_overload_chance:
			continue  # Didn't proc this time.

		# Calculate the splash damage (true damage, bypasses all defence).
		var splash_damage = max(1, int(float(original_crit_damage) * data.crit_overload_damage_percent))
		print("💥 Crit Overload triggered! Splash damage: ", splash_damage)

		# Find all enemy cells within the splash radius around the target.
		var splash_cells = _get_aura_cells(target.grid_position, data.crit_overload_radius)
		var already_splashed: Array = [target]  # Don't hit the original target again.

		for cell in splash_cells:
			var victim = grid_ref.get_unit_at(cell)
			if victim == null or not is_instance_valid(victim):
				continue
			if victim in already_splashed:
				continue
			# Only hits enemies of the caster.
			if _is_ally(caster, victim):
				continue

			already_splashed.append(victim)
			victim.take_damage(splash_damage, "true")
			print("   💥 Crit Overload hit ", victim.unit_data.display_name, " for ", splash_damage)

			# Play the one-shot VFX scene on this tile if one is defined.
			if data.crit_overload_vfx_scene != null:
				_play_vfx_at(data.crit_overload_vfx_scene, victim.position)

# ── PUBLIC API — MOMENTUM (KILLS) ─────────────────────────────────────────────

func on_unit_killed_inside_aura(caster, killed_unit) -> void:
	# Called by AbilityExecutor when a kill is confirmed inside an aura zone.
	# We count the kill and add permanent fractional stat bonuses.
	for entry in _active_auras:
		if entry["caster"] != caster:
			continue
		var data: AuraData = entry["data"]
		if not data.has_momentum:
			continue

		# Was the kill inside this aura?
		# (killed_unit.grid_position is still valid at this point — die() hasn't freed it yet.)
		if not killed_unit.grid_position in entry["aura_cells"]:
			continue

		entry["momentum_kills"] += 1
		print("🔥 Momentum: ", caster.unit_data.display_name,
			  " kill #", entry["momentum_kills"], " inside aura '", data.id, "'")

		# Accumulate the fractional bonuses.
		var totals: Dictionary = entry["momentum_float_totals"]
		totals["atk"]         += data.momentum_atk_per_kill
		totals["def"]         += data.momentum_def_per_kill
		totals["matk"]        += data.momentum_matk_per_kill
		totals["mdef"]        += data.momentum_mdef_per_kill
		totals["mov"]         += data.momentum_mov_per_kill
		totals["crit_chance"] += data.momentum_crit_chance_per_kill
		totals["crit_damage"] += data.momentum_crit_damage_per_kill

		# Decide who receives the bonuses.
		var recipients: Array = _get_momentum_recipients(entry)

		# Strip OLD bonuses from the previous recipients, then re-apply the NEW totals.
		# This keeps things clean: we always replace rather than stack on top.
		_strip_momentum_bonuses(entry)
		entry["momentum_recipients"] = recipients
		_apply_momentum_bonuses(entry)

# ── PUBLIC API — END-OF-ROUND TICK ────────────────────────────────────────────

func tick_auras_end_of_player_round(player_units: Array, enemy_units: Array) -> void:
	# Called by BattleManager at the end of the player's round (just before the
	# enemy turn begins). This is when enemy damage and status effects apply.

	var to_remove: Array = []  # Indices of auras that have just expired.

	for i in range(_active_auras.size()):
		var entry    = _active_auras[i]
		var data: AuraData = entry["data"]
		var caster   = entry["caster"]

		# Safety check — if the caster was freed since last frame, remove the aura.
		if not is_instance_valid(caster):
			to_remove.append(i)
			continue

		# -- RECALCULATE CELLS ─────────────────────────────────────────────────
		# For follows_caster=true auras: the caster may have moved this round,
		# so recalculate from their CURRENT position.
		# For follows_caster=false auras: cells are fixed at the cast location
		# (anchor_cell) and must never change, so we use anchor_cell instead.
		var centre_cell: Vector2i = (
			caster.grid_position if data.follows_caster
			else entry["anchor_cell"]
		)
		entry["aura_cells"] = _get_aura_cells(centre_cell, data.radius)
		var cells: Array    = entry["aura_cells"]

		# -- APPLY DAMAGE & STATUSES TO ENEMIES ────────────────────────────────
		if data.damage_mode != "none" or data.applies_statuses.size() > 0:
			for cell in cells:
				var unit = grid_ref.get_unit_at(cell)
				if unit == null or not is_instance_valid(unit):
					continue
				# Only affect the correct team.
				if not _matches_team(caster, unit, data.affects_team):
					continue
				# Don't double-hit a unit that was already processed (multi-cell units).
				if unit in entry["enemies_hit_this_round"]:
					continue

				entry["enemies_hit_this_round"].append(unit)

				# Deal aura damage.
				if data.damage_mode != "none":
					var dmg = _calculate_aura_damage(caster, unit, data)
					unit.take_damage(dmg, _damage_type_string(data))
					print("🌀 Aura '", data.id, "' dealt ", dmg, " to ",
						  unit.unit_data.display_name)

				# Apply status effects.
				_apply_statuses_to(unit, data)

		# -- CLEAR THE HIT LIST FOR NEXT ROUND ─────────────────────────────────
		entry["enemies_hit_this_round"].clear()

		# -- TICK DURATION ─────────────────────────────────────────────────────
		if entry["remaining_rounds"] > 0:
			entry["remaining_rounds"] -= 1
			if entry["remaining_rounds"] <= 0:
				# Aura has run out of time — schedule for removal after the loop.
				to_remove.append(i)

	# Remove expired auras in reverse order so indices stay valid.
	for i in range(to_remove.size() - 1, -1, -1):
		var idx = to_remove[i]
		_strip_momentum_bonuses(_active_auras[idx])
		_fade_and_remove_aura(idx)

# ── PRIVATE — TEAM HELPERS ────────────────────────────────────────────────────

func _is_ally(caster, unit) -> bool:
	# Returns true if 'unit' is on the SAME team as 'caster'.
	return unit.is_player_unit == caster.is_player_unit


func _matches_team(caster, unit, affects_team: String) -> bool:
	# Returns true if 'unit' falls within the targeting filter.
	match affects_team:
		"enemies": return not _is_ally(caster, unit)
		"allies":  return _is_ally(caster, unit)
		"all":     return true
	return false

# ── PRIVATE — CELL CALCULATION ────────────────────────────────────────────────

func _get_aura_cells(center: Vector2i, radius: int) -> Array:
	# Returns all valid grid cells in a square of side (2*radius-1) centred
	# on 'center'. Matches the "square" AOE shape in battle_manager.gd.
	var cells: Array = []
	for x in range(-radius + 1, radius):
		for y in range(-radius + 1, radius):
			var cell = center + Vector2i(x, y)
			if grid_ref.is_valid_cell(cell):
				cells.append(cell)
	return cells

# ── PRIVATE — DAMAGE CALCULATION ──────────────────────────────────────────────

func _calculate_aura_damage(caster, target, data: AuraData) -> int:
	# Computes the damage this aura deals to 'target' this round.
	match data.damage_mode:
		"flat_true":
			# Flat true damage — ignores all stats and defences.
			return data.flat_damage

		"physical":
			# Same formula as AbilityExecutor: (ATK - DEF) * multiplier, min 1.
			var atk = caster.get_effective_atk()
			var def = target.get_effective_def()
			return max(1, int(float(atk - def) * data.damage_multiplier))

		"magical":
			# Magic version: (MATK - MDEF) * multiplier, min 1.
			var matk = caster.get_effective_matk()
			var mdef = target.get_effective_mdef()
			return max(1, int(float(matk - mdef) * data.damage_multiplier))

	return 0  # "none" or unrecognised mode.


func _damage_type_string(data: AuraData) -> String:
	# Maps our damage_mode to the string that UnitNode.take_damage() expects.
	match data.damage_mode:
		"flat_true": return "true"
		"physical":  return "physical"
		"magical":   return "magical"
	return "true"

# ── PRIVATE — STATUS APPLICATION ──────────────────────────────────────────────

func _apply_statuses_to(unit, data: AuraData) -> void:
	# Applies every status in the aura's list to the given unit.
	for status in data.applies_statuses:
		if status != null:
			unit.apply_status(status)

# ── PRIVATE — VISUALS ─────────────────────────────────────────────────────────

func _spawn_visuals(entry: Dictionary, fade_in: bool) -> void:
	# Creates the visual representation of an aura and adds it to AuraLayer.
	# If fade_in is true, all visuals start transparent and tween to full opacity.
	var data: AuraData = entry["data"]

	match data.visual_type:
		"color":
			# One ColorRect per tile in the aura area.
			for cell in entry["aura_cells"]:
				var rect = ColorRect.new()
				rect.size = Vector2(TILE_SIZE, TILE_SIZE)
				# Position the rect so it covers the tile exactly.
				rect.position = grid_ref.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
				rect.color = data.aura_color
				rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
				# Start invisible if we're fading in.
				if fade_in:
					rect.modulate.a = 0.0
				_aura_layer.add_child(rect)
				entry["visuals"].append(rect)
			if fade_in:
				_fade_visuals_in(entry["visuals"])

		"sprite":
			# One Sprite2D per tile showing the custom texture.
			for cell in entry["aura_cells"]:
				var sprite = Sprite2D.new()
				sprite.texture = data.aura_sprite
				sprite.position = grid_ref.grid_to_world(cell)
				if fade_in:
					sprite.modulate.a = 0.0
				_aura_layer.add_child(sprite)
				entry["visuals"].append(sprite)
			if fade_in:
				_fade_visuals_in(entry["visuals"])

		"scene":
			# One looping scene instance, placed at the caster's world position.
			if data.aura_scene != null:
				var instance = data.aura_scene.instantiate()
				var caster = entry["caster"]
				instance.position = grid_ref.grid_to_world(caster.grid_position)
				if fade_in:
					instance.modulate.a = 0.0
				_aura_layer.add_child(instance)
				entry["visuals"].append(instance)
				if fade_in:
					_fade_visuals_in(entry["visuals"])


func _rebuild_visuals(entry: Dictionary) -> void:
	# Smoothly slides existing aura visuals to their new positions when the caster moves.
	# This is called from on_caster_moved AFTER entry["aura_cells"] and entry["anchor_cell"]
	# have already been updated to the new position.
	#
	# Rather than destroying and respawning nodes (which causes a visible pop), we
	# tween each existing visual directly to its new target world position.
	# The tween duration and easing match unit_node.gd's move_to() exactly so the
	# aura overlay slides in perfect lockstep with the unit sprite underneath it.
	#
	# If the number of cells changed (rare edge case: map boundary), we fall back
	# to a full respawn since we can't tween a node that doesn't exist yet.
	var data: AuraData   = entry["data"]
	var new_cells: Array = entry["aura_cells"]

	match data.visual_type:

		"color", "sprite":
			# Each visual corresponds to one cell, in the same order they were created.
			# If cell count matches, slide each one to its new position.
			if entry["visuals"].size() == new_cells.size():
				for idx in range(new_cells.size()):
					var visual = entry["visuals"][idx]
					if not is_instance_valid(visual):
						continue
					var cell: Vector2i = new_cells[idx]
					var target_pos: Vector2
					if data.visual_type == "color":
						# ColorRect origins are top-left; subtract half a tile to align.
						target_pos = grid_ref.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
					else:
						# Sprite2D positions are centred on the tile.
						target_pos = grid_ref.grid_to_world(cell)
					# Match unit_node.move_to(): TRANS_CUBIC, EASE_OUT, same duration.
					var tween = visual.create_tween()
					tween.set_trans(Tween.TRANS_CUBIC)
					tween.set_ease(Tween.EASE_OUT)
					tween.tween_property(visual, "position", target_pos, VISUAL_MOVE_DURATION)
			else:
				# Cell count changed — fall back to a full destroy-and-respawn.
				for visual in entry["visuals"]:
					if is_instance_valid(visual):
						visual.queue_free()
				entry["visuals"].clear()
				_spawn_visuals(entry, false)

		"scene":
			# A single scene instance is centred on the anchor cell.
			# Tween it to the new anchor world position.
			var new_anchor_world: Vector2 = grid_ref.grid_to_world(entry["anchor_cell"])
			for visual in entry["visuals"]:
				if not is_instance_valid(visual):
					continue
				var tween = visual.create_tween()
				tween.set_trans(Tween.TRANS_CUBIC)
				tween.set_ease(Tween.EASE_OUT)
				tween.tween_property(visual, "position", new_anchor_world, VISUAL_MOVE_DURATION)


func _fade_visuals_in(visuals: Array) -> void:
	# Tweens all visuals in the list from alpha=0 to alpha=1.
	for visual in visuals:
		if not is_instance_valid(visual):
			continue
		var tween = visual.create_tween()
		tween.tween_property(visual, "modulate:a", 1.0, VISUAL_FADE_DURATION)


func _fade_visuals_out_and_free(visuals: Array) -> void:
	# Tweens all visuals from current alpha to 0, then frees them.
	for visual in visuals:
		if not is_instance_valid(visual):
			continue
		var tween = visual.create_tween()
		tween.tween_property(visual, "modulate:a", 0.0, VISUAL_FADE_DURATION)
		# After the fade completes, free the node from memory.
		tween.tween_callback(visual.queue_free)


func _fade_and_remove_aura(index: int) -> void:
	# Begins a fade-out on the visuals, then removes the aura entry from the list.
	# The visual nodes free themselves after the tween via queue_free callback.
	var entry = _active_auras[index]
	_strip_momentum_bonuses(entry)
	_fade_visuals_out_and_free(entry["visuals"])
	_active_auras.remove_at(index)


func _remove_aura_entry(index: int) -> void:
	# Instantly removes an aura entry and frees its visuals without a fade.
	# Used on caster death (immediate, no graceful fade).
	var entry = _active_auras[index]
	for visual in entry["visuals"]:
		if is_instance_valid(visual):
			visual.queue_free()
	_active_auras.remove_at(index)

# ── PRIVATE — VFX SPAWNING ────────────────────────────────────────────────────

func _play_vfx_at(scene: PackedScene, world_position: Vector2) -> void:
	# Spawns a one-shot VFX scene at the given world position.
	# The scene is expected to free itself when it finishes (e.g. via AnimationPlayer
	# calling queue_free, or a timer).
	if scene == null:
		return
	var instance = scene.instantiate()
	instance.position = world_position
	# Attach to AuraLayer so it shares the same coordinate space.
	_aura_layer.add_child(instance)

# ── PRIVATE — MOMENTUM HELPERS ────────────────────────────────────────────────

func _get_momentum_recipients(entry: Dictionary) -> Array:
	# Returns the list of units that should currently receive this aura's bonuses.
	var data: AuraData = entry["data"]
	var caster = entry["caster"]

	if data.momentum_applies_to == "caster_only":
		return [caster]

	# "all_allies": gather every player unit that is still alive.
	# We access player_units via BattleManager. The AuraManager doesn't hold a
	# direct reference, so we walk the scene tree to find BattleManager.
	# A cleaner solution: pass player_units into tick_auras_end_of_player_round
	# and cache them. We do that here via a stored reference set in that function.
	# For now, use the grid to find allies.
	var allies: Array = []
	for cell in grid_ref.unit_positions:
		var unit = grid_ref.unit_positions[cell]
		if is_instance_valid(unit) and _is_ally(caster, unit):
			if not unit in allies:
				allies.append(unit)
	return allies


func _apply_momentum_bonuses(entry: Dictionary) -> void:
	# Writes the current accumulated momentum bonuses to each recipient.
	# We store the bonuses directly on the unit as a Dictionary so we can
	# read them in the stat getter functions (see the unit_node.gd changes).
	var totals: Dictionary = entry["momentum_float_totals"]
	var aura_id: String    = entry["data"].id

	for unit in entry["momentum_recipients"]:
		if not is_instance_valid(unit):
			continue
		# momentum_bonuses is a Dictionary on UnitNode: { aura_id: { stat: int } }
		# Using floor() converts the float accumulation into a whole-number bonus.
		unit.momentum_bonuses[aura_id] = {
			"atk":        int(floor(totals["atk"])),
			"def":        int(floor(totals["def"])),
			"matk":       int(floor(totals["matk"])),
			"mdef":       int(floor(totals["mdef"])),
			"mov":        int(floor(totals["mov"])),
			"crit_chance":totals["crit_chance"],   # Float — already a percentage.
			"crit_damage":totals["crit_damage"],   # Float — already a percentage.
		}
		print("🔥 Momentum bonus applied to ", unit.unit_data.display_name,
			  ": ATK+", int(floor(totals["atk"])),
			  " DEF+", int(floor(totals["def"])))


func _strip_momentum_bonuses(entry: Dictionary) -> void:
	# Removes the momentum bonuses this aura granted from all its recipients.
	# Called when the aura expires OR when the caster dies.
	var aura_id: String = entry["data"].id
	for unit in entry["momentum_recipients"]:
		if not is_instance_valid(unit):
			continue
		unit.momentum_bonuses.erase(aura_id)
		print("🔥 Momentum bonus removed from ", unit.unit_data.display_name)
		

func snap_to(caster) -> void:
	# Called by BattleManager when a unit's movement is canceled or instantly warped.
	# This bypasses the sliding tweens and immediately snaps the aura to the unit.
	for entry in _active_auras:
		if entry["caster"] != caster:
			continue
		
		var data: AuraData = entry["data"]
		
		# Stationary auras never move, so skip updating positioning
		if not data.follows_caster:
			continue
			
		# 1. Update the logical grid positions immediately
		var new_cells: Array = _get_aura_cells(caster.grid_position, data.radius)
		entry["aura_cells"]  = new_cells
		entry["anchor_cell"] = caster.grid_position
		
		# 2. Instantly teleport the visual nodes without a tween
		match data.visual_type:
			"color", "sprite":
				# If cell count changed due to map boundaries, rebuild completely
				if entry["visuals"].size() != new_cells.size():
					_rebuild_visuals(entry)
				else:
					for idx in range(new_cells.size()):
						var visual = entry["visuals"][idx]
						if not is_instance_valid(visual):
							continue
						var cell: Vector2i = new_cells[idx]
						
						if data.visual_type == "color":
							visual.position = grid_ref.grid_to_world(cell) - Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
						else:
							visual.position = grid_ref.grid_to_world(cell)
							
			"scene":
				var anchor_world: Vector2 = grid_ref.grid_to_world(caster.grid_position)
				for visual in entry["visuals"]:
					if is_instance_valid(visual):
						visual.position = anchor_world
