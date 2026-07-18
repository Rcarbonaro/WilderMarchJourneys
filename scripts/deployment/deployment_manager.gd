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

@onready var roster_list: VBoxContainer     = $RosterScroll/RosterList
@onready var selected_unit_label: Label     = $EquipPanel/SelectedUnitLabel
@onready var slots_container: HBoxContainer = $EquipPanel/SlotsContainer
@onready var inventory_list: VBoxContainer  = $InventoryScroll/InventoryList

@onready var forge_slot_a_label: Label      = $EquipPanel/ForgeRow/ForgeSlotALabel
@onready var forge_slot_b_label: Label      = $EquipPanel/ForgeRow/ForgeSlotBLabel
@onready var set_slot_a_button: Button      = $EquipPanel/ForgeRow/SetSlotAButton
@onready var set_slot_b_button: Button      = $EquipPanel/ForgeRow/SetSlotBButton
@onready var forge_button: Button           = $EquipPanel/ForgeRow/ForgeButton
@onready var forge_status_label: Label      = $EquipPanel/ForgeRow/ForgeStatusLabel

@onready var shop_button: Button            = $ShopButton
@onready var continue_button: Button        = $ContinueButton
@onready var scout_button: Button           = $ScoutButton
@onready var scout_panel: PanelContainer    = $ScoutPanel
@onready var scout_text: RichTextLabel      = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutText
@onready var scout_close_button: Button     = $ScoutPanel/ScoutMargin/ScoutVBox/ScoutCloseButton
@onready var preview_layer: Node2D          = $PreviewLayer
@onready var stage_label: Label             = $StageLabel
# Add a Label named "StageLabel" near the top of DeploymentScene.tscn --
# _update_stage_label() below fills in its text at runtime.
# Add a plain Node2D named "PreviewLayer" to DeploymentScene.tscn, positioned
# near the center of the screen behind your UI panels -- every wandering
# unit gets parented under it, so moving/resizing IT moves the whole group.

var deployed_instance_ids: Array[String] = []   # instance_id of every unit currently on the 4-person team

var _selected_party_index: int = -1             # index into _get_full_roster(), or -1
var _selected_inventory_item_id: String = ""    # picked-up equipment item_id, or ""
var _forge_slot_a: String = ""                  # picked BASIC equipment item_id for forging, or ""
var _forge_slot_b: String = ""


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

	for entry in RunManager.current_run.party:
		if entry != null and entry.has("instance_id"):
			deployed_instance_ids.append(entry["instance_id"])

	_rebuild_roster()
	_rebuild_equip_slots()
	_rebuild_inventory()
	_update_scout_button()
	_update_stage_label()
	_spawn_unit_previews()


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

		roster_list.add_child(row)


func _on_roster_toggle_pressed(instance_id: String) -> void:
	if instance_id in deployed_instance_ids:
		deployed_instance_ids.erase(instance_id)
	else:
		if deployed_instance_ids.size() >= 4:
			print("⛔ You can only deploy up to 4 units. Deselect one first.")
			return
		deployed_instance_ids.append(instance_id)
	_rebuild_roster()


func _on_roster_entry_pressed(index: int) -> void:
	_selected_party_index = index
	_rebuild_roster()
	_rebuild_equip_slots()


func _get_selected_entry() -> Dictionary:
	var roster := _get_full_roster()
	if _selected_party_index < 0 or _selected_party_index >= roster.size():
		return {}
	return roster[_selected_party_index]


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


# ── EQUIPMENT SLOTS ────────────────────────────────────────────────────────────

func _rebuild_equip_slots() -> void:
	for child in slots_container.get_children():
		child.queue_free()

	var entry := _get_selected_entry()
	if entry.is_empty():
		selected_unit_label.text = "Select a unit above to manage its equipment."
		return

	var unit_data := _load_unit_data(entry.get("unit_id", ""))
	selected_unit_label.text = "Equipping: " + (unit_data.display_name if unit_data != null else entry.get("unit_id", "?"))

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	for i in range(MAX_EQUIP_SLOTS):
		var item_id = equipped[i]
		var btn := Button.new()
		if item_id == null or item_id == "":
			btn.text = "Empty Slot %d" % (i + 1)
		else:
			btn.text = ContentLoader.get_equipment(item_id).get("name", item_id)
		btn.pressed.connect(func(): _on_equip_slot_pressed(i))
		slots_container.add_child(btn)


func _on_equip_slot_pressed(slot_index: int) -> void:
	var entry := _get_selected_entry()
	if entry.is_empty():
		return

	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)

	if _selected_inventory_item_id != "":
		# Equipping: put the picked-up inventory item into this slot,
		# returning whatever was already there back to the inventory.
		var old_item = equipped[slot_index]
		equipped[slot_index] = _selected_inventory_item_id
		RunManager.current_run.equipment_inventory.erase(_selected_inventory_item_id)
		if old_item != null and old_item != "":
			RunManager.current_run.equipment_inventory.append(old_item)
		_selected_inventory_item_id = ""
	else:
		# No item picked up -- treat this as "unequip": send it back to the bag.
		if equipped[slot_index] != null and equipped[slot_index] != "":
			RunManager.current_run.equipment_inventory.append(equipped[slot_index])
			equipped[slot_index] = null

	entry["equipped_item_ids"] = equipped
	RunManager.save_run()
	_rebuild_equip_slots()
	_rebuild_inventory()


# ── INVENTORY ──────────────────────────────────────────────────────────────────

func _rebuild_inventory() -> void:
	for child in inventory_list.get_children():
		child.queue_free()
	for item_id in RunManager.current_run.equipment_inventory:
		if ContentLoader.get_equipment(item_id).get("type", "") == "consumable":
			continue   # consumables live in the combat item bar, not here
		var btn := Button.new()
		var prefix := "[Selected] " if item_id == _selected_inventory_item_id else ""
		btn.text = prefix + ContentLoader.get_equipment(item_id).get("name", item_id)
		btn.pressed.connect(func(): _on_inventory_item_pressed(item_id))
		inventory_list.add_child(btn)


func _on_inventory_item_pressed(item_id: String) -> void:
	# Clicking the same item again deselects it; clicking a different one
	# switches the selection. Then click an equip slot or a forge Set button.
	_selected_inventory_item_id = "" if _selected_inventory_item_id == item_id else item_id
	_rebuild_inventory()


# ── FORGING ────────────────────────────────────────────────────────────────────
# Pick two BASIC equipment items from inventory (type == "basic") and combine
# them via ContentLoader's forging_recipes.json -- the same lookup equipping
# and combat already use, so forged items work immediately, unlike the old
# BasicEquipmentData-based forge this replaces.

func _on_set_slot_a_pressed() -> void:
	if _is_basic_item(_selected_inventory_item_id):
		_forge_slot_a = _selected_inventory_item_id
		forge_slot_a_label.text = "A: " + ContentLoader.get_equipment(_forge_slot_a).get("name", _forge_slot_a)
		_selected_inventory_item_id = ""
		_rebuild_inventory()
	else:
		forge_status_label.text = "Select a BASIC equipment item from inventory first."


func _on_set_slot_b_pressed() -> void:
	if _is_basic_item(_selected_inventory_item_id):
		_forge_slot_b = _selected_inventory_item_id
		forge_slot_b_label.text = "B: " + ContentLoader.get_equipment(_forge_slot_b).get("name", _forge_slot_b)
		_selected_inventory_item_id = ""
		_rebuild_inventory()
	else:
		forge_status_label.text = "Select a BASIC equipment item from inventory first."


func _is_basic_item(item_id: String) -> bool:
	return item_id != "" and ContentLoader.get_equipment(item_id).get("type", "") == "basic"


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
	RunManager.current_run.equipment_inventory.erase(_forge_slot_a)
	RunManager.current_run.equipment_inventory.erase(_forge_slot_b)
	RunManager.current_run.equipment_inventory.append(output_id)

	_forge_slot_a = ""
	_forge_slot_b = ""
	forge_slot_a_label.text = "A: (empty)"
	forge_slot_b_label.text = "B: (empty)"
	forge_status_label.text = "Forged: " + ContentLoader.get_equipment(output_id).get("name", output_id) + "!"
	RunManager.save_run()
	_rebuild_inventory()


# ── SCOUT AHEAD ────────────────────────────────────────────────────────────────
# Unchanged -- this already used the real RunManager/StageDirector API.

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
	if deployed_instance_ids.is_empty():
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
