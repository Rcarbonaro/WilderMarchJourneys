# res://scripts/deployment/deployment_manager.gd
#
# Attached to the ROOT node of DeploymentScene.tscn (see the README for the
# exact node tree this expects). The hub the player lands on after every
# battle/encounter, and where a new run starts.
#   1. Pick up to 4 units (from party + bench combined) to deploy.
#   2. Equip/unequip items on whichever unit is selected, and forge two
#      basic items together if a matching recipe exists.
#   3. Scout Ahead: preview the exact upcoming map/enemies before deploying,
#      for combat/special_combat/boss stages only.

extends Node2D

@onready var roster_list: VBoxContainer     = $RosterScroll/RosterList
@onready var selected_unit_label: Label     = $EquipPanel/SelectedUnitLabel
@onready var slots_container: HBoxContainer = $EquipPanel/SlotsContainer
@onready var forge_slot_a_label: Label      = $EquipPanel/ForgeRow/ForgeSlotALabel
@onready var forge_slot_b_label: Label      = $EquipPanel/ForgeRow/ForgeSlotBLabel
@onready var set_slot_a_button: Button      = $EquipPanel/ForgeRow/SetSlotAButton
@onready var set_slot_b_button: Button      = $EquipPanel/ForgeRow/SetSlotBButton
@onready var forge_button: Button           = $EquipPanel/ForgeRow/ForgeButton
@onready var forge_status_label: Label      = $EquipPanel/ForgeRow/ForgeStatusLabel
@onready var inventory_list: VBoxContainer  = $InventoryScroll/InventoryList
@onready var shop_button: Button            = $ShopButton
@onready var continue_button: Button        = $ContinueButton
@onready var scout_button: Button           = $ScoutButton
@onready var scout_panel: PanelContainer    = $ScoutPanel
@onready var scout_text: RichTextLabel      = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutText
@onready var scout_close_button: Button     = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutCloseButton

var deployed_ids: Array[String] = []
var selected_unit_for_equip = null
var selected_inventory_item = null
var forge_slot_a = null
var forge_slot_b = null


func _ready() -> void:
	shop_button.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/meta/ShopScene.tscn"))
	continue_button.pressed.connect(_on_continue_pressed)
	set_slot_a_button.pressed.connect(_on_set_slot_a_pressed)
	set_slot_b_button.pressed.connect(_on_set_slot_b_pressed)
	forge_button.pressed.connect(_on_forge_pressed)
	scout_button.pressed.connect(_on_scout_pressed)
	scout_close_button.pressed.connect(func(): scout_panel.visible = false)
	scout_panel.visible = false

	if RunManager.current_run == null:
		printerr("❌ DeploymentScene: no active run found.")
		return

	for unit in RunManager.current_run.party:
		if unit != null and "id" in unit:
			deployed_ids.append(unit.id)

	_rebuild_roster()
	_rebuild_inventory()
	_clear_equip_panel()
	_update_scout_button()


# ── ROSTER ──────────────────────────────────────────────────────────────────

func _get_full_roster() -> Array:
	var roster: Array = []
	roster.append_array(RunManager.current_run.party)
	roster.append_array(RunManager.current_run.bench)
	return roster


func _rebuild_roster() -> void:
	for child in roster_list.get_children():
		child.queue_free()

	for unit in _get_full_roster():
		if unit == null:
			continue
		var row = HBoxContainer.new()

		var toggle_btn = Button.new()
		toggle_btn.text = ("[Deployed] " if unit.id in deployed_ids else "[ ] ") + unit.display_name
		toggle_btn.pressed.connect(func(): _on_roster_toggle_pressed(unit))
		row.add_child(toggle_btn)

		var equip_btn = Button.new()
		equip_btn.text = "Manage Equipment"
		equip_btn.pressed.connect(func(): _select_unit_for_equip(unit))
		row.add_child(equip_btn)

		roster_list.add_child(row)


func _on_roster_toggle_pressed(unit) -> void:
	if unit.id in deployed_ids:
		deployed_ids.erase(unit.id)
	else:
		if deployed_ids.size() >= 4:
			print("⛔ You can only deploy up to 4 units. Deselect one first.")
			return
		deployed_ids.append(unit.id)
	_rebuild_roster()


# ── EQUIPMENT SLOTS ──────────────────────────────────────────────────────────

func _select_unit_for_equip(unit) -> void:
	selected_unit_for_equip = unit
	selected_unit_label.text = "Equipping: " + unit.display_name
	_rebuild_slots()


func _clear_equip_panel() -> void:
	selected_unit_for_equip = null
	selected_unit_label.text = "Select a unit above to manage its equipment."
	for child in slots_container.get_children():
		child.queue_free()


func _rebuild_slots() -> void:
	for child in slots_container.get_children():
		child.queue_free()
	if selected_unit_for_equip == null:
		return

	var slots: Array = RunManager.get_equipped_slots(selected_unit_for_equip.id)
	for i in range(3):
		var item = slots[i]
		var btn = Button.new()
		btn.text = item.display_name if item != null else "Empty Slot %d" % (i + 1)
		btn.pressed.connect(func(): _on_slot_pressed(i))
		slots_container.add_child(btn)


func _on_slot_pressed(slot_index: int) -> void:
	if selected_unit_for_equip == null:
		return
	var unit_id: String = selected_unit_for_equip.id
	var slots: Array = RunManager.get_equipped_slots(unit_id)

	if selected_inventory_item != null:
		var old_item = slots[slot_index]
		slots[slot_index] = selected_inventory_item
		RunManager.current_run.inventory.erase(selected_inventory_item)
		if old_item != null:
			RunManager.current_run.inventory.append(old_item)
		selected_inventory_item = null
	else:
		if slots[slot_index] != null:
			RunManager.current_run.inventory.append(slots[slot_index])
			slots[slot_index] = null

	RunManager.current_run.equipped_items[unit_id] = slots
	RunManager.save_run()
	_rebuild_slots()
	_rebuild_inventory()


# ── INVENTORY ─────────────────────────────────────────────────────────────────

func _rebuild_inventory() -> void:
	for child in inventory_list.get_children():
		child.queue_free()

	for item in RunManager.current_run.inventory:
		if item == null:
			continue
		var btn = Button.new()
		var prefix = "[Selected] " if item == selected_inventory_item else ""
		btn.text = prefix + item.display_name + " (" + item.get_class() + ")"
		btn.pressed.connect(func(): _on_inventory_item_pressed(item))
		inventory_list.add_child(btn)


func _on_inventory_item_pressed(item) -> void:
	selected_inventory_item = null if selected_inventory_item == item else item
	_rebuild_inventory()


# ── FORGING ──────────────────────────────────────────────────────────────────

func _on_set_slot_a_pressed() -> void:
	if selected_inventory_item is BasicEquipmentData:
		forge_slot_a = selected_inventory_item
		forge_slot_a_label.text = "A: " + forge_slot_a.display_name
		selected_inventory_item = null
		_rebuild_inventory()
	else:
		forge_status_label.text = "Select a BASIC equipment item from inventory first."


func _on_set_slot_b_pressed() -> void:
	if selected_inventory_item is BasicEquipmentData:
		forge_slot_b = selected_inventory_item
		forge_slot_b_label.text = "B: " + forge_slot_b.display_name
		selected_inventory_item = null
		_rebuild_inventory()
	else:
		forge_status_label.text = "Select a BASIC equipment item from inventory first."


func _on_forge_pressed() -> void:
	if forge_slot_a == null or forge_slot_b == null:
		forge_status_label.text = "Set both Slot A and Slot B first."
		return

	var result = EquipmentSystem.forge_equipment(forge_slot_a, forge_slot_b)
	if result == null:
		forge_status_label.text = "No recipe matches that combination."
		return

	RunManager.current_run.inventory.erase(forge_slot_a)
	RunManager.current_run.inventory.erase(forge_slot_b)
	RunManager.current_run.inventory.append(result)
	forge_slot_a = null
	forge_slot_b = null
	forge_slot_a_label.text = "A: (empty)"
	forge_slot_b_label.text = "B: (empty)"
	forge_status_label.text = "Forged: " + result.display_name + "!"
	RunManager.save_run()
	_rebuild_inventory()


# ── SCOUT AHEAD ────────────────────────────────────────────────────────────────

func _update_scout_button() -> void:
	var upcoming_stage = RunManager.get_upcoming_stage_index()
	var upcoming_type = RunManager.get_stage_type_for_index(upcoming_stage)
	var scoutable = upcoming_type in ["combat", "special_combat", "boss"]
	scout_button.disabled = not scoutable
	scout_button.text = ("Scout Ahead (%d gold)" % RunManager.get_scout_cost()) if scoutable \
		else "Scout Ahead (not available — next stage is a %s)" % upcoming_type


func _on_scout_pressed() -> void:
	var cost = RunManager.get_scout_cost()
	if not RunManager.spend_gold(cost):
		print("⛔ Not enough gold to scout ahead.")
		return
	RunManager.save_run()

	var upcoming_stage = RunManager.get_upcoming_stage_index()
	var content = StageDirector.get_or_generate_stage_content(upcoming_stage)
	scout_text.text = _format_scout_report(content)
	scout_panel.visible = true


func _format_scout_report(content: Dictionary) -> String:
	var report = "[b]Stage Type:[/b] %s\n[b]Biome:[/b] %s\n\n" % [content["stage_type"], content["biome"]]
	report += "[b]Enemies (%d):[/b]\n" % content["enemies"].size()
	for enemy in content["enemies"]:
		report += "- %s (%s tier)\n" % [enemy.display_name, enemy.tier]
	report += "\n[b]Map Preview:[/b]\n[code]" + _build_ascii_map(content) + "[/code]\n"
	report += "\nLegend: A=your squad, E=enemy, #=wall, ~=slows movement, .=blocks sight, *=both, (blank)=clear"
	return report


func _build_ascii_map(content: Dictionary) -> String:
	var tile_map: Dictionary = content["tile_map"]
	var ally_cells: Array = content["ally_cells"]
	var enemy_cells: Array = content["enemy_cells"]

	var max_x = 0
	var max_y = 0
	for cell in tile_map.keys():
		max_x = max(max_x, cell.x)
		max_y = max(max_y, cell.y)

	var lines: Array[String] = []
	for y in range(max_y + 1):
		var line = ""
		for x in range(max_x + 1):
			var cell = Vector2i(x, y)
			if cell in ally_cells:
				line += "A"
			elif cell in enemy_cells:
				line += "E"
			elif tile_map.has(cell):
				var tile: TileTypeData = tile_map[cell]
				if tile.is_wall:
					line += "#"
				elif tile.movement_cost > 1 and tile.blocks_line_of_sight:
					line += "*"
				elif tile.movement_cost > 1:
					line += "~"
				elif tile.blocks_line_of_sight:
					line += "."
				else:
					line += " "
			else:
				line += "?"
		lines.append(line)
	return "\n".join(lines)


# ── CONTINUE ─────────────────────────────────────────────────────────────────

func _on_continue_pressed() -> void:
	if deployed_ids.is_empty():
		print("⛔ Select at least 1 unit to deploy before continuing.")
		return

	var full_roster = _get_full_roster()
	var new_party: Array = []
	var new_bench: Array = []
	for unit in full_roster:
		if unit == null:
			continue
		if unit.id in deployed_ids:
			new_party.append(unit)
		else:
			new_bench.append(unit)

	RunManager.current_run.party = new_party
	RunManager.current_run.bench = new_bench

	if RunManager.stage_content_completed_for_current_stage:
		RunManager.advance_stage()
		RunManager.stage_content_completed_for_current_stage = false
	else:
		RunManager.save_run()

	get_tree().change_scene_to_file(RunManager.get_scene_path_for_current_stage())
