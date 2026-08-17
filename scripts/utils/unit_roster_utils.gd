# res://scripts/utils/unit_roster_utils.gd
#
# UNIT ROSTER UTILS -- a tiny, stateless helper shared by Random mode and
# Draft Mode for answering one question: "which units are available to pick
# right now?"
#
# HOW THE ROSTER IS BUILT: every *.tres file inside res://resources/units/
# is automatically offered, except any unit id passed in via excluded_ids.
# This means adding a brand new playable unit is just "drop its .tres file
# in that folder" -- neither this script nor anything that calls it needs
# to change.
#
# This is a plain utility class (extends RefCounted, no autoload needed) --
# class_name makes UnitRosterUtils available everywhere in the project
# automatically, the moment this file exists anywhere under res://.

class_name UnitRosterUtils
extends RefCounted

const UNITS_DIR := "res://resources/units/"

static func get_available_units(excluded_ids: Array = []) -> Array[UnitData]:
	var result: Array[UnitData] = []
	var dir := DirAccess.open(UNITS_DIR)
	if dir == null:
		printerr("❌ UnitRosterUtils: folder not found: ", UNITS_DIR)
		return result

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		# In an EXPORTED build with "Convert Text Resources to Binary"
		# enabled, .tres files are physically renamed to "<name>.tres.remap"
		# in the packed PCK -- ResourceLoader.load() still resolves the
		# ORIGINAL "res://...tres" path fine, but a raw folder scan only
		# ever sees the ".remap" filename on disk. Match both extensions,
		# and strip ".remap" back off before load()'ing. In the editor (or
		# an export with that conversion setting off), file_name is already
		# a plain ".tres" and stripping a suffix it doesn't have is a no-op.
		if not dir.current_is_dir() and (file_name.ends_with(".tres") or file_name.ends_with(".tres.remap")):
			var clean_name := file_name.trim_suffix(".remap")
			var unit_data := load(UNITS_DIR + clean_name) as UnitData
			if unit_data != null and not excluded_ids.has(unit_data.id):
				result.append(unit_data)
			elif unit_data == null:
				printerr("⚠️ UnitRosterUtils: ", clean_name, " did not load as a UnitData resource -- skipped.")
		file_name = dir.get_next()
	dir.list_dir_end()
	return result
	
