# res://scripts/ui/ui_manager.gd
# ==============================================================================
# THE USER INTERFACE MANAGER (UI Layout Controller)
# ==============================================================================
# This script is the bridge between the hidden data loops of the BattleManager
# and the buttons the player actually sees on their phone screen. 
# It handles drawing, graying out, and clearing player actions dynamically.
# ==============================================================================

extends CanvasLayer

# An '@export' variable shows up as an editable slot in your Inspector panel on the right.
# We drag and drop the primary BattleManager node here so this script can send 
# player button-click decisions back to the combat engine.
@export var battle_manager: Node  # Drag BattleManager here in the Inspector

# '@onready' variables wait to load until the game starts and all layout boxes exist.
# The '$' symbol tells Godot to look inside your UI scene tree to find a node by name.
@onready var ability_bar = $VBoxContainer/AbilityBar        # The HBoxContainer where spell buttons go
@onready var end_turn_button = $VBoxContainer/EndTurnButton # The static manual skip button


# _ready() runs automatically the exact moment this UI pops onto the player's screen.
func _ready() -> void:
	# '.connect' tells Godot: "When the player clicks this button, immediately jump down
	# and execute the _on_end_turn_pressed() function written at the bottom of this script."
	end_turn_button.pressed.connect(_on_end_turn_pressed)


# This function runs automatically whenever you select a friendly hero on the grid map.
# It reads their data card card and builds a custom shortcut row of action choices from scratch.
# res://scripts/battle/ui_manager.gd

# res://scripts/battle/ui_manager.gd

func show_unit_abilities(unit) -> void:
	# 🛑 FIX: Force the containers holding the buttons to let clicks pass through!
	$VBoxContainer.mouse_filter = Control.MOUSE_FILTER_PASS
	$VBoxContainer/AbilityBar.mouse_filter = Control.MOUSE_FILTER_PASS

	# Clear out old buttons first
	for child in $VBoxContainer/AbilityBar.get_children():
		child.queue_free()
		
	# Loop through the unit's starting abilities
	for ability in unit.unit_data.starting_abilities:
		var btn = Button.new()
		btn.text = ability.display_name
		
		# 🟢 Explicitly ensure the button is set to STOP so it catches the click
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		
		# 🔗 Connect the button click directly back to the BattleManager!
		btn.pressed.connect(func(): 
			if battle_manager != null:
				print("🎯 UI Button Clicked for ability: ", ability.display_name)
				battle_manager.on_ability_selected(ability)
		)
		
		$VBoxContainer/AbilityBar.add_child(btn)

# Triggered when the human player manually taps the big "End Turn" interface button.
func _on_end_turn_pressed() -> void:
	# 📤 EXPORTS TO: Passes control to the referee to process the enemy monster actions.
	battle_manager.end_player_turn()


# A simple cleaning tool function.
func clear_abilities() -> void:
	# Loops through every single active button sitting inside your horizontal layout bar 
	# and safely disintegrates them using 'queue_free()' so they stop taking up phone memory.
	for child in ability_bar.get_children():
		child.queue_free()
		
		
