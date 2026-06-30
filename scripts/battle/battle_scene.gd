# res://scripts/battle/battle_scene.gd
# 📥 CALLS FROM: RunManager — reads current run's party and stage info
# 📤 EXPORTS TO: RunManager — when battle ends, reports win/loss and advances stage

extends Node2D

@onready var battle_manager = $BattleManager
@onready var battle_ui = $BattleUI
@onready var background_texture: TextureRect = $BattleBackgrounds/BackgroundTexture

func _ready() -> void:
	# 1. Connect UI to BattleManager
	battle_ui.battle_manager = battle_manager
	
	# 2: set up biome
	setup_battle_background("grassland")

	# 3: Connect BattleManager back to the UI Manager
	battle_manager.ui_manager = battle_ui

	# 3. Connect battle end signal
	battle_manager.battle_ended.connect(_on_battle_ended)

	# 4. Setup the test map
	_setup_test_map()

func _setup_test_map() -> void:
	# Creates a flat grid of dirt tiles.
	#
	# BUGFIX: this used to loop `range(10)` for y, generating a 10-row map —
	# but battle_grid.gd's GRID_HEIGHT constant is 9, and is_valid_cell()
	# rejects any row >= GRID_HEIGHT. That meant row 9 (the 10th, bottom-most
	# row) was drawn and given grid-line outlines like any other tile, but
	# units could never move to it, target it, or be spawned on it — a
	# visible "dead" row at the bottom of the map. Looping to $BattleGrid's
	# own GRID_HEIGHT instead keeps the drawn map and the usable map in sync
	# by construction, so this can't drift out of sync again if GRID_HEIGHT
	# ever changes.
	# 📥 CALLS FROM: tile_dirt resource you made in Phase 1
	var dirt_tile = preload("res://resources/tiles/tile_dirt.tres")
	var map_data = {}
	for x in range(25):
		for y in range($BattleGrid.GRID_HEIGHT):
			map_data[Vector2i(x, y)] = dirt_tile
	$BattleGrid.setup_grid(map_data)

func _on_battle_ended(result: String) -> void:
	if result == "victory":
		RunManager.add_gold(5)  # reward gold for winning
		RunManager.advance_stage()
		get_tree().change_scene_to_file("res://scenes/meta/ShopScene.tscn")
	elif result == "defeat":
		get_tree().change_scene_to_file("res://scenes/meta/GameOverScreen.tscn")



# 🗺️ The Biome Resource Database
const BIOME_BACKGROUNDS = {
#USING FOREST FLOOR AS PLACEHOLDER
	"grassland": [
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
	# 1. Fallback safety check: If biome doesn't exist, default to grassland
	if not BIOME_BACKGROUNDS.has(biome_type):
		print("⚠️ Unknown biome type requested: '", biome_type, "'. Defaulting to grassland.")
		biome_type = "grassland"
		
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
