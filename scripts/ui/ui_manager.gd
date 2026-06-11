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
func show_unit_abilities(unit) -> void:
	print("🔍 [UI CHECK 1] show_unit_abilities called for node: ", unit)
	
	$VBoxContainer.mouse_filter = Control.MOUSE_FILTER_PASS
	$VBoxContainer/AbilityBar.mouse_filter = Control.MOUSE_FILTER_PASS

	# Clear out old buttons first
	clear_abilities()
	
	if unit == null:
		print("❌ [UI RETURNING EARLY] Passed unit node is NULL!")
		return
		
	if not "unit_data" in unit:
		print("❌ [UI RETURNING EARLY] The unit node does not have a 'unit_data' property!")
		return
		
	if unit.unit_data == null:
		print("❌ [UI RETURNING EARLY] The 'unit_data' resource on this unit is NULL!")
		return

	# 🔍 CHECK VALUE NAMES: Are we using starting_abilities?
	if not "starting_abilities" in unit.unit_data:
		print("❌ [UI RETURNING EARLY] 'starting_abilities' array not found on unit_data card!")
		return
		
	print("📋 [UI CHECK 2] Unit has ", unit.unit_data.starting_abilities.size(), " starting abilities.")

	if unit.has_acted:
		print("📋 [UI RETURNING EARLY] ", unit.unit_data.display_name, " has already acted. Hiding hotbar.")
		return

	print("🎨 [UI SUCCESS] Proceeding to draw layout buttons for: ", unit.unit_data.display_name)

	for ability in unit.unit_data.starting_abilities:
		if ability == null:
			print("⚠️ Found a null ability entry in starting_abilities array!")
			continue
			
		var btn = Button.new()
		btn.text = ability.display_name
		btn.custom_minimum_size = Vector2(120, 40)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		
		var current_cooldown = unit.ability_cooldowns.get(ability.id, 0)
		if current_cooldown > 0:
			btn.disabled = true
			btn.text += " (%d)" % current_cooldown
		
		btn.pressed.connect(func(): 
			if battle_manager != null and battle_manager.has_method("on_ability_selected"):
				print("🎯 UI Button Clicked for ability: ", ability.display_name)
				battle_manager.on_ability_selected(ability)
		)
		
		$VBoxContainer/AbilityBar.add_child(btn)
		print("📦 [UI BUTTON ADDED] Rendered button node: ", btn.text)

# Triggered when the human player manually taps the big "End Turn" interface button.
func _on_end_turn_pressed() -> void:
	# 📤 EXPORTS TO: Passes control to the referee to process the enemy monster actions.
	if battle_manager != null and battle_manager.has_method("end_player_turn"):
		battle_manager.end_player_turn()


# A simple cleaning tool function.
func clear_abilities() -> void:
	# Loops through every single active button sitting inside your horizontal layout bar 
	# and safely disintegrates them using 'queue_free()' so they stop taking up phone memory.
	if ability_bar != null:
		for child in ability_bar.get_children():
			child.queue_free()
