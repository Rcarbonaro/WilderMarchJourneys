# res://scripts/managers/popup_manager.gd
extends Node

var current_popup: UnitInfoPopup = null

func open_popup(new_popup: UnitInfoPopup) -> void:
	# If a popup is already open, close/remove it first
	if is_instance_valid(current_popup):
		current_popup.queue_free()
	
	current_popup = new_popup
