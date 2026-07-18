extends CanvasLayer

signal difficulty_chosen(difficulty: String)
signal cancelled

var normal_button:    Button = null
var hard_button:      Button = null
var nightmare_button: Button = null
var cancel_button:    Button = null


func _ready() -> void:
	normal_button    = find_child("NormalButton",    true, false) as Button
	hard_button      = find_child("HardButton",      true, false) as Button
	nightmare_button = find_child("NightmareButton", true, false) as Button
	cancel_button    = find_child("CancelButton",    true, false) as Button

	for pair in [["NormalButton", normal_button], ["HardButton", hard_button],
				 ["NightmareButton", nightmare_button], ["CancelButton", cancel_button]]:
		if pair[1] == null:
			push_warning("DifficultySelectPopup: could not find a Button named '%s' in the scene -- check the Name field matches exactly (case-sensitive)." % pair[0])

	var unlocks: Dictionary = RunManager.meta.difficulty_unlocks if RunManager.meta != null else {"normal": true, "hard": false, "nightmare": false}

	_setup_button(normal_button,    "Normal",    "normal",    true)
	_setup_button(hard_button,      "Hard",      "hard",      unlocks.get("hard", false))
	_setup_button(nightmare_button, "Nightmare", "nightmare", unlocks.get("nightmare", false))

	if cancel_button:
		cancel_button.pressed.connect(func():
			cancelled.emit()
			queue_free()
		)
	AudioManager.wire_all_buttons_in(self)


func _setup_button(btn: Button, label: String, difficulty_id: String, is_unlocked: bool) -> void:
	if btn == null:
		return   # already warned above -- just skip it instead of crashing
	if is_unlocked:
		btn.text     = label
		btn.disabled = false
		btn.pressed.connect(func():
			difficulty_chosen.emit(difficulty_id)
			queue_free()
		)
	else:
		btn.text     = "🔒 " + label
		btn.disabled = true
