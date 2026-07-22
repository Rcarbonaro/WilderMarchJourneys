# res://scripts/deployment/deployment_manager.gd
#
# Attached to the ROOT node of DeploymentScene.tscn. This is now the default
# hub the player lands on after every stage (see stage_director.gd's
# complete_stage()) -- pick your 4-unit team, manage equipment, forge
# advanced items, peek at the shop, or scout the next stage before
# continuing.
#
# REWRITE NOTE: this file previously used a disconnected equipment model
# (BasicEquipmentData Resources, RunManager.current_run.equipped_items
# [unit_id], EquipmentSystem.forge_equipment()) and treated party/bench
# entries as objects with .id/.display_name. Neither matches the actual
# RunState shape: party/bench are plain Dictionaries ({ "unit_id",
# "instance_id", "level", "equipped_item_ids", "permanent_modifiers" }),
# equipment lives in RunManager.current_run.equipment_inventory as an Array
# of item_id Strings, and forging goes through
# ContentLoader.get_forging_recipe(subtype_a, subtype_b). Everything below
# now matches shop_manager.gd's already-correct implementation of the same
# ideas, so items equipped or forged here actually show up in combat.

extends Node2D

const MAX_EQUIP_SLOTS := 3

# ── AMBIENT BACKGROUND PREVIEW ────────────────────────────────────────────────
# Every owned unit (party + bench) gets a small, grid-free stand-in that
# wanders and occasionally "practices" an attack animation behind the UI.
# Purely cosmetic -- see deployment_unit_preview.gd for the whole thing.
const UNIT_PREVIEW_SCENE_PATH := "res://scenes/deployment/DeploymentUnitPreview.tscn"

@export var preview_bounds: Rect2 = Rect2(Vector2(-450, -150), Vector2(900, 300))
# Wander area, LOCAL to preview_layer's position. preview_layer should be
# positioned near the center of the screen, behind the UI panels -- adjust
# both its position in the editor and this Rect2's size to fit your
# background art. (0,0) to (500,160) by default just gives a starting box;
# reposition/resize freely, nothing else needs to change.

# ── PANEL TABS (show/hide Forge / Roster / Item Inventory) ─────────────────
# Roster and Forge start HIDDEN; Item Inventory starts shown. Player can
# open any of them via the PanelTabs buttons regardless. To change any
# default, just flip it here -- e.g.
#     @export var roster_visible_by_default: bool = true
# These are @export, so you can also flip them per-scene-instance from the
# Inspector without touching code at all, if you'd rather.
@export var roster_visible_by_default: bool = false
@export var forge_visible_by_default: bool = false
@export var inventory_visible_by_default: bool = true

@onready var background_texture: TextureRect = $BackgroundTexture
# Add a TextureRect named "BackgroundTexture" as a direct child of
# DeploymentScene's root, FIRST in the child order (so everything else draws
# on top of it). Set its Layout > Anchors Preset to "Full Rect" in the editor
# so it fills the screen. _setup_deployment_background() below fills in its
# texture at runtime based on the run's current biome.

@onready var roster_list: VBoxContainer     = $RosterScroll/RosterList
@onready var roster_scroll: ScrollContainer = $RosterScroll
@onready var equip_panel: Control           = $EquipPanel
@onready var inventory_scroll: ScrollContainer = $InventoryScroll
@onready var inventory_list: VBoxContainer  = $InventoryScroll/InventoryList
# ADDED: 4 slots showing exactly which units are currently deployed, same
# idea as DraftScene's SelectedPartyContainer. Add an HBoxContainer named
# "DeployedPartyContainer" to DeploymentScene.tscn (a good spot is right
# above RosterScroll, so it reads as "your team" before "your full roster
# below it") -- _rebuild_deployed_party_slots() builds its 4 slot buttons at
# runtime, the same way roster_list's rows are built.
@onready var deployed_party_container: HBoxContainer = $DeployedPartyContainer

# ADDED: 3 toggle buttons for the panel-tabs feature above. Add an
# HBoxContainer named "PanelTabs" to DeploymentScene.tscn (a good spot is
# right below StageLabel, above everything else) containing 3 Buttons named
# "RosterTabButton", "ForgeTabButton", and "InventoryTabButton" -- text
# doesn't matter, _ready() below overwrites it to reflect shown/hidden state.
@onready var roster_tab_button: Button      = $PanelTabs/RosterTabButton
@onready var forge_tab_button: Button       = $PanelTabs/ForgeTabButton
@onready var inventory_tab_button: Button   = $PanelTabs/InventoryTabButton

# REMOVED (this round): SelectedUnitLabel / SlotsContainer / the
# InventoryScrollContent wrapper node they briefly lived in are GONE now --
# equip-slot management moved again, this time inline into roster_list
# itself (see _append_equip_management_section()), appearing right below
# whichever unit's "Manage Equipment" you just pressed instead of living in
# a separate static section under a different tab. InventoryScroll is back
# to directly containing InventoryList, same as it was originally. If you
# still have the InventoryScrollContent/SelectedUnitLabel/SlotsContainer
# nodes sitting in your scene from last round, they're just unused now --
# safe to delete, nothing references those paths anymore.

@onready var forge_slot_a_button: Button    = $EquipPanel/ForgeRow/ForgeSlotAButton
@onready var forge_slot_b_button: Button    = $EquipPanel/ForgeRow/ForgeSlotBButton
# CHANGED: these were Labels (ForgeSlotALabel/ForgeSlotBLabel). Clicking one
# now clears it (if filled) or opens a picker of eligible items (if empty) --
# a plain Label can't emit a click. In the editor: change ForgeSlotALabel's
# and ForgeSlotBLabel's TYPE to Button (right-click the node > Change Type),
# and rename them to ForgeSlotAButton/ForgeSlotBButton to match. The old
# SetSlotAButton/SetSlotBButton nodes are no longer used at all -- Combine
# (and now the slot buttons themselves) auto-fill/pick directly instead of
# needing a separate "Set" click -- safe to delete them from the scene.
@onready var forge_button: Button           = $EquipPanel/ForgeRow/ForgeButton
@onready var forge_preview_button: Button   = $EquipPanel/ForgeRow/ForgePreviewButton
# Add a Button named "ForgePreviewButton" next to ForgeButton -- opens a
# popup showing the resulting item's icon/stats/description before you
# commit to forging.
@onready var forge_status_label: Label      = $EquipPanel/ForgeRow/ForgeStatusLabel
@onready var forge_preview_label: RichTextLabel = $EquipPanel/ForgeRow/ForgePreviewLabel
# Add a RichTextLabel named "ForgePreviewLabel" under ForgeRow (enable BBCode)
# -- shows each set slot's stats/description, and the resulting item's
# stats/description once both slots match a real recipe.

@onready var shop_button: Button            = $ShopButton
@onready var continue_button: Button        = $ContinueButton
@onready var scout_button: Button           = $ScoutButton
@onready var scout_panel: PanelContainer    = $ScoutPanel
@onready var scout_text: RichTextLabel      = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutText
@onready var scout_map_view: ScoutMapView   = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutMapView
@onready var scout_back_button: Button      = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutCloseButton
@onready var scout_enter_combat_button: Button = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutEnterCombatButton
# Add a Control named "ScoutMapView" (script: scout_map_view.gd) under
# ScoutVBox -- shows the actual tile layout + where enemies/allies will
# spawn. Also add a second Button named "ScoutEnterCombatButton" next to the
# existing close button (renamed here from "Close" to "Back" via code --
# feel free to also rename the NODE if you want, the path still works either
# way since @onready keys off the node name, not its text).
@onready var preview_layer: Node2D          = $PreviewLayer
@onready var stage_label: Label             = $StageLabel
# Add a Label named "StageLabel" near the top of DeploymentScene.tscn --
# _update_stage_label() below fills in its text at runtime.
# Add a plain Node2D named "PreviewLayer" to DeploymentScene.tscn, positioned
# near the center of the screen behind your UI panels -- every wandering
# unit gets parented under it, so moving/resizing IT moves the whole group.

var deployed_instance_ids: Array[String] = ["", "", "", ""]
# CHANGED: fixed at exactly 4 entries now, one per slot, "" meaning "empty" --
# used to be a dynamically-sized Array that only ever held real instance_ids
# (no placeholder for "empty"), which meant removing a unit via .erase()
# shifted every later unit up by one index. That was harmless when a slot's
# position was purely cosmetic, but now that clicking an empty slot needs to
# fill THAT specific slot (see _on_deployed_slot_pressed), slot identity has
# to survive removal -- "" is used instead of null because this is a typed
# Array[String], which can't hold null.

var _selected_party_index: int = -1             # index into _get_full_roster(), or -1
# REMOVED: _selected_inventory_item_id. Used to track a "picked up" item
# waiting for a destination click (an equip slot, or a forge Set button).
# Clicking an item now opens a popup with explicit actions instead (see
# _on_inventory_item_pressed), so there's no in-between "selected" state to
# track anymore.
var _forge_slot_a: String = ""                  # picked BASIC equipment item_id for forging, or ""
var _forge_slot_b: String = ""


func _ready() -> void:
	if not _validate_required_nodes():
		return

	shop_button.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/meta/ShopScene.tscn"))
	continue_button.pressed.connect(_on_continue_pressed)
	forge_slot_a_button.pressed.connect(func(): _on_forge_slot_pressed(true))
	forge_slot_b_button.pressed.connect(func(): _on_forge_slot_pressed(false))
	forge_button.pressed.connect(_on_forge_pressed)
	forge_preview_button.pressed.connect(_on_forge_preview_pressed)
	scout_button.pressed.connect(_on_scout_pressed)
	scout_back_button.text = "Back"
	scout_back_button.pressed.connect(func(): scout_panel.visible = false)
	scout_enter_combat_button.text = "Enter Combat"
	scout_enter_combat_button.pressed.connect(_on_scout_enter_combat_pressed)
	scout_panel.visible = false

	roster_tab_button.pressed.connect(func(): _toggle_panel(roster_scroll, roster_tab_button, "Roster"))
	forge_tab_button.pressed.connect(func(): _toggle_panel(equip_panel, forge_tab_button, "Forge"))
	inventory_tab_button.pressed.connect(func(): _toggle_panel(inventory_scroll, inventory_tab_button, "Inventory"))
	roster_scroll.visible    = roster_visible_by_default
	equip_panel.visible      = forge_visible_by_default
	inventory_scroll.visible = inventory_visible_by_default
	_update_tab_button_text(roster_tab_button, "Roster", roster_scroll.visible)
	_update_tab_button_text(forge_tab_button, "Forge", equip_panel.visible)
	_update_tab_button_text(inventory_tab_button, "Inventory", inventory_scroll.visible)

	if RunManager.current_run == null:
		printerr("❌ DeploymentScene: no active run found.")
		return

	for i in range(min(RunManager.current_run.party.size(), 4)):
		var entry = RunManager.current_run.party[i]
		if entry != null and entry.has("instance_id"):
			deployed_instance_ids[i] = entry["instance_id"]

	_rebuild_roster()
	_rebuild_inventory()
	_update_scout_button()
	_update_stage_label()
	_setup_deployment_background()
	_spawn_unit_previews()


func _toggle_panel(panel: Control, button: Button, label: String) -> void:
	panel.visible = not panel.visible
	_update_tab_button_text(button, label, panel.visible)


func _update_tab_button_text(button: Button, label: String, is_visible: bool) -> void:
	button.text = ("Hide %s" if is_visible else "Show %s") % label


# ADDED: this scene has accumulated a lot of "add a node named X here"
# instructions across several rounds of changes, and a single wrong/missing
# node used to fail as a generic, hard-to-place "Cannot call method
# 'get_children' on a null value" once _ready() reached whatever function
# needed it. This checks every required node up front and prints exactly
# which one is missing/misnamed, so a scene mismatch is obvious immediately
# instead of crashing deep inside some later rebuild function. See the
# README's node tree listing for exactly what each of these should look
# like.
func _validate_required_nodes() -> bool:
	var required := {
		"BackgroundTexture": background_texture,
		"RosterScroll/RosterList": roster_list,
		"RosterScroll": roster_scroll,
		"EquipPanel": equip_panel,
		"InventoryScroll": inventory_scroll,
		"InventoryScroll/InventoryList": inventory_list,
		"DeployedPartyContainer": deployed_party_container,
		"PanelTabs/RosterTabButton": roster_tab_button,
		"PanelTabs/ForgeTabButton": forge_tab_button,
		"PanelTabs/InventoryTabButton": inventory_tab_button,
		"EquipPanel/ForgeRow/ForgeSlotAButton": forge_slot_a_button,
		"EquipPanel/ForgeRow/ForgeSlotBButton": forge_slot_b_button,
		"EquipPanel/ForgeRow/ForgeButton": forge_button,
		"EquipPanel/ForgeRow/ForgePreviewButton": forge_preview_button,
		"EquipPanel/ForgeRow/ForgeStatusLabel": forge_status_label,
		"EquipPanel/ForgeRow/ForgePreviewLabel": forge_preview_label,
		"ShopButton": shop_button,
		"ContinueButton": continue_button,
		"ScoutButton": scout_button,
		"ScoutPanel": scout_panel,
		"ScoutPanel/ScoutMargin/ScoutVBox/ScoutText": scout_text,
		"ScoutPanel/ScoutMargin/ScoutVBox/ScoutMapView": scout_map_view,
		"ScoutPanel/ScoutMargin/ScoutVBox/ScoutCloseButton": scout_back_button,
		"ScoutPanel/ScoutMargin/ScoutVBox/ScoutEnterCombatButton": scout_enter_combat_button,
		"PreviewLayer": preview_layer,
		"StageLabel": stage_label,
	}
	var all_ok := true
	for path in required:
		if required[path] == null:
			printerr("❌ DeploymentScene: missing node at '%s' -- check it exists with this exact name/path. See the README's node tree." % path)
			all_ok = false
	return all_ok


# ── ROSTER / TEAM SELECTION ───────────────────────────────────────────────────

func _update_stage_label() -> void:
	if RunManager.current_run == null or stage_label == null:
		return
	var stage_index: int = RunManager.current_run.stage_index
	var stage_type: String = RunManager.get_current_stage_type()
	# String.capitalize() turns "special_combat" into "Special Combat" for free.
	stage_label.text = "Stage %d of 30 — %s" % [stage_index, stage_type.capitalize()]


func _get_full_roster() -> Array:
	var roster: Array = []
	roster.append_array(RunManager.current_run.party)
	roster.append_array(RunManager.current_run.bench)
	return roster


func _load_unit_data(unit_id: String) -> UnitData:
	var path := "res://resources/units/" + unit_id + "_data.tres"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as UnitData


func _rebuild_roster() -> void:
	for child in roster_list.get_children():
		child.queue_free()

	var roster := _get_full_roster()
	for i in range(roster.size()):
		var entry: Dictionary = roster[i]
		var unit_data := _load_unit_data(entry.get("unit_id", ""))
		var label: String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")
		var instance_id: String = entry.get("instance_id", "")

		var row := HBoxContainer.new()

		var toggle_btn := Button.new()
		toggle_btn.text = ("[Deployed] " if instance_id in deployed_instance_ids else "[ ] ") \
			+ label + " (Lv " + str(entry.get("level", 1)) + ")"
		toggle_btn.pressed.connect(func(): _on_roster_toggle_pressed(instance_id))
		row.add_child(toggle_btn)

		var equip_btn := Button.new()
		equip_btn.text = ("▶ " if i == _selected_party_index else "") + "Manage Equipment"
		equip_btn.pressed.connect(func(): _on_roster_entry_pressed(i))
		row.add_child(equip_btn)

		var more_info_btn := Button.new()
		more_info_btn.text = "More Info"
		more_info_btn.pressed.connect(func(): _on_more_info_pressed(i))
		row.add_child(more_info_btn)

		roster_list.add_child(row)

	# ADDED: if a unit is currently selected via "Manage Equipment", their
	# equipped items (with Unequip/Info buttons) appear right here, below
	# the full roster list -- built fresh every time since roster_list's
	# children are always fully cleared and rebuilt anyway (see the top of
	# this function).
	_append_equip_management_section()

	_rebuild_deployed_party_slots()


# ADDED: shows the currently-selected unit's 3 equipped items, each with an
# Unequip button (returns it to the inventory bag) and an Info button (same
# read-only preview popup used everywhere else). Shows nothing at all if no
# unit is currently selected for equip management.
func _append_equip_management_section() -> void:
	var entry := _get_selected_entry()
	if entry.is_empty():
		return

	var unit_data := _load_unit_data(entry.get("unit_id", ""))
	var label: String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")

	roster_list.add_child(HSeparator.new())

	var header := Label.new()
	header.text = "Equipping: " + label
	header.add_theme_font_size_override("font_size", 16)
	roster_list.add_child(header)

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	for i in range(MAX_EQUIP_SLOTS):
		var item_id = equipped[i]
		var row := HBoxContainer.new()

		var slot_label := Label.new()
		if item_id == null or item_id == "":
			slot_label.text = "Slot %d: (empty)" % (i + 1)
		else:
			slot_label.text = "Slot %d: %s" % [i + 1, ContentLoader.get_equipment(item_id).get("name", item_id)]
		row.add_child(slot_label)

		if item_id != null and item_id != "":
			var unequip_btn := Button.new()
			unequip_btn.text = "Unequip"
			unequip_btn.pressed.connect(func(): _on_unequip_pressed(i))
			row.add_child(unequip_btn)

			var info_btn := Button.new()
			info_btn.text = "Info"
			info_btn.pressed.connect(func(): _show_item_preview_popup(item_id))
			row.add_child(info_btn)

		roster_list.add_child(row)


func _on_unequip_pressed(slot_index: int) -> void:
	# CHANGED: delegates to _unequip_from_entry() now -- same operation the
	# DeployedPartyContainer's "Manage Inventory" popup uses, just resolved
	# from the currently roster-selected unit instead of an explicit
	# instance_id. Was a second copy of the same logic before.
	var entry := _get_selected_entry()
	if entry.is_empty():
		return
	_unequip_from_entry(entry.get("instance_id", ""), slot_index)


# ADDED: the 4-slot "who's actually deploying" strip, mirroring DraftScene's
# SelectedPartyContainer. Always shows exactly 4 slots -- filled ones show
# the unit's portrait/name and open an action popup (Remove from Party /
# Manage Inventory) when clicked; empty ones open a picker of currently-
# undeployed units to fill that exact slot.
func _rebuild_deployed_party_slots() -> void:
	if deployed_party_container == null:
		return
	for child in deployed_party_container.get_children():
		child.queue_free()

	var portrait_size := Vector2i(48, 48)
	var roster := _get_full_roster()
	for i in range(4):
		# ADDED: each slot is now a small vertical stack -- portrait on top,
		# the existing name/click button underneath -- instead of just the
		# bare button.
		var slot_column := VBoxContainer.new()
		slot_column.alignment = BoxContainer.ALIGNMENT_CENTER

		var portrait_rect := TextureRect.new()
		portrait_rect.custom_minimum_size = Vector2(portrait_size)
		portrait_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

		var slot_btn := Button.new()
		slot_btn.custom_minimum_size = Vector2(120, 40)

		var instance_id: String = deployed_instance_ids[i]
		if instance_id != "":
			var entry: Dictionary = {}
			for candidate in roster:
				if candidate.get("instance_id", "") == instance_id:
					entry = candidate
					break
			var unit_data := _load_unit_data(entry.get("unit_id", "")) if not entry.is_empty() else null
			var label: String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")
			slot_btn.text = label
			slot_btn.pressed.connect(func(): _on_deployed_slot_pressed(i))
			# Same fallback-to-black-box pattern used everywhere else a
			# portrait/icon might be missing (see unit_info_popup.gd).
			portrait_rect.texture = UnitInfoPopup.texture_or_black_box(
				unit_data.portrait if unit_data != null else null, portrait_size)
		else:
			# CHANGED: empty slots are no longer dead/disabled -- tapping one
			# now opens a picker of currently-undeployed units to fill THIS
			# specific slot with (see _on_deployed_slot_pressed /
			# _show_deploy_picker_for_slot).
			slot_btn.text = "+ Deploy"
			slot_btn.pressed.connect(func(): _on_deployed_slot_pressed(i))
			portrait_rect.visible = false   # nothing to show a portrait of yet

		slot_column.add_child(portrait_rect)
		slot_column.add_child(slot_btn)
		deployed_party_container.add_child(slot_column)


func _on_deployed_slot_pressed(slot_index: int) -> void:
	if deployed_instance_ids[slot_index] != "":
		# CHANGED: used to remove the unit immediately on click. Now shows
		# an action popup instead -- "Remove from Party" does what the old
		# immediate click did, "Manage Inventory" opens a dedicated popup
		# for unequipping/equipping THIS unit's gear without leaving the
		# deployed-party strip.
		_show_deployed_slot_action_popup(slot_index)
	else:
		# Empty -- show which units can fill this slot.
		_show_deploy_picker_for_slot(slot_index)


func _show_deployed_slot_action_popup(slot_index: int) -> void:
	var instance_id: String = deployed_instance_ids[slot_index]
	var entry: Dictionary = {}
	for candidate in _get_full_roster():
		if candidate.get("instance_id", "") == instance_id:
			entry = candidate
			break
	if entry.is_empty():
		return
	var unit_data := _load_unit_data(entry.get("unit_id", ""))
	var label: String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")

	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = label
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var remove_btn := Button.new()
	remove_btn.text = "Remove from Party"
	remove_btn.pressed.connect(func():
		popup.queue_free()
		deployed_instance_ids[slot_index] = ""
		_rebuild_roster()
	)
	vbox.add_child(remove_btn)

	var manage_btn := Button.new()
	manage_btn.text = "Manage Inventory"
	manage_btn.pressed.connect(func():
		popup.queue_free()
		_show_manage_inventory_popup(instance_id)
	)
	vbox.add_child(manage_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(cancel_btn)

	popup.popup_centered(Vector2(240, 200))


# ADDED: lets a unit's equipment be unequipped, or an open slot filled,
# entirely from the deployed-party strip -- doesn't require pressing
# "Manage Equipment" in the roster list first.
func _show_manage_inventory_popup(instance_id: String) -> void:
	var entry: Dictionary = {}
	for candidate in _get_full_roster():
		if candidate.get("instance_id", "") == instance_id:
			entry = candidate
			break
	if entry.is_empty():
		return

	var unit_data := _load_unit_data(entry.get("unit_id", ""))
	var label: String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")

	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = label + "'s Equipment"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	for i in range(MAX_EQUIP_SLOTS):
		var item_id = equipped[i]
		var row := HBoxContainer.new()

		if item_id == null or item_id == "":
			var empty_btn := Button.new()
			empty_btn.text = "Slot %d: (empty) -- tap to equip" % (i + 1)
			empty_btn.pressed.connect(func():
				popup.queue_free()
				_show_equip_item_picker_for_slot(instance_id, i)
			)
			row.add_child(empty_btn)
		else:
			var slot_label := Label.new()
			slot_label.text = "Slot %d: %s" % [i + 1, ContentLoader.get_equipment(item_id).get("name", item_id)]
			row.add_child(slot_label)

			var unequip_btn := Button.new()
			unequip_btn.text = "Unequip"
			unequip_btn.pressed.connect(func():
				popup.queue_free()
				_unequip_from_entry(instance_id, i)
			)
			row.add_child(unequip_btn)

			var info_btn := Button.new()
			info_btn.text = "Info"
			info_btn.pressed.connect(func(): _show_item_preview_popup(item_id))
			row.add_child(info_btn)

		vbox.add_child(row)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(close_btn)

	popup.popup_centered(Vector2(300, 260))


# ADDED: the item list shown after tapping an empty slot in the popup above.
# Reuses the same "is a copy actually free" accounting the forge picker
# uses, so an item currently sitting in a forge slot can't also be equipped
# from here.
func _show_equip_item_picker_for_slot(instance_id: String, slot_index: int) -> void:
	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Equip to Slot %d:" % (slot_index + 1)
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var seen_ids := {}
	var any_available := false
	for item_id in RunManager.current_run.equipment_inventory:
		if seen_ids.has(item_id):
			continue
		seen_ids[item_id] = true
		if not _has_unreserved_copy(item_id):
			continue
		any_available = true

		var item_btn := Button.new()
		item_btn.text = ContentLoader.get_equipment(item_id).get("name", item_id)
		item_btn.pressed.connect(func():
			popup.queue_free()
			_equip_item_to_slot(instance_id, slot_index, item_id)
		)
		vbox.add_child(item_btn)

	if not any_available:
		var empty_label := Label.new()
		empty_label.text = "(no items available)"
		vbox.add_child(empty_label)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(cancel_btn)

	popup.popup_centered(Vector2(260, 320))


func _equip_item_to_slot(instance_id: String, slot_index: int, item_id: String) -> void:
	var entry: Dictionary = {}
	for candidate in _get_full_roster():
		if candidate.get("instance_id", "") == instance_id:
			entry = candidate
			break
	if entry.is_empty():
		return

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	equipped[slot_index] = item_id
	RunManager.current_run.equipment_inventory.erase(item_id)
	entry["equipped_item_ids"] = equipped
	RunManager.save_run()
	_rebuild_roster()
	_rebuild_inventory()


func _unequip_from_entry(instance_id: String, slot_index: int) -> void:
	var entry: Dictionary = {}
	for candidate in _get_full_roster():
		if candidate.get("instance_id", "") == instance_id:
			entry = candidate
			break
	if entry.is_empty():
		return

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)
	if equipped[slot_index] == null or equipped[slot_index] == "":
		return

	RunManager.current_run.equipment_inventory.append(equipped[slot_index])
	equipped[slot_index] = null
	entry["equipped_item_ids"] = equipped
	RunManager.save_run()
	_rebuild_roster()
	_rebuild_inventory()


func _show_deploy_picker_for_slot(slot_index: int) -> void:
	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Deploy to this slot:"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	# Only units not CURRENTLY occupying any of the 4 slots are offered --
	# a unit deployed in another slot has to be removed from there first
	# (clicking their slot) before they can show up here.
	var any_available := false
	for entry in _get_full_roster():
		var instance_id: String = entry.get("instance_id", "")
		if instance_id in deployed_instance_ids:
			continue
		any_available = true
		var unit_data := _load_unit_data(entry.get("unit_id", ""))
		var label: String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")

		var pick_btn := Button.new()
		pick_btn.text = label + " (Lv " + str(entry.get("level", 1)) + ")"
		pick_btn.pressed.connect(func():
			deployed_instance_ids[slot_index] = instance_id
			popup.queue_free()
			_rebuild_roster()
		)
		vbox.add_child(pick_btn)

	if not any_available:
		var empty_label := Label.new()
		empty_label.text = "(every other unit is already deployed)"
		vbox.add_child(empty_label)

	var close_btn := Button.new()
	close_btn.text = "Cancel"
	close_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(close_btn)

	popup.popup_centered(Vector2(260, 300))


func _on_roster_toggle_pressed(instance_id: String) -> void:
	if instance_id in deployed_instance_ids:
		deployed_instance_ids[deployed_instance_ids.find(instance_id)] = ""
	else:
		var empty_slot: int = deployed_instance_ids.find("")
		if empty_slot == -1:
			print("⛔ You can only deploy up to 4 units. Deselect one first.")
			return
		deployed_instance_ids[empty_slot] = instance_id
	_rebuild_roster()


func _deployed_count() -> int:
	var count := 0
	for id in deployed_instance_ids:
		if id != "":
			count += 1
	return count


func _on_roster_entry_pressed(index: int) -> void:
	_selected_party_index = index
	_rebuild_roster()


func _get_selected_entry() -> Dictionary:
	var roster := _get_full_roster()
	if _selected_party_index < 0 or _selected_party_index >= roster.size():
		return {}
	return roster[_selected_party_index]


# ── MORE INFORMATION POPUP ────────────────────────────────────────────────────
# Reuses the same UnitInfoPopup class the Draft screen and in-battle
# "Information" button use (see unit_info_popup.gd) -- this is exactly what
# that class's own header comment describes it for: any screen just builds
# stat_lines + equipped_item_entries that make sense for its situation and
# hands them to the same popup.

func _on_more_info_pressed(index: int) -> void:
	var roster := _get_full_roster()
	if index < 0 or index >= roster.size():
		return
	var entry: Dictionary = roster[index]
	var unit_data := _load_unit_data(entry.get("unit_id", ""))
	if unit_data == null:
		return

	var level: int = int(entry.get("level", 1))
	var stats_index: int = clamp(level - 1, 0, unit_data.stats_by_level.size() - 1)
	if unit_data.stats_by_level.is_empty():
		return
	var stats: StatsData = unit_data.stats_by_level[stats_index]

	# Base stats at this unit's current level -- NOT live battle numbers
	# (there's no live battle here), same idea as how the Draft screen shows
	# level-1 base numbers.
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

	# CHANGED: pulls each equipped item's FULL raw equipment Dictionary
	# (icon, name, effects, description) via ContentLoader.get_equipment(),
	# same shape live battle passes in via unit.equipped_items -- so
	# unit_info_popup.gd's new stat-line/description rendering works here too.
	var equipped_entries: Array = []
	for item_id in entry.get("equipped_item_ids", []):
		if item_id == null or item_id == "":
			continue
		equipped_entries.append(ContentLoader.get_equipment(item_id))

	var popup_instance := UnitInfoPopup.new()
	add_child(popup_instance)
	popup_instance.setup(unit_data, stat_lines, equipped_entries)


# ── BIOME BACKGROUND ───────────────────────────────────────────────────────────

func _setup_deployment_background() -> void:
	if RunManager.current_run == null or background_texture == null:
		return

	var biome := "forest"
	if RunManager.current_run.biome_sequence.size() > 0:
		var slot := ContentLoader.get_biome_slot(RunManager.current_run.stage_index)
		if slot < RunManager.current_run.biome_sequence.size():
			biome = RunManager.current_run.biome_sequence[slot]

	# Reuses battle_scene.gd's existing BIOME_BACKGROUNDS table instead of
	# keeping a second copy here that could drift out of sync -- it's a
	# top-level const, so it's readable straight off the script itself
	# without needing to instantiate BattleScene.
	var battle_scene_script := preload("res://scripts/battle/battle_scene.gd")
	var biome_backgrounds: Dictionary = battle_scene_script.BIOME_BACKGROUNDS
	if not biome_backgrounds.has(biome):
		biome = "forest"

	var available: Array = biome_backgrounds.get(biome, [])
	if available.is_empty():
		return

	var chosen_path: String = available[randi() % available.size()]
	var texture_resource = load(chosen_path)
	if texture_resource:
		background_texture.texture = texture_resource


# ── AMBIENT BACKGROUND PREVIEW ────────────────────────────────────────────────

@export var min_preview_separation: float = 70.0
# Minimum distance kept between any two wandering units' spawn points, so
# they never render on top of (or overlapping) each other. Raise this if
# sprite_scale is bigger, or if they still look cramped for your preview_bounds.


func _spawn_unit_previews() -> void:
	if preview_layer == null or not ResourceLoader.exists(UNIT_PREVIEW_SCENE_PATH):
		printerr("❌ DeploymentScene: PreviewLayer node or DeploymentUnitPreview.tscn is missing -- skipping ambient previews.")
		return

	var preview_scene: PackedScene = load(UNIT_PREVIEW_SCENE_PATH)
	var placed_positions: Array[Vector2] = []

	for entry in _get_full_roster():
		if entry == null:
			continue
		var unit_data := _load_unit_data(entry.get("unit_id", ""))
		if unit_data == null:
			continue

		var preview := preview_scene.instantiate() as DeploymentUnitPreview
		preview_layer.add_child(preview)

		var start_pos := _pick_non_overlapping_spawn_pos(placed_positions)
		placed_positions.append(start_pos)
		preview.setup(unit_data, start_pos, preview_bounds)


func _pick_non_overlapping_spawn_pos(placed_positions: Array[Vector2]) -> Vector2:
	const MAX_ATTEMPTS := 30
	var candidate := Vector2.ZERO
	for attempt in range(MAX_ATTEMPTS):
		candidate = Vector2(
			randf_range(preview_bounds.position.x, preview_bounds.position.x + preview_bounds.size.x),
			randf_range(preview_bounds.position.y, preview_bounds.position.y + preview_bounds.size.y)
		)
		var far_enough := true
		for existing in placed_positions:
			if candidate.distance_to(existing) < min_preview_separation:
				far_enough = false
				break
		if far_enough:
			return candidate
	# Ran out of attempts -- preview_bounds is probably too small for this many
	# units at this separation. Use the last candidate anyway rather than
	# looping forever or leaving a unit unspawned; widen preview_bounds or
	# lower min_preview_separation in the Inspector if this keeps happening.
	return candidate


# ── INVENTORY ──────────────────────────────────────────────────────────────────


# ADDED: shared accounting for "how many copies of this item does the
# player actually have free to use elsewhere" -- items sitting in a forge
# slot stay physically in equipment_inventory now (see the bugfix note on
# _set_forge_slot below) rather than being removed, so anything offering
# items for equip/forge needs to know how many copies are already spoken
# for by the forge slots specifically.
func _count_owned(item_id: String) -> int:
	var count := 0
	for owned_id in RunManager.current_run.equipment_inventory:
		if owned_id == item_id:
			count += 1
	return count


func _count_reserved_for_forge(item_id: String) -> int:
	var count := 0
	if _forge_slot_a == item_id:
		count += 1
	if _forge_slot_b == item_id:
		count += 1
	return count


func _has_unreserved_copy(item_id: String) -> bool:
	return _count_reserved_for_forge(item_id) < _count_owned(item_id)


func _rebuild_inventory() -> void:
	for child in inventory_list.get_children():
		child.queue_free()

	# Items currently sitting in a forge slot are shown there instead of
	# here (see ForgeRow), even though they're still physically present in
	# equipment_inventory -- hide exactly as many copies as are reserved,
	# not every copy of that item_id, so owning multiple copies still shows
	# the spare ones correctly.
	var to_hide := {}
	for reserved_id in [_forge_slot_a, _forge_slot_b]:
		if reserved_id != "":
			to_hide[reserved_id] = to_hide.get(reserved_id, 0) + 1

	for item_id in RunManager.current_run.equipment_inventory:
		if to_hide.get(item_id, 0) > 0:
			to_hide[item_id] -= 1
			continue

		# CHANGED: consumables used to be skipped here under the assumption
		# they lived in a separate "combat item bar" bag -- but potions
		# actually equip into the SAME equipped_item_ids slots as basic/
		# advanced gear (that's what battle_scene.gd's Items popup reads
		# from), so they need to go through this same equip flow too.
		var item_data: Dictionary = ContentLoader.get_equipment(item_id)

		# ADDED: an "Info" button next to every inventory row, so players can
		# see what an item does right here before equipping/forging it.
		var row := HBoxContainer.new()

		var btn := Button.new()
		btn.text = item_data.get("name", item_id)
		btn.pressed.connect(func(): _on_inventory_item_pressed(item_id))
		row.add_child(btn)

		var info_btn := Button.new()
		info_btn.text = "Info"
		info_btn.pressed.connect(func(): _show_item_preview_popup(item_id))
		row.add_child(info_btn)

		inventory_list.add_child(row)


# CHANGED: clicking an item used to "pick it up" (a lingering selection you'd
# then click a destination -- an equip slot or a forge Set button -- to
# resolve), shown with a "[Selected] " prefix. Replaced with a popup offering
# the 2 actions directly: Equip (pick which unit) or Combine (send it to an
# open forge slot). No more in-between state to track.
func _on_inventory_item_pressed(item_id: String) -> void:
	var data: Dictionary = ContentLoader.get_equipment(item_id)

	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = data.get("name", item_id)
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var equip_btn := Button.new()
	equip_btn.text = "Equip"
	equip_btn.pressed.connect(func():
		popup.queue_free()
		_show_equip_unit_picker(item_id)
	)
	vbox.add_child(equip_btn)

	var combine_btn := Button.new()
	combine_btn.text = "Combine"
	combine_btn.pressed.connect(func():
		popup.queue_free()
		_combine_item_into_forge(item_id)
	)
	vbox.add_child(combine_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(cancel_btn)

	popup.popup_centered(Vector2(220, 200))


# ADDED: the unit list shown after pressing "Equip" in the popup above.
# Equips to the first open slot on whichever unit you pick; if that unit has
# no open slot, shows a message instead of guessing which of their 3 items
# to bump.
func _show_equip_unit_picker(item_id: String) -> void:
	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Equip " + ContentLoader.get_equipment(item_id).get("name", item_id) + " to:"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	for entry in _get_full_roster():
		var unit_data := _load_unit_data(entry.get("unit_id", ""))
		var label: String = unit_data.display_name if unit_data != null else entry.get("unit_id", "?")
		var instance_id: String = entry.get("instance_id", "")

		var unit_btn := Button.new()
		unit_btn.text = label + " (Lv " + str(entry.get("level", 1)) + ")"
		unit_btn.pressed.connect(func():
			popup.queue_free()
			_equip_item_to_unit(item_id, instance_id)
		)
		vbox.add_child(unit_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(cancel_btn)

	popup.popup_centered(Vector2(260, 320))


func _equip_item_to_unit(item_id: String, instance_id: String) -> void:
	var target_entry: Dictionary = {}
	for entry in _get_full_roster():
		if entry.get("instance_id", "") == instance_id:
			target_entry = entry
			break
	if target_entry.is_empty():
		return

	var equipped: Array = target_entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	var empty_slot := -1
	for i in range(MAX_EQUIP_SLOTS):
		if equipped[i] == null or equipped[i] == "":
			empty_slot = i
			break

	if empty_slot == -1:
		_show_message_popup("No Equip Slot Available")
		return

	equipped[empty_slot] = item_id
	RunManager.current_run.equipment_inventory.erase(item_id)
	target_entry["equipped_item_ids"] = equipped
	RunManager.save_run()
	_rebuild_roster()
	_rebuild_inventory()


# ADDED: a small reusable "OK" message popup, used for the "No Equip Slot
# Available" / "No Forge Slot Available" feedback.
func _show_message_popup(message: String) -> void:
	var popup := AcceptDialog.new()
	popup.dialog_text = message
	add_child(popup)
	popup.popup_centered()
	popup.confirmed.connect(func(): popup.queue_free())
	popup.canceled.connect(func(): popup.queue_free())


# ── FORGING ────────────────────────────────────────────────────────────────────
# Pick two BASIC equipment items from inventory (type == "basic") and combine
# them via ContentLoader's forging_recipes.json -- the same lookup equipping
# and combat already use, so forged items work immediately, unlike the old
# BasicEquipmentData-based forge this replaces.

func _combine_item_into_forge(item_id: String) -> void:
	if not _is_basic_item(item_id):
		_show_message_popup("Only basic equipment can be combined for forging.")
		return
	if not _has_unreserved_copy(item_id):
		_show_message_popup("You don't have another copy of that item available.")
		return

	# Make the Forge panel visible if it was hidden, since you're about to
	# see feedback (the item landing in a slot, or the status label) appear
	# inside it.
	if not equip_panel.visible:
		equip_panel.visible = true
		_update_tab_button_text(forge_tab_button, "Forge", true)

	if _forge_slot_a == "":
		_set_forge_slot(true, item_id)
	elif _forge_slot_b == "":
		_set_forge_slot(false, item_id)
	else:
		_show_message_popup("No Forge Slot Available")


# ADDED: assigns an item to a forge slot and refreshes everything that
# depends on it. Shared by Combine (from the inventory item popup) and the
# new forge-slot item picker (clicking an empty ForgeSlotAButton/
# ForgeSlotBButton directly).
func _set_forge_slot(is_slot_a: bool, item_id: String) -> void:
	if is_slot_a:
		_forge_slot_a = item_id
		forge_slot_a_button.text = "A: " + ContentLoader.get_equipment(item_id).get("name", item_id)
	else:
		_forge_slot_b = item_id
		forge_slot_b_button.text = "B: " + ContentLoader.get_equipment(item_id).get("name", item_id)

	# BUGFIX: an item used to be erased from equipment_inventory the instant
	# it landed in a forge slot, to stop the same physical copy being placed
	# into BOTH slot A and slot B. But _forge_slot_a/_forge_slot_b only live
	# on this DeploymentScene NODE, not on the saved run -- so entering
	# combat (which frees this scene entirely) and coming back for the next
	# stage reset them to "", and whatever item had been "in the forge" was
	# gone for good: never in the bag, never actually forged, nowhere.
	# Items now stay in equipment_inventory the whole time they're sitting
	# in a forge slot -- they're just hidden from the visible list instead
	# (see _rebuild_inventory()) -- and the double-placement problem is
	# prevented by _has_unreserved_copy()'s counting instead. One side
	# effect: your forge slot picks don't persist across a stage transition
	# (nothing saves them) -- but the ITEMS themselves can never be lost,
	# since they were never removed from the bag in the first place.
	_rebuild_inventory()
	_update_forge_preview()


# ADDED: clicking a forge slot button now does one of two things -- clears
# it if it's filled, or (new) opens a picker of eligible items if it's
# empty, so you don't have to go back to the inventory list to fill a slot.
func _on_forge_slot_pressed(is_slot_a: bool) -> void:
	var current_id: String = _forge_slot_a if is_slot_a else _forge_slot_b
	if current_id != "":
		_clear_forge_slot(is_slot_a)
	else:
		_show_forge_item_picker(is_slot_a)


func _clear_forge_slot(is_slot_a: bool) -> void:
	var item_id: String = _forge_slot_a if is_slot_a else _forge_slot_b
	if item_id == "":
		return
	# CHANGED: no longer returns the item to equipment_inventory -- it was
	# never removed from there in the first place now (see _set_forge_slot's
	# bugfix note). Doing so here would duplicate it.
	if is_slot_a:
		_forge_slot_a = ""
		forge_slot_a_button.text = "A: (empty)"
	else:
		_forge_slot_b = ""
		forge_slot_b_button.text = "B: (empty)"
	_rebuild_inventory()
	_update_forge_preview()


# ADDED: the list shown when tapping an EMPTY forge slot directly.
# Consumables are excluded entirely -- only "basic" equipment can ever go
# into a forge slot -- and each distinct item is listed once even if you
# own several copies.
func _show_forge_item_picker(is_slot_a: bool) -> void:
	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Add to Forge Slot %s:" % ("A" if is_slot_a else "B")
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var seen_ids := {}
	var any_available := false
	for item_id in RunManager.current_run.equipment_inventory:
		if seen_ids.has(item_id):
			continue
		seen_ids[item_id] = true
		if not _is_basic_item(item_id):
			continue
		if not _has_unreserved_copy(item_id):
			continue
		any_available = true

		var item_btn := Button.new()
		item_btn.text = ContentLoader.get_equipment(item_id).get("name", item_id)
		item_btn.pressed.connect(func():
			popup.queue_free()
			_set_forge_slot(is_slot_a, item_id)
		)
		vbox.add_child(item_btn)

	if not any_available:
		var empty_label := Label.new()
		empty_label.text = "(no basic equipment available)"
		vbox.add_child(empty_label)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(cancel_btn)

	popup.popup_centered(Vector2(260, 320))


func _is_basic_item(item_id: String) -> bool:
	return item_id != "" and ContentLoader.get_equipment(item_id).get("type", "") == "basic"


# CHANGED (new): shows each set slot's stats/description, and -- once both
# slots match a real recipe -- the resulting advanced item's stats and
# description too, so you know what you're about to make before forging.
# Reuses UnitInfoPopup._describe_effect() rather than reimplementing the
# same "+2 Atk" style formatting a second time.
func _update_forge_preview() -> void:
	if forge_preview_label == null:
		return

	var lines: Array[String] = []
	lines.append(_describe_item_for_preview("A", _forge_slot_a))
	lines.append(_describe_item_for_preview("B", _forge_slot_b))

	if _forge_slot_a != "" and _forge_slot_b != "":
		var subtype_a: String = ContentLoader.get_equipment(_forge_slot_a).get("subtype", "")
		var subtype_b: String = ContentLoader.get_equipment(_forge_slot_b).get("subtype", "")
		var recipe: Dictionary = ContentLoader.get_forging_recipe(subtype_a, subtype_b)
		if not recipe.is_empty():
			lines.append("")
			lines.append(_describe_item_for_preview("Will forge into", recipe.get("output_equipment_id", "")))

	forge_preview_label.bbcode_enabled = true
	forge_preview_label.text = "\n".join(lines)


func _describe_item_for_preview(label: String, item_id: String) -> String:
	if item_id == "":
		return "[b]%s:[/b] (empty)" % label

	var data: Dictionary = ContentLoader.get_equipment(item_id)
	var name: String = data.get("name", item_id)

	var effect_lines: Array[String] = []
	for effect in data.get("effects", []):
		var described: String = UnitInfoPopup._describe_effect(effect)
		if described != "":
			effect_lines.append(described)

	var text := "[b]%s: %s[/b]" % [label, name]
	if not effect_lines.is_empty():
		text += "\n" + ", ".join(effect_lines)
	var description: String = data.get("description", "")
	if description != "":
		text += "\n" + description
	return text


# CHANGED (new): a dedicated popup button, separate from the inline
# forge_preview_label text -- shows the resulting item's icon, stats, and
# description in a bigger, standalone popup before you commit to forging.
func _on_forge_preview_pressed() -> void:
	if _forge_slot_a == "" or _forge_slot_b == "":
		forge_status_label.text = "Set both Slot A and Slot B first to preview."
		return

	var subtype_a: String = ContentLoader.get_equipment(_forge_slot_a).get("subtype", "")
	var subtype_b: String = ContentLoader.get_equipment(_forge_slot_b).get("subtype", "")
	var recipe: Dictionary = ContentLoader.get_forging_recipe(subtype_a, subtype_b)

	if recipe.is_empty():
		forge_status_label.text = "No recipe matches '%s' + '%s'." % [subtype_a, subtype_b]
		return

	_show_item_preview_popup(recipe.get("output_equipment_id", ""))


func _show_item_preview_popup(item_id: String) -> void:
	var data: Dictionary = ContentLoader.get_equipment(item_id)

	var popup := PopupPanel.new()
	add_child(popup)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(280, 0)
	margin.add_child(vbox)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	# Same icon-string-vs-Texture2D issue fixed in unit_info_popup.gd applies
	# here too, since this also reads a raw equipment Dictionary --
	# UnitInfoPopup._resolve_icon() is reused rather than duplicating that
	# fix a second time.
	var icon_rect := TextureRect.new()
	icon_rect.custom_minimum_size = Vector2(48, 48)
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.texture = UnitInfoPopup.texture_or_black_box(
		UnitInfoPopup._resolve_icon(data.get("icon")), Vector2i(48, 48))
	header.add_child(icon_rect)

	var name_label := Label.new()
	name_label.text = data.get("name", item_id)
	name_label.add_theme_font_size_override("font_size", 20)
	header.add_child(name_label)

	var effect_lines: Array[String] = []
	for effect in data.get("effects", []):
		var described: String = UnitInfoPopup._describe_effect(effect)
		if described != "":
			effect_lines.append(described)
	if not effect_lines.is_empty():
		var stats_label := Label.new()
		stats_label.text = ", ".join(effect_lines)
		stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(stats_label)

	var description: String = data.get("description", "")
	if description != "":
		var desc_label := Label.new()
		desc_label.text = description
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(desc_label)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(close_btn)

	popup.popup_centered(Vector2(320, 220))


func _on_forge_pressed() -> void:
	if _forge_slot_a == "" or _forge_slot_b == "":
		forge_status_label.text = "Set both Slot A and Slot B first."
		return

	var subtype_a: String = ContentLoader.get_equipment(_forge_slot_a).get("subtype", "")
	var subtype_b: String = ContentLoader.get_equipment(_forge_slot_b).get("subtype", "")
	var recipe: Dictionary = ContentLoader.get_forging_recipe(subtype_a, subtype_b)

	if recipe.is_empty():
		# Shows exactly what was looked up, instead of a generic "no recipe" --
		# if this says something like "monocle_of_health" instead of
		# "monocle_talisman", the item's "subtype" field doesn't match what
		# forging_recipes.json expects (see the notes below).
		forge_status_label.text = "No recipe matches '%s' + '%s'." % [subtype_a, subtype_b]
		return

	var output_id: String = recipe.get("output_equipment_id", "")
	# CHANGED: items are no longer removed from equipment_inventory at
	# Combine time (see _set_forge_slot's bugfix note) -- they only actually
	# leave the bag now, right here, at the moment forging actually happens.
	RunManager.current_run.equipment_inventory.erase(_forge_slot_a)
	RunManager.current_run.equipment_inventory.erase(_forge_slot_b)
	RunManager.current_run.equipment_inventory.append(output_id)

	_forge_slot_a = ""
	_forge_slot_b = ""
	forge_slot_a_button.text = "A: (empty)"
	forge_slot_b_button.text = "B: (empty)"
	forge_status_label.text = "Forged: " + ContentLoader.get_equipment(output_id).get("name", output_id) + "!"
	_update_forge_preview()
	RunManager.save_run()
	_rebuild_inventory()


# ── SCOUT AHEAD ────────────────────────────────────────────────────────────────
# Unchanged -- this already used the real RunManager/StageDirector API.

func _update_scout_button() -> void:
	var upcoming_stage = RunManager.get_upcoming_stage_index()
	var upcoming_type = RunManager.get_stage_type_for_index(upcoming_stage)
	# BUGFIX: "subboss" is a combat-shaped stage type -- it routes to
	# BattleScene exactly like combat/special_combat/boss do (see stage_
	# director.gd's SCENE_FOR_STAGE_TYPE) -- but was missing from this list,
	# so subboss stages incorrectly showed Scout Ahead as unavailable.
	# "encounter" is intentionally NOT in this list (see bug report: scouting
	# should never be selectable for encounters).
	var scoutable = upcoming_type in ["combat", "special_combat", "subboss", "boss"]
	scout_button.disabled = not scoutable
	scout_button.text = ("Scout Ahead (%d gold)" % RunManager.get_scout_cost()) if scoutable \
		else "Scout Ahead (Not Available)"


func _on_scout_pressed() -> void:
	var cost = RunManager.get_scout_cost()
	if not RunManager.spend_gold(cost):
		print("⛔ Not enough gold to scout ahead.")
		return
	RunManager.save_run()

	var upcoming_stage = RunManager.get_upcoming_stage_index()
	var content = StageDirector.get_or_generate_stage_content(upcoming_stage)
	scout_text.text = _format_scout_report(content)
	if scout_map_view != null:
		scout_map_view.setup(content)
	scout_panel.visible = true


func _on_scout_enter_combat_pressed() -> void:
	# Skips back to the main DeploymentScene screen entirely -- the player
	# already reviewed the map/enemies here, so this jumps straight into the
	# stage StageDirector already advanced to.
	scout_panel.visible = false
	StageDirector.enter_current_stage()


func _format_scout_report(content: Dictionary) -> String:
	# CHANGED: the ASCII map is gone -- ScoutMapView (a Control with its own
	# _draw()) now renders the actual layout visually instead. This text just
	# covers stage type/biome/enemy list.
	var report = "[b]Stage Type:[/b] %s\n[b]Biome:[/b] %s\n\n" % [content["stage_type"], content["biome"]]
	report += "[b]Enemies (%d):[/b]\n" % content["enemies"].size()
	for enemy in content["enemies"]:
		report += "- %s (%s tier)\n" % [enemy.display_name, enemy.tier]
	return report


# ── CONTINUE ─────────────────────────────────────────────────────────────────

func _on_continue_pressed() -> void:
	if _deployed_count() == 0:
		print("⛔ Select at least 1 unit to deploy before continuing.")
		return

	var full_roster = _get_full_roster()
	var new_party: Array = []
	var new_bench: Array = []
	for entry in full_roster:
		if entry == null:
			continue
		if entry.get("instance_id", "") in deployed_instance_ids:
			new_party.append(entry)
		else:
			new_bench.append(entry)

	RunManager.current_run.party = new_party
	RunManager.current_run.bench = new_bench

	# CHANGED: removed a reference to a RunManager field
	# (stage_content_completed_for_current_stage) that was never actually
	# declared anywhere in the project -- accessing it crashed this function
	# right here, before save_run() ever ran. It's also unnecessary:
	# StageDirector.complete_stage() already called advance_stage() once,
	# right when the PREVIOUS stage ended, before routing here. So by the
	# time Continue is pressed, current_run.stage_index is already correct
	# -- this just needs to persist the team/equipment choices and go.
	RunManager.save_run()

	# CHANGED: StageDirector already owns the stage_type -> scene mapping
	# (SCENE_FOR_STAGE_TYPE), so route through it instead of a
	# RunManager function that duplicated the same lookup.
	StageDirector.enter_current_stage()
