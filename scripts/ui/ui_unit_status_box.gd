# 1. Class name MUST be the very first line of the file.
class_name UnitStatusBox 

# 2. Extend the node type.
extends PanelContainer

# 3. Define UI references (onready).
@onready var name_label = $VBoxContainer/NameLabel
@onready var hp_bar = $VBoxContainer/HPBar
@onready var mana_bar = $VBoxContainer/ManaBar
@onready var status_container = $VBoxContainer/StatusIconContainer


# 4. Main function to refresh the visuals.
func update_display(unit: Node) -> void:
	# Guard clause: stop if the unit or its data is missing.
	if not unit or not unit.unit_data:
		return

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
