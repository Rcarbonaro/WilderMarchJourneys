# res://scripts/meta/game_over_screen.gd
#
# GameOverScreen -- shown when battle_scene.gd's battle_ended handler sees
# result == "defeat" (see the call to
# get_tree().change_scene_to_file("res://scenes/meta/GameOverScreen.tscn")
# already in your battle_scene.gd around line 2409-2410).
#
# This is a full scene change (not a popup layered on top of battle, the
# way show_game_victory_popup() works), which matches how your project
# already treats defeat -- it fully replaces the battle scene.
extends Control

@onready var _return_button: Button = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/ReturnButton


func _ready() -> void:
	_return_button.pressed.connect(_on_return_pressed)
	_return_button.grab_focus()

	# The run is over -- clear it so a stray current_run doesn't linger into
	# whatever the player does next (starting a new run, opening the main
	# menu, etc). This mirrors what run_manager.gd's advance_stage() already
	# does when a run finishes by reaching stage 30 (current_run = null).
	if RunManager:
		RunManager.current_run = null

	# If you later want to track losses in MetaState (e.g. a "runs lost"
	# stat for the Achievements screen), this is the place to add it --
	# something like:
	#   RunManager.meta.runs_lost += 1
	#   RunManager.save_meta_state()
	# left out here since MetaState doesn't currently define that field.


func _on_return_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/mainmenu/main_menu.tscn")
