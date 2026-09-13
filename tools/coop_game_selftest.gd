extends SceneTree
## 真实关卡场景的联机集成自测。
##
## 与 tools/coop_selftest.gd 的分工
##   coop_selftest 用替身节点验证「复制协议」本身。
##   本测试则验证「真实游戏场景」有没有正确接上这套协议：
##     房主端跑真正的 res://game/map/Main.tscn（Town），走 autoload 的 Net/Coop；
##     客户端端是一个轻量 peer，用替身容器接收复制结果。
##
## 这样做既覆盖了场景接入代码（Town._setup_coop_world / monsterCreate），
## 又不会因为一棵树里跑两份完整场景而让 Utils.player、PlayerData 这些
## 全局单例互相打架。
##
## 验证目标
##   1. 真实场景加载后 Coop 世界挂载成功。
##   2. 场景里预置的 Hero 被复用为本机玩家，而不是又造一个。
##   3. 房主为客户端生成了 RemotePlayer 代理（不是第二个 Hero）。
##   4. 房主端真实的怪物生成流程（LevelServer.monsterCreate -> Town.monsterCreate）
##      会走 Coop 复制，客户端收到影子怪物。
##   5. 中途挂载的客户端能通过补发拿到已有世界。
##
## 用法
##   godot --headless --path . --script res://tools/coop_game_selftest.gd

const NetScript := preload("res://autoload/net/NetworkManager.gd")
const CoopScript := preload("res://autoload/net/CoopSession.gd")

const MAIN_SCENE := "res://game/map/Main.tscn"
const PORT := 27423
const MAX_FRAMES := 2400
const SETTLE := 25
const CLIENT_NAME := "ClientPlayer"

enum Stage { CONNECTING, CLIENT_WORLD, LOAD_SCENE, HOST_WORLD, SPAWN_MONSTER, VERIFY, REATTACH, DONE }


# --- 客户端替身 ---------------------------------------------------------------

class StubPlayer extends Node2D:
	var peer_id := 0
	var is_local := false
	var player_name := ""

	func mark_as_local_player(id: int) -> void:
		peer_id = id
		is_local = true

	func setup_remote_player(id: int, name: String) -> void:
		peer_id = id
		is_local = false
		player_name = name

	func apply_remote_state(pos: Vector2, _flip: bool) -> void:
		global_position = pos


class StubMonster extends Node2D:
	var coop: Node = null
	var net_id := 0
	var authoritative := true
	var hp := 5.0
	var data_received := false

	func setData(_data: Dictionary) -> void:
		data_received = true

	func set_authoritative(value: bool) -> void:
		authoritative = value

	func set_network_id(id: int) -> void:
		net_id = id

	func set_network_hp(value: float) -> void:
		hp = value

	func apply_remote_position(pos: Vector2) -> void:
		global_position = pos

	func apply_network_damage(amount: float) -> void:
		if authoritative:
			hp -= amount
			if coop != null:
				coop.call("broadcast_monster_hp", net_id, hp)


# --- 状态 ---------------------------------------------------------------------

var _log: FileAccess = null
var _failures: Array[String] = []
var _checks := 0
var _frames := 0
var _stage_mark := 0
var _finished := false
var _pending_start := false
var _stage: int = Stage.CONNECTING

var _host_net: Node = null
var _host_coop: Node = null
var _client_api: MultiplayerAPI = null
var _client_transport: ENetTransport = null
var _client_net: Node = null
var _client_coop: Node = null
var _client_world: CoopWorld = null
var _client_player_root: Node2D = null
var _client_monster_root: Node2D = null
var _main_scene: Node = null
var _client_peer: int = 0


func _initialize() -> void:
	_log = FileAccess.open("user://coop_game_selftest.log", FileAccess.WRITE)
	_say("[gcoop] Godot " + str(Engine.get_version_info()["string"]))
	_pending_start = true


func _start() -> void:
	_host_net = root.get_node_or_null(^"Net")
	_host_coop = root.get_node_or_null(^"Coop")
	_check(_host_net != null, "应当能拿到 autoload 的 Net")
	_check(_host_coop != null, "应当能拿到 autoload 的 Coop")
	if _host_net == null or _host_coop == null:
		_finish()
		return

	var err: int = _host_net.call("host_game", PORT, 8)
	_check(err == OK, "房主开房应当成功，错误码 " + str(err))

	# 客户端分支：独立 MultiplayerAPI + 独立 Net/Coop 实例。
	var branch := Node.new()
	branch.name = "ClientBranch"
	root.add_child(branch)
	_client_api = MultiplayerAPI.create_default_interface()
	set_multiplayer(_client_api, branch.get_path())
	_client_transport = ENetTransport.new()
	_client_transport.set_multiplayer_api(_client_api)

	_client_net = NetScript.new()
	_client_net.name = "Net"
	_client_net.set("transport_factory", func(_backend: int) -> NetworkTransport:
		return _client_transport)
	branch.add_child(_client_net)
	_client_net.set("local_player_name", CLIENT_NAME)
	_client_net.set("verbose", false)

	_client_player_root = Node2D.new()
	_client_player_root.name = "PlayerRoot"
	branch.add_child(_client_player_root)
	_client_monster_root = Node2D.new()
	_client_monster_root.name = "MonsterRoot"
	branch.add_child(_client_monster_root)

	_client_coop = CoopScript.new()
	_client_coop.name = "Coop"
	branch.add_child(_client_coop)
	_client_coop.set("net_override", _client_net)

	var join_err: int = _client_net.call("join_game", "127.0.0.1", PORT)
	_check(join_err == OK, "客户端加入应当成功，错误码 " + str(join_err))
	_advance(Stage.CONNECTING)


func _tick() -> void:
	match _stage:
		Stage.CONNECTING:
			_tick_connecting()
		Stage.CLIENT_WORLD:
			_tick_client_world()
		Stage.LOAD_SCENE:
			_tick_load_scene()
		Stage.HOST_WORLD:
			_tick_host_world()
		Stage.SPAWN_MONSTER:
			_tick_spawn_monster()
		Stage.VERIFY:
			_tick_verify()
		Stage.REATTACH:
			_tick_reattach()
		Stage.DONE:
			pass


func _tick_connecting() -> void:
	if _client_transport.state == NetworkTransport.State.FAILED:
		_fail("客户端连接失败: " + _client_transport.last_error)
		_finish()
		return
	if _client_transport.state != NetworkTransport.State.CONNECTED:
		return
	_say("[gcoop] 客户端已连接（第 %d 帧）" % _frames)
	# 客户端先把自己的替身世界挂上，之后房主产生的复制事件它才收得到。
	_client_world = CoopWorld.create(_client_player_root, _client_monster_root, Vector2(32, 32))
	_client_world.with_players(
		func() -> Node2D: return StubPlayer.new(),
		func() -> Node2D: return StubPlayer.new())
	_client_world.with_monster("monster2", func() -> Node2D:
		var monster := StubMonster.new()
		monster.coop = _client_coop
		return monster)
	_client_coop.call("attach_world", _client_world)
	_advance(Stage.CLIENT_WORLD)


func _tick_client_world() -> void:
	if _frames - _stage_mark < SETTLE:
		return
	_check(bool(_client_coop.call("is_active")), "客户端替身世界应当已生效")
	_advance(Stage.LOAD_SCENE)


func _tick_load_scene() -> void:
	var packed: PackedScene = load(MAIN_SCENE)
	_check(packed != null, "主场景应当能加载：" + MAIN_SCENE)
	if packed == null:
		_finish()
		return
	_main_scene = packed.instantiate()
	_check(_main_scene != null, "主场景应当能实例化")
	if _main_scene == null:
		_finish()
		return
	root.add_child(_main_scene)
	_say("[gcoop] 真实主场景已加载（第 %d 帧）" % _frames)
	_advance(Stage.HOST_WORLD)


func _tick_host_world() -> void:
	if _frames - _stage_mark < SETTLE * 2:
		return
	_check(bool(_host_coop.call("is_active")),
		"真实场景加载后 Coop 世界应当已挂载")
	_check(int(_host_coop.call("get_player_count")) == 2,
		"房主端应有 2 个玩家节点，实际 " + str(_host_coop.call("get_player_count")))
	_verify_host_players()
	_advance(Stage.SPAWN_MONSTER)


func _verify_host_players() -> void:
	var host_id: int = int(_host_net.call("get_unique_id"))
	_client_peer = int(_client_net.call("get_unique_id"))

	var mine: Node = _host_coop.call("get_player_node", host_id)
	var other: Node = _host_coop.call("get_player_node", _client_peer)
	_check(mine != null, "房主端应当有本机玩家节点")
	_check(other != null, "房主端应当有客户端的代理节点")
	if mine != null:
		# 关键：场景里预置的 Hero 必须被复用，而不是又生成一个。
		# 这里比对脚本路径而不是 `is Player`：Hero.gd 引用了 autoload，
		# 在 --script 编译期按类名引用会让它编译失败并污染日志。
		_check(_script_path(mine).ends_with("Hero.gd"),
			"房主端本机玩家应当是场景预置的真实 Hero，实际 " + _script_path(mine))
		_check(str(mine.name) == "P%d" % host_id, "本机玩家应当被重命名为 P%d" % host_id)
	if other != null:
		_check(_script_path(other).ends_with("RemotePlayer.gd"),
			"房主端客户端的节点应当是 RemotePlayer 代理，实际 " + _script_path(other))

	# 客户端视角
	_check(int(_client_coop.call("get_player_count")) == 2,
		"客户端应看到 2 个玩家，实际 " + str(_client_coop.call("get_player_count")))
	var client_self: Node = _client_coop.call("get_player_node", _client_peer)
	var client_sees_host: Node = _client_coop.call("get_player_node", host_id)
	_check(client_self != null and bool(client_self.get("is_local")),
		"客户端自己应当是本地玩家")
	_check(client_sees_host != null and not bool(client_sees_host.get("is_local")),
		"客户端上的房主应当是远端代理")


## 取节点脚本的资源路径，用于避开类名引用。
func _script_path(node: Node) -> String:
	if node == null:
		return ""
	var script: Variant = node.get_script()
	if script == null:
		return ""
	return str(script.get("resource_path"))


func _tick_spawn_monster() -> void:
	# 触发真实的关卡怪物生成流程：LevelServer -> Town.monsterCreate -> Coop。
	var level_server := root.get_node_or_null(^"LevelServer")
	_check(level_server != null, "应当能拿到 LevelServer")
	if level_server == null:
		_finish()
		return
	level_server.emit_signal("monsterCreate")
	_say("[gcoop] 已触发真实怪物生成流程（第 %d 帧）" % _frames)
	_advance(Stage.VERIFY)


func _tick_verify() -> void:
	if _frames - _stage_mark < SETTLE * 3:
		return
	var host_monsters: int = _host_coop.call("get_monster_count")
	_check(host_monsters == 1,
		"房主端应当通过真实流程生成 1 只怪物，实际 " + str(host_monsters))

	var client_monsters: int = _client_coop.call("get_monster_count")
	_check(client_monsters == 1,
		"客户端应当复制到 1 只影子怪物，实际 " + str(client_monsters))

	if host_monsters >= 1 and client_monsters >= 1:
		var host_ids: Array = _host_coop.call("get_monster_ids")
		var net_id: int = int(host_ids[0])
		var host_monster: Node = _host_coop.call("get_monster_node", net_id)
		var client_monster: Node = _client_coop.call("get_monster_node", net_id)
		_check(_script_path(host_monster).ends_with("Monster2.gd"),
			"房主端的怪物应当是真实怪物场景，实际 " + _script_path(host_monster))
		if host_monster != null:
			_check(bool(host_monster.get("is_authoritative")),
				"房主端的怪物应当是权威的")
			_check(host_monster.get("net_id") != null and int(host_monster.get("net_id")) == net_id,
				"房主端怪物应当带上 net_id")
		_check(client_monster != null, "客户端应当有同 net_id 的影子怪物")
		if client_monster != null:
			_check(not bool(client_monster.get("authoritative")),
				"客户端上的怪物应当是影子（非权威）")
			_check(bool(client_monster.get("data_received")),
				"影子怪物应当收到 setData 的属性数据")

	# 客户端把世界卸掉再挂上，验证它会重新索取状态，并且场景预置节点不受影响。
	_client_coop.call("detach_world")
	_client_coop.call("attach_world", _client_world)
	_advance(Stage.REATTACH)


func _tick_reattach() -> void:
	if _frames - _stage_mark < SETTLE * 3:
		return
	_check(int(_client_coop.call("get_player_count")) == 2,
		"重新挂载世界后客户端应重新拿到 2 个玩家，实际 " + str(_client_coop.call("get_player_count")))
	_check(int(_client_coop.call("get_monster_count")) == 1,
		"重新挂载世界后客户端应重新拿到补发的怪物，实际 " + str(_client_coop.call("get_monster_count")))
	# 房主端的场景预置 Hero 不应该因为客户端重挂而被删掉。
	var host_id: int = int(_host_net.call("get_unique_id"))
	var mine: Node = _host_coop.call("get_player_node", host_id)
	_check(mine != null and is_instance_valid(mine),
		"客户端重挂世界不应影响房主端的本机玩家节点")
	_finish()


# --- 框架 ---------------------------------------------------------------------

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
	if _host_net != null and bool(_host_net.call("is_online")):
		_host_net.call("stop")
	if _client_net != null and bool(_client_net.call("is_online")):
		_client_net.call("stop")
	if _failures.is_empty():
		_say("[gcoop] %d 项检查全部通过" % _checks)
		_say("RESULT: PASS")
	else:
		_say("[gcoop] %d 项检查，%d 项失败" % [_checks, _failures.size()])
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
	if _client_api != null:
		_client_api.poll()
	_tick()
	if _frames >= MAX_FRAMES:
		_fail("超时：%d 帧内未完成（stage=%d）" % [MAX_FRAMES, _stage])
		_finish()
	return _finished
