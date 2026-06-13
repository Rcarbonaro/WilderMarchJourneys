# res://scripts/managers/run_manager.gd

# This is an AUTOLOAD singleton. Add it in Project > Project Settings > Autoload

# Name it "RunManager". Every scene can access it as RunManager.current_run

# 📤 EXPORTS TO: Every major scene — BattleScene, ShopScene, EncounterScene all read this

extends Node

var current_run: RunData = null

# Stage type lookup — what happens at each stage

const STAGE_TYPES = {

	1: "combat", 2: "combat", 3: "encounter",

	4: "combat", 5: "subboss",

	6: "encounter", 7: "combat",

	8: "special_combat", 9: "encounter", 10: "boss"

}

func start_new_run(difficulty: int = 1) -> void:

	current_run = RunData.new()

	current_run.difficulty = difficulty

	current_run.gold = 10

	current_run.current_stage = 1

	# Give starting party (4 random units)

	# 📥 CALLS FROM: UnitPool which holds all available units

	_assign_starting_party()

func get_current_stage_type() -> String:

	return STAGE_TYPES.get(current_run.current_stage, "combat")

func advance_stage() -> void:

	current_run.current_stage += 1

	if current_run.current_stage > 10:

		# Run is complete!

		_run_complete()

func add_gold(amount: int) -> void:

	current_run.gold += amount

func spend_gold(amount: int) -> bool:

	if current_run.gold >= amount:

		current_run.gold -= amount

		return true

	return false

func _assign_starting_party() -> void:

	# For now, just flag — you'll fill this when you have unit resources made

	pass

func _run_complete() -> void:

	# Go to victory scene

	get_tree().change_scene_to_file("res://scenes/meta/VictoryScreen.tscn")
	



# 🌲 Placeholder variable to track the active biome state of the run
# Change this manually in code to "desert" or "dungeon" to test your different backgrounds!
var current_biome: String = "grassland"

## Optional: An array of biomes if you want to test fully random progression later
const AVAILABLE_BIOMES = ["grassland", "desert", "dungeon"]

func _ready() -> void:
	print("🚀 RunManager initialized. Current biome placeholder set to: ", current_biome)


## 📤 PUBLIC API: This is what BattleScene calls to know which background to load
func get_current_biome_type() -> String:
	# Returns the tracked biome, lowercase to guarantee dictionary matchmaking matches perfectly
	return current_biome.strip_edges().to_lower()


func advance_to_next_stage_placeholder() -> void:
	# Randomly chooses one of your biomes for testing purposes
	var random_index = randi() % AVAILABLE_BIOMES.size()
	current_biome = AVAILABLE_BIOMES[random_index]
	
	print("🔄 Advanced stage! RunManager placeholder biome shifted to: ", current_biome)
