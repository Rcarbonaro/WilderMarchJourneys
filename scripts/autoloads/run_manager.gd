# res://scripts/autoloads/run_manager.gd
#
# RUN MANANGER-- the single autoload that holds "what's currently loaded":
# the active RunState (or null if no run is in progress) and the MetaState
# (always loaded). Also owns save/load to disk.
#
# REGISTER THIS AS THE AUTOLOAD NAMED "RunManager" (not "GameState") --
# every existing script (battle_manager.gd, battle_scene.gd, main_menu.gd,
# stage_director.gd, combat_hooks.gd's wiring checklist) already calls
# RunManager.current_run / RunManager.add_gold() / RunManager.is_test_mode /
# etc. Godot's autoload singleton name comes from the NODE NAME you give it
# in Project Settings > Autoload, not from this script's filename or class
# -- so registering this script under the name "RunManager" makes every one
# of those existing calls resolve here with zero other files needing to
# change.
extends Node

var current_run: RunState = null
var meta: MetaState = null

var _unit_data_load_cache: Dictionary = {}   # unit_id -> UnitData (or null if missing)
# Used by _guarantee_party_roles()/_load_unit_data_cached() below, purely to
# avoid re-loading the same .tres several times within one Random-mode party
# pick (checking existing party members, THEN scanning the full candidate
# pool for a replacement). Harmless to keep around between calls too -- same
# resources every time, nothing goes stale.

const SAVE_DIR := "user://saves/"
const META_SAVE_PATH := "user://meta_state.json"

# ── TEST MODE (your existing sandbox -- untouched logic, just given a home) ───
# battle_manager.gd's _spawn_stage_enemies() already checks these two fields
# and calls _spawn_test_enemies(test_encounter_index) when is_test_mode is
# true -- that function is NOT touched by anything in this package. Flip
# is_test_mode on/off however you like (a debug menu, editing it directly
# here, an exported var you toggle in the Inspector on this autoload node --
# your call, nothing in this file assumes a specific method).
@export var is_test_mode: bool = false
@export var test_encounter_index: int = 0


func _ready() -> void:
	_ensure_save_dir()
	meta = _load_meta_state()


func start_new_run(difficulty: String = "easy") -> RunState:
	var rs := RunState.new()
	rs.run_id = "run_" + Time.get_datetime_string_from_system().replace(":", "-")
	rs.player_seed = randi()
	rs.difficulty = difficulty
	# ADDED: without this, biome_sequence stayed empty forever, which meant
	# ScalingEngine.resolve_spawn_table() always looked up biome == "" and
	# never matched any spawn table -- shuffle a copy of the full biome pool
	# and take the first 3 (or fewer, if you've only defined 1-2 biomes so far).
	var pool: Array = ContentLoader.biome_pool.duplicate()
	pool.shuffle()
	rs.biome_sequence.assign(pool.slice(0, min(3, pool.size())))

	# ADDED: BUGFIX -- start_new_run_for_mode() below actually calls THIS
	# function to build its own RunState (see the line right at the top of
	# that function), so granting it here covers BOTH paths at once: plain
	# start_new_run() (used directly by at least game_mode_select.gd's Test
	# mode) and start_new_run_for_mode() (used by Random/Draft). One grant
	# point, no duplication -- same counter-in-runtime_effect_state approach
	# as camp_recruit_count, zero content authoring required.
	rs.runtime_effect_state["skill_scroll_count"] = \
		int(rs.runtime_effect_state.get("skill_scroll_count", 0)) + 1

	current_run = rs
	return rs


# ADDED -- the tutorial's own dedicated run setup. Doesn't go through
# start_new_run() (no random biome_sequence, no starting Skill Scroll grant,
# fixed 4-unit roster instead of a random one) since none of that applies to
# a fixed, scripted tutorial battle. See tutorial_manager.gd/
# game_mode_select.gd's _start_tutorial_run() for how the actual scene
# transition after this is handled.
func start_tutorial_run() -> RunState:
	var rs := RunState.new()
	rs.run_id = "tutorial_run"
	rs.player_seed = 0
	rs.difficulty = "easy"
	rs.is_tutorial = true
	rs.stage_index = 1
	rs.biome_sequence = ["forest"]
	rs.party = [
		{ "unit_id": "hexweaver",   "instance_id": "hexweaver_tutorial",   "level": 1, "equipped_item_ids": [null, null, null], "permanent_modifiers": [] },
		{ "unit_id": "icemage",     "instance_id": "icemage_tutorial",     "level": 1, "equipped_item_ids": [null, null, null], "permanent_modifiers": [] },
		{ "unit_id": "dreadknight", "instance_id": "dreadknight_tutorial", "level": 1, "equipped_item_ids": [null, null, null], "permanent_modifiers": [] },
		{ "unit_id": "executioner", "instance_id": "executioner_tutorial", "level": 1, "equipped_item_ids": [null, null, null], "permanent_modifiers": [] },
	]
	rs.gold = 0
	rs.bench = []
	rs.tarot_cards = []
	rs.equipment_inventory = []
	current_run = rs
	TutorialManager.start_tutorial()
	return rs


func save_run(slot_name: String = "autosave") -> void:
	if current_run == null:
		return
	_ensure_save_dir()
	var file := FileAccess.open(SAVE_DIR + slot_name + ".json", FileAccess.WRITE)
	if file == null:
		push_warning("GameState: could not write save file for slot '" + slot_name + "'")
		return
	file.store_string(JSON.stringify(current_run.to_dict(), "\t"))


func load_run(slot_name: String = "autosave") -> bool:
	var path := SAVE_DIR + slot_name + ".json"
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("GameState: save file '" + slot_name + "' is corrupted.")
		return false
	current_run = RunState.from_dict(json.data)
	return true


func save_meta_state() -> void:
	if meta == null:
		return
	var file := FileAccess.open(META_SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(meta.to_dict(), "\t"))


func _load_meta_state() -> MetaState:
	if not FileAccess.file_exists(META_SAVE_PATH):
		return MetaState.new()
	var file := FileAccess.open(META_SAVE_PATH, FileAccess.READ)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("GameState: meta_state.json is corrupted -- starting fresh.")
		return MetaState.new()
	return MetaState.from_dict(json.data)


func _ensure_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)


# ==============================================================================
# ADDED -- everything below is new, extending the original file above with
# the API your real project's scripts already depend on.
# ==============================================================================

# ── GOLD ────────────────────────────────────────────────────────────────────

func add_gold(amount: int) -> void:
	if current_run == null:
		return
	current_run.gold = max(0, current_run.gold + amount)
	EventBus.publish(EventBus.ON_GOLD_CHANGED, {"amount": amount, "new_total": current_run.gold})


func spend_gold(amount: int) -> bool:
	if current_run == null or current_run.gold < amount:
		return false
	current_run.gold -= amount
	EventBus.publish(EventBus.ON_GOLD_CHANGED, {"amount": -amount, "new_total": current_run.gold})
	return true


# ── STAGE / DIFFICULTY ────────────────────────────────────────────────────────

func get_current_stage_type() -> String:
	if current_run == null:
		return "combat"
	return ContentLoader.get_stage_type(current_run.stage_index)


# ADDED -- these three were being called from deployment_manager.gd's Scout
# Ahead feature (get_upcoming_stage_index/get_stage_type_for_index) and its
# button label (get_scout_cost), but were never actually defined anywhere.
# All three are thin wrappers around functionality that already exists
# elsewhere (ContentLoader.get_stage_type(), current_run.stage_index).

func get_upcoming_stage_index() -> int:
	# BUGFIX: this returned stage_index + 1, but by the time DeploymentScene
	# (and its Scout Ahead button) is showing, StageDirector.complete_stage()
	# has ALREADY called advance_stage() for the stage that just ended --
	# current_run.stage_index is already the next stage that "Continue" /
	# enter_current_stage() will route to (it reads RunManager.
	# get_current_stage_type(), which uses current_run.stage_index directly,
	# with no +1). The extra "+ 1" here meant Scout Ahead was checking the
	# type of, and generating a preview for, the stage AFTER the one you were
	# actually about to play -- so an upcoming encounter with a combat stage
	# sitting right after it would show as scoutable (wrongly), and an
	# upcoming combat stage followed by an encounter would show as
	# unscoutable (also wrongly). See also deployment_manager.gd's
	# _update_scout_button().
	if current_run == null:
		return 0
	return current_run.stage_index


func get_stage_type_for_index(stage_index: int) -> String:
	return ContentLoader.get_stage_type(stage_index)


const SCOUT_COST := 1   # gold cost to scout ahead -- tune freely

func get_scout_cost() -> int:
	return SCOUT_COST


func get_difficulty() -> String:
	if current_run == null:
		return "easy"
	return current_run.difficulty


func advance_stage() -> void:
	# NOTE: StageDirector.complete_stage() is the normal entry point for
	# ending a stage (it applies reward_rules THEN calls this) -- call this
	# directly only if you specifically want to move the stage counter
	# without running reward rules (the test-mode sandbox might want that).
	if current_run == null:
		return
	current_run.stage_index += 1
	if current_run.stage_index > 30:
		EventBus.publish(EventBus.ON_STAGE_COMPLETE, {"run_complete": true})
		current_run = null
		return

	# ADDED — recurring Skill Scroll grant, on top of the single starting
	# scroll start_new_run() already grants: one more every 3rd stage
	# (stage 3, 6, 9, ...).
	if current_run.stage_index % 3 == 0:
		current_run.runtime_effect_state["skill_scroll_count"] = \
			int(current_run.runtime_effect_state.get("skill_scroll_count", 0)) + 1

	save_run()


# ── GAME MODE / NEW RUN ────────────────────────────────────────────────────────

func start_new_run_for_mode(mode_id: String, chosen_party: Array = []) -> RunState:
	# Reads content/game_modes/<mode_id>.json for starting_gold/party_size/
	# starting_equipment_ids, applies them to a fresh RunState, and (for
	# Draft mode, where the player already picked their party on a Draft
	# screen) accepts that party directly via chosen_party.
	var rs := start_new_run(current_run.difficulty if current_run != null else "easy")
	var mode_config := ContentLoader.get_game_mode_config(mode_id)
	rs.draft_or_random_mode = mode_id
	rs.gold = int(mode_config.get("starting_gold", 10))
	for equipment_id in mode_config.get("starting_equipment_ids", []):
		rs.equipment_inventory.append(equipment_id)

	# NOTE: the Skill Scroll starting grant lives in start_new_run() above
	# (called on the line right above this comment block, to build 'rs' in
	# the first place) -- NOT here. It used to also be duplicated here,
	# which meant anything going through this function actually started
	# with 2 scrolls instead of 1, since start_new_run()'s grant ran first
	# and this block ran a second time right after. Removed the duplicate.

	if not chosen_party.is_empty():
		rs.party = chosen_party
	else:
		# Random mode: pick starting_party_size (from mode config, default 4)
		# random units, excluding excluded_unit_ids, from res://resources/units/.
		var excluded: Array = mode_config.get("excluded_unit_ids", [])
		var party_size: int = int(mode_config.get("party_size", 4))
		rs.party = _pick_random_starting_party(party_size, excluded)

	save_run()
	return rs


func _pick_random_starting_party(party_size: int, excluded_ids: Array) -> Array:
	var candidates: Array[String] = []
	var dir := DirAccess.open("res://resources/units/")
	if dir != null:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with("_data.tres"):
				var unit_id := file_name.trim_suffix("_data.tres")
				if not excluded_ids.has(unit_id):
					candidates.append(unit_id)
			file_name = dir.get_next()
		dir.list_dir_end()

	candidates.shuffle()
	var party_ids: Array[String] = []
	for i in range(min(party_size, candidates.size())):
		party_ids.append(candidates[i])

	# ── GUARANTEE AT LEAST 1 TANK + 1 PRIMARY DAMAGE (ADDED) ────────────────
	# See UnitData.unit_roles (Session 1's Role Tags checkboxes). A unit
	# tagged BOTH Tank and Primary Damage satisfies both guarantees on its
	# own -- this doesn't force two SEPARATE units if one hybrid already
	# covers both. If no candidate anywhere carries a needed role (e.g.
	# nothing's been tagged yet), this just warns and leaves the roll as a
	# plain random party rather than failing run start entirely.
	#
	# BUGFIX: passing an array literal directly as a function argument where
	# an Array[int] is expected (e.g. "_fn([UnitData.ROLE_TANK, ...])") can
	# throw a type-mismatch error in GDScript's static checker -- a plain
	# "[a, b]" literal is an untyped Array until it's actually ASSIGNED to a
	# typed variable, and Godot doesn't always coerce it automatically when
	# it's inline in a call. Building it as its own explicitly-typed
	# variable first sidesteps that entirely.
	var required_roles: Array[int] = [UnitData.ROLE_TANK, UnitData.ROLE_PRIMARY_DAMAGE]
	party_ids = _guarantee_party_roles(party_ids, candidates, required_roles)

	var result: Array = []
	for i in range(party_ids.size()):
		result.append({
			"unit_id": party_ids[i],
			"instance_id": party_ids[i] + "_" + str(Time.get_ticks_msec()) + "_" + str(i),
			"level": 1,
			"equipped_item_ids": [null, null, null],
			"permanent_modifiers": [],
		})
	return result


func _load_unit_data_cached(unit_id: String) -> UnitData:
	if _unit_data_load_cache.has(unit_id):
		return _unit_data_load_cache[unit_id]
	var path := "res://resources/units/" + unit_id + "_data.tres"
	var data: UnitData = (load(path) as UnitData) if ResourceLoader.exists(path) else null
	_unit_data_load_cache[unit_id] = data
	return data


func _guarantee_party_roles(party_ids: Array[String], all_candidates: Array[String],
		required_roles: Array[int]) -> Array[String]:
	var protected_indices: Array[int] = []

	for role_flag in required_roles:
		# Does someone already in the party cover this role?
		var holder_index := -1
		for i in range(party_ids.size()):
			var data := _load_unit_data_cached(party_ids[i])
			if data != null and data.has_role(role_flag):
				holder_index = i
				break
		if holder_index != -1:
			if not holder_index in protected_indices:
				protected_indices.append(holder_index)
			continue

		# Nobody currently in the party covers it -- find someone (not
		# already in the party) who does.
		var pool: Array[String] = []
		for id in all_candidates:
			if id in party_ids:
				continue
			var data := _load_unit_data_cached(id)
			if data != null and data.has_role(role_flag):
				pool.append(id)

		if pool.is_empty():
			push_warning("RunManager: no available unit tagged for role " + str(role_flag) +
				" -- Random mode's role guarantee couldn't be met this run.")
			continue

		pool.shuffle()

		# Replace the first slot that ISN'T already protecting a role we've
		# already guaranteed this pass (so fixing role #2 can't undo role #1).
		var replace_index := -1
		for i in range(party_ids.size()):
			if not i in protected_indices:
				replace_index = i
				break
		if replace_index == -1:
			push_warning("RunManager: every party slot is already protecting a guaranteed role -- " +
				"can't also fit role " + str(role_flag) + " (is party_size too small?).")
			continue

		party_ids[replace_index] = pool[0]
		protected_indices.append(replace_index)

	return party_ids


# ── SAVE SLOT LISTING ──────────────────────────────────────────────────────────

func list_save_files() -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			result.append(file_name.trim_suffix(".json"))
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


func delete_save(slot_name: String) -> void:
	var path := SAVE_DIR + slot_name + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
