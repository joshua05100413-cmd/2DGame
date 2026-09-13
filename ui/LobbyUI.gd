extends Control
## 联机大厅界面。
##
## 为什么用代码搭 UI
##   主菜单 ui/ControlUI.tscn 有 600+ 行，手改它的节点树风险高、审查也困难。
##   大厅是独立的一块，代码构建既避免了碰主菜单，也让它能被无头测试直接
##   实例化出来点一遍。
##
## 它只跟 NetworkManager（autoload `Net`）打交道，永远不直接碰 ENet 或
## Steam —— 换后端不需要改这里任何一行，只改下拉框的选项。

## 面板尺寸。
##
## 注意 viewport 的**逻辑**尺寸只有 410x230（见 project.godot 的
## window/size/viewport_*，配合 canvas_items 拉伸），不是窗口的像素尺寸。
## 按桌面分辨率想当然的话，内容会把底部的「返回」按钮顶到屏幕外面去。
const LOBBY_WIDTH := 380.0
const LOBBY_HEIGHT := 212.0
## 面板内边距。
const PANEL_MARGIN := 6.0
## 底部「返回」按钮占用的一条，独立于内容流，永远不会被内容挤走。
##
## 26 是紧凑按钮**实测**的最小高度，不是估的 —— 曾经这里写 20，而按钮实际要 26，
## 于是「返回」比面板底部多伸出 3px、正好顶到屏幕边缘。凡是和控件真实尺寸有关的
## 数字，都先量再说。
const FOOTER_HEIGHT := 26.0
## 状态栏占用的一条，横跨整幅面板，同样独立于内容流。
##
## 为什么让状态栏独占一整行，而不是塞进右列：
## 它是这块 410x230 画布上最需要**读清楚**的文字 —— 房主的 IP、64 位 SteamID
## 都写在这里，玩家要照着它念给队友。放进两列之一的话，宽度只剩 110 上下：
## SteamID 会被折成两行，而本字体一行就是 21px，两行 42px 会直接吃掉右列。
## 独占一行同时也解开了「状态栏宽度」和「两列怎么分」之间的耦合 ——
## 之前那个把右列整个挤出面板的 bug，就是这个耦合造成的。
const STATUS_HEIGHT := 22.0
## 内容区与底部两条之间的间距。
const ROW_GAP := 4.0
## 右列（房间成员）的固定宽度。左列拿剩下的全部宽度给输入框。
const RIGHT_COLUMN_WIDTH := 120.0
## 左列里「传输后端 / 昵称 / 地址」这些标签的固定宽度。
## 84 太宽了 —— 挤掉的全是输入框的宽度，而输入框里要放得下 17 位 SteamID。
const FIELD_LABEL_WIDTH := 56.0

var _panel: Panel = null
var _backend_option: OptionButton = null
var _backend_hint: Label = null
var _name_edit: LineEdit = null
var _address_edit: LineEdit = null
var _port_edit: LineEdit = null
var _host_button: Button = null
var _join_button: Button = null
var _leave_button: Button = null
var _status_label: Label = null
var _player_list: VBoxContainer = null
var _player_title: Label = null

## 后端下拉框中 index -> [enum TransportFactory.Backend] 的映射。
var _backend_ids: Array[int] = []


func _ready() -> void:
	# 必须用 set_anchors_and_offsets_preset，不是 set_anchors_preset。
	# 后者只改 anchors，并把 offsets 重新算成「保持当前 rect 不变」——
	# 而新建的 Control 是 0x0，于是整个大厅宽高都是 0，点「联机」什么都不出现。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 盖住同一 CanvasLayer 里的准星和 toast。
	z_index = 10
	# 自己带一份精简主题，见 _build_compact_theme() 的说明。
	theme = _build_compact_theme()
	_build()

	var net: Variant = _net()
	if net != null:
		net.players_changed.connect(_refresh_players)
		net.state_changed.connect(_refresh_status)
		net.connection_failed.connect(_on_connection_failed)
		net.server_disconnected.connect(_on_server_disconnected)

	_refresh_backends()
	_refresh_status()
	_refresh_players()


func _exit_tree() -> void:
	var net: Variant = _net()
	if net == null:
		return
	if net.players_changed.is_connected(_refresh_players):
		net.players_changed.disconnect(_refresh_players)
	if net.state_changed.is_connected(_refresh_status):
		net.state_changed.disconnect(_refresh_status)
	if net.connection_failed.is_connected(_on_connection_failed):
		net.connection_failed.disconnect(_on_connection_failed)
	if net.server_disconnected.is_connected(_on_server_disconnected):
		net.server_disconnected.disconnect(_on_server_disconnected)


## 打开大厅（显示并刷新一次）。
func open() -> void:
	visible = true
	_refresh_backends()
	_refresh_status()
	_refresh_players()


func close() -> void:
	visible = false


# --- 网络交互 -----------------------------------------------------------------

## 当前选中的后端。
func selected_backend() -> int:
	var index := _backend_option.selected
	if index < 0 or index >= _backend_ids.size():
		return TransportFactory.Backend.ENET
	return _backend_ids[index]


func host_game() -> void:
	var net: Variant = _net()
	if net == null:
		return
	net.set_backend(selected_backend())
	net.set_local_player_name(_name_edit.text)
	_set_status("正在开房……", Color(0.9, 0.9, 0.6))
	var err: int = net.host_game(_read_port())
	if err == OK:
		_set_status(_hosting_status(_read_port()), Color(0.6, 1.0, 0.7))
	_refresh_players()


## 开房成功后状态栏该写什么。
##
## 必须把「队友要填什么」写出来：两种后端都是直连，客户端要填房主的寻址信息，
## 而房主自己看不到自己该报什么。以前这里只写端口，跨机器测试时房主只能靠猜
## 或者另外去查 ipconfig。Steam 后端更麻烦 —— 要报的是一串 64 位数字，
## 光靠玩家自己是找不到的。
##
## ENet 的两种连法分开写：同一台电脑双开填 127.0.0.1，别的电脑必须填内网地址。
## 不写清楚的话，房主很可能把 127.0.0.1 报给不在本机的人，对方会一直连到超时。
##
## 这段话很短是故意的：大厅状态栏的字体只有 7px，viewport 逻辑宽度只有 410px，
## 多写两行就会把下面的成员列表和按钮挤出屏幕。
func _hosting_status(port: int) -> String:
	if selected_backend() == TransportFactory.Backend.STEAM:
		return _steam_hosting_status()
	var address := NetManager.local_address_hint()
	if address.is_empty():
		return "已开房 %d ｜ 无网卡地址，仅可本机双开" % port
	var text := "已开房 %s:%d ｜ 本机双开填 127.0.0.1" % [address, port]
	# 这台机器有几块网卡时，最优地址不一定就是能连通的那块，所以要房主知道还有备选。
	var extra := NetManager.extra_address_count()
	if extra > 0:
		text += "（另有 %d 个网卡地址）" % extra
	return text


## Steam 开房后要报给队友的是房主的 64 位 SteamID。
##
## 这是 Steam 路径上最容易卡住的一步：SteamID 是一串 17 位数字，玩家在 Steam
## 界面上根本看不到完整值（个人资料页只显示好友代码或自定义 URL）。不主动报出来，
## 加入方就只能去翻 Steam 的配置文件。
func _steam_hosting_status() -> String:
	var steam_id := SteamTransport.local_steam_id()
	if steam_id == 0:
		return "已开房（Steam）｜ 拿不到 SteamID，请确认 Steam 已登录"
	return "已开房 SteamID %d ｜ 把它发给队友，队友填进地址栏" % steam_id


func join_game() -> void:
	var net: Variant = _net()
	if net == null:
		return
	net.set_backend(selected_backend())
	net.set_local_player_name(_name_edit.text)
	var address := _address_edit.text.strip_edges()
	if address.is_empty():
		_set_status("请先填写房主地址或 SteamID。", Color(1.0, 0.6, 0.6))
		return
	_set_status("正在连接 %s……" % address, Color(0.9, 0.9, 0.6))
	var err: int = net.join_game(address, _read_port())
	if err == OK:
		_set_status("已发起连接，等待房主响应……", Color(0.9, 0.9, 0.6))


func leave_session() -> void:
	var net: Variant = _net()
	if net == null:
		return
	net.stop()
	_set_status("已断开。", Color(0.8, 0.8, 0.8))
	_refresh_players()


# --- 界面刷新 -----------------------------------------------------------------

func _on_backend_selected(index: int) -> void:
	_refresh_backend_hint(index)
	# Steam 走 64 位 SteamID，ENet 走 IP，提示语不同。
	var backend := selected_backend()
	_address_edit.placeholder_text = _address_placeholder(backend)
	# Steam P2P 没有端口概念（virtual port 是两端约定的固定值，不由玩家填）。
	# 藏掉它有两个好处：不再让玩家以为要填端口；容器下一帧重排时，让出的宽度
	# 会回到地址输入框 —— 17 位 SteamID 要 80px 上下才看得全。
	_port_edit.visible = backend != TransportFactory.Backend.STEAM
	_prepare_selected_backend(backend)


## 选中 Steam 时才初始化 SteamAPI，并把玩家名换成 Steam 昵称。
##
## 刻意不放在游戏启动时：单机玩家不该因为打开一次大厅就把 Steam 拉起来、
## 让 Steam 显示「正在玩 Spacewar」。放在这里也保证了「先启动 Steam，再选
## Steam P2P」这个最自然的操作顺序能直接成功。
func _prepare_selected_backend(backend: int) -> void:
	if backend != TransportFactory.Backend.STEAM:
		return
	var net: Variant = _net()
	if net == null:
		return
	var reason: String = net.prepare_steam_backend()
	if reason.is_empty():
		_say_steam_ready()
	else:
		_set_status(reason, Color(1.0, 0.75, 0.5))


## 准备好了就把 Steam 昵称同步到名字输入框，让玩家看到自己会以什么名字进房间。
func _say_steam_ready() -> void:
	var persona := SteamTransport.steam_persona_name()
	if not persona.is_empty():
		_name_edit.text = persona
	_set_status("Steam 已就绪，可以开房或填房主 SteamID 加入。", Color(0.6, 1.0, 0.7))


func _on_connection_failed(reason: String) -> void:
	_set_status("连接失败：" + reason, Color(1.0, 0.55, 0.55))


func _on_server_disconnected() -> void:
	_set_status("与房主的连接已断开。", Color(1.0, 0.7, 0.5))
	_refresh_players()


func _refresh_backends() -> void:
	if _backend_option == null:
		return
	var previous := selected_backend()
	_backend_option.clear()
	_backend_ids.clear()
	for backend in TransportFactory.all_backends():
		var id: int = backend
		var label: String = TransportFactory.backend_name(id)
		if not TransportFactory.is_available(id):
			# 不可用的后端仍然列出，但标注清楚原因，让玩家知道为什么选不了。
			label += "（不可用）"
		_backend_option.add_item(label)
		_backend_ids.append(id)
	# 尽量保持之前的选择。
	var restored := 0
	for i in _backend_ids.size():
		if _backend_ids[i] == previous:
			restored = i
			break
	_backend_option.selected = restored
	_refresh_backend_hint(restored)


func _refresh_backend_hint(index: int) -> void:
	if _backend_hint == null:
		return
	if index < 0 or index >= _backend_ids.size():
		_backend_hint.text = ""
		return
	var reason := TransportFactory.unavailable_reason(_backend_ids[index])
	_backend_hint.text = reason if not reason.is_empty() else "该后端可用。"
	_backend_hint.modulate = Color(1.0, 0.7, 0.7) if not reason.is_empty() else Color(0.7, 0.9, 0.75)


func _refresh_status() -> void:
	var net: Variant = _net()
	if net == null:
		return
	if not bool(net.is_online()):
		_host_button.disabled = false
		_join_button.disabled = false
		_leave_button.disabled = true
		return
	_host_button.disabled = true
	_join_button.disabled = true
	_leave_button.disabled = false
	if _status_label.text.is_empty():
		_set_status(str(net.describe()), Color(0.8, 0.9, 1.0))


func _refresh_players() -> void:
	if _player_list == null:
		return
	for child in _player_list.get_children():
		# 立刻摘下来再 queue_free：否则本帧内 get_child_count() 还包含待释放
		# 节点，界面上也会短暂出现重影。
		_player_list.remove_child(child)
		child.queue_free()
	var net: Variant = _net()
	if net == null:
		return
	var entries: Array = net.get_player_list()
	_player_title.text = "房间成员（%d）" % entries.size()
	for raw in entries:
		var entry: Dictionary = raw
		var label := Label.new()
		var prefix := "★ " if bool(entry.get("is_host", false)) else "· "
		var suffix := "（我）" if bool(entry.get("is_local", false)) else ""
		var ready := " ✔" if bool(entry.get("ready", false)) else ""
		label.text = "%s%s%s%s" % [prefix, str(entry.get("name", "Player")), suffix, ready]
		label.add_theme_font_size_override("font_size", 8)
		_player_list.add_child(label)


func _set_status(text: String, color: Color) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_label.modulate = color


func _net() -> Variant:
	# 不按标识符直接引用 autoload，理由见 CoopSession._net()。
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(^"Net")


func _read_port() -> int:
	var value := int(_port_edit.text.strip_edges())
	return value if value > 0 and value < 65536 else NetManager.DEFAULT_PORT


func _address_placeholder(backend: int) -> String:
	if backend == TransportFactory.Backend.STEAM:
		return "房主的 64 位 SteamID"
	return "127.0.0.1"


# --- 界面搭建 -----------------------------------------------------------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.72)
	# 同上：只设 anchors 会留下 0x0 的遮罩。
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_panel = Panel.new()
	_panel.name = "Panel"
	_panel.size = Vector2(LOBBY_WIDTH, LOBBY_HEIGHT)
	_panel.custom_minimum_size = Vector2(LOBBY_WIDTH, LOBBY_HEIGHT)
	# 用 TOP_LEFT anchors + 自己算居中位置，**不要**用 PRESET_CENTER。
	#
	# PRESET_CENTER 会把 anchors 设成 0.5，而 Control.position 在那种情况下是
	# 「相对锚点的偏移」—— 它的真实屏幕位置还取决于父节点当时的尺寸。_build() 在
	# _ready() 里跑，那时父节点尺寸还没定，结果面板被放到 global_position
	# (-190,-112)，整个跑到屏幕左上角外面去。用 TOP_LEFT 之后 position 就是
	# 屏幕坐标本身，与父节点尺寸无关，可预测。
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = _centered_panel_position(_panel.size)
	add_child(_panel)

	# 这个 viewport 只有 410x230。单列堆十个控件实测需要 240px 而可用只有 180px，
	# 底部的按钮必然被顶出屏幕，所以改成左右两列。
	#
	# 纵向预算：面板高 212，减上下内边距各 6 → 200。
	# 底部两条固定高度，两列拿剩下的；不够高的话最后由 _fit_panel_to_content()
	# 按内容真实需要的高度加高，所以这里的数字只是设计基准，不必精确。
	var footer_top := LOBBY_HEIGHT - FOOTER_HEIGHT - PANEL_MARGIN * 0.5
	var status_top := footer_top - STATUS_HEIGHT
	var body_height := status_top - PANEL_MARGIN
	var columns := HBoxContainer.new()
	columns.name = "Body"
	columns.position = Vector2(PANEL_MARGIN, PANEL_MARGIN)
	columns.size = Vector2(LOBBY_WIDTH - PANEL_MARGIN * 2.0, body_height)
	columns.add_theme_constant_override("separation", 8)
	_panel.add_child(columns)

	# 左列：连接参数与操作。它装着所有输入框，需要宽度 —— 让它吃掉剩余空间。
	#
	# 两列**都**标 SIZE_EXPAND_FILL 试过，实测额外宽度全被右列拿走了（左列停在
	# 自己的最小宽度 184，地址输入框只剩 36px，连 17 位 SteamID 都显示不下）。
	# 与其去猜容器的分配规则，不如明确指定：右列内容短（成员名），给固定宽度。
	var root_box := VBoxContainer.new()
	root_box.name = "Left"
	root_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.add_theme_constant_override("separation", 2)
	columns.add_child(root_box)

	# 右列：房间成员。宽度固定，够放「房间成员（N）」和名字即可。
	var right_box := VBoxContainer.new()
	right_box.name = "Right"
	right_box.size_flags_horizontal = Control.SIZE_FILL
	right_box.custom_minimum_size = Vector2(RIGHT_COLUMN_WIDTH, 0)
	right_box.add_theme_constant_override("separation", 2)
	columns.add_child(right_box)

	# 这里原本有一个 font_size = 10 的「联机合作生存」标题，占 30px 高。
	#
	# 删掉它是有意的：项目这套字体在 410x230 的逻辑画布上，一个 Label 的最小高度
	# 实测是字号的 **3 倍**（font 7 → 21px，font 10 → 30px），所以一个纯装饰的标题
	# 就要吃掉 13% 的纵向预算，而面板总高只有 230。省下来的 30px 让面板从
	# 「上下各剩 3px、按钮贴着屏幕边缘」回到正常留白。
	#
	# 面板的用途并不需要标题：玩家刚点了主菜单的「联机」，里面是传输后端 / 昵称 /
	# 地址 / 开房 / 加入 / 断开 / 返回，不可能认错；状态栏也在持续说明下一步做什么。

	# 后端选择
	var backend_row := HBoxContainer.new()
	backend_row.add_theme_constant_override("separation", 6)
	root_box.add_child(backend_row)
	backend_row.add_child(_make_label("传输后端", FIELD_LABEL_WIDTH))
	_backend_option = OptionButton.new()
	_backend_option.add_theme_font_size_override("font_size", 8)
	_backend_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backend_option.item_selected.connect(_on_backend_selected)
	backend_row.add_child(_backend_option)

	_backend_hint = Label.new()
	_backend_hint.add_theme_font_size_override("font_size", 7)
	_backend_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 只卡高度，宽度交给容器。
	# 这里曾经写的是 Vector2(LOBBY_WIDTH - 16, 20)，那是单列时代的残留：
	# 当时这一行独占整幅面板，写死 364px 是对的；改成两列之后它变成了左列的
	# **最小宽度**，而右列的状态栏也写着同样的 364px —— 两列合计 728px 要塞进
	# 360px 的容器，右列整体被推出面板，状态栏只剩几个像素露在外面。
	_backend_hint.custom_minimum_size = Vector2(0, 20)
	root_box.add_child(_backend_hint)

	# 昵称
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	root_box.add_child(name_row)
	name_row.add_child(_make_label("昵称", FIELD_LABEL_WIDTH))
	_name_edit = LineEdit.new()
	_name_edit.text = _default_name()
	_name_edit.max_length = NetManager.MAX_NAME_LENGTH
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.add_theme_font_size_override("font_size", 8)
	name_row.add_child(_name_edit)

	# 地址与端口
	var addr_row := HBoxContainer.new()
	addr_row.add_theme_constant_override("separation", 6)
	root_box.add_child(addr_row)
	addr_row.add_child(_make_label("地址", FIELD_LABEL_WIDTH))
	_address_edit = LineEdit.new()
	_address_edit.text = "127.0.0.1"
	_address_edit.placeholder_text = "127.0.0.1"
	_address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address_edit.add_theme_font_size_override("font_size", 8)
	addr_row.add_child(_address_edit)
	_port_edit = LineEdit.new()
	_port_edit.text = str(NetManager.DEFAULT_PORT)
	_port_edit.custom_minimum_size = Vector2(52, 0)
	_port_edit.add_theme_font_size_override("font_size", 8)
	addr_row.add_child(_port_edit)

	# 操作按钮
	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 6)
	root_box.add_child(button_row)
	_host_button = _make_button("开房", _on_host_pressed)
	_join_button = _make_button("加入", _on_join_pressed)
	_leave_button = _make_button("断开", _on_leave_pressed)
	button_row.add_child(_host_button)
	button_row.add_child(_join_button)
	button_row.add_child(_leave_button)

	# 状态栏：横跨整幅面板的独立一行，不参与上面的两列布局。
	#
	# 同样注意 position/size 必须在 add_child **之后**设置 —— 入树时 Godot 会按
	# anchors/offsets 重算控件矩形，先设的值会被扔掉。
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 7)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_status_label.text = ""
	_panel.add_child(_status_label)
	_status_label.position = Vector2(PANEL_MARGIN, status_top)
	_status_label.size = Vector2(LOBBY_WIDTH - PANEL_MARGIN * 2.0, STATUS_HEIGHT)

	# 房间成员
	_player_title = Label.new()
	_player_title.add_theme_font_size_override("font_size", 8)
	_player_title.text = "房间成员（0）"
	right_box.add_child(_player_title)

	_player_list = VBoxContainer.new()
	_player_list.name = "PlayerList"
	_player_list.add_theme_constant_override("separation", 1)
	_player_list.custom_minimum_size = Vector2(0, 20)
	# 人多时让它吃掉剩余空间，溢出部分裁掉，而不是把面板撑变形。
	_player_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_player_list.clip_contents = true
	right_box.add_child(_player_list)

	# 「返回」固定在面板底部，不参与上面的内容流。
	# 之前它排在内容末尾，而内容总高远超面板高度，于是它被顶到屏幕外面，
	# 结果大厅关不掉、也就点不到后面的「开始游戏」。
	#
	# 注意：position/size 必须在 add_child **之后**设置。入树时 Godot 会按
	# anchors/offsets 重算控件矩形，先设的值会被扔掉（实测 size 会从 20 变 40）。
	var close_button := _make_button("返回", _on_close_pressed)
	_panel.add_child(close_button)
	close_button.position = Vector2(PANEL_MARGIN, footer_top)
	close_button.size = Vector2(LOBBY_WIDTH - PANEL_MARGIN * 2.0, FOOTER_HEIGHT)

	_fit_panel_to_content(columns, close_button)


## 按内容的真实最小高度把面板加高，然后重新摆放两列、状态栏和底部按钮。
##
## 为什么不手算纵向预算（这条踩过两次）：
##   第一次给两列预留 157px，而左列实际需要 165px —— Container **不会**被压到
##   自己的最小高度以下，于是它长到 165，和状态栏重叠 8px；
##   第二次把 FOOTER_HEIGHT 写成 20，而紧凑按钮实测最小高度是 26，于是「返回」
##   比面板底部多伸出 3px。
##   两次都是同一个毛病：**手写的数字和真实布局对不上**。所以这里一律问控件要。
func _fit_panel_to_content(columns: HBoxContainer, close_button: Button) -> void:
	# 控件自报的最小高度可能比常量还大（字号、样式都是变量），取两者的大者。
	var footer_height := maxf(close_button.get_combined_minimum_size().y, FOOTER_HEIGHT)
	var status_height := maxf(_status_label.get_combined_minimum_size().y, STATUS_HEIGHT)
	var body_height := columns.get_combined_minimum_size().y

	var needed := PANEL_MARGIN * 2.0 + body_height + status_height + footer_height + ROW_GAP * 2.0
	# 不低于设计尺寸（太扁不好看），也不高于屏幕（viewport 逻辑高度只有 230）。
	needed = clampf(needed, LOBBY_HEIGHT, 230.0)

	_panel.size.y = needed
	_panel.custom_minimum_size.y = needed
	# anchors 是 TOP_LEFT，改完高度必须重新居中。
	_panel.position = _centered_panel_position(_panel.size)

	# 上下内边距对称，底部不再被按钮顶出去。
	var footer_top := _panel.size.y - PANEL_MARGIN - footer_height
	var status_top := footer_top - ROW_GAP - status_height
	var inner_width := LOBBY_WIDTH - PANEL_MARGIN * 2.0
	var columns_height := status_top - ROW_GAP - PANEL_MARGIN

	columns.position = Vector2(PANEL_MARGIN, PANEL_MARGIN)
	columns.size = Vector2(inner_width, columns_height)
	_status_label.position = Vector2(PANEL_MARGIN, status_top)
	_status_label.size = Vector2(inner_width, status_height)
	close_button.position = Vector2(PANEL_MARGIN, footer_top)
	close_button.size = Vector2(inner_width, footer_height)

	_say_layout(needed, body_height, status_height, footer_height, columns_height)


## 把最终几何写进日志。
##
## 这块画布的纵向预算是硬约束，出问题时「哪一条多高」比「哪里错了」更有用；
## 前面两次返工都是靠这类数字才定位到的。
func _say_layout(panel_height: float, body: float, status: float, footer: float, columns_height: float) -> void:
	print("[lobby] 面板高 %.0f（两列 %.0f / 状态 %.0f / 返回 %.0f / 内容区 %.0f）" % [
		panel_height, body, status, footer, columns_height])


## 把面板摆到屏幕正中。TOP_LEFT anchors 下 position 就是屏幕坐标。
func _centered_panel_position(panel_size: Vector2) -> Vector2:
	return ((get_viewport_rect().size - panel_size) * 0.5).floor()


func _make_label(text: String, width: float) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0)
	label.add_theme_font_size_override("font_size", 8)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _make_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", 8)
	# 项目主题里的 Button 内边距很大：一个 8px 字号的按钮实测最小高度 40px，
	# 而整个 viewport 逻辑高度才 230。不换掉样式的话，光按钮就会把大厅撑爆，
	# 底部的「返回」直接掉到屏幕外。这里换成紧凑样式，让高度回到可控范围。
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, _compact_button_style(state))
	button.pressed.connect(handler)
	return button


## 大厅专用的小尺寸主题。
##
## 项目主题 ui/theme.tres 是按更大的 UI 尺度调的：一个 8px 字号的 Button
## 实测最小高度就有 40px，而 viewport 的逻辑尺寸只有 410x230。用项目主题的话，
## 光是按钮和输入框的最小高度加起来就超过整屏，底部控件必然被挤到屏幕外。
##
## 与其给每个控件单独 add_theme_*_override（容易漏、也难维护），不如让大厅
## 自带一份主题，让所有子控件一次性变小。
func _build_compact_theme() -> Theme:
	var compact := Theme.new()
	compact.default_font_size = 7

	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		compact.set_stylebox(state, "Button", _compact_button_style(state))
		compact.set_stylebox(state, "OptionButton", _compact_button_style(state))
	compact.set_font_size("font_size", "Button", 7)
	compact.set_font_size("font_size", "OptionButton", 7)

	var edit_style := StyleBoxFlat.new()
	edit_style.bg_color = Color(0.08, 0.08, 0.10, 0.9)
	edit_style.border_color = Color(0.40, 0.42, 0.48, 0.8)
	edit_style.set_border_width_all(1)
	edit_style.set_corner_radius_all(2)
	edit_style.content_margin_top = 1.0
	edit_style.content_margin_bottom = 1.0
	edit_style.content_margin_left = 3.0
	edit_style.content_margin_right = 3.0
	for state in ["normal", "focus", "read_only"]:
		compact.set_stylebox(state, "LineEdit", edit_style)
	compact.set_font_size("font_size", "LineEdit", 7)

	compact.set_font_size("font_size", "Label", 7)
	return compact


## 大厅里用的紧凑按钮样式。
func _compact_button_style(state: String) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	match state:
		"hover":
			style.bg_color = Color(0.22, 0.24, 0.28, 0.95)
		"pressed":
			style.bg_color = Color(0.10, 0.11, 0.13, 0.95)
		"disabled":
			style.bg_color = Color(0.12, 0.12, 0.13, 0.6)
		_:
			style.bg_color = Color(0.15, 0.16, 0.19, 0.92)
	style.border_color = Color(0.42, 0.44, 0.50, 0.85)
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_top = 1.0
	style.content_margin_bottom = 1.0
	style.content_margin_left = 6.0
	style.content_margin_right = 6.0
	return style


func _default_name() -> String:
	var net: Variant = _net()
	if net != null:
		return str(net.get("local_player_name"))
	return "Player"


func _on_host_pressed() -> void:
	host_game()


func _on_join_pressed() -> void:
	join_game()


func _on_leave_pressed() -> void:
	leave_session()


func _on_close_pressed() -> void:
	close()
