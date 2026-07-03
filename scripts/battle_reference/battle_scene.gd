# res://scripts/battle/battle_scene.gd
# 📥 CALLS FROM: RunManager — reads current run's party and stage info
# 📤 EXPORTS TO: RunManager — when battle ends, reports win/loss and advances stage

extends Node2D

const MAP_WIDTH := 16
const MAP_HEIGHT := 9

@onready var battle_manager = $BattleManager
@onready var battle_ui = $BattleUI
@onready var background_texture: TextureRect = $BattleBackgrounds/BackgroundTexture

func _ready() -> void:
	# 1. Connect UI to BattleManager
	battle_ui.battle_manager = battle_manager

	# 2. Work out which biome this stage is actually in, and use that SAME
	# value for both the backdrop image below and the procedural map
	# generation further down -- previously these used two different,
	# incompatible naming schemes ("grassland" here vs "forest" everywhere
	# else in the project), which only became a real problem once map
	# generation started actually reading RunState.biome_sequence.
	var biome := _get_current_biome()
	setup_battle_background(biome)

	# 3: Connect BattleManager back to the UI Manager
	battle_manager.ui_manager = battle_ui

	# 3. Connect battle end signal
	battle_manager.battle_ended.connect(_on_battle_ended)

	# 4. Generate the map, THEN explicitly tell BattleManager to spawn --
	# in that order, on purpose. By the time this line runs, BattleManager's
	# own _ready() has ALREADY finished (children ready before parents in
	# Godot), so spawning can no longer happen automatically inside it --
	# see start_battle()'s comment in battle_manager.gd for why.
	_setup_generated_map(biome)


func _get_current_biome() -> String:
	if RunManager.current_run != null and RunManager.current_run.biome_sequence.size() > 0:
		return RunManager.current_run.biome_sequence[ContentLoader.get_biome_slot(RunManager.current_run.stage_index)]
	return "forest"


func _setup_generated_map(biome: String) -> void:
	var spawn_resolution: Dictionary = ScalingEngine.resolve_spawn_table(RunManager.current_run)
	var enemy_roster: Array = spawn_resolution.get("roster", [])
	var reinforcements: Array = spawn_resolution.get("reinforcements", [])
	var enemy_count := 0
	for entry in enemy_roster:
		enemy_count += entry.get("count", 1)
	enemy_count = max(enemy_count, 1)

	var party_size: int = 4
	if RunManager.current_run != null:
		party_size = max(RunManager.current_run.party.size(), 1)

	var result := MapGenerator.generate_map(MAP_WIDTH, MAP_HEIGHT, biome, party_size, enemy_count)
	$BattleGrid.setup_grid(result["tile_map"])
	$BattleGrid.spawn_scatter_features(result["feature_placements"])

	battle_manager.start_battle(result["player_spawns"], result["enemy_spawns"], enemy_roster, reinforcements)


func _on_battle_ended(result: String) -> void:
	EventBus.publish(EventBus.ON_STAGE_COMPLETE, {"was_combat": true})
	if result == "victory":
		StageDirector.complete_stage()
	elif result == "defeat":
		get_tree().change_scene_to_file("res://scenes/meta/GameOverScreen.tscn")



# 🗺️ The Biome Resource Database
const BIOME_BACKGROUNDS = {
#USING FOREST FLOOR AS PLACEHOLDER
	"forest": [
		"res://assets/backgrounds/forestfloor1.png",
		"res://assets/backgrounds/forestfloor1.png"
	],
	"desert": [
		"res://assets/backgrounds/forest)floor1.png",
		"res://assets/backgrounds/forest)floor1.png"
	],
	"dungeon": [
		"res://assets/backgrounds/forest)floor1.png"
	]
}

func setup_battle_background(biome_type: String) -> void:
	# 1. Fallback safety check: If biome doesn't exist, default to forest
	if not BIOME_BACKGROUNDS.has(biome_type):
		print("⚠️ Unknown biome type requested: '", biome_type, "'. Defaulting to forest.")
		biome_type = "forest"
		
	var available_images: Array = BIOME_BACKGROUNDS[biome_type]
	
	if available_images.is_empty():
		print("❌ No background image paths found for biome: ", biome_type)
		return
		
	# 2. Pick a random texture path from the selected biome array
	var random_index: int = randi() % available_images.size()
	var chosen_path: String = available_images[random_index]
	
	print("🏞️ Loading battle background art assets: ", chosen_path)
	
	# 3. Load the file from disk and assign it to our background node
	var texture_resource = load(chosen_path)
	if texture_resource:
		background_texture.texture = texture_resource
	else:
		print("❌ Failed to load background texture asset at: ", chosen_path)
