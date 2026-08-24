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

const REWARD_GLITTER_BLUE := Color(0.3, 0.6, 1.0)
# Used for the reward popup shown whenever a dialogue choice grants the
# player an item or a unit -- see _on_choice_pressed below.


const FALLBACK_ENCOUNTER_ID := "the_thief_in_the_night"
# If the randomly-picked encounter's dialogue graph fails to load for any
# reason (missing file, JSON parse error, an id typo between an encounter's
# "dialogue_graph_id" and its graph's own "id", etc.), fall back to this
# always-known-good encounter instead of leaving the player stuck on a
# broken screen with no way to proceed.


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

	if first_node.is_empty():
		# ADDED: the picked encounter's dialogue graph failed to load. Check
		# the Output panel for DialogueEngine's warning -- it names the
		# exact graph id that failed -- but rather than leave the player
		# stuck, fall back to a known-good encounter here.
		printerr("❌ EncounterScene: '", _encounter_id, "' failed to load its dialogue graph -- ",
				 "falling back to '", FALLBACK_ENCOUNTER_ID, "'.")
		_encounter_id = FALLBACK_ENCOUNTER_ID
		_set_background(_encounter_id)
		first_node = EncounterEngine.start_encounter(_encounter_id, RunManager.current_run)
		if first_node.is_empty():
			# Even the fallback failed to load (e.g. its own file got moved
			# or renamed) -- bail out to the shop rather than get stuck.
			printerr("❌ EncounterScene: fallback encounter also failed to load.")
			StageDirector.enter_current_stage()
			return

	_display_node(first_node)


@onready var _default_bg: Texture2D = background.texture

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

	# Fall back to the default image assigned to the node in the Inspector.
	# If no texture was set in the Inspector, fall back to a generated gray image.
	if _default_bg != null:
		background.texture = _default_bg



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
	# ADDED: grab the choice's OWN effects list before choose() runs, so we
	# can tell afterward whether it actually granted an item or a unit and
	# show a reward popup for it. DialogueEngine.choose()'s own return value
	# doesn't include the effects list, only next_node_id/combat info.
	var granted_effects := _get_choice_effects(choice_id)

	var result: Dictionary = DialogueEngine.choose(choice_id)

	# BUGFIX: some effects carry their own "conditions" (e.g. random_weighted_
	# flag picks ONE outcome and gates the real reward effects behind flag
	# checks -- see effect_system.gd). EffectSystem already respects those
	# when actually granting things, but this loop used to announce EVERY
	# add_equipment/add_unit entry unconditionally -- so a roll that landed
	# on "success" could still pop up a popup for a "crit-only" reward that
	# was correctly never added to the inventory. Re-checking each effect's
	# own conditions here, with the same context choose() just used, keeps
	# the popups honest about what was actually granted.
	var context := {"run_state": RunManager.current_run, "source": "dialogue:" + choice_id}

	# ADDED: pop up a glittering reward popup for anything this choice just
	# granted the player. A single choice can grant more than one thing
	# (e.g. gold AND an item) -- every add_equipment/add_unit entry gets its
	# own popup, shown one after another.
	for effect in granted_effects:
		if not EffectSystem.evaluate_conditions(effect.get("conditions", []), context):
			continue
		match effect.get("type", ""):
			"add_equipment":
				_show_encounter_item_reward(effect.get("equipment_id", ""))
			"add_unit":
				_show_encounter_unit_reward(effect.get("unit_id", ""))
				
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


# ADDED: finds the effects list for a specific choice_id on the CURRENT
# dialogue node, straight from DialogueEngine.get_visible_choices() (the
# same source _display_node() already uses to build the choice buttons).
func _get_choice_effects(choice_id: String) -> Array:
	for choice in DialogueEngine.get_visible_choices():
		if choice.get("id", "") == choice_id:
			return choice.get("effects", [])
	return []


# ADDED: item/consumable reward popup -- icon + description, Close only
# (matches the spec: items don't get a "More Information" button here).
func _show_encounter_item_reward(equipment_id: String) -> void:
	if equipment_id == "" or equipment_id.begins_with("$"):
		return   # Templated id ("$event_payload...") -- nothing concrete to show.
	AudioManager.play_sfx(load("res://assets/audio/sfx/bells.wav"))   # ADDED
	var data: Dictionary = ContentLoader.get_equipment(equipment_id)
	var icon: Texture2D = UnitInfoPopup.texture_or_black_box(
		UnitInfoPopup._resolve_icon(data.get("icon")), Vector2i(96, 96))

	var popup := RewardPopup.new()
	add_child(popup)
	popup.setup(icon, data.get("description", ""), REWARD_GLITTER_BLUE, [
		{"text": "Close", "callback": Callable()},
	])


# ADDED: unit reward popup -- portrait + description, Close + More Info
# (More Info opens the same full UnitInfoPopup character sheet used
# everywhere else in the project).
func _show_encounter_unit_reward(unit_id: String) -> void:
	if unit_id == "" or unit_id.begins_with("$"):
		return
	var path := "res://resources/units/" + unit_id + "_data.tres"
	if not ResourceLoader.exists(path):
		return
	var unit_data: UnitData = load(path) as UnitData
	if unit_data == null:
		return

	var popup := RewardPopup.new()
	add_child(popup)
	popup.setup(unit_data.portrait, unit_data.description, REWARD_GLITTER_BLUE, [
		{"text": "Close", "callback": Callable()},
		{"text": "More Information", "callback": func(): _show_encounter_unit_info_popup(unit_data)},
	])


func _show_encounter_unit_info_popup(unit_data: UnitData) -> void:
	# Same level-1 base-numbers convention the Draft screen and shop's
	# "More Info" already use -- a unit gained here isn't leveled/equipped
	# yet either.
	if unit_data.stats_by_level.is_empty():
		return
	var stats: StatsData = unit_data.stats_by_level[0]
	var stat_lines: Array[String] = [
		"HP: %d" % stats.hp,
		"Mana: %d" % stats.mana,
		"ATK: %d" % stats.atk,
		"MATK: %d" % stats.matk,
		"DEF: %d" % stats.def,
		"MDEF: %d" % stats.mdef,
		"Crit %%: %.0f%%" % stats.crit_chance,
		"Crit DMG: %.0f%%" % stats.crit_damage,
		"MOV: %d" % stats.mov,
	]
	var popup_instance := UnitInfoPopup.new()
	add_child(popup_instance)
	popup_instance.setup(unit_data, stat_lines, [])
