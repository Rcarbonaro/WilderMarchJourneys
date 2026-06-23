# res://scripts/autoloads/custom_equipment_handlers.gd
#
# CUSTOM EQUIPMENT HANDLERS -- the unique mechanic behind every Advanced
# Equipment item. Each piece of gear that needs more than a flat stat bonus
# (which is most of them) gets ONE block of functions here.
#
# HOW THIS CONNECTS TO THE REST OF THE SYSTEM:
#   - equipment_runtime.gd calls on_equip(custom_id, unit) the moment a unit
#     wearing this item is spawned into a battle.
#   - on_equip() registers whatever CombatHooks callback this item needs
#     (a damage modifier, a round-tick, a death reaction, etc.)
#   - on_unequip() removes that callback again, so gear that's taken off (or
#     a unit that dies) doesn't keep affecting the game forever.
#
# A NOTE ON SIMPLE ITEMS: Barbed Arrow is just flat/percent stat bonuses with
# no special behaviour -- it has no entry here at all. Its bonuses are
# handled entirely by equipment_runtime.gd reading its plain "add_stat"
# effects, which is why has_handler() below doesn't list it.
#
# CONVENTION USED THROUGHOUT THIS FILE: every ATK bonus is mirrored to MATK,
# and every DEF bonus is mirrored to MDEF, exactly like the base items. That
# mirroring is baked directly into each item's JSON (two add_stat effects)
# rather than hidden in code, so it stays visible and editable as content.

extends Node

# ---- PER-UNIT RUNTIME STATE --------------------------------------------------
# Keyed directly by the live UnitNode reference (Godot allows using an
# Object as a Dictionary key). Cleared in on_unequip() so nothing leaks
# between battles.
var _bloodthirster_stacks: Dictionary = {}   # unit -> int (0-4)
var _bloodthirster_acted: Dictionary  = {}   # unit -> bool (attacked this round?)
var _stoneheart_triggered: Dictionary = {}   # unit -> bool (one-time per battle)
var _oracle_lens_used: Dictionary     = {}   # unit -> bool (one-time per battle)

# We remember the EXACT bound Callables we registered with CombatHooks so we
# can remove the right one again on unequip (you can only erase a Callable
# from an Array if you have the identical Callable you put in).
var _registered_callbacks: Dictionary = {}   # "<custom_id>:<unit instance id>" -> Array of {list, callback}


func has_handler(custom_id: String) -> bool:
    return custom_id in [
        "bloodthirster", "vanguards_edge", "heartpiercer", "spellforged_blade",
        "heavy_plate", "stoneheart_mail", "aegis_codex", "mirrorplate",
        "vital_bloom", "soulweaver_charm", "bloody_mantle", "soul_jar",
        "oracles_lens", "crystal_sight",
    ]


func on_equip(custom_id: String, unit) -> void:
    match custom_id:
        "bloodthirster":     _equip_bloodthirster(unit)
        "vanguards_edge":    _equip_vanguards_edge(unit)
        "heartpiercer":      _equip_heartpiercer(unit)
        "spellforged_blade": _equip_spellforged_blade(unit)
        "heavy_plate":       _equip_heavy_plate(unit)
        "stoneheart_mail":   _equip_stoneheart_mail(unit)
        "aegis_codex":       _equip_aegis_codex(unit)
        "mirrorplate":       _equip_mirrorplate(unit)
        "vital_bloom":       _equip_vital_bloom(unit)
        "soulweaver_charm":  _equip_soulweaver_charm(unit)
        "bloody_mantle":     _equip_bloody_mantle(unit)
        "soul_jar":          _equip_soul_jar(unit)
        "oracles_lens":      _equip_oracles_lens(unit)
        "crystal_sight":     _equip_crystal_sight(unit)


func on_unequip(custom_id: String, unit) -> void:
    var key := custom_id + ":" + str(unit.get_instance_id())
    if _registered_callbacks.has(key):
        for entry in _registered_callbacks[key]:
            var list: Array = entry["list"]
            list.erase(entry["callback"])
        _registered_callbacks.erase(key)
    _bloodthirster_stacks.erase(unit)
    _bloodthirster_acted.erase(unit)
    _stoneheart_triggered.erase(unit)
    _oracle_lens_used.erase(unit)
    unit.momentum_bonuses.erase("equip_custom_" + custom_id)


func _track(custom_id: String, unit, list: Array, callback: Callable) -> void:
    # Helper: registers 'callback' into 'list' AND remembers it so
    # on_unequip() can find and remove the exact same Callable later.
    list.append(callback)
    var key := custom_id + ":" + str(unit.get_instance_id())
    if not _registered_callbacks.has(key):
        _registered_callbacks[key] = []
    _registered_callbacks[key].append({"list": list, "callback": callback})

# ==============================================================================
# 1. BLOODTHIRSTER (Blade + Blade)
# +5 ATK/+5 MATK flat (plain add_stat effects in its JSON, handled by
# equipment_runtime.gd -- not repeated here). Each round the wearer attacks,
# gain +1 ATK/+1 MATK, up to +4 total; resets to +0 the round they don't attack.
# ==============================================================================

func _equip_bloodthirster(unit) -> void:
    _bloodthirster_stacks[unit] = 0
    _bloodthirster_acted[unit] = false
    _track("bloodthirster", unit, CombatHooks.after_ability_used,
        Callable(self, "_bloodthirster_on_ability_used").bind(unit))
    _track("bloodthirster", unit, CombatHooks.on_unit_round_tick,
        Callable(self, "_bloodthirster_round_tick").bind(unit))


func _bloodthirster_on_ability_used(caster, ability, unit) -> void:
    if caster == unit and ability.base_damage_multiplier > 0:
        _bloodthirster_acted[unit] = true


func _bloodthirster_round_tick(tick_unit, unit) -> void:
    if tick_unit != unit:
        return
    if _bloodthirster_acted.get(unit, false):
        _bloodthirster_stacks[unit] = min(_bloodthirster_stacks.get(unit, 0) + 1, 4)
    else:
        _bloodthirster_stacks[unit] = 0
    _bloodthirster_acted[unit] = false
    var stacks: int = _bloodthirster_stacks[unit]
    unit.momentum_bonuses["equip_custom_bloodthirster"] = {"atk": stacks, "matk": stacks}

# ==============================================================================
# 2. VANGUARD'S EDGE (Blade + Armor)
# +2 ATK/+2 MATK, +2 DEF/+2 MDEF flat. When attacking an enemy whose DEF is
# lower than the wearer's own DEF, add 33% (rounded up) of that difference
# as bonus flat damage.
# ==============================================================================

func _equip_vanguards_edge(unit) -> void:
    _track("vanguards_edge", unit, CombatHooks.outgoing_damage_modifiers,
        Callable(self, "_vanguards_edge_modify_damage").bind(unit))


func _vanguards_edge_modify_damage(attacker, target, damage: int, is_crit: bool, unit) -> int:
    if attacker != unit:
        return damage
    var def_diff: int = unit.get_effective_def() - target.get_effective_def()
    if def_diff <= 0:
        return damage
    return damage + int(ceil(def_diff * 0.33))

# ==============================================================================
# 3. HEARTPIERCER (Blade + Talisman)
# +2 ATK/+2 MATK, +5 HP flat. ATK (mirrored to MATK) increases by 1 for
# every 10 HP the wearer is missing from max. Recalculated at the start of
# every one of the wearer's own turns.
# ==============================================================================

func _equip_heartpiercer(unit) -> void:
    _track("heartpiercer", unit, CombatHooks.on_unit_round_tick,
        Callable(self, "_heartpiercer_round_tick").bind(unit))
    _heartpiercer_recalculate(unit)


func _heartpiercer_round_tick(tick_unit, unit) -> void:
    if tick_unit == unit:
        _heartpiercer_recalculate(unit)


func _heartpiercer_recalculate(unit) -> void:
    var missing_hp: int = unit.get_stats().hp - unit.current_hp
    var bonus: int = max(0, int(floor(missing_hp / 10.0)))
    unit.momentum_bonuses["equip_custom_heartpiercer"] = {"atk": bonus, "matk": bonus}

# ==============================================================================
# 4. SPELLFORGED BLADE (Blade + Spellbook)
# +2 ATK/+2 MATK, +10 mana flat. Damage dealt increases 10% for every 20
# mana the wearer is missing from max.
# ==============================================================================

func _equip_spellforged_blade(unit) -> void:
    _track("spellforged_blade", unit, CombatHooks.outgoing_damage_modifiers,
        Callable(self, "_spellforged_blade_modify_damage").bind(unit))


func _spellforged_blade_modify_damage(attacker, target, damage: int, is_crit: bool, unit) -> int:
    if attacker != unit:
        return damage
    var missing_mana: int = unit.get_stats().mana - unit.current_mana
    var chunks: int = max(0, int(floor(missing_mana / 20.0)))
    if chunks <= 0:
        return damage
    return int(damage * (1.0 + chunks * 0.10))

# ==============================================================================
# 5. BARBED ARROW (Blade + Monocle) -- intentionally no handler here.
# +3 ATK/+3 MATK, +20% crit chance, +40% crit damage -- ALL plain add_stat
# effects, fully handled by equipment_runtime.gd already.
# ==============================================================================

# ==============================================================================
# 6. HEAVY PLATE (Armor + Armor)
# +5 DEF/+5 MDEF flat to the wearer. Every ally within 1 tile (including
# diagonals) gets +2 DEF/+2 MDEF for as long as they stay nearby. This is
# recalculated every round, like a passive mini-aura.
# ==============================================================================

func _equip_heavy_plate(unit) -> void:
    _track("heavy_plate", unit, CombatHooks.on_unit_round_tick,
        Callable(self, "_heavy_plate_round_tick").bind(unit))


func _heavy_plate_round_tick(tick_unit, unit) -> void:
    if tick_unit != unit or unit.grid_ref == null:
        return
    var bonus_key := "equip_custom_heavy_plate_" + str(unit.get_instance_id())
    var nearby_allies := []
    for cell in unit.grid_ref.unit_positions:
        var other = unit.grid_ref.unit_positions[cell]
        if other == unit or not is_instance_valid(other) or other.is_player_unit != unit.is_player_unit:
            continue
        var dist = max(abs(other.grid_position.x - unit.grid_position.x),
                        abs(other.grid_position.y - unit.grid_position.y))
        if dist <= 1:
            nearby_allies.append(other)
            other.momentum_bonuses[bonus_key] = {"def": 2, "mdef": 2}
    # Strip the bonus from anyone who drifted out of range this round.
    for other in unit.grid_ref.unit_positions.values():
        if is_instance_valid(other) and other != unit and not other in nearby_allies:
            other.momentum_bonuses.erase(bonus_key)

# ==============================================================================
# 7. STONEHEART MAIL (Armor + Talisman)
# +1 DEF/+1 MDEF, +5 HP flat. The FIRST time the wearer drops to/below 25%
# of max HP in a battle, gain temporary HP equal to 50% of max HP for 2
# rounds. Reuses the combat side's EXISTING shield system (apply_shield) --
# "temporary HP that absorbs damage first" is exactly what a shield already is.
# ==============================================================================

func _equip_stoneheart_mail(unit) -> void:
    _stoneheart_triggered[unit] = false
    _track("stoneheart_mail", unit, CombatHooks.on_damage_applied_reactions,
        Callable(self, "_stoneheart_mail_on_damage_applied").bind(unit))


func _stoneheart_mail_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, unit) -> void:
    if target != unit or _stoneheart_triggered.get(unit, false):
        return
    var max_hp: int = unit.get_stats().hp
    if float(unit.current_hp) / float(max_hp) <= 0.25:
        _stoneheart_triggered[unit] = true
        if unit.grid_ref != null:
            unit.grid_ref.apply_shield(unit, int(max_hp * 0.5), 2)

# ==============================================================================
# 8. AEGIS CODEX (Armor + Spellbook)
# +1 DEF/+1 MDEF, +10% mana flat. Whenever the wearer uses an ability that
# has a cooldown, gain +2 DEF/+2 MDEF for 1 round. Built the same way
# synergy_system.gd builds its own temporary bonuses: construct a
# StatusEffectData on the fly and apply it.
# ==============================================================================

func _equip_aegis_codex(unit) -> void:
    _track("aegis_codex", unit, CombatHooks.after_ability_used,
        Callable(self, "_aegis_codex_after_ability").bind(unit))


func _aegis_codex_after_ability(caster, ability, unit) -> void:
    if caster != unit or ability.cooldown_rounds <= 0:
        return
    var status := StatusEffectData.new()
    status.id = "aegis_codex_buff"
    status.display_name = "Aegis Codex"
    status.duration_rounds = 1
    status.can_stack = false
    status.def_modifier = 2
    status.mdef_modifier = 2
    unit.apply_status(status)

# ==============================================================================
# 9. MIRRORPLATE (Armor + Monocle)
# +1 DEF/+1 MDEF, +15% crit chance flat. On being hit, a chance equal to the
# wearer's OWN crit chance to reflect 10% of the damage taken back at the
# attacker as a critical hit (scaled by the wearer's crit damage). Can never
# reduce the attacker below 1 HP.
# ==============================================================================

func _equip_mirrorplate(unit) -> void:
    _track("mirrorplate", unit, CombatHooks.on_damage_applied_reactions,
        Callable(self, "_mirrorplate_on_damage_applied").bind(unit))


func _mirrorplate_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, unit) -> void:
    if target != unit or attacker == null or not is_instance_valid(attacker):
        return
    if randf() * 100.0 >= unit.get_effective_crit_chance():
        return
    var crit_mult: float = unit.get_effective_crit_damage() / 100.0
    var reflect := int(actual_damage * 0.10 * crit_mult)
    reflect = min(reflect, attacker.current_hp - 1)   # never lethal
    if reflect > 0:
        attacker.take_damage(reflect, "true")

# ==============================================================================
# 10. VITAL BLOOM (Talisman + Talisman)
# No ATK/DEF -- pure defense. Gain temporary HP equal to 2% of max HP at the
# start of every round; it always REPLACES the previous amount rather than
# stacking (reusing apply_shield(), which already overwrites instead of
# adding when called again on the same unit).
# ==============================================================================

func _equip_vital_bloom(unit) -> void:
    _track("vital_bloom", unit, CombatHooks.on_unit_round_tick,
        Callable(self, "_vital_bloom_round_tick").bind(unit))


func _vital_bloom_round_tick(tick_unit, unit) -> void:
    if tick_unit != unit or unit.grid_ref == null:
        return
    unit.grid_ref.apply_shield(unit, int(ceil(unit.get_stats().hp * 0.02)), 1)

# ==============================================================================
# 11. SOULWEAVER CHARM (Talisman + Spellbook)
# +5 HP, +15 mana flat. Whenever the wearer spends mana, heal 2% of max HP
# for every 10 mana spent (rounded UP to the next whole "chunk" of 10).
# ==============================================================================

func _equip_soulweaver_charm(unit) -> void:
    _track("soulweaver_charm", unit, CombatHooks.on_mana_spent,
        Callable(self, "_soulweaver_charm_on_mana_spent").bind(unit))


func _soulweaver_charm_on_mana_spent(spender, amount: int, unit) -> void:
    if spender != unit or amount <= 0:
        return
    var chunks: int = int(ceil(amount / 10.0))
    unit.heal(chunks * int(ceil(unit.get_stats().hp * 0.02)))

# ==============================================================================
# 12. BLOODY MANTLE (Talisman + Monocle)
# Upon dealing a critical hit, gain temporary HP equal to 25% of the
# wearer's ATK (rounded down).
# ==============================================================================

func _equip_bloody_mantle(unit) -> void:
    _track("bloody_mantle", unit, CombatHooks.on_damage_applied_reactions,
        Callable(self, "_bloody_mantle_on_damage_applied").bind(unit))


func _bloody_mantle_on_damage_applied(attacker, target, actual_damage: int, is_crit: bool, unit) -> void:
    if attacker != unit or not is_crit:
        return
    var temp_hp := int(floor(unit.get_effective_atk() * 0.25))
    if temp_hp > 0 and unit.grid_ref != null:
        unit.grid_ref.apply_shield(unit, temp_hp, 1)

# ==============================================================================
# 13. SOUL JAR (Spellbook + Spellbook)
# Whenever an ENEMY of the wearer dies within 5 tiles of the wearer, restore
# 5% (rounded up) of the wearer's max mana, up to their maximum.
# ==============================================================================

func _equip_soul_jar(unit) -> void:
    _track("soul_jar", unit, CombatHooks.on_unit_died,
        Callable(self, "_soul_jar_on_unit_died").bind(unit))


func _soul_jar_on_unit_died(dead_unit, unit) -> void:
    if not is_instance_valid(unit) or dead_unit.is_player_unit == unit.is_player_unit:
        return
    var dist = abs(dead_unit.grid_position.x - unit.grid_position.x) + \
               abs(dead_unit.grid_position.y - unit.grid_position.y)
    if dist <= 5:
        unit.restore_mana(int(ceil(unit.get_stats().mana * 0.05)))

# ==============================================================================
# 14. ORACLE'S LENS (Spellbook + Monocle)
# +10 mana, +10% crit chance flat. The FIRST spell-type ability the wearer
# casts each battle gets +50% crit chance, one time only.
# ==============================================================================

func _equip_oracles_lens(unit) -> void:
    _oracle_lens_used[unit] = false
    _track("oracles_lens", unit, CombatHooks.before_ability_used,
        Callable(self, "_oracles_lens_before_ability").bind(unit))
    _track("oracles_lens", unit, CombatHooks.after_ability_used,
        Callable(self, "_oracles_lens_after_ability").bind(unit))


func _oracles_lens_before_ability(caster, ability, unit) -> void:
    if caster != unit or _oracle_lens_used.get(unit, false) or ability.ability_type != "spell":
        return
    unit.momentum_bonuses["equip_custom_oracles_lens_temp"] = {"crit_chance": 50.0}


func _oracles_lens_after_ability(caster, ability, unit) -> void:
    if caster != unit:
        return
    if unit.momentum_bonuses.has("equip_custom_oracles_lens_temp"):
        unit.momentum_bonuses.erase("equip_custom_oracles_lens_temp")
        _oracle_lens_used[unit] = true

# ==============================================================================
# 15. CRYSTAL SIGHT (Monocle + Monocle)
# +20% crit chance flat. Critical hits made by the wearer ignore 25% of the
# target's effective DEF for that hit.
# ==============================================================================

func _equip_crystal_sight(unit) -> void:
    _track("crystal_sight", unit, CombatHooks.outgoing_damage_modifiers,
        Callable(self, "_crystal_sight_modify_damage").bind(unit))


func _crystal_sight_modify_damage(attacker, target, damage: int, is_crit: bool, unit) -> int:
    if attacker != unit or not is_crit:
        return damage
    # We only receive the FINAL damage number here, not the raw ATK/DEF used
    # to build it -- so this approximates "ignore 25% of DEF" by adding back
    # 25% of the target's effective DEF as flat bonus damage. Good enough for
    # most cases; for an exact recompute you'd extend the hook signature to
    # pass atk/def through instead of just the final number.
    return damage + int(target.get_effective_def() * 0.25)
