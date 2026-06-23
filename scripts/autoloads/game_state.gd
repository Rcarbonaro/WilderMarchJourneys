# res://scripts/autoloads/game_state.gd
#
# GAME STATE -- the single autoload that holds "what's currently loaded":
# the active RunState (or null if no run is in progress) and the MetaState
# (always loaded). Also owns save/load to disk.

extends Node

var current_run: RunState = null
var meta: MetaState = null

const SAVE_DIR := "user://saves/"
const META_SAVE_PATH := "user://meta_state.json"


func _ready() -> void:
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
