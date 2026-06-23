# res://scripts/data_models/spawn_table_data.gd
class_name SpawnTableData
extends RefCounted

var id: String = ""
var biome: String = ""
var stage_type: String = "combat"
var stage_min: int = 1
var stage_max: int = 30
var enemy_pool: Array = []          # [{"enemy_id": "...", "weight": 1.0}, ...]
var guaranteed_enemy_ids: Array = []
var total_enemies_min: int = 1
var total_enemies_max: int = 1
var elite_chance: float = 0.0

static func from_dict(data: Dictionary) -> SpawnTableData:
    var s := SpawnTableData.new()
    s.id = data.get("id", "")
    s.biome = data.get("biome", "")
    s.stage_type = data.get("stage_type", "combat")
    s.stage_min = data.get("stage_min", 1)
    s.stage_max = data.get("stage_max", 30)
    s.enemy_pool = data.get("enemy_pool", [])
    s.guaranteed_enemy_ids = data.get("guaranteed_enemy_ids", [])
    s.total_enemies_min = data.get("total_enemies_min", 1)
    s.total_enemies_max = data.get("total_enemies_max", 1)
    s.elite_chance = data.get("elite_chance", 0.0)
    return s
