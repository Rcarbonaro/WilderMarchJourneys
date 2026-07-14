# res://scripts/data/reinforcement_wave_data.gd
#
# A ReinforcementWaveData describes ONE summon event — a group of enemies
# that get dropped into an ongoing battle. This is intentionally decoupled
# from WHO calls for it: a boss phase transition, a "ritual" hazard tile,
# a timed EventBus trigger, or a future "call for backup" enemy ability can
# all hand one of these to ReinforcementSpawner and get identical behavior.
class_name ReinforcementWaveData
extends Resource

@export var id: String = ""

@export var entries: Array[WaveEntryData] = []
# Every enemy type + count in this wave. All entries spawn together.

@export_enum("near_summoner", "designated_cells", "map_edge") var spawn_strategy: String = "near_summoner"
# "near_summoner"    — spawns land on empty cells as close as possible to
#                       the summoning unit (e.g. the boss calling its pack).
# "designated_cells" — spawns land on the exact cells in designated_cells
#                       below, in order, skipping any that are occupied.
# "map_edge"          — spawns land on empty cells along the enemy-side map
#                       edge, same pool battle_manager.gd's real spawn path
#                       already uses (MapGenerator.last_result.enemy_spawns).

@export var designated_cells: Array[Vector2i] = []
# Only used when spawn_strategy == "designated_cells".

@export var search_radius: int = 4
# Only used when spawn_strategy == "near_summoner". How far out from the
# summoner ReinforcementSpawner is willing to look for an empty cell before
# giving up on that particular unit (it's skipped, with a warning, if no
# empty cell is found in range).

@export var announcement_text: String = ""
# Optional. If non-empty, shown as a brief banner ("The forest answers its
# call...") when this wave spawns. Leave blank for a silent summon.
