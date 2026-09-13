extends Node
class_name CoopSession
## 合作生存的会话复制层（自动加载为 `Coop`）。
##
## 它把「联机会话」翻译成游戏世界里的复制行为，是唯一知道
## 「谁该出现、怪物归谁算、伤害怎么结算」的地方。
##
## 权威模型
##   * 房主是权威方：怪物生成/移动/死亡、伤害结算、关卡进程。
##   * 每个客户端本地即时模拟自己的角色（手感），把状态上报房主聚合。
##   * 房主把聚合后的世界状态广播回去，客户端只做表现。
##
## 为什么玩家状态要「客户端上报 -> 房主聚合 -> 房主广播」
##   ENet 是星型拓扑：客户端的 rpc() 只能到达房主，客户端之间不直连。
##   所以房主必须当聚合点，否则客户端 A 永远看不到客户端 B 在动。
##
## 单机行为
##   未联机时 [method is_active] 为 false，本节点完全不介入：关卡场景照旧
##   自己造玩家和怪物。联机开关不会改变单机玩法。
##
## 无头可测性
##   所有节点都由 [CoopWorld] 里的工厂创建，测试可以注入替身节点，
##   从而在单进程内用两个 MultiplayerAPI 端到端验证整套复制协议。

## 世界已接管（关卡场景注册完成）。
signal world_attached()
## 世界已注销（关卡场景卸载）。
signal world_detached()
## 某个玩家的节点已在本端创建。
signal player_spawned(peer_id: int, node: Node2D)
## 某个玩家的节点已在本端移除。
signal player_despawned(peer_id: int)
## 某个怪物已在本端创建。
signal monster_spawned(net_id: int, node: Node2D)
## 某个怪物已在本端移除。
signal monster_removed(net_id: int)
## 某个掉落物已在本端创建。
signal pickup_spawned(net_id: int, node: Node2D)
## 某个掉落物已在本端移除。
signal pickup_removed(net_id: int)
## 掉落物被拾取（只有房主会发出，因为归属由房主裁定）。
signal pickup_claimed(net_id: int, by_peer: int)
## 本机玩家受到伤害（由房主裁定并下发）。
signal local_player_damaged(amount: float)
## 关卡共享状态（关卡号/剩余时间/击杀/金币）发生变化。
signal level_state_changed()

## 玩家位置的上报/广播频率（秒）。
const PLAYER_SYNC_INTERVAL := 0.05
## 关卡状态广播频率（秒）。
const LEVEL_SYNC_INTERVAL := 0.25

## 本端注册的世界上下文；未进入关卡时为 null。
var world: CoopWorld = null

## 本会话层使用的 NetworkManager。
## 为空时用 autoload 的 `Net`；无头测试注入独立实例，从而能在一棵场景树里
## 同时跑房主和客户端两侧的会话层。
var net_override: Node = null

# --- 共享关卡状态（房主写，客户端读）---------------------------------------
var level := 1
var time_left := 0.0
var kills := 0
var gold := 0
var round_active := false

## peer_id -> 该玩家最近的权威位置/朝向（房主维护）。
var _player_states: Dictionary = {}
## peer_id -> 本端为该玩家创建的节点。
var _player_nodes: Dictionary = {}
## peer_id -> true，表示该玩家节点是会话层自己造的（而不是场景预置的）。
## 世界卸载时只能释放自己造的那些，不能连带把场景里的 Hero 一起删掉。
var _owned_players: Dictionary = {}
## net_id -> 本端创建的怪物节点。
var _monster_nodes: Dictionary = {}
## net_id -> 怪物的权威数据快照（用于中途加入时补发）。
var _monster_records: Dictionary = {}
var _next_monster_id := 1
## net_id -> 本端创建的掉落物节点。
var _pickup_nodes: Dictionary = {}
## net_id -> 掉落物的权威数据（用于中途加入时补发）。
var _pickup_records: Dictionary = {}
var _next_pickup_id := 1

var _player_sync_accum := 0.0
## 联机调试输出开关，跟随 NetworkManager 的 verbose。
var verbose := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## 本会话层背后的 NetworkManager。
##
## 返回类型故意留成 Variant，而且**不用 `Net` 这个标识符直接引用**：
##   * NetworkManager 是 autoload 脚本，没有可引用的静态类型；
##   * 更关键的是，`--script` 模式下入口脚本会在 autoload 注册之前就被编译，
##     此时编译器不认识 `Net`，会直接报 "Identifier not found: Net"。
## 所以这里在运行时从 /root 找节点，找不到就返回 null。
func _net() -> Variant:
	if net_override != null:
		return net_override
	return find_autoload("Net")


## 按名字从 /root 取一个 autoload 节点。
## 不要换成标识符直接引用：见 [method _net] 的说明。
func find_autoload(node_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(node_name))


# --- 世界注册 -----------------------------------------------------------------

## 关卡场景就绪时调用，把复制容器交给会话层。
func attach_world(new_world: CoopWorld) -> void:
	detach_world()
	world = new_world
	if is_active():
		verbose = bool(_net().get("verbose"))
		_connect_session_signals()
		if _is_host():
			# 房主立刻把当前名单里的人生成出来。
			_reconcile_players()
		else:
			# 客户端：场景加载完成才挂世界，此时房主早先广播的生成事件已经错过，
			# 必须主动要一份完整状态。
			_request_world.rpc_id(_net().get_server_id())
	world_attached.emit()


## 关卡场景卸载时调用。
func detach_world() -> void:
	if world == null:
		return
	_disconnect_session_signals()
	_clear_spawned_nodes()
	_clear_runtime_state()
	world = null
	world_detached.emit()


## 会话是否真正生效：既在联机中，又有一个已注册的世界。
func is_active() -> bool:
	if world == null or not is_instance_valid(world.player_root):
		return false
	var n: Variant = _net()
	return n != null and bool(n.is_multiplayer_active())


## 本端是否为权威方；没有会话时返回 false。
func is_host() -> bool:
	var n: Variant = _net()
	return n != null and bool(n.is_host())


func _is_host() -> bool:
	return is_host()


func _connect_session_signals() -> void:
	var n: Variant = _net()
	if n == null:
		return
	if not n.players_changed.is_connected(_on_players_changed):
		n.players_changed.connect(_on_players_changed)
	if not n.state_changed.is_connected(_on_net_state_changed):
		n.state_changed.connect(_on_net_state_changed)


func _disconnect_session_signals() -> void:
	var n: Variant = _net()
	if n == null:
		return
	if n.players_changed.is_connected(_on_players_changed):
		n.players_changed.disconnect(_on_players_changed)
	if n.state_changed.is_connected(_on_net_state_changed):
		n.state_changed.disconnect(_on_net_state_changed)


func _clear_runtime_state() -> void:
	_player_states.clear()
	_player_nodes.clear()
	_monster_nodes.clear()
	_monster_records.clear()


func _on_net_state_changed() -> void:
	# 会话结束（主动断开或掉线）：清掉复制出来的节点。
	# 不清的话重连时 _player_nodes 里还留着旧条目，_reconcile_players 会以为
	# 这些玩家已经生成过而跳过，结果就是重连后看不到任何人。
	if not bool(_net().is_multiplayer_active()):
		_clear_spawned_nodes()
		return
	if _is_host():
		_reconcile_players()


func _on_players_changed() -> void:
	if not is_active() or not _is_host():
		return
	_reconcile_players()


# --- 玩家复制 -----------------------------------------------------------------

## 房主：让本端的玩家节点集合与权威名单一致。
func _reconcile_players() -> void:
	if world == null or not world.is_valid():
		return
	for peer_id in _net().players.keys():
		if _player_nodes.has(peer_id):
			continue
		_spawn_player.rpc(int(peer_id), world.spawn_position, str(_net().get_player_name(peer_id)))
		# 中途加入：把已有的怪物与关卡进度补发给这位玩家。
		resync_peer(int(peer_id))
	# 名单里已经没有的 peer 要清掉。
	for peer_id in _player_nodes.keys():
		if not _net().players.has(peer_id):
			_despawn_player.rpc(int(peer_id))


## 所有 peer 都执行：为本端创建某个玩家的节点。
##
## call_local 让房主和客户端的代码路径完全一致，避免两套分支各自跑偏。
@rpc("authority", "call_local", "reliable")
func _spawn_player(peer_id: int, spawn_pos: Vector2, player_name: String) -> void:
	if world == null or not world.is_valid():
		return
	if _player_nodes.has(peer_id):
		return

	var is_local: bool = peer_id == int(_net().get_unique_id())
	var node: Node2D = null
	if is_local and world.local_player_node != null and is_instance_valid(world.local_player_node):
		# 场景里已经摆好的本地玩家（例如 Town.tscn 的 Hero），直接复用。
		# 注意不要把 world.local_player_node 置空：世界可能被卸载后重新挂载，
		# 那时还要靠它认领同一个节点。
		node = world.local_player_node
	else:
		var factory: Callable = world.local_player_factory if is_local else world.remote_player_factory
		if not factory.is_valid():
			_trace("没有为 peer %d 配置%s玩家工厂，跳过生成" % [peer_id, "本地" if is_local else "远端"])
			return
		node = factory.call()
		_owned_players[peer_id] = true
	if node == null:
		return
	node.name = "P%d" % peer_id
	# 联机时**所有**玩家都从同一个出生点开始，包括场景预置的那个 Hero。
	#
	# 这里踩过一次坑：原先特意保留预置 Hero 的原位置（「它已经有自己的位置」），
	# 结果房主留在 TileMap2/PlayerRoot/Hero，客户端却生成在 PositionHome ——
	# 两个点不在一起，两端隔着大半张地图，互相看不见对方。
	node.global_position = spawn_pos
	if is_local:
		if node.has_method("mark_as_local_player"):
			node.call("mark_as_local_player", peer_id)
	else:
		if node.has_method("setup_remote_player"):
			node.call("setup_remote_player", peer_id, player_name)
	_player_states[peer_id] = {"p": node.global_position, "flip": false}
	if node.get_parent() == null:
		world.player_root.add_child(node)
	_player_nodes[peer_id] = node
	_trace("生成玩家节点 peer=%d local=%s" % [peer_id, str(is_local)])
	player_spawned.emit(peer_id, node)


@rpc("authority", "call_local", "reliable")
func _despawn_player(peer_id: int) -> void:
	var node: Node2D = _player_nodes.get(peer_id)
	if node == null:
		return
	_player_nodes.erase(peer_id)
	_player_states.erase(peer_id)
	if is_instance_valid(node):
		node.queue_free()
	_trace("移除玩家节点 peer=%d" % peer_id)
	player_despawned.emit(peer_id)


## 清空本端复制出来的所有节点（断线重连、世界卸载时用）。
## 只释放会话层自己造的节点：场景预置的 Hero 属于场景，不归这里管。
func _clear_spawned_nodes() -> void:
	for peer_id in _player_nodes.keys():
		if not _owned_players.has(peer_id):
			continue
		var node: Node2D = _player_nodes[peer_id]
		if is_instance_valid(node):
			node.queue_free()
	_player_nodes.clear()
	_owned_players.clear()
	_player_states.clear()
	for net_id in _monster_nodes.keys():
		var monster: Node2D = _monster_nodes[net_id]
		if is_instance_valid(monster):
			monster.queue_free()
	_monster_nodes.clear()
	_monster_records.clear()
	for pickup_id in _pickup_nodes.keys():
		var pickup: Node2D = _pickup_nodes[pickup_id]
		if is_instance_valid(pickup):
			pickup.queue_free()
	_pickup_nodes.clear()
	_pickup_records.clear()


# --- 玩家状态同步 -------------------------------------------------------------

## 本机玩家每帧调用（由本地玩家节点驱动）。只有非权威端需要上报。
func report_local_state(position: Vector2, flip: bool) -> void:
	if not is_active():
		return
	if _is_host():
		# 房主自己的位置直接进权威表，不必走网络。
		_player_states[_net().get_unique_id()] = {"p": position, "flip": flip}
	else:
		_report_player_state.rpc_id(_net().get_server_id(), position, flip)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _report_player_state(position: Vector2, flip: bool) -> void:
	if not _is_host():
		return
	# 用发送者 id 而不是参数里的 id，避免伪造别人的位置。
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	_player_states[sender] = {"p": position, "flip": flip}


## 本端玩家节点构造时调用，让 Coop 知道自己该往哪写位置。
func register_local_player_node(node: Node2D) -> void:
	var n: Variant = _net()
	if n == null:
		return
	_player_nodes[int(n.get_unique_id())] = node


# --- 怪物复制 -----------------------------------------------------------------

## 房主：生成一只权威怪物，并把生成事件广播给所有人。
## [param monster_type] 是 [member CoopWorld.monster_factories] 里的键。
## 返回分配到的 net_id；非房主调用返回 0。
func spawn_monster(monster_type: String, position: Vector2, data: Dictionary = {}) -> int:
	if not is_active() or not _is_host():
		return 0
	var net_id := _next_monster_id
	_next_monster_id += 1
	_spawn_monster.rpc(net_id, monster_type, position, data)
	return net_id


@rpc("authority", "call_local", "reliable")
func _spawn_monster(net_id: int, monster_type: String, position: Vector2, data: Dictionary) -> void:
	if world == null or not world.is_valid():
		return
	if _monster_nodes.has(net_id):
		return
	var factory: Variant = world.monster_factories.get(monster_type)
	if factory == null or not (factory is Callable) or not (factory as Callable).is_valid():
		_trace("未注册的怪物类型：%s" % monster_type)
		return
	var node: Node2D = (factory as Callable).call()
	if node == null:
		return
	node.name = "M%d" % net_id
	node.global_position = position
	_monster_records[net_id] = {"type": monster_type, "p": position, "data": data}
	if node.has_method("setData") and not data.is_empty():
		node.call("setData", data)
	# 客户端上的怪物是「影子」：不跑 AI、不本地结算伤害。
	if node.has_method("set_authoritative"):
		node.call("set_authoritative", _is_host())
	if node.has_method("set_network_id"):
		node.call("set_network_id", net_id)
	world.monster_root.add_child(node)
	_monster_nodes[net_id] = node
	_trace("生成怪物 net_id=%d type=%s authoritative=%s" % [net_id, monster_type, str(_is_host())])
	monster_spawned.emit(net_id, node)


## 房主：移除一只怪物并广播。
func despawn_monster(net_id: int) -> void:
	if not is_active() or not _is_host():
		return
	_despawn_monster.rpc(net_id)


@rpc("authority", "call_local", "reliable")
func _despawn_monster(net_id: int) -> void:
	var node: Node2D = _monster_nodes.get(net_id)
	_monster_nodes.erase(net_id)
	_monster_records.erase(net_id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	_trace("移除怪物 net_id=%d" % net_id)
	monster_removed.emit(net_id)


## 怪物节点死亡时由自身调用，避免会话层去猜节点的生命周期。
func notify_monster_died(net_id: int) -> void:
	if not is_active():
		return
	if _is_host():
		despawn_monster(net_id)
	else:
		# 客户端只做本地清理，权威端会另行广播。
		_monster_nodes.erase(net_id)
		_monster_records.erase(net_id)


# --- 掉落物复制 ---------------------------------------------------------------
##
## 掉落物和怪物有个关键区别：**每一端都保留可交互的实体**。
## 怪物在客户端是「影子」（不跑逻辑），但金币必须能被任何本地玩家碰到。
## 所以这里不做权威/影子之分，只做「房主决定生成与消失，拾取权由房主裁定」：
##   本地玩家碰到 -> 本地加钱 -> 上报房主 -> 房主广播移除（避免队友重复拾取）。

## 房主：生成一个掉落物并广播给所有人。返回分配的 net_id；非房主返回 0。
func spawn_pickup(pickup_type: String, position: Vector2, data: Dictionary = {}) -> int:
	if not is_active() or not _is_host():
		return 0
	var net_id := _next_pickup_id
	_next_pickup_id += 1
	_spawn_pickup.rpc(net_id, pickup_type, position, data)
	return net_id


@rpc("authority", "call_local", "reliable")
func _spawn_pickup(net_id: int, pickup_type: String, position: Vector2, data: Dictionary) -> void:
	if world == null or not world.is_valid():
		return
	if _pickup_nodes.has(net_id):
		return
	var factory: Variant = world.pickup_factories.get(pickup_type)
	if factory == null or not (factory is Callable) or not (factory as Callable).is_valid():
		_trace("未注册的掉落物类型：%s" % pickup_type)
		return
	var node: Node2D = (factory as Callable).call()
	if node == null:
		return
	node.name = "K%d" % net_id
	node.global_position = position
	_pickup_records[net_id] = {"type": pickup_type, "p": position, "data": data}
	if node.has_method("set_network_id"):
		node.call("set_network_id", net_id)
	var container := world.pickup_container()
	if container == null:
		node.queue_free()
		return
	container.add_child(node)
	_pickup_nodes[net_id] = node
	_trace("生成掉落物 net_id=%d type=%s" % [net_id, pickup_type])
	pickup_spawned.emit(net_id, node)


## 房主：移除一个掉落物并广播。
func despawn_pickup(net_id: int) -> void:
	if not is_active() or not _is_host():
		return
	_despawn_pickup.rpc(net_id)


@rpc("authority", "call_local", "reliable")
func _despawn_pickup(net_id: int) -> void:
	var node: Node2D = _pickup_nodes.get(net_id)
	_pickup_nodes.erase(net_id)
	_pickup_records.erase(net_id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	_trace("移除掉落物 net_id=%d" % net_id)
	pickup_removed.emit(net_id)


## 任何一端拾取掉落物后调用。
##   房主：直接裁定归属并广播移除。
##   客户端：上报房主，由房主裁定，避免两个玩家同时捡到同一枚金币。
func report_pickup_claimed(net_id: int) -> void:
	if not is_active():
		return
	if _is_host():
		_resolve_pickup_claim(net_id, int(_net().get_unique_id()))
	else:
		_report_pickup_claimed.rpc_id(_net().get_server_id(), net_id)


@rpc("any_peer", "call_remote", "reliable")
func _report_pickup_claimed(net_id: int) -> void:
	if not _is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	_resolve_pickup_claim(net_id, sender)


func _resolve_pickup_claim(net_id: int, by_peer: int) -> void:
	# 已经被别人捡走的话，_pickup_nodes 里就没有它了，这里天然幂等。
	if not _pickup_nodes.has(net_id):
		return
	pickup_claimed.emit(net_id, by_peer)
	despawn_pickup(net_id)


func get_pickup_node(net_id: int) -> Node2D:
	var node: Variant = _pickup_nodes.get(net_id)
	return node if node is Node2D and is_instance_valid(node) else null


func get_pickup_count() -> int:
	return _pickup_nodes.size()


func get_pickup_ids() -> Array:
	var ids := _pickup_nodes.keys()
	ids.sort()
	return ids


# --- 伤害路由 -----------------------------------------------------------------

## 任何一端命中怪物都走这里。
##   房主：直接在自己权威的怪物上结算。
##   客户端：把伤害上报房主，由房主决定死活，再把结果广播回来。
func apply_monster_damage(net_id: int, amount: float) -> void:
	if not is_active():
		return
	if _is_host():
		_resolve_monster_damage(net_id, amount)
	else:
		_report_monster_damage.rpc_id(_net().get_server_id(), net_id, amount)


@rpc("any_peer", "call_remote", "reliable")
func _report_monster_damage(net_id: int, amount: float) -> void:
	if not _is_host():
		return
	# 基本校验：只接受有量纲意义的正伤害，防止客户端上报 NaN/负数回血。
	if not is_finite(amount) or amount <= 0.0:
		return
	_resolve_monster_damage(net_id, amount)


func _resolve_monster_damage(net_id: int, amount: float) -> void:
	var node: Node2D = _monster_nodes.get(net_id)
	if node == null or not is_instance_valid(node):
		return
	if node.has_method("apply_network_damage"):
		node.call("apply_network_damage", amount)


## 房主结算：把权威血量广播给所有端（用于修正客户端的表现血量）。
func broadcast_monster_hp(net_id: int, hp: float) -> void:
	if not is_active() or not _is_host():
		return
	_sync_monster_hp.rpc(net_id, hp)


@rpc("authority", "call_local", "reliable")
func _sync_monster_hp(net_id: int, hp: float) -> void:
	var node: Node2D = _monster_nodes.get(net_id)
	if node == null or not is_instance_valid(node):
		return
	if node.has_method("apply_network_damage"):
		# 客户端影子的血量直接对齐房主，不再二次扣减。
		node.call("set_network_hp", hp)


## 房主对某个玩家结算伤害（怪物攻击等），由该玩家的本机扣血。
func apply_player_damage(peer_id: int, amount: float) -> void:
	if not is_active() or not _is_host():
		return
	if peer_id == _net().get_unique_id():
		_damage_local_player(amount)
	else:
		_player_damage.rpc_id(peer_id, amount)


@rpc("authority", "call_remote", "reliable")
func _player_damage(amount: float) -> void:
	_damage_local_player(amount)


func _damage_local_player(amount: float) -> void:
	# 先发信号：即使本端还没有玩家节点（例如关卡正在加载），UI 也能给出反馈，
	# 而且这让「伤害确实路由到了本人」这件事可以被无头测试断言。
	local_player_damaged.emit(amount)
	# Utils 也是 autoload，同样不能按标识符编译期引用。
	var utils := find_autoload("Utils")
	if utils == null:
		return
	var player: Variant = utils.get("player")
	if player == null or not is_instance_valid(player):
		return
	if player.has_method("onHit"):
		player.call("onHit", amount)


# --- 弹道表现同步 -------------------------------------------------------------
##
## 这只是**表现**：子弹是各端本地生成的，所以队友默认看不到你在开火。
## 真正的命中与伤害仍然只有房主的权威判定那一发算数（见「伤害路由」），
## 表现子弹的碰撞层是空的，飞出去就消失。
##
## 为什么房主要当中转：ENet 是星型拓扑，客户端之间不能直接通信，
## 所以客户端 A 的开火必须由房主转发给 B。

## 收到队友开火（本地据此复现弹道）。
signal shot_fired(shooter_peer: int, from: Vector2, direction: Vector2, speed: float)


## 本机玩家开火时调用。
func broadcast_shot(from: Vector2, direction: Vector2, speed: float) -> void:
	if not is_active():
		return
	if _is_host():
		_shot_fired.rpc(int(_net().get_unique_id()), from, direction, speed)
	else:
		_report_shot.rpc_id(_net().get_server_id(), from, direction, speed)


@rpc("any_peer", "call_remote", "unreliable")
func _report_shot(from: Vector2, direction: Vector2, speed: float) -> void:
	if not _is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	_shot_fired.rpc(sender, from, direction, speed)


@rpc("authority", "call_remote", "unreliable")
func _shot_fired(shooter_peer: int, from: Vector2, direction: Vector2, speed: float) -> void:
	# 不给自己复现：本地那一发已经飞出去了，再生成一次会变成双份。
	if shooter_peer == int(_net().get_unique_id()):
		return
	shot_fired.emit(shooter_peer, from, direction, speed)
	if world != null and world.shot_visual_factory.is_valid():
		world.shot_visual_factory.call(shooter_peer, from, direction, speed)


# --- 关卡状态同步 -------------------------------------------------------------

## 房主更新共享关卡状态并广播。
func publish_level_state(p_level: int, p_time_left: float, p_kills: int, p_gold: int, p_active: bool) -> void:
	if not is_active() or not _is_host():
		return
	level = p_level
	time_left = p_time_left
	kills = p_kills
	gold = p_gold
	round_active = p_active
	_sync_level_state.rpc(level, time_left, kills, gold, round_active)
	level_state_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_level_state(p_level: int, p_time_left: float, p_kills: int, p_gold: int, p_active: bool) -> void:
	level = p_level
	time_left = p_time_left
	kills = p_kills
	gold = p_gold
	round_active = p_active
	level_state_changed.emit()


## 房主记录一次击杀（怪物死亡时调用）。
func add_kill() -> void:
	if not is_active() or not _is_host():
		return
	kills += 1


# --- 中途加入 -----------------------------------------------------------------

## 客户端挂上世界后向房主索取完整状态。
@rpc("any_peer", "call_remote", "reliable")
func _request_world() -> void:
	if not _is_host() or world == null or not world.is_valid():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	_trace("peer %d 请求世界状态，开始补发" % sender)
	# 该 peer 连上时本端可能已经建过它的节点，但它那时世界还没加载完，
	# 所以这里按 id 重发全部玩家的生成事件（接收端有幂等保护），再补世界快照。
	for peer_id in _net().players.keys():
		_spawn_player.rpc_id(sender, int(peer_id), world.spawn_position,
			str(_net().get_player_name(peer_id)))
	resync_peer(sender)


## 房主把当前世界快照补发给某个 peer。
func resync_peer(peer_id: int) -> void:
	if not is_active() or not _is_host():
		return
	# 不能给自己发 RPC：Godot 会直接报
	# "RPC '_resync_world' on yourself is not allowed by selected mode"。
	if peer_id == int(_net().get_unique_id()):
		return
	var snapshot := {
		"level": level,
		"time_left": time_left,
		"kills": kills,
		"gold": gold,
		"round_active": round_active,
		"monsters": _monster_records.duplicate(true),
		"pickups": _pickup_records.duplicate(true),
	}
	_resync_world.rpc_id(peer_id, snapshot)


@rpc("authority", "call_remote", "reliable")
func _resync_world(snapshot: Dictionary) -> void:
	if world == null or not world.is_valid():
		return
	level = int(snapshot.get("level", 1))
	time_left = float(snapshot.get("time_left", 0.0))
	kills = int(snapshot.get("kills", 0))
	gold = int(snapshot.get("gold", 0))
	round_active = bool(snapshot.get("round_active", false))
	level_state_changed.emit()

	var monsters: Dictionary = snapshot.get("monsters", {})
	for raw_id in monsters.keys():
		var net_id := int(raw_id)
		if _monster_nodes.has(net_id):
			continue
		var record: Dictionary = monsters[raw_id]
		var position: Vector2 = record.get("p", Vector2.ZERO)
		var data: Dictionary = record.get("data", {})
		# net_id 由房主在快照里给定，客户端的节点表必须沿用同一个 id 空间，
		# 否则后续的伤害与移除 RPC 会对不上号。
		_spawn_monster(net_id, str(record.get("type", "")), position, data)

	var pickups: Dictionary = snapshot.get("pickups", {})
	for raw_pickup_id in pickups.keys():
		var pickup_id := int(raw_pickup_id)
		if _pickup_nodes.has(pickup_id):
			continue
		var pickup_record: Dictionary = pickups[raw_pickup_id]
		var pickup_position: Vector2 = pickup_record.get("p", Vector2.ZERO)
		var pickup_data: Dictionary = pickup_record.get("data", {})
		_spawn_pickup(pickup_id, str(pickup_record.get("type", "")), pickup_position, pickup_data)


# --- 玩家节点访问 -------------------------------------------------------------

## 本端为 [param peer_id] 创建的玩家节点，没有则返回 null。
func get_player_node(peer_id: int) -> Node2D:
	var node: Variant = _player_nodes.get(peer_id)
	return node if node is Node2D and is_instance_valid(node) else null


## 本端创建的怪物节点，没有则返回 null。
func get_monster_node(net_id: int) -> Node2D:
	var node: Variant = _monster_nodes.get(net_id)
	return node if node is Node2D and is_instance_valid(node) else null


func get_player_count() -> int:
	return _player_nodes.size()


func get_monster_count() -> int:
	return _monster_nodes.size()


func get_monster_ids() -> Array:
	var ids := _monster_nodes.keys()
	ids.sort()
	return ids


## 诊断串，方便在日志里看清状态。
func describe() -> String:
	if not is_active():
		return "coop: inactive"
	return "coop: %s | peer %d | players %d | monsters %d | level %d" % [
		"host" if _is_host() else "client",
		_net().get_unique_id(),
		_player_nodes.size(),
		_monster_nodes.size(),
		level,
	]


# --- 每帧 ---------------------------------------------------------------------

func _process(delta: float) -> void:
	# 只有房主需要周期性地把聚合好的玩家位置广播出去。
	if not is_active() or not _is_host():
		return
	_player_sync_accum += delta
	if _player_sync_accum < PLAYER_SYNC_INTERVAL:
		return
	_player_sync_accum = 0.0
	_broadcast_world_states()


func _broadcast_world_states() -> void:
	if not _player_states.is_empty():
		_sync_player_states.rpc(_player_states)
	var monsters := _collect_monster_states()
	if not monsters.is_empty():
		_sync_monster_states.rpc(monsters)


## 收集房主端所有怪物的权威位置。
func _collect_monster_states() -> Dictionary:
	var snapshot := {}
	for raw_id in _monster_nodes.keys():
		var net_id := int(raw_id)
		var node: Node2D = _monster_nodes[raw_id]
		if not is_instance_valid(node):
			continue
		snapshot[net_id] = {"p": node.global_position}
	return snapshot


## 客户端：把影子怪物插值到房主给的位置。
@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_monster_states(snapshot: Dictionary) -> void:
	for raw_id in snapshot.keys():
		var net_id := int(raw_id)
		var node: Node2D = get_monster_node(net_id)
		if node == null:
			continue
		var state: Dictionary = snapshot[raw_id]
		var target: Vector2 = state.get("p", node.global_position)
		if node.has_method("apply_remote_position"):
			node.call("apply_remote_position", target)
		else:
			node.global_position = target


func _broadcast_player_states() -> void:
	if _player_states.is_empty():
		return
	_sync_player_states.rpc(_player_states)


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_player_states(snapshot: Dictionary) -> void:
	for raw_id in snapshot.keys():
		var peer_id := int(raw_id)
		# 自己的角色是本地预测的，不接受远端覆盖。
		if peer_id == _net().get_unique_id():
			continue
		var state: Dictionary = snapshot[raw_id]
		_player_states[peer_id] = state
		var node: Node2D = get_player_node(peer_id)
		if node != null and node.has_method("apply_remote_state"):
			node.call("apply_remote_state", state.get("p", node.global_position), bool(state.get("flip", false)))


## 取某个玩家最近的权威位置（房主与客户端都有）。
func get_player_state(peer_id: int) -> Dictionary:
	var state: Variant = _player_states.get(peer_id)
	return state if state is Dictionary else {}


func _trace(message: String) -> void:
	if verbose:
		print("[Coop] " + message)
