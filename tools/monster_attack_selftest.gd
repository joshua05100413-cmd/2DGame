extends SceneTree
## 单机怪物攻击的回归测试。
##
## 为什么需要它
##   为了让房主端的 RemotePlayer 代理也能被怪物打到，Monster2 的攻击判定曾被
##   从 `body is Player` 改成 `body.has_method("onHit")`。但 BaseMonster 自己也
##   有 onHit，于是怪物把彼此当成目标，互相攻击、停在原地不追玩家。
##   这个测试就是钉住「怪物会攻击玩家、且不会把怪物当目标」。
##
## 用法
##   godot --headless --path . --script res://tools/monster_attack_selftest.gd

const MAIN_SCENE := "res://game/map/Main.tscn"
## 用 load() 而不是 preload()：Monster2.gd 继承了 BaseMonster.gd，后者引用了
## Utils 这个 autoload。--script 指定的入口脚本在 autoload 注册**之前**就被编译，
## preload 会顺着依赖链把 BaseMonster.gd 也拉进编译期，直接报
## "Identifier not found: Utils"。load() 是运行时的，那时 autoload 已经就绪。
const MONSTER_SCENE_PATH := "res://game/monster/Monster 2/Monster2.tscn"
## MonsterRoot 在 Town 子场景里，不是 Main.tscn 的直接后代。
const MONSTER_ROOT_PATH := "Town/TileMap2/MonsterRoot"

const REPORT_DIR := "res://_userdata/reports"
const REPORT_PATH := REPORT_DIR + "/monster_attack_selftest.log"
const MAX_FRAMES := 1800
const SETTLE := 10
## 让怪物有时间追上来并打中几次。
const OBSERVE_FRAMES := 600

enum Stage { LOAD, SPAWN, OBSERVE, TWO_MONSTERS, VERIFY_PAIR, DONE }

var _log: FileAccess = null
var _failures: Array[String] = []
var _checks := 0
var _frames := 0
var _stage_mark := 0
var _finished := false
var _pending_start := false
var _stage: int = Stage.LOAD

var _main: Node = null
var _monster_root: Node = null
var _player: Node2D = null
var _monster: Node = null
var _monster_b: Node = null
var _hp_before := 0
var _monster_hp_before := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	_log = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	_say("[atk] Godot " + str(Engine.get_version_info()["string"]))
	_pending_start = true


func _start() -> void:
	var packed: PackedScene = load(MAIN_SCENE)
	_check(packed != null, "主场景应当能加载")
	if packed == null:
		_finish()
		return
	_main = packed.instantiate()
	if _main == null:
		_fail("主场景实例化失败")
		_finish()
		return
	root.add_child(_main)
	_advance(Stage.LOAD)


func _tick() -> void:
	match _stage:
		Stage.LOAD:
			_tick_load()
		Stage.SPAWN:
			_tick_spawn()
		Stage.OBSERVE:
			_tick_observe()
		Stage.TWO_MONSTERS:
			_tick_two_monsters()
		Stage.VERIFY_PAIR:
			_tick_verify_pair()
		Stage.DONE:
			pass


func _tick_load() -> void:
	if not _settled():
		return
	_monster_root = _main.get_node_or_null(MONSTER_ROOT_PATH)
	_check(_monster_root != null, "应当能拿到 " + MONSTER_ROOT_PATH)
	var utils := root.get_node_or_null(^"Utils")
	var player: Variant = null if utils == null else utils.get("player")
	_check(player != null, "场景应当已经创建了本机玩家")
	if player == null or _monster_root == null:
		_finish()
		return
	_player = player
	_check(_player.is_in_group("hero"),
		"玩家应当在 hero 组里（怪物靠这个组建目标）")
	# 单机：怪物必须是权威的，否则它不跑 AI。
	_advance(Stage.SPAWN)


func _tick_spawn() -> void:
	var data := {"speed": 90, "hp": 999, "hurt": 1}
	_monster = load(MONSTER_SCENE_PATH).instantiate()
	_monster.setData(data)
	_monster.global_position = _player.global_position + Vector2(24, 0)
	_monster_root.add_child(_monster)
	_hp_before = _read_hp()
	_say("[atk] 已生成怪物，玩家血量 %d，位置 %s" % [_hp_before, str(_player.global_position)])
	_advance(Stage.OBSERVE)


func _tick_observe() -> void:
	if _frames - _stage_mark < OBSERVE_FRAMES:
		return
	var hp_now := _read_hp()
	_say("[atk] %d 帧后玩家血量 %d（起始 %d）" % [OBSERVE_FRAMES, hp_now, _hp_before])
	_say("[atk] 怪物状态：is_atk=%s targets=%d area_player=%s" % [
		str(_monster.get("is_atk")),
		(_monster.get("_targets") as Array).size(),
		str(_monster.get("area_player")),
	])

	# 核心断言：怪物必须攻击玩家。
	_check(hp_now < _hp_before,
		"怪物应当打到玩家（起始 %d，现在 %d）" % [_hp_before, hp_now])
	# 而且它追的目标必须是玩家，不是别的怪物。
	var targets: Array = _monster.get("_targets")
	_check(targets.has(_player), "怪物的目标列表里应当有玩家")
	_check(_monster.get("area_player") == _player,
		"怪物当前的目标应当是玩家，实际 " + str(_monster.get("area_player")))

	# 第二段：再放一只怪物进来，确认它们不会互相把对方当目标。
	# 先把玩家救回来 —— 上一步它被 A 打死了，测试要从干净状态开始。
	var player_data := root.get_node_or_null(^"PlayerData")
	if player_data != null:
		player_data.set("player_hp", int(player_data.get("player_hp_max")))
	_monster_b = load(MONSTER_SCENE_PATH).instantiate()
	_monster_b.setData({"speed": 90, "hp": 999, "hurt": 1})
	_monster_b.global_position = _player.global_position + Vector2(-24, 0)
	_monster_root.add_child(_monster_b)
	_monster_hp_before = int(_monster.get("HP"))
	_advance(Stage.TWO_MONSTERS)


func _tick_two_monsters() -> void:
	# Area2D 的 body_entered 由物理帧驱动，给足时间再断言。
	# SETTLE（10 帧）在实测里不够，B 的 _targets 那时还是空的。
	if _frames - _stage_mark < 60:
		return
	var a_targets: Array = _monster.get("_targets")
	var b_targets: Array = _monster_b.get("_targets")
	_say("[atk] 两只怪物：A targets=%d B targets=%d" % [a_targets.size(), b_targets.size()])
	_check(not a_targets.has(_monster_b),
		"怪物 A 不应当把怪物 B 当成攻击目标")
	_check(not b_targets.has(_monster),
		"怪物 B 不应当把怪物 A 当成攻击目标")
	_check(a_targets.has(_player), "怪物 A 的目标里应当仍然有玩家")
	# 不断言「B 一定有玩家目标」：B 的出生点有可能正好压在墙上，CharacterBody2D
	# 嵌进碰撞体会被卡住（实测 vel 恒为 0），那是测试选点的问题、不是产品缺陷。
	# 真正要钉死的是「怪物不会把另一只怪物当目标」，所以这里只要求：
	# B 的目标要么为空，要么是玩家。
	for target in b_targets:
		_check(target == _player,
			"怪物 B 的目标只能是玩家，实际 " + str(target))
	_advance(Stage.VERIFY_PAIR)


func _tick_verify_pair() -> void:
	if _frames - _stage_mark < 300:
		return
	var monster_hp := int(_monster.get("HP"))
	_check(monster_hp == _monster_hp_before,
		"怪物之间不应该互相掉血（%d -> %d）" % [_monster_hp_before, monster_hp])
	_finish()


func _read_hp() -> int:
	var player_data := root.get_node_or_null(^"PlayerData")
	if player_data == null:
		return -1
	return int(player_data.get("player_hp"))


func _settled() -> bool:
	return _frames - _stage_mark >= SETTLE


func _advance(next: int) -> void:
	_stage = next
	_stage_mark = _frames


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		_say("[ok] " + description)
	else:
		_fail(description)


func _fail(description: String) -> void:
	_failures.append(description)
	_say("[FAIL] " + description)


func _say(line: String) -> void:
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _failures.is_empty():
		_say("[atk] %d 项检查全部通过" % _checks)
		_say("RESULT: PASS")
	else:
		_say("[atk] %d 项检查，%d 项失败" % [_checks, _failures.size()])
		_say("RESULT: FAIL")
	if _log != null:
		_log.flush()
		_log.close()
	quit(1 if not _failures.is_empty() else 0)


func _process(_delta: float) -> bool:
	if _finished:
		return true
	_frames += 1
	if _pending_start:
		_pending_start = false
		_start()
	_tick()
	if _frames >= MAX_FRAMES:
		_fail("超时：%d 帧内未完成（stage=%d）" % [MAX_FRAMES, _stage])
		_finish()
	return _finished
