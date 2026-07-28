# res://scripts/data/bark_line_data.gd
#
# ONE LINE OF DIALOGUE -- a single thing a unit might say, plus how likely
# it is to be picked and what mood it's said in.
#
# HOW TO USE THIS:
#   You don't create these directly in the FileSystem -- they live INSIDE
#   a DialogueBarkData resource's "Lines" array (see dialogue_bark_data.gd).
#   Open a DialogueBarkData .tres file in the Inspector, expand "Lines",
#   and click "Add Element" -> "New BarkLineData" to add one of these.

class_name BarkLineData
extends Resource

@export var text: String = ""
# The actual words shown in the speech bubble.

@export var weight: float = 1.0
# How likely this line is to be picked relative to the OTHER lines in the
# same DialogueBarkData. Higher = more common. e.g. if one line has
# weight 3.0 and another has weight 1.0, the first is picked 3x as often.
# This does NOT need to add up to any particular total -- it's just a
# ratio between the lines in this one list.

@export_enum("happy", "angry", "sad") var emotion: String = "happy"
# Controls which speech bubble shape/border is used when this line is
# shown (see speech_bubble.gd):
#   "happy" -- smooth, rounded border.
#   "angry" -- jagged, spiky border.
#   "sad"   -- droopy, sagging border.
