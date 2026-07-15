extends Node

const SETTINGS_PATH := "user://settings.cfg"

var music_volume: float = 50.0   # CHANGED — now 0-100 scale, matching the slider directly
var sfx_volume: float   = 50.0   # CHANGED

func _ready() -> void:
	_load_settings()
	_apply_music_volume()
	_apply_sfx_volume()


func set_music_volume(value: float) -> void:
	music_volume = clamp(value, 0.0, 100.0)   # CHANGED — was 0.0-1.0
	_apply_music_volume()
	_save_settings()


func set_sfx_volume(value: float) -> void:
	sfx_volume = clamp(value, 0.0, 100.0)   # CHANGED
	_apply_sfx_volume()
	_save_settings()


func _apply_music_volume() -> void:
	var idx := AudioServer.get_bus_index("Music")
	if idx == -1:
		push_warning("SettingsManager: no 'Music' audio bus found — volume slider will have no effect until one is created in the Audio panel.")
		return
	AudioServer.set_bus_volume_db(idx, _linear_to_db_safe(music_volume / 100.0))   # CHANGED — divide by 100 to get 0.0-1.0 for the dB conversion


func _apply_sfx_volume() -> void:
	var idx := AudioServer.get_bus_index("SFX")
	if idx == -1:
		push_warning("SettingsManager: no 'SFX' audio bus found — volume slider will have no effect until one is created in the Audio panel.")
		return
	AudioServer.set_bus_volume_db(idx, _linear_to_db_safe(sfx_volume / 100.0))   # CHANGED


func _linear_to_db_safe(value: float) -> float:
	if value <= 0.0001:
		return -80.0
	return linear_to_db(value)


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	config.save(SETTINGS_PATH)


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	music_volume = float(config.get_value("audio", "music_volume", 50.0))   # CHANGED default
	sfx_volume   = float(config.get_value("audio", "sfx_volume", 50.0))     # CHANGED default
