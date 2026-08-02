# res://scripts/encounter/mini_encounter_scene.gd
#
# MINI-ENCOUNTER SCENE -- the brief "you come across survivors" interstitial
# that can occasionally happen after combat, before returning to
# DeploymentScene. Triggered by stage_director.gd's complete_stage() (see
# MINI_ENCOUNTER_ENABLED / MINI_ENCOUNTER_CHANCE there to turn this off or
# rebalance how often it fires).
#
# BUGFIX #1 (empty screen): the original version required hand-building a
# scene tree with exact node names, silently rendering blank if you hadn't.
# Fixed by building the UI in code instead -- see the previous fix's commit
# message in your version history for the full explanation.
#
# BUGFIX #2 (visible but unclickable buttons): the code-generated-UI version
# built its own ColorRect + CenterContainer stack directly under the scene's
# plain Control root. That's visually fine, but it doesn't get the same
# input-handling treatment Godot gives an actual Popup node -- and this
# project's OWN proven-working popups (deployment_manager.gd's Equip/Combine
# and Skill Scroll pickers) all use a real PopupPanel, not a hand-rolled
# dim-backdrop stack. Rebuilt to match that exact, already-working pattern:
# a PopupPanel child, shown via popup_centered(), instead of a custom Control
# stack. If you were previously seeing the buttons but clicks did nothing,
# this should be why.
#
# ── REQUIRED SCENE SETUP (do this once in the Godot editor) ──────────────────
# Create res://scenes/encounter/MiniEncounterScene.tscn with JUST a single
# Control node as the root, and attach this script to it. That's the whole
# scene -- nothing else needs to be added; everything else below builds
# itself in _ready().

extends Control

@export var survivor_flavors: Array[SurvivorEncounterData] = []
# Assign your SurvivorEncounterData .tres instances here in the Inspector.
# One is picked at random each time this scene loads. Leave empty and a
# single generic fallback description is used instead -- the scene still
# works correctly with zero content authored, it just won't vary.

const ROB_GOLD_MIN := 4
const ROB_GOLD_MAX := 10
# "Rob them (instantly gain 4-10 gold)" -- edit these two numbers to rebalance.

var _finishing := false
# Guards against a double-click on Recruit/Rob firing _finish() twice (e.g.
# a slow frame between the click and the scene actually changing).


func _ready() -> void:
	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	var flavor: SurvivorEncounterData = null
	if not survivor_flavors.is_empty():
		flavor = survivor_flavors[randi() % survivor_flavors.size()]

	if flavor != null and flavor.portrait != null:
		var portrait_rect := TextureRect.new()
		portrait_rect.texture = flavor.portrait
		portrait_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		portrait_rect.custom_minimum_size = Vector2(0, 160)
		vbox.add_child(portrait_rect)

	var title := Label.new()
	title.text = "Survivors"
	title.add_theme_font_size_override("font_size", 20)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var description_label := Label.new()
	description_label.text = flavor.description if (flavor != null and flavor.description != "") else \
		"You come across a small group of survivors sheltering nearby."
	description_label.custom_minimum_size = Vector2(320, 0)
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	description_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(description_label)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 10)
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(button_row)

	var recruit_button := Button.new()
	recruit_button.text = "Recruit"
	recruit_button.tooltip_text = "Adds +1 gold to every future stage's reward, permanently, and grows your camp."
	recruit_button.pressed.connect(_on_recruit_pressed)
	button_row.add_child(recruit_button)

	var rob_button := Button.new()
	rob_button.text = "Rob"
	rob_button.tooltip_text = "Instantly gain %d-%d gold." % [ROB_GOLD_MIN, ROB_GOLD_MAX]
	rob_button.pressed.connect(_on_rob_pressed)
	button_row.add_child(rob_button)

	# Not player-closable by clicking outside/pressing Escape -- Recruit or
	# Rob are the only ways forward, on purpose, so there's no dead end
	# where the player closes this and never gets back to Deployment.
	popup.exclusive = true

	# popup_centered() is what actually makes a Popup node visible AND
	# properly interactive -- Popups start hidden by default (same as every
	# other PopupPanel in this project; see deployment_manager.gd's pickers).
	popup.popup_centered(Vector2(380, 320))


func _on_recruit_pressed() -> void:
	# "Recruit them (each time they recruit survivors, they get a
	# cumulative +1 gold per mission)". add_camp_recruit increments
	# RunState.runtime_effect_state["camp_recruit_count"] -- read by
	# stage_director.gd (the cumulative gold bonus) and
	# deployment_manager.gd (one more tent in camp). See effect_system.gd's
	# _do_add_camp_recruit() for the full explanation.
	if _finishing:
		return
	EffectSystem.apply_effects(
		[{"type": "add_camp_recruit"}],
		{"run_state": RunManager.current_run, "source": "mini_encounter:recruit"}
	)
	_finish()


func _on_rob_pressed() -> void:
	# "Rob them (instantly gain 4-10 gold)" -- one-time, no recruit-counter
	# increment, no cumulative bonus. Pure immediate gold via the SAME
	# add_gold effect every other gold reward in the game already uses,
	# just with a random range instead of a fixed amount (see
	# effect_system.gd's _do_add_gold() -- amount_min/amount_max is a new
	# addition there specifically to support this).
	if _finishing:
		return
	EffectSystem.apply_effects(
		[{"type": "add_gold", "amount_min": ROB_GOLD_MIN, "amount_max": ROB_GOLD_MAX}],
		{"run_state": RunManager.current_run, "source": "mini_encounter:rob"}
	)
	_finish()


func _finish() -> void:
	_finishing = true
	RunManager.save_run()
	# Continues on to Deployment exactly as if this encounter had never
	# happened -- see stage_director.gd's complete_stage(), which is what
	# routed here in the first place instead of going straight to
	# DeploymentScene.
	SceneTransitions.change_scene(StageDirector.DEPLOYMENT_SCENE_PATH)
	
