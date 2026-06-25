# res://scripts/data/status_effect_data.gd
#
# A StatusEffectData resource defines a buff, debuff, or special condition that
# can be applied to a unit. The actual live instance is tracked in unit_node.gd's
# active_statuses array.
#
# NEW ADDITIONS:
#   - Visual override animations: a status can swap the unit's entire animation
#     set (idle/attack/walk/etc.) for as long as it's active, with one-shot
#     transition animations playing on enter and exit.
#   - Taunt: forces the affected unit to direct damaging single-target attacks
#     at the unit who applied the taunt.
#   - Damage-over-time (DoT): deals damage at the end of each enemy round,
#     either flat or scaling off the caster's ATK/MATK with an adjustable %.
#   - cleansable is now actually wired up: a cleanse ability (is_cleanse on
#     AbilityData) reads this flag to decide what it can and can't strip.

class_name StatusEffectData

extends Resource

@export var id: String = ""

@export var display_name: String = ""

@export var description: String = ""

@export var icon: Texture2D  # drag a small icon here in the Inspector

# Duration

@export var duration_rounds: int = 1   # how many rounds it lasts

@export var is_permanent: bool = false

# Stacking

@export var can_stack: bool = false    # check this box if it stacks

@export var max_stacks: int = 1

# DEPRECATED — no longer used to control countdown timing. A status now
# always decrements by 1 every time the unit's OWN team's round ends,
# regardless of this value (a unit only ever receives ticks for its own
# team, so filtering by team here meant some statuses never expired).
# duration_rounds is simply "this many of the unit's own rounds must pass."
# Field is kept so existing .tres resources don't break, but it has no effect.
@export_enum("end_of_enemy_round", "end_of_player_round") var expires_at: String = "end_of_enemy_round"

# Can it be cleansed?
# Any ability with AbilityData.is_cleanse = true strips every status on its
# target where this is checked, the instant it hits them (see
# ability_executor.gd's CLEANSE step, and unit_node.gd's cleanse_statuses()).
# Leave this UNCHECKED for a status that should survive a cleanse no matter
# what — e.g. a stun or DoT from a source that's specifically meant to be
# un-cleansable, or a buff you never want accidentally stripped.

@export var cleansable: bool = true

# Stat changes while this is active (flat amounts, can be negative)

@export var atk_modifier: int = 0

@export var def_modifier: int = 0

@export var matk_modifier: int = 0

@export var mdef_modifier: int = 0

@export var mov_modifier: int = 0

@export var crit_chance_modifier: float = 0.0

@export var damage_taken_modifier: float = 0.0   # e.g. 0.1 = take 10% more damage

@export var damage_dealt_modifier: float = 0.0   # e.g. -0.25 = deal 25% less damage

# Trigger effects (damage over time, etc.)

@export_enum("none", "start_of_turn", "end_of_turn", "on_enter_tile") var trigger_timing: String = "none"

@export var trigger_damage_multiplier: float = 0.0  # 0 = no trigger damage

@export_enum("physical", "magical", "hazard", "true") var trigger_damage_type: String = "physical"

# Special flags

@export var is_root: bool = false        # movement = 0

@export var is_stun: bool = false        # skip turn entirely

@export var is_invisible: bool = false   # untargetable by ranged

@export var grants_immunity: bool = false # blocks all debuffs

# ── VISUAL OVERRIDE ANIMATIONS ────────────────────────────────────────────────
# Some statuses fundamentally change how a unit looks for their whole duration —
# e.g. a "Bark Armor" buff that replaces the unit's idle/attack/walk animations
# with an armored version, bookended by one-shot transition animations.
#
# HOW THIS WORKS:
#   1. When the status is first applied, unit_node plays enter_animation ONCE
#      (e.g. the armor materialising and wrapping around the unit).
#   2. After enter_animation finishes, the unit's normal animation calls
#      (idle/walk/attack/hurt) are redirected to the override_* animation names
#      below for as long as this status is active.
#   3. When the status expires or is cleansed, exit_animation plays ONCE
#      (e.g. the armor crumbling away), and only then does the unit return to
#      its normal default animation set.
#
# All animation name fields below are ONLY used when visual_override_mode is
# "animation_names". They refer to named animations that must already exist
# on the unit's OWN AnimatedSprite2D (added via the Sprite Frames editor on
# that exact node), exactly like "idle", "attack", "walk" etc. already work.
# Leave a field blank to skip overriding that specific animation (falls back
# to the unit's normal one). If your override lives in a separate scene file,
# use visual_override_mode = "override_scene" and override_scene instead.

@export var has_visual_override: bool = false
# Check this box to enable the full visual override behaviour described above.
# If false, all fields below are ignored and the status only affects stats.

@export_enum("animation_names", "override_scene") var visual_override_mode: String = "animation_names"
# "animation_names" — the override animations must already exist as named
#   animations INSIDE the unit's own AnimatedSprite2D / SpriteFrames resource
#   (added via the Sprite Frames editor on that exact node, the same place
#   "idle", "attack", "walk" etc. already live). Use the enter_animation /
#   override_idle_animation / etc. String fields below.
#
# "override_scene" — instead, an entirely separate scene (with its own
#   AnimatedSprite2D and its own SpriteFrames) is instantiated as a CHILD of
#   the unit and shown in place of the unit's normal sprite for the duration
#   of the status. This is almost certainly what you want for something like
#   "Bark Armor" where the animations live in their own dedicated scene file
#   rather than being merged frame-by-frame into the character's existing
#   AnimatedSprite2D. Use the override_scene field below — that single scene
#   should contain its OWN animations named "enter", "idle", "exit" (the
#   engine looks for those exact names on the override scene's AnimatedSprite2D
#   or AnimationPlayer).

@export var override_scene: PackedScene
# Only used when visual_override_mode == "override_scene".
# A scene with its own AnimatedSprite2D (or AnimationPlayer) containing
# animations named exactly "enter", "idle", and "exit". "enter" plays once
# when the status is applied, "idle" loops for the duration, "exit" plays
# once on removal. If "enter" or "exit" don't exist on the scene, that phase
# is skipped (jumps straight to idle, or removes instantly, respectively).
# The unit's own sprite is hidden while this scene is visible, and restored
# automatically once "exit" finishes (or instantly if there's no exit anim).

@export var enter_animation: String = ""
# Played ONCE when this status is first applied. e.g. "bark_armor_enter".
# Leave blank to skip straight to the override idle animation with no transition.

@export var exit_animation: String = ""
# Played ONCE when this status expires or is removed. e.g. "bark_armor_exit".
# Leave blank to skip straight back to the normal "idle" animation with no transition.

@export var override_idle_animation: String = ""
# Replaces "idle" for the duration of this status. e.g. "bark_armor_idle".

@export var override_walk_animation: String = ""
# Replaces "walk" for the duration of this status.

@export var override_attack_animation: String = ""
# Replaces "attack" for the duration of this status.

@export var override_hurt_animation: String = ""
# Replaces "hurt" for the duration of this status.

# ── TAUNT ─────────────────────────────────────────────────────────────────────
# A taunted unit can still freely use AOE, buff, heal, and movement abilities,
# but if their CHOSEN action this turn is a damage-dealing ability with
# affects_team == "enemies", the AI must aim it at the taunt source specifically.
# If the taunter is unreachable with that ability this turn, the AI falls back
# to its normal target-selection logic for that turn only.

@export var applies_taunt: bool = false
# Check this box to make this status force damaging attacks toward a specific unit.
# The "taunt source" (who gets attacked) is recorded as the unit that APPLIED
# this status — tracked at runtime in unit_node.active_statuses, not here.

# ── DAMAGE OVER TIME (END OF ENEMY ROUND) ─────────────────────────────────────
# Deals repeated damage to the AFFECTED unit at the end of every enemy round,
# for as long as this status remains active. This is separate from the
# trigger_timing/trigger_damage_multiplier fields above (which fire on a single
# tile-enter or turn-start/end event) — this DoT fires every round, reliably,
# regardless of movement.

@export var has_dot: bool = false
# Check this box to enable repeating end-of-round damage.

@export_enum("flat", "physical", "magical") var dot_damage_mode: String = "physical"
# "flat"      — a fixed amount of true damage each round, ignoring all defence.
# "physical"  — uses (caster.ATK - target.DEF) * dot_damage_percent, normal formula.
# "magical"   — uses (caster.MATK - target.MDEF) * dot_damage_percent, normal formula.

@export var dot_flat_amount: int = 5
# Used only when dot_damage_mode == "flat". The exact damage dealt each round.

@export var dot_damage_percent: float = 0.4
# Used only when dot_damage_mode is "physical" or "magical".
# This is the SAME multiplier role as an ability's base_damage_multiplier.
# e.g. 0.4 = the DoT tick deals 40% of what a normal hit using that stat would.
