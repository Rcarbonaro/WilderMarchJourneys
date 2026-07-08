# res://scripts/systems/tarot_system.gd
#
# AUTOLOAD. Make sure ContentLoader, RunManager, EventBus are ABOVE it. This
# is the ONLY place tarot card effects are decided. Other systems call small
# specific functions here and get back a plain number.

extends Node

const TAROT_FOLDER = "res://content/tarot/"

# ── PER-BATTLE STATE ────────────────────────────────────────────────────────

var _hermit_bonus_used_this_battle: bool = false
var _blade_crit_bonus_used_this_battle: bool = false

func reset_battle_state() -> void:
	# Called by battle_manager.gd's _ready() at the start of every battle.
	_hermit_bonus_used_this_battle = false
	_blade_crit_bonus_used_this_battle = false


func _ready() -> void:
	EventBus.combat_won.connect(_on_combat_won)


# ── CARD LOOKUP ────────────────────────────────────────────────────────────────

var _card_cache: Dictionary = {}

func _get_card_data(tarot_id: String) -> TarotCardData:
	if _card_cache.is_empty():
		for card in ContentLoader.load_all_resources_in_folder(TAROT_FOLDER, "TarotCardData"):
			_card_cache[card.id] = card
	return _card_cache.get(tarot_id, null)


func get_stacks(tarot_id: String) -> int:
	for entry in RunManager.tarot_cards:
		if entry["tarot_id"] == tarot_id:
			return entry["stacks"]
	return 0


# ── CARD SELECTION (data only — no UI yet) ─────────────────────────────────────

func get_random_choices(count: int, cursed: bool) -> Array:
	var pool: Array = ContentLoader.load_all_resources_in_folder(TAROT_FOLDER, "TarotCardData")
	var eligible: Array = []
	for card in pool:
		if card.is_cursed != cursed:
			continue
		if not card.stackable and RunManager.has_tarot(card.id):
			continue
		eligible.append(card)

	eligible.shuffle()
	return eligible.slice(0, min(count, eligible.size()))


func select_card(card: TarotCardData) -> void:
	RunManager.add_tarot_card(card.id)

	match card.effect_id:
		"miser_grant_starting_gold":
			var amount: int = card.effect_params.get("starting_gold_bonus", 10)
			RunManager.add_gold(amount)

	RunManager.save_run()


# ── SHOP DROP-RATE HOOK ────────────────────────────────────────────────────────

func get_shop_weight_multiplier(item) -> float:
	var multiplier: float = 1.0

	# "The Star (Rare Fortune)" — boosts RARE-tier items specifically.
	if RunManager.has_tarot("the_star_rare_fortune") and "rarity" in item and item.rarity == "rare":
		var card = _get_card_data("the_star_rare_fortune")
		var pct: float = card.effect_params.get("bonus_percent", 30.0) if card else 30.0
		var stacks: int = get_stacks("the_star_rare_fortune")
		multiplier *= (1.0 + (pct / 100.0) * stacks)

	# "The Hermit (Isolation)" — boosts units tagged "Isolation".
	if RunManager.has_tarot("the_hermit_isolation") and "synergy_tags" in item and "Isolation" in item.synergy_tags:
		var card = _get_card_data("the_hermit_isolation")
		var pct: float = card.effect_params.get("drop_rate_bonus_percent", 30.0) if card else 30.0
		var stacks: int = get_stacks("the_hermit_isolation")
		multiplier *= (1.0 + (pct / 100.0) * stacks)

	return multiplier


# ── SHOP REFRESH-COST HOOK ────────────────────────────────────────────────────

func get_refresh_cost_modifier() -> int:
	if not RunManager.has_tarot("the_miser_hoard"):
		return 0
	var card = _get_card_data("the_miser_hoard")
	var duration: int = card.effect_params.get("duration_stages", 5) if card else 5
	if RunManager.get_stage_index() > duration:
		return 0
	var extra: int = card.effect_params.get("extra_refresh_cost", 1) if card else 1
	var stacks: int = get_stacks("the_miser_hoard")
	return extra * stacks


# ── COMBAT DAMAGE HOOKS ─────────────────────────────────────────────────────────

func get_isolation_bonus_multiplier(caster, target_is_isolated: bool) -> float:
	if not caster.is_player_unit:
		return 1.0
	if _hermit_bonus_used_this_battle:
		return 1.0
	if not RunManager.has_tarot("the_hermit_isolation"):
		return 1.0
	if not target_is_isolated:
		return 1.0

	_hermit_bonus_used_this_battle = true
	var card = _get_card_data("the_hermit_isolation")
	var pct: float = card.effect_params.get("damage_bonus_percent", 20.0) if card else 20.0
	var stacks: int = get_stacks("the_hermit_isolation")
	return 1.0 + (pct / 100.0) * stacks


func get_first_crit_bonus(caster) -> float:
	if not caster.is_player_unit:
		return 0.0
	if _blade_crit_bonus_used_this_battle:
		return 0.0
	if not RunManager.has_tarot("the_blade_critical"):
		return 0.0

	_blade_crit_bonus_used_this_battle = true
	var card = _get_card_data("the_blade_critical")
	var pct: float = card.effect_params.get("crit_damage_bonus_percent", 40.0) if card else 40.0
	var stacks: int = get_stacks("the_blade_critical")
	return pct * stacks


# ── POST-COMBAT HOOK ───────────────────────────────────────────────────────────

func _on_combat_won() -> void:
	if RunManager.has_tarot("the_merchant_funds"):
		var card = _get_card_data("the_merchant_funds")
		var amount: int = card.effect_params.get("gold_per_combat", 1) if card else 1
		var stacks: int = get_stacks("the_merchant_funds")
		RunManager.add_gold(amount * stacks)
		RunManager.save_run()
