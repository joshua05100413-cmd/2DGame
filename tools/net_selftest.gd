extends SceneTree

## 报告写到项目内的固定位置：Windows / Linux / CI 路径完全一致，脚本不必去猜
## Godot 的 user:// 落在哪（Windows 是 %APPDATA%，Linux 是 $XDG_DATA_HOME）。
const REPORT_DIR := "res://_userdata/reports"
const REPORT_PATH := REPORT_DIR + "/net_selftest.log"
## 网络传输层无头自测（真 ENet 回环，不是 mock）。
##
## 验证目标
##   1. 后端探测：ENet 永远可用；Steam 在没装扩展时必须优雅报告不可用，
##      而不是崩溃、也不是静默成功。
##   2. 真 ENet 握手：本进程内同时起「房主」和「客户端」两个 MultiplayerAPI，
##      通过 127.0.0.1 UDP 真实收发。
##   3. 名单 RPC 双向同步：客户端报到 -> 房主广播 -> 双方名单一致。
##   4. 断开收敛：客户端退出后房主名单缩回。
##
## 为什么要两个 MultiplayerAPI
##   Godot 允许在一棵场景树里挂多个互相独立的 MultiplayerAPI
##   （SceneTree.set_multiplayer(api, root_path)）。每个 API 的 RPC 节点路径
##   相对自己的 root_path 解析，所以两个分支下同名的 `Net` 节点能正确配对，
##   无需开两个进程就能端到端验证真实网络栈。
##   注意：SceneTree 只自动轮询默认 API，自定义 API 必须自己 poll()。
##
## 用法
##   godot --headless --path . --script res://tools/net_selftest.gd

const NetScript := preload("res://autoload/net/NetworkManager.gd")
const PORT := 27123
const MAX_FRAMES := 900
const RPC_SETTLE_FRAMES := 20
const HOST_NAME := "HostPlayer"
const CLIENT_NAME := "ClientPlayer"

enum Stage { CONNECTING, ROSTER, READY, DISCONNECT, DONE }

var _log: FileAccess = null
var _failures: Array[String] = []
var _checks := 0
var _frames := 0
var _stage_mark := 0
var _finished := false
var _stage: int = Stage.CONNECTING
var _pending_start := false

var _host_api: MultiplayerAPI = null
var _client_api: MultiplayerAPI = null
var _host_transport: ENetTransport = null
var _client_transport: ENetTransport = null
var _host_net: Node = null
var _client_net: Node = null


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	_log = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	_say("[net] Godot " + str(Engine.get_version_info()["string"]))
	_say("[net] display=" + DisplayServer.get_name())
	_static_checks()
	if not _failures.is_empty():
		# 静态检查就挂了，没必要再起网络。
		_finish()
	# NOTE: the loopback session is deliberately NOT started here.
	# In _initialize() the SceneTree's /root Window does not exist yet, so
	# Node.get_path() fails and SceneTree.set_multiplayer() ends up without a
	# root path. Godot then rejects every RPC with:
	#   "Multiplayer root was not initialized. If you are using custom
	#    multiplayer, remember to set the root path via
	#    SceneMultiplayer.set_root_path before using it."
	# Starting on the first _process() frame guarantees the tree is live.
	_pending_start = true


# --- 静态检查：后端探测与工厂 ------------------------------------------------

func _static_checks() -> void:
	_check(TransportFactory.is_available(TransportFactory.Backend.ENET),
		"ENet 后端应当始终可用")

	var enet: NetworkTransport = TransportFactory.create(TransportFactory.Backend.ENET)
	_check(enet is ENetTransport, "TransportFactory 应当为 ENet 造出 ENetTransport")
	_check(enet.backend_name == "ENet", "ENet 后端名应为 ENet，实际 " + str(enet.backend_name))

	# Steam 扩展已被 .gdignore 隔离，这里必须走「优雅不可用」分支。
	var steam_reason: String = TransportFactory.unavailable_reason(TransportFactory.Backend.STEAM)
	_say("[net] Steam 后端状态: " + ("可用" if steam_reason.is_empty() else steam_reason))
	_check(not steam_reason.is_empty(),
		"未安装 GodotSteam 扩展时，Steam 后端应当报告不可用原因")
	var steam: NetworkTransport = TransportFactory.create(TransportFactory.Backend.STEAM)
	_check(steam == null,
		"Steam 扩展缺失时 TransportFactory.create(STEAM) 应当返回 null 而不是崩溃")

	# 不可用的后端被直接使用时，必须返回错误码并进入 FAILED，而不是静默成功。
	var probe := SteamTransport.new()
	var err: int = probe.host(4, 0)
	_check(err != OK, "Steam 后端不可用时 host() 必须返回错误码")
	_check(probe.state == NetworkTransport.State.FAILED,
		"Steam 后端不可用时状态应为 FAILED，实际 " + str(probe.state))
	_check(not probe.last_error.is_empty(), "失败时必须给出可展示给玩家的原因")

	var join_err: int = probe.join("76561198000000000", 0)
	_check(join_err != OK, "Steam 后端不可用时 join() 也必须返回错误码")

	# 基类契约默认值（保证子类接口完整）。
	var base := NetworkTransport.new()
	_check(base.get_server_id() == 1, "NetworkTransport 基类默认 server id 应为 1")
	_check(base.get_unique_id() == 0, "未安装 peer 时 unique id 应为 0")
	_check(base.get_peer_ids().is_empty(), "未安装 peer 时 peer 列表应为空")


# --- 回环会话 ----------------------------------------------------------------

func _start_loopback() -> void:
	# 两个分支，各自绑定一个独立的 MultiplayerAPI。
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

	_say("[net] 房主 API root_path=" + str(_host_api.get_root_path()))
	_say("[net] 客户端 API root_path=" + str(_client_api.get_root_path()))

	_host_transport = ENetTransport.new()
	_host_transport.set_multiplayer_api(_host_api)
	_client_transport = ENetTransport.new()
	_client_transport.set_multiplayer_api(_client_api)

	_host_net = _make_net(host_branch, HOST_NAME, _host_transport)
	_client_net = _make_net(client_branch, CLIENT_NAME, _client_transport)

	var host_err: int = _host_net.call("host_game", PORT, 4)
	_check(host_err == OK, "开房应当成功，错误码 " + str(host_err))
	_check(bool(_host_net.call("is_host")), "开房后 is_host() 应为 true")
	_check(int(_host_net.call("get_server_id")) == 1, "ENet 房主 peer id 应为 1")
	_check(_host_transport.state == NetworkTransport.State.HOSTING,
		"房主传输层状态应为 HOSTING，实际 " + str(_host_transport.state))
	_check(int(_host_net.call("get_peer_count")) == 1,
		"开房瞬间名单里应只有房主，实际 " + str(_host_net.call("get_peer_count")))

	var join_err: int = _client_net.call("join_game", "127.0.0.1", PORT)
	_check(join_err == OK, "加入房间应当成功，错误码 " + str(join_err))
	_check(bool(_client_net.call("is_client")), "加入后 is_client() 应为 true")
	_check(_client_transport.state == NetworkTransport.State.STARTING,
		"加入瞬间传输层状态应为 STARTING，实际 " + str(_client_transport.state))


func _make_net(parent: Node, player_name: String, transport: NetworkTransport) -> Node:
	var net: Node = NetScript.new()
	net.name = "Net"
	# 注入已经绑定好独立 API 的传输实例，绕开默认的 SceneTree API。
	net.set("transport_factory", func(_backend: int) -> NetworkTransport:
		return transport)
	parent.add_child(net)
	# 名字必须在 add_child 之后设置：_ready() 会用系统用户名覆盖 local_player_name。
	net.set("local_player_name", player_name)
	net.set("verbose", true)
	return net


func _tick() -> void:
	match _stage:
		Stage.CONNECTING:
			_tick_connecting()
		Stage.ROSTER:
			_tick_roster()
		Stage.READY:
			if _frames - _stage_mark >= RPC_SETTLE_FRAMES:
				_tick_ready()
		Stage.DISCONNECT:
			_tick_disconnect()


func _tick_connecting() -> void:
	if _client_transport.state == NetworkTransport.State.CONNECTED:
		_say("[net] 客户端握手完成（第 %d 帧）" % _frames)
		_check(bool(_client_net.call("is_multiplayer_active")),
			"连接后 is_multiplayer_active() 应为 true")
		_check(int(_client_net.call("get_server_id")) == 1,
			"客户端应认为房主是 peer 1，实际 " + str(_client_net.call("get_server_id")))
		_advance(Stage.ROSTER)
	elif _client_transport.state == NetworkTransport.State.FAILED:
		_fail("客户端连接失败: " + _client_transport.last_error)
		_finish()


func _tick_roster() -> void:
	var host_count: int = _host_net.call("get_peer_count")
	var client_count: int = _client_net.call("get_peer_count")
	if host_count != 2 or client_count != 2:
		return

	# 房主在发现新 peer 的当帧会先用占位名 "Player" 广播一次名单（让大厅能立刻
	# 显示「有人进来了」），客户端的 _register_player 报到是在同一帧稍后才被
	# poll 处理的。所以这里必须等真名收敛，否则读到的是占位值。
	var client_self: int = _client_net.call("get_unique_id")
	var host_sees: String = str(_host_net.call("get_player_name", client_self))
	if host_sees != CLIENT_NAME:
		if _frames - _stage_mark > 60:
			_fail("房主始终没收到客户端报到，看到的仍是 " + host_sees)
			_finish()
		return

	_say("[net] 名单已双向同步且名字收敛（第 %d 帧）" % _frames)
	_verify_roster()
	_client_net.call("set_ready", true)
	_advance(Stage.READY)


func _verify_roster() -> void:
	var host_ids: Array = _host_net.call("get_sorted_peer_ids")
	var client_ids: Array = _client_net.call("get_sorted_peer_ids")
	_check(host_ids.size() == 2, "房主名单应有 2 人，实际 " + str(host_ids.size()))
	_check(client_ids.size() == 2, "客户端名单应有 2 人，实际 " + str(client_ids.size()))
	_check(host_ids == client_ids,
		"两端 peer id 列表应一致：" + str(host_ids) + " vs " + str(client_ids))

	var client_self: int = _client_net.call("get_unique_id")
	_check(client_self != 1, "客户端 peer id 不应是 1，实际 " + str(client_self))
	_check(str(_host_net.call("get_player_name", 1)) == HOST_NAME,
		"房主端应看到自己的名字，实际 " + str(_host_net.call("get_player_name", 1)))
	_check(str(_client_net.call("get_player_name", 1)) == HOST_NAME,
		"客户端应看到房主的名字，实际 " + str(_client_net.call("get_player_name", 1)))
	_check(str(_host_net.call("get_player_name", client_self)) == CLIENT_NAME,
		"房主应看到客户端的名字，实际 " + str(_host_net.call("get_player_name", client_self)))
	_check(str(_client_net.call("get_player_name", client_self)) == CLIENT_NAME,
		"客户端应看到自己的名字，实际 " + str(_client_net.call("get_player_name", client_self)))

	# 玩家列表结构（大厅 UI 直接消费）。
	var roster: Array = _host_net.call("get_player_list")
	_check(roster.size() == 2, "get_player_list() 应返回 2 条")
	var local_flags := 0
	var host_flags := 0
	for raw in roster:
		var entry: Dictionary = raw
		if bool(entry.get("is_local", false)):
			local_flags += 1
		if bool(entry.get("is_host", false)):
			host_flags += 1
	_check(local_flags == 1, "房主视角应当只有 1 个 is_local，实际 " + str(local_flags))
	_check(host_flags == 1, "应当只有 1 个 is_host，实际 " + str(host_flags))


func _tick_ready() -> void:
	var host_ready := _count_ready(_host_net)
	var client_ready := _count_ready(_client_net)
	_check(host_ready == 1, "房主应看到 1 个已准备玩家，实际 " + str(host_ready))
	_check(client_ready == 1, "客户端也应看到 1 个已准备玩家，实际 " + str(client_ready))

	# 断开：客户端退出后房主名单应缩回 1 人。
	_client_net.call("stop")
	_advance(Stage.DISCONNECT)


func _count_ready(net: Node) -> int:
	var count := 0
	for raw in net.call("get_player_list"):
		var entry: Dictionary = raw
		if bool(entry.get("ready", false)):
			count += 1
	return count


func _tick_disconnect() -> void:
	if int(_host_net.call("get_peer_count")) == 1:
		_check(true, "客户端断开后房主名单缩回 1 人")
		_verify_cleanup()
		_finish()
	elif _frames - _stage_mark >= 120:
		_fail("客户端断开后房主名单未缩回，实际 " + str(_host_net.call("get_peer_count")))
		_finish()


func _verify_cleanup() -> void:
	_host_net.call("stop")
	_check(not bool(_host_net.call("is_online")), "stop() 后 is_online() 应为 false")
	_check(int(_host_net.call("get_peer_count")) == 0, "stop() 后名单应清空")
	_check(_host_transport.state == NetworkTransport.State.STOPPED,
		"stop() 后传输层状态应为 STOPPED，实际 " + str(_host_transport.state))


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
		_say("[net] %d 项检查全部通过" % _checks)
		_say("RESULT: PASS")
	else:
		_say("[net] %d 项检查，%d 项失败" % [_checks, _failures.size()])
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
		_start_loopback()
		if _finished:
			return true

	# SceneTree 只自动轮询默认 MultiplayerAPI，自定义的必须手动驱动。
	if _host_api != null:
		_host_api.poll()
	if _client_api != null:
		_client_api.poll()

	_tick()

	if _frames >= MAX_FRAMES:
		_fail("超时：%d 帧内未完成（stage=%d）" % [MAX_FRAMES, _stage])
		_finish()
	return _finished
