extends NetworkTransport
class_name SteamTransport
## Steam P2P 传输后端（房主/直连，走 Steam 中继或真实 P2P）。
##
## 设计约束（重要）
##   1. 本文件在**解析期绝不引用 GodotSteam 的类名**。仓库自带的
##      addons/godotsteam 是为更老的 Godot 编译的 GDExtension，一旦加载会让
##      Godot 4.4 直接崩溃，因此已从插件列表移除。如果这里写死
##      `SteamMultiplayerPeer.new()`，那么在未安装扩展的机器上整个脚本会
##      解析失败，并顺着 TransportFactory -> NetworkManager 一路污染启动。
##      → 一律通过 [method ClassDB.class_exists] / [method ClassDB.instantiate]
##        和 [method Object.call] 动态访问，扩展缺失时优雅降级。
##   2. 房主的 peer id 在 Steam 下**不是常量 1**（ENet 才是）。所以
##      [method get_server_id] 必须返回真实 id，NetworkManager 也不得硬编码 1。
##   3. 为了能在没有 Steam 客户端、没有 DLL 的无头环境里验证状态机，
##      [member _steam_override] / [member _peer_factory] /
##      [member _availability_override] 三个注入点允许测试替身接入。
##
## 启用真实 Steam 联机的步骤见 docs/MULTIPLAYER_PLAN.md：
##   1. 下载兼容 Godot 4.4 的 GodotSteam GDExtension（例如 4.17.1-gde）
##   2. 替换 addons/godotsteam/win64/ 下的 DLL
##   3. 把 addons/godotsteam/godotsteam.gdextension 重新加入插件列表
## 之后无需改动任何游戏逻辑：大厅里选中「Steam P2P」即可。

## 注册 Steam API 的全局单例名。
const STEAM_SINGLETON := "Steam"
## GodotSteam 提供的 MultiplayerPeer 实现类名。
const STEAM_PEER_CLASS := "SteamMultiplayerPeer"
## Steam P2P 的虚拟端口，两端必须一致。
const DEFAULT_VIRTUAL_PORT := 0
## 等待握手的最长时间。
const CONNECT_TIMEOUT_SEC := 8.0

## steamInit 的缓存状态。只缓存成功：失败不缓存，这样玩家中途把 Steam 启动
## 起来之后重试还能成功，而不是被一个几分钟前的失败结论永久挡住。
const INIT_UNKNOWN := 0
const INIT_OK := 1
static var _init_state: int = INIT_UNKNOWN

var _steam: Object = null
var _peer: MultiplayerPeer = null
var _pending: int = State.STOPPED
var _connect_timer: float = -1.0
## 本会话中权威方的 peer id。
var _server_id: int = 1
## 作为客户端时记录房主的 SteamID，用来反查它的 peer id。
var _host_steam_id: int = 0

# --- 测试注入点 ---------------------------------------------------------------

## 覆盖 Steam 单例（无头测试传入替身）。
var _steam_override: Object = null
## 覆盖 peer 创建逻辑，返回一个 [MultiplayerPeer]。
var _peer_factory: Callable = Callable()
## 覆盖对 SteamMultiplayerPeer 的方法调用。
##
## 真实的 SteamMultiplayerPeer 来自 GDExtension，在本机不可用，所以无头测试
## 用一个 ENetMultiplayerPeer 顶替传输、用这个回调接收 create_host /
## create_client / get_peer_id_for_steam_id 等调用。这样 Steam 后端的**协议
## 逻辑**（状态机、超时、server id 解析、错误信息）能被真正跑到，而不是只靠
## 读代码判断。
var _peer_invoke: Callable = Callable()
## -1 = 按真实环境探测；0 = 强制不可用；1 = 强制可用。仅测试使用。
var _availability_override: int = -1


func _init() -> void:
	backend_name = "Steam P2P"


# --- 可用性探测 ---------------------------------------------------------------

## 真实环境里这个后端是否可用。
static func is_available() -> bool:
	return probe_reason().is_empty()


## 无副作用的可用性探测：只问「Steam 现在能不能用」，绝不调用 steamInit。
##
## 大厅每次刷新成员列表都会走到这里，如果顺手把 Steam 初始化了，一个单机玩家
## 只要打开大厅就会把 Steam 拉起来。真正的初始化推迟到玩家确实要用 Steam P2P
## 的时候（见 [method ensure_steam_ready]）。
##
## isSteamRunning() 映射到 SteamAPI_IsSteamRunning()，是**可以在 Init 之前安全
## 调用**的自由函数（已实测：Steam 未运行时返回 false，不崩）。必须先问它，
## 因为直接 steamInit 会在 Steam 没开时也走一遍完整的失败路径。
static func probe_reason() -> String:
	if not Engine.has_singleton(STEAM_SINGLETON):
		return "未检测到 Steam 单例：未安装兼容 Godot 4.4 的 GodotSteam 扩展。"
	if not ClassDB.class_exists(STEAM_PEER_CLASS):
		return "GodotSteam 扩展里没有 %s 类（扩展版本过旧？需要 4.4+ 的构建）。" % STEAM_PEER_CLASS
	var steam: Object = Engine.get_singleton(STEAM_SINGLETON)
	if steam != null and steam.has_method("isSteamRunning") and not bool(steam.call("isSteamRunning")):
		return "Steam 客户端未运行或未登录。请先启动并登录 Steam，再选 Steam P2P。"
	return ""


## 初始化 SteamAPI 并缓存结果。返回 "" 表示可用，否则返回不可用原因。
##
## 为什么必须集中在这里：GodotSteam 的绝大多数方法在 SteamAPI_Init 之前调用会
## 直接踩空指针。这里踩过一次真实的坑 —— NetworkManager._ready() 里调了
## Steam.getPersonaName()，游戏一启动就崩，日志里只有一行
##   ERROR: Friends class not found, Steam may not be initialized: getPersonaName
## 接着是堆损坏（0xC0000374）。现象看着像「扩展和 Godot 4.4 不兼容」，实际是
## 「压根没初始化就去调 API」。所以：任何需要初始化状态的 Steam 调用之前，
## 都必须先过这一关。
static func ensure_steam_ready() -> String:
	if _init_state == INIT_OK:
		return ""

	# 先跑一遍无副作用的检查，把「扩展没装」和「Steam 没开」区分开。
	var reason := probe_reason()
	if not reason.is_empty():
		return reason

	var steam: Object = Engine.get_singleton(STEAM_SINGLETON)
	if steam == null:
		return "无法获取 Steam 单例。"
	if not steam.has_method("steamInit"):
		return "GodotSteam 扩展里没有 steamInit 方法（版本过旧？）。"

	var raw: Variant = steam.call("steamInit", false)
	# steamInit 返回 Dictionary{status:int, verbal:String}；老版本可能直接返回 bool。
	var status := 0
	var verbal := ""
	if raw is Dictionary:
		status = int(raw.get("status", 0))
		verbal = str(raw.get("verbal", ""))
	elif raw is bool:
		status = 0 if bool(raw) else 1
	if status != 0:
		return "SteamAPI 初始化失败（status=%d %s）。" % [status, verbal]

	_init_state = INIT_OK
	return ""


## SteamAPI 是否已成功初始化。
## 只有为 true 时才可以安全调用 getSteamID / getPersonaName 这类方法。
static func is_steam_initialized() -> bool:
	return _init_state == INIT_OK


## 本机 Steam 昵称；未初始化时返回空串。
##
## 宁可不给名字也不冒崩的风险：getPersonaName() 在未初始化时会堆损坏，
## 而不是返回空串。
static func steam_persona_name() -> String:
	if _init_state != INIT_OK:
		return ""
	var steam: Object = Engine.get_singleton(STEAM_SINGLETON)
	if steam == null or not steam.has_method("getPersonaName"):
		return ""
	return str(steam.call("getPersonaName"))


## 本机 64 位 SteamID（房主要把它报给队友）；未初始化时返回 0。
static func local_steam_id() -> int:
	if _init_state != INIT_OK:
		return 0
	var steam: Object = Engine.get_singleton(STEAM_SINGLETON)
	if steam == null or not steam.has_method("getSteamID"):
		return 0
	return int(steam.call("getSteamID"))


func _backend_reason() -> String:
	match _availability_override:
		1:
			# 测试强制可用：注入的替身会接手，不走真实 Steam。
			return ""
		0:
			return "（测试）Steam 后端被强制标记为不可用。"
	# 真实路径：这里才真正初始化 Steam（host/join 之前的唯一入口）。
	return ensure_steam_ready()



# --- 会话生命周期 -------------------------------------------------------------

## 开房。
##
## [param _max_clients] 被有意忽略：真实的 SteamMultiplayerPeer 签名是
## create_host(virtual_port)，**没有人数上限参数**。这里曾经传了两个参数
## （virtual port + max_clients），而单测里的注入桩照收不误，所以一路绿灯 ——
## 真机上会直接 "Invalid call. Expected 1 argument" 并且开房永远失败。
## 人数由「谁知道房主的 SteamID」决定，Steam 侧不做限制。
func host(_max_clients: int, _port: int) -> int:
	var reason := _backend_reason()
	if not reason.is_empty():
		last_error = reason
		_set_state(State.FAILED)
		return ERR_UNAVAILABLE

	_steam = _resolve_steam()
	if _steam == null:
		last_error = "无法获取 Steam 单例。"
		_set_state(State.FAILED)
		return ERR_UNAVAILABLE
	_init_relay()

	var peer := _create_peer()
	if peer == null:
		last_error = "无法创建 %s 实例。" % STEAM_PEER_CLASS
		_set_state(State.FAILED)
		return ERR_CANT_CREATE

	# SteamMultiplayerPeer.host_with_lobby() 需要大厅 id；合作生存用直连
	# create_host 即可，玩家通过 SteamID 直接加入。
	var err := _peer_error(_invoke_peer(peer, &"create_host", [DEFAULT_VIRTUAL_PORT]))
	if err != OK:
		last_error = "创建 Steam 主机失败（错误码 %d）。" % err
		_set_state(State.FAILED)
		return err

	_peer = peer
	_server_id = peer.get_unique_id()
	if _server_id == 0:
		_server_id = 1
	last_error = ""
	_install_peer(peer)
	_set_state(State.HOSTING)
	return OK


func join(address: String, _port: int) -> int:
	var reason := _backend_reason()
	if not reason.is_empty():
		last_error = reason
		_set_state(State.FAILED)
		return ERR_UNAVAILABLE

	# Steam 用 64 位 SteamID 而不是 IP 地址来寻址。
	var steam_id := address.strip_edges().to_int()
	if steam_id <= 0:
		last_error = "SteamID 无效：%s。请填写房主的 64 位 SteamID。" % address
		_set_state(State.FAILED)
		return ERR_INVALID_PARAMETER

	_steam = _resolve_steam()
	if _steam == null:
		last_error = "无法获取 Steam 单例。"
		_set_state(State.FAILED)
		return ERR_UNAVAILABLE
	_init_relay()

	var peer := _create_peer()
	if peer == null:
		last_error = "无法创建 %s 实例。" % STEAM_PEER_CLASS
		_set_state(State.FAILED)
		return ERR_CANT_CREATE

	var err := _peer_error(_invoke_peer(peer, &"create_client", [steam_id, DEFAULT_VIRTUAL_PORT]))
	if err != OK:
		last_error = "连接 Steam 主机 %d 失败（错误码 %d）。" % [steam_id, err]
		_set_state(State.FAILED)
		return err

	_peer = peer
	_host_steam_id = steam_id
	_server_id = _lookup_peer_id_for_steam_id(steam_id)
	last_error = ""
	_install_peer(peer)
	_set_state(State.STARTING)
	_pending = State.CONNECTED
	_connect_timer = CONNECT_TIMEOUT_SEC
	return OK


func close() -> void:
	_connect_timer = -1.0
	_pending = State.STOPPED
	if _peer != null and _peer.has_method("close"):
		_peer.call("close")
	_peer = null
	_host_steam_id = 0
	_server_id = 1
	_install_peer(null)
	_set_state(State.STOPPED)


# --- 查询 ---------------------------------------------------------------------

func is_server() -> bool:
	return _peer != null and is_ready and get_unique_id() == get_server_id()


func get_server_id() -> int:
	return _server_id


func get_peer_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	if _peer == null:
		return ids
	ids.append(get_server_id())
	var api := _multiplayer()
	if api != null:
		ids.append_array(api.get_peers())
	return ids


func get_unique_id() -> int:
	if _peer == null:
		return 0
	return _peer.get_unique_id()


# --- 每帧轮询 ---------------------------------------------------------------

## SteamMultiplayerPeer 会通过 connection_status 反映连接结果，
## 但不会发「失败」信号，所以这里做状态机 + 握手超时。
func poll() -> void:
	if _peer == null:
		return

	_sync_peer_events()

	# 客户端可能在连接成功后才解析得出房主的 peer id。
	if _pending == State.CONNECTED and _server_id <= 1 and _host_steam_id != 0:
		_server_id = _lookup_peer_id_for_steam_id(_host_steam_id)

	match _peer.get_connection_status():
		MultiplayerPeer.CONNECTION_CONNECTING:
			if _connect_timer > 0.0:
				_connect_timer -= 1.0 / maxf(Engine.physics_ticks_per_second, 1.0)
				if _connect_timer <= 0.0:
					last_error = "Steam 连接超时。请确认房主已开房、SteamID 正确、双方 Steam 在线。"
					close()
					_set_state(State.FAILED)
		MultiplayerPeer.CONNECTION_CONNECTED:
			_connect_timer = -1.0
			if _pending == State.CONNECTED:
				_pending = State.STOPPED
				_set_state(State.CONNECTED)
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			var was_client := _pending == State.CONNECTED or state == State.CONNECTED
			_connect_timer = -1.0
			_pending = State.STOPPED
			_peer = null
			_install_peer(null)
			_set_state(State.STOPPED)
			if was_client:
				closed.emit()


# --- 内部工具 -----------------------------------------------------------------

func _resolve_steam() -> Object:
	if _steam_override != null:
		return _steam_override
	if not Engine.has_singleton(STEAM_SINGLETON):
		return null
	return Engine.get_singleton(STEAM_SINGLETON)


func _create_peer() -> MultiplayerPeer:
	if _peer_factory.is_valid():
		var injected: Variant = _peer_factory.call()
		return injected as MultiplayerPeer
	if not ClassDB.class_exists(STEAM_PEER_CLASS):
		return null
	# ClassDB.instantiate() returns Variant by design, so never use `:=` here:
	# this project treats "inferred from Variant" warnings as errors.
	var instance: Object = ClassDB.instantiate(STEAM_PEER_CLASS)
	return instance as MultiplayerPeer


## 让中继网络就绪。GodotSteam 里这个调用可能返回 void，也可能返回
## Dictionary{success=...}，两种都容忍；失败只记警告，不阻断流程。
func _init_relay() -> void:
	if _steam == null or not _steam.has_method("initRelayNetworkAccess"):
		return
	var result: Variant = _steam.call("initRelayNetworkAccess")
	if result is Dictionary and result.has("success") and not result["success"]:
		push_warning("SteamTransport: InitRelayNetworkAccess 报告失败，P2P 可能不可用。")
	elif result is int and int(result) != OK:
		push_warning("SteamTransport: InitRelayNetworkAccess 返回错误码 %d。" % int(result))


## 把 GDExtension 返回的 Variant 归一成 [enum Error]。
## void 返回值（null）视为成功。
func _peer_error(raw: Variant) -> int:
	if raw == null:
		return OK
	if raw is int:
		return int(raw)
	if raw is bool:
		return OK if raw else FAILED
	return OK


func _lookup_peer_id_for_steam_id(steam_id: int) -> int:
	if _peer == null:
		return 1
	if not _peer_invoke.is_valid() and not _peer.has_method("get_peer_id_for_steam_id"):
		return 1
	var raw: Variant = _invoke_peer(_peer, &"get_peer_id_for_steam_id", [steam_id])
	if raw == null:
		return 1
	var peer_id := int(raw)
	return peer_id if peer_id != 0 else 1


## 调用 SteamMultiplayerPeer 上的一个方法。
## 默认直接转发给 peer；测试注入的回调会在这之前截获调用。
func _invoke_peer(peer: MultiplayerPeer, method: StringName, args: Array) -> Variant:
	if _peer_invoke.is_valid():
		return _peer_invoke.call(peer, method, args)
	return peer.callv(method, args)
