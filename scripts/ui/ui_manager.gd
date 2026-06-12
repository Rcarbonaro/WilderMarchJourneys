# res://scripts/ui/ui_manager.gd
# ==============================================================================
# THE USER INTERFACE MANAGER
# ==============================================================================
# Draws the ability hotbar buttons when a unit is selected,
# and manages the Cancel Move button.
# ==============================================================================

extends CanvasLayer

@export var battle_manager: Node
# Drag the BattleManager node here in the Inspector.

@onready var ability_bar          = $VBoxContainer/AbilityBar
@onready var end_turn_button      = $VBoxContainer/EndTurnButton
@onready var cancel_move_button   = $VBoxContainer/CancelMoveButton
# ⚠️ You must add a Button node named "CancelMoveButton" inside VBoxContainer
#    in your BattleUI.tscn scene tree for this line to work.


func _ready() -> void:
	end_turn_button.pressed.connect(_on_end_turn_pressed)

	# 🆕 Connect the cancel move button.
	cancel_move_button.text = "↩️ Cancel Move"
	cancel_move_button.pressed.connect(_on_cancel_move_pressed)
	cancel_move_button.visible = false  # Hidden by default — only shown when valid.


func show_unit_abilities(unit) -> void:
	# Rebuilds the ability button row for the selected unit.
	print("🔍 show_unit_abilities called for: ", unit)

	$VBoxContainer.mouse_filter = Control.MOUSE_FILTER_PASS
	$VBoxContainer/AbilityBar.mouse_filter = Control.MOUSE_FILTER_PASS

	clear_abilities()

	if unit == null:
		print("❌ Unit is null — returning early.")
		return
	if not "unit_data" in unit or unit.unit_data == null:
		print("❌ unit_data missing or null.")
		return
	if not "starting_abilities" in unit.unit_data:
		print("❌ starting_abilities not found on unit_data.")
		return

	print("📋 Unit has ", unit.unit_data.starting_abilities.size(), " abilities.")

	if unit.has_acted:
		print("📋 Unit already acted — hiding hotbar.")
		return

	for ability in unit.unit_data.starting_abilities:
		if ability == null:
			print("⚠️ Null ability entry found.")
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
				print("🎯 Ability selected: ", ability.display_name)
				battle_manager.on_ability_selected(ability)
		)

		$VBoxContainer/AbilityBar.add_child(btn)
		print("📦 Button added: ", btn.text)


func set_cancel_move_visible(visible_state: bool) -> void:
	# 🆕 Shows or hides the Cancel Move button.
	# Called by BattleManager after a unit finishes moving (show)
	# and after they use an ability or cancel (hide).
	if cancel_move_button != null:
		cancel_move_button.visible = visible_state


func _on_end_turn_pressed() -> void:
	if battle_manager != null and battle_manager.has_method("end_player_turn"):
		battle_manager.end_player_turn()


func _on_cancel_move_pressed() -> void:
	# 🆕 Called when the player taps the Cancel Move button.
	if battle_manager != null and battle_manager.has_method("cancel_unit_move"):
		battle_manager.cancel_unit_move()


func clear_abilities() -> void:
	# Removes all ability buttons from the hotbar.
	if ability_bar != null:
		for child in ability_bar.get_children():
			child.queue_free()
