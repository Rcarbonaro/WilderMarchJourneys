# res://scripts/sim/sim_economy.gd
#
# SIM ECONOMY -- headless, UI-free automation of the shop/forge/equip/skill-
# scroll loop, for running many simulated stages without a human clicking
# through ShopScene/DeploymentScene. Every function here reads and writes a
# RunState directly (via the same ContentLoader/ShopEngine/EffectSystem
# autoloads the real scenes use), so a run driven through this script ends
# up in an identical shape to one played by hand -- it can be handed
# straight to a real battle afterward.
#
# NOT an autoload. Instantiate where you need it:
#   var econ := SimEconomy.new()
#   var report := econ.run_shop_phase(RunManager.current_run)
#
# ASSUMPTIONS -- flag these if your project's rules differ:
#   - ShopEngine.generate_shop(run_state) has already been called for this
#     stage (run_state.shop_inventory is populated) before run_shop_phase().
#   - "auto buy" = every BASIC equipment entry currently on offer, bought
#     greedily while gold allows. Units, advanced items (never offered
#     directly anyway), and consumables are left alone by the buying pass.
#   - forging_recipes.json currently covers every subtype pair (7 subtypes,
#     28 recipes -- all combos exist), so random pairing practically always
#     finds a match. The lookup is still checked rather than assumed.
#   - "a unit with mana" = their current effective mana > 0 (non-casters
#     have base mana == 0 and, before this pass, no mana-granting gear).
#   - The "only equip X to Y" rules are read as hard constraints, per the
#     brief's wording: if no qualifying unit has an open slot, the item is
#     left in equipment_inventory rather than mis-assigned, and gets
#     another chance next stage. Search "return {}" below to relax this to
#     "fall back to anyone with a slot" instead.
#   - "crit units" is read as synergy_tags containing "Critical" first
#     (the game's own vocabulary for this -- see unit_data.gd), falling
#     back to whoever currently has the highest crit_chance if no unit
#     carries that tag yet.

class_name SimEconomy
extends RefCounted

const MAX_EQUIP_SLOTS := 3
const MAX_ENHANCEMENTS_PER_ABILITY := 3   # mirrors deployment_manager.gd's own const

var _unit_data_cache: Dictionary = {}   # unit_id -> UnitData, local to this instance


# ═══════════════════════════════════════════════════════════════════════════
# PUBLIC ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

func run_shop_phase(run_state: RunState) -> Dictionary:
	# Runs the full automated pass for one shop visit: buy every basic item
	# on offer, combine whatever basics end up in the bag, equip everything
	# equippable onto a suitable unit, then spend any skill scrolls on
	# hand. Returns a report Dictionary, handy for per-stage logging.
	var report := {}
	report["bought"] = auto_buy_basic_items(run_state)
	report["combined"] = auto_combine_basic_items(run_state)
	report["equipped"] = auto_equip_inventory(run_state)
	report["scrolls_used"] = auto_use_skill_scrolls(run_state)
	return report


# ═══════════════════════════════════════════════════════════════════════════
# 1. AUTO-BUY -- every basic equipment item on offer, while gold allows
# ═══════════════════════════════════════════════════════════════════════════

func auto_buy_basic_items(run_state: RunState) -> Array:
	var bought: Array = []
	# Snapshot first -- ShopEngine.purchase() removes the bought entry from
	# run_state.shop_inventory as it goes, so iterating the live array
	# directly would skip entries (mutating a container while walking it).
	var offer_snapshot: Array = run_state.shop_inventory.duplicate(true)

	for entry in offer_snapshot:
		var shop_entry_id: String = entry.get("shop_entry_id", "")
		var shop_data: Dictionary = ContentLoader.get_shop_entry(shop_entry_id)
		if shop_data.get("item_type", "") != "equipment":
			continue   # skip units and consumables -- gear only, per the brief
		var item_id: String = shop_data.get("item_id", "")
		if ContentLoader.get_equipment(item_id).get("type", "") != "basic":
			continue   # skip advanced items (never offered directly anyway)

		var price: int = int(entry.get("final_price", 0))
		if run_state.gold < price:
			continue   # can't afford THIS one -- keep checking the rest of the offer

		var result := ShopEngine.purchase(shop_entry_id, run_state)
		if result.get("success", false):
			bought.append(item_id)

	return bought


# ═══════════════════════════════════════════════════════════════════════════
# 2. AUTO-COMBINE -- randomly pair up basic items in the bag and forge them
# ═══════════════════════════════════════════════════════════════════════════

func auto_combine_basic_items(run_state: RunState) -> Array:
	var combined_log: Array = []

	var basics: Array = []
	for item_id in run_state.equipment_inventory:
		if ContentLoader.get_equipment(item_id).get("type", "") == "basic":
			basics.append(item_id)
	basics.shuffle()

	# Walk the shuffled list two at a time. Every subtype pair currently has
	# a recipe (see forging_recipes.json), so this will practically always
	# match -- but the lookup is still checked rather than assumed, so nothing
	# breaks if a recipe is ever removed.
	var i := 0
	while i + 1 < basics.size():
		var item_a: String = basics[i]
		var item_b: String = basics[i + 1]
		var subtype_a: String = ContentLoader.get_equipment(item_a).get("subtype", "")
		var subtype_b: String = ContentLoader.get_equipment(item_b).get("subtype", "")
		var recipe: Dictionary = ContentLoader.get_forging_recipe(subtype_a, subtype_b)

		if recipe.is_empty():
			i += 1   # no recipe for this particular pairing -- leave both, advance one at a time
			continue

		var output_id: String = recipe.get("output_equipment_id", "")
		run_state.equipment_inventory.erase(item_a)
		run_state.equipment_inventory.erase(item_b)
		run_state.equipment_inventory.append(output_id)
		combined_log.append({"inputs": [item_a, item_b], "output": output_id})
		i += 2

	return combined_log


# ═══════════════════════════════════════════════════════════════════════════
# 3. AUTO-EQUIP -- send every remaining bag item to a suitable unit
# ═══════════════════════════════════════════════════════════════════════════
# Preference per item (checked in this order):
#   - grants crit_chance      -> a unit tagged synergy "Critical", else
#                                whoever currently has the highest crit_chance
#   - grants mana             -> ONLY a unit whose current mana > 0
#   - grants atk, not matk    -> ONLY a unit whose current atk > matk
#   - grants matk, not atk    -> ONLY a unit whose current matk > atk
#   - anything else (pure def/mdef/hp, or items with both atk AND matk)
#                             -> whichever eligible unit holds the fewest
#                                items right now, to spread gear around

func auto_equip_inventory(run_state: RunState) -> Array:
	var equipped_log: Array = []
	var roster := _get_full_roster(run_state)   # entries are references INTO run_state

	# Only basic/advanced gear gets auto-equipped -- consumables (potions,
	# named scroll items) stay in the bag; they trigger on use, not on equip.
	var pool: Array = []
	for item_id in run_state.equipment_inventory:
		if ContentLoader.get_equipment(item_id).get("type", "") in ["basic", "advanced"]:
			pool.append(item_id)

	for item_id in pool:
		var bonuses := _get_stat_bonuses(item_id)
		var target: Dictionary = _pick_target_for_item(bonuses, roster)
		if target.is_empty():
			continue   # no qualifying unit with an open slot right now -- try again next stage

		if _equip_item_to_entry(run_state, target, item_id):
			equipped_log.append({"item": item_id, "unit": target.get("unit_id", "")})

	return equipped_log


func _pick_target_for_item(bonuses: Dictionary, roster: Array) -> Dictionary:
	var open_slot_entries: Array = roster.filter(func(e): return _has_open_slot(e))
	if open_slot_entries.is_empty():
		return {}

	if bonuses.get("crit", 0.0) > 0.0:
		var crit_units: Array = open_slot_entries.filter(func(e):
			var ud := _get_unit_data(e.get("unit_id", ""))
			return ud != null and ud.synergy_tags.has("Critical")
		)
		if not crit_units.is_empty():
			return _fewest_items_entry(crit_units)
		return _highest_stat_entry(open_slot_entries, "crit_chance")   # always non-empty here

	if bonuses.get("mana", 0.0) > 0.0:
		var casters: Array = open_slot_entries.filter(func(e): return _current_stat(e, "mana") > 0.0)
		if casters.is_empty():
			return {}   # "only" units with mana -- don't hand a spellbook to a non-caster
		return _fewest_items_entry(casters)

	if bonuses.get("atk", 0.0) > 0.0 and bonuses.get("matk", 0.0) <= 0.0:
		var attackers: Array = open_slot_entries.filter(func(e): return _current_stat(e, "atk") > _current_stat(e, "matk"))
		if attackers.is_empty():
			return {}
		return _fewest_items_entry(attackers)

	if bonuses.get("matk", 0.0) > 0.0 and bonuses.get("atk", 0.0) <= 0.0:
		var casters_atk: Array = open_slot_entries.filter(func(e): return _current_stat(e, "matk") > _current_stat(e, "atk"))
		if casters_atk.is_empty():
			return {}
		return _fewest_items_entry(casters_atk)

	# Doesn't match any specific rule (pure def/mdef/hp item, or a hybrid
	# atk+matk item) -- spread it onto whoever has the fewest items so far.
	return _fewest_items_entry(open_slot_entries)


func _equip_item_to_entry(run_state: RunState, entry: Dictionary, item_id: String) -> bool:
	var equipped: Array = entry.get("equipped_item_ids", [])
	while equipped.size() < MAX_EQUIP_SLOTS:
		equipped.append(null)
	var slot := -1
	for i in range(MAX_EQUIP_SLOTS):
		if equipped[i] == null or equipped[i] == "":
			slot = i
			break
	if slot == -1:
		return false
	equipped[slot] = item_id
	entry["equipped_item_ids"] = equipped
	run_state.equipment_inventory.erase(item_id)
	return true


# ═══════════════════════════════════════════════════════════════════════════
# 4. AUTO SKILL SCROLLS -- random unit, random enhanceable ability, random enhancement
# ═══════════════════════════════════════════════════════════════════════════
# Mirrors deployment_manager.gd's own scroll flow exactly (same
# "ability_enhancements" field, same max-3-per-ability overwrite rule) so a
# simulated run's save shape matches a hand-played one. Currently only
# scans unit_data.starting_abilities, same as the real picker -- if you
# later make level-gated abilities scroll-eligible too, update both places.

func auto_use_skill_scrolls(run_state: RunState) -> Array:
	var log: Array = []
	var count: int = int(run_state.runtime_effect_state.get("skill_scroll_count", 0))

	while count > 0:
		var applied := _apply_one_random_scroll(run_state)
		if applied.is_empty():
			break   # nobody on the roster has an enhanceable ability -- stop trying
		log.append(applied)
		count -= 1

	run_state.runtime_effect_state["skill_scroll_count"] = count
	return log


func _apply_one_random_scroll(run_state: RunState) -> Dictionary:
	var roster := _get_full_roster(run_state)
	var candidates: Array = []   # [{entry, ability}]

	for entry in roster:
		var unit_data := _get_unit_data(entry.get("unit_id", ""))
		if unit_data == null:
			continue
		for ability in unit_data.starting_abilities:
			if ability != null and not ability.eligible_enhancements.is_empty():
				candidates.append({"entry": entry, "ability": ability})

	if candidates.is_empty():
		return {}

	var choice: Dictionary = candidates[randi() % candidates.size()]
	var entry: Dictionary = choice["entry"]
	var ability: AbilityData = choice["ability"]
	var enhancement: AbilityEnhancementData = ability.eligible_enhancements[randi() % ability.eligible_enhancements.size()]

	var applied: Dictionary = entry.get("ability_enhancements", {})
	var applied_for_ability: Array = applied.get(ability.id, [])
	if applied_for_ability.size() >= MAX_ENHANCEMENTS_PER_ABILITY:
		applied_for_ability[randi() % applied_for_ability.size()] = enhancement.id   # overwrite a random existing one
	else:
		applied_for_ability.append(enhancement.id)
	applied[ability.id] = applied_for_ability
	entry["ability_enhancements"] = applied

	return {"unit": entry.get("unit_id", ""), "ability": ability.id, "enhancement": enhancement.id}


# ═══════════════════════════════════════════════════════════════════════════
# SHARED HELPERS
# ═══════════════════════════════════════════════════════════════════════════

func _get_full_roster(run_state: RunState) -> Array:
	# party + bench, deduplicated by instance_id (party wins) -- same rule
	# deployment_manager.gd's _get_full_roster() uses. Dictionaries are
	# reference types in GDScript, so entries returned here are the SAME
	# objects living in run_state.party/bench -- mutating one mutates the
	# real run_state directly, no write-back step needed.
	var roster: Array = []
	var seen: Dictionary = {}
	for entry in run_state.party + run_state.bench:
		var iid: String = entry.get("instance_id", "")
		if iid != "" and seen.has(iid):
			continue
		seen[iid] = true
		roster.append(entry)
	return roster


func _get_unit_data(unit_id: String) -> UnitData:
	if _unit_data_cache.has(unit_id):
		return _unit_data_cache[unit_id]
	var path := "res://resources/units/" + unit_id + "_data.tres"
	var data: UnitData = (load(path) as UnitData) if ResourceLoader.exists(path) else null
	_unit_data_cache[unit_id] = data
	return data


func _has_open_slot(entry: Dictionary) -> bool:
	var equipped: Array = entry.get("equipped_item_ids", [null, null, null])
	if equipped.size() < MAX_EQUIP_SLOTS:
		return true
	for slot in equipped:
		if slot == null or slot == "":
			return true
	return false


func _get_stat_bonuses(item_id: String) -> Dictionary:
	# Reads the SAME "effects" array the real preview UI describes items
	# from (deployment_manager.gd's _describe_item_for_preview()), so this
	# stays correct for basic items AND every forged advanced item alike,
	# with no per-item special-casing needed.
	var totals := {"atk": 0.0, "matk": 0.0, "crit": 0.0, "mana": 0.0}
	for effect in ContentLoader.get_equipment(item_id).get("effects", []):
		if effect.get("type", "") != "add_stat":
			continue
		match effect.get("stat", ""):
			"atk": totals["atk"] += float(effect.get("amount", 0))
			"matk": totals["matk"] += float(effect.get("amount", 0))
			"crit_chance": totals["crit"] += float(effect.get("amount", 0))
			"mana": totals["mana"] += float(effect.get("amount", 0))
	return totals


func _current_stat(entry: Dictionary, stat: String) -> float:
	# Base stat at current level, plus FLAT bonuses from items already
	# equipped on this unit. An approximation -- percent-mode bonuses and
	# permanent_modifiers from tarot/encounters aren't folded in -- but
	# good enough to classify "which lane is this unit in" for gearing.
	# battle_manager.gd / EquipmentRuntime remain the source of truth for
	# exact combat numbers.
	var unit_data := _get_unit_data(entry.get("unit_id", ""))
	if unit_data == null or unit_data.stats_by_level.is_empty():
		return 0.0
	var level: int = clampi(int(entry.get("level", 1)), 1, unit_data.stats_by_level.size())
	var base: StatsData = unit_data.stats_by_level[level - 1]
	var value: float = float(base.get(stat)) if base != null else 0.0

	for equipped_id in entry.get("equipped_item_ids", []):
		if equipped_id == null or equipped_id == "":
			continue
		for effect in ContentLoader.get_equipment(equipped_id).get("effects", []):
			if effect.get("type", "") == "add_stat" and effect.get("stat", "") == stat \
			and effect.get("value_mode", "flat") == "flat":
				value += float(effect.get("amount", 0))
	return value


func _highest_stat_entry(entries: Array, stat: String) -> Dictionary:
	var best: Dictionary = {}
	var best_value := -INF
	for entry in entries:
		var v := _current_stat(entry, stat)
		if v > best_value:
			best_value = v
			best = entry
	return best


func _fewest_items_entry(entries: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_count := 999
	for entry in entries:
		var count := 0
		for slot in entry.get("equipped_item_ids", []):
			if slot != null and slot != "":
				count += 1
		if count < best_count:
			best_count = count
			best = entry
	return best
