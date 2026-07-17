# res://scripts/battle/interrupt_system.gd
# ==============================================================================
# INTERRUPT SYSTEM — lets a unit react to being hit by firing an ability back,
# EVEN DURING THE ATTACKER'S OWN TURN. Fully generic: works for any unit with
# innate_interrupts on their UnitData, or any status with grants_interrupt.
#
# HOW IT HOOKS IN:
#   ability_executor.gd already calls
#     CombatHooks.run_damage_applied_reactions(caster, target, actual_damage, is_crit)
#   immediately after target.take_damage() resolves — for EVERY damage
#   instance in the game, player or enemy, on-turn or reactive. We register
#   ourselves into that same chain in _ready(), so no other file needs to
#   change to support this feature.
#
# Add this as a Node (this script attached) under BattleScene, sibling to
# AISystem/AbilityExecutor, and wire it in battle_manager.gd's _ready()
# exactly like aura_manager is wired.
# ==============================================================================
extends Node

var grid_ref: Node = null
var pathfinder_ref: Node = null
var executor_ref: Node = null

func setup(grid: Node, pathfinder: Node, executor: Node) -> void:
	grid_ref       = grid
	pathfinder_ref = pathfinder
	executor_ref   = executor
	if not CombatHooks.on_damage_applied_reactions.has(_on_damage_applied):
		CombatHooks.on_damage_applied_reactions.append(_on_damage_applied)


func _exit_tree() -> void:
	CombatHooks.on_damage_applied_reactions.erase(_on_damage_applied)


func _on_damage_applied(attacker, target, actual_damage: int, _is_crit: bool, damage_type: String) -> void:
	if actual_damage <= 0:
		return
	if not is_instance_valid(target) or target.current_hp <= 0:
		return
	if not is_instance_valid(attacker):
		return
	if not target.has_method("get_active_interrupts"):
		return

	# Fire every eligible interrupt this unit currently carries — innate AND
	# status-granted — independently. This is what makes stacking work: a
	# unit with both an innate lash-out and a Counterattack Stance buff can
	# fire both off the same hit, each with its own cooldown/chance/ability.
	for entry in target.get_active_interrupts():
		_try_fire_interrupt(target, attacker, entry)


func _try_fire_interrupt(target, attacker, entry: Dictionary) -> void:
	var data: InterruptAbilityData = entry["data"]
	if data.trigger != "on_damaged":
		return
	if data.ability == null:
		return

	# Team-relationship check.
	if not data.can_trigger_on_own_turn and attacker.is_player_unit == target.is_player_unit:
		return

	# Cooldown check (per-unit, keyed by this interrupt's id).
	var cd: int = target.interrupt_cooldowns.get(data.id, 0)
	if cd > 0:
		return

	# Chance roll.
	if randf() > data.chance:
		return

	# Attacker must still be alive to be counter-hit (unless explicitly
	# allowed to fire regardless).
	if data.requires_attacker_alive and (not is_instance_valid(attacker) or attacker.current_hp <= 0):
		return

	# Range/LOS check — reuse the ability's own targeting rules.
	var dist = (abs(target.grid_position.x - attacker.grid_position.x)
			  + abs(target.grid_position.y - attacker.grid_position.y))
	if dist < data.ability.min_range or dist > data.ability.max_range:
		return
	if data.ability.requires_line_of_sight and pathfinder_ref != null:
		if not pathfinder_ref.has_line_of_sight(target.grid_position, attacker.grid_position):
			return

	# All checks passed — fire it. Not awaited: interrupts happen "alongside"
	# whatever's already resolving, same fire-and-forget pattern the rest of
	# CombatHooks' reaction callbacks use (Thorns, Mirrorplate, etc.).
	_execute_interrupt(target, attacker, data)


func _execute_interrupt(target, attacker, data: InterruptAbilityData) -> void:
	if data.cooldown_rounds > 0:
		target.interrupt_cooldowns[data.id] = data.cooldown_rounds

	if target.has_method("look_at_target"):
		target.look_at_target(attacker.grid_position)
	if target.has_method("play_animation"):
		target.play_animation("attack")

	await get_tree().create_timer(0.3).timeout
	if not is_instance_valid(target) or target.current_hp <= 0:
		return
	if not is_instance_valid(attacker):
		return

	await executor_ref.execute_ability(
		target, data.ability, [attacker.grid_position], attacker.grid_position
	)

	if is_instance_valid(target) and target.has_method("play_animation"):
		target.play_animation("idle")
