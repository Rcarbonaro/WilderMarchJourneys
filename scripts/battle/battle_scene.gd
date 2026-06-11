# res://scripts/battle/battle_scene.gd
# 📥 CALLS FROM: RunManager — reads current run's party and stage info
# 📤 EXPORTS TO: RunManager — when battle ends, reports win/loss and advances stage

extends Node2D

@onready var battle_manager = $BattleManager
@onready var battle_ui = $BattleUI

func _ready() -> void:
	# 1. Connect UI to BattleManager
	battle_ui.battle_manager = battle_manager

	# 🛑 THE ADDITION: Connect BattleManager back to the UI Manager
	battle_manager.ui_manager = battle_ui

	# 2. Connect battle end signal
	battle_manager.battle_ended.connect(_on_battle_ended)

	# 3. Setup the test map
	_setup_test_map()

func _setup_test_map() -> void:
	# Creates a flat 10x10 grid of dirt tiles
	# 📥 CALLS FROM: tile_dirt resource you made in Phase 1
	var dirt_tile = preload("res://resources/tiles/tile_dirt.tres")
	var map_data = {}
	for x in range(10):
		for y in range(10):
			map_data[Vector2i(x, y)] = dirt_tile
	$BattleGrid.setup_grid(map_data)

func _on_battle_ended(victory: bool) -> void:
	if victory:
		RunManager.add_gold(5)  # reward gold for winning
		RunManager.advance_stage()
		get_tree().change_scene_to_file("res://scenes/meta/ShopScene.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/meta/GameOverScreen.tscn")
