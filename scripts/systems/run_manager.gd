# res://scripts/systems/run_manager.gd
#
# AUTOLOAD. REPLACES your existing res://scripts/managers/run_manager.gd —
# repoint the autoload entry at THIS file (same Node Name: "RunManager").
#
# BACKWARD COMPATIBLE: every method/property your existing scripts already
# call (current_run, add_gold, spend_gold, advance_stage, current_biome,
# get_current_biome_type) still exists here with the same name/behavior.
# Everything else is additive.

extends Node

# ── CURRENT RUN STATE ──────────────────────────────────────────────────────────

var current_run: RunData = null

# ── DIFFICULTY ─────────────────────────────────────────────────────────────────

@export_enum("normal", "hard", "nightmare") var difficulty: String = "normal"

func get_difficulty() -> String:
	return difficulty

func set_difficulty(new_difficulty: String) -> void:
	difficulty = new_difficulty


# ── STAGE TRACKING (now driven by run_config.json — see that file's README) ───

func get_stage_index() -> int:
	if current_run == null:
		return 1
	return current_run.current_stage


var _run_config: Dictionary = {}
const RUN_CONFIG_PATH = "res://content/run_config.json"

func _reload_run_config() -> void:
	var loaded = ContentLoader.load_json(RUN_CONFIG_PATH, false)
	if loaded == null:
		printerr("❌ RunManager: could not load run_config.json — using fallback defaults.")
		_run_config = {
			"stages_per_biome": 10, "biome_order": ["forest", "swamp", "desert"], "scout_cost": 1,
			"stage_type_template": {
				"1": "combat", "2": "combat", "3": "encounter", "4": "combat", "5": "subboss",
				"6": "encounter", "7": "combat", "8": "special_combat", "9": "encounter", "10": "boss"
			}
		}
	else:
		_run_config = loaded

func get_stages_per_biome() -> int:
	return _run_config.get("stages_per_biome", 10)

func get_biome_order() -> Array:
	return _run_config.get("biome_order", ["forest", "swamp", "desert"])

func get_total_stage_count() -> int:
	return get_stages_per_biome() * get_biome_order().size()

func get_biome_index_for_stage(stage_index: int) -> int:
	return int((stage_index - 1) / float(get_stages_per_biome()))

func get_stage_position_in_biome(stage_index: int) -> int:
	return ((stage_index - 1) % get_stages_per_biome()) + 1

func get_stage_type_for_index(stage_index: int) -> String:
	var position = get_stage_position_in_biome(stage_index)
	var template: Dictionary = _run_config.get("stage_type_template", {})
	return template.get(str(position), "combat")

func get_current_stage_type() -> String:
	if current_run == null:
		return "combat"
	return get_stage_type_for_index(current_run.current_stage)

func get_biome_for_stage_index(stage_index: int) -> String:
	var biome_order = get_biome_order()
	var idx = clamp(get_biome_index_for_stage(stage_index), 0, biome_order.size() - 1)
	return biome_order[idx]

func get_upcoming_stage_index() -> int:
	# The stage the player is ABOUT to enter — differs from
	# current_run.current_stage while sitting in Deployment after finishing
	# content but before pressing Continue. Scout Ahead previews THIS index.
	if current_run == null:
		return 1
	if stage_content_completed_for_current_stage:
		return current_run.current_stage + 1
	return current_run.current_stage

func get_scout_cost() -> int:
	return _run_config.get("scout_cost", 1)


# ── BIOME ───────────────────────────────────────────────────────────────────────

var current_biome: String = "forest"
const AVAILABLE_BIOMES = ["forest", "desert", "dungeon"]  # legacy fallback only

func get_current_biome_type() -> String:
	# Derives the biome automatically from how far into the run the player
	# is (see get_biome_for_stage_index() and run_config.json's biome_order).
	if current_run == null:
		return current_biome.strip_edges().to_lower()
	return get_biome_for_stage_index(current_run.current_stage)

func advance_to_next_stage_placeholder() -> void:
	# Kept for backward compatibility — no longer used by the new stage flow.
	var random_index = randi() % AVAILABLE_BIOMES.size()
	current_biome = AVAILABLE_BIOMES[random_index]
	print("🔄 Advanced stage! RunManager placeholder biome shifted to: ", current_biome)


# ── GOLD ────────────────────────────────────────────────────────────────────────

func add_gold(amount: int) -> void:
	current_run.gold += amount

func spend_gold(amount: int) -> bool:
	if current_run.gold >= amount:
		current_run.gold -= amount
		return true
	return false


# ── STAGE ADVANCEMENT ───────────────────────────────────────────────────────────

func advance_stage() -> void:
	current_run.current_stage += 1
	current_shop_slots.clear()          # Force a fresh shop roll for the new stage.
	session_unit_stat_bonuses.clear()   # "session"-scoped stat effects expire at stage change.
	temp_drop_rate_modifiers.clear()    # Same for session-scoped drop-rate effects.
	# Clears cached stage content for stages we've moved past, but PRESERVES
	# the entry for the stage we just entered (in case Scout Ahead already
	# generated it while the player was still in Deployment).
	StageDirector.clear_old_cache(current_run.current_stage)
	if current_run.current_stage > get_total_stage_count():
		_run_complete()
		return
	save_run()


func _run_complete() -> void:
	save_run()
	get_tree().change_scene_to_file("res://scenes/meta/VictoryScreen.tscn")


# ── NEW RUN CREATION ────────────────────────────────────────────────────────────

func start_new_run(chosen_difficulty: String = "normal") -> void:
	current_run = RunData.new()
	current_run.difficulty = chosen_difficulty
	current_run.gold = 10
	current_run.current_stage = 1
	difficulty = chosen_difficulty
	run_flags.clear()
	tarot_cards.clear()
	current_shop_slots.clear()
	stage_content_completed_for_current_stage = false
	save_run()


# ── RUN FLAGS ───────────────────────────────────────────────────────────────────

var run_flags: Array[String] = []

func set_flag(flag_id: String) -> void:
	if not flag_id in run_flags:
		run_flags.append(flag_id)

func has_flag(flag_id: String) -> bool:
	return flag_id in run_flags

func unset_flag(flag_id: String) -> void:
	run_flags.erase(flag_id)


# ── TAROT CARDS (storage only here — TarotSystem handles the actual effects) ──

var tarot_cards: Array = []

func add_tarot_card(tarot_id: String) -> void:
	for entry in tarot_cards:
		if entry["tarot_id"] == tarot_id:
			entry["stacks"] += 1
			return
	tarot_cards.append({"tarot_id": tarot_id, "stacks": 1})

func has_tarot(tarot_id: String) -> bool:
	for entry in tarot_cards:
		if entry["tarot_id"] == tarot_id:
			return true
	return false


# ── SHOP SLOT PERSISTENCE ──────────────────────────────────────────────────────

var current_shop_slots: Array = []
# Each entry is either null (slot was purchased/empty) or a Dictionary
# {"category": "unit"/"equipment"/"consumable", "id": String}.


# ── PERMANENT / SESSION / TEMPORARY PER-UNIT STAT BONUSES ─────────────────────

var session_unit_stat_bonuses: Dictionary = {}
# unit_data.id -> {stat_name: amount}. Cleared in advance_stage(). NOT saved
# to disk — short-lived by design.

var temporary_unit_stat_bonuses: Dictionary = {}
# unit_data.id -> {stat_name: {"amount":.., "duration":..}}. Applied ONCE, as
# a normal in-battle status, the next time that unit spawns — then cleared.
# Not saved to disk.

var temp_drop_rate_modifiers: Dictionary = {}
# resource_key -> multiplier, from "modify_drop_rate" effects. Cleared on
# advance_stage(). Recognized keys: "equipment", "consumable", "unit",
# "unit_tag:<Tag>", or any exact item id string.


func apply_run_modifiers_to_unit(unit) -> void:
	# Called once by unit_node.setup() for every PLAYER unit spawned. Applies
	# permanent, session, and pending temporary stat bonuses as
	# StatusEffectData, same pattern used everywhere else in this codebase.
	if not unit.is_player_unit:
		return
	if unit.unit_data == null or not ("id" in unit.unit_data):
		return
	var unit_id: String = unit.unit_data.id

	var perm: Dictionary = current_run.permanent_unit_stat_bonuses.get(unit_id, {})
	if not perm.is_empty():
		unit.apply_status(_build_stat_status("run_permanent_" + unit_id, perm, true, 9999))

	var sess: Dictionary = session_unit_stat_bonuses.get(unit_id, {})
	if not sess.is_empty():
		unit.apply_status(_build_stat_status("run_session_" + unit_id, sess, true, 9999))

	var temp: Dictionary = temporary_unit_stat_bonuses.get(unit_id, {})
	if not temp.is_empty():
		for stat_name in temp:
			var entry: Dictionary = temp[stat_name]
			var single_stat := {stat_name: entry.get("amount", 0)}
			var status = _build_stat_status(
				"run_temp_" + unit_id + "_" + stat_name + "_" + str(Time.get_ticks_msec()),
				single_stat, false, entry.get("duration", 1)
			)
			unit.apply_status(status)
		temporary_unit_stat_bonuses.erase(unit_id)


func _build_stat_status(status_id: String, stats: Dictionary, is_permanent: bool, duration: int) -> StatusEffectData:
	var status = StatusEffectData.new()
	status.id              = status_id
	status.is_permanent    = is_permanent
	status.duration_rounds  = duration
	status.atk_modifier         = stats.get("atk", 0)
	status.matk_modifier        = stats.get("matk", 0)
	status.def_modifier         = stats.get("def", 0)
	status.mdef_modifier        = stats.get("mdef", 0)
	status.mov_modifier         = stats.get("mov", 0)
	status.crit_chance_modifier = stats.get("crit_chance", 0.0)
	status.crit_damage_modifier = stats.get("crit_damage", 0.0)
	return status


func get_drop_rate_modifier(item) -> float:
	var mult: float = 1.0
	for key in temp_drop_rate_modifiers:
		var applies: bool = false
		if key == "equipment" and item is BasicEquipmentData:
			applies = true
		elif key == "consumable" and item is ConsumableData:
			applies = true
		elif key == "unit" and item is UnitData:
			applies = true
		elif key.begins_with("unit_tag:") and "synergy_tags" in item and key.trim_prefix("unit_tag:") in item.synergy_tags:
			applies = true
		elif "id" in item and key == item.id:
			applies = true
		if applies:
			mult *= temp_drop_rate_modifiers[key]
	return mult


# ── DEPLOYMENT / STAGE-CONTENT ROUTING ────────────────────────────────────────

var stage_content_completed_for_current_stage: bool = false
# false = Deployment's "Continue" should load the CURRENT stage's content
# (fresh run, never fought anything yet). true = "Continue" should advance
# to the NEXT stage first. Set true by battle_scene.gd/encounter_scene.gd/
# encounter_engine.gd right before routing back to Deployment.

const STAGE_TYPE_SCENES = {
	"combat":          "res://scenes/battle/BattleScene.tscn",
	"subboss":         "res://scenes/battle/BattleScene.tscn",
	"special_combat":  "res://scenes/battle/BattleScene.tscn",
	"boss":            "res://scenes/battle/BattleScene.tscn",
	"encounter":       "res://scenes/encounter/EncounterScene.tscn",
}

func get_scene_path_for_current_stage() -> String:
	return STAGE_TYPE_SCENES.get(get_current_stage_type(), "res://scenes/battle/BattleScene.tscn")

func mark_stage_content_completed() -> void:
	stage_content_completed_for_current_stage = true

func get_equipped_slots(unit_id: String) -> Array:
	# Returns this unit's 3 equipment slots as a fixed-size Array (padded
	# with null). Creates the entry if this unit never had one before.
	if not current_run.equipped_items.has(unit_id):
		current_run.equipped_items[unit_id] = [null, null, null]
	var slots: Array = current_run.equipped_items[unit_id]
	while slots.size() < 3:
		slots.append(null)
	return slots


# ── SAVE / LOAD ──────────────────────────────────────────────────────────────────

const SAVE_DIR = "user://saves/"

func _ready() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	_reload_run_config()


func save_run() -> void:
	if current_run == null:
		return

	if current_run.run_id == "":
		current_run.run_id = "run_%d" % Time.get_unix_time_from_system()

	var save_dict := {
		"run_id": current_run.run_id,
		"difficulty": difficulty,
		"stage_index": current_run.current_stage,
		"biome": current_biome,
		"gold": current_run.gold,
		"tarot_cards": tarot_cards,
		"flags": run_flags,
		"party_ids": [],
		"unit_levels": current_run.unit_levels,
		"equipped_items": {},
		"inventory_ids": [],
		"shop_slots": current_shop_slots,
	}

	for unit_data in current_run.party:
		if unit_data != null and "id" in unit_data:
			save_dict["party_ids"].append(unit_data.id)

	# equipped_items: unit_data.id -> Array[EquipmentData] becomes
	# unit_data.id -> Array[String id], reconstructed on load via id lookup.
	for unit_id in current_run.equipped_items:
		var id_list: Array = []
		for item in current_run.equipped_items[unit_id]:
			if item != null and "id" in item:
				id_list.append(item.id)
		save_dict["equipped_items"][unit_id] = id_list

	for item in current_run.inventory:
		if item != null and "id" in item:
			save_dict["inventory_ids"].append(item.id)

	var path = SAVE_DIR + current_run.run_id + ".json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("❌ RunManager: failed to open save file for writing: ", path)
		return
	file.store_string(JSON.stringify(save_dict, "\t"))
	file.close()
	print("💾 Run saved to: ", path)


func list_save_files() -> Array[String]:
	var result: Array[String] = []
	var dir = DirAccess.open(SAVE_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			result.append(file_name.trim_suffix(".json"))
		file_name = dir.get_next()
	return result


func load_run(run_id: String) -> bool:
	var path = SAVE_DIR + run_id + ".json"
	if not FileAccess.file_exists(path):
		printerr("❌ RunManager: no save file found for run_id: ", run_id)
		return false

	var file = FileAccess.open(path, FileAccess.READ)
	var text = file.get_as_text()
	file.close()

	var data = JSON.parse_string(text)
	if data == null:
		printerr("❌ RunManager: save file is corrupted: ", path)
		return false

	current_run = RunData.new()
	current_run.run_id        = data.get("run_id", run_id)
	current_run.current_stage = data.get("stage_index", 1)
	current_run.gold          = data.get("gold", 10)
	current_run.unit_levels   = data.get("unit_levels", {})

	current_run.equipped_items = {}
	var saved_equipped: Dictionary = data.get("equipped_items", {})
	for unit_id in saved_equipped:
		var rebuilt: Array = []
		for item_id in saved_equipped[unit_id]:
			var found = _find_equipment_by_id(item_id)
			if found != null:
				rebuilt.append(found)
		current_run.equipped_items[unit_id] = rebuilt

	current_run.inventory = []
	for item_id in data.get("inventory_ids", []):
		var found = _find_equipment_by_id(item_id)
		if found != null:
			current_run.inventory.append(found)

	current_shop_slots = data.get("shop_slots", [])

	difficulty  = data.get("difficulty", "normal")
	current_biome = data.get("biome", "forest")
	tarot_cards = data.get("tarot_cards", [])
	run_flags   = data.get("flags", [])

	current_run.party = []
	for unit_id in data.get("party_ids", []):
		var unit_path = "res://resources/units/%s_data.tres" % unit_id
		if ResourceLoader.exists(unit_path):
			current_run.party.append(load(unit_path))
		else:
			printerr("⚠️ RunManager: could not find unit data for id '", unit_id, "' at ", unit_path)

	print("📂 Run loaded from: ", path)
	return true


func delete_save(run_id: String) -> void:
	var path = SAVE_DIR + run_id + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _find_equipment_by_id(item_id: String):
	var found = ContentLoader.find_equipment_by_id(item_id)
	if found == null:
		printerr("⚠️ RunManager: could not find equipment with id '", item_id, "' while loading save.")
	return found
