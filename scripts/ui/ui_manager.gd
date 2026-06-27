# res://scripts/ui/ui_manager.gd
# ==============================================================================
# THE USER INTERFACE MANAGER
# ==============================================================================
# Draws the ability hotbar buttons when a unit is selected, manages the
# Cancel Move button, and now also:
#   - Shows a unit info box (top-left) when ANY unit (ally or enemy) is tapped:
#     exact HP bar + numbers, mana, status effect count, and clickable status
#     icons that show a description tooltip on click.
#   - A grid-lines toggle button that turns the battlefield grid overlay on/off.
# ==============================================================================

extends CanvasLayer

@export var battle_manager: Node
# Drag the BattleManager node here in the Inspector.

@export var grid: Node
# Drag BattleGrid here in the Inspector — needed so the grid-toggle button
# can tell battle_grid.gd to show/hide its GridLinesLayer.

@onready var ability_bar          = $VBoxContainer/AbilityBar
@onready var end_turn_button      = $VBoxContainer/EndTurnButton
@onready var cancel_move_button   = $VBoxContainer/CancelMoveButton
# ⚠️ You must add a Button node named "CancelMoveButton" inside VBoxContainer
#    in your BattleUI.tscn scene tree for this line to work.

# ── UNIT INFO BOX (built entirely in code — no scene changes required) ───────
# A small panel anchored near the top-left of the screen. Rebuilt from scratch
# every time show_unit_info() is called, since its contents (status icons,
# HP/mana values) change per-unit and per-tick.

var _info_box: PanelContainer = null
var _info_box_vbox: VBoxContainer = null
var _info_hp_bar_bg: ColorRect = null
var _info_hp_bar_fill: ColorRect = null
var _info_hp_label: Label = null
var _info_mana_bar_holder: Control = null
var _info_mana_bar_bg: ColorRect = null
var _info_mana_bar_fill: ColorRect = null
var _info_mana_label: Label = null
var _info_name_label: Label = null
var _info_stats_grid: GridContainer = null
var _info_stat_labels: Dictionary = {}
# Keys: "atk", "matk", "def", "mdef", "crit_chance", "crit_damage", "mov"
var _info_status_count_label: Label = null
var _info_status_icon_row: HFlowContainer = null

#Description button
var _info_description_button: Button = null

var _info_box_unit = null
# The unit the info box currently displays. Used so we can refresh it on a
# timer/poll if you want live updates — see show_unit_info() for details.

# ── STATUS TOOLTIP POPUP ──────────────────────────────────────────────────────
# A small floating panel that appears when a status icon is clicked, showing
# that status's display_name + description. Dismissed by clicking anywhere
# else (see _unhandled_input below).

var _status_tooltip: PanelContainer = null

const STATUS_ICON_SIZE: float = 32.0
const MISSING_ICON_COLOR: Color = Color(0, 0, 0, 1)
# Used as the fallback "icon" for any StatusEffectData with no icon assigned —
# a plain black box, per spec.

const HP_BAR_BG_TEXTURE_PATH: String = "res://sprites/UI/Health & Mana Bars/hpbar_background.png"
const MANA_BAR_BG_TEXTURE_PATH: String = "res://sprites/UI/Health & Mana Bars/manabar_background.png"
# Your background/frame art for the info box's bars. Drawn as a Sprite2D
# layered on top of the dark ColorRect base, scaled to exactly fit the bar's
# pixel dimensions regardless of the source PNG's native size.


func _ready() -> void:
	end_turn_button.pressed.connect(_on_end_turn_pressed)

	cancel_move_button.text = "↩️ Cancel Move"
	cancel_move_button.pressed.connect(_on_cancel_move_pressed)
	cancel_move_button.visible = false  # Hidden by default — only shown when valid.

	_build_info_box()
	_build_grid_toggle_button()


func _process(_delta: float) -> void:
	# Keeps the info box numbers live without needing every single HP/mana/
	# status change source in the codebase (abilities, auras, hazards, DoT,
	# AI attacks, etc.) to individually remember to call a refresh function.
	# This is cheap — it only does work while the box is actually visible,
	# and only refreshes numeric labels/icon list, not the whole box layout.
	if _info_box != null and _info_box.visible and is_instance_valid(_info_box_unit):
		_refresh_info_box_live_values()
	elif _info_box != null and _info_box.visible and not is_instance_valid(_info_box_unit):
		# The unit info box was showing a unit that has since been freed
		# (e.g. they died). Close the box rather than show stale data.
		hide_unit_info()


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
	if cancel_move_button != null:
		cancel_move_button.visible = visible_state


func _on_end_turn_pressed() -> void:
	if battle_manager != null and battle_manager.has_method("end_player_turn"):
		battle_manager.end_player_turn()


func _on_cancel_move_pressed() -> void:
	if battle_manager != null and battle_manager.has_method("cancel_unit_move"):
		battle_manager.cancel_unit_move()


func clear_abilities() -> void:
	if ability_bar != null:
		for child in ability_bar.get_children():
			child.queue_free()

# ══════════════════════════════════════════════════════════════════════════════
# UNIT INFO BOX
# ══════════════════════════════════════════════════════════════════════════════

func _build_info_box() -> void:
	# Constructs the info box once at startup, hidden by default.
	# Anchored near the top-left of the screen via a Control's anchor/offset.
	_info_box = PanelContainer.new()
	_info_box.custom_minimum_size = Vector2(220, 0)
	_info_box.position = Vector2(16, 16)   # Top-left corner with a small margin.
	_info_box.visible = false
	_info_box.z_index = 50
	_info_box.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_info_box)

	_info_box_vbox = VBoxContainer.new()
	_info_box_vbox.add_theme_constant_override("separation", 6)
	_info_box.add_child(_info_box_vbox)

	# Unit name header.
	_info_name_label = Label.new()
	_info_name_label.add_theme_font_size_override("font_size", 18)
	_info_box_vbox.add_child(_info_name_label)

	# HP bar (background + fill), with an exact-numbers label beside/below it.
	var hp_bar_holder = Control.new()
	hp_bar_holder.custom_minimum_size = Vector2(0, 18)
	_info_box_vbox.add_child(hp_bar_holder)

	_info_hp_bar_bg = ColorRect.new()
	_info_hp_bar_bg.color = Color(0.1, 0.1, 0.1, 0.9)
	_info_hp_bar_bg.size = Vector2(196, 16)
	_info_hp_bar_bg.position = Vector2(0, 1)
	hp_bar_holder.add_child(_info_hp_bar_bg)

	# Background art drawn on top of the dark ColorRect base, same treatment
	# as the mana bar below — see MANA_BAR_BG_TEXTURE_PATH for the pattern.
	var hp_bg_texture: Texture2D = load(HP_BAR_BG_TEXTURE_PATH)
	if hp_bg_texture != null:
		var hp_bg_sprite := Sprite2D.new()
		hp_bg_sprite.texture = hp_bg_texture
		hp_bg_sprite.centered = false
		var hp_tex_size: Vector2 = hp_bg_texture.get_size()
		if hp_tex_size.x > 0 and hp_tex_size.y > 0:
			hp_bg_sprite.scale = Vector2(196.0 / hp_tex_size.x, 16.0 / hp_tex_size.y)
		_info_hp_bar_bg.add_child(hp_bg_sprite)
	else:
		printerr("⚠️ Could not load HP bar background at: ", HP_BAR_BG_TEXTURE_PATH)

	_info_hp_bar_fill = ColorRect.new()
	_info_hp_bar_fill.color = Color(0.2, 0.9, 0.2, 1.0)
	_info_hp_bar_fill.size = Vector2(192, 12)
	_info_hp_bar_fill.position = Vector2(2, 3)
	_info_hp_bar_bg.add_child(_info_hp_bar_fill)

	_info_hp_label = Label.new()
	_info_hp_label.add_theme_font_size_override("font_size", 12)
	_info_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_hp_label.size = Vector2(196, 16)
	_info_hp_bar_bg.add_child(_info_hp_label)

	# ── MANA BAR ────────────────────────────────────────────────────────────────
	# Built the same way as the HP bar (dark background + colored fill), wrapped
	# in its own holder Control so the whole thing can be hidden when a unit has
	# zero max mana (e.g. a melee-only enemy with no mana pool at all).
	_info_mana_bar_holder = Control.new()
	_info_mana_bar_holder.custom_minimum_size = Vector2(0, 18)
	_info_box_vbox.add_child(_info_mana_bar_holder)

	_info_mana_bar_bg = ColorRect.new()
	_info_mana_bar_bg.color = Color(0.1, 0.1, 0.1, 0.9)
	_info_mana_bar_bg.size = Vector2(196, 16)
	_info_mana_bar_bg.position = Vector2(0, 1)
	_info_mana_bar_holder.add_child(_info_mana_bar_bg)

	# Background art drawn on top of the dark ColorRect base (acts as a frame/
	# border graphic). If the texture fails to load, the plain dark ColorRect
	# above still provides a usable background, so this fails gracefully.
	var mana_bg_texture: Texture2D = load(MANA_BAR_BG_TEXTURE_PATH)
	if mana_bg_texture != null:
		var mana_bg_sprite := Sprite2D.new()
		mana_bg_sprite.texture = mana_bg_texture
		mana_bg_sprite.centered = false
		var tex_size: Vector2 = mana_bg_texture.get_size()
		if tex_size.x > 0 and tex_size.y > 0:
			mana_bg_sprite.scale = Vector2(196.0 / tex_size.x, 16.0 / tex_size.y)
		_info_mana_bar_bg.add_child(mana_bg_sprite)
	else:
		printerr("⚠️ Could not load mana bar background at: ", MANA_BAR_BG_TEXTURE_PATH)

	_info_mana_bar_fill = ColorRect.new()
	_info_mana_bar_fill.color = Color(0.25, 0.45, 0.95, 1.0)   # Blue, distinct from HP's green/red.
	_info_mana_bar_fill.size = Vector2(192, 12)
	_info_mana_bar_fill.position = Vector2(2, 3)
	_info_mana_bar_bg.add_child(_info_mana_bar_fill)

	_info_mana_label = Label.new()
	_info_mana_label.add_theme_font_size_override("font_size", 12)
	_info_mana_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_mana_label.size = Vector2(196, 16)
	_info_mana_bar_bg.add_child(_info_mana_label)

	# ── EFFECTIVE STATS GRID ──────────────────────────────────────────────────────
	# Shows ATK / MATK / DEF / MDEF / Crit% / Crit DMG / MOV, all read from the
	# unit's get_effective_*() getters so status modifiers and Momentum aura
	# bonuses are already baked in — exactly what the unit would actually use
	# in combat right now, not just their base stats.
	var stats_separator := HSeparator.new()
	_info_box_vbox.add_child(stats_separator)

	_info_stats_grid = GridContainer.new()
	_info_stats_grid.columns = 2
	_info_stats_grid.add_theme_constant_override("h_separation", 12)
	_info_stats_grid.add_theme_constant_override("v_separation", 2)
	_info_box_vbox.add_child(_info_stats_grid)

	_info_stat_labels = {}
	for stat_key in ["atk", "matk", "def", "mdef", "crit_chance", "crit_damage", "mov"]:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 13)
		_info_stats_grid.add_child(lbl)
		_info_stat_labels[stat_key] = lbl

	# Status effect count label.
	_info_status_count_label = Label.new()
	_info_status_count_label.add_theme_font_size_override("font_size", 14)
	_info_box_vbox.add_child(_info_status_count_label)

	# Status icon row — wraps horizontally automatically via HFlowContainer.
	_info_status_icon_row = HFlowContainer.new()
	_info_status_icon_row.add_theme_constant_override("h_separation", 4)
	_info_status_icon_row.add_theme_constant_override("v_separation", 4)
	_info_box_vbox.add_child(_info_status_icon_row)
	
	var btn_separator := HSeparator.new()
	_info_box_vbox.add_child(btn_separator)
	
	_info_description_button = Button.new()
	_info_description_button.text = "More Information"
	_info_description_button.custom_minimum_size = Vector2(0, 30)
	_info_description_button.mouse_filter = Control.MOUSE_FILTER_STOP
	
	# Connect the press event to our new method
	_info_description_button.pressed.connect(_on_description_button_pressed)
	
	_info_box_vbox.add_child(_info_description_button)


func show_unit_info(unit) -> void:
	# Populates and shows the info box for exactly ONE unit (ally or enemy).
	# Called by battle_manager.gd whenever any unit is tapped.
	if not is_instance_valid(unit):
		hide_unit_info()
		return

	_info_box_unit = unit
	_info_box.visible = true
	_hide_status_tooltip()   # A new unit's info shouldn't leave a stale tooltip up.
	_last_status_fingerprint = ""   # Force the next _process poll to rebuild icons.

	# ── NAME ────────────────────────────────────────────────────────────────────
	var team_tag := "🛡️" if unit.is_player_unit else "⚔️"
	_info_name_label.text = "%s %s" % [team_tag, unit.unit_data.display_name]

	# ── HP ──────────────────────────────────────────────────────────────────────
	var max_hp: int = max(1, unit.get_stats().hp)
	var pct: float = clamp(float(unit.current_hp) / float(max_hp), 0.0, 1.0)
	_info_hp_bar_fill.size.x = 192.0 * pct
	if pct > 0.5:
		_info_hp_bar_fill.color = Color(0.2, 0.9, 0.2, 1.0)
	elif pct > 0.25:
		_info_hp_bar_fill.color = Color(0.95, 0.85, 0.1, 1.0)
	else:
		_info_hp_bar_fill.color = Color(0.9, 0.15, 0.15, 1.0)
	_info_hp_label.text = "%d / %d" % [unit.current_hp, max_hp]

	# ── MANA ────────────────────────────────────────────────────────────────────
	# Only show the mana bar at all if this unit actually has a mana pool —
	# some enemies (or melee-only units) may have max_mana == 0, in which case
	# the whole bar holder is hidden rather than showing an empty "0 / 0" bar.
	var max_mana: int = unit.get_stats().mana
	if max_mana > 0:
		_info_mana_bar_holder.visible = true
		var mana_pct: float = clamp(float(unit.current_mana) / float(max_mana), 0.0, 1.0)
		_info_mana_bar_fill.size.x = 192.0 * mana_pct
		_info_mana_label.text = "%d / %d" % [unit.current_mana, max_mana]
	else:
		_info_mana_bar_holder.visible = false

	_update_stat_labels(unit)

	# ── STATUS EFFECTS ──────────────────────────────────────────────────────────
	_info_status_count_label.text = "Status Effects: %d" % unit.active_statuses.size()

	for child in _info_status_icon_row.get_children():
		child.queue_free()

	for status_entry in unit.active_statuses:
		var status_data: StatusEffectData = status_entry["data"]
		_add_status_icon(status_data, status_entry["stacks"])

func hide_unit_info() -> void:
	_info_box.visible = false
	_info_box_unit = null
	_hide_status_tooltip()

func _on_description_button_pressed() -> void:
	if not is_instance_valid(_info_box_unit):
		return
		
	print("📋 Instantiating script-only UnitInfoPopup for: ", _info_box_unit.unit_data.display_name)
	
	# 1. Instantiate the script-only class using .new()
	var popup_instance = UnitInfoPopup.new()
	
	# 2. Add it to this UI canvas so it renders on screen
	add_child(popup_instance)
	
	# 3. Format your live, effective combat stats into strings for the popup grid
	var unit = _info_box_unit
	var live_stat_lines: Array[String] = [
		"ATK: %d" % unit.get_effective_atk(),
		"MATK: %d" % unit.get_effective_matk(),
		"DEF: %d" % unit.get_effective_def(),
		"MDEF: %d" % unit.get_effective_mdef(),
		"Crit %%: %.0f%%" % unit.get_effective_crit_chance(),
		"Crit DMG: %.0f%%" % unit.get_effective_crit_damage(),
		"MOV: %d" % unit.get_effective_mov()
	]
	
	# 4. Pull equipped items data if your unit structure supports it
	var items: Array = []
	if "equipped_items" in unit and unit.equipped_items != null:
		items = unit.equipped_items
	
	# 5. Initialize the popup layout with your live data
	# Setup expects: setup(unit_data, stat_lines, equipped_item_entries)
	popup_instance.setup(unit.unit_data, live_stat_lines, items)
	
func _update_stat_labels(unit) -> void:
	# Reads all seven get_effective_*() getters and writes them into the stats
	# grid. These already include status modifiers AND Momentum aura bonuses —
	# i.e. exactly the numbers the unit would actually fight with right now.
	_info_stat_labels["atk"].text         = "ATK: %d" % unit.get_effective_atk()
	_info_stat_labels["matk"].text        = "MATK: %d" % unit.get_effective_matk()
	_info_stat_labels["def"].text         = "DEF: %d" % unit.get_effective_def()
	_info_stat_labels["mdef"].text        = "MDEF: %d" % unit.get_effective_mdef()
	_info_stat_labels["crit_chance"].text = "Crit %%: %.0f%%" % unit.get_effective_crit_chance()
	_info_stat_labels["crit_damage"].text = "Crit DMG: %.0f%%" % unit.get_effective_crit_damage()
	_info_stat_labels["mov"].text         = "MOV: %d" % unit.get_effective_mov()


func refresh_unit_info_if_showing(unit) -> void:
	# Call this after anything that changes a unit's HP/mana/statuses (damage,
	# healing, a status tick, etc.) so the box stays live while it's open.
	# Safe to call unconditionally — does nothing if this unit's box isn't open.
	# NOTE: the _process() poll above already keeps the box live automatically,
	# so calling this manually is optional/redundant but harmless.
	if _info_box_unit == unit and _info_box.visible:
		show_unit_info(unit)


func _refresh_info_box_live_values() -> void:
	# Lightweight per-frame refresh: updates HP/mana numbers and the status
	# count/icons WITHOUT doing the full show_unit_info() teardown each time,
	# to avoid icon flicker. Only rebuilds the icon row if the status count
	# (or any status's stack count) actually changed since last frame.
	var unit = _info_box_unit

	var max_hp: int = max(1, unit.get_stats().hp)
	var pct: float = clamp(float(unit.current_hp) / float(max_hp), 0.0, 1.0)
	_info_hp_bar_fill.size.x = 192.0 * pct
	if pct > 0.5:
		_info_hp_bar_fill.color = Color(0.2, 0.9, 0.2, 1.0)
	elif pct > 0.25:
		_info_hp_bar_fill.color = Color(0.95, 0.85, 0.1, 1.0)
	else:
		_info_hp_bar_fill.color = Color(0.9, 0.15, 0.15, 1.0)
	_info_hp_label.text = "%d / %d" % [unit.current_hp, max_hp]

	var max_mana: int = unit.get_stats().mana
	if max_mana > 0:
		_info_mana_bar_holder.visible = true
		var mana_pct: float = clamp(float(unit.current_mana) / float(max_mana), 0.0, 1.0)
		_info_mana_bar_fill.size.x = 192.0 * mana_pct
		_info_mana_label.text = "%d / %d" % [unit.current_mana, max_mana]
	else:
		_info_mana_bar_holder.visible = false

	_update_stat_labels(unit)

	# Only rebuild the status icon row if something about it actually changed —
	# comparing a cheap fingerprint string avoids flicker from rebuilding
	# identical icons every single frame.
	var fingerprint := ""
	for s in unit.active_statuses:
		fingerprint += "%s:%d|" % [s["data"].id, s["stacks"]]

	if fingerprint != _last_status_fingerprint:
		_last_status_fingerprint = fingerprint
		_info_status_count_label.text = "Status Effects: %d" % unit.active_statuses.size()
		for child in _info_status_icon_row.get_children():
			child.queue_free()
		for status_entry in unit.active_statuses:
			var status_data: StatusEffectData = status_entry["data"]
			_add_status_icon(status_data, status_entry["stacks"])


var _last_status_fingerprint: String = ""
# Used by _refresh_info_box_live_values to detect when the status icon row
# actually needs rebuilding, vs. when only HP/mana numbers changed.


func _add_status_icon(status_data: StatusEffectData, stacks: int) -> void:
	# Builds one clickable icon button for a single active status effect.
	# Uses status_data.icon if assigned, otherwise a plain black box fallback.
	var icon_button := TextureButton.new()
	icon_button.custom_minimum_size = Vector2(STATUS_ICON_SIZE, STATUS_ICON_SIZE)
	icon_button.ignore_texture_size = true
	icon_button.stretch_mode = TextureButton.STRETCH_SCALE
	icon_button.mouse_filter = Control.MOUSE_FILTER_STOP

	if status_data.icon != null:
		icon_button.texture_normal = status_data.icon
	else:
		# Fallback: a flat black square texture, generated on the fly.
		var img := Image.create(int(STATUS_ICON_SIZE), int(STATUS_ICON_SIZE), false, Image.FORMAT_RGBA8)
		img.fill(MISSING_ICON_COLOR)
		icon_button.texture_normal = ImageTexture.create_from_image(img)

	icon_button.pressed.connect(func():
		_show_status_tooltip(status_data, icon_button)
	)

	_info_status_icon_row.add_child(icon_button)

	# If the status is stacked, overlay a small stack-count label in the corner.
	if stacks > 1:
		var stack_label := Label.new()
		stack_label.text = "x%d" % stacks
		stack_label.add_theme_font_size_override("font_size", 10)
		stack_label.position = Vector2(STATUS_ICON_SIZE - 16, STATUS_ICON_SIZE - 14)
		stack_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_button.add_child(stack_label)

# ══════════════════════════════════════════════════════════════════════════════
# STATUS TOOLTIP (click an icon → see its description)
# ══════════════════════════════════════════════════════════════════════════════

func _show_status_tooltip(status_data: StatusEffectData, anchor_node: Control) -> void:
	# Shows a small popup near the clicked icon with its name + description.
	# Clicking anywhere else on screen dismisses it — see _unhandled_input.
	_hide_status_tooltip()

	_status_tooltip = PanelContainer.new()
	_status_tooltip.z_index = 100
	_status_tooltip.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_status_tooltip)

	var vbox := VBoxContainer.new()
	_status_tooltip.add_child(vbox)

	var title := Label.new()
	title.text = status_data.display_name
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var desc := Label.new()
	desc.text = status_data.description if status_data.description != "" else "(No description)"
	desc.custom_minimum_size = Vector2(200, 0)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc.add_theme_font_size_override("font_size", 13)
	vbox.add_child(desc)

	# Position the tooltip just below-right of the icon that was clicked,
	# clamped so it doesn't run off the right/bottom edge of the screen.
	var anchor_global_pos: Vector2 = anchor_node.global_position
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var tooltip_pos: Vector2 = anchor_global_pos + Vector2(0, STATUS_ICON_SIZE + 4)
	tooltip_pos.x = min(tooltip_pos.x, viewport_size.x - 220)
	tooltip_pos.y = min(tooltip_pos.y, viewport_size.y - 100)
	_status_tooltip.position = tooltip_pos


func _hide_status_tooltip() -> void:
	if _status_tooltip != null and is_instance_valid(_status_tooltip):
		_status_tooltip.queue_free()
	_status_tooltip = null


func _unhandled_input(event: InputEvent) -> void:
	# Dismiss the status tooltip on any click that isn't on the tooltip itself.
	# We check for mouse button press OR a touch screen press, since this is a
	# mobile-and-desktop project (per the broader UI patterns already in use).
	if _status_tooltip == null:
		return

	var is_click: bool = false
	var click_pos: Vector2 = Vector2.ZERO

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed:
			is_click = true
			click_pos = mouse_event.position
	elif event is InputEventScreenTouch:
		var touch_event := event as InputEventScreenTouch
		if touch_event.pressed:
			is_click = true
			click_pos = touch_event.position

	if not is_click:
		return

	# If the click landed inside the tooltip's own rect, let it be (clicking
	# the tooltip itself shouldn't dismiss it — only clicking AWAY from it should).
	var tooltip_rect := Rect2(_status_tooltip.global_position, _status_tooltip.size)
	if tooltip_rect.has_point(click_pos):
		return

	_hide_status_tooltip()

# ══════════════════════════════════════════════════════════════════════════════
# GRID LINES TOGGLE
# ══════════════════════════════════════════════════════════════════════════════

var _grid_toggle_button: Button = null

func _build_grid_toggle_button() -> void:
	# Adds a simple toggle button into the existing VBoxContainer alongside
	# the End Turn / Cancel Move buttons, so no scene-tree edits are required.
	_grid_toggle_button = Button.new()
	_grid_toggle_button.text = "🔳 Grid: Off"
	_grid_toggle_button.toggle_mode = true
	_grid_toggle_button.custom_minimum_size = Vector2(120, 40)
	_grid_toggle_button.pressed.connect(_on_grid_toggle_pressed)
	$VBoxContainer.add_child(_grid_toggle_button)


func _on_grid_toggle_pressed() -> void:
	if grid == null or not grid.has_method("set_grid_lines_visible"):
		printerr("⚠️ UIManager: grid reference missing or set_grid_lines_visible() ",
				 "not found on BattleGrid — cannot toggle grid lines.")
		return

	var now_visible: bool = _grid_toggle_button.button_pressed
	grid.set_grid_lines_visible(now_visible)
	_grid_toggle_button.text = "🔳 Grid: On" if now_visible else "🔳 Grid: Off"
