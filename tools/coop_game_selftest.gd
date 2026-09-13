extends SceneTree

## 报告写到项目内的固定位置：Windows / Linux / CI 路径完全一致，脚本不必去猜
## Godot 的 user:// 落在哪（Windows 是 %APPDATA%，Linux 是 $XDG_DATA_HOME）。
const REPORT_DIR := "res://_userdata/reports"
const REPORT_PATH := REPORT_DIR + "/coop_game_selftest.log"
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
## 传送门在 Town 子场景下（Town 是 Main.tscn 的子场景）。
const PORTAL_PATH := "Town/TileMap2/PortalRoot/Portal"
const PORT := 27423
const MAX_FRAMES := 2400
const SETTLE := 25
const CLIENT_NAME := "ClientPlayer"

enum Stage { LOAD_SCENE, CONNECTING, CLIENT_WORLD, HOST_WORLD, SPAWN_MONSTER, VERIFY, REATTACH, PORTAL_SOLO, PORTAL_VERIFY, DONE }


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

	## 签名必须和 RemotePlayer 的一致（含武器表现的两个可选参数）。
	func apply_remote_state(pos: Vector2, _flip: bool, _gun_path: String = "", _aim: float = 0.0) -> void:
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
var _stage: int = Stage.LOAD_SCENE

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
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	_log = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
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

	# 关键顺序：先加载真实主场景，而且此时**还没有联机**。
	# 这才是玩家的真实流程 —— 游戏先启动、主菜单出现，玩家之后才去开房。
	# Town 和主菜单同属 Main.tscn，所以它的 _ready() 会在未联机时跑完，
	# _setup_coop_world() 那一刻会直接返回。联机必须靠 Net.state_changed
	# 的监听补挂，否则「普通模式」下的联机永远不会生效。
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
	_say("[gcoop] 真实主场景已加载，此时尚未联机（第 %d 帧）" % _frames)
	_advance(Stage.LOAD_SCENE)


func _tick() -> void:
	match _stage:
		Stage.LOAD_SCENE:
			_tick_load_scene()
		Stage.CONNECTING:
			_tick_connecting()
		Stage.CLIENT_WORLD:
			_tick_client_world()
		Stage.HOST_WORLD:
			_tick_host_world()
		Stage.SPAWN_MONSTER:
			_tick_spawn_monster()
		Stage.VERIFY:
			_tick_verify()
		Stage.REATTACH:
			_tick_reattach()
		Stage.PORTAL_SOLO:
			_tick_portal_solo()
		Stage.PORTAL_VERIFY:
			_tick_portal_verify()
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
	_advance(Stage.HOST_WORLD)


func _tick_load_scene() -> void:
	if _frames - _stage_mark < SETTLE:
		return
	# 还没联机：Town 不应该挂载 Coop 世界。
	_check(_host_coop.get("world") == null,
		"未联机时 Town 不应当挂载 Coop 世界")

	# 现在开房 —— 等价于玩家在主菜单点了「开房」。
	var host_err: int = _host_net.call("host_game", PORT, 8)
	_check(host_err == OK, "房主开房应当成功，错误码 " + str(host_err))

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


func _tick_host_world() -> void:
	if _frames - _stage_mark < SETTLE * 2:
		return
	_check(bool(_host_coop.call("is_active")),
		"场景先加载、之后才开房时，Coop 世界也应当被挂上（靠 Net.state_changed 补挂）")
	_check(_host_coop.get("world") != null,
		"联机建立后 Town 应当已经持有 world 上下文")
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
		# 代理必须和本地 Hero 处在**不同的层**上。
		# Hero 的 CollisionShape2D 没设 collision_mask，默认是 1（bit0）；
		# 代理如果也占 bit0，本地 Hero 就会把队友当成实体障碍 —— 实测会被
		# 队友顶住推着走，最后卡进补给站里出不来。
		_check((other.collision_layer & 1) == 0,
			"远端玩家代理不能占用 bit0（Hero 的默认 mask），实际 layer=" + str(other.collision_layer))
		_check((other.collision_layer & 8) != 0,
			"远端玩家代理应当占用 bit3（玩家层，供怪物攻击 Area2D 检测），实际 layer=" + str(other.collision_layer))
		if mine != null:
			_check((mine.collision_mask & 8) == 0,
				"本地 Hero 的 collision_mask 不应包含 bit3，否则会被队友代理阻挡，实际 mask=" + str(mine.collision_mask))
		# 节点存在 ≠ 看得见。这里踩过 LobbyUI 的坑（26 项全绿但界面隐形），
		# 所以远端代理必须验证到精灵这一层。
		_check(other.visible and other.is_visible_in_tree(),
			"远端玩家代理应当可见")
		var proxy_sprite := other.find_child("AnimatedSprite2D", true, false) as AnimatedSprite2D
		_check(proxy_sprite != null, "远端玩家代理应当有 AnimatedSprite2D")
		if proxy_sprite != null:
			_check(proxy_sprite.visible and proxy_sprite.is_visible_in_tree(),
				"代理的精灵应当可见")
			_check(proxy_sprite.sprite_frames != null,
				"代理的 SpriteFrames 不能为空 —— 否则角色完全画不出来")
			if proxy_sprite.sprite_frames != null:
				_check(proxy_sprite.sprite_frames.has_animation("idle"),
					"代理的 SpriteFrames 应当包含 idle 动画")
				_say("[gcoop] 代理动画=%s 帧数=%d" % [
					str(proxy_sprite.animation),
					proxy_sprite.sprite_frames.get_frame_count("idle")])

	# 客户端视角
	_check(int(_client_coop.call("get_player_count")) == 2,
		"客户端应看到 2 个玩家，实际 " + str(_client_coop.call("get_player_count")))
	var client_self: Node = _client_coop.call("get_player_node", _client_peer)
	var client_sees_host: Node = _client_coop.call("get_player_node", host_id)
	_check(client_self != null and bool(client_self.get("is_local")),
		"客户端自己应当是本地玩家")
	_check(client_sees_host != null and not bool(client_sees_host.get("is_local")),
		"客户端上的房主应当是远端代理")

	# 两端必须从同一个出生点开始，否则玩家互相看不见 —— 这就是踩过的坑：
	# 房主留在场景预置 Hero 的位置，客户端生成在 PositionHome，两边隔了半张地图。
	var host_self: Node = _host_coop.call("get_player_node", host_id)
	if host_self != null and client_self != null:
		_say("[gcoop] 房主本机玩家位置=%s 客户端本机玩家位置=%s" % [
			str(host_self.global_position), str(client_self.global_position)])
		_check(host_self.global_position.is_equal_approx(client_self.global_position),
			"两端本机玩家应当从同一个出生点开始：房主 %s vs 客户端 %s" % [
				str(host_self.global_position), str(client_self.global_position)])


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

	# 传送门：必须所有人到齐才开放。
	_portal = _main_scene.get_node_or_null(PORTAL_PATH)
	_check(_portal != null, "应当能找到传送门 " + PORTAL_PATH)
	if _portal == null:
		_finish()
		return
	var utils := root.get_node_or_null(^"Utils")
	_host_player = null if utils == null else utils.get("player")
	_check(_host_player != null, "应当能拿到房主的本机玩家")
	if _host_player == null:
		_finish()
		return
	# 房主的角色先走进传送门范围。
	_host_player.global_position = _portal.global_position
	_advance(Stage.PORTAL_SOLO)


func _tick_portal_solo() -> void:
	if _frames - _stage_mark < 30:
		return
	# 房间里是 2 个人，只有房主一个人在门里 —— 不该开门。
	_check(_portal.expected_player_count() == 2,
		"联机时应期望 2 个玩家到齐，实际 " + str(_portal.expected_player_count()))
	_check(not _portal.is_complete(),
		"只有房主一个人在门里时不应该开放传送门")
	# 客户端报告自己也在传送门位置 —— 房主端的代理会跟着进入范围。
	_client_coop.call("report_local_state", _portal.global_position, false)
	_advance(Stage.PORTAL_VERIFY)


func _tick_portal_verify() -> void:
	if _frames - _stage_mark < 60:
		return
	_check(_portal.is_complete(),
		"两端都到齐后传送门应当开放")
	_verify_town_listens_to_coop()
	_finish()


## Town 必须真的**订阅**了 Coop 的这两条权威通知。
##
## 这条补的是一个代价很高的盲区：上一轮把「回合结束」从本地的
## `LevelServer.onRoundEnd` 改成房主广播 `Coop.round_ended`，但 Town 侧忘了连线。
## 原来的断言只验证了「信号发得出去」（coop_selftest 里数了两端的回调次数），
## 没验证「有人接」—— 于是「只有客户端不返回出发点」被改成了
## **「两个人都不返回」**，比修之前更糟。
##
## 直接查连接本身，不依赖任何运行时流程，是这类「接线漏了」最直接的守门方式。
func _verify_town_listens_to_coop() -> void:
	var town := _main_scene.get_node_or_null("Town")
	_check(town != null, "应当能找到 Town 节点")
	if town == null:
		return
	var coop := root.get_node_or_null(^"Coop")
	_check(coop != null, "应当能拿到 Coop autoload")
	if coop == null:
		return
	_check(coop.is_connected("level_advanced", Callable(town, "_on_level_advanced")),
		"Town 必须订阅 Coop.level_advanced，否则房主推进关卡后没人挪自己的玩家")
	_check(coop.is_connected("round_ended", Callable(town, "onRoundEnd")),
		"Town 必须订阅 Coop.round_ended，否则关卡结束后没人返回出发点")


var _portal: Node = null
var _host_player: Node2D = null


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
