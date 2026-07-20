# res://scripts/ui/ui_manager.gd
# ==============================================================================
# THE USER INTERFACE MANAGER — BOTTOM BAR VERSION
# ==============================================================================
# All visual layout now lives in BattleUI.tscn. This script:
#   1. Finds named nodes in the scene and connects their signals
#   2. Populates the unit info section when a unit is tapped
#   3. Populates the ability button bar when a unit is selected for action
#   4. Refreshes HP/mana/status values every frame while the bar is visible
#
# The public function names (show_unit_info, hide_unit_info, show_unit_abilities,
# clear_abilities, set_cancel_move_visible) are UNCHANGED so BattleManager
# doesn't need any edits.
#
# ── REQUIRED NODE NAMES IN BattleUI.tscn ────────────────────────────────────
# The script searches the scene recursively for these exact names (case-
# sensitive). You can nest them however you like inside BottomBar as long as
# the names match.
#
#   BottomBar          PanelContainer   The whole bar. Anchored full-width at
#                                       the bottom of the viewport.
#   PortraitRect       TextureRect      Unit portrait art. (Optional)
#   NameLabel          Label            Unit name + team emoji.
#   HPBarBG            Control          The background track of the HP bar.
#   HPBarFill          ColorRect        The coloured fill strip inside HPBarBG.
#   HPLabel            Label            "current / max" numbers on the HP bar.
#   ManaBarHolder      Control          Wraps the whole mana section. Hidden
#                                       for units that have no mana stat.
#   ManaBarFill        ColorRect        The blue fill strip inside ManaBarHolder.
#   ManaLabel          Label            Mana numbers.
#   StatsGrid          GridContainer    Script adds rows here. Set Columns = 2.
#   StatusCountLabel   Label            "Status Effects: N"
#   StatusIconRow      HFlowContainer   Script adds clickable status icons here.
#   MoreInfoButton     Button           Opens the full character-sheet popup.
#   AbilityBar         HBoxContainer    Script adds ability buttons here at
#                                       runtime when a unit is selected.
#   CancelMoveButton   Button           Cancels the current unit's movement.
#   EndRoundButton      Button           Ends the player's turn.
#   GridToggleButton   Button (opt.)    Toggles the battlefield grid overlay.
# ==============================================================================

extends CanvasLayer

@export var battle_manager: Node
# Drag the BattleManager node here in the Inspector.

@export var grid: Node
# Drag BattleGrid here in the Inspector (needed for the grid toggle button).
@export var hp_bar_pixel_width:   float = 150.0
@export var mana_bar_pixel_width: float = 150.0

@export var turn_announcement_duration: float = 2.0
@export var player_turn_texture:        Texture2D   = null
@export var enemy_turn_texture:         Texture2D   = null
@export var player_turn_scene:          PackedScene = null
@export var enemy_turn_scene:           PackedScene = null

@onready var music_volume_slider: HSlider = $PauseMenu/VBoxContainer/MusicVolumeSlider
@onready var sfx_volume_slider:   HSlider = $PauseMenu/VBoxContainer/SFXVolumeSlider

# ── SCENE NODE REFERENCES ─────────────────────────────────────────────────────
# These are populated in _ready() by searching the scene tree for each name.
# If a node is missing, the variable stays null and that piece is skipped
# gracefully — a warning is printed so you know what to add.

var bottom_bar:          Control         = null
var portrait_rect:       TextureRect     = null
var name_label:          Label           = null
var hp_bar_bg:           Control         = null
var hp_bar_fill:         Control       = null
var hp_label:            Label           = null
var _hp_fill_texture:  TextureRect = null  
var _mana_fill_texture: TextureRect = null  
var mana_bar_holder:     Control         = null
var mana_bar_fill:       Control       = null
var mana_label:          Label           = null
var stats_grid:          GridContainer   = null
var status_count_label:  Label           = null
var status_icon_row:     Control         = null  # HFlowContainer
var more_info_button:    Button          = null
var ability_bar:         Control         = null  # HBoxContainer
var cancel_move_button:  Button          = null
var end_turn_button:     Button          = null
var grid_toggle_button:  Button          = null
var speed_toggle_button: Button = null
var _prev_bar_hp: int = -1

### Pause Menu Variables
var pause_menu:           Control = null
var menu_grid_toggle:     Button  = null
var menu_quit_button:     Button  = null
var menu_resume_button:   Button  = null


#anouncement instance for the turn announcer
var _announcement_instance: Node = null

# Stat value Label nodes; created by _build_stat_rows() once StatsGrid is found.
var _stat_labels: Dictionary = {}

# The unit currently shown in the bar. null = bar is idle / hidden.
var _bar_unit = null

# ── STATUS TOOLTIP ────────────────────────────────────────────────────────────
var _status_tooltip:          PanelContainer = null
var _ability_tooltip:   PanelContainer = null
var _last_status_fingerprint: String         = ""

const STATUS_ICON_SIZE:  float = 50.0
const MISSING_ICON_COLOR: Color = Color(0, 0, 0, 1)

# Fill widths in pixels, read from scene layout after the first layout pass.
# Defaults here are safe fallbacks if HPBarBG/ManaBarBG can't be measured.
var _hp_bar_width:   float = 192.0
var _mana_bar_width: float = 192.0


# ══════════════════════════════════════════════════════════════════════════════
# SETUP
# ══════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	# ── Find every named node by searching the whole scene recursively ─────────
	# The second argument (true) means "search child nodes". The third (false)
	# means "don't require the node to be owned by this scene root" — set it
	# false so nodes you've added as raw children still get found.
	bottom_bar         = find_child("BottomBar",        true, false) as Control
	portrait_rect      = find_child("PortraitRect",     true, false) as TextureRect
	name_label         = find_child("NameLabel",        true, false) as Label
	hp_bar_bg          = find_child("HPBarBG",          true, false) as Control
	hp_bar_fill        = find_child("HPBarFill",        true, false) as Control
	hp_label           = find_child("HPLabel",          true, false) as Label
	mana_bar_holder    = find_child("ManaBarHolder",    true, false) as Control
	mana_label         = find_child("ManaLabel",        true, false) as Label
	stats_grid         = find_child("StatsGrid",        true, false) as GridContainer
	status_count_label = find_child("StatusCountLabel", true, false) as Label
	status_icon_row    = find_child("StatusIconRow",    true, false)
	more_info_button   = find_child("MoreInfoButton",   true, false) as Button
	ability_bar        = find_child("AbilityBar",       true, false)
	cancel_move_button = find_child("CancelMoveButton", true, false) as Button
	end_turn_button    = find_child("EndTurnButton",    true, false) as Button
	grid_toggle_button = find_child("GridToggleButton", true, false) as Button
	mana_bar_fill      = find_child("ManaBarFill",      true, false) as Control

	if sfx_volume_slider != null:
		sfx_volume_slider.min_value = 0
		sfx_volume_slider.max_value = 100
		sfx_volume_slider.step      = 10
		sfx_volume_slider.value = SettingsManager.sfx_volume
		sfx_volume_slider.value_changed.connect(_on_sfx_volume_changed)

	AudioManager.wire_all_buttons_in(self)   # ADDED — must be LAST, after every button above exists
	
	speed_toggle_button = find_child("SpeedToggleButton", true, false) as Button
	if speed_toggle_button:
		speed_toggle_button.toggle_mode = true
		speed_toggle_button.text        = "Speed: 1x"
		if not speed_toggle_button.pressed.is_connected(_on_speed_toggle_pressed):
			speed_toggle_button.pressed.connect(_on_speed_toggle_pressed)

	if mana_bar_fill is TextureRect:
		(mana_bar_fill as TextureRect).expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		(mana_bar_fill as TextureRect).stretch_mode = TextureRect.STRETCH_SCALE
		mana_bar_fill.custom_minimum_size = Vector2.ZERO

	#Find Pause Menu items
	pause_menu         = find_child("PauseMenu",          true, false) as Control
	if pause_menu:
		pause_menu.visible = false
	menu_grid_toggle   = find_child("MenuGridToggleButton", true, false) as Button
	menu_quit_button   = find_child("MenuQuitButton",     true, false) as Button
	menu_resume_button = find_child("MenuResumeButton",   true, false) as Button


	# Warn about any critical missing nodes so you know what to add to the scene.
	var required: Array = [
		["BottomBar",        bottom_bar],
		["NameLabel",        name_label],
		["HPBarFill",        hp_bar_fill],
		["AbilityBar",       ability_bar],
		["CancelMoveButton", cancel_move_button],
		["EndTurnButton",    end_turn_button],
	]
	for pair in required:
		if pair[1] == null:
			push_warning(
				"UIManager: could not find required node '%s' in BattleUI.tscn. " % pair[0] +
				"Add it and make sure the Name field matches exactly (it's case-sensitive)."
			)

	# ── Connect button signals ─────────────────────────────────────────────────
	if end_turn_button:
		if not end_turn_button.pressed.is_connected(_on_end_turn_pressed):
			end_turn_button.pressed.connect(_on_end_turn_pressed)

	if cancel_move_button:
		cancel_move_button.text    = "↩ Cancel Movement"
		cancel_move_button.visible = false
		if not cancel_move_button.pressed.is_connected(_on_cancel_move_pressed):
			cancel_move_button.pressed.connect(_on_cancel_move_pressed)

	if more_info_button:
		if not more_info_button.pressed.is_connected(_on_more_info_pressed):
			more_info_button.pressed.connect(_on_more_info_pressed)

	if grid_toggle_button:
		grid_toggle_button.toggle_mode = true
		grid_toggle_button.text        = "Grid: Off"
		if not grid_toggle_button.pressed.is_connected(_on_grid_toggle_pressed):
			grid_toggle_button.pressed.connect(_on_grid_toggle_pressed)

	# ── Read HP/mana bar widths from the actual laid-out scene ────────────────
	# Control nodes report size = (0, 0) until Godot finishes a layout pass.
	# Waiting one frame guarantees we get the real dimensions.
	_hp_fill_texture   = find_child("HPBarFillTexture",   true, false) as TextureRect
	_mana_fill_texture = find_child("ManaBarFillTexture", true, false) as TextureRect

	if _hp_fill_texture:
		_hp_fill_texture.custom_minimum_size.x = hp_bar_pixel_width
	if _mana_fill_texture:
		_mana_fill_texture.custom_minimum_size.x = mana_bar_pixel_width

	# ── Populate the stats rows inside StatsGrid ──────────────────────────────
	if stats_grid != null:
		_build_stat_rows()

	# Bar is visible from battle start -- EndTurnButton/GridToggleButton/
# CancelMoveButton are always available even with no unit selected.
# hide_unit_info() hides just the per-unit section (portrait, name,
# stats) so it doesn't show blank/empty values before anything is tapped.
	if bottom_bar:
		bottom_bar.visible = true
	hide_unit_info()
	EventBus.subscribe(EventBus.ON_BOSS_PHASE_CHANGED, _on_boss_phase_changed)
	
	#Volume Sliders
	if music_volume_slider != null:
		music_volume_slider.min_value = 0     # CHANGED
		music_volume_slider.max_value = 100   # CHANGED
		music_volume_slider.step      = 10    # CHANGED
		music_volume_slider.value = SettingsManager.music_volume
		music_volume_slider.value_changed.connect(_on_music_volume_changed)
	if sfx_volume_slider != null:
		sfx_volume_slider.min_value = 0
		sfx_volume_slider.max_value = 100
		sfx_volume_slider.step      = 10
		sfx_volume_slider.value = SettingsManager.sfx_volume
		sfx_volume_slider.value_changed.connect(_on_sfx_volume_changed)


func _on_music_volume_changed(value: float) -> void:
	SettingsManager.set_music_volume(value)


func _on_sfx_volume_changed(value: float) -> void:
	SettingsManager.set_sfx_volume(value)

# ── BOSS PHASE / STAGE ANNOUNCEMENT BANNER ────────────────────────────────────
var _announcement_label: Label = null

func show_announcement_banner(text: String, duration: float = 2.0) -> void:
	if text == "":
		return

	# Build the label once, lazily, and reuse it on every subsequent call.
	if _announcement_label == null:
		_announcement_label = Label.new()
		_announcement_label.name = "AnnouncementBanner"
		_announcement_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_announcement_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_announcement_label.add_theme_font_size_override("font_size", 36)
		_announcement_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_announcement_label.position = Vector2(-300, 60)
		_announcement_label.size = Vector2(600, 60)
		_announcement_label.modulate.a = 0.0
		_announcement_label.z_index = 100
		add_child(_announcement_label)   # 'self' here is ui_manager — assumes
										  # ui_manager is itself a CanvasLayer
										  # or Control; see note below if not.

	_announcement_label.text = text

	# Cancel any in-flight fade from a rapid second call (e.g. two phase
	# transitions close together) so they don't visually fight each other.
	var tween := create_tween()
	tween.tween_property(_announcement_label, "modulate:a", 1.0, 0.3)
	tween.tween_interval(duration)
	tween.tween_property(_announcement_label, "modulate:a", 0.0, 0.5)

func _on_boss_phase_changed(payload: Dictionary) -> void:
	show_announcement_banner(payload.get("text", ""))
	
			
func _on_speed_toggle_pressed() -> void:
	var now_fast: bool = speed_toggle_button.button_pressed
	CombatFeedback.set_speed_multiplier(2.0 if now_fast else 1.0)
	speed_toggle_button.text = "Speed: 2x" if now_fast else "Speed: 1x"

	if mana_bar_fill is TextureRect:
		(mana_bar_fill as TextureRect).expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		(mana_bar_fill as TextureRect).stretch_mode = TextureRect.STRETCH_SCALE
		mana_bar_fill.custom_minimum_size = Vector2.ZERO


func _build_stat_rows() -> void:
	for child in stats_grid.get_children():
		child.queue_free()

	stats_grid.columns = 3
	stats_grid.add_theme_constant_override("h_separation", 13)
	stats_grid.add_theme_constant_override("v_separation", 6)

	var icon_paths: Dictionary = {
		"atk":         "res://sprites/UI/Icons/atk_icon.png",
		"matk":        "res://sprites/UI/Icons/matk_icon.png",
		"crit_chance": "res://sprites/UI/Icons/crit%_icon.png",
		"crit_damage": "res://sprites/UI/Icons/critdmg_icon.png",
		"def":         "res://sprites/UI/Icons/def_icon.png",
		"mdef":        "res://sprites/UI/Icons/mdef_icon.png",
		"mov":         "res://sprites/UI/Icons/mov_icon.png",
	}

	_stat_labels = {}
	for key in ["atk", "matk", "crit_chance", "crit_damage", "def", "mdef", "mov"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(45, 45)
		icon.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if ResourceLoader.exists(icon_paths[key]):
			icon.texture = load(icon_paths[key]) as Texture2D
		row.add_child(icon)

		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 16)
		row.add_child(lbl)

		stats_grid.add_child(row)
		_stat_labels[key] = lbl
		
		
		if menu_resume_button:
			if not menu_resume_button.pressed.is_connected(_close_pause_menu):
				menu_resume_button.pressed.connect(_close_pause_menu)

		if menu_quit_button:
			if not menu_quit_button.pressed.is_connected(_on_menu_quit_pressed):
				menu_quit_button.pressed.connect(_on_menu_quit_pressed)

		if menu_grid_toggle:
			menu_grid_toggle.toggle_mode = true
			menu_grid_toggle.text        = "Grid: Off"
			if not menu_grid_toggle.pressed.is_connected(_on_menu_grid_toggle_pressed):
				menu_grid_toggle.pressed.connect(_on_menu_grid_toggle_pressed)

# ══════════════════════════════════════════════════════════════════════════════
# LIVE REFRESH  (runs every frame while the bar is visible)
# ══════════════════════════════════════════════════════════════════════════════

func _process(_delta: float) -> void:
	if bottom_bar == null or not bottom_bar.visible:
		return
	if not is_instance_valid(_bar_unit):
		hide_unit_info()
		return
	_refresh_live_values()


# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC API  (called by BattleManager — do NOT rename these functions)
# ══════════════════════════════════════════════════════════════════════════════

func show_unit_info(unit) -> void:
	# Shows the unit info section. Called when any unit (ally or enemy) is tapped.
	if not is_instance_valid(unit):
		hide_unit_info()
		return

	_bar_unit                 = unit
	_last_status_fingerprint  = "__RESET__"
	_hide_status_tooltip()
	_set_unit_content_visible(true)

	if bottom_bar:
		bottom_bar.visible = true

	# Portrait
	if portrait_rect:
		if unit.unit_data != null and unit.unit_data.portrait != null:
			portrait_rect.texture = unit.unit_data.portrait
			portrait_rect.visible = true
		else:
			portrait_rect.texture = null

	# Name
	if name_label:
		var tag := "🛡 " if unit.is_player_unit else "⚔ "
		name_label.text = tag + unit.unit_data.display_name

	# HP, mana, stats, status icons
	_refresh_live_values()


func hide_unit_info() -> void:
	_bar_unit = null
	_hide_status_tooltip()
	_set_unit_content_visible(false)
	# EndTurnButton, GridToggleButton, and CancelMoveButton are NOT in the
	# list above, so they stay fully visible and functional at all times.

func show_unit_abilities(unit) -> void:
	# Rebuilds the ability button row for the currently selected player unit.
	clear_abilities()
	if unit == null:
		return
	if not ("unit_data" in unit) or unit.unit_data == null:
		return
	if not ("starting_abilities" in unit.unit_data):
		return
	if unit.has_acted:
		return
	if ability_bar == null:
		push_warning("UIManager: AbilityBar node not found — ability buttons cannot appear.")
		return
	if bottom_bar:
		bottom_bar.visible = true
	for ability in unit.unit_data.starting_abilities:
		if ability == null:
			continue
		var btn := Button.new()
		btn.text                    = ability.display_name
		btn.icon = ability.icon
		btn.expand_icon = true             # Allows the icon to scale to fit
		btn.add_theme_constant_override("icon_max_width", 64) # Sets the size (in pixels)
		btn.custom_minimum_size     = Vector2(110, 40)
		btn.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
		btn.mouse_filter            = Control.MOUSE_FILTER_STOP
		
		var cooldown: int = unit.ability_cooldowns.get(ability.id, 0)
		if cooldown > 0:
			btn.disabled = true
			btn.text    += " (%d)" % cooldown
		btn.pressed.connect(func():
			if battle_manager and battle_manager.has_method("on_ability_selected"):
				battle_manager.on_ability_selected(ability)
		)
		
		btn.mouse_entered.connect(func(): _show_ability_tooltip(ability, btn))
		btn.mouse_exited.connect(_hide_ability_tooltip)
		AudioManager.wire_button_sfx(btn)   # ADDED
		ability_bar.add_child(btn)

		
func set_cancel_move_visible(visible_state: bool) -> void:
	if cancel_move_button:
		cancel_move_button.visible = visible_state


func clear_abilities() -> void:
	_hide_ability_tooltip()
	if ability_bar:
		for child in ability_bar.get_children():
			child.queue_free()


func refresh_unit_info_if_showing(unit) -> void:
	if _bar_unit == unit and bottom_bar and bottom_bar.visible:
		show_unit_info(unit)


# ══════════════════════════════════════════════════════════════════════════════
# GENERIC POPUP / TOAST SYSTEM
# ══════════════════════════════════════════════════════════════════════════════
# Lightweight, code-only popups — no extra BattleUI.tscn nodes required.
# Two flavours:
#   _show_toast()           — fades out on its own. Use for "you can't do
#                              that" one-liners (not enough mana, occupied
#                              tile, unleash not ready, ...).
#   show_targeting_prompt()  — stays up until explicitly hidden. Use for
#   / hide_targeting_prompt()  multi-step flows the player needs to keep
#                              reading throughout, like wall placement.

var _toast_label:  Label = null
var _toast_tween:  Tween = null

func _show_toast(text: String, duration: float = 1.4) -> void:
	if _toast_label == null or not is_instance_valid(_toast_label):
		_toast_label = Label.new()
		_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_toast_label.add_theme_font_size_override("font_size", 22)
		_toast_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		_toast_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_toast_label.add_theme_constant_override("outline_size", 5)
		_toast_label.z_index      = 200
		_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_toast_label)

	_toast_label.text      = text
	_toast_label.modulate  = Color(1, 1, 1, 1)
	_toast_label.visible   = true

	await get_tree().process_frame   # let it measure itself before centering
	if not is_instance_valid(_toast_label):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_toast_label.position = Vector2((vp.x - _toast_label.size.x) / 2.0, 90.0)

	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()

	_toast_tween = create_tween()
	_toast_tween.tween_interval(duration)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.35)


func show_popup_message(text: String) -> void:
	# Generic entry point for any one-off toast — e.g. wall placement errors.
	_show_toast(text)


func show_unleash_not_ready_popup() -> void:
	_show_toast("Unleash Not Ready")


func show_insufficient_mana_popup() -> void:
	_show_toast("Not Enough Mana")


# ── TARGETING PROMPT (wall placement, or anything multi-step) ──────────────

var _targeting_prompt_label: Label = null

func show_targeting_prompt(text: String) -> void:
	if _targeting_prompt_label == null or not is_instance_valid(_targeting_prompt_label):
		_targeting_prompt_label = Label.new()
		_targeting_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_targeting_prompt_label.add_theme_font_size_override("font_size", 20)
		_targeting_prompt_label.add_theme_color_override("font_color", Color(1, 1, 1))
		_targeting_prompt_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_targeting_prompt_label.add_theme_constant_override("outline_size", 4)
		_targeting_prompt_label.z_index      = 200
		_targeting_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_targeting_prompt_label)

	_targeting_prompt_label.text     = text
	_targeting_prompt_label.visible  = true
	_targeting_prompt_label.modulate = Color(1, 1, 1, 1)

	await get_tree().process_frame
	if not is_instance_valid(_targeting_prompt_label):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_targeting_prompt_label.position = Vector2((vp.x - _targeting_prompt_label.size.x) / 2.0, 40.0)


func hide_targeting_prompt() -> void:
	if is_instance_valid(_targeting_prompt_label):
		_targeting_prompt_label.visible = false


# ── CONFIRM TARGETS BUTTON (multi-target selection) ─────────────────────────
# Shown alongside the targeting prompt while picking Zephyr-Strike-style
# multi-target abilities, so the player can commit with FEWER than the max
# number of targets instead of being forced to fill every slot.

var _confirm_targets_button: Button = null
var _confirm_targets_callback: Callable = Callable()

func show_confirm_targets_button(callback: Callable) -> void:
	if _confirm_targets_button == null or not is_instance_valid(_confirm_targets_button):
		_confirm_targets_button = Button.new()
		_confirm_targets_button.text = "Confirm"
		_confirm_targets_button.z_index = 200
		add_child(_confirm_targets_button)

	# Swap the callback each time rather than only connecting once, since a
	# fresh Callable is passed in every time targeting starts.
	if _confirm_targets_button.pressed.is_connected(_on_confirm_targets_pressed):
		_confirm_targets_button.pressed.disconnect(_on_confirm_targets_pressed)
	_confirm_targets_callback = callback
	_confirm_targets_button.pressed.connect(_on_confirm_targets_pressed)

	_confirm_targets_button.visible = true

	await get_tree().process_frame
	if not is_instance_valid(_confirm_targets_button):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	# Sits just below the targeting prompt label (which anchors at y=40).
	_confirm_targets_button.position = Vector2((vp.x - _confirm_targets_button.size.x) / 2.0, 80.0)


func hide_confirm_targets_button() -> void:
	if is_instance_valid(_confirm_targets_button):
		_confirm_targets_button.visible = false


func _on_confirm_targets_pressed() -> void:
	if _confirm_targets_callback.is_valid():
		_confirm_targets_callback.call()


# ══════════════════════════════════════════════════════════════════════════════
# INTERNAL — LIVE VALUE REFRESH
# ══════════════════════════════════════════════════════════════════════════════

func _refresh_live_values() -> void:
	var unit = _bar_unit

	# ── HP ────────────────────────────────────────────────────────────────────
	if unit.has_method("get_stats"):
		var max_hp: int   = unit.get_effective_max_hp()
		var pct:    float = clamp(float(unit.current_hp) / float(max_hp), 0.0, 1.0)
	
		# Only update the visual bar if it actually exists
		# Only update the visual bar if it actually exists
		if hp_bar_fill:
			hp_bar_fill.size.x = hp_bar_pixel_width * pct
		# THE FIX: this texture-based fill was only ever sized ONCE, in
		# _ready(), to the full configured width — it never tracked actual
		# HP percentage at all, which is why the bar looked stuck at
		# "mostly full" no matter how much damage was taken.
		if _hp_fill_texture:
			_hp_fill_texture.custom_minimum_size.x = hp_bar_pixel_width * pct
			_hp_fill_texture.size.x = hp_bar_pixel_width * pct
		# Only update the text label if it actually exists
		if hp_label:
			hp_label.text = "%d / %d" % [unit.current_hp, max_hp]
		
	# ── HP bar flash on damage ─────────────────────────────────────────────
	if _prev_bar_hp >= 0 and unit.current_hp < _prev_bar_hp:
		CombatFeedback.flash_bar(hp_bar_fill)
	_prev_bar_hp = unit.current_hp
	
	# ── Mana ──────────────────────────────────────────────────────────────────
	if mana_bar_holder and unit.has_method("get_stats"):
		var max_mana: int = unit.get_effective_max_mana()
		mana_bar_holder.modulate.a = 1.0 if max_mana > 0 else 0.0
		if max_mana > 0:
			var mana_pct: float = clamp(float(unit.current_mana) / float(max_mana), 0.0, 1.0)
			if mana_bar_fill:
				mana_bar_fill.size.x = mana_bar_pixel_width * mana_pct
			if _mana_fill_texture:
				_mana_fill_texture.custom_minimum_size.x = mana_bar_pixel_width * mana_pct
				_mana_fill_texture.size.x = mana_bar_pixel_width * mana_pct
			if mana_label:
				mana_label.text = "%d / %d" % [unit.current_mana, max_mana]
			
	# ── Stats ──────────────────────────────────────────────────────────────────
	if not _stat_labels.is_empty():
		_stat_labels["atk"].text          = "ATK %d"      % unit.get_effective_atk()
		_stat_labels["matk"].text         = "MATK %d"     % unit.get_effective_matk()
		_stat_labels["def"].text          = "DEF %d"      % unit.get_effective_def()
		_stat_labels["mdef"].text         = "MDEF %d"     % unit.get_effective_mdef()
		_stat_labels["crit_chance"].text  = "Crit %.0f%%" % unit.get_effective_crit_chance()
		_stat_labels["crit_damage"].text  = "CDmg %.0f%%" % unit.get_effective_crit_damage()
		_stat_labels["mov"].text          = "MOV %d"      % unit.get_effective_mov()

	# ── Status effects (only rebuild when they actually changed) ──────────────
	var fingerprint: String = ""
	for s in unit.active_statuses:
		fingerprint += "%s:%d|" % [s["data"].id, s["stacks"]]

	if fingerprint != _last_status_fingerprint:
		_last_status_fingerprint = fingerprint
		if status_count_label:
			status_count_label.text = "Status Effects: %d" % unit.active_statuses.size()
		if status_icon_row:
			for child in status_icon_row.get_children():
				child.queue_free()
			for entry in unit.active_statuses:
				_add_status_icon(entry["data"], entry["stacks"], entry["remaining_rounds"])



# ══════════════════════════════════════════════════════════════════════════════
# INTERNAL — STATUS ICONS
# ══════════════════════════════════════════════════════════════════════════════

func _add_status_icon(status_data, stacks: int, remaining_rounds: int = -1) -> void:
	if status_icon_row == null:
		return

	var btn := TextureButton.new()
	btn.custom_minimum_size = Vector2(STATUS_ICON_SIZE, STATUS_ICON_SIZE)
	btn.ignore_texture_size = true
	btn.stretch_mode        = TextureButton.STRETCH_SCALE
	btn.mouse_filter        = Control.MOUSE_FILTER_STOP

	if status_data.icon != null:
		btn.texture_normal = status_data.icon
	else:
		var img := Image.create(int(STATUS_ICON_SIZE), int(STATUS_ICON_SIZE), false, Image.FORMAT_RGBA8)
		img.fill(MISSING_ICON_COLOR)
		btn.texture_normal = ImageTexture.create_from_image(img)

	btn.pressed.connect(func(): _show_status_tooltip(status_data, btn, remaining_rounds))
	status_icon_row.add_child(btn)

	if stacks > 1:
		var lbl := Label.new()
		lbl.text = "x%d" % stacks
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.position     = Vector2(STATUS_ICON_SIZE - 32, STATUS_ICON_SIZE - 32)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(lbl)


# ══════════════════════════════════════════════════════════════════════════════
# INTERNAL — STATUS TOOLTIP
# ══════════════════════════════════════════════════════════════════════════════

func _show_status_tooltip(status_data, anchor_node: Control, remaining_rounds: int = -1) -> void:
	_hide_status_tooltip()

	_status_tooltip             = PanelContainer.new()
	_status_tooltip.z_index     = 100
	_status_tooltip.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_status_tooltip)

	var vbox := VBoxContainer.new()
	_status_tooltip.add_child(vbox)

	var title := Label.new()
	title.text = status_data.display_name
	title.add_theme_font_size_override("font_size", 30)
	vbox.add_child(title)

	var desc := Label.new()
	desc.text = status_data.description if status_data.description != "" else "(No description)"
	desc.custom_minimum_size = Vector2(200, 0)
	desc.autowrap_mode       = TextServer.AUTOWRAP_WORD
	desc.add_theme_font_size_override("font_size", 13)
	vbox.add_child(desc)

	var duration := Label.new()
	if status_data.is_permanent:
		duration.text = "Permanent"
	elif remaining_rounds == 1:
		duration.text = "1 turn left"
	else:
		duration.text = "%d turns left" % remaining_rounds
	duration.add_theme_font_size_override("font_size", 13)
	duration.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	vbox.add_child(duration)

	# Position above the status icon, nudged inside the viewport.

	# Position above the status icon, nudged inside the viewport.
	var vp:  Vector2 = get_viewport().get_visible_rect().size
	var pos: Vector2 = anchor_node.global_position + Vector2(0, -(120.0 + STATUS_ICON_SIZE))
	pos.x = clamp(pos.x, 4.0, vp.x - 224.0)
	pos.y = clamp(pos.y, 4.0, vp.y - 140.0)
	_status_tooltip.position = pos


func _hide_status_tooltip() -> void:
	if is_instance_valid(_status_tooltip):
		_status_tooltip.queue_free()
	_status_tooltip = null


func _unhandled_input(event: InputEvent) -> void:
	# ── ESC toggles the pause menu ────────────────────────────────────────────
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo and ke.keycode == KEY_ESCAPE:
			if pause_menu and pause_menu.visible:
				_close_pause_menu()
			else:
				_open_pause_menu()
			get_viewport().set_input_as_handled()
			return

	# ── Clicking outside the status tooltip closes it ─────────────────────────
	if _status_tooltip == null:
		return

	var pressed:   bool    = false
	var click_pos: Vector2 = Vector2.ZERO

	if event is InputEventMouseButton:
		var me := event as InputEventMouseButton
		if me.pressed:
			pressed   = true
			click_pos = me.position
	elif event is InputEventScreenTouch:
		var te := event as InputEventScreenTouch
		if te.pressed:
			pressed   = true
			click_pos = te.position

	if not pressed:
		return
	if Rect2(_status_tooltip.global_position, _status_tooltip.size).has_point(click_pos):
		return
	_hide_status_tooltip()


# ══════════════════════════════════════════════════════════════════════════════
# INTERNAL — BUTTON HANDLERS
# ══════════════════════════════════════════════════════════════════════════════

func _on_end_turn_pressed() -> void:
	if battle_manager and battle_manager.has_method("end_player_turn"):
		battle_manager.end_player_turn()


func _on_cancel_move_pressed() -> void:
	if battle_manager and battle_manager.has_method("cancel_unit_move"):
		battle_manager.cancel_unit_move()


func _on_more_info_pressed() -> void:
	if not is_instance_valid(_bar_unit):
		return

	var unit     = _bar_unit
	var max_hp:   int = max(1, unit.get_stats().hp)
	var max_mana: int = unit.get_effective_max_mana()

	var live_stat_lines: Array[String] = [
		"HP: %d / %d"      % [unit.current_hp,   max_hp],
		"Mana: %d / %d"    % [unit.current_mana, max_mana],
		"ATK: %d"          % unit.get_effective_atk(),
		"MATK: %d"         % unit.get_effective_matk(),
		"DEF: %d"          % unit.get_effective_def(),
		"MDEF: %d"         % unit.get_effective_mdef(),
		"Crit %%: %.0f%%"  % unit.get_effective_crit_chance(),
		"Crit DMG: %.0f%%" % unit.get_effective_crit_damage(),
		"MOV: %d"          % unit.get_effective_mov(),
	]

	var items: Array = []
	if "equipped_items" in unit and unit.equipped_items != null:
		items = unit.equipped_items

	var popup_instance := UnitInfoPopup.new()
	add_child(popup_instance)
	popup_instance.setup(unit.unit_data, live_stat_lines, items)


func _on_grid_toggle_pressed() -> void:
	if grid == null or not grid.has_method("set_grid_lines_visible"):
		push_warning("UIManager: grid export is not set or BattleGrid missing set_grid_lines_visible().")
		return
	var now_on: bool = grid_toggle_button.button_pressed
	grid.set_grid_lines_visible(now_on)
	grid_toggle_button.text = "Grid: On" if now_on else "Grid: Off"


func _set_unit_content_visible(show: bool) -> void:
	var alpha: float = 1.0 if show else 0.0
	for node in [
		portrait_rect, name_label, hp_bar_bg, mana_bar_holder,
		stats_grid, status_count_label, status_icon_row,
		more_info_button, ability_bar
	]:
		if node != null:
			node.modulate.a = alpha

func _show_ability_tooltip(ability, anchor_btn: Control) -> void:
	_hide_ability_tooltip()

	_ability_tooltip              = PanelContainer.new()
	_ability_tooltip.z_index      = 101   # above the status tooltip (z 100)
	_ability_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ability_tooltip)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_ability_tooltip.add_child(vbox)

	# Icon + name side by side on the top row
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vbox.add_child(header)

	if ability.icon != null:
		var icon := TextureRect.new()
		icon.texture             = ability.icon
		icon.custom_minimum_size = Vector2(32, 32)
		icon.expand_mode         = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		header.add_child(icon)

	var title := Label.new()
	title.text = ability.display_name
	title.add_theme_font_size_override("font_size", 16)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)

	# Description below
	var desc_text: String = ""
	if "description" in ability and ability.description != "":
		desc_text = ability.description
	else:
		desc_text = "(No description)"

	var desc := Label.new()
	desc.text                = desc_text
	desc.custom_minimum_size = Vector2(220, 0)
	desc.autowrap_mode       = TextServer.AUTOWRAP_WORD
	desc.add_theme_font_size_override("font_size", 13)
	vbox.add_child(desc)

	# Position above the button, clamped inside the viewport
	await get_tree().process_frame   # wait one frame so the tooltip measures itself
	if not is_instance_valid(_ability_tooltip):
		return
	var vp:  Vector2 = get_viewport().get_visible_rect().size
	var pos: Vector2 = anchor_btn.global_position
	pos.y -= _ability_tooltip.size.y + 8.0   # 8px gap above the button
	pos.x  = clamp(pos.x, 4.0, vp.x - _ability_tooltip.size.x - 4.0)
	pos.y  = clamp(pos.y, 4.0, vp.y - _ability_tooltip.size.y - 4.0)
	_ability_tooltip.position = pos


func _hide_ability_tooltip() -> void:
	if is_instance_valid(_ability_tooltip):
		_ability_tooltip.queue_free()
	_ability_tooltip = null


func _open_pause_menu() -> void:
	if pause_menu:
		pause_menu.visible = true


func _close_pause_menu() -> void:
	if pause_menu:
		pause_menu.visible = false


func _on_menu_quit_pressed() -> void:
	_close_pause_menu()
	# Change this path to wherever your main menu scene lives.
	get_tree().change_scene_to_file("res://scenes/mainmenu/main_menu.tscn")


func _on_menu_grid_toggle_pressed() -> void:
	if grid == null or not grid.has_method("set_grid_lines_visible"):
		return
	var now_on: bool = menu_grid_toggle.button_pressed
	grid.set_grid_lines_visible(now_on)
	menu_grid_toggle.text = "Grid: On" if now_on else "Grid: Off"
	# Keep the bottom bar toggle in sync if you still have one there.
	if grid_toggle_button:
		grid_toggle_button.button_pressed = now_on
		grid_toggle_button.text = menu_grid_toggle.text
		


#Turn Announcer
func show_turn_announcement(is_player_turn: bool) -> void:
	_hide_turn_announcement()

	var custom_scene:   PackedScene = player_turn_scene   if is_player_turn else enemy_turn_scene
	var custom_texture: Texture2D   = player_turn_texture if is_player_turn else enemy_turn_texture
	var label_text:     String      = "Player's Turn"     if is_player_turn else "Enemy's Turn"

	var content: Control

	if custom_scene != null:
		# Scene overrides everything — instantiate and use as-is.
		content = custom_scene.instantiate() as Control

	elif custom_texture != null:
		# Texture overrides the default box.
		var img := TextureRect.new()
		img.texture             = custom_texture
		img.expand_mode         = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.custom_minimum_size = custom_texture.get_size()
		content = img

	else:
		# Default: plain gray panel with text.
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(300, 80)
		var lbl := Label.new()
		lbl.text                     = label_text
		lbl.horizontal_alignment     = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment       = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 32)
		panel.add_child(lbl)
		content = panel

	# Wrap in a full-screen centering container so content is always centred
	# regardless of which variant is used.
	var wrapper := CenterContainer.new()
	wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.z_index      = 200
	add_child(wrapper)
	wrapper.add_child(content)
	_announcement_instance = wrapper

	await get_tree().create_timer(turn_announcement_duration).timeout
	_hide_turn_announcement()


func _hide_turn_announcement() -> void:
	if is_instance_valid(_announcement_instance):
		_announcement_instance.queue_free()
	_announcement_instance = null
		

var _big_warning_label: Label = null
var _big_warning_tween: Tween = null

func show_big_warning_popup(text: String, duration: float = 2.2) -> void:
	if _big_warning_label == null or not is_instance_valid(_big_warning_label):
		_big_warning_label = Label.new()
		_big_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_big_warning_label.add_theme_font_size_override("font_size", 34)
		_big_warning_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
		_big_warning_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
		_big_warning_label.add_theme_constant_override("outline_size", 7)
		_big_warning_label.z_index      = 250
		_big_warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_big_warning_label)

	_big_warning_label.text     = text
	_big_warning_label.modulate = Color(1, 1, 1, 1)
	_big_warning_label.visible  = true

	await get_tree().process_frame
	if not is_instance_valid(_big_warning_label):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_big_warning_label.position = Vector2(
		(vp.x - _big_warning_label.size.x) / 2.0,
		(vp.y - _big_warning_label.size.y) / 2.0
	)

	if _big_warning_tween != null and _big_warning_tween.is_valid():
		_big_warning_tween.kill()
	_big_warning_tween = create_tween()
	_big_warning_tween.tween_interval(duration)
	_big_warning_tween.tween_property(_big_warning_label, "modulate:a", 0.0, 0.4)

@export var victory_scene:   PackedScene = null
@export var defeat_scene:    PackedScene = null
@export var victory_texture: Texture2D   = null
@export var defeat_texture:  Texture2D   = null
@export var battle_result_banner_duration: float = 2.2
# Same override pattern as show_turn_announcement -- drop in a custom scene
# or texture later for real victory/defeat art without touching this code.

func show_battle_result_banner(is_victory: bool) -> void:
	_hide_turn_announcement()   # clear any lingering "Enemy's Turn" banner first

	var custom_scene:   PackedScene = victory_scene   if is_victory else defeat_scene
	var custom_texture: Texture2D   = victory_texture if is_victory else defeat_texture
	var label_text:     String      = "Victory!"      if is_victory else "Defeat..."
	var label_color:    Color       = Color(1.0, 0.85, 0.2) if is_victory else Color(0.85, 0.2, 0.2)

	var content: Control

	if custom_scene != null:
		content = custom_scene.instantiate() as Control
	elif custom_texture != null:
		var img := TextureRect.new()
		img.texture             = custom_texture
		img.expand_mode         = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.custom_minimum_size = custom_texture.get_size()
		content = img
	else:
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(400, 120)
		var lbl := Label.new()
		lbl.text                 = label_text
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 48)
		lbl.add_theme_color_override("font_color", label_color)
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		lbl.add_theme_constant_override("outline_size", 8)
		panel.add_child(lbl)
		content = panel

	var wrapper := CenterContainer.new()
	wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.z_index      = 210   # above regular turn banners (which use 200)
	add_child(wrapper)
	wrapper.add_child(content)
	_announcement_instance = wrapper

	await get_tree().create_timer(battle_result_banner_duration).timeout
	# Deliberately not fading/hiding it here -- battle_manager.gd emits
	# battle_ended right after this await returns, and the scene change
	# that follows (StageDirector.complete_stage() / GameOverScreen) tears
	# the whole banner down along with the rest of the scene anyway.

func show_game_victory_popup() -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.75)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.z_index = 300
	add_child(overlay)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	var title := Label.new()
	title.text = "Game Victory!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Congratulations, you have completed the WilderMarch demo!"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 20)
	box.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 30)
	box.add_child(spacer)

	var button := Button.new()
	button.text = "Return to Main Menu"
	button.custom_minimum_size = Vector2(240, 50)
	button.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/mainmenu/main_menu.tscn")
	)
	box.add_child(button)

	overlay.add_child(box)


# ── STAGE INTRO ANNOUNCEMENT ──────────────────────────────────────────────────
# Same override pattern as show_turn_announcement: a plain gray placeholder
# box by default, replaceable per stage_type with a custom texture or a full
# custom scene later, with zero code changes needed once art exists.
@export var combat_intro_scene:         PackedScene = null
@export var subboss_intro_scene:        PackedScene = null
@export var special_combat_intro_scene: PackedScene = null
@export var boss_intro_scene:           PackedScene = null
@export var encounter_intro_scene:      PackedScene = null

@export var combat_intro_texture:         Texture2D = null
@export var subboss_intro_texture:        Texture2D = null
@export var special_combat_intro_texture: Texture2D = null
@export var boss_intro_texture:           Texture2D = null
@export var encounter_intro_texture:      Texture2D = null

@export var stage_intro_duration: float = 2.0

func show_stage_intro_announcement(stage_type: String, stage_number: int) -> void:
	_hide_turn_announcement()   # clear anything lingering first

	var custom_scene:   PackedScene = null
	var custom_texture: Texture2D   = null
	match stage_type:
		"combat":
			custom_scene   = combat_intro_scene
			custom_texture = combat_intro_texture
		"subboss":
			custom_scene   = subboss_intro_scene
			custom_texture = subboss_intro_texture
		"special_combat":
			custom_scene   = special_combat_intro_scene
			custom_texture = special_combat_intro_texture
		"boss":
			custom_scene   = boss_intro_scene
			custom_texture = boss_intro_texture
		"encounter":
			custom_scene   = encounter_intro_scene
			custom_texture = encounter_intro_texture

	var label_text: String = "Stage %d" % stage_number
	var content: Control

	if custom_scene != null:
		# Full custom scene overrides everything — you're responsible for
		# whatever it displays (it can read stage_number itself if it has a
		# method for that; not assumed here).
		content = custom_scene.instantiate() as Control

	elif custom_texture != null:
		var img := TextureRect.new()
		img.texture             = custom_texture
		img.expand_mode         = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.custom_minimum_size = custom_texture.get_size()
		content = img

	else:
		# Placeholder — plain gray box with the stage number, used until
		# real art/scenes exist for each stage_type.
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(360, 90)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.3, 0.3, 0.9)
		style.set_corner_radius_all(8)
		panel.add_theme_stylebox_override("panel", style)

		var lbl := Label.new()
		lbl.text                 = label_text
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 36)
		panel.add_child(lbl)
		content = panel

	var wrapper := CenterContainer.new()
	wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.z_index      = 205   # above regular turn banners (200), below victory/defeat (210)
	add_child(wrapper)
	wrapper.add_child(content)
	_announcement_instance = wrapper

	await get_tree().create_timer(stage_intro_duration).timeout
	_hide_turn_announcement()
	

#Show consumable/usable items in battle
var _items_popup: PopupPanel = null

func show_usable_items(unit) -> void:
	if ability_bar == null or unit == null or unit.has_used_item_this_turn:
		return

	var consumables: Array = []   # [{ "item_id": String, "slot_index": int, "data": Dictionary }, ...]
	for i in range(unit.equipped_item_ids.size()):
		var item_id = unit.equipped_item_ids[i]
		if item_id == null or item_id == "":
			continue
		var data := ContentLoader.get_equipment(item_id)
		if data.get("type", "") == "consumable":
			consumables.append({"item_id": item_id, "slot_index": i, "data": data})

	# THE FIX (your 3rd point): no consumables equipped -> no button, period.
	if consumables.is_empty():
		return

	var items_btn := Button.new()
	items_btn.text = "Items"
	items_btn.custom_minimum_size = Vector2(90, 40)
	items_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	items_btn.pressed.connect(func(): _open_items_popup(items_btn, unit, consumables))
	AudioManager.wire_button_sfx(items_btn)
	ability_bar.add_child(items_btn)


func _open_items_popup(anchor_button: Button, unit, consumables: Array) -> void:
	if _items_popup != null and is_instance_valid(_items_popup):
		_items_popup.queue_free()

	_items_popup = PopupPanel.new()
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	_items_popup.add_child(list)

	for entry in consumables:
		var data: Dictionary = entry["data"]
		var item_id: String = entry["item_id"]
		var slot_index: int = entry["slot_index"]

		var btn := Button.new()
		btn.text = data.get("name", item_id)
		var icon_path: String = data.get("icon", "")
		if icon_path != "" and ResourceLoader.exists(icon_path):
			btn.icon = load(icon_path)
		btn.expand_icon = true
		btn.add_theme_constant_override("icon_max_width", 48)
		btn.custom_minimum_size = Vector2(150, 36)
		btn.pressed.connect(func():
			_items_popup.hide()
			if battle_manager and battle_manager.has_method("on_item_selected"):
				battle_manager.on_item_selected(item_id, slot_index, unit)
		)
		AudioManager.wire_button_sfx(btn)
		list.add_child(btn)

	ability_bar.add_child(_items_popup)
	# Positions the popup just above the "Items" button. Tweak the y-offset
	# to taste once you see it against your actual action bar layout.
	_items_popup.position = Vector2(anchor_button.global_position.x, anchor_button.global_position.y - 200)
	_items_popup.popup()
		
