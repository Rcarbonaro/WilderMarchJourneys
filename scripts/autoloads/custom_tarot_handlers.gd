# res://scripts/autoloads/custom_tarot_handlers.gd
#
# CUSTOM TAROT HANDLERS -- same pattern as custom_equipment_handlers.gd, but
# for tarot cards whose mechanic needs a CombatHooks modifier (something
# that takes a number and returns a different number) rather than a simple
# EventBus-triggered effects list.
#
# This file registers itself into EffectSystem's SHARED custom_id registry
# in _ready() -- the same registry equipment uses. A tarot card's "custom"
# effect entry references a custom_id exactly like an equipment item does.
#
# Add an autoload entry for this file (after EffectSystem and CombatHooks)
# if you use any tarot card with a "custom" effect type.

extends Node

var _hermit_attacked_this_battle: bool = false


func _ready() -> void:
	EffectSystem.register_custom_handler("the_hermit_isolation", Callable(self, "_setup_hermit_isolation"))
	EventBus.subscribe(EventBus.ON_BATTLE_START, Callable(self, "_on_battle_start"))


func _on_battle_start(_payload: Dictionary) -> void:
	_hermit_attacked_this_battle = false

# ==============================================================================
# THE HERMIT (Isolation)
# "Your first attack each combat deals +20% damage if the target has no
# adjacent allies." This needs to inspect the damage about to be dealt and
# return a BIGGER number -- EventBus can't do that, so it registers into
# CombatHooks.outgoing_damage_modifiers instead, exactly like Vanguard's Edge
# does for equipment. Registered ONCE, run-wide (not per-unit), since this
# bonus applies to whichever player unit attacks first, not one specific unit.
# ==============================================================================

func _setup_hermit_isolation(effect: Dictionary, context: Dictionary) -> void:
	# Called once when "The Hermit" is acquired.
	var callback := Callable(self, "_hermit_modify_damage")
	if not CombatHooks.outgoing_damage_modifiers.has(callback):
		CombatHooks.outgoing_damage_modifiers.append(callback)


func _hermit_modify_damage(attacker, target, damage: int, is_crit: bool) -> int:
	if _hermit_attacked_this_battle:
		return damage
	if attacker == null or target == null or not is_instance_valid(attacker) or not attacker.is_player_unit:
		return damage   # Only the player's FIRST attack counts -- ignore enemy attacks entirely.
	_hermit_attacked_this_battle = true
	if _is_target_isolated(target):
		return int(damage * 1.2)
	return damage


func _is_target_isolated(target) -> bool:
	# Mirrors ability_executor.gd's own _is_target_isolated() check at range 1.
	if target.grid_ref == null:
		return false
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var check_cell = target.grid_position + Vector2i(dx, dy)
			var unit_there = target.grid_ref.get_unit_at(check_cell)
			if unit_there != null and unit_there != target and unit_there.is_player_unit == target.is_player_unit:
				return false
	return true
