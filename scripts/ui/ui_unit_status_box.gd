# 1. Class name MUST be the very first line of the file.
class_name UnitStatusBox 
# 2. Extend the node type.
extends PanelContainer
# 3. Define UI references (onready).
@onready var name_label = $VBoxContainer/NameLabel
@onready var hp_bar = $VBoxContainer/HPBar
@onready var mana_bar = $VBoxContainer/ManaBar
@onready var status_container = $VBoxContainer/StatusIconContainer

# Remembers whoever update_display() was last called with, so the
# Description button knows who to show without needing its own parameter --
# the button itself can't carry an argument, since it's wired up once in
# _ready() before any unit has ever been shown here.
var _current_unit: Node = null

# 4. Built once, in code -- same approach as draft_scene.gd's per-card
# Description button. Appending it here means you don't need to touch this
# box's .tscn file at all to get the button to show up.
func _ready() -> void:
	var description_button := Button.new()
	description_button.text = "📜 Description"
	description_button.pressed.connect(_on_description_pressed)
	$VBoxContainer.add_child(description_button)

# 5. Main function to refresh the visuals.
func update_display(unit: Node) -> void:
	# Guard clause: stop if the unit or its data is missing.
	if not unit or not unit.unit_data:
		return

	_current_unit = unit

	# Update labels and bars.
	name_label.text = unit.unit_data.display_name # Assuming display_name is in UnitData
	hp_bar.value = unit.current_hp
	hp_bar.max_value = unit.unit_data.max_hp
	
	mana_bar.value = unit.current_mana
	mana_bar.max_value = unit.unit_data.max_mana
	
	# 5. Refresh Status Icons.
	# Clear the container first so we don't duplicate icons.
	for child in status_container.get_children():
		child.queue_free()
		
	# Loop through statuses and create an icon for each.
	for status in unit.active_statuses:
		var icon_rect = TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(32, 32)
		
		# Check if the status has an icon in its resource.
		if status.has("icon") and status.icon:
			icon_rect.texture = status.icon
		else:
			# If no icon, generate a white square fallback.
			var img = Image.create(32, 32, false, Image.FORMAT_RGBA8)
			img.fill(Color.WHITE)
			icon_rect.texture = ImageTexture.create_from_image(img)
			
		status_container.add_child(icon_rect)


# 6. Description button handler -- opens the same UnitInfoPopup the Draft
# screen uses, but fed this unit's LIVE in-battle numbers (get_effective_*(),
# which already include equipment/buffs/auras) instead of static base stats,
# plus their actually-equipped items.
func _on_description_pressed() -> void:
	if _current_unit == null or not is_instance_valid(_current_unit):
		return
	_show_description_popup(_current_unit)


func _show_description_popup(unit: Node) -> void:
	var unit_data: UnitData = unit.unit_data
	if unit_data == null:
		return

	var popup := UnitInfoPopup.new()
	get_tree().current_scene.add_child(popup)

	var max_hp_stat: int = unit.get_stats().hp
	var max_mana_stat: int = unit.get_stats().mana

	var stat_lines: Array = []
	stat_lines.append("HP: %d / %d" % [unit.current_hp, max_hp_stat])
	if max_mana_stat > 0:
		stat_lines.append("Mana: %d / %d" % [unit.current_mana, max_mana_stat])
	stat_lines.append("ATK: %d" % unit.get_effective_atk())
	stat_lines.append("MATK: %d" % unit.get_effective_matk())
	stat_lines.append("DEF: %d" % unit.get_effective_def())
	stat_lines.append("MDEF: %d" % unit.get_effective_mdef())
	stat_lines.append("MOV: %d" % unit.get_effective_mov())
	stat_lines.append("Crit %%: %.0f%%" % unit.get_effective_crit_chance())
	stat_lines.append("Crit DMG: %.0f%%" % unit.get_effective_crit_damage())

	# Equipped items -- works for both player units AND enemies. Enemies just
	# naturally end up with an empty 'equipped_items' (spawn_unit() in
	# battle_manager.gd only ever calls EquipmentRuntime for player units), so
	# this gracefully shows no "Equipped Items" section for them at all,
	# rather than needing a separate code path.
	var equipped_item_entries: Array = []
	if "equipped_items" in unit:
		for item in unit.equipped_items:
			if item == null:
				continue
			equipped_item_entries.append({
				"icon": item.icon if "icon" in item else null,
				"name": item.display_name if "display_name" in item else "Unknown Item",
			})

	popup.setup(unit_data, stat_lines, equipped_item_entries)
