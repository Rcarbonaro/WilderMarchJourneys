# res://scripts/autoloads/event_bus.gd
#
# EVENT BUS -- a simple "announcement board" for the whole game.
#
# WHAT THIS IS FOR (beginner explanation):
#   Lots of different systems need to know when something happens -- e.g.
#   when a unit dies, when a round starts, when the shop opens. Instead of
#   every system having to know about every OTHER system directly, they all
#   just talk to this one EventBus.
#
#     - A system that wants to REACT to something calls subscribe().
#     - A system that wants to ANNOUNCE that something happened calls publish().
#
#   This keeps systems decoupled: EncounterEngine doesn't need to know that
#   an AchievementTracker even exists -- it just publishes "on_encounter_end"
#   and anything that cares can listen for it.
#
# HOW TO ADD THIS TO YOUR PROJECT:
#   Project Settings > Autoload > add this script, name it "EventBus".
#
# NAMING TIP: always use the constants below (EventBus.ON_UNIT_DIED) instead
# of typing the raw string "on_unit_died" by hand, so a typo can never cause
# a silent bug where nobody hears your event.

extends Node

# ---- CANONICAL EVENT NAMES --------------------------------------------------
# Add a new constant here every time you invent a new event, so this file is
# always a complete list of "everything that can happen" in the game.

const ON_ENCOUNTER_START    := "on_encounter_start"
const ON_ENCOUNTER_END      := "on_encounter_end"
const ON_STAGE_COMPLETE     := "on_stage_complete"
const ON_UNIT_DEALT_DAMAGE  := "on_unit_dealt_damage"
const ON_UNIT_DIED          := "on_unit_died"
const ON_ENEMY_DEFEATED     := "on_enemy_defeated"
const ON_SHOP_OPEN          := "on_shop_open"
const ON_ROUND_START        := "on_round_start"
const ON_ROUND_END          := "on_round_end"
const ON_ABILITY_USED       := "on_ability_used"
const ON_CRITICAL_HIT       := "on_critical_hit"
const ON_MANA_SPENT         := "on_mana_spent"
const ON_GOLD_CHANGED       := "on_gold_changed"
const ON_FLAG_SET           := "on_flag_set"
const ON_TAROT_ACQUIRED     := "on_tarot_acquired"
const ON_EQUIPMENT_ACQUIRED := "on_equipment_acquired"
const ON_BATTLE_START       := "on_battle_start"
# Publish this once, near the top of battle_scene.gd's _ready(). It resets
# every "once_per_battle" tarot trigger guard and any battle-scoped custom
# handler state (see effect_system.gd and custom_tarot_handlers.gd).
const ON_BUFF_APPLIED       := "on_buff_applied"
# Publish from unit_node.gd's apply_status(), only when a BRAND NEW status
# is added (not a refresh) -- see combat_hooks.gd's wiring checklist for the
# exact payload shape ("is_buff" needs to be computed at the call site).
const ON_SHOP_PURCHASE      := "on_shop_purchase"
# Published by shop_engine.gd itself -- no wiring needed, it's already in
# this project's own code.

# ---- INTERNAL SUBSCRIBER LIST -----------------------------------------------
# Key: event name (String). Value: Array of Callables to run when it fires.
var _subscribers: Dictionary = {}

# ---- PUBLIC API --------------------------------------------------------------

func subscribe(event_name: String, callback: Callable) -> void:
    # Registers 'callback' to run every time 'event_name' is published.
    # callback should accept exactly ONE argument: a Dictionary "payload".
    if not _subscribers.has(event_name):
        _subscribers[event_name] = []
    if not _subscribers[event_name].has(callback):
        _subscribers[event_name].append(callback)


func unsubscribe(event_name: String, callback: Callable) -> void:
    # Stops 'callback' from being notified about 'event_name' in the future.
    # IMPORTANT: always unsubscribe when something is freed (a unit dying,
    # a piece of equipment being unequipped) or you'll eventually try to call
    # a Callable bound to an object that no longer exists.
    if _subscribers.has(event_name):
        _subscribers[event_name].erase(callback)


func publish(event_name: String, payload: Dictionary = {}) -> void:
    # Announces that 'event_name' just happened, with extra info in 'payload'.
    # Every subscriber registered for this event_name gets called immediately,
    # in the order they subscribed.
    if not _subscribers.has(event_name):
        return
    # We loop over a COPY of the array, because a callback might subscribe or
    # unsubscribe something while we're in the middle of looping, which would
    # otherwise corrupt the loop we're iterating.
    for callback in _subscribers[event_name].duplicate():
        if callback.is_valid():
            callback.call(payload)
        else:
            # The object this callback belonged to was freed without
            # unsubscribing first -- clean it up so it doesn't pile up forever.
            _subscribers[event_name].erase(callback)
