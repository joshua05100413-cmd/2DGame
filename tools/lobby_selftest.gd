extends SceneTree

## 报告写到项目内的固定位置：Windows / Linux / CI 路径完全一致，脚本不必去猜
## Godot 的 user:// 落在哪（Windows 是 %APPDATA%，Linux 是 $XDG_DATA_HOME）。
const REPORT_DIR := "res://_userdata/reports"
const REPORT_PATH := REPORT_DIR + "/lobby_selftest.log"
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
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	_log = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
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

	_verify_layout()
	_verify_address_hint()


## 房主该报哪个地址给队友。
##
## 这组是纯函数断言，不依赖真实网卡：只要「哪些地址能用」的判断错了，房主就会
## 报一个对方连不上的 IP，而症状只是「一直连不上」，很难反查到是这里的问题。
func _verify_address_hint() -> void:
	# 回环和链路本地必须排除：127.0.0.1 只有同机双开能用，169.254 是没拿到
	# DHCP 时的自分配地址，任何机器都连不上。
	_check(not NetManager.is_lan_address("127.0.0.1"), "回环地址不应当作为可连接地址")
	_check(not NetManager.is_lan_address("169.254.10.20"), "链路本地地址不应当作为可连接地址")
	_check(not NetManager.is_lan_address("::1"), "IPv6 不应当出现在 IPv4 候选里")
	_check(not NetManager.is_lan_address(""), "空串不应当作为可连接地址")
	_check(not NetManager.is_lan_address("192.168.1"), "段数不足的地址应当被拒绝")
	_check(not NetManager.is_lan_address("192.168.1.999"), "超出 255 的地址应当被拒绝")
	_check(NetManager.is_lan_address("192.168.1.7"), "正常内网地址应当被接受")

	_check(NetManager.is_private_address("10.0.0.5"), "10/8 应当算私有网段")
	_check(NetManager.is_private_address("172.16.3.9"), "172.16/12 下界应当算私有网段")
	_check(NetManager.is_private_address("172.31.255.1"), "172.16/12 上界应当算私有网段")
	_check(not NetManager.is_private_address("172.32.0.1"), "172.32 已经出了 172.16/12")
	_check(not NetManager.is_private_address("8.8.8.8"), "公网地址不算私有网段")

	# 候选表里绝不能出现回环地址，否则房主可能照着念 127.0.0.1。
	var candidates: Array = NetManager.local_address_candidates()
	var has_loopback := false
	for address in candidates:
		if str(address).begins_with("127."):
			has_loopback = true
	_check(not has_loopback, "候选地址里不应当出现回环地址，实际 " + str(candidates))
	_say("[lobby] 本机候选地址：" + str(candidates) + " 提示语：" + NetManager.local_address_hint())


## 布局/可见性断言。
##
## 这些是补上的盲区：之前只断言「节点存在」，于是 set_anchors_preset 用错
## （不设 offsets、控件尺寸为 0）时 26 项全绿，进游戏却什么都看不到；
## 「返回」按钮被内容顶到屏幕外也一样测不出来。
func _verify_layout() -> void:
	var viewport_size := _lobby.get_viewport_rect().size
	_say("[lobby] viewport 逻辑尺寸：" + str(viewport_size))

	# 根节点必须真的有尺寸，否则整个大厅是隐形的。
	_check(_lobby.size.x > 0.0 and _lobby.size.y > 0.0,
		"大厅根节点必须有非零尺寸，实际 " + str(_lobby.size))
	_check(_lobby.size.is_equal_approx(viewport_size),
		"大厅根节点应当铺满 viewport，实际 " + str(_lobby.size))

	var dim := _lobby.get_node_or_null("Dim") as ColorRect
	_check(dim != null, "应当有遮罩层")
	if dim != null:
		_check(dim.size.x > 0.0 and dim.size.y > 0.0,
			"遮罩必须有非零尺寸，实际 " + str(dim.size))

	var panel := _lobby.get("_panel") as Panel
	_check(panel != null and panel.size.x > 0.0 and panel.size.y > 0.0,
		"面板必须有非零尺寸，实际 " + str(null if panel == null else panel.size))
	if panel == null:
		return

	# 面板必须整个落在屏幕里，否则底部按钮会被切掉。
	var panel_rect := Rect2(panel.global_position, panel.size)
	var screen := Rect2(Vector2.ZERO, viewport_size)
	_check(screen.encloses(panel_rect),
		"面板应当完整位于屏幕内。面板 %s，屏幕 %s" % [str(panel_rect), str(screen)])

	# 「返回」按钮曾经被内容顶到屏幕外，导致大厅关不掉。
	var close_button: Button = null
	for child in panel.get_children():
		if child is Button and (child as Button).text == "返回":
			close_button = child
			break
	_check(close_button != null, "面板上应当有「返回」按钮")
	if close_button != null:
		var rect := Rect2(close_button.global_position, close_button.size)
		_say("[lobby] 「返回」按钮 rect：" + str(rect))
		_check(rect.size.x > 0.0 and rect.size.y > 0.0,
			"「返回」按钮必须有非零尺寸，实际 " + str(rect.size))
		_check(screen.encloses(rect),
			"「返回」按钮必须完整位于屏幕内（否则大厅关不掉）。按钮 %s，屏幕 %s" % [
				str(rect), str(screen)])
		# 再确认它真的能收到点击：面板中心和按钮中心都要落在可见区域内。
		_check(close_button.is_visible_in_tree(), "「返回」按钮应当在可见树上")


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

	# 开房状态栏比默认提示长得多（要写出本机地址），而面板里塞不下就会被顶到
	# 屏幕外——「返回」按钮被挤出屏幕正是之前踩过的坑。所以这里必须在**真实
	# 开了房、状态栏换成最长文案之后**重新量一遍，而不是只看构建时那一次。
	var panel := _lobby.get("_panel") as Panel
	if panel != null:
		var panel_rect := Rect2(panel.global_position, panel.size)
		var screen := Rect2(Vector2.ZERO, _lobby.get_viewport_rect().size)
		_check(screen.encloses(panel_rect),
			"开房后（状态栏变长）面板仍应完整位于屏幕内。面板 %s，屏幕 %s" % [str(panel_rect), str(screen)])

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
