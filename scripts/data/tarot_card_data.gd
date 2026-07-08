# res://scripts/data/tarot_card_data.gd
#
# One tarot card. Effects dispatched by 'effect_id' — a string key
# TarotSystem looks up internally. Leave effect_id blank for a card that's
# checked live via RunManager.has_tarot() directly elsewhere (most cards
# work this way — see the README for how to add new ones).

class_name TarotCardData
extends Resource

@export var id: String = ""
@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D

@export var is_cursed: bool = false
@export var stackable: bool = true
@export var max_stacks: int = 99

@export var effect_id: String = ""
# Only needed for a ONE-TIME effect applied at the moment the card is
# picked (e.g. granting starting gold). Leave blank otherwise.

@export var effect_params: Dictionary = {}
# Tunable numbers for this card, read by whichever system checks for it.
