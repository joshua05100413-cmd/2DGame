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

const LOBBY_WIDTH := 320.0
const LOBBY_HEIGHT := 186.0

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
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
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
		_set_status("已开房，等待队友加入（端口 %d）" % _read_port(), Color(0.6, 1.0, 0.7))
	_refresh_players()


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
	_address_edit.placeholder_text = _address_placeholder(selected_backend())


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
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_panel = Panel.new()
	_panel.name = "Panel"
	_panel.custom_minimum_size = Vector2(LOBBY_WIDTH, LOBBY_HEIGHT)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.position = Vector2(-LOBBY_WIDTH * 0.5, -LOBBY_HEIGHT * 0.5)
	_panel.size = Vector2(LOBBY_WIDTH, LOBBY_HEIGHT)
	add_child(_panel)

	var root_box := VBoxContainer.new()
	root_box.name = "Body"
	root_box.position = Vector2(8, 6)
	root_box.size = Vector2(LOBBY_WIDTH - 16, LOBBY_HEIGHT - 12)
	root_box.add_theme_constant_override("separation", 4)
	_panel.add_child(root_box)

	var title := Label.new()
	title.text = "联机合作生存"
	title.add_theme_font_size_override("font_size", 10)
	root_box.add_child(title)

	# 后端选择
	var backend_row := HBoxContainer.new()
	backend_row.add_theme_constant_override("separation", 6)
	root_box.add_child(backend_row)
	backend_row.add_child(_make_label("传输后端", 84))
	_backend_option = OptionButton.new()
	_backend_option.add_theme_font_size_override("font_size", 8)
	_backend_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backend_option.item_selected.connect(_on_backend_selected)
	backend_row.add_child(_backend_option)

	_backend_hint = Label.new()
	_backend_hint.add_theme_font_size_override("font_size", 7)
	_backend_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_backend_hint.custom_minimum_size = Vector2(LOBBY_WIDTH - 16, 20)
	root_box.add_child(_backend_hint)

	# 昵称
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	root_box.add_child(name_row)
	name_row.add_child(_make_label("昵称", 84))
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
	addr_row.add_child(_make_label("地址", 84))
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

	# 状态
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 7)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(LOBBY_WIDTH - 16, 18)
	_status_label.text = ""
	root_box.add_child(_status_label)

	# 房间成员
	_player_title = Label.new()
	_player_title.add_theme_font_size_override("font_size", 8)
	_player_title.text = "房间成员（0）"
	root_box.add_child(_player_title)

	_player_list = VBoxContainer.new()
	_player_list.name = "PlayerList"
	_player_list.add_theme_constant_override("separation", 1)
	_player_list.custom_minimum_size = Vector2(0, 40)
	root_box.add_child(_player_list)

	var close_button := _make_button("返回", _on_close_pressed)
	root_box.add_child(close_button)


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
	button.pressed.connect(handler)
	return button


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
