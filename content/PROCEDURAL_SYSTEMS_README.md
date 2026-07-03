# Procedural Systems -- Map, Enemies, Rewards, Stage Progression

This covers everything from this session: stronger map connectivity,
enemy/reward/stage scaling, and the new Stage Director. Read Â§1-2 first if
you're applying `battle_grid.gd`/`battle_scene.gd` changes by hand -- those
two sections list every single change, nothing summarized away.

---

## 1. Everything changed in `battle_grid.gd`

Exactly ONE addition, nothing else touched:

- **New method `spawn_scatter_features(feature_placements: Array)`**,
  inserted immediately after the existing `_draw_tiles()` function. It
  renders every object `MapGenerator` placed (trees, rocks, mud, flowers)
  by instantiating either `feature.scene` (if set) or a plain `Sprite2D`
  using `feature.texture`, applying optional random position jitter and
  scale variance, and adding it as a child of a node named `FeatureLayer`.
  If no `FeatureLayer` node exists, it prints a warning and does nothing
  (never crashes).
  **Requires one manual editor step**: add a `Node2D` named exactly
  `FeatureLayer` as a child of `BattleGrid`, positioned directly after
  `GroundLayer` in the tree, then save the scene. Nothing else in
  `battle_grid.gd` needed to change because your existing
  `tile_map`/`is_wall`/`movement_cost`/`blocks_line_of_sight` system already
  does everything the combat side needs -- this method only adds visuals.

## 2. Everything changed in `battle_scene.gd`

1. Added two constants: `const MAP_WIDTH := 16` and `const MAP_HEIGHT := 9`.
2. `_ready()` rewritten:
   - Computes the run's actual current biome via a new `_get_current_biome()`
     function instead of hardcoding `"grassland"`.
   - Passes that biome to `setup_battle_background(biome)`.
   - Calls a new `_setup_generated_map(biome)` instead of the old
     `_setup_test_map()`.
3. New function `_get_current_biome() -> String` -- reads
   `RunManager.current_run.biome_sequence` (falls back to `"forest"` if
   there's no active run, e.g. testing the scene standalone).
4. **Removed** the old `_setup_test_map()` (a flat 25x10 dirt-tile grid).
5. New function `_setup_generated_map(biome: String)`, which:
   - Calls `ScalingEngine.resolve_spawn_table(RunManager.current_run)` --
     **once** -- getting back `{"roster": Array, "reinforcements": Array}`.
   - Computes `enemy_count` from that SAME roster (previously, before this
     session, this would have called `resolve_spawn_table()` a SECOND time
     independently inside `battle_manager.gd`, risking a different random
     roll than the one used to size the map -- fixed by resolving once here
     and passing the result all the way down).
   - Calls `MapGenerator.generate_map(...)`, then `$BattleGrid.setup_grid(...)`
     and `$BattleGrid.spawn_scatter_features(...)`.
   - Calls `battle_manager.start_battle(player_spawns, enemy_spawns,
     enemy_roster, reinforcements)` -- 4 arguments now, not 2.
6. `BIOME_BACKGROUNDS` dict: key renamed `"grassland"` -> `"forest"`, and
   the fallback default in `setup_battle_background()` updated to match --
   this name now agrees with `RunManager`/`ScalingEngine`/every spawn table
   in the project, instead of being its own disconnected naming scheme.
7. `_on_battle_ended(result)` rewritten:
   - Always publishes `EventBus.ON_STAGE_COMPLETE`.
   - On victory: calls `StageDirector.complete_stage()` -- replacing the
     previous hardcoded `RunManager.add_gold(5); RunManager.advance_stage();
     change_scene_to_file(ShopScene)`. That +5 gold didn't disappear, it
     became a reward rule (`content/reward_rules/post_combat_gold.json`)
     so it's data now, not code.
   - On defeat: unchanged, still goes straight to `GameOverScreen.tscn`.

---

## 3. Map feature sprites -- naming and storage

This is the convention `MapGenerator` and the Inspector workflow both
assume. Mirrors the pattern already used elsewhere in the project
(`res://assets/` for raw art, `res://resources/` for the `.tres` files that
reference it -- e.g. how a unit's portrait texture and its `_data.tres` are
already split today).

**Raw images (textures)** go in:
```
res://assets/map_features/<biome>/<feature_id>.png
```
Example: `res://assets/map_features/forest/oak_tree.png`,
`res://assets/map_features/forest/mossy_rock.png`,
`res://assets/map_features/forest/mud_patch.png`,
`res://assets/map_features/forest/wildflowers.png`

**MapFeatureData resources (`.tres`)** go in:
```
res://resources/map_features/<biome>/<feature_id>.tres
```
Example: `res://resources/map_features/forest/oak_tree.tres`,
`res://resources/map_features/forest/mossy_rock.tres`, etc. -- same name,
same biome subfolder, just the `.tres` instead of `.png`.

**Naming**: snake_case, and make the `.tres` filename, the texture
filename, AND the resource's own `id` field all identical (e.g. all three
are `mud_patch`). Nothing technically REQUIRES this -- `MapGenerator` only
ever reads the `id` field inside the resource, never the filename -- but
keeping them matched is the difference between instantly knowing what a
file is six months from now versus not.

You do not need separate subfolders per category (decorative/blocking/
slowing) -- that's already a field inside each `.tres`, visible the moment
you open it in the Inspector. One subfolder per biome is enough structure.

Full creation steps (Inspector only, no code) are in
`MAP_GENERATION_SETUP.md` Â§4 from the previous session -- this section is
just the naming/location reference, that one's the click-by-click walkthrough.

---

## 4. Map connectivity -- now a stronger guarantee

Previously: "the player side can reach SOME enemy spawn cell." Now: **every**
ally spawn cell can reach **every** enemy spawn cell, which is the same
thing as saying every single spawn cell (both teams) belongs to one
connected region.

How: `MapGenerator` picks one player spawn cell closest to the cluster's
center as a "hub," then carves a separate reserved corridor from that hub
to EACH individual enemy spawn cell (enemies are spread apart by design, so
each needs its own link back). On top of that, every spawn cell -- both
teams -- gets a small reserved halo (its 4 direct neighbors) so a unit can
never spawn already boxed in, even somewhere no corridor happened to pass
through. Blocking-category features are never allowed to land on any
reserved cell. After everything's placed, a flood-fill from one spawn cell
verifies every OTHER spawn cell is reachable; if anything's still isolated
(shouldn't happen, but it's verified, not assumed), a fallback path gets
forced open.

**Tradeoff worth knowing**: more reserved corridors means less room for
"blocking" category features elsewhere on the map, especially with several
enemy spawns scattered widely. If your maps start feeling too open, the
first knob to try is reducing how many tiles wide each corridor reserves
(currently the corridor cell plus its 4 neighbors, in
`_carve_guaranteed_corridor()`), not the connectivity guarantee itself.

---

## 5. Enemy count scaling by difficulty

`ScalingEngine.resolve_spawn_table()` now adds extra enemies based on
`RunState.difficulty`, on top of whatever a stage's spawn table normally
rolls.

**To change it globally**: edit `DEFAULT_DIFFICULTY_COUNT_BONUS` at the top
of `scaling_engine.gd`:
```gdscript
const DEFAULT_DIFFICULTY_COUNT_BONUS: Dictionary = {"hard": 1, "nightmare": 2}
```
This applies to every stage that doesn't specify its own override.

**To override just ONE stage**: add a `"difficulty_count_bonus"` field to
that stage's `content/scaling/*.json` file:
```json
{
  "id": "forest_scaling_stage_5",
  "stage_index": 5,
  "difficulty_count_bonus": {"hard": 2, "nightmare": 4},
  "base_modifiers": [ ... ]
}
```
A stage with no such field falls back to the global default above -- you
never need to touch all 30 stage configs just to get sensible behavior.

---

## 6. Stage Director -- the 10-stage order, and how to change it

The fixed order (standard combat, standard combat, encounter, standard
combat, sub-boss, encounter, standard combat, special combat, encounter,
boss) was ALREADY exactly what `content/scaling/stage_type_map.json`
encodes, from several sessions ago -- nothing needed to change there. Each
of the run's 3 "Areas" reuses this same 10-entry pattern; which absolute
stage numbers (1-30) map to which entry is handled automatically by
`ContentLoader.get_stage_type()`.

**To change the order**: edit `content/scaling/stage_type_map.json`
directly -- it's a plain `{"1": "combat", "2": "combat", ...}` lookup, keys
`"1"` through `"10"` (position within an Area, not the absolute stage
number). No code changes needed for a pure reordering.

**To change it in code instead** (e.g. if you want the pattern to vary
based on something dynamic): `ContentLoader.get_stage_type(stage_index)`
is the one function that reads this file -- replace its body with whatever
logic you want; everything else in the project (StageDirector, ScalingEngine,
spawn table matching) only ever calls that function, never reads the JSON
directly.

### What StageDirector actually does

Two entry points:
- **`complete_stage()`** -- call the instant a stage's activity finishes (a
  battle's won, an encounter resolves). Applies every matching reward rule
  for the stage that just ended, advances `RunManager`, then sends the
  player to the shop (per the design doc, shopping happens between every
  stage, regardless of what's next).
- **`enter_current_stage()`** -- call this from the shop's "Continue"
  button once it exists. Looks at whatever stage `RunManager` is now on
  (already advanced) and routes to the matching scene.

`battle_scene.gd`'s victory path already calls `complete_stage()`.
`encounter_scene.gd`'s new Continue button also calls it. **Nothing yet
calls `enter_current_stage()`**, because there's no working `ShopScene` UI
script yet (`shop_manager.gd` is still the broken misplaced file from much
earlier) -- whoever builds that scene's Continue button just needs that one
line.

Register `StageDirector` as an autoload (after `RunManager`,
`ScalingEngine`, `EffectSystem`, `ContentLoader` -- it calls into all four).

---

## 7. Sub-boss, Special Combat, and reinforcements

### Sub-boss
`content/spawn_tables/forest_subboss.json` -- 3 random picks from the elite
pool (`ent`, `hulkingsporeling`), fresh mix every time. Use
`guaranteed_enemy_ids` instead of `enemy_pool` in that file if you want an
exact, non-random lineup instead.

### Special Combat (round-3 reinforcements)
`content/spawn_tables/forest_special_combat.json` starts with a SMALLER
roster (2-3, vs. combat's 2-4) and adds a `"reinforcements"` array:
```json
"reinforcements": [
  { "round": 3, "count": 2 }
]
```
**How it actually fires**: `battle_manager.gd`'s `start_battle()` now takes
the resolved roster and reinforcements list as parameters (this is also
what fixed a real bug -- the spawn table used to get resolved TWICE,
independently, once for map sizing and once for actual spawning, which
could silently roll two DIFFERENT rosters). Every round, right when
`round_number` increments, `_check_reinforcements()` checks whether any
entry's `"round"` matches; if so, it spawns that many enemies at empty,
passable cells biased toward the map's right-hand side, drawn from the SAME
enemy ids already in the main roster (since "2 more normal enemies" just
means "more of what's already there") unless that reinforcement entry sets
its own `"enemy_pool_override"`.

**To add another wave**, or change the round, or the count: just edit the
`reinforcements` array in the JSON -- no script changes. To add reinforcements
to OTHER stage types, add the same field to their spawn table.

---

## 8. Enemy ranks (normal / elite / boss)

There wasn't any rank-classification logic before this session -- confirmed
by checking. The roster you gave me:

| Rank | Forest enemies |
|---|---|
| Normal | `sporeling`, `thornling`, `sylvaris`, `wolf` |
| Elite | `ent`, `hulkingsporeling` |
| Boss | `barkhideelk` |

**The actual mechanism is the spawn tables**, not a field on the unit --
`forest_combat.json`'s `enemy_pool` only lists the 4 normal ids,
`forest_subboss.json`'s only lists the 2 elite ids, `forest_boss.json`
guarantees `barkhideelk`. That's sufficient for "which enemies show up
when" to work correctly today.

That said, I'd still add a small **descriptive** field to `UnitData` --
useful later for UI ("ELITE" tag on a unit info panel), achievements, etc.
-- even though nothing currently reads it as load-bearing logic:
```gdscript
@export_enum("normal", "elite", "boss") var enemy_rank: String = "normal"
```
I don't have your current `unit_data.gd`, so this is a manual addition on
your end (or upload the file and I'll apply it precisely). Set it to match
the table above on each of the 7 enemy `.tres` files whenever convenient --
nothing currently depends on it being set correctly yet.

---

## 9. Procedural rewards

New content type, `content/reward_rules/*.json` -- one file per rule, each
just a `conditions` array + `effects` array, reusing the exact same
vocabulary as everything else in the project (tarot triggers, encounter
choices, scaling configs). `StageDirector.complete_stage()` checks **every**
rule against the stage that just finished -- there's no "first match wins,"
multiple rules can fire on the same stage.

Three examples included:
- `post_combat_gold.json` -- +5 gold after any combat-shaped stage (this
  replaces the old hardcoded line removed from `battle_scene.gd`).
- `stage_3_item.json` -- a random basic item, exactly on absolute stage 3
  (the brief's literal example).
- `boss_bonus_gold.json` -- +15 gold and a random advanced item on every
  boss stage (stacks with `post_combat_gold`'s +5, for +20 total).

Two new building blocks made this possible:
- **Condition `"stage_exact"`** -- `{"type": "stage_exact", "value": 3}`,
  true only on that one absolute stage number.
- **Condition `"stage_type_is"`** -- `{"type": "stage_type_is", "value":
  "boss"}`, true whenever the CURRENT stage's type matches, regardless of
  which absolute number it happens to be.
- **Effect `"add_random_equipment"`** -- like `add_equipment` but takes an
  `equipment_type` ("basic"/"advanced") and/or `tags` filter instead of a
  specific id, and picks one random match.

**To add your own rule**: drop a new `.json` file in
`content/reward_rules/`, give it `conditions` (when it fires) and `effects`
(what it does) -- see `FIELD_REFERENCE.md` for the full condition/effect
vocabulary, all of it already applies here unchanged.

---

## 10. `encounter_scene.gd` -- rewritten

You weren't sure if this had been migrated -- it hadn't, confirmed. It was
still on its own standalone `encounter_pool: Array[EncounterData]` random
picker with simple gold-only rewards, totally disconnected from the JSON
encounter content, dialogue graphs, flags, and `once_per_run` tracking
built earlier this project. Rewrote it to delegate everything to
`EncounterEngine`/`DialogueEngine` instead -- picks via
`EncounterEngine.pick_encounter()`, walks the graph via
`dialogue_engine.choose()`/`get_current_node()`, and finishes via
`EncounterEngine.complete_encounter()` + `StageDirector.complete_stage()`.

**I don't have your current `EncounterScene.tscn`.** The new script expects
node names `TitleLabel` (Label), `DescriptionLabel` (RichTextLabel),
`ChoiceContainer` (any Container), `ResultLabel` (Label), `ContinueButton`
(Button) -- matching the ORIGINAL script's own `@onready` paths, which
themselves didn't quite match the scene tree shown in the original
architecture dump (`Description`/`Choices`/`"Result Feedback"`/`Button`,
no `TitleLabel` at all) -- that mismatch predates this session. Verify
your actual current scene's node names against the list above and rename
whichever side is easier, or upload the `.tscn`/current `.gd` and I'll
match it exactly instead of guessing twice.

A combat-leading encounter choice (`leads_to_combat: true`) currently just
logs its `combat_request` and ends the encounter -- there's no scene yet
that actually consumes a `combat_request` to set up a custom fight. Flagging
this as a real gap, not a finished hand-off.

---

## 11. Autoloads -- updated full list

If you're setting these up fresh, current full order:
1. `EventBus`
2. `ContentLoader`
3. `EffectSystem`
4. `CombatHooks`
5. `CustomEquipmentHandlers`
6. `CustomTarotHandlers`
7. `RunManager`
8. `EquipmentRuntime`
9. `ScalingEngine`
10. `ShopEngine`
11. `MapGenerator`
12. **`StageDirector`** -- new this session
13. `DialogueEngine` (optional, `EncounterEngine` can instance its own)
14. `EncounterEngine`

---

## 12. Files in this delivery

| File | Status |
|---|---|
| `map_generator.gd` | Updated -- hub-and-spoke connectivity rewrite |
| `scaling_engine.gd` | Updated -- difficulty count bonus, new return shape for `resolve_spawn_table()` |
| `effect_system.gd` | Updated -- `stage_exact`, `stage_type_is` conditions; `add_random_equipment` effect |
| `content_loader.gd` | Updated -- loads `content/reward_rules/` |
| `stage_director.gd` | New autoload |
| `battle_grid.gd` | Updated against your latest upload -- see Â§1 |
| `battle_scene.gd` | Updated against your latest upload -- see Â§2 |
| `battle_manager.gd` | Updated -- `start_battle()`/`_spawn_stage_enemies()` signatures changed, reinforcement logic added |
| `encounter_scene.gd` | Rewritten -- see Â§10 |
| `content/spawn_tables/forest_combat.json` | New (replaces the old, wrong-roster `forest_combat_early.json`) |
| `content/spawn_tables/forest_subboss.json` | New |
| `content/spawn_tables/forest_special_combat.json` | New |
| `content/spawn_tables/forest_boss.json` | New |
| `content/reward_rules/*.json` (3 files) | New |

## 13. Test checklist

1. Run several battles in a row, watching for the "spawn cell was isolated"
   fallback warning -- should be rare to never.
2. Trigger a `special_combat` stage and confirm 2 extra enemies appear right
   as round 3 begins (watch the Output panel for "Reinforcements arriving").
3. Confirm a `subboss` stage spawns exactly 3 enemies, only from
   `ent`/`hulkingsporeling`.
4. Win a combat stage and confirm gold actually increases by the rule
   amount (5, or 20 on a boss stage) -- this is now entirely rule-driven,
   worth double-checking it didn't silently stop working.
5. Set `RunState.difficulty` to `"hard"`/`"nightmare"` (no UI for this yet,
   so set it directly on `RunManager.current_run.difficulty` for testing)
   and confirm extra enemies actually appear.
