# res://scripts/encounter/encounter_scene.gd
#
# Attach to the ROOT node of EncounterScene.tscn. Pure display layer -- all
# actual encounter/dialogue logic lives in the EncounterEngine/DialogueEngine
# autoloads. This script picks a valid encounter, walks its dialogue graph
# node by node, and shows that encounter's own background image.
#
# Expected node tree -- see the README for the full step-by-step walkthrough:
#   EncounterScene (Node2D)
#     Background (TextureRect)
#     TitleLabel (Label)
#     DescriptionLabel (RichTextLabel)
#     ChoicesContainer (HBoxContainer)   <- choice buttons built here at runtime

extends Node2D

@onready var background: TextureRect = $Background
@onready var title_label: Label = $TitleLabel
@onready var desc_label: RichTextLabel = $DescriptionLabel
@onready var choices_container: HBoxContainer = $ChoicesContainer

var _encounter_id: String = ""
var _placeholder_bg: ImageTexture = null


func _ready() -> void:
	if RunManager.current_run == null:
		printerr("❌ EncounterScene: RunManager.current_run is null.")
		return

	_encounter_id = EncounterEngine.pick_encounter(RunManager.current_run)
	if _encounter_id == "":
		printerr("❌ EncounterScene: no eligible encounter for this stage/biome -- ",
				 "returning to the shop instead of getting stuck.")
		StageDirector.enter_current_stage()
		return

	_set_background(_encounter_id)

	var first_node := EncounterEngine.start_encounter(_encounter_id, RunManager.current_run)
	_display_node(first_node)


func _set_background(encounter_id: String) -> void:
	# Each encounter's OWN JSON content file can set a "background" field
	# (a res:// path to an image) -- this is a convention this script reads
	# directly; ContentLoader.get_encounter() just hands back whatever's in
	# the JSON, so no engine-file changes were needed to support this.
	var encounter: Dictionary = ContentLoader.get_encounter(encounter_id)
	var bg_path: String = encounter.get("background", "")
	if bg_path != "" and ResourceLoader.exists(bg_path):
		background.texture = load(bg_path)
		return

	# No background set (or path doesn't exist) -- a plain gray placeholder
	# rather than leaving the TextureRect showing nothing at all.
	if _placeholder_bg == null:
		var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.25, 0.25, 0.28))
		_placeholder_bg = ImageTexture.create_from_image(img)
	background.texture = _placeholder_bg


func _display_node(node: Dictionary) -> void:
	if node.is_empty():
		printerr("❌ EncounterScene: dialogue node not found.")
		return

	title_label.text = ContentLoader.get_encounter(_encounter_id).get("title", "")
	desc_label.text = node.get("text", "")

	for child in choices_container.get_children():
		child.queue_free()

	var visible_choices: Array = DialogueEngine.get_visible_choices()

	if visible_choices.is_empty():
		# A node with no (remaining) choices is a dead end -- finish the
		# encounter and return to the shop, same as every other stage type.
		var finish_btn := Button.new()
		finish_btn.text = "Continue"
		finish_btn.pressed.connect(_on_encounter_finished)
		choices_container.add_child(finish_btn)
		return

	for choice in visible_choices:
		var btn := Button.new()
		var choice_id: String = choice.get("id", "")
		var label: String = choice.get("text", choice_id if choice_id != "" else "Choose")

		# BUGFIX: choices that couldn't be afforded used to just never show
		# up at all (filtered out inside DialogueEngine.get_visible_choices()).
		# They're now included, and we gray them out here with a reason
		# instead -- e.g. "(lack 3 gold)" -- so the player can see the option
		# exists and understand why they can't take it yet.
		if not choice.get("_affordable", true):
			label += " (%s)" % choice.get("_unaffordable_reason", "unavailable")
			btn.disabled = true

		btn.text = label
		btn.pressed.connect(func(): _on_choice_pressed(choice_id))
		choices_container.add_child(btn)


func _on_choice_pressed(choice_id: String) -> void:
	var result: Dictionary = DialogueEngine.choose(choice_id)

	if result.get("leads_to_combat", false):
		# KNOWN GAP -- see the README. Nothing in this backend currently
		# defines what a dialogue choice's "combat_request" dictionary
		# should contain (a specific fixed enemy group? a spawn_table id?),
		# or how battle_manager.gd would receive it. Routing to
		# enter_current_stage() here would be WRONG -- the current stage's
		# type is still "encounter", so that would just reload this same
		# encounter scene again instead of starting a fight. Rather than
		# silently doing the wrong thing, this prints a clear warning and
		# finishes the encounter normally so you're not stuck in a loop.
		printerr("⚠️ EncounterScene: choice '", choice_id, "' has leads_to_combat = true, ",
				 "but no combat-request handoff is wired up yet. See the README's ",
				 "'Encounter-triggered combat' note for what's needed to build this.")
		_on_encounter_finished()
		return

	var next_id = result.get("next_node_id", null)
	if next_id == null:
		_on_encounter_finished()
		return

	_display_node(DialogueEngine.get_current_node())


func _on_encounter_finished() -> void:
	EncounterEngine.complete_encounter(RunManager.current_run)
	StageDirector.complete_stage()
