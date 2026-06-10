# res://scripts/encounter/encounter_scene.gd

# 📥 CALLS FROM: EncounterData resources (the .tres files you make)

# 📤 EXPORTS TO: RunManager — updates gold/items based on choices

extends Node2D

# Pool of all available encounters

@export var encounter_pool: Array[EncounterData] = []

@onready var title_label = $TitleLabel

@onready var desc_label = $DescriptionLabel

@onready var choice_container = $VBoxContainer

@onready var result_label = $ResultLabel

@onready var continue_button = $ContinueButton

var current_encounter: EncounterData = null

func _ready() -> void:

	# Pick a random encounter

	if encounter_pool.size() > 0:

		current_encounter = encounter_pool[randi() % encounter_pool.size()]

		_display_encounter()

	continue_button.visible = false

	continue_button.pressed.connect(_on_continue)

func _display_encounter() -> void:

	title_label.text = current_encounter.title

	desc_label.text = current_encounter.description

	for i in range(current_encounter.choices.size()):

		var choice = current_encounter.choices[i]

		var btn = Button.new()

		btn.text = choice.get("text", "Choose")

		btn.pressed.connect(func(): _make_choice(choice))

		choice_container.add_child(btn)

func _make_choice(choice: Dictionary) -> void:

	# Clear choice buttons

	for child in choice_container.get_children():

		child.queue_free()

	var result = ""

	# Apply gold reward

	var gold = choice.get("reward_gold", 0)

	if gold > 0:

		RunManager.add_gold(gold)

		result += "Gained " + str(gold) + " gold. "

	elif gold < 0:

		RunManager.spend_gold(abs(gold))

		result += "Lost " + str(abs(gold)) + " gold. "

	result_label.text = result if result != "" else "Nothing happened."

	continue_button.visible = true

func _on_continue() -> void:

	RunManager.advance_stage()

	get_tree().change_scene_to_file("res://scenes/meta/ShopScene.tscn")
