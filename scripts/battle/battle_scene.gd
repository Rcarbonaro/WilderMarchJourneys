# res://scripts/battle/battle_scene.gd
# 📥 CALLS FROM: RunManager — reads current run's party and stage info
# 📤 EXPORTS TO: RunManager — when battle ends, reports win/loss and advances stage

extends Node2D

@onready var battle_manager = $BattleManager
@onready var battle_ui = $BattleUI
@onready var background_texture: TextureRect = $BattleBackgrounds/BackgroundTexture

func _enter_tree() -> void:
	if RunManager.is_test_mode:
		return
	if RunManager.current_run == null:
		printerr("❌ BattleScene: RunManager.current_run is null and is_test_mode is false -- ",
				 "nothing to generate a map for.")
		return

	var biome := _get_current_biome()
	var party_size: int = RunManager.current_run.party.size()

	# ADDED — keep the number of generated enemy spawn cells in sync with
	# resolve_spawn_table()'s own bonus_enemy_count, so a scaling-boosted
	# roster always has enough physical cells to land on instead of losing
	# enemies to the "more enemies than spawn cells" warning.
	StageDirector.get_or_generate_stage_content(RunManager.current_run.stage_index)
	$BattleGrid.setup_grid(MapGenerator.last_result.get("tile_map", {}))
	$BattleGrid.spawn_scatter_features(MapGenerator.last_result.get("feature_placements", []))

func _get_current_biome() -> String:
	if RunManager.current_run == null or RunManager.current_run.biome_sequence.is_empty():
		return "forest"
	var slot := ContentLoader.get_biome_slot(RunManager.current_run.stage_index)
	if slot >= RunManager.current_run.biome_sequence.size():
		return "forest"
	return RunManager.current_run.biome_sequence[slot]
const BIOME_MUSIC := {
	"forest": [
		preload("res://assets/audio/music/forest_ambient_1.ogg"),
		preload("res://assets/audio/music/forest_ambient_2.ogg"),
		preload("res://assets/audio/music/forest_ambient_3.ogg"),
	],
}

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
	var biome: String = _get_current_biome() if not RunManager.is_test_mode else "forest"
	setup_battle_background(biome)

	# ── MUSIC ──────────────────────────────────────────────────────────────
	# Decide which track to play FIRST, then make exactly one AudioManager
	# call. Calling the biome playlist AND a boss override back-to-back in
	# the same frame used to create two competing tweens fighting over the
	# same AudioStreamPlayer -- this way there's only ever one.
	var boss_override_played := false
	if not RunManager.is_test_mode and RunManager.current_run != null:
		var stage_index: int = RunManager.current_run.stage_index
		if ContentLoader.get_stage_type(stage_index) == "boss":
			var scaling_config := ContentLoader.get_scaling_config(stage_index)
			if scaling_config.has("music_playlist") and scaling_config["music_playlist"] is Array \
					and not scaling_config["music_playlist"].is_empty():
				var loaded: Array = []
				for path in scaling_config["music_playlist"]:
					loaded.append(load(path))
				AudioManager.play_music_playlist(loaded, true)
				boss_override_played = true
			elif scaling_config.has("music_track") and scaling_config["music_track"] != "":
				AudioManager.play_music(load(scaling_config["music_track"]))
				boss_override_played = true

	if not boss_override_played and BIOME_MUSIC.has(biome):
		AudioManager.play_next_in_playlist(BIOME_MUSIC[biome])
		
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
		print("Test battle ended: ", result)
		return
	if result == "victory":
		# TEMPORARY — until biomes 2 and 3 have their own stage-10 bosses
		# built, clearing stage 10 counts as clearing the whole game.
		# Remove this early-return once biome 2/3 content exists, so
		# StageDirector.complete_stage() can carry the run past stage 10
		# normally.
		if RunManager.current_run != null and RunManager.current_run.stage_index == 10:
			if battle_ui and battle_ui.has_method("show_game_victory_popup"):
				battle_ui.show_game_victory_popup()
			return
		StageDirector.complete_stage()
	elif result == "defeat":
		get_tree().change_scene_to_file("res://scenes/meta/GameOverScreen.tscn")


# 🗺️ The Biome Resource Database
const BIOME_BACKGROUNDS = {
#USING FOREST FLOOR AS PLACEHOLDER
	"forest": [
		"res://assets/backgrounds/forestfloor1.png",
		"res://assets/backgrounds/forestfloor1.png"
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
