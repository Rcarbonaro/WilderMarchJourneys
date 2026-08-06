# res://scripts/data/unit_data.gd

# 📤 EXPORTS TO: UnitNode (the actual game unit reads this), ShopManager (recruits use this)

# 📥 CALLS FROM: StatsData (embeds stats), AbilityData (lists abilities)

class_name UnitData

extends Resource

@export var id: String = ""

@export var display_name: String = ""

@export var description: String = ""

@export var unique_mechanics: String = ""
# ADDED. Optional -- leave blank ("") to skip this section entirely. Shown in
# UnitInfoPopup directly below Description (see unit_info_popup.gd) whenever
# it's non-empty. Use this for a plain-language explanation of a unit's named
# passive/mechanic that doesn't read naturally as ability flavor text -- e.g.
# the Spellsword's Arcana Charge: what it does, how it builds, what it
# unlocks. Every other unit can just leave this blank; the section simply
# won't render for them.

@export var portrait: Texture2D

@export var battle_sprite: Texture2D

@export var cost_gold: int = 3          # 📤 EXPORTS TO: ShopManager for purchase price

# Class identity

@export var class_name_label: String = ""

@export var synergy_tags: Array[String] = []  # e.g. ["Overkill", "Critical"]

# ── ROLE TAGS (ADDED) ─────────────────────────────────────────────────────────
# Multi-select checkboxes in the Inspector -- click as many as apply. This is
# a bitmask (not a single dropdown) because some units genuinely fall into
# more than one bucket at once (e.g. a beefy skirmisher that also deals real
# damage).
#
# USED BY: Random game mode's spawn guarantee (at least 1 tank + 1 primary
# damage dealer every run -- see game_mode logic that builds the Random
# roster). Anything else that wants to reason about "is this a tank" without
# hardcoding specific unit ids can check this too.
#
# CHECKING IN CODE: a unit can match more than one role, so always check with
# a bitwise AND against the named constants below -- never with `==`.
#   if unit_data.unit_roles & UnitData.ROLE_TANK:
#       ...
# ...or use the has_role() helper just below, which does the same thing:
#   if unit_data.has_role(UnitData.ROLE_TANK):
#       ...

@export_flags("Tank", "Support", "Skirmisher", "Sub Damage", "Primary Damage") var unit_roles: int = 0

const ROLE_TANK           := 1   # bit 0 -- "Tank"
const ROLE_SUPPORT        := 2   # bit 1 -- "Support"
const ROLE_SKIRMISHER     := 4   # bit 2 -- "Skirmisher"
const ROLE_SUB_DAMAGE     := 8   # bit 3 -- "Sub Damage"
const ROLE_PRIMARY_DAMAGE := 16  # bit 4 -- "Primary Damage"

func has_role(role_flag: int) -> bool:
	# Convenience wrapper around the bitmask check above -- reads a little
	# cleaner at call sites than repeating "& " everywhere.
	return (unit_roles & role_flag) != 0

# ── HEAVY / TANKY UNIT TRAITS (ADDED) ─────────────────────────────────────────
# Deliberately SEPARATE from Role Tags above. Role Tags are about TEAM
# COMPOSITION (who to bring to a fight); these are about actual BATTLEFIELD
# BEHAVIOR (how hard THIS specific unit is to punt around or wear down with
# hazards/DOT). A unit can have Tank checked above and none of these set, or
# vice versa -- e.g. a support unit standing in a hazard field, or a
# genuinely unstoppable boss, doesn't need to also carry the Tank team-comp
# tag just to get these.

@export var immune_to_displacement_and_cc: bool = false
# When checked, this unit:
#   - cannot be pushed/pulled/scattered by any player ability's displacement
#     (see ability_executor.gd's _resolve_pending_displacements())
#   - ignores negative mov_modifier from slows entirely -- positive mov BUFFS
#     still apply normally (see unit_node.gd's get_effective_mov())
#   - can never have a stun or root status applied to it AT ALL (full CC
#     immunity, not just movement -- see unit_node.gd's apply_status())

@export_range(0.0, 1.0, 0.05) var hazard_damage_reduction_percent: float = 0.0
# 0.0 = no reduction, 1.0 = fully immune to hazard tile damage (spikes, fire
# fields, etc). Set per-unit so individual "tanky" enemies can be rebalanced
# independently instead of sharing one global number. See battle_grid.gd's
# apply_hazard_to_unit().

@export_range(0.0, 1.0, 0.05) var dot_damage_reduction_percent: float = 0.0
# 0.0 = no reduction, 1.0 = fully immune to damage-over-time ticks (poison/
# fire/curse). Same per-unit rebalancing reasoning as hazard resistance
# above. See unit_node.gd's _apply_dot_tick().

# Stats PER LEVEL (index 0 = level 1, index 4 = level 5)

@export var stats_by_level: Array[StatsData] = []

# Abilities unlocked per level (Dictionary: level number -> AbilityData)

# Example: { 1: [basic_attack, enraged_strike], 2: [blood_fury], 3: [unstoppable_fury] }

@export var abilities_by_level: Dictionary = {}

# Rarity for shop weighting

@export_enum("common", "uncommon", "rare") var rarity: String = "common"

@export_enum("normal", "elite", "boss") var tier: String = "normal"
# ADDED. Read by battle_manager.gd's real (non-test) enemy-spawn path and
# passed into ScalingEngine.apply_scaling() so elites get an extra stat
# multiplier on top of normal per-stage scaling (see
# content/scaling/<stage>.json's "elite_stat_multiplier" -- see the README
# entry on marking an enemy elite for the full explanation). Has no effect
# on player units; "boss" is provided for the same reason but isn't read by
# anything yet -- reserved for whenever your boss-stage handling needs to
# tell a boss apart from a regular elite.

# ── SEGMENTED HEALTH / BOSS PHASES ────────────────────────────────────────────
# ADDED. Any unit can opt into this — not gated behind tier == "boss" — so a
# tough sub-boss or an elite pack leader can use the exact same system.

@export var hp_segment_count: int = 1
# 1 = normal single HP bar (default, zero behavior change for every existing
# unit). >1 = HP is divided into this many equal segments visually and
# mechanically — damage that would cross a segment boundary is clamped
# exactly at the boundary (no bleed-through into the next segment in the
# same hit). See unit_node.gd's take_damage() and boss_phase_controller.gd.

@export var boss_phases: Array[BossPhaseData] = []
# Must have exactly hp_segment_count entries when hp_segment_count > 1 —
# boss_phases[0] is how the unit behaves in its FIRST (topmost) segment,
# boss_phases[hp_segment_count - 1] is its final segment. Ignored entirely
# when hp_segment_count == 1.

@export var ends_battle_on_death: bool = false
# CHECK for a boss whose death should immediately win the battle even if
# other enemies (its own summoned reinforcements, an untouched second pack,
# etc.) are still alive. See battle_manager.gd's _check_battle_end().

# ── INTERRUPT / REACTION ABILITIES ────────────────────────────────────────────
@export var innate_interrupts: Array[InterruptAbilityData] = []
# Reactive abilities this unit can ALWAYS use, with no status needed —
# e.g. a monster that innately lashes out whenever it's struck. Combined at
# runtime with any interrupts granted by active statuses (counterattack
# stance, etc.) — see unit_node.gd's get_active_interrupts().


# Base stats
@export var base_stats: StatsData

# Ability

@export var starting_abilities: Array[AbilityData] = []

# Ensure this is at the top of unit_node.gd, outside any functions
@export var is_spellsword: bool = false
var has_arcana_charge: bool = false

# ── SPAWN AURAS ───────────────────────────────────────────────────────────────

@export var spawn_auras: Array[AuraData] = []
# Auras this unit carries from the MOMENT they spawn into battle — no ability
# cast needed. Each entry should have its on_spawn box checked (see
# aura_data.gd) — that's just a sanity flag, but leaving it unchecked will
# print a warning at battle start as a reminder it's probably a mistake.
#
# Activated automatically in battle_manager.gd's spawn_unit(), right after
# the unit is placed and registered on the grid, by calling the exact same
# AuraManager.activate_aura() an ability cast would use — so everything
# about how the aura behaves afterward (following the unit, ticking,
# expiring, being cleansed if cleansable, etc.) works completely identically
# to a normal cast aura. Works for both player units and enemies.

@export var hurt_sfx:  AudioStream = null
@export var death_sfx: AudioStream = null

@export var movement_sfx: AudioStream = null
# ADDED. Optional per-unit override for the footstep sound looped while this
# unit walks (see unit_node.gd's move_along_path()). Leave null to use the
# project-wide default footstep sound (unit_node.gd's DEFAULT_MOVEMENT_SFX_PATH,
# res://assets/audio/sfx/movement/Dirt Run 1.ogg).

# ── WIND SWAY ──────────────────────────────────────────────────────────────
# ADDED. unit_node.gd's setup() applies res://shaders/wind_sway.gdshader
# (the same shader map features use — see map_feature_data.gd) to this
# unit's AnimatedSprite2D when sways_in_wind is true.

@export var sways_in_wind: bool = false
# Off by default (unlike MapFeatureData, which defaults ON) -- character
# sway reads as a much more noticeable effect than a tree wobbling, so it's
# opt-in per unit. Turn on for whichever units you want to experiment with.

@export var sway_strength: float = 3.0
# Pixels of horizontal offset AT THE VERY TOP of the sprite (above
# sway_pivot), fading to zero at/below it. Worth starting smaller than
# you'd use for a tree -- a character reads as "wrong" faster than foliage
# does.

@export var sway_speed: float = 1.0
# Higher = faster swaying.

@export_range(0.0, 1.0) var sway_pivot: float = 0.5
# UV.y (0 = top of the sprite frame, 1 = bottom) at and below which there's
# ZERO sway -- this is the actual fix for "the whole unit moves" rather
# than just its top. An animated character's sprite sheet is almost always
# padded with transparent space around the character (so every animation
# frame shares one uniform size without the character visibly shifting
# between frames) -- if this were left at 1.0 (map features' default,
# anchoring at the very bottom of the FRAME), that padding gets counted as
# part of the character's height, and the real, visible portion of the
# sprite ends up sitting in the middle of the sway curve instead of at its
# anchored extreme. 0.5 is a reasonable starting guess (upper body sways,
# waist-down doesn't) -- raise it if the character still looks like it's
# leaning as a whole, lower it if even the head barely moves.

@export var sway_in_unison: bool = true
# true  -- this unit shares the exact same sway phase as every OTHER
#          unison-enabled unit AND every map feature with sways_in_wind on
#          (map_feature_data.gd) -- everything sways together as one
#          coherent gust passing through the whole scene.
# false -- this unit gets its own randomized phase instead, swaying
#          independently of everyone else -- useful for making a specific
#          unit feel deliberately "off" from the group (nervous, wounded,
#          possessed, whatever fits) rather than moving with everything else.

# ── BREATHING ────────────────────────────────────────────────────────────────
# ADDED. A separate, independent effect from wind sway above -- a small
# vertical bob concentrated around the chest, on its own clock. Always
# individually randomized per unit (see unit_node.gd) regardless of
# sway_in_unison -- real breathing doesn't sync between separate people the
# way wind affects everything at once, so this never respects the "unison"
# setting even when both effects are on for the same unit.

@export var breathes: bool = false
# Off by default. Independent of sways_in_wind -- a unit can breathe
# without swaying in the wind, sway without breathing, both, or neither.

@export var breathing_speed: float = 0.5
# Higher = faster/more anxious-looking breathing. 0.5 is a slow, calm
# resting rate; try something like 1.5-2.0 for a winded/exhausted unit.

@export var breathing_strength: float = 1.5
# Pixels of vertical offset at the peak of the breath (at breathing_center).

@export_range(0.0, 1.0) var breathing_center: float = 0.3
# UV.y of the "chest" -- the center of the affected band. Same padded-frame
# caveat as sway_pivot above applies here -- 0.3 is a guess assuming a
# roughly head-at-the-top layout; nudge it to match your actual sprite.

@export_range(0.01, 1.0) var breathing_width: float = 0.15
# How tall the affected band is, centered on breathing_center. Smaller =
# tighter/more localized to just the chest; bigger = a softer, wider bob
# that blends into the shoulders/waist.


@export var deployment_barks: DialogueBarkData

# ── LEVEL-UP CONFIGURATION (ADDED) ────────────────────────────────────────────
# Controls what happens when this specific unit levels up (buying a
# duplicate copy from the shop) -- see level_up_engine.gd for the full
# rules engine that reads these. Both arrays can be left EMPTY, in which
# case this unit uses the project-wide defaults: every stat equally likely,
# +1 for most stats, +5 mana (skipped entirely if this unit has no mana),
# +2% crit chance, +2% crit damage, and an equal chance of 2, 3, or 4 stats
# increasing per level.

@export var level_up_stat_rules: Array[StatLevelUpRule] = []
# Add one entry per stat you want to customize for THIS unit -- its
# likelihood of being chosen, the color of its "+X" popup/sparkles, and/or
# its own possible amounts (e.g. "this unit's mana always jumps by 5, 6, 7,
# or 8"). Any stat with no entry here falls back to the project defaults.

@export var level_up_stat_count_options: Array[LevelUpCountOption] = []
# How many stats increase per level-up for THIS unit (e.g. always exactly
# 3, or weighted toward bigger jumps). Leave empty for the project default
# (equal chance of 2, 3, or 4).
