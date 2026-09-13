extends SceneTree

## 报告写到项目内的固定位置：Windows / Linux / CI 路径完全一致，脚本不必去猜
## Godot 的 user:// 落在哪（Windows 是 %APPDATA%，Linux 是 $XDG_DATA_HOME）。
const REPORT_DIR := "res://_userdata/reports"
const REPORT_PATH := REPORT_DIR + "/steam_selftest.log"
## Steam P2P 后端的无头自测。
##
## 扩展是可选的（`tools/setup_steam.bat` 安装，不进仓库，见 .gitignore），
## 所以本机可能装也可能没装。因此这里分三层验证：
##
##   A. 优雅降级 / 真实探测（真实环境，无替身）
##      后端不可用时必须报告原因、返回错误码、给出可读原因，而不是崩溃或静默成功；
##      装好扩展时则记录真实探测结果，并交叉核对真实方法表的参数个数。
##      另有几条**无条件**断言守着「未初始化就去调 Steam API」这个崩溃（见下）。
##
##   B. 协议逻辑（注入替身，真实网络回环）
##      SteamTransport 支持注入「Steam 单例」「peer 工厂」「GDExtension 调用代理」。
##      测试用 ENetMultiplayerPeer 顶替 SteamMultiplayerPeer 提供真实传输，
##      用一个回调接收 create_host / create_client / get_peer_id_for_steam_id
##      调用。这样状态机、超时、server id 解析、参数传递都被真正执行到。
##
##   C. 可插拔性证明
##      同样的 NetworkManager 代码换上 SteamTransport 后，能完成一次完整的
##      连接与名单同步 —— 这就是「换后端不改游戏代码」的实证。
##
## 用法
##   godot --headless --path . --script res://tools/steam_selftest.gd

const NetScript := preload("res://autoload/net/NetworkManager.gd")

const PORT := 27523
const DEAD_PORT := 27524
const MAX_FRAMES := 2400
const SETTLE := 20
const FAKE_STEAM_ID := 76561198000000001
## ENet 替身需要的连接数上限。真实的 create_host 不收这个参数（见 _make_steam_transport）。
const HOST_MAX_CLIENTS := 4
const HOST_NAME := "SteamHost"
const CLIENT_NAME := "SteamClient"


## Steam 单例的替身：只需要 SteamTransport 实际会调用的那几个方法。
class FakeSteam extends RefCounted:
	var relay_calls := 0
	var init_calls := 0
	var running := true
	var persona := "FakeSteamUser"

	func isSteamRunning() -> bool:
		return running

	## 真实签名：steamInit(embed_callbacks: bool = false) -> Dictionary。
	func steamInit(_embed_callbacks: bool = false) -> Dictionary:
		init_calls += 1
		if not running:
			return {"status": 1, "verbal": "Steam not running"}
		return {"status": 0, "verbal": "OK"}

	func initRelayNetworkAccess() -> void:
		relay_calls += 1

	func getSteamID() -> int:
		return FAKE_STEAM_ID_REF

	func getPersonaName() -> String:
		return persona


## FakeSteam 拿不到外层常量，单独放一份。
const FAKE_STEAM_ID_REF := 76561198000000001


enum Stage { DEGRADE, HOSTING, CONNECTING, ROSTER, INVALID, TIMEOUT, DONE }

var _log: FileAccess = null
var _failures: Array[String] = []
var _checks := 0
var _frames := 0
var _stage_mark := 0
var _finished := false
var _pending_start := false
var _stage: int = Stage.DEGRADE

## 记录替身收到的每一次 GDExtension 调用。
var _call_log: Array = []
var _host_api: MultiplayerAPI = null
var _client_api: MultiplayerAPI = null
var _host_transport: SteamTransport = null
var _client_transport: SteamTransport = null
var _host_net: Node = null
var _client_net: Node = null
var _fake_steam: FakeSteam = null


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	_log = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	_say("[steam] Godot " + str(Engine.get_version_info()["string"]))
	_pending_start = true


func _start() -> void:
	_verify_degradation()
	_start_loopback()
	_advance(Stage.HOSTING)


# --- A. 优雅降级 ---------------------------------------------------------------

func _verify_degradation() -> void:
	var reason := SteamTransport.probe_reason()
	_say("[steam] 真实探测结果：" + ("可用" if reason.is_empty() else reason))

	# --- 崩溃回归：未初始化就碰 Steam API ----------------------------------
	#
	# 这里踩过一次真实的坑，而且现象极具误导性：NetworkManager._ready() 调了
	# Steam.getPersonaName()，游戏一启动就 signal 11 / 堆损坏，日志里只有一行
	#   ERROR: Friends class not found, Steam may not be initialized: getPersonaName
	# 看着像「GodotSteam 4.22 和 Godot 4.4 不兼容」（我一开始就是这么判断的，
	# 还去下了另一个版本的扩展），实际是「SteamAPI 从没初始化过」。
	#
	# 所以这几条断言必须无条件成立：在没有任何人调用 ensure_steam_ready() 之前，
	# 那两个取值函数只能安静地返回空值，绝对不能去碰真实 Steam。
	_check(not SteamTransport.is_steam_initialized(),
		"还没有开房/加入之前，SteamAPI 不应当已经被初始化")
	_check(SteamTransport.steam_persona_name().is_empty(),
		"未初始化时 steam_persona_name() 必须返回空串而不是去调 getPersonaName")
	_check(SteamTransport.local_steam_id() == 0,
		"未初始化时 local_steam_id() 必须返回 0 而不是去调 getSteamID")

	if SteamTransport.is_available():
		# 真机上装了扩展且 Steam 已登录：降级分支不适用，但仍然要保证接口自洽。
		_say("[steam] 本机 Steam 后端可用，跳过降级断言")
		return

	_check(not SteamTransport.is_available(), "后端不可用时 is_available() 必须为 false")
	_check(not reason.is_empty(), "后端不可用时必须给出不可用原因")
	_check(not TransportFactory.is_available(TransportFactory.Backend.STEAM),
		"后端不可用时工厂必须报告 Steam 后端不可用")
	_check(TransportFactory.create(TransportFactory.Backend.STEAM) == null,
		"后端不可用时工厂应当返回 null 而不是抛异常")
	var hint := TransportFactory.unavailable_reason(TransportFactory.Backend.STEAM)
	_check(hint.contains("GodotSteam") or hint.contains("Steam"),
		"给玩家的提示应当指明是 Steam 的问题，实际：" + hint)

	var transport := SteamTransport.new()
	_check(transport.host(4, 0) != OK, "后端不可用时 host() 必须失败")
	_check(transport.state == NetworkTransport.State.FAILED, "host() 失败后状态应为 FAILED")
	_check(not transport.last_error.is_empty(), "host() 失败后必须带可读原因")
	_check(transport.join(str(FAKE_STEAM_ID), 0) != OK, "后端不可用时 join() 必须失败")
	_check(transport.state == NetworkTransport.State.FAILED, "join() 失败后状态应为 FAILED")
	_check(not transport.is_ready, "失败后不应当认为传输层已就绪")

	# 强制不可用的注入路径也要走同一分支。
	var forced := SteamTransport.new()
	forced.set("_availability_override", 0)
	_check(forced.host(4, 0) != OK, "被强制标记为不可用时 host() 必须失败")
	_check(forced.state == NetworkTransport.State.FAILED, "强制不可用时状态应为 FAILED")


# --- B. 协议逻辑 ---------------------------------------------------------------

func _start_loopback() -> void:
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

	_fake_steam = FakeSteam.new()

	_host_transport = _make_steam_transport(_host_api, "host", PORT)
	_client_transport = _make_steam_transport(_client_api, "client", PORT)

	_host_net = _make_net(host_branch, HOST_NAME, _host_transport)
	_client_net = _make_net(client_branch, CLIENT_NAME, _client_transport)

	var host_err: int = _host_net.call("host_game", PORT, 4)
	_check(host_err == OK, "注入替身后 Steam 开房应当成功，错误码 " + str(host_err))
	_check(bool(_host_net.call("is_host")), "Steam 开房后应当处于房主状态")
	_check(_host_transport.state == NetworkTransport.State.HOSTING,
		"Steam 开房后状态应为 HOSTING，实际 " + str(_host_transport.state))
	_check(bool(_host_net.call("is_multiplayer_active")),
		"Steam 会话应当被认为是可用的联机会话")

	# 验证传下去的 Steam 参数：virtual port 与人数上限。
	var host_call := _find_call("host", "create_host")
	_check(not host_call.is_empty(), "Steam 开房应当调用 create_host")
	if not host_call.is_empty():
		var args: Array = host_call["args"]
		_check(args.size() == 1,
			"create_host 只应当收到 virtual port 这一个参数，实际 %d 个：%s" % [args.size(), str(args)])
		_check(int(args[0]) == SteamTransport.DEFAULT_VIRTUAL_PORT,
			"create_host 的 virtual port 应当是 %d，实际 %s" % [SteamTransport.DEFAULT_VIRTUAL_PORT, str(args[0])])
	_check(_fake_steam.relay_calls == 1, "开房应当初始化一次 Steam 中继网络，实际 " +
		str(_fake_steam.relay_calls))

	var join_err: int = _client_net.call("join_game", str(FAKE_STEAM_ID), PORT)
	_check(join_err == OK, "Steam 加入应当成功，错误码 " + str(join_err))
	_check(bool(_client_net.call("is_client")), "Steam 加入后应当处于客户端状态")
	var client_call := _find_call("client", "create_client")
	_check(not client_call.is_empty(), "Steam 加入应当调用 create_client")
	if not client_call.is_empty():
		var args: Array = client_call["args"]
		_check(int(args[0]) == FAKE_STEAM_ID,
			"create_client 应当带上房主 SteamID，实际 " + str(args[0]))
		_check(int(args[1]) == SteamTransport.DEFAULT_VIRTUAL_PORT,
			"create_client 的 virtual port 应当与房主一致，实际 " + str(args[1]))

	_verify_against_real_signature(host_call, client_call)


## 拿真实 GDExtension 的方法表来核对参数个数。
##
## 这条断言是补上一个真实踩过的坑：create_host 的真实签名是
## create_host(virtual_port)，**只有一个参数**，而代码传了
## [virtual_port, max_clients] 两个。单测里的注入桩照单全收，于是 39 项全绿，
## 真机上却永远开不了房 —— 因为多传的参数会让调用直接失败。
##
## 扩展装在本机时，ClassDB 里的方法表就是权威答案，直接拿来比。没装扩展时
## 退化成对已知签名的断言，仍然能挡住参数个数被改错。
func _verify_against_real_signature(host_call: Dictionary, client_call: Dictionary) -> void:
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		_say("[steam] 本机没有 SteamMultiplayerPeer，跳过与真实签名的交叉核对")
		return

	var expected := {}
	for method in ClassDB.class_get_method_list("SteamMultiplayerPeer", true):
		expected[String(method.get("name", ""))] = method.get("args", []).size()
	_say("[steam] 真实签名参数个数：" + str(expected))

	_check(expected.get("create_host", -1) == host_call.get("args", []).size(),
		"create_host 的实参个数应当等于真实签名 %d，实际 %d" % [
			expected.get("create_host", -1), host_call.get("args", []).size()])
	_check(expected.get("create_client", -1) == client_call.get("args", []).size(),
		"create_client 的实参个数应当等于真实签名 %d，实际 %d" % [
			expected.get("create_client", -1), client_call.get("args", []).size()])


func _make_steam_transport(api: MultiplayerAPI, role: String, port: int) -> SteamTransport:
	var transport := SteamTransport.new()
	transport.set_multiplayer_api(api)
	# 没有扩展也要走「可用」分支，否则跑不到协议逻辑。
	transport.set("_availability_override", 1)
	transport.set("_steam_override", _fake_steam)
	transport.set("_peer_factory", func() -> MultiplayerPeer:
		return ENetMultiplayerPeer.new())
	# 把 SteamMultiplayerPeer 的调用翻译成 ENet 的调用，并记录下来。
	transport.set("_peer_invoke", func(peer: MultiplayerPeer, method: StringName, args: Array) -> Variant:
		_call_log.append({"role": role, "method": String(method), "args": args.duplicate()})
		var enet := peer as ENetMultiplayerPeer
		if enet == null:
			return null
		match String(method):
			"create_host":
				# create_host 的真实签名只有 virtual_port 一个参数，人数由
				# 「谁知道房主 SteamID」决定，Steam 侧不做限制。ENet 必须给个
				# 上限，这里固定一个测试值，不再从实参里取 —— 之前就是从
				# args[1] 取的，而实参只有 1 个，于是越界报错。
				return enet.create_server(port, HOST_MAX_CLIENTS)
			"create_client":
				return enet.create_client("127.0.0.1", port)
			"get_peer_id_for_steam_id":
				return 1
			"close":
				enet.close()
				return null
		return null)
	return transport


func _make_net(parent: Node, player_name: String, transport: NetworkTransport) -> Node:
	var net: Node = NetScript.new()
	net.name = "Net"
	net.set("transport_factory", func(_backend: int) -> NetworkTransport:
		return transport)
	parent.add_child(net)
	net.set("local_player_name", player_name)
	return net


func _find_call(role: String, method: String) -> Dictionary:
	for entry in _call_log:
		var record: Dictionary = entry
		if str(record["role"]) == role and str(record["method"]) == method:
			return record
	return {}


# --- C. 可插拔性：同一个 NetworkManager 换上 Steam 后端 -------------------------

func _tick() -> void:
	match _stage:
		Stage.HOSTING:
			_tick_hosting()
		Stage.CONNECTING:
			_tick_connecting()
		Stage.ROSTER:
			_tick_roster()
		Stage.INVALID:
			_tick_invalid()
		Stage.TIMEOUT:
			_tick_timeout()
		Stage.DONE:
			pass


func _tick_hosting() -> void:
	_check(_host_transport.get_server_id() == _host_transport.get_unique_id(),
		"Steam 房主的 server id 应当来自 peer 自身，而不是硬编码 1")
	_check(str(_host_net.call("describe")).begins_with("Steam P2P"),
		"诊断串应当标明当前后端是 Steam P2P，实际：" + str(_host_net.call("describe")))
	_advance(Stage.CONNECTING)


func _tick_connecting() -> void:
	if _client_transport.state == NetworkTransport.State.FAILED:
		_fail("Steam 客户端连接失败: " + _client_transport.last_error)
		_finish()
		return
	if _client_transport.state != NetworkTransport.State.CONNECTED:
		return
	_say("[steam] 注入替身后客户端已连接（第 %d 帧）" % _frames)
	_check(_client_transport.get_server_id() == 1,
		"客户端应当解析出房主的 peer id，实际 " + str(_client_transport.get_server_id()))
	_advance(Stage.ROSTER)


func _tick_roster() -> void:
	if int(_host_net.call("get_peer_count")) != 2 or int(_client_net.call("get_peer_count")) != 2:
		if _frames - _stage_mark > 400:
			_fail("Steam 后端下名单未同步：host=%d client=%d" % [
				int(_host_net.call("get_peer_count")), int(_client_net.call("get_peer_count"))])
			_finish()
		return
	# 这就是可插拔性的实证：同一份 NetworkManager 代码，后端换成 Steam 后
	# 名单 RPC 依然照常工作。
	_check(str(_host_net.call("get_player_name", 1)) == HOST_NAME,
		"Steam 后端下房主应当看到自己的名字")
	var client_peer: int = int(_client_net.call("get_unique_id"))
	_check(str(_host_net.call("get_player_name", client_peer)) == CLIENT_NAME,
		"Steam 后端下房主应当看到客户端的名字")
	_check(_host_net.call("get_sorted_peer_ids") == _client_net.call("get_sorted_peer_ids"),
		"Steam 后端下两端名单应当一致")
	_advance(Stage.INVALID)


func _tick_invalid() -> void:
	if _frames - _stage_mark < SETTLE:
		return
	# 无效 SteamID：必须在本地就被挡下，而不是发出去等超时。
	var probe := SteamTransport.new()
	probe.set("_availability_override", 1)
	probe.set("_steam_override", _fake_steam)
	var err: int = probe.join("not-a-steamid", PORT)
	_check(err == ERR_INVALID_PARAMETER,
		"非法 SteamID 应当返回 ERR_INVALID_PARAMETER，实际 " + str(err))
	_check(not probe.last_error.is_empty(), "非法 SteamID 应当给出可读原因")

	# 断开后应当干净复位。
	_host_net.call("stop")
	_check(not bool(_host_net.call("is_online")), "stop() 后应当回到未联机状态")
	_check(_host_transport.state == NetworkTransport.State.STOPPED,
		"stop() 后 Steam 传输层应当回到 STOPPED，实际 " + str(_host_transport.state))

	# 连一个没人监听的端口：应当走超时失败，而不是永远卡在 STARTING。
	# 用独立的 MultiplayerAPI，避免顶掉仍在使用的客户端连接。
	_probe_api = MultiplayerAPI.create_default_interface()
	var probe_client := SteamTransport.new()
	probe_client.set_multiplayer_api(_probe_api)
	probe_client.set("_availability_override", 1)
	probe_client.set("_steam_override", _fake_steam)
	probe_client.set("_peer_factory", func() -> MultiplayerPeer:
		return ENetMultiplayerPeer.new())
	probe_client.set("_peer_invoke", func(peer: MultiplayerPeer, method: StringName, _args: Array) -> Variant:
		var enet := peer as ENetMultiplayerPeer
		if enet == null:
			return null
		match String(method):
			"create_client":
				return enet.create_client("127.0.0.1", DEAD_PORT)
			"get_peer_id_for_steam_id":
				return 1
		return null)
	_timeout_probe = probe_client
	var timeout_err: int = probe_client.join(str(FAKE_STEAM_ID), DEAD_PORT)
	_check(timeout_err == OK, "超时用例的 join 调用本身应当成功发起")
	_advance(Stage.TIMEOUT)


var _timeout_probe: SteamTransport = null
var _probe_api: MultiplayerAPI = null


func _tick_timeout() -> void:
	if _timeout_probe == null:
		_finish()
		return
	# 这个 transport 不归任何 NetworkManager 管，必须自己驱动。
	if _probe_api != null:
		_probe_api.poll()
	_timeout_probe.poll()
	if _timeout_probe.state != NetworkTransport.State.FAILED:
		if _frames - _stage_mark > 900:
			_fail("Steam 连接超时未被检出，状态仍为 " + str(_timeout_probe.state))
			_finish()
		return
	_say("[steam] 超时已被检出（第 %d 帧）：%s" % [_frames, _timeout_probe.last_error])
	_check(_timeout_probe.last_error.contains("超时"),
		"超时后应当给出可读原因，实际：" + _timeout_probe.last_error)
	_check(_timeout_probe.get_server_id() == 1,
		"失败后 server id 应当回落到默认值")
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
		_say("[steam] %d 项检查全部通过" % _checks)
		_say("RESULT: PASS")
	else:
		_say("[steam] %d 项检查，%d 项失败" % [_checks, _failures.size()])
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
	if _host_api != null:
		_host_api.poll()
	if _client_api != null:
		_client_api.poll()
	_tick()
	if _frames >= MAX_FRAMES:
		_fail("超时：%d 帧内未完成（stage=%d）" % [MAX_FRAMES, _stage])
		_finish()
	return _finished
