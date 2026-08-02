# res://scripts/data/survivor_encounter_data.gd
#
# SURVIVOR ENCOUNTER DATA -- one possible "flavor" of the post-combat
# survivor Mini-Encounter (see mini_encounter_scene.gd). Create .tres
# instances under res://resources/encounters/survivors/, one per distinct
# survivor group you want to be possible ("wounded_soldier.tres",
# "lost_child.tres", "old_hermit.tres", etc.) -- MiniEncounterScene picks
# one at random every time the encounter triggers, same "randomly select
# between multiple pictures" pattern as camp tents (see
# deployment_manager.gd's _refresh_camp_decorations()).
#
# Assign your created instances to MiniEncounterScene's own
# survivor_flavors array (an @export on mini_encounter_scene.gd) in the
# Godot editor. Leave portrait empty on any entry to just skip showing one
# for that flavor -- description still displays normally.

class_name SurvivorEncounterData
extends Resource

@export_multiline var description: String = ""
# The flavor text shown above the Recruit/Rob choice, e.g. "A wounded
# soldier, separated from their unit, watches you warily from behind a
# fallen log."

@export var portrait: Texture2D
# Optional. Shown next to/above the description "to visualize who you are
# talking to" -- leave empty for no portrait.
