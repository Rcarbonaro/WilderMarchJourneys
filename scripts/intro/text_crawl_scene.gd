# res://scripts/intro/text_crawl_scene.gd
#
# TEXT CRAWL SCENE -- shown once, right when a new run begins (see
# game_mode_select.gd's _start_random_run()/_start_draft_run(), which now
# route here first instead of going straight to the tarot-pick/draft scene).
#
# One paragraph is shown at a time. Each stays up for
# CRAWL_SECONDS_PER_PARAGRAPH seconds before auto-advancing -- unless the
# player presses "Next" (jumps to the next paragraph immediately) or "Skip"
# (ends the WHOLE crawl immediately).

extends Control

const CRAWL_SECONDS_PER_PARAGRAPH := 30.0

# One entry per paragraph, in order. "background" is OPTIONAL -- leave it out
# (or use "") for the plain black default background (see BackgroundImage,
# which just stays hidden in that case and lets the black ColorRect behind
# it show through). ParagraphLabel wraps long lines automatically.
const PARAGRAPHS: Array[Dictionary] = [
	{ "text": "Long ago, Elyndra's Prophecy warned of the dangers that would lead to the Last Days. It was said that if we remained faithful, Elyndra would appear in the Last Days to save us. For many years, the Inari fought hard to keep Elyndra's tenants, believing their brutal piety would save the world…" },
	{ "text": "However, as the Rodescian Empire grew in strength, not even the Inari could stand against them, and their influence quickly dwindled, until they were seen as the Rodescians came to be seen as an existential threat to the East. However, something far worse than the Rodescians would soon arise…" },
	{ "text": "It was a day like any other in the port city of Epissis. Still recovery from fighting off the Rodescians four months prior, the city was caught off guard when a massive creature arose from the depths. The city's bells rang within moments of its arrival, but emergency responses were accustomed to siege warfare, not something of this magnitude…",},
	{ "text": "Its steps alone caused nearby buildings to crumble, its devastating roar caused many to collapse in the streets, and the only survivors were those whose first instinct were to flee the walls…"},
	{ "text": "You soon found yourself among a small group of survivors, who formed a small caravan to travel east, hoping to make their way to the desert fortress-city Saulimar, where you hoped to make refuge. They look to you for guidance, for refuge. Their protection has fallen onto your shoulders. You must lead the few fighters who remain, and carve a safe path until we can arrive at Saulimar, the city that will save us."},
	{ "text": "Traveler, I trust in you. I believe that you can lead us to safety.",  "background": "res://sprites/UI/tarot/tarot_pick_background.png" },

]

@onready var paragraph_label:  Label       = $ParagraphLabel
@onready var next_button:      Button      = $ButtonRow/NextButton
@onready var skip_button:      Button      = $ButtonRow/SkipButton
@onready var advance_timer:    Timer       = $AdvanceTimer
@onready var background_image: TextureRect = $BackgroundImage

var _index: int = 0


func _ready() -> void:
	next_button.pressed.connect(_on_next_pressed)
	skip_button.pressed.connect(_on_skip_pressed)
	advance_timer.one_shot = true
	advance_timer.timeout.connect(_on_timer_timeout)
	_show_paragraph(0)


func _show_paragraph(index: int) -> void:
	if index >= PARAGRAPHS.size():
		_finish_crawl()
		return
	_index = index
	var paragraph: Dictionary = PARAGRAPHS[_index]
	paragraph_label.text = paragraph.get("text", "")

	# Shows this paragraph's background image if it has one, otherwise hides
	# BackgroundImage entirely so the plain black ColorRect behind it is
	# what's visible -- that's the default.
	var background_path: String = paragraph.get("background", "")
	if background_path != "" and ResourceLoader.exists(background_path):
		background_image.texture = load(background_path)
		background_image.visible = true
	else:
		background_image.visible = false

	advance_timer.start(CRAWL_SECONDS_PER_PARAGRAPH)


func _on_next_pressed() -> void:
	# Instantly shows the next paragraph, same as if the timer had elapsed.
	advance_timer.stop()
	_show_paragraph(_index + 1)


func _on_skip_pressed() -> void:
	# Skips the ENTIRE crawl, not just the current paragraph.
	advance_timer.stop()
	_finish_crawl()


func _on_timer_timeout() -> void:
	_show_paragraph(_index + 1)


func _finish_crawl() -> void:
	SceneTransitions.change_scene(RunManager.pending_next_scene_path)
	
