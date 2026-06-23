# Field Reference

Every JSON content type, every Effect type, and every Condition type, with
what each field means. When in doubt about whether something is wired up,
search the relevant `.gd` file for the exact string (e.g. search
`effect_system.gd` for `"modify_drop_rate"`) -- this document is meant to
match the code exactly, but the code is the actual source of truth.

---

## 1. Tarot Card -- `content/tarot/*.json`

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Unique id, snake_case. |
| `name` | String | Display name. |
| `description` | String | Shown to the player. |
| `category` | String | `"blessed"` \| `"cursed"`. |
| `rarity` | String | `"common"` \| `"uncommon"` \| `"rare"` \| `"epic"` \| `"legendary"` (your call on the exact set -- nothing currently reads this for game logic, it's UI/display only). |
| `tags` | Array[String] | Synergy/category tags. Also doubles as a `modify_drop_rate` matching target (see Â§6). |
| `available_modes` | Array[String] (optional) | Which game modes this card can be offered in -- `"random"` and/or `"draft"`. Omit or leave empty to allow every mode (the default for every existing example card except The Wheel). Checked by `tarot_pick_scene.gd` when rolling the 3 choices offered at the start of a run. |
| `stackable` | bool | Can the player own more than one copy? |
| `max_stacks` | int | Cap on stacks, only relevant if `stackable`. |
| `effects` | Array[Effect] | Run **once, immediately**, the moment the card is acquired. |
| `triggers` | Array[Trigger] | Run **every time** a named event fires, for as long as the card is owned. See Â§2. |

### Trigger object (inside a tarot card's `triggers` array)

| Field | Type | Meaning |
|---|---|---|
| `id` | String (optional) | Stable identifier for THIS trigger, used as part of the `once_per_battle`/`once_per_run` guard key. Defaults to `event` if omitted -- only give triggers an explicit `id` if a single card has more than one trigger on the same event. |
| `event` | String | One of the `EventBus.ON_*` constants, as a plain string (e.g. `"on_enemy_defeated"`). |
| `condition` | Condition (optional) | Single condition object (see Â§7) checked when the event fires, using a context that includes `event_payload`. If omitted, always passes. |
| `once_per_battle` | bool | If true, fires at most once per battle, reset by `EventBus.ON_BATTLE_START`. |
| `once_per_run` | bool | If true, fires at most once ever, for the lifetime of this save (tracked via an auto-generated flag). |
| `effects` | Array[Effect] | Run when the event fires and the condition (if any) passes. |

---

## 2. Equipment -- `content/equipment/basic/*.json` and `.../advanced/*.json`

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Unique id. |
| `name`, `description` | String | Display. |
| `type` | String | `"basic"` \| `"advanced"`. **This is what `modify_drop_rate`/`modify_shop_price` match against if you write `"resource": "basic"` or `"resource": "advanced"`.** |
| `subtype` | String | Basic: matches a forging-recipe ingredient (`"blade"`, `"armor"`, `"talisman"`, `"spellbook"`, `"monocle"`, `"staff"`, `"mantle"`). Advanced: the sorted combo, e.g. `"blade_armor"` (informational only, not currently used for matching). |
| `tags` | Array[String] | Free-form (`"melee"`, `"magic"`, `"tank"`, `"forgeable"`, ...) -- matched by `modify_drop_rate`/`modify_shop_price`. |
| `effects` | Array[Effect] | Applied to the wearer when spawned into combat (see `equipment_runtime.gd`). Almost always `add_stat` (scope `"permanent"`) plus, for advanced gear with a unique mechanic, one `{"type":"custom","custom_id":"..."}` entry. |
| `stackable` | bool | Can the player own more than one copy in inventory? |
| `consumable` | bool | Single-use item that's removed after use (not currently auto-handled by any engine -- if you add a real consumable, its "use" code needs to remove it from `equipment_inventory` itself). |

**The ATK→MATK / DEF→MDEF mirroring convention**: every basic and advanced
item that grants ATK or DEF also grants the same flat amount to MATK/DEF
respectively, as **two separate `add_stat` effects** in the JSON -- this is
content, not a hidden code rule, so an item that should break the pattern
just... doesn't include the second line.

---

## 3. Encounter -- `content/encounters/*.json`

| Field | Type | Meaning |
|---|---|---|
| `id`, `title`, `description` | String | Display + identity. |
| `biomes` | Array[String] | Which biomes this can appear in. Empty array = any biome. |
| `stage_min`, `stage_max` | int | Absolute stage range (1-30) this can appear in. |
| `spawn_weight` | float | Relative chance vs other valid encounters, default 1.0. |
| `flags_required` | Array[String] | Every flag here must already be set. |
| `flags_blocked` | Array[String] | If ANY flag here is set, this encounter is excluded. |
| `flags_set_on_completion` | Array[String] | Set automatically when `EncounterEngine.complete_encounter()` runs. |
| `dialogue_graph_id` | String | Which dialogue graph drives this encounter. |
| `once_per_run` | bool | Excluded from selection again once completed. |

**No `rewards` or `combat_request` field at the top level on purpose** --
both live entirely inside the dialogue graph, one per choice, so there's
exactly one source of truth for "what does picking this choice actually do."

---

## 4. Dialogue Graph -- `content/dialogue/*.json`

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Matches the encounter's `dialogue_graph_id`. |
| `start_node` | String | Which node id to show first. |
| `nodes` | Array[Node] | See below. |

### Node

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Referenced by `next_node_id`. |
| `text`, `image` | String | Display. |
| `conditions` | Array[Condition] | Currently informational -- DialogueEngine doesn't skip whole nodes based on this yet, only individual choices. |
| `choices` | Array[Choice] | See below. |

### Choice

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Passed to `DialogueEngine.choose(choice_id)`. |
| `text` | String | Button label. |
| `cost` | Object \| null | `{"type":"gold","amount":5}` or `{"type":"equipment","equipment_id":"..."}`. `null` = free. |
| `conditions` | Array[Condition] | Must ALL pass for this choice to be shown at all (separate from affordability). |
| `effects` | Array[Effect] | Applied when chosen, after the cost is paid. |
| `next_node_id` | String \| null | Where to go next. `null` usually pairs with `leads_to_combat: true`. |
| `leads_to_combat` | bool | Whether this choice hands off to a battle. |
| `combat_request` | Object | `{"enemy_group_id": "...", "modifiers": [...]}` -- read by whatever scene transitions into combat. |

---

## 5. Shop Entry -- `content/shop/*.json`

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Unique id. |
| `item_type` | String | `"equipment"` \| `"unit"` \| `"consumable"`. |
| `item_id` | String | Which equipment/unit/consumable id. |
| `base_price` | int | Before any price modifiers. |
| `tags` | Array[String] | Per-slot override tags, separate from the underlying item's own tags -- usually leave empty and let the item's own `tags`/`type`/`subtype` do the matching (see Â§6). |
| `conditions` | Array[Condition] | Whether this entry is even eligible to appear right now (e.g. gate a unit behind a flag). |
| `spawn_weight` | float | Relative weight among eligible entries. |

`rarity` is intentionally **not** a field here -- it lives on the
underlying equipment/unit definition, so it isn't duplicated across every
shop slot that could offer that item.

---

## 6. `modify_drop_rate` / `modify_shop_price` -- the "resource" matching rules

This is the direct answer to "how do I make sure I'm affecting basic
equipment drop rates." A `resource` string is checked against ALL of these
for each shop entry; it applies if **any** match:

| What `resource` can equal | Matches |
|---|---|
| an exact item id | `"blade"` matches only the Blade. |
| an `item_type` | `"equipment"`, `"unit"`, or `"consumable"`. |
| (equipment only) the item's own `type` | `"basic"` or `"advanced"` -- **this is the one you want for "all basic equipment."** |
| (equipment only) the item's own `subtype` | `"blade"`, `"armor"`, `"blade_armor"`, etc. |
| (equipment only) the item's own `tags` | `"melee"`, `"magic"`, `"tank"`, `"forgeable"`, etc. |
| (unit only) the unit's `synergy_tags` | `"Overkill"`, `"Critical"`, etc. (read from the unit's `.tres` resource). |
| the shop_entry's own `tags` | A per-slot override, independent of the above. |
| the special keyword `"owned_units"` | Recognized dynamically -- true if the player already owns at least one copy of that unit. Not a static tag. |

`modify_shop_price` uses a simpler rule: `resource` is matched only against
`item_type`, or the literal string `"all"`. There's also a special
`item_type` value `"shop_refresh"` used by `ShopEngine.refresh_shop()` for
pricing a reroll specifically (see The Miser's example card).

Both `modify_drop_rate` and `modify_shop_price` effects support an optional
**`active_while`** field -- a Conditions array re-checked every single time
the shop is priced/weighted, unlike the effect's own top-level `conditions`
field (checked once, at the moment the tarot card itself is acquired). Use
`active_while` for anything that should expire or kick in partway through
a run (e.g. "only for the first 5 stages").

---

## 7. Effect Dictionary -- full field list per `type`

| `type` | Fields | Notes |
|---|---|---|
| `add_stat` | `target` (`"unit"`/`"team"`), `target_selector`, `stat`, `amount`, `value_mode` (`"flat"`/`"percent"`), `scope` (`"permanent"`/`"temporary"`/`"session"`), `duration` | See Â§8 for target_selector and Â§9 for scope. |
| `add_gold` | `amount` | Negative allowed. |
| `add_equipment` | `equipment_id` (supports `"$event_payload.field"` templating) | Adds to `equipment_inventory`. |
| `add_unit` | `unit_id` (supports templating) | Adds to `party` if under 4, else `bench`. |
| `add_tarot_card` | `tarot_id` | Stacks automatically if already owned and `stackable`. |
| `remove_tarot_card` | `tarot_id` | |
| `set_flag` / `unset_flag` | `flag_id` | |
| `modify_drop_rate` | `resource`, `multiplier`, `active_while` | See Â§6. |
| `modify_shop_slots` | `amount` | Added to `run_state.shop_slot_modifier`. |
| `modify_shop_price` | `resource`, `multiplier`, `amount`, `active_while` | See Â§6. |
| `heal` | `amount` | Meta-layer only (sets `pending_heal` on save data) -- live-battle healing during a fight just calls `UnitNode.heal()` directly, it doesn't need this. |
| `grant_temp_hp` | `amount` | Same meta-layer caveat as `heal`. |
| `custom` | `custom_id` | Dispatches to whatever's registered via `EffectSystem.register_custom_handler()` -- shared between equipment and tarot cards. |

Every effect (any type) also optionally accepts a top-level `conditions`
array (Â§10) -- checked once, right before the effect runs.

---

## 8. `target` / `target_selector` reference

**Permanent scope** (writes to save data, via `resolve_targets()`):

| `target_selector` | Resolves to |
|---|---|
| `"self"` | `context.unit_entry` -- only meaningful when something explicitly passes one in (e.g. a per-unit shop purchase). |
| `"all_allies"` / `"all_party"` | Every entry in `run_state.party`. |
| `"random_party_member"` | One random entry from `run_state.party`. |
| `"specific_id"` | The party entry whose `instance_id` matches `effect.target_unit_instance_id`. |

**Temporary / session scope** (applies directly to LIVE UnitNodes, via
`_resolve_live_units()` -- only works when the effect fires from a
battle-time event):

| `target_selector` | Resolves to |
|---|---|
| `"all_allies"` / `"all_party"` | `event_payload.live_units` -- the publisher of that event must include this array. |
| `"event_caster"` | `event_payload.caster`. |
| `"event_target"` | `event_payload.target`. |
| `"event_unit"` | `event_payload.unit`. |

If the relevant payload field is missing, the effect quietly does nothing
and prints a `push_warning()` -- it never crashes.

---

## 9. `scope` reference (on `add_stat`)

| `scope` | Where it's stored | Counts down? |
|---|---|---|
| `"permanent"` | `run_state.party[i].permanent_modifiers` (save data) | Never -- lasts the whole run. |
| `"temporary"` | A dynamically-built `StatusEffectData` applied directly to a live unit | Yes, `duration` rounds. |
| `"session"` | Same as temporary, but `is_permanent = true` on the status | No -- lasts until the unit is freed at the end of the battle, then it's simply gone (never written to save data). |

---

## 10. Condition Dictionary -- full field list per `type`

| `type` | Fields | True when |
|---|---|---|
| `flag` | `flag_id` | The flag is set. |
| `not_flag` | `flag_id` | The flag is NOT set. |
| `stage_min` | `value` | `run_state.stage_index >= value`. |
| `stage_max` | `value` | `run_state.stage_index <= value`. |
| `has_tarot` | `tarot_id` | The card is owned (any stack count). |
| `not_has_tarot` | `tarot_id` | The card is not owned. |
| `tarot_stacks_min` | `tarot_id`, `value` | Owned with at least `value` stacks -- use this for "scales per stack" approximations on stackable cards. |
| `random_chance` | `value` (0.0-1.0) | A fresh roll each check succeeds. |
| `gold_min` | `value` | `run_state.gold >= value`. |
| `has_equipment` | `equipment_id` | Sitting in `equipment_inventory` (not equipped specifically). |
| `difficulty_is` | `value` | `run_state.difficulty == value`. |
| `event_payload_true` | `field` | `event_payload[field]` is truthy. Only meaningful inside a trigger's `condition`. |
| `event_payload_min` | `field`, `value` | `event_payload[field] >= value`. |
| `all_of` | `conditions` | Every sub-condition passes (same as a plain array, spelled out explicitly). |
| `any_of` | `conditions` | At least one sub-condition passes (the only way to get OR logic). |
| `not` | `condition` | The single sub-condition fails. |

Conditions arrays (wherever they appear -- effect-level, trigger-level,
choice-level, shop entry-level) are **always implicitly AND'd** unless you
wrap things in `any_of`.

---

## 11. Scaling Config -- `content/scaling/*.json`

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Unique id (informational). |
| `stage_index` | int | **Absolute** 1-30 (per project decision -- not relative to the current biome). |
| `base_modifiers` | Array[Effect] | Always applied. Only `add_stat` effects make sense here (no `target`/`target_selector` needed -- it always means "this enemy group"). |
| `difficulty_modifiers` | Dictionary[String, Array[Effect]] | Keyed `"hard"`/`"nightmare"` -- applied on top of base, only for the matching difficulty. |
| `conditional_modifiers` | Array[{`condition`, `effects`}] | Each entry's `condition` is checked once (e.g. `has_tarot`); if it passes, its `effects` apply too. |

---

## 12. Spawn Table -- `content/spawn_tables/*.json`

| Field | Type | Meaning |
|---|---|---|
| `id`, `biome`, `stage_type` | String | `stage_type` is one of `"combat"`/`"encounter"`/`"subboss"`/`"special_combat"`/`"boss"`. |
| `stage_min`, `stage_max` | int | Absolute stage range this table is valid for. |
| `enemy_pool` | Array[{`enemy_id`, `weight`}] | Randomly drawn from to fill the roster. |
| `guaranteed_enemy_ids` | Array[String] | Always included (use for a subboss/boss themselves). |
| `total_enemies_min`, `total_enemies_max` | int | Random total roster size (guaranteed enemies count toward this). |
| `elite_chance` | float | Not yet consumed by `ScalingEngine` -- reserved for when you add an "elite" enemy variant system. |

---

## 13. Forging Recipe -- `content/equipment/forging_recipes.json` (one array, not one-file-per-recipe)

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Informational. |
| `inputs` | Array[String, String] | Two basic-equipment `subtype` values, any order -- `ContentLoader.make_combo_key()` sorts them alphabetically before lookup. |
| `output_equipment_id` | String | Which advanced equipment id results. |

---

## 14. Game Mode Config -- `content/game_modes/*.json`

One file per mode (currently `random.json` and `draft.json`). This is what
makes starting gold, starting resources, and the available unit pool
independently tunable per mode without touching any script.

| Field | Type | Meaning |
|---|---|---|
| `id` | String | `"random"` or `"draft"` -- matched against `RunState.draft_or_random_mode`. |
| `display_name` | String | Informational only right now. |
| `starting_gold` | int | What `RunState.gold` gets set to the moment a run starts in this mode. |
| `starting_equipment_ids` | Array[String] | Equipment ids added to `equipment_inventory` at run start. |
| `party_size` | int | How many units this mode assembles (Random picks this many at random; Draft requires exactly this many to enable Confirm). |
| `excluded_unit_ids` | Array[String] | Passed straight into `UnitRosterUtils.get_available_units()` -- hides these units from this mode's pool specifically (the two modes' exclusion lists are independent). |
| `draft_budget` | int | **Draft only.** The gold budget spent picking units, separate from `starting_gold` -- whatever's left over when the player confirms is ADDED on top of `starting_gold` (per project decision), not used instead of it. |

`game_mode_select.gd` (Random) and `draft_scene.gd` (Draft) both read their
respective config at the moment the player commits to that mode, via
`ContentLoader.get_game_mode_config(mode_id)`.

---

## 15. Tarot Pick Screen -- `tarot_pick_scene.gd`

Not a content schema, but worth noting here since it's new: this is the
screen shown right after Random/Draft assembles the party and right before
`BattleScene` loads. It offers 3 random eligible **blessed** tarot cards
(cursed cards are excluded entirely -- there's no difficulty-select UI yet
for them to make sense against), filtered by each card's `available_modes`
field (Â§1) against `RunState.draft_or_random_mode`. Picking one calls
`EffectSystem.apply_effect({"type":"add_tarot_card", ...})` exactly the way
an encounter reward or shop purchase would -- no special-cased logic.
