# res://scripts/systems/stage_director.gd
#
# AUTOLOAD. Make sure ContentLoader, RunManager, MapGenerator, EnemySelector,
# ScalingEngine are ABOVE it.
#
# Decides "what does the upcoming stage actually contain" (map + enemies),
# and CACHES the result the first time it's computed — so Scout Ahead can
# preview the EXACT upcoming fight, and the real battle later reuses that
# same result instead of rolling a different one.

extends Node

const BOSS_REGISTRY_FOLDER = "res://content/bosses/"

var _cached_content: Dictionary = {}


func get_or_generate_stage_content(stage_index: int) -> Dictionary:
	if _cached_content.has(stage_index):
		return _cached_content[stage_index]

	var stage_type = RunManager.get_stage_type_for_index(stage_index)
	var biome = RunManager.get_biome_for_stage_index(stage_index)

	var content: Dictionary
	if stage_type == "boss":
		content = _generate_boss_content(biome, stage_index)
	else:
		content = _generate_normal_content(stage_index, biome)

	content["stage_type"] = stage_type
	content["biome"] = biome
	_cached_content[stage_index] = content
	return content


func clear_old_cache(keep_stage_index: int) -> void:
	for key in _cached_content.keys():
		if key != keep_stage_index:
			_cached_content.erase(key)


func _generate_normal_content(stage_index: int, biome: String) -> Dictionary:
	var biome_path = "res://content/biomes/%s_map_config.tres" % biome
	var biome_config: BiomeMapConfig
	if ResourceLoader.exists(biome_path):
		biome_config = load(biome_path)
	else:
		printerr("⚠️ StageDirector: no BiomeMapConfig at ", biome_path, " — using an empty placeholder.")
		biome_config = BiomeMapConfig.new()

	var map_result = MapGenerator.generate_map(biome_config)
	var enemies = EnemySelector.get_enemies_for_stage(stage_index, RunManager.get_difficulty())

	return {
		"tile_map": map_result["tile_map"], "ally_cells": map_result["ally_cells"],
		"enemy_cells": map_result["enemy_cells"], "enemies": enemies, "is_boss": false,
	}


func _generate_boss_content(biome: String, stage_index: int) -> Dictionary:
	var registry_path = BOSS_REGISTRY_FOLDER + biome + "_boss.json"
	var registry = ContentLoader.load_json(registry_path)
	if registry == null:
		printerr("❌ StageDirector: no boss registry for biome '", biome, "' — falling back to normal content.")
		return _generate_normal_content(stage_index, biome)

	var map_path: String = registry.get("map_config_path", "")
	var biome_config: BiomeMapConfig
	if map_path != "" and ResourceLoader.exists(map_path):
		biome_config = load(map_path)
	else:
		printerr("⚠️ StageDirector: boss map_config_path missing/invalid for '", biome, "' — using an empty arena.")
		biome_config = BiomeMapConfig.new()

	var map_result = MapGenerator.generate_map(biome_config, 4, registry.get("enemy_count_hint", 6))
	var enemies = EnemySelector.get_fixed_group(registry.get("enemy_group_id", ""), EnemySelector.BOSS_ENEMY_GROUP_FOLDER)

	return {
		"tile_map": map_result["tile_map"], "ally_cells": map_result["ally_cells"],
		"enemy_cells": map_result["enemy_cells"], "enemies": enemies, "is_boss": true,
	}
