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


## 两列必须真的装得进内容区。
##
## 这条断言是补上一个真实踩到的盲区：左列的 _backend_hint 和右列的 _status_label
## 各自带着 custom_minimum_size.x = LOBBY_WIDTH - 16 = 364px（单列时代的残留），
## 而两列容器只有 360px 可用。HBoxContainer 不会压缩子节点的最小宽度，于是右列
## 从 x=364 开始、整体被推到面板外面 —— 状态栏只剩几个像素露在边缘。
##
## 而当时「面板在屏幕内」和「返回按钮在屏幕内」两条断言**全部通过**：面板和返回
## 按钮确实好好地在屏幕上，坏掉的只是面板内部的列。所以必须单独量列。
func _verify_columns_fit() -> void:
	var panel := _lobby.get("_panel") as Panel
	if panel == null:
		return
	var columns := panel.get_node_or_null("Body") as HBoxContainer
	if columns == null:
		_check(false, "面板里应当有名为 Body 的两列容器")
		return

	var box := Rect2(columns.global_position, columns.size)
	_say("[lobby] 内容区 %s" % str(box))
	_check(box.size.x > 0.0 and box.size.y > 0.0, "内容区必须有非零尺寸，实际 " + str(box.size))

	for child in columns.get_children():
		var column := child as Control
		if column == null:
			continue
		var rect := Rect2(column.global_position, column.size)
		_say("[lobby] 列「%s」 %s  最小宽度 %.1f" % [
			column.name, str(rect), column.get_combined_minimum_size().x])
		_check(rect.end.x <= box.end.x + 0.5,
			"列「%s」不应当超出内容区右边缘（超出的部分会被面板切掉）。列 %s，内容区 %s" % [
				column.name, str(rect), str(box)])
		_check(column.size.x > 0.0, "列「%s」必须有非零宽度，实际 %s" % [column.name, str(column.size)])

		# 把左列每一行的最小高度打出来。
		# 这块 410x230 的画布上纵向预算只有 200px 左右，行高必须心里有数；
		# 之前两次返工都是因为「我以为某一行是 N 像素」。
		if column.name == "Left":
			var total := 0.0
			for row in column.get_children():
				var row_control := row as Control
				if row_control == null:
					continue
				var row_height := row_control.get_combined_minimum_size().y
				total += row_height
				var row_label := str(row_control.name)
				if row_label.is_empty():
					row_label = row_control.get_class()
				_say("[lobby]   左列行 %-14s 最小高 %.1f" % [row_label, row_height])
			_say("[lobby]   左列行高合计 %.1f（内容区实际高度 %.1f）" % [total, box.size.y])


## 状态栏必须真的看得见。
##
## 它是这块画布上最重要的文字：房主的 IP / 64 位 SteamID 都写在这里，要靠它念给
## 队友。曾经它被推到面板外面，玩家完全看不到，界面却没有任何报错。
func _verify_status_visible() -> void:
	var panel := _lobby.get("_panel") as Panel
	var status := _lobby.get("_status_label") as Label
	if panel == null or status == null:
		_check(false, "应当有面板和状态栏")
		return

	var status_rect := Rect2(status.global_position, status.size)
	var panel_rect := Rect2(panel.global_position, panel.size)
	var screen := Rect2(Vector2.ZERO, _lobby.get_viewport_rect().size)
	_say("[lobby] 状态栏 %s  面板 %s" % [str(status_rect), str(panel_rect)])

	_check(status.size.x > 0.0 and status.size.y > 0.0,
		"状态栏必须有非零尺寸，实际 " + str(status.size))
	_check(panel_rect.encloses(status_rect),
		"状态栏必须完整落在面板内。状态栏 %s，面板 %s" % [str(status_rect), str(panel_rect)])
	_check(screen.encloses(status_rect),
		"状态栏必须完整落在屏幕内。状态栏 %s，屏幕 %s" % [str(status_rect), str(screen)])

	# 只判「在屏幕内」还不够：宽度小到只剩十几个像素时它照样在屏幕内，
	# 但一个字都读不出来。状态栏现在横跨整幅面板，宽度应当接近面板内宽。
	var expected_width := panel_rect.size.x - 12.0
	_check(status.size.x >= expected_width - 1.0,
		"状态栏应当横跨整幅面板（约 %.0f px），实际 %.1f" % [expected_width, status.size.x])
	# 它必须位于两列内容区**下方**，不能和列重叠。
	var columns := panel.get_node_or_null("Body") as HBoxContainer
	if columns != null:
		_check(status.global_position.y >= columns.global_position.y + columns.size.y - 1.0,
			"状态栏应当在两列内容区下方。状态栏 y=%.1f，内容区底部 y=%.1f" % [
				status.global_position.y, columns.global_position.y + columns.size.y])


## 地址输入框必须真的放得下房主要报的东西。
##
## 这条是补上一个纯功能性的盲区：布局「没错」，但输入框只有 36px 宽 ——
## 17 位 SteamID（约 80px）在里面只能看到四五个字符，房主没法核对、加入方没法
## 输入。这类问题不会让任何断言变红，只会让人用不了。
func _verify_address_field_usable() -> void:
	var address := _lobby.get("_address_edit") as LineEdit
	if address == null:
		_check(false, "应当有地址输入框")
		return

	var width := address.size.x
	_say("[lobby] 地址输入框宽度 %.1f" % width)
	# 17 位 SteamID 在 font 8 下约 80px；再留一点光标余量。
	_check(width >= 90.0,
		"地址输入框应当放得下 17 位 SteamID（至少 90px），实际 %.1f" % width)
	_check(address.is_visible_in_tree(), "地址输入框应当在可见树上")


## Steam 后端下端口输入框应当隐藏。
##
## Steam P2P 的 virtual port 是两端约定的固定值，不由玩家填。留着一个没用的
## 输入框既让人困惑，又白占 58px —— 那 58px 正是地址输入框需要的。
func _verify_port_field_per_backend() -> void:
	var port_edit := _lobby.get("_port_edit") as LineEdit
	var address := _lobby.get("_address_edit") as LineEdit
	if port_edit == null or address == null:
		_check(false, "应当有端口和地址输入框")
		return

	var option := _lobby.get("_backend_option") as OptionButton
	if option == null:
		return

	# 切到 Steam：端口应当隐藏，地址输入框应当变宽。
	var steam_index := -1
	for i in option.item_count:
		if option.get_item_text(i).begins_with("Steam"):
			steam_index = i
	if steam_index < 0:
		_say("[lobby] 下拉框里没有 Steam 项，跳过端口显隐检查")
		return

	option.selected = steam_index
	_lobby.call("_on_backend_selected", steam_index)
	var steam_width := address.size.x
	_check(not port_edit.visible, "选中 Steam P2P 时端口输入框应当隐藏")
	_say("[lobby] Steam 模式下地址输入框宽度 %.1f" % steam_width)
	_check(steam_width >= 90.0,
		"Steam 模式下地址输入框应当能放下 SteamID。实际 %.1f" % steam_width)

	# 切回 ENet：端口应当回来。
	option.selected = 0
	_lobby.call("_on_backend_selected", 0)
	_check(port_edit.visible, "选中 ENet 时端口输入框应当恢复显示")


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

	# 几何检查必须放在这里，不能放到 _verify_built()。
	#
	# Container 的尺寸是在 NOTIFICATION_SORT_CHILDREN 里算的，构建当帧还没排过版，
	# 子节点量出来全是 0x0 —— 那样断言会以「尺寸为 0」的形式误报，而不是报出真正
	# 的问题。等几帧之后再量才是真实布局。
	_verify_columns_fit()
	_verify_status_visible()
	_verify_address_field_usable()
	_verify_port_field_per_backend()

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
