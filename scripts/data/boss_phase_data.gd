# res://scripts/data/boss_phase_data.gd
#
# One HP-segment's worth of behavior for a segmented-health unit (a "boss"
# in the gameplay sense, though nothing here requires UnitData.tier == "boss").
#
# UnitData.boss_phases holds an ARRAY of these, one per segment, ordered from
# the FIRST segment (100%-75% HP, index 0) to the LAST (25%-0%, the final
# index). See unit_data.gd for how hp_segment_count and boss_phases relate.
class_name BossPhaseData
extends Resource

@export var phase_name: String = ""
# e.g. "Enraged", "Feral", "Last Stand" — shown in the announcement banner.

@export var announcement_text: String = ""
# e.g. "The Barkskin Elk shrugs off its wounds and grows feral!"
# Shown via EventBus.ON_BOSS_PHASE_CHANGED when this phase BEGINS (i.e. when
# the PREVIOUS segment was just depleted). Leave blank to skip the banner
# for this specific transition (the very first phase, index 0, usually has
# no transition banner since the boss starts in it).

# ── STAT MULTIPLIERS (applied on top of base stats for this phase onward) ──
@export var atk_multiplier: float = 1.0
@export var matk_multiplier: float = 1.0
@export var def_multiplier: float = 1.0
@export var mdef_multiplier: float = 1.0
@export var mov_bonus: int = 0
# Flat MOV add (not a multiplier — MOV numbers are small enough that a
# multiplier would round awkwardly).

# ── ABILITY KIT CHANGES ─────────────────────────────────────────────────────
@export var add_abilities: Array[AbilityData] = []
# Appended to the unit's usable kit (starting_abilities) from this phase on.
# Does not remove anything — abilities from earlier phases stay available
# unless you deliberately give the same ability a phase-gated cooldown.

# ── RETREAT ──────────────────────────────────────────────────────────────────
@export var retreat_squares: int = 5
# How far (in movement, pathfinding-respecting) the unit tries to retreat
# from whoever just hit it, the instant this segment is DEPLETED (i.e. right
# before entering the NEXT phase). 0 = no retreat for this transition.

# ── REINFORCEMENTS ───────────────────────────────────────────────────────────
@export var summon_wave: ReinforcementWaveData = null
# Spawned the instant this segment is depleted, alongside the retreat.
# Leave null for a phase transition with no summon.

# ── INVULNERABILITY WINDOW ───────────────────────────────────────────────────
@export var transition_invulnerable: bool = true
# CHECK (default): while the retreat+summon sequence plays out, this unit
# cannot take further damage (blocks bleed-through from multi-hit abilities
# still resolving against its old position). Cleared the instant the
# sequence finishes. See boss_phase_controller.gd.
