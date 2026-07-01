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


# ── SCENE NODE REFERENCES ─────────────────────────────────────────────────────
# These are populated in _ready() by searching the scene tree for each name.
# If a node is missing, the variable stays null and that piece is skipped
# gracefully — a warning is printed so you know what to add.

var bottom_bar:          Control         = null
var portrait_rect:       TextureRect     = null
var name_label:          Label           = null
var hp_bar_bg:           Control         = null
var hp_bar_fill:         ColorRect       = null
var hp_label:            Label           = null
var mana_bar_holder:     Control         = null
var mana_bar_fill:       ColorRect       = null
var mana_label:          Label           = null
var stats_grid:          GridContainer   = null
var status_count_label:  Label           = null
var status_icon_row:     Control         = null  # HFlowContainer
var more_info_button:    Button          = null
var ability_bar:         Control         = null  # HBoxContainer
var cancel_move_button:  Button          = null
var end_turn_button:     Button          = null
var grid_toggle_button:  Button          = null

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
	hp_bar_fill        = find_child("HPBarFill",        true, false) as ColorRect
	hp_label           = find_child("HPLabel",          true, false) as Label
	mana_bar_holder    = find_child("ManaBarHolder",    true, false) as Control
	mana_bar_fill      = find_child("ManaBarFill",      true, false) as ColorRect
	mana_label         = find_child("ManaLabel",        true, false) as Label
	stats_grid         = find_child("StatsGrid",        true, false) as GridContainer
	status_count_label = find_child("StatusCountLabel", true, false) as Label
	status_icon_row    = find_child("StatusIconRow",    true, false)
	more_info_button   = find_child("MoreInfoButton",   true, false) as Button
	ability_bar        = find_child("AbilityBar",       true, false)
	cancel_move_button = find_child("CancelMoveButton", true, false) as Button
	end_turn_button    = find_child("EndTurnButton",    true, false) as Button
	grid_toggle_button = find_child("GridToggleButton", true, false) as Button

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
		end_turn_button.pressed.connect(_on_end_turn_pressed)

	if cancel_move_button:
		cancel_move_button.text    = "↩ Cancel Movement"
		cancel_move_button.visible = false
		cancel_move_button.pressed.connect(_on_cancel_move_pressed)

	if more_info_button:
		more_info_button.pressed.connect(_on_more_info_pressed)

	if grid_toggle_button:
		grid_toggle_button.toggle_mode = true
		grid_toggle_button.text        = "Grid: Off"
		grid_toggle_button.pressed.connect(_on_grid_toggle_pressed)

	# ── Read HP/mana bar widths from the actual laid-out scene ────────────────
	# Control nodes report size = (0, 0) until Godot finishes a layout pass.
	# Waiting one frame guarantees we get the real dimensions.
	await get_tree().process_frame
	if hp_bar_bg != null and hp_bar_bg.size.x > 0:
		_hp_bar_width = hp_bar_bg.size.x - 4.0   # 2-px padding each side
	if mana_bar_holder != null:
		var mana_bg: Control = find_child("ManaBarBG", true, false) as Control
		if mana_bg and mana_bg.size.x > 0:
			_mana_bar_width = mana_bg.size.x - 4.0
		else:
			_mana_bar_width = _hp_bar_width

	# ── Populate the stats rows inside StatsGrid ──────────────────────────────
	if stats_grid != null:
		_build_stat_rows()

	# Start hidden — becomes visible when a unit is tapped or selected.
	if bottom_bar:
		bottom_bar.visible = false


func _build_stat_rows() -> void:
	# Creates 7 icon+value rows inside the StatsGrid container.
	# The GridContainer only needs to exist in the scene; the rows are all
	# built here so you don't have to manually add 14 sub-nodes in the editor.
	stats_grid.columns = 2
	stats_grid.add_theme_constant_override("h_separation", 12)
	stats_grid.add_theme_constant_override("v_separation", 3)

	var icon_paths: Dictionary = {
		"atk":         "res://sprites/UI/Icons/atk_icon.png",
		"matk":        "res://sprites/UI/Icons/matk_icon.png",
		"def":         "res://sprites/UI/Icons/def_icon.png",
		"mdef":        "res://sprites/UI/Icons/mdef_icon.png",
		"crit_chance": "res://sprites/UI/Icons/crit%_icon.png",
		"crit_damage": "res://sprites/UI/Icons/critdmg_icon.png",
		"mov":         "res://sprites/UI/Icons/mov_icon.png",
	}

	_stat_labels = {}
	for key in ["atk", "matk", "def", "mdef", "crit_chance", "crit_damage", "mov"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(24, 24)
		icon.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if ResourceLoader.exists(icon_paths[key]):
			icon.texture = load(icon_paths[key]) as Texture2D
		row.add_child(icon)

		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 20)
		row.add_child(lbl)

		stats_grid.add_child(row)
		_stat_labels[key] = lbl


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


func show_unleash_not_ready_popup() -> void:
	# TODO: replace with your own popup or toast notification if needed.
	pass


func show_insufficient_mana_popup() -> void:
	# TODO: replace with your own popup or toast notification if needed.
	pass


# ══════════════════════════════════════════════════════════════════════════════
# INTERNAL — LIVE VALUE REFRESH
# ══════════════════════════════════════════════════════════════════════════════

func _refresh_live_values() -> void:
	var unit = _bar_unit

	# ── HP ────────────────────────────────────────────────────────────────────
	if hp_bar_fill and unit.has_method("get_stats"):
		var max_hp: int   = max(1, unit.get_stats().hp)
		var pct:    float = clamp(float(unit.current_hp) / float(max_hp), 0.0, 1.0)
		hp_bar_fill.size.x = _hp_bar_width * pct
		hp_bar_fill.color  = (
			Color(0.2,  0.9,  0.2)  if pct > 0.5  else
			Color(0.95, 0.85, 0.1)  if pct > 0.25 else
			Color(0.9,  0.15, 0.15)
		)
		if hp_label:
			hp_label.text = "%d / %d" % [unit.current_hp, max_hp]

	# ── Mana ──────────────────────────────────────────────────────────────────
	if mana_bar_holder and unit.has_method("get_stats"):
		var max_mana: int = unit.get_stats().mana
		mana_bar_holder.visible = max_mana > 0
		if max_mana > 0:
			var mana_pct: float = clamp(float(unit.current_mana) / float(max_mana), 0.0, 1.0)
			if mana_bar_fill:
				mana_bar_fill.size.x = _mana_bar_width * mana_pct
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
				_add_status_icon(entry["data"], entry["stacks"])


# ══════════════════════════════════════════════════════════════════════════════
# INTERNAL — STATUS ICONS
# ══════════════════════════════════════════════════════════════════════════════

func _add_status_icon(status_data, stacks: int) -> void:
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

	btn.pressed.connect(func(): _show_status_tooltip(status_data, btn))
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

func _show_status_tooltip(status_data, anchor_node: Control) -> void:
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
	var max_mana: int = unit.get_stats().mana

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
