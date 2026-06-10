# res://scripts/managers/shop_manager.gd

# 📥 CALLS FROM: RunManager (reads current gold and party)

# 📤 EXPORTS TO: RunManager (updates gold and party when unit purchased)

extends Node2D

const REFRESH_COST = 4

const MAX_SHOP_SLOTS = 4

@onready var gold_label = $GoldLabel

@onready var unit_container = $HBoxContainer

@onready var refresh_button = $RefreshButton

@onready var continue_button = $ContinueButton

# Pool of all available units — populate this in the Inspector or via code

# 📥 CALLS FROM: UnitData resources you created in Phase 1

@export var all_units: Array[UnitData] = []

var current_shop_units: Array = []

func _ready() -> void:

	refresh_button.pressed.connect(_on_refresh_pressed)

	continue_button.pressed.connect(_on_continue_pressed)

	_refresh_shop()

	_update_gold_display()

func _refresh_shop() -> void:

	# Pick random units to show

	current_shop_units = []

	var available = all_units.duplicate()

	available.shuffle()

	for i in range(min(MAX_SHOP_SLOTS, available.size())):

		current_shop_units.append(available[i])

	_draw_shop()

func _draw_shop() -> void:

	for child in unit_container.get_children():

		child.queue_free()

	for unit_data in current_shop_units:

		var card = _make_unit_card(unit_data)

		unit_container.add_child(card)

func _make_unit_card(unit_data: UnitData) -> Control:

	var panel = PanelContainer.new()

	var vbox = VBoxContainer.new()

	panel.add_child(vbox)

	var name_label = Label.new()

	name_label.text = unit_data.display_name

	vbox.add_child(name_label)

	var cost_label = Label.new()

	cost_label.text = "Cost: " + str(unit_data.cost_gold) + " gold"

	vbox.add_child(cost_label)

	var buy_button = Button.new()

	buy_button.text = "Recruit"

	# Check if affordable and party not full

	var can_buy = RunManager.current_run.gold >= unit_data.cost_gold

	var party_size = RunManager.current_run.party.size() + RunManager.current_run.bench.size()

	buy_button.disabled = not can_buy or party_size >= 10  # 4 party + 6 bench

	buy_button.pressed.connect(func(): _buy_unit(unit_data, buy_button))

	vbox.add_child(buy_button)

	return panel

func _buy_unit(unit_data: UnitData, button: Button) -> void:

	# 📤 EXPORTS TO: RunManager.spend_gold() and updates run party

	if RunManager.spend_gold(unit_data.cost_gold):

		if RunManager.current_run.party.size() < 4:

			RunManager.current_run.party.append(unit_data)

		else:

			RunManager.current_run.bench.append(unit_data)

		button.disabled = true

		_update_gold_display()

func _on_refresh_pressed() -> void:

	if RunManager.spend_gold(REFRESH_COST):

		_refresh_shop()

		_update_gold_display()

func _on_continue_pressed() -> void:

	# Move to the next stage

	# �04 EXPORTS TO: RunManager.advance_stage() then loads appropriate scene

	RunManager.advance_stage()

	var stage_type = RunManager.get_current_stage_type()

	match stage_type:

		"combat", "subboss", "boss", "special_combat":

			get_tree().change_scene_to_file("res://scenes/battle/BattleScene.tscn")

		"encounter":

			get_tree().change_scene_to_file("res://scenes/encounter/EncounterScene.tscn")

func _update_gold_display() -> void:

	$GoldLabel.text = "Gold: " + str(RunManager.current_run.gold)
