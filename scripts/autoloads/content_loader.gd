# res://scripts/autoloads/content_loader.gd
#
# CONTENT LOADER -- reads every JSON content file ONCE at startup and keeps
# it in memory as plain Dictionaries, so the rest of the game never has to
# touch the filesystem again.
#
# WHY PRELOAD EVERYTHING INSTEAD OF LOADING ON DEMAND?
#   We're talking about hundreds of small JSON files, not megabytes of data.
#   Loading everything up front means:
#     1. We can validate ALL content the moment the game starts (catching a
#        typo in a content file immediately, instead of only when a player
#        happens to hit that one broken card 10 hours into a run).
#     2. Every other system can just ask ContentLoader for an id and get an
#        instant answer -- no async loading, no "is it ready yet?" bugs.
#
# WHAT HAPPENS IF A FILE IS BROKEN?
#   Per project decision: we WARN and SKIP the broken file rather than
#   crashing the whole game. The bad id simply won't exist, and anything
#   that references it will also warn-and-skip when it tries to use it.
#   Flip STRICT_MODE to true below to instead hard-crash with a clear error
#   -- useful as a "content lint" pass before you ship a build.

extends Node

const STRICT_MODE: bool = false

# ---- CONTENT FOLDERS ---------------------------------------------------------
# Add a new folder constant here the moment you invent a new content type.
const TAROT_DIR              := "res://content/tarot/"
const ENCOUNTER_DIR          := "res://content/encounters/"
const DIALOGUE_DIR           := "res://content/dialogue/"
const EQUIPMENT_BASIC_DIR    := "res://content/equipment/basic/"
const CONSUMABLE_DIR         := "res://content/equipment/consumable/"
const EQUIPMENT_ADVANCED_DIR := "res://content/equipment/advanced/"
const FORGING_RECIPES_FILE   := "res://content/equipment/forging_recipes.json"
const SHOP_DIR                := "res://content/shop/"
const SCALING_DIR             := "res://content/scaling/"
const SPAWN_TABLE_DIR         := "res://content/spawn_tables/"
const STAGE_TYPE_MAP_FILE     := "res://content/scaling/stage_type_map.json"
const GAME_MODES_DIR          := "res://content/game_modes/"
const GLOBAL_DIFFICULTY_FILE := "res://content/scaling/global_difficulty.json"
# One file per mode -- e.g. random.json, draft.json. Holds starting_gold,
# starting_equipment_ids, party_size, excluded_unit_ids, and (draft only)
# draft_budget, so every "how does Random differ from Draft" number lives
# in content, not scattered across game_mode_select.gd / draft_scene.gd.

const REWARD_RULES_DIR := "res://content/reward_rules/"
# ADDED: one file per rule, e.g. { "id": "combat_gold_reward", "conditions":
# [...], "effects": [{"type":"add_gold","amount":5}] }. stage_director.gd's
# complete_stage() checks EVERY rule against the stage that just finished --
# there's no "first match wins", so more than one rule can fire on the same
# stage (e.g. a flat gold reward AND a tarot-driven bonus rule both firing
# on the same combat stage).

const BIOME_POOL_PATH := "res://content/biome_pool.json"
# ADDED: single file, not a folder -- { "biomes": ["forest", "swamp", ...] }.
# GameState.start_new_run() shuffles a copy of this list and takes 3 for
# RunState.biome_sequence. Add more biome names here as you build them out;
# nothing else needs to change.

# ---- IN-MEMORY CONTENT TABLES ------------------------------------------------
# Every one of these is Dictionary[String id] -> Dictionary (the parsed JSON).
var tarot_cards: Dictionary = {}
var encounters: Dictionary = {}
var dialogue_graphs: Dictionary = {}
var equipment: Dictionary = {}          # basic AND advanced share one table
var shop_entries: Dictionary = {}
var scaling_configs: Dictionary = {}    # keyed by their own "id", looked up by stage_index
var spawn_tables: Dictionary = {}
var forging_recipes: Dictionary = {}    # keyed by "subtypeA_subtypeB" (sorted)
var stage_type_map: Dictionary = {}     # keyed by String(stage 1-10)
var game_modes: Dictionary = {}         # keyed by mode id ("random", "draft")
var reward_rules: Dictionary = {}       # keyed by "id", read directly by stage_director.gd
var biome_pool: Array = []              # flat Array[String], loaded from BIOME_POOL_PATH
var global_difficulty: Dictionary = {}  

# Every problem found while loading ends up here, so you can see a single
# report instead of hunting through console output line by line.
var load_warnings: Array[String] = []


func _ready() -> void:
	_load_all_content()
	if load_warnings.size() > 0:
		printerr("ContentLoader finished with ", load_warnings.size(), " warning(s):")
		for w in load_warnings:
			printerr("   - ", w)
	else:
		print("ContentLoader: all content loaded cleanly.")


func _load_all_content() -> void:
	tarot_cards     = _load_folder(TAROT_DIR, ["id", "name"])
	encounters      = _load_folder(ENCOUNTER_DIR, ["id", "title", "dialogue_graph_id"])
	dialogue_graphs = _load_folder(DIALOGUE_DIR, ["id", "nodes", "start_node"])
	shop_entries    = _load_folder(SHOP_DIR, ["id", "item_type", "item_id", "base_price"])
	spawn_tables    = _load_folder(SPAWN_TABLE_DIR, ["id", "enemy_pool"])
	global_difficulty = _load_single_file(GLOBAL_DIFFICULTY_FILE, []) 

	var basic_equipment    = _load_folder(EQUIPMENT_BASIC_DIR, ["id", "name", "type"])
	var advanced_equipment = _load_folder(EQUIPMENT_ADVANCED_DIR, ["id", "name", "type"])
	var consumable_equipment = _load_folder(CONSUMABLE_DIR, ["id", "name", "type"])   # ADDED
	equipment = basic_equipment.duplicate()
	for key in advanced_equipment:
		equipment[key] = advanced_equipment[key]
	for key in consumable_equipment:   # ADDED
		equipment[key] = consumable_equipment[key]

	scaling_configs = _load_folder(SCALING_DIR, ["id", "stage_index"])
	# stage_type_map.json lives in the SAME folder but is one lookup table,
	# not "one file per item" -- it gets loaded separately and shouldn't be
	# mistaken for a scaling config, so we make sure it isn't in the dict.
	scaling_configs.erase("stage_type_map")
	stage_type_map = _load_single_file(STAGE_TYPE_MAP_FILE, [])

	forging_recipes = _load_forging_recipes()
	game_modes = _load_folder(GAME_MODES_DIR, ["id", "starting_gold", "party_size"])
	reward_rules = _load_folder(REWARD_RULES_DIR, ["id", "effects"])

	var biome_pool_data: Dictionary = _load_single_file(BIOME_POOL_PATH, [])   # ADDED
	biome_pool = biome_pool_data.get("biomes", [])


func _load_folder(path: String, required_fields: Array) -> Dictionary:
	# Reads every *.json file directly inside 'path', parses it, checks that
	# every field in 'required_fields' is present, and stores it keyed by its
	# own "id" field. Returns Dictionary[id] -> Dictionary.
	var result: Dictionary = {}
	var dir := DirAccess.open(path)
	if dir == null:
		_warn("Content folder not found: " + path)
		return result

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var full_path := path + file_name
			var parsed = _parse_json_file(full_path)
			if parsed != null:
				var missing := _find_missing_fields(parsed, required_fields)
				if missing.size() > 0:
					_warn(full_path + " is missing required field(s) " + str(missing) + " -- skipped.")
				elif not (parsed is Dictionary) or not parsed.has("id"):
					_warn(full_path + " has no 'id' field -- skipped.")
				elif result.has(parsed["id"]):
					_warn(full_path + " reuses id '" + str(parsed["id"]) + "' -- skipped.")
				else:
					result[parsed["id"]] = parsed
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


func _load_single_file(path: String, required_fields: Array) -> Dictionary:
	# Like _load_folder, but for ONE file holding a single Dictionary lookup
	# table (not "one file per content item"). Used for stage_type_map.json.
	if not FileAccess.file_exists(path):
		_warn("Expected single content file not found: " + path)
		return {}
	var parsed = _parse_json_file(path)
	if parsed == null:
		return {}
	var missing := _find_missing_fields(parsed, required_fields)
	if missing.size() > 0:
		_warn(path + " is missing required field(s) " + str(missing) + " -- ignored.")
		return {}
	return parsed


func _load_forging_recipes() -> Dictionary:
	# forging_recipes.json holds an ARRAY of recipe Dictionaries (recipes
	# don't have a meaningful single "id" the way other content does -- they
	# are keyed by their two ingredient subtypes instead).
	var result: Dictionary = {}
	if not FileAccess.file_exists(FORGING_RECIPES_FILE):
		_warn("forging_recipes.json not found at " + FORGING_RECIPES_FILE)
		return result

	var parsed = _parse_json_file(FORGING_RECIPES_FILE)
	if parsed == null or not (parsed is Array):
		_warn(FORGING_RECIPES_FILE + " did not contain a JSON array -- ignored.")
		return result

	for recipe in parsed:
		if not (recipe is Dictionary) or not recipe.has("inputs") or not recipe.has("output_equipment_id"):
			_warn("A forging recipe entry is missing 'inputs' or 'output_equipment_id' -- skipped.")
			continue
		var inputs: Array = recipe["inputs"]
		if inputs.size() != 2:
			_warn("Forging recipe with inputs " + str(inputs) + " must have exactly 2 ingredients -- skipped.")
			continue
		result[make_combo_key(inputs[0], inputs[1])] = recipe

	return result


func make_combo_key(subtype_a: String, subtype_b: String) -> String:
	# Builds a stable lookup key for two equipment subtypes, regardless of
	# the order they were combined in. "blade"+"armor" and "armor"+"blade"
	# both produce "armor_blade", because we always sort alphabetically first.
	var pair := [subtype_a, subtype_b]
	pair.sort()
	return pair[0] + "_" + pair[1]


func _parse_json_file(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_warn("Could not open file: " + path)
		return null
	var text := file.get_as_text()
	var json := JSON.new()
	var error := json.parse(text)
	if error != OK:
		_warn(path + " -- JSON parse error: " + json.get_error_message() +
			  " (line " + str(json.get_error_line()) + ")")
		return null
	return json.data


func _find_missing_fields(data, required_fields: Array) -> Array:
	var missing := []
	if not (data is Dictionary):
		return required_fields  # the whole file is the wrong shape entirely
	for field in required_fields:
		if not data.has(field):
			missing.append(field)
	return missing


func _warn(message: String) -> void:
	load_warnings.append(message)
	if STRICT_MODE:
		assert(false, "ContentLoader STRICT_MODE failure: " + message)

# ---- PUBLIC GETTERS ----------------------------------------------------------
# Every other system should go through these rather than touching the
# Dictionaries above directly -- that way, if we ever change HOW content is
# stored internally, nothing outside this file needs to change.

func get_tarot(id: String) -> Dictionary:
	return tarot_cards.get(id, {})

func get_encounter(id: String) -> Dictionary:
	return encounters.get(id, {})

func get_dialogue_graph(id: String) -> Dictionary:
	return dialogue_graphs.get(id, {})

func get_equipment(id: String) -> Dictionary:
	return equipment.get(id, {})

func get_shop_entry(id: String) -> Dictionary:
	return shop_entries.get(id, {})

func get_scaling_config(stage_index: int) -> Dictionary:
	# Scaling configs are looked up by ABSOLUTE stage number (1-30), per
	# project decision -- not by position within a biome.
	for key in scaling_configs:
		var cfg = scaling_configs[key]
		if int(cfg.get("stage_index", -1)) == stage_index:
			return cfg
	return {}

func get_spawn_table(id: String) -> Dictionary:
	return spawn_tables.get(id, {})

func find_spawn_tables_for(biome: String, stage_type: String, stage_index: int) -> Array:
	# Returns every spawn table whose biome/stage_type/range matches. There
	# can be more than one (several "combat" tables for forest stages 1-10);
	# ScalingEngine picks one at random.
	var stage_within_biome := get_stage_within_biome(stage_index)
	var matches := []
	for id in spawn_tables:
		var table = spawn_tables[id]
		if table.get("biome", "") != biome:
			continue
		if table.get("stage_type", "") != stage_type:
			continue
		var min_s = int(table.get("stage_min", 1))
		var max_s = int(table.get("stage_max", 999))
		if stage_within_biome >= min_s and stage_within_biome <= max_s:   
			matches.append(table)
	return matches

func get_forging_recipe(subtype_a: String, subtype_b: String) -> Dictionary:
	return forging_recipes.get(make_combo_key(subtype_a, subtype_b), {})

func get_game_mode_config(mode_id: String) -> Dictionary:
	return game_modes.get(mode_id, {})

func get_stage_within_biome(stage_index: int) -> int:   
	return ((stage_index - 1) % 10) + 1

func get_stage_type(stage_index: int) -> String:
	# Stage TYPE (combat/encounter/subboss/special_combat/boss) repeats every
	# 10 stages, because every biome reuses the same 1-10 pattern. We convert
	# the absolute stage_index (1-30) down to its position-within-biome
	# (1-10) and look THAT up in stage_type_map.json.
	var stage_within_biome := ((stage_index - 1) % 10) + 1
	return stage_type_map.get(str(stage_within_biome), "combat")

func get_biome_slot(stage_index: int) -> int:
	# Returns 0, 1, or 2 -- which of the run's 3 chosen biomes this stage
	# belongs to. Stages 1-10 = biome_sequence[0], 11-20 = [1], 21-30 = [2].
	return int(floor(float(stage_index - 1) / 10.0))

func get_difficulty_summary(difficulty: String) -> Dictionary:
	return {
		"stat_multiplier": float(global_difficulty.get("difficulty_stat_multiplier", {}).get(difficulty, 1.0)),
		"spawn_bonus":     global_difficulty.get("difficulty_spawn_bonus", {}).get(difficulty, {}),
	}
