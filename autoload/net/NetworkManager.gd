extends Node
class_name NetManager
## 联机总入口（自动加载为 `Net`）。
##
## 职责：
##   * 持有当前 [NetworkTransport] 并每帧驱动它
##   * 维护「peer_id -> 玩家信息」的权威名单
##   * 暴露与后端无关的 RPC，游戏代码不需要知道下面是 ENet 还是 Steam
##
## 游戏逻辑只允许访问本节点（`Net`），绝不直接碰 ENet / Steam。
## 这正是 Steam 后端可以整体替换而不改玩法代码的原因。
##
## 权威模型（合作生存）
##   * 房主是权威方：怪物、掉落、关卡进程、伤害结算都由房主决定。
##   * 客户端只本地预测自己的移动/瞄准/开火，把动作上报房主校验。
##   * 详细设计见 docs/MULTIPLAYER_PLAN.md。
##
## 后端无关性注意：房主的 peer id 在 ENet 下是 1，在 Steam P2P 下是由
## SteamID 派生的其它值。因此本文件**任何地方都不得硬编码 1**，一律走
## [method get_server_id]。

## 任意网络状态变化（连接/断开/名单变化），供 UI 统一刷新。
signal state_changed()
signal server_started()
signal server_stopped()
signal joined_server()
signal connection_failed(reason: String)
signal players_changed()
signal local_player_registered(peer_id: int)
## 房主宣布开始一局；所有端（含房主自己）据此进入同一个模式。
signal match_started(mode: int)
## 客户端侧：到房主的连接断了。
signal server_disconnected()

enum Mode {
	OFFLINE, ## 未联机（单机或菜单）。
	HOSTING, ## 本机是房主。
	CLIENT,  ## 本机是客户端。
}

const DEFAULT_PORT := 27015
const DEFAULT_MAX_CLIENTS := 8
## 玩家名长度上限，避免 RPC 负载过大。
const MAX_NAME_LENGTH := 16

## 网卡名里出现这些词的基本都是虚拟机/隧道，队友按它连一般连不上。
## 放在最后当作兜底候选，而不是直接丢掉——某些精简系统上真实网卡也可能叫得怪。
const VIRTUAL_ADAPTER_HINTS := [
	"vmware", "virtualbox", "vethernet", "hyper-v", "loopback",
	"bluetooth", "docker", "tap", "wintun", "npcap",
]

## 当前选中的后端（[enum TransportFactory.Backend]）。
var backend: int = TransportFactory.Backend.ENET
## 当前传输层实例；未联机时为 null。
var transport: NetworkTransport = null

## 覆盖传输层创建逻辑。为空时走 [method TransportFactory.create]。
## 无头测试用它注入绑定到独立 MultiplayerAPI 的传输实例。
var transport_factory: Callable = Callable()

## peer_id -> { "name": String, "ready": bool }
var players: Dictionary = {}

## 本机玩家名，连接时发给对端。
var local_player_name: String = "Player"

var mode: int = Mode.OFFLINE

## 上一次失败/提示信息，供大厅显示。
var last_error: String = ""

## 打开后把每一次网络事件写进日志。联机问题排查时设 true。
var verbose: bool = false


func _trace(message: String) -> void:
	if verbose:
		print("[Net] " + message)


func _ready() -> void:
	# 跨场景存活：联机会话必须能挺过地图切换。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 跑游戏时加 `-- --net-verbose` 就会打印每一次网络事件。
	# 真实双进程下的联机问题（看不到队友、状态不同步）靠这个日志定位，
	# 单进程测试覆盖不到进程间差异。
	for arg in OS.get_cmdline_user_args():
		if arg == "--net-verbose":
			verbose = true
			print("[Net] 网络日志已开启")
	local_player_name = default_player_name()


func _process(_delta: float) -> void:
	if transport == null:
		return
	transport.poll()
	# ENet / Steam 都没有统一的「失败」事件，只能由这里轮询超时状态。
	_check_transport_failure()


# --- 查询 ---------------------------------------------------------------------

func is_host() -> bool:
	return mode == Mode.HOSTING


func is_client() -> bool:
	return mode == Mode.CLIENT


func is_online() -> bool:
	return mode != Mode.OFFLINE


## 联机会话是否真正可用（相对单机模式）。
##
## 注意必须检查**连接状态**，不能只看 is_ready。
## is_ready 只表示「peer 已装到 MultiplayerAPI 上」，而 join() 之后握手还没完成、
## 甚至 host() 之后对端还没接上时它就已经是 true 了。在那段时间里发 RPC 会被
## 拒绝（"Trying to call an RPC via a multiplayer peer which is not connected"），
## 连 call_local 的本地执行都不会发生 —— 房主自己的玩家节点就是这样没建出来的。
func is_multiplayer_active() -> bool:
	if mode == Mode.OFFLINE or transport == null or not transport.is_ready:
		return false
	return transport.state == NetworkTransport.State.HOSTING \
		or transport.state == NetworkTransport.State.CONNECTED


## 本机 peer id；单机时返回 1，保证调用方总能拿到合法 owner id。
func get_unique_id() -> int:
	if transport != null:
		var id := transport.get_unique_id()
		if id != 0:
			return id
	return 1


## 权威方 peer id。
func get_server_id() -> int:
	return transport.get_server_id() if transport != null else 1


## 列出本机可以报给队友的 IPv4 地址，最可能连通的排在最前面。
##
## 为什么需要这个：ENet 是直连后端，客户端要填房主的地址，而**房主自己看不到
## 该报什么**。本机双开填 127.0.0.1 就行，一旦换成两台机器，回环地址立刻失效，
## 必须报内网地址——而内网地址会随网卡、随换网变化，房主没法凭记忆填对。
##
## 排序依据（从优到劣）：
##   1. 真实网卡的私有地址（10./172.16-31./192.168.）——同局域网直接可用
##   2. 其它真实网卡地址
##   3. 虚拟网卡地址——只有当双方都在同一个虚拟局域网里时才有用
##
## 用 [method IP.get_local_interfaces] 而不是 [method IP.get_local_addresses]，
## 因为只有前者能拿到网卡名，而「是不是虚拟机」这个判断只能靠名字。
static func local_address_candidates() -> Array:
	# 用字典按地址去重：一块网卡可以有多个地址，多块网卡也可能重复。
	var seen: Dictionary = {}
	var private_real: Array = []
	var other_real: Array = []
	var virtual: Array = []

	var interfaces: Array = IP.get_local_interfaces()
	for entry in interfaces:
		var info: Dictionary = entry
		var adapter_name: String = info.get("name", "")
		var addresses: PackedStringArray = info.get("addresses", PackedStringArray())
		var is_virtual := _looks_virtual(adapter_name)
		for address in addresses:
			if not is_lan_address(address) or seen.has(address):
				continue
			seen[address] = true
			# 三个桶分开收，最后按优先级拼接。不要塞进一个数组再排序：
			# 网卡枚举顺序本身没有保证，混在一起就没法稳定地把虚拟网卡压到后面。
			if is_virtual:
				virtual.append(address)
			elif is_private_address(address):
				private_real.append(address)
			else:
				other_real.append(address)

	var result: Array = []
	result.append_array(private_real)
	result.append_array(other_real)
	result.append_array(virtual)
	return result


## 最值得报给队友的那个本机地址；一个都没有时返回空串（例如完全没联网）。
##
## 只返回地址本身，不带任何修饰。以前这里顺手拼了「（另有 N 个地址）」，
## 结果在大厅里显示成 `10.236.7.166（另有 2 个地址）:27015`——看着像端口号的一部分。
## 计数交给调用方补在句子末尾。
static func local_address_hint() -> String:
	var candidates := local_address_candidates()
	if candidates.is_empty():
		return ""
	return str(candidates[0])


## 除最优地址之外还有几个候选网卡地址。房主可能要挨个试，所以要报出来。
static func extra_address_count() -> int:
	return maxi(local_address_candidates().size() - 1, 0)


## 能不能拿来当连接目标：必须是 IPv4，且不是回环/链路本地。
static func is_lan_address(address: String) -> bool:
	if address.is_empty() or address.contains(":"):
		return false
	if address.begins_with("127.") or address.begins_with("169.254."):
		return false
	var parts := address.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		if not part.is_valid_int():
			return false
		var value := int(part)
		if value < 0 or value > 255:
			return false
	return true


## RFC1918 私有网段。这些地址在同一个局域网里可直接互连。
static func is_private_address(address: String) -> bool:
	var parts := address.split(".")
	if parts.size() != 4:
		return false
	var first := int(parts[0])
	var second := int(parts[1])
	if first == 10:
		return true
	if first == 192 and second == 168:
		return true
	if first == 172 and second >= 16 and second <= 31:
		return true
	return false


static func _looks_virtual(adapter_name: String) -> bool:
	var lowered := adapter_name.to_lower()
	for hint in VIRTUAL_ADAPTER_HINTS:
		if lowered.contains(hint):
			return true
	return false


func get_player_name(peer_id: int) -> String:
	if players.has(peer_id):
		return players[peer_id].get("name", "Player")
	return "Player %d" % peer_id


func get_sorted_peer_ids() -> Array:
	var ids := players.keys()
	ids.sort()
	return ids


func get_peer_count() -> int:
	return players.size()


## 供大厅列表使用的结构化快照。
func get_player_list() -> Array:
	var list: Array = []
	for peer_id in get_sorted_peer_ids():
		var info: Dictionary = players[peer_id]
		list.append({
			"id": peer_id,
			"name": info.get("name", "Player"),
			"ready": info.get("ready", false),
			"is_local": peer_id == get_unique_id(),
			"is_host": peer_id == get_server_id(),
		})
	return list


## 日志用的诊断串。
func describe() -> String:
	if not is_multiplayer_active():
		return "single-player"
	return "%s | %s | peer %d | players %d" % [
		transport.backend_name,
		"host" if is_host() else "client",
		get_unique_id(),
		players.size(),
	]


# --- 会话生命周期 -------------------------------------------------------------

## 玩家默认名：优先 Steam 昵称，其次系统用户名。
## 只通过 TransportFactory 探测后端，绝不直接依赖 SteamTransport 的实现细节。
##
## 这里**只读已经初始化好的** Steam 昵称（[method SteamTransport.steam_persona_name]）。
## 以前是直接 Engine.get_singleton("Steam") 再调 getPersonaName()，而 SteamAPI
## 从没被初始化过 —— 于是游戏一启动就 signal 11 / 堆损坏，因为
## SteamFriends() 是空指针。启动阶段不该碰任何需要初始化状态的 Steam API。
func default_player_name() -> String:
	var persona := SteamTransport.steam_persona_name()
	if not persona.is_empty():
		return persona.substr(0, MAX_NAME_LENGTH)
	return _os_player_name()


## 系统用户名兜底。单独抽出来是因为 [method prepare_steam_backend] 需要判断
## 「玩家还没自己改过名字」——而那时候 default_player_name() 已经返回 Steam
## 昵称了，拿它比较永远不相等。
func _os_player_name() -> String:
	var os_name := OS.get_environment("USERNAME")
	if os_name.is_empty():
		os_name = OS.get_environment("USER")
	if os_name.is_empty():
		os_name = "Player"
	return os_name.substr(0, MAX_NAME_LENGTH)


## 为 Steam 后端做准备：初始化 SteamAPI 并把默认名换成 Steam 昵称。
##
## 时机由大厅决定（玩家在下拉框里选中 Steam P2P 时），而不是在启动时 ——
## 单机玩家不该因为打开一次大厅就把 Steam 拉起来。
## 返回 "" 表示准备好了，否则是不可用原因。
func prepare_steam_backend() -> String:
	var reason := SteamTransport.ensure_steam_ready()
	if not reason.is_empty():
		return reason
	# 只在玩家没有自己改过名字时才替换，否则会踩掉他刚输入的内容。
	if local_player_name == _os_player_name():
		var persona := SteamTransport.steam_persona_name()
		if not persona.is_empty():
			set_local_player_name(persona)
	return ""




func set_local_player_name(new_name: String) -> void:
	var trimmed := new_name.strip_edges().substr(0, MAX_NAME_LENGTH)
	if trimmed.is_empty():
		trimmed = "Player"
	local_player_name = trimmed
	if is_host() and players.has(get_server_id()):
		players[get_server_id()]["name"] = local_player_name
		_broadcast_players()


func set_backend(new_backend: int) -> void:
	if is_online():
		push_warning("Net: 会话进行中不能切换后端，请先断开。")
		return
	backend = new_backend
	state_changed.emit()


## 开房。返回 [constant OK] 或错误码。
func host_game(port: int = DEFAULT_PORT, max_clients: int = DEFAULT_MAX_CLIENTS) -> int:
	_stop_transport()
	last_error = ""
	var t := _create_transport()
	if t == null:
		last_error = TransportFactory.unavailable_reason(backend)
		connection_failed.emit(last_error)
		return ERR_UNAVAILABLE
	transport = t
	_connect_transport_signals()

	var err := transport.host(max_clients, port)
	if err != OK:
		last_error = transport.last_error
		connection_failed.emit(last_error)
		_stop_transport()
		return err

	mode = Mode.HOSTING
	# 房主就是权威方，天然属于会话。
	var host_id := transport.get_server_id()
	players = {host_id: {"name": local_player_name, "ready": false}}
	players_changed.emit()
	server_started.emit()
	local_player_registered.emit(host_id)
	state_changed.emit()
	return OK


## 加入房间。返回 [constant OK] 或错误码。
func join_game(address: String, port: int = DEFAULT_PORT) -> int:
	_stop_transport()
	last_error = ""
	var t := _create_transport()
	if t == null:
		last_error = TransportFactory.unavailable_reason(backend)
		connection_failed.emit(last_error)
		return ERR_UNAVAILABLE
	transport = t
	_connect_transport_signals()

	var err := transport.join(address, port)
	if err != OK:
		last_error = transport.last_error
		connection_failed.emit(last_error)
		_stop_transport()
		return err

	mode = Mode.CLIENT
	# 具体名单由房主回包填充。
	players = {}
	state_changed.emit()
	return OK


## 离开会话，回到单机。
func stop() -> void:
	var was_host := is_host()
	_stop_transport()
	mode = Mode.OFFLINE
	players.clear()
	players_changed.emit()
	if was_host:
		server_stopped.emit()
	state_changed.emit()


## 向房主上报「我准备好了」。
func set_ready(is_ready: bool = true) -> void:
	if not is_multiplayer_active():
		return
	if is_host():
		var host_id := get_server_id()
		if players.has(host_id):
			players[host_id]["ready"] = is_ready
			_broadcast_players()
	else:
		_set_ready.rpc_id(get_server_id(), is_ready)


## 房主宣布开始一局。
##
## 为什么需要它：「开始游戏」原本是各端各自的本地操作，于是房主进了关卡、
## 客户端还停在主菜单上 —— 四人协作没法玩。房间的节奏应当由房主决定，
## 各端只是跟随。
##
## [param mode] 与 ModeSelect 的模式编号一致（0 = 城镇，1 = 雪地）。
func start_match(mode: int) -> void:
	if not is_multiplayer_active():
		# 单机：直接本地开始，和联机走同一条路径，避免两套分支各自跑偏。
		match_started.emit(mode)
		return
	if not is_host():
		push_warning("Net: 只有房主能开始一局，客户端应当等待 match_started。")
		return
	# call_local：房主自己也收到，进入同一个模式，不必再写一份本地分支。
	_match_started.rpc(mode)


@rpc("authority", "call_local", "reliable")
func _match_started(mode: int) -> void:
	match_started.emit(mode)


# --- 内部：传输层装配 ---------------------------------------------------------

func _create_transport() -> NetworkTransport:
	if transport_factory.is_valid():
		return transport_factory.call(backend) as NetworkTransport
	return TransportFactory.create(backend)


func _stop_transport() -> void:
	if transport != null:
		_disconnect_transport_signals()
		transport.close()
		transport = null


func _connect_transport_signals() -> void:
	if transport == null:
		return
	if not transport.peer_joined.is_connected(_on_peer_joined):
		transport.peer_joined.connect(_on_peer_joined)
	if not transport.peer_left.is_connected(_on_peer_left):
		transport.peer_left.connect(_on_peer_left)
	if not transport.closed.is_connected(_on_transport_closed):
		transport.closed.connect(_on_transport_closed)
	if not transport.state_changed.is_connected(_on_transport_state_changed):
		transport.state_changed.connect(_on_transport_state_changed)


func _disconnect_transport_signals() -> void:
	if transport == null:
		return
	if transport.peer_joined.is_connected(_on_peer_joined):
		transport.peer_joined.disconnect(_on_peer_joined)
	if transport.peer_left.is_connected(_on_peer_left):
		transport.peer_left.disconnect(_on_peer_left)
	if transport.closed.is_connected(_on_transport_closed):
		transport.closed.disconnect(_on_transport_closed)
	if transport.state_changed.is_connected(_on_transport_state_changed):
		transport.state_changed.disconnect(_on_transport_state_changed)


func _check_transport_failure() -> void:
	if transport == null:
		return
	if transport.state != NetworkTransport.State.FAILED:
		return
	last_error = transport.last_error
	_stop_transport()
	mode = Mode.OFFLINE
	players.clear()
	players_changed.emit()
	connection_failed.emit(last_error)
	state_changed.emit()


# --- 内部：传输层回调 ---------------------------------------------------------

func _on_transport_state_changed(new_state: int) -> void:
	_trace("传输层状态 -> %d（mode=%d is_client=%s）" % [new_state, mode, str(is_client())])
	state_changed.emit()
	if new_state == NetworkTransport.State.CONNECTED and is_client():
		# 向房主报到；它会回一份完整名单。
		_trace("向房主 %d 报到，名字=%s" % [get_server_id(), local_player_name])
		_register_player.rpc_id(get_server_id(), local_player_name)
		joined_server.emit()


func _on_transport_closed() -> void:
	_stop_transport()
	mode = Mode.OFFLINE
	players.clear()
	players_changed.emit()
	server_disconnected.emit()
	state_changed.emit()


# --- 内部：名单同步 -----------------------------------------------------------

func _on_peer_joined(peer_id: int) -> void:
	# 只有权威方维护并广播名单。
	if not is_host():
		return
	_trace("peer 加入：%d" % peer_id)
	# ORDERING MATTERS: SceneTree polls the MultiplayerAPI *before* running node
	# _process(), so a fast client's _register_player RPC can already have filled
	# in the real name by the time this fires. Overwriting unconditionally would
	# clobber that name back to the placeholder. Only seed a missing entry.
	if players.has(peer_id):
		return
	players[peer_id] = {"name": "Player", "ready": false}
	_broadcast_players()


func _on_peer_left(peer_id: int) -> void:
	if not is_host():
		return
	_trace("peer 离开：%d" % peer_id)
	players.erase(peer_id)
	_broadcast_players()


# --- RPC ---------------------------------------------------------------------

## 客户端向房主报到。
@rpc("any_peer", "call_remote", "reliable")
func _register_player(player_name: String) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	_trace("收到报到：sender=%d name=%s" % [sender, player_name])
	if sender == 0:
		return
	players[sender] = {
		"name": str(player_name).strip_edges().substr(0, MAX_NAME_LENGTH),
		"ready": false,
	}
	_broadcast_players()


## 客户端上报准备状态，房主转发给所有人。
@rpc("any_peer", "call_remote", "reliable")
func _set_ready(is_ready: bool) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if players.has(sender):
		players[sender]["ready"] = is_ready
		_broadcast_players()


## 房主把名单推给所有人。
@rpc("authority", "call_remote", "reliable")
func _sync_players(snapshot: Dictionary) -> void:
	players = snapshot
	players_changed.emit()
	state_changed.emit()
	var local_id := get_unique_id()
	if players.has(local_id):
		local_player_registered.emit(local_id)


func _broadcast_players() -> void:
	_trace("广播名单 -> %s" % str(players.keys()))
	players_changed.emit()
	for peer_id in players.keys():
		if peer_id == get_unique_id():
			continue
		_sync_players.rpc_id(peer_id, players)
