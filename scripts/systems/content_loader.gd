# res://scripts/systems/content_loader.gd
#
# AUTOLOAD. Reads JSON files from disk into plain Dictionaries/Arrays, and
# loads whole folders of .tres resources at once (enemy pools, equipment
# pools, tarot pools, etc). Every other system in this package calls into
# this one for file access — no one else touches FileAccess/DirAccess directly.

extends Node

var _cache: Dictionary = {}


func load_json(path: String, use_cache: bool = true) -> Variant:
	if use_cache and _cache.has(path):
		return _cache[path]

	if not FileAccess.file_exists(path):
		printerr("❌ ContentLoader: file not found: ", path)
		return null

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("❌ ContentLoader: could not open file: ", path)
		return null

	var text: String = file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(text)
	if parsed == null:
		printerr("❌ ContentLoader: failed to parse JSON (check for a syntax ",
				 "error like a missing comma or bracket) in: ", path)
		return null

	if use_cache:
		_cache[path] = parsed

	return parsed


func clear_cache() -> void:
	# Call this if you edit a JSON file and want the game to re-read it
	# without restarting (handy while tuning numbers during testing).
	_cache.clear()


func load_all_resources_in_folder(folder_path: String, expected_class: String = "") -> Array:
	var results: Array = []
	var dir = DirAccess.open(folder_path)
	if dir == null:
		printerr("❌ ContentLoader: folder not found: ", folder_path)
		return results

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var full_path = folder_path.path_join(file_name)
			var res = load(full_path)
			if res == null:
				printerr("❌ ContentLoader: failed to load resource: ", full_path)
			elif expected_class != "" and res.get_script() != null and res.get_script().get_global_name() != expected_class:
				printerr("⚠️ ContentLoader: expected ", expected_class,
						 " but found ", res.get_script().get_global_name(),
						 " at: ", full_path)
			else:
				results.append(res)
		file_name = dir.get_next()

	return results


func find_equipment_by_id(item_id: String):
	# Searches basic, advanced, and consumable folders for a matching id.
	for folder in ["res://content/equipment/basic/", "res://content/equipment/advanced/", "res://content/equipment/consumables/"]:
		for item in load_all_resources_in_folder(folder):
			if "id" in item and item.id == item_id:
				return item
	return null


func find_unit_by_id(unit_id: String):
	# res://resources/units/<id>_data.tres — matches your existing convention.
	var path = "res://resources/units/%s_data.tres" % unit_id
	if ResourceLoader.exists(path):
		return load(path)
	return null
