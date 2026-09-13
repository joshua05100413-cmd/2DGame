extends SceneTree
## 联机大厅 UI 的无头自测。
##
## 验证目标
##   1. 大厅能用纯代码构建出来（Panel、后端下拉、房间成员列表都在）。
##   2. 后端列表同时列出 ENet 与 Steam，且把不可用的后端标注清楚。
##   3. 「开房」真的把 NetworkManager 带进房主状态，成员列表立刻出现自己。
##   4. 「断开」把一切复位，列表清空。
##   5. 连接一个不存在的房主会走超时失败路径并给出可展示的提示，
##      而不是静默卡住。
##
## 说明
##   这里用 autoload 的 `Net`（默认 MultiplayerAPI），所以是真实的端口监听，
##   不是 mock。多端之间的复制协议由 tools/coop_selftest.gd 覆盖。
##
## 用法
##   godot --headless --path . --script res://tools/lobby_selftest.gd

const LobbyScript := preload("res://ui/LobbyUI.gd")
const PORT := 27323
## 一个几乎不可能有人监听的端口，用来触发连接失败。
const DEAD_PORT := 27324
const MAX_FRAMES := 1800

enum Stage { BUILD, HOST, LEAVE, JOIN_FAIL, DONE }

var _log: FileAccess = null
var _failures: Array[String] = []
var _checks := 0
var _frames := 0
var _stage_mark := 0
var _finished := false
var _pending_start := false
var _stage: int = Stage.BUILD

var _lobby: Control = null
var _net: Node = null
var _host_clicked := false


func _initialize() -> void:
	_log = FileAccess.open("user://lobby_selftest.log", FileAccess.WRITE)
	_say("[lobby] Godot " + str(Engine.get_version_info()["string"]))
	# /root 在 _initialize() 阶段还没建立，UI 必须等第一帧。
	_pending_start = true


func _start() -> void:
	_net = root.get_node_or_null(^"Net")
	_check(_net != null, "应当能拿到 autoload 的 Net 节点")
	if _net == null:
		_finish()
		return
	_lobby = LobbyScript.new()
	_lobby.name = "LobbyUI"
	root.add_child(_lobby)
	_say("[lobby] 大厅已实例化（第 %d 帧）" % _frames)
	_advance(Stage.HOST)


func _tick() -> void:
	match _stage:
		Stage.HOST:
			_tick_host()
		Stage.LEAVE:
			_tick_leave()
		Stage.JOIN_FAIL:
			_tick_join_fail()
		Stage.DONE:
			pass


# --- 构建检查 -----------------------------------------------------------------

func _verify_built() -> void:
	var panel := _lobby.get("_panel") as Panel
	var option := _lobby.get("_backend_option") as OptionButton
	var list := _lobby.get("_player_list") as VBoxContainer
	var status := _lobby.get("_status_label") as Label
	_check(panel != null, "大厅应当构建出主面板")
	_check(option != null, "大厅应当构建出后端下拉框")
	_check(list != null, "大厅应当构建出房间成员列表")
	_check(status != null, "大厅应当构建出状态栏")
	_check(_lobby.get_child_count() >= 2, "大厅应当包含遮罩与面板")

	if option == null:
		return
	_check(option.item_count == TransportFactory.all_backends().size(),
		"后端下拉应当列出全部后端，实际 %d 项" % option.item_count)
	var texts: Array[String] = []
	for i in option.item_count:
		texts.append(option.get_item_text(i))
	var joined := " | ".join(texts)
	_say("[lobby] 后端选项：" + joined)
	_check(joined.contains("ENet"), "后端列表里应当有 ENet")
	_check(joined.contains("Steam"), "后端列表里应当有 Steam P2P")
	# 当前环境没有 GodotSteam，Steam 项必须被标注为不可用而不是假装可选。
	if not TransportFactory.is_available(TransportFactory.Backend.STEAM):
		_check(joined.contains("不可用"), "Steam 不可用时应在下拉里标注出来")

	# 后端选择器应当返回真实的后端枚举值。
	option.selected = 0
	_check(_lobby.selected_backend() == TransportFactory.all_backends()[0],
		"选中的后端应当与下拉项对应")


# --- 开房 / 断开 ---------------------------------------------------------------

func _tick_host() -> void:
	if not _host_clicked:
		# 先只验证构建，再点开房。
		_verify_built()
		var port_edit := _lobby.get("_port_edit") as LineEdit
		if port_edit != null:
			port_edit.text = str(PORT)
		_lobby.host_game()
		_host_clicked = true
		_stage_mark = _frames
		return
	if _frames - _stage_mark < 3:
		return

	var status := _lobby.get("_status_label") as Label
	_check(bool(_net.call("is_host")), "点击开房后 Net 应当进入房主状态")
	_check(bool(_net.call("is_online")), "点击开房后 Net 应当处于联机状态")
	_check(int(_net.call("get_peer_count")) == 1, "开房后成员列表应只有房主自己")
	var list := _lobby.get("_player_list") as VBoxContainer
	_check(list != null and list.get_child_count() == 1,
		"界面上应当只有 1 条成员，实际 " + str(0 if list == null else list.get_child_count()))
	_check(status != null and not status.text.is_empty(), "开房后状态栏应当有提示文字")
	if status != null:
		_say("[lobby] 开房状态：" + status.text)

	var host_button := _lobby.get("_host_button") as Button
	var leave_button := _lobby.get("_leave_button") as Button
	_check(host_button != null and host_button.disabled, "开房后「开房」按钮应当禁用")
	_check(leave_button != null and not leave_button.disabled, "开房后「断开」按钮应当可用")

	_lobby.leave_session()
	_advance(Stage.LEAVE)


func _tick_leave() -> void:
	if _frames - _stage_mark < 2:
		return
	_check(not bool(_net.call("is_online")), "断开后 Net 应当回到未联机状态")
	_check(int(_net.call("get_peer_count")) == 0, "断开后成员列表应当清空")
	var list := _lobby.get("_player_list") as VBoxContainer
	_check(list != null and list.get_child_count() == 0,
		"断开后界面上不应当再有成员")
	var leave_button := _lobby.get("_leave_button") as Button
	var host_button := _lobby.get("_host_button") as Button
	_check(leave_button != null and leave_button.disabled, "断开后「断开」按钮应当禁用")
	_check(host_button != null and not host_button.disabled, "断开后「开房」按钮应当恢复")

	# 连一个没人监听的端口，验证失败路径有反馈。
	var port_edit := _lobby.get("_port_edit") as LineEdit
	var address_edit := _lobby.get("_address_edit") as LineEdit
	if port_edit != null:
		port_edit.text = str(DEAD_PORT)
	if address_edit != null:
		address_edit.text = "127.0.0.1"
	_lobby.join_game()
	_advance(Stage.JOIN_FAIL)


func _tick_join_fail() -> void:
	# ENet 握手超时是 5 秒，多给一点余量。
	if _frames - _stage_mark < 400:
		return
	var status := _lobby.get("_status_label") as Label
	var text := "" if status == null else status.text
	_say("[lobby] 连接失败后的状态：" + text)
	_check(not bool(_net.call("is_online")), "连接失败后应当回到未联机状态")
	_check(text.contains("失败") or text.contains("超时"),
		"连接失败后状态栏应当给出可读的原因，实际：" + text)

	# 再开一次房，确认失败之后还能正常使用。
	_lobby.host_game()
	_check(bool(_net.call("is_host")), "失败之后仍然可以正常开房")
	_lobby.leave_session()
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
	if _net != null and bool(_net.call("is_online")):
		_net.call("stop")
	if _failures.is_empty():
		_say("[lobby] %d 项检查全部通过" % _checks)
		_say("RESULT: PASS")
	else:
		_say("[lobby] %d 项检查，%d 项失败" % [_checks, _failures.size()])
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
