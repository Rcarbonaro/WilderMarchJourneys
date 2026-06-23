# res://scripts/managers/run_manager.gd
#
# RUN MANAGER -- the autoload that holds "what run is currently active" and
# the small helpers the rest of the game calls constantly (add_gold,
# spend_gold, advance_stage, current stage type/biome).
#
# THIS FILE REPLACES YOUR EXISTING run_manager.gd IN PLACE -- same autoload
# name, same path, so nothing needs to change in Project Settings > Autoload.
# It also absorbs what was a separate "GameState" autoload earlier in this
# project: having two different places holding "the current run" would have
# meant two sources of truth that could silently drift out of sync, so
# everything lives here now.
#
# WHAT CHANGED FROM YOUR ORIGINAL run_manager.gd:
#   - current_run is now a RunState (not RunData). RunState additionally
#     tracks tarot cards, flags, equipment inventory, shop modifiers, and
#     per-unit equipped_item_ids/permanent_modifiers -- see run_state.gd.
#   - current_stage is renamed stage_index and now genuinely runs 1-30
#     across all 3 biomes (per project decision: absolute stage numbering),
#     instead of secretly ending the run at stage 11.
#   - get_current_stage_type() now reads content/scaling/stage_type_map.json
#     via ContentLoader instead of a hardcoded Dictionary -- editing that
#     JSON file is enough to change the pattern, no code changes needed.
#   - current_biome / advance_to_next_stage_placeholder() (the old "pick one
#     random biome for testing" stub) are replaced by biome_sequence on
#     RunState, chosen once when the run starts, plus get_current_biome().
#
# COMPATIBILITY NOTE FOR main_menu.gd: its _on_new_game_pressed() currently
# builds a run by hand with `RunManager.current_run = RunData.new()` and
# assigns `.party` / `.unit_levels` directly -- RunState doesn't have a
# `unit_levels` field (level lives per-party-entry instead), so that
# function needs a small update. See the corrected version in this
# project's README.md under "Known follow-ups."
#
# AUTOLOAD ORDER: register this AFTER ContentLoader (get_current_stage_type
# and get_current_biome both call into it) and after EventBus (add_gold/
# spend_gold publish ON_GOLD_CHANGED). It does NOT need to come before
# anything else -- none of this project's other autoloads call into
# RunManager from their own _ready(), so exact position beyond "after those
# two" doesn't matter for correctness.

extends Node

var current_run: RunState = null
var meta: MetaState = null

const SAVE_DIR := "user://saves/"
const META_SAVE_PATH := "user://meta_state.json"

# The biomes a run can draw from. Add more here as you build them out --
# nothing else in the project needs to change.
const AVAILABLE_BIOMES: Array[String] = ["forest", "swamp", "plains"]


func _ready() -> void:
	meta = _load_meta_state()
	print("RunManager initialized.")

# ---- STARTING / ENDING A RUN --------------------------------------------------

func start_new_run(difficulty: String = "normal") -> RunState:
	var rs := RunState.new()
	rs.run_id = "run_" + Time.get_datetime_string_from_system().replace(":", "-")
	rs.player_seed = randi()
	rs.difficulty = difficulty
	rs.biome_sequence = _pick_random_biomes()
	current_run = rs
	return rs


func _pick_random_biomes() -> Array[String]:
	# Picks 3 distinct biomes for this run, in order. Right now there's only
	# one real biome (forest) -- this will start producing meaningful
	# variety the moment you add a second and third.
	var pool := AVAILABLE_BIOMES.duplicate()
	pool.shuffle()
	var picked: Array[String] = []
	for b in pool:
		picked.append(b)
		if picked.size() == 3:
			break
	return picked


func advance_stage() -> void:
	if current_run == null:
		return
	current_run.stage_index += 1
	if current_run.stage_index > 30:
		_run_complete()
	EventBus.publish(EventBus.ON_STAGE_COMPLETE, {
		"was_combat": RunManager.get_current_stage_type() in ["combat","subboss","special_combat","boss"],
		})



func _run_complete() -> void:
	# Snapshot a reusable Endless Abyss team BEFORE the run ends, so a
	# fully-built Nightmare-difficulty party isn't lost. (This is the
	# MetaState.save_endless_team() call the README flagged as "written but
	# nothing calls it yet" -- this is that call site.)
	if meta != null and current_run != null:
		meta.save_endless_team(current_run, current_run.run_id + "_team")
		save_meta_state()
	get_tree().change_scene_to_file("res://scenes/meta/VictoryScreen.tscn")

# ---- STAGE TYPE / BIOME LOOKUPS -----------------------------------------------

func get_current_stage_type() -> String:
	# Returns "combat" | "encounter" | "subboss" | "special_combat" | "boss"
	# for whatever stage the run is currently on.
	if current_run == null:
		return "combat"
	return ContentLoader.get_stage_type(current_run.stage_index)


func get_current_biome() -> String:
	if current_run == null or current_run.biome_sequence.is_empty():
		return ""
	return current_run.biome_sequence[ContentLoader.get_biome_slot(current_run.stage_index)]


func get_current_biome_type() -> String:
	# Kept as an alias of get_current_biome() in case other code still
	# calls the original method name.
	return get_current_biome()

# ---- GOLD --------------------------------------------------------------------

func add_gold(amount: int) -> void:
	if current_run == null:
		return
	current_run.gold += amount
	EventBus.publish(EventBus.ON_GOLD_CHANGED, {"amount": amount, "new_total": current_run.gold})


func spend_gold(amount: int) -> bool:
	if current_run == null or current_run.gold < amount:
		return false
	current_run.gold -= amount
	EventBus.publish(EventBus.ON_GOLD_CHANGED, {"amount": -amount, "new_total": current_run.gold})
	return true

# ---- SAVE / LOAD ---------------------------------------------------------------

func save_run(slot_name: String = "autosave") -> void:
	if current_run == null:
		return
	_ensure_save_dir()
	var file := FileAccess.open(SAVE_DIR + slot_name + ".json", FileAccess.WRITE)
	if file == null:
		push_warning("RunManager: could not write save file for slot '" + slot_name + "'")
		return
	file.store_string(JSON.stringify(current_run.to_dict(), "\t"))


func load_run(slot_name: String = "autosave") -> bool:
	var path := SAVE_DIR + slot_name + ".json"
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("RunManager: save file '" + slot_name + "' is corrupted.")
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
		push_warning("RunManager: meta_state.json is corrupted -- starting fresh.")
		return MetaState.new()
	return MetaState.from_dict(json.data)


func _ensure_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
