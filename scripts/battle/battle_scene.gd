# res://scripts/battle/battle_scene.gd
# 📥 CALLS FROM: RunManager — reads current run's party and stage info
# 📤 EXPORTS TO: RunManager — when battle ends, reports win/loss and advances stage

extends Node2D

@onready var battle_manager = $BattleManager
@onready var battle_ui = $BattleUI
@onready var background_texture: TextureRect = $BattleBackgrounds/BackgroundTexture

func _enter_tree() -> void:
	# Runs BEFORE _ready() -- and, importantly, before BattleManager's own
	# _ready() too, since Godot calls _enter_tree() top-down (parent first)
	# but _ready() bottom-up (children first). BattleManager's
	# _spawn_player_party_from_run()/_spawn_stage_enemies() both read
	# MapGenerator.last_result, so the map has to exist before either of
	# those run. Test mode (RunManager.is_test_mode) never calls this at
	# all -- your _spawn_test_enemies() sandbox keeps using its own fixed
	# Vector2i positions exactly as before.
	if RunManager.is_test_mode:
		return
	if RunManager.current_run == null:
		printerr("❌ BattleScene: RunManager.current_run is null and is_test_mode is false -- ",
				 "nothing to generate a map for.")
		return

	var biome := _get_current_biome()
	var party_size: int = RunManager.current_run.party.size()
	MapGenerator.generate_map($BattleGrid.GRID_WIDTH, $BattleGrid.GRID_HEIGHT, biome, party_size, 8)
	$BattleGrid.setup_grid(MapGenerator.last_result.get("tile_map", {}))
	$BattleGrid.spawn_scatter_features(MapGenerator.last_result.get("feature_placements", []))


func _get_current_biome() -> String:
	if RunManager.current_run == null or RunManager.current_run.biome_sequence.is_empty():
		return "forest"
	var slot := ContentLoader.get_biome_slot(RunManager.current_run.stage_index)
	if slot >= RunManager.current_run.biome_sequence.size():
		return "forest"
	return RunManager.current_run.biome_sequence[slot]


func _ready() -> void:
	# 1. Connect UI to BattleManager
	battle_ui.battle_manager = battle_manager

	# CanvasLayers ignore normal node tree draw order and are stacked by
	# their own "layer" property instead -- BattleBackgrounds defaulted to
	# layer 1, same tier as BattleUI, which put it ABOVE the default canvas
	# (layer 0) that BattleGrid/UnitLayer render on, hiding every unit
	# sprite behind an opaque background. Force it below the default canvas.
	$BattleBackgrounds.layer = -1

	# 2: set up biome
	setup_battle_background(_get_current_biome() if not RunManager.is_test_mode else "forest")
	
	# 3: Connect BattleManager back to the UI Manager
	battle_manager.ui_manager = battle_ui

	# 3. Connect battle end signal
	battle_manager.battle_ended.connect(_on_battle_ended)

	# 4. Map is generated in _enter_tree() above for real runs. Test mode
	# still needs SOME grid to exist, since it skips _enter_tree()'s
	# generation entirely -- fall back to the old flat test map for that case.
	if RunManager.is_test_mode:
		_setup_test_map()
	
	# 5. Setup camera for screen shake
	CombatFeedback.register_camera($Camera2D)
	

func _setup_test_map() -> void:
	# Creates a flat grid of dirt tiles. ONLY used in test mode now -- real
	# runs get their map from MapGenerator in _enter_tree() above.
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
	if RunManager.is_test_mode:
		# Test mode never had a real run in progress -- there's nothing for
		# StageDirector to advance or reward. Just report the result.
		print("Test battle ended: ", result)
		return
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
