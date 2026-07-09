# res://scripts/autoloads/game_state.gd
#
# GAME STATE -- the single autoload that holds "what's currently loaded":
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
#
# ADDED BELOW (everything above this point is your original game_state.gd,
# untouched): add_gold, spend_gold, advance_stage, get_current_stage_type,
# get_difficulty, is_test_mode, test_encounter_index, list_save_files,
# delete_save, start_new_run_for_mode -- the full surface your combat
# scripts, stage_director.gd, and scaling_engine.gd already expect to exist.

extends Node

var current_run: RunState = null
var meta: MetaState = null

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


func start_new_run(difficulty: String = "normal") -> RunState:
    var rs := RunState.new()
    rs.run_id = "run_" + Time.get_datetime_string_from_system().replace(":", "-")
    rs.player_seed = randi()
    rs.difficulty = difficulty
    current_run = rs
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


func get_difficulty() -> String:
    if current_run == null:
        return "normal"
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
    save_run()


# ── GAME MODE / NEW RUN ────────────────────────────────────────────────────────

func start_new_run_for_mode(mode_id: String, chosen_party: Array = []) -> RunState:
    # Reads content/game_modes/<mode_id>.json for starting_gold/party_size/
    # starting_equipment_ids, applies them to a fresh RunState, and (for
    # Draft mode, where the player already picked their party on a Draft
    # screen) accepts that party directly via chosen_party.
    var rs := start_new_run(current_run.difficulty if current_run != null else "normal")
    var mode_config := ContentLoader.get_game_mode_config(mode_id)
    rs.draft_or_random_mode = mode_id
    rs.gold = int(mode_config.get("starting_gold", 10))
    for equipment_id in mode_config.get("starting_equipment_ids", []):
        rs.equipment_inventory.append(equipment_id)

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
    var result: Array = []
    for i in range(min(party_size, candidates.size())):
        result.append({
            "unit_id": candidates[i],
            "instance_id": candidates[i] + "_" + str(Time.get_ticks_msec()) + "_" + str(i),
            "level": 1,
            "equipped_item_ids": [null, null, null],
            "permanent_modifiers": [],
        })
    return result


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
