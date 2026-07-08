# res://scripts/data/ability_data.gd
#
# This is a "Resource" — think of it like a data card you fill out in the
# Inspector. Every ability in the game (attacks, spells, buffs) is one of these.
# You create a new .tres file for each ability and fill in the fields.
#
# NEW ADDITIONS:
#   - Dash ability support (is_dash, dash_trail_texture, dash_speed)
#   - Knockback with direction choice (push away vs manual direction)
#   - Mana cost checked before casting
#   - Special effect architecture: Tether, Thorns, Shield, Guardian,
#     On-Kill, Movement-after-attack, Conditional bonus damage
#   - Aura ability support (is_aura, aura_data)
#   - Cleanse ability support (is_cleanse) — strips cleansable statuses AND
#     cleansable auras (curses the target themselves cast/carry) from a target

class_name AbilityData
extends Resource

# ── IDENTITY ──────────────────────────────────────────────────────────────────

@export var id: String = ""
# A unique machine-readable name, e.g. "fireball" or "basic_slash".
# No spaces. Used to track cooldowns in dictionaries.

@export var display_name: String = ""
# The human-readable name shown on the ability button in-game.

@export var description: String = ""
# Flavour text / tooltip shown to the player.

@export var icon: Texture2D
# The small image shown on the ability button.

@export var effect_scene: PackedScene
# Optional scene used for projectile travel or AOE display.
# Falls back to icon, then a white square if neither is set.

@export var scale_vfx_to_fit_aoe: bool = true
# CHECK (default, unchanged behaviour): the effect_scene/icon visual is
# stretched/squashed non-uniformly so it exactly fills the AOE's bounding
# box, however many tiles wide/tall that turns out to be.
#
# UNCHECK: the visual keeps its own art's natural proportions instead of
# being warped to fit the tile area. It's still scaled up/down to roughly
# match the AOE's footprint, but uniformly (same scale on both axes, fit
# entirely within the bounding box) so circular/asymmetric VFX and any
# distinct walk/idle/attack animation frames don't get squished or
# stretched into a rectangle. Turn this off for AOE visuals that look wrong
# warped — e.g. a round explosion or an animated character-shaped effect
# spawned at a multi-tile AOE size.
# See ability_executor.gd's _apply_vfx_scaling() for where this is read.

# ── CUSTOM ATTACK ANIMATION ───────────────────────────────────────────────────

@export var attack_animation_name: String = ""
# The named animation played on the caster's AnimatedSprite2D when this specific
# ability is used. e.g. "attack_fire_sword", "attack_lightning_sword".
#
# Leave BLANK to fall back to the unit's normal generic attack animations
# ("attack", "attack_up", "attack_down" based on target direction — the
# existing behaviour in battle_manager.gd / ai_system.gd is unchanged).
#
# When set, this OVERRIDES the directional fallback entirely — the exact named
# animation plays regardless of target direction. If you need directional
# variants for a custom animation too, suffix your own and check in
# battle_manager/ai_system, or leave this blank to use the built-in fallback.

# ── COST ──────────────────────────────────────────────────────────────────────

@export var mana_cost: int = 0
# How much mana this ability costs. Checked BEFORE casting.
# If the unit doesn't have enough, casting is blocked.

@export var hp_cost_percent: float = 0.0
# e.g. 0.2 = costs 20% of max HP when used.

@export var is_unleash_ability: bool = false
# Check this box to mark this as a party-wide "Unleash" ability — one that can
# only be used once total HP spent on ability costs (across the whole party,
# tracked by battle_manager.gd's unleash_available flag) crosses
# HP_UNLEASH_THRESHOLD. Casting it consumes the threshold, resetting the
# counter so the party has to build it back up again before using another.
# If unleash_available is false, selecting this ability is blocked entirely
# (mirrors how Arcana Charge gates Spellsword abilities, but party-wide
# instead of per-unit).

@export var charge_cost: int = 0
@export var custom_resource_cost: int = 0
@export var custom_resource_name: String = ""

# ── COOLDOWN ──────────────────────────────────────────────────────────────────

@export var cooldown_rounds: int = 0
# 0 = no cooldown. After use, this many turns must pass before using again.

# ── TARGETING ─────────────────────────────────────────────────────────────────

@export var min_range: int = 0
@export var max_range: int = 1
@export var requires_line_of_sight: bool = true
@export var can_ignore_los: bool = false

@export_enum("enemies", "allies", "all") var affects_team: String = "enemies"
# "enemies"  — only damages / debuffs enemy units.
# "allies"   — only heals / buffs friendly units.
# "all"      — hits everyone in the area.

# ── AREA OF EFFECT ────────────────────────────────────────────────────────────

@export_enum("single", "line", "cone", "square", "cross", "wall", "chain", "multi_target") var aoe_shape: String = "single"
@export var aoe_size: int = 1
# For "line": how many tiles long. For "square": radius. For "cone": how far.
# For "wall": ignored — wall length comes from spawns_hazard.wall_length instead.

# ── WALL PLACEMENT ─────────────────────────────────────────────────────────────
# Only relevant when aoe_shape == "wall". A wall ability requires the player to
# pick a START tile and an END tile (two taps instead of one), and the resulting
# wall's orientation (horizontal or vertical) is determined automatically from
# whichever axis has the larger offset relative to the CASTER's position —
# see battle_manager.gd's wall placement flow for the exact two-tap UI sequence.

@export var wall_select_start_prompt: String = "Select wall start location"
# Text shown to the player during the first tap of wall placement.

@export var wall_select_end_prompt: String = "Select wall end location"
# Text shown to the player during the second tap of wall placement.

# ── DAMAGE ────────────────────────────────────────────────────────────────────

@export var base_damage_multiplier: float = 1.0
@export_enum("physical", "magical", "hazard", "true") var damage_type: String = "physical"
@export var scaling_stat: String = "atk"
# "atk" uses physical attack, "matk" uses magic attack.

@export var hits: int = 1
# Multi-hit abilities strike this many times.

# ── EFFECTS ───────────────────────────────────────────────────────────────────

@export var applies_statuses: Array[StatusEffectData] = []
# Status effects applied to every hit target.

@export var applies_statuses_to_self: Array[StatusEffectData] = []


@export var spawns_hazard: HazardData
# If set, places a hazard tile on every affected cell.

@export var heal_percent: float = 0.0
# Fraction of max HP to restore. e.g. 0.3 = heals 30%.

@export var is_cleanse: bool = false
# Check this box to make this ability strip CLEANSABLE effects from every
# target it hits (works alongside any other effects above — damage, healing,
# statuses, etc. can all happen in the same cast as a cleanse).
#
# When a target is hit by a cleanse:
#   1. Every status effect currently on them with cleansable = true (see
#      status_effect_data.gd) is removed immediately — buffs and debuffs
#      alike, since "cleansable" is a per-status flag the designer controls,
#      not a hardcoded "debuffs only" rule. Leave cleansable UNCHECKED on any
#      status that should always survive a cleanse.
#   2. Any active AURA where the target is the CASTER/OWNER, and that aura's
#      cleansable = true (see aura_data.gd), is also removed — this is for
#      curse-style auras that are attached to (cast by) the afflicted unit
#      themselves, e.g. a "Toxic Bloom" curse that makes them constantly hurt
#      whoever stands near them. Auras the target merely happens to be
#      standing INSIDE, cast by someone else, are never touched by this —
#      cleansing only ever strips effects the target themselves owns or
#      carries, never an enemy's battlefield-wide aura.
#
# No target cell (a "self" cast with nobody there)? Falls back to cleansing
# the caster, exactly like heal_percent does above.

# ── DISPLACEMENT (PUSH / PULL / KNOCKBACK) ────────────────────────────────────
# "Displacement" moves the target relative to the caster.

@export var displacement_squares: int = 0
# How many squares to move the target.
# Positive = push away from caster. Negative = pull toward caster.

@export_enum("auto", "manual", "scatter") var displacement_type: String = "auto"
# "auto"    = always pushes/pulls directly away from / toward the caster.
# "manual"  = uses the displacement_manual_dir vector below.
# "scatter" = pushes outward from the AOE centre point.

@export var displacement_manual_dir: Vector2i = Vector2i(0, -1)
# Only used when displacement_type == "manual".
# (0, -1) = always push upward. (1, 0) = always push right. Etc.

# ── DASH ABILITY ──────────────────────────────────────────────────────────────
# A "dash" is a line AOE where the CASTER travels to the last valid tile
# in the line and optionally damages everything along the way.

@export var is_dash: bool = false
# Check this box to make the caster move to the end of the line after casting.
# Only works when aoe_shape == "line".

@export var dash_damages_path: bool = true
# If true, every valid tile the caster dashes THROUGH takes damage.

@export var dash_trail_texture: Texture2D
# Optional texture stretched along the full length of the dash line.

@export var dash_speed: float = 800.0
# Pixels per second the caster sprite travels during the dash.

@export var dash_effect_scene: PackedScene
# Optional scene to instantiate on the caster during the dash.

@export var dash_animation_name: String = "dash"
# The named animation played on the caster's AnimatedSprite2D for the
# duration of the dash slide itself. Override per-ability if a specific
# dash needs a different animation name.

# ── CHAIN LIGHTNING ────────────────────────────────────────────────────────
# aoe_shape == "chain": hits ONE initial target, then bounces further.
# aoe_size (shared field above) = number of ADDITIONAL (secondary) targets,
# not counting the first hit.

@export var chain_range: int = 3
# How far a bounce can reach from the PREVIOUS hit target to find the next
# one. Separate from min_range/max_range, which only govern the very first
# tap (caster → first target).

@export var chain_simultaneous: bool = false
# UNCHECK (default): each secondary bounce plays fully — including its own
# damage — before the next one starts.
# CHECK: every secondary bounce fires at the same time.

@export var chain_manual_targets: bool = false
# UNCHECK (default): secondary targets are auto-picked — nearest unhit
# enemy within chain_range of the last hit target.
# CHECK: the player taps every secondary target themselves (same
# multi-tap targeting flow "multi_target" abilities use below).

@export var chain_bounce_scene_first: PackedScene
# Lightning-stretch scene from the CASTER to the first target. Falls back
# to effect_scene if left empty.

@export var chain_bounce_scene_secondary: PackedScene
# Lightning-stretch scene from the first target to EACH other target.
# Falls back to chain_bounce_scene_first (then effect_scene) if empty.

# ── MULTI-TARGET / TRAVEL+IMPACT ANIMATIONS ───────────────────────────────
# aoe_shape == "multi_target": the player taps aoe_size individual enemy
# tiles (Zephyr Strike). travel_animation_name/impact_animation_name below
# are also reused by Leap for its own movement + hit.

@export var multi_target_simultaneous: bool = false
# UNCHECK (default): the caster visits targets ONE AT A TIME, in tap order,
# then returns to their starting tile.
# CHECK: temporary visual duplicates fly out and hit every target at once
# while the real unit is hidden; it reappears at its start tile once every
# duplicate finishes.

@export var travel_animation_name: String = ""
# Caster's own animation while moving TOWARD a target (Zephyr Strike,
# Leap). Blank falls back to "walk". For Leap, set this to "leap" (or
# whatever your leap animation is named) on that ability's resource.

@export var impact_animation_name: String = ""
# Caster's own animation played ON ARRIVAL at each target — the actual hit
# (Zephyr Strike, Leap). Blank falls back to a short fixed delay instead.

# ── LEAP ──────────────────────────────────────────────────────────────────
# Two-tap ability: "Select Target" (an enemy), then "Select Destination"
# (an empty tile directly orthogonally adjacent to that target). The
# caster moves there and damages only the target.

@export var is_leap: bool = false

@export var leap_select_target_prompt: String = "Select target"
@export var leap_select_destination_prompt: String = "Select destination"


# ── TAGS & TYPE ───────────────────────────────────────────────────────────────

@export var tags: Array[String] = []
# Arbitrary labels used for synergy checks. e.g. ["Fire", "AOE", "Overkill"]

@export_enum("basic_attack", "ability", "spell", "passive") var ability_type: String = "ability"

@export var is_counterattack_immune: bool = false
# If true, this ability cannot trigger counter-attacks.

# ── BONUS DAMAGE TO ISOLATED TARGETS ─────────────────────────────────────────
# Deals extra damage to targets who have no allies standing nearby.

@export var bonus_damage_isolated: float = 0.0
# Additional damage MULTIPLIER when the target is isolated.
# e.g. 0.5 means +50% extra damage. 0.0 = disabled.

@export var isolated_range: int = 1
# How far away we check for allies. 1 = only immediate neighbours.

# ─────────────────────────────────────────────────────────────────────────────
# SPECIAL EFFECT ARCHITECTURE
# The fields below let you attach advanced one-off effects to any ability.
# Each group is completely optional — leave them at defaults to ignore them.
# ─────────────────────────────────────────────────────────────────────────────

# ── TETHER ────────────────────────────────────────────────────────────────────
# When a tethered unit is hit by a SINGLE-TARGET attack, a percentage of that
# damage is also dealt to all other units in the tether group.

@export var applies_tether: bool = false
@export var tether_id: String = ""
# A shared ID string. All units with the same tether_id are linked.

@export var tether_damage_percent: float = 0.5
# What fraction of damage is passed to each tethered ally.

@export var tether_overkill_percent: float = 0.75
# On overkill hits, tethered allies take this fraction instead.

@export var tether_duration_rounds: int = 2

# ── THORNS ────────────────────────────────────────────────────────────────────
# When this unit is attacked, a portion of the damage is reflected back
# at the attacker.

@export var applies_thorns: bool = false
@export var thorns_reflect_percent: float = 0.25
@export_enum("atk", "matk", "def", "mdef") var thorns_scaling_stat: String = "def"
@export var thorns_duration_rounds: int = 2

# ── SHIELD / BARRIER ──────────────────────────────────────────────────────────
# Applies a flat damage-absorbing barrier. Damage hits the barrier first,
# and only the remaining damage (if any) touches HP.

@export var applies_shield: bool = false
@export var shield_amount: int = 0
@export var shield_duration_rounds: int = 2

# ── GUARDIAN ──────────────────────────────────────────────────────────────────
# A unit with the Guardian effect intercepts damage meant for an ally.

@export var applies_guardian: bool = false
@export var guardian_redirect_percent: float = 1.0
@export_enum("caster_def", "caster_mdef", "target_def", "target_mdef") var guardian_uses_defense: String = "caster_def"
@export var guardian_duration_rounds: int = 1

# ── ON-KILL EFFECTS ───────────────────────────────────────────────────────────
# Something special happens when this unit lands a killing blow.

@export var has_on_kill_effect: bool = false
@export var on_kill_trigger_ability: PackedScene
@export var on_kill_trigger_on_caster: bool = false
@export var on_kill_reset_has_acted: bool = false
@export var on_kill_reset_has_moved: bool = false
@export var on_kill_reset_cooldowns: bool = false
@export var on_kill_apply_status: StatusEffectData

# ── MOVEMENT AFTER ATTACK ─────────────────────────────────────────────────────
# After the attack resolves, the caster can move some squares.

@export var post_attack_move_squares: int = 0
# 0 = disabled. Positive = free movement squares granted after attacking.

# ── CONDITIONAL BONUS DAMAGE / STAT SCALING ───────────────────────────────────
# These let you build abilities whose power scales with battle state.

@export var bonus_per_target_debuff: float = 0.0
# Extra damage added per DEBUFF the TARGET currently has.

@export var bonus_per_target_debuff_max: float = 1.0
# Maximum total bonus from target debuffs.

@export var bonus_damage_per_caster_buff: float = 0.0
# Extra damage added per BUFF the CASTER currently has.

@export var bonus_damage_per_caster_buff_max: float = 1.0
# Maximum bonus damage from caster buffs.

@export var bonus_atk_per_caster_buff: int = 0
@export var bonus_matk_per_caster_buff: int = 0
@export var bonus_def_per_caster_buff: int = 0
@export var bonus_mdef_per_caster_buff: int = 0
@export var bonus_crit_chance_per_caster_buff: float = 0.0
@export var bonus_crit_dmg_per_caster_buff: float = 0.0
@export var bonus_mov_per_caster_buff: int = 0
# Each is multiplied by the caster's buff count for this single hit.

@export var buff_bonus_max_stacks: int = 10
# Maximum number of buffs counted for the per-buff bonuses above.

# ── AURA ABILITY ──────────────────────────────────────────────────────────────
# When is_aura is true, using this ability activates a persistent zone effect
# defined by the AuraData resource assigned to aura_data.
# The aura follows the caster as they move, applies effects to units inside
# its area, and has its own visual (color overlay, sprite, or looping scene).

@export var is_aura: bool = false
# Check this box to mark this ability as an aura activator.
# When the ability is used, AbilityExecutor calls AuraManager.activate_aura()
# in addition to (or instead of) the normal damage/status pipeline.
# Leave this unchecked for all normal attacks, spells, and buffs.

@export var aura_data: AuraData
# Drag the AuraData .tres resource here (the one you filled out in aura_data.gd).
# This defines the aura's radius, who it affects, what damage it deals,
# what status effects it applies, how long it lasts, and how it looks.
# Only read when is_aura is true — ignored on all other abilities.


#Spellsword's arcana charge consumption:
@export var consumes_arcana_charge: bool = false
# Uncheck this on any ability that should IGNORE an arcana charge and
# behave as if one wasn't available — basic attacks, passive triggers,
# anything that shouldn't benefit from or deplete the charge.
# Defaults to true so all existing abilities are unchanged.
