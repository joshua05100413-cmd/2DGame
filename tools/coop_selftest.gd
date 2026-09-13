extends SceneTree
## 合作生存复制协议的无头自测。
##
## 验证目标（全部走真实 ENet 回环，两个 MultiplayerAPI 在同一进程里）
##   1. 玩家复制：房主决定生成，双方都为每个 peer 建节点，本地/远端区分正确。
##   2. 怪物复制：房主 spawn，客户端拿到的是「影子」（非权威）。
##   3. 伤害路由：客户端上报 -> 房主结算 -> 血量广播回客户端对齐。
##   4. 死亡收敛：血量归零后双方都移除节点。
##   5. 关卡状态：房主广播 level/time/kills/gold，客户端一致。
##   6. 位置同步：本地角色上报 -> 房主聚合 -> 广播 -> 客户端代理跟随。
##   7. 中途加入：晚到的客户端能收到全部玩家、已有怪物与进度。
##   8. 世界卸载：detach_world 清干净，重复调用不报错。
##
## 为什么用替身节点
##   真实 Hero / BaseMonster 依赖全局单例（Utils.player、PlayerData），
##   一棵树里跑两份会互相打架。CoopSession 的节点全部由 CoopWorld 的工厂
##   创建，所以测试注入极简替身即可端到端验证复制协议本身。
##
## 用法
##   godot --headless --path . --script res://tools/coop_selftest.gd

const NetScript := preload("res://autoload/net/NetworkManager.gd")
const CoopScript := preload("res://autoload/net/CoopSession.gd")

const PORT := 27223
const MAX_FRAMES := 2400
const SETTLE := 20
const HOST_NAME := "HostPlayer"
const CLIENT_NAME := "ClientPlayer"
const LATE_NAME := "LatePlayer"
const MONSTER_TYPE := "stub_ghoul"


# --- 替身节点 -----------------------------------------------------------------

## 玩家替身：记录自己被配置成了本地还是远端，以及收到过什么远端状态。
class StubPlayer extends Node2D:
	var peer_id := 0
	var is_local := false
	var player_name := ""
	var applied_states := 0
	var last_applied := Vector2.ZERO

	func mark_as_local_player(id: int) -> void:
		peer_id = id
		is_local = true

	func setup_remote_player(id: int, name: String) -> void:
		peer_id = id
		is_local = false
		player_name = name

	func apply_remote_state(pos: Vector2, _flip: bool) -> void:
		applied_states += 1
		last_applied = pos
		global_position = pos


## 怪物替身：模拟 BaseMonster 的权威语义。
## 注意内部类拿不到外层脚本的常量，所以这里自带一份 MAX_HP。
class StubMonster extends Node2D:
	const MAX_HP := 10.0

	var coop: Node = null
	var net_id := 0
	var authoritative := true
	var hp := MAX_HP
	var damage_events := 0
	var data_set := false
	var died := false

	func setData(_data: Dictionary) -> void:
		data_set = true

	func set_authoritative(value: bool) -> void:
		authoritative = value

	func set_network_id(id: int) -> void:
		net_id = id

	## 客户端影子：血量直接被房主对齐，不做本地扣减。
	func set_network_hp(value: float) -> void:
		hp = value

	## 伤害入口。只有权威端真正扣血，扣完广播结果（本地子弹与网络伤害共用）。
	func apply_network_damage(amount: float) -> void:
		damage_events += 1
		if not authoritative:
			return
		hp -= amount
		if coop != null:
			coop.call("broadcast_monster_hp", net_id, hp)
		if hp <= 0.0 and not died:
			hp = 0.0
			died = true
			if coop != null:
				coop.call("notify_monster_died", net_id)


# --- 测试状态 -----------------------------------------------------------------

enum Stage {
	CONNECTING,
	ATTACH,
	PLAYERS,
	MONSTER_SPAWN,
	MONSTER_REPLICATED,
	MONSTER_DAMAGED,
	MONSTER_DEATH,
	LEVEL_STATE,
	POSITION_SYNC,
	LATE_JOIN,
	DETACH,
	DONE,
}

var _log: FileAccess = null
var _failures: Array[String] = []
var _checks := 0
var _frames := 0
var _stage_mark := 0
var _finished := false
var _pending_start := false
var _stage: int = Stage.CONNECTING

var _host_api: MultiplayerAPI = null
var _client_api: MultiplayerAPI = null
var _late_api: MultiplayerAPI = null
var _host_transport: ENetTransport = null
var _client_transport: ENetTransport = null
var _late_transport: ENetTransport = null
var _host_net: Node = null
var _client_net: Node = null
var _late_net: Node = null
var _host_coop: Node = null
var _client_coop: Node = null
var _late_coop: Node = null
var _host_world: CoopWorld = null
var _client_world: CoopWorld = null
var _late_world: CoopWorld = null
var _host_player_root: Node2D = null
var _client_player_root: Node2D = null
var _late_player_root: Node2D = null
var _host_monster_root: Node2D = null
var _client_monster_root: Node2D = null
var _late_monster_root: Node2D = null

var _spawned_monster_id := 0
var _late_joined := false
var _late_beacon_id := 0


func _initialize() -> void:
	_log = FileAccess.open("user://coop_selftest.log", FileAccess.WRITE)
	_say("[coop] Godot " + str(Engine.get_version_info()["string"]))
	# 和 net_selftest 一样：/root 在 _initialize() 阶段还没建立，
	# 必须等到第一帧 _process 才能 set_multiplayer。
	_pending_start = true


# --- 引导 ---------------------------------------------------------------------

func _start() -> void:
	var host_branch := Node.new()
	host_branch.name = "HostBranch"
	root.add_child(host_branch)
	var client_branch := Node.new()
	client_branch.name = "ClientBranch"
	root.add_child(client_branch)

	_host_api = MultiplayerAPI.create_default_interface()
	_client_api = MultiplayerAPI.create_default_interface()
	set_multiplayer(_host_api, host_branch.get_path())
	set_multiplayer(_client_api, client_branch.get_path())

	_host_transport = ENetTransport.new()
	_host_transport.set_multiplayer_api(_host_api)
	_client_transport = ENetTransport.new()
	_client_transport.set_multiplayer_api(_client_api)

	_host_net = _make_net(host_branch, HOST_NAME, _host_transport)
	_client_net = _make_net(client_branch, CLIENT_NAME, _client_transport)

	_host_player_root = _make_root(host_branch, "PlayerRoot")
	_host_monster_root = _make_root(host_branch, "MonsterRoot")
	_client_player_root = _make_root(client_branch, "PlayerRoot")
	_client_monster_root = _make_root(client_branch, "MonsterRoot")

	_host_coop = _make_coop(host_branch, _host_net)
	_client_coop = _make_coop(client_branch, _client_net)

	var host_err: int = _host_net.call("host_game", PORT, 8)
	_check(host_err == OK, "开房应当成功，错误码 " + str(host_err))
	var join_err: int = _client_net.call("join_game", "127.0.0.1", PORT)
	_check(join_err == OK, "加入房间应当成功，错误码 " + str(join_err))


func _make_net(parent: Node, player_name: String, transport: NetworkTransport) -> Node:
	var net: Node = NetScript.new()
	net.name = "Net"
	net.set("transport_factory", func(_backend: int) -> NetworkTransport:
		return transport)
	parent.add_child(net)
	net.set("local_player_name", player_name)
	net.set("verbose", true)
	return net


func _make_coop(parent: Node, net: Node) -> Node:
	var coop: Node = CoopScript.new()
	coop.name = "Coop"
	parent.add_child(coop)
	coop.set("net_override", net)
	coop.set("verbose", true)
	return coop


func _make_root(parent: Node, node_name: String) -> Node2D:
	var node := Node2D.new()
	node.name = node_name
	parent.add_child(node)
	return node


func _build_world(player_root: Node2D, monster_root: Node2D, coop: Node) -> CoopWorld:
	var world := CoopWorld.create(player_root, monster_root, Vector2(64, 64))
	world.with_players(
		func() -> Node2D: return StubPlayer.new(),
		func() -> Node2D: return StubPlayer.new())
	world.with_monster(MONSTER_TYPE, func() -> Node2D:
		var monster := StubMonster.new()
		monster.coop = coop
		return monster)
	return world


# --- 各阶段 -------------------------------------------------------------------

func _tick() -> void:
	match _stage:
		Stage.CONNECTING:
			_tick_connecting()
		Stage.ATTACH:
			_tick_attach()
		Stage.PLAYERS:
			_tick_players()
		Stage.MONSTER_SPAWN:
			_tick_monster_spawn()
		Stage.MONSTER_REPLICATED:
			_tick_monster_replicated()
		Stage.MONSTER_DAMAGED:
			_tick_monster_damaged()
		Stage.MONSTER_DEATH:
			_tick_monster_death()
		Stage.LEVEL_STATE:
			_tick_level_state()
		Stage.POSITION_SYNC:
			_tick_position_sync()
		Stage.LATE_JOIN:
			_tick_late_join()
		Stage.DETACH:
			_tick_detach()
		Stage.DONE:
			pass


func _settled() -> bool:
	return _frames - _stage_mark >= SETTLE


func _tick_connecting() -> void:
	if _client_transport.state == NetworkTransport.State.FAILED:
		_fail("客户端连接失败: " + _client_transport.last_error)
		_finish()
		return
	if _client_transport.state != NetworkTransport.State.CONNECTED:
		return
	_say("[coop] 客户端已连接（第 %d 帧）" % _frames)
	_advance(Stage.ATTACH)


func _tick_attach() -> void:
	# 等名单收敛到 2 人再挂世界。
	if int(_host_net.call("get_peer_count")) != 2 or int(_client_net.call("get_peer_count")) != 2:
		return
	_check(not bool(_host_coop.call("is_active")), "还没挂世界时 is_active() 应为 false")

	_host_world = _build_world(_host_player_root, _host_monster_root, _host_coop)
	_client_world = _build_world(_client_player_root, _client_monster_root, _client_coop)
	_host_coop.call("attach_world", _host_world)
	_client_coop.call("attach_world", _client_world)

	_check(bool(_host_coop.call("is_active")), "房主挂上世界后 is_active() 应为 true")
	_check(bool(_client_coop.call("is_active")), "客户端挂上世界后 is_active() 应为 true")
	_advance(Stage.PLAYERS)


func _tick_players() -> void:
	if not _settled():
		return
	_verify_players()
	_advance(Stage.MONSTER_SPAWN)


func _verify_players() -> void:
	var host_count: int = _host_coop.call("get_player_count")
	var client_count: int = _client_coop.call("get_player_count")
	_check(host_count == 2, "房主端应复制出 2 个玩家节点，实际 " + str(host_count))
	_check(client_count == 2, "客户端应复制出 2 个玩家节点，实际 " + str(client_count))

	var client_peer: int = _client_net.call("get_unique_id")

	var host_self: Node = _host_coop.call("get_player_node", 1)
	var host_sees_client: Node = _host_coop.call("get_player_node", client_peer)
	_check(host_self != null and bool(host_self.get("is_local")),
		"房主端 peer 1 应当是本地玩家")
	_check(host_sees_client != null, "房主端应当有客户端的代理节点")
	if host_sees_client != null:
		_check(not bool(host_sees_client.get("is_local")), "房主端的客户端应当是远端代理")
		_check(str(host_sees_client.get("player_name")) == CLIENT_NAME,
			"房主端的客户端代理应带正确名字，实际 " + str(host_sees_client.get("player_name")))
		_check(host_sees_client.global_position.is_equal_approx(Vector2(64, 64)),
			"玩家节点应生成在世界出生点，实际 " + str(host_sees_client.global_position))

	var client_self: Node = _client_coop.call("get_player_node", client_peer)
	var client_sees_host: Node = _client_coop.call("get_player_node", 1)
	_check(client_self != null and bool(client_self.get("is_local")),
		"客户端自己的节点应当是本地玩家")
	_check(client_sees_host != null, "客户端应当有房主的代理节点")
	if client_sees_host != null:
		_check(not bool(client_sees_host.get("is_local")), "客户端上的房主应当是远端代理")
		_check(str(client_sees_host.get("player_name")) == HOST_NAME,
			"客户端上的房主代理应带正确名字，实际 " + str(client_sees_host.get("player_name")))


func _tick_monster_spawn() -> void:
	var net_id: int = _host_coop.call("spawn_monster", MONSTER_TYPE, Vector2(300, 120), {"hp": 10.0})
	_check(net_id > 0, "房主 spawn_monster 应当返回正的 net_id，实际 " + str(net_id))
	_spawned_monster_id = net_id
	_advance(Stage.MONSTER_REPLICATED)


func _tick_monster_replicated() -> void:
	if not _settled():
		return
	var host_monster: Node = _host_coop.call("get_monster_node", _spawned_monster_id)
	var client_monster: Node = _client_coop.call("get_monster_node", _spawned_monster_id)
	_check(host_monster != null, "房主端应当存在刚生成的怪物")
	_check(client_monster != null, "客户端应当复制出这只怪物")
	if host_monster == null or client_monster == null:
		_finish()
		return

	_check(int(_host_coop.call("get_monster_count")) == 1, "房主端应有 1 只怪物")
	_check(int(_client_coop.call("get_monster_count")) == 1, "客户端应有 1 只怪物")
	_check(bool(host_monster.get("authoritative")), "房主端的怪物应当是权威的")
	_check(not bool(client_monster.get("authoritative")), "客户端的怪物应当是影子（非权威）")
	_check(int(client_monster.get("net_id")) == _spawned_monster_id,
		"客户端的怪物应当沿用房主分配的 net_id")
	_check(bool(host_monster.get("data_set")), "怪物应当收到 setData 的属性数据")
	_check(host_monster.global_position.is_equal_approx(Vector2(300, 120)),
		"怪物应生成在房主指定的位置，实际 " + str(host_monster.global_position))
	_check(is_equal_approx(float(client_monster.get("hp")), StubMonster.MAX_HP),
		"客户端影子初始血量应与房主一致")

	# 客户端上报 4 点伤害。
	_client_coop.call("apply_monster_damage", _spawned_monster_id, 4.0)
	_advance(Stage.MONSTER_DAMAGED)


func _tick_monster_damaged() -> void:
	if not _settled():
		return
	var host_monster: Node = _host_coop.call("get_monster_node", _spawned_monster_id)
	var client_monster: Node = _client_coop.call("get_monster_node", _spawned_monster_id)
	if host_monster == null or client_monster == null:
		_fail("上报伤害后怪物节点丢失")
		_finish()
		return
	var host_hp := float(host_monster.get("hp"))
	var client_hp := float(client_monster.get("hp"))
	_check(is_equal_approx(host_hp, StubMonster.MAX_HP - 4.0),
		"房主的权威血量应扣到 %.1f，实际 %.3f" % [StubMonster.MAX_HP - 4.0, host_hp])
	_check(int(host_monster.get("damage_events")) == 1,
		"房主应当只结算一次伤害，实际 " + str(host_monster.get("damage_events")))
	_check(int(client_monster.get("damage_events")) == 0,
		"客户端影子不应当本地结算伤害")
	_check(is_equal_approx(client_hp, host_hp),
		"客户端影子血量应与房主一致（%.3f vs %.3f）" % [client_hp, host_hp])

	# 再补 10 点，必定致死。
	_client_coop.call("apply_monster_damage", _spawned_monster_id, 10.0)
	_advance(Stage.MONSTER_DEATH)


func _tick_monster_death() -> void:
	if _frames - _stage_mark < SETTLE * 2:
		return
	_check(int(_host_coop.call("get_monster_count")) == 0,
		"怪物死亡后房主端应清空，实际 " + str(_host_coop.call("get_monster_count")))
	_check(int(_client_coop.call("get_monster_count")) == 0,
		"怪物死亡后客户端应同步清空，实际 " + str(_client_coop.call("get_monster_count")))
	_advance(Stage.LEVEL_STATE)


func _tick_level_state() -> void:
	if not _settled():
		return
	_host_coop.call("publish_level_state", 4, 31.5, 17, 240, true)
	_advance(Stage.POSITION_SYNC)


func _tick_position_sync() -> void:
	if not _settled():
		return
	_check(int(_client_coop.get("level")) == 4,
		"客户端关卡号应同步为 4，实际 " + str(_client_coop.get("level")))
	_check(int(_client_coop.get("kills")) == 17,
		"客户端击杀数应同步为 17，实际 " + str(_client_coop.get("kills")))
	_check(int(_client_coop.get("gold")) == 240,
		"客户端金币应同步为 240，实际 " + str(_client_coop.get("gold")))
	_check(is_equal_approx(float(_client_coop.get("time_left")), 31.5),
		"客户端剩余时间应同步为 31.5，实际 " + str(_client_coop.get("time_left")))
	_check(bool(_client_coop.get("round_active")), "客户端回合状态应同步为进行中")

	# 房主把自己的位置写进权威表，Coop 会周期性广播给客户端。
	_host_coop.call("report_local_state", Vector2(777, 333), true)
	_advance(Stage.LATE_JOIN)


func _tick_late_join() -> void:
	if not _late_joined and _late_net == null:
		if _frames - _stage_mark < SETTLE:
			return
		_verify_position_sync()
		_start_late_joiner()
		return

	if not _late_joined:
		if _late_transport.state != NetworkTransport.State.CONNECTED:
			return
		if int(_late_net.call("get_peer_count")) != 3:
			return
		_late_joined = true
		_late_world = _build_world(_late_player_root, _late_monster_root, _late_coop)
		_late_coop.call("attach_world", _late_world)
		_stage_mark = _frames
		return

	if _frames - _stage_mark < SETTLE * 4:
		return
	_verify_late_join()
	_advance(Stage.DETACH)


func _verify_position_sync() -> void:
	var host_proxy: Node = _client_coop.call("get_player_node", 1)
	_check(host_proxy != null, "客户端应当有房主的代理节点")
	if host_proxy == null:
		return
	_check(int(host_proxy.get("applied_states")) > 0, "客户端应当收到过房主的位置同步")
	_check(Vector2(host_proxy.get("last_applied")).is_equal_approx(Vector2(777, 333)),
		"客户端上的房主代理应移动到 (777,333)，实际 " + str(host_proxy.get("last_applied")))


func _start_late_joiner() -> void:
	var late_branch := Node.new()
	late_branch.name = "LateBranch"
	root.add_child(late_branch)
	_late_api = MultiplayerAPI.create_default_interface()
	set_multiplayer(_late_api, late_branch.get_path())
	_late_transport = ENetTransport.new()
	_late_transport.set_multiplayer_api(_late_api)
	_late_net = _make_net(late_branch, LATE_NAME, _late_transport)
	_late_player_root = _make_root(late_branch, "PlayerRoot")
	_late_monster_root = _make_root(late_branch, "MonsterRoot")
	_late_coop = _make_coop(late_branch, _late_net)

	# 加入前先造一只怪物、推进一段进度，用来验证补发。
	_late_beacon_id = _host_coop.call("spawn_monster", MONSTER_TYPE, Vector2(900, 400), {})
	_host_coop.call("publish_level_state", 7, 12.0, 55, 900, true)

	var err: int = _late_net.call("join_game", "127.0.0.1", PORT)
	_check(err == OK, "第三个客户端加入应当成功，错误码 " + str(err))


func _verify_late_join() -> void:
	_check(int(_late_coop.call("get_player_count")) == 3,
		"中途加入的客户端应看到 3 个玩家，实际 " + str(_late_coop.call("get_player_count")))
	_check(int(_late_coop.call("get_monster_count")) == 1,
		"中途加入的客户端应补发到已有的 1 只怪物，实际 " + str(_late_coop.call("get_monster_count")))
	_check(int(_late_coop.get("level")) == 7,
		"中途加入的客户端应同步到关卡 7，实际 " + str(_late_coop.get("level")))
	_check(int(_late_coop.get("kills")) == 55,
		"中途加入的客户端应同步到击杀 55，实际 " + str(_late_coop.get("kills")))
	var beacon: Node = _late_coop.call("get_monster_node", _late_beacon_id)
	_check(beacon != null, "中途加入的客户端应当拿到补发的怪物节点")
	if beacon != null:
		_check(not bool(beacon.get("authoritative")), "补发的怪物在客户端应当是影子")


func _tick_detach() -> void:
	if not _settled():
		return
	_client_coop.call("detach_world")
	_check(not bool(_client_coop.call("is_active")), "detach_world 后 is_active() 应为 false")
	_client_coop.call("detach_world")
	_check(true, "重复 detach_world 不应报错")
	_finish()


func _advance(next: int) -> void:
	_stage = next
	_stage_mark = _frames


# --- 框架 ---------------------------------------------------------------------

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
		_say("[coop] %d 项检查全部通过" % _checks)
		_say("RESULT: PASS")
	else:
		_say("[coop] %d 项检查，%d 项失败" % [_checks, _failures.size()])
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

	# 自定义 MultiplayerAPI 必须手动轮询。
	if _host_api != null:
		_host_api.poll()
	if _client_api != null:
		_client_api.poll()
	if _late_api != null:
		_late_api.poll()

	_tick()

	if _frames >= MAX_FRAMES:
		_fail("超时：%d 帧内未完成（stage=%d）" % [MAX_FRAMES, _stage])
		_finish()
	return _finished
