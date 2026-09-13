extends Control

@onready var setting_ui = $SettingUI

const pre = preload("res://ui/ModeSelect.tscn")
const LOBBY = preload("res://ui/LobbyUI.gd")

var _lobby = null

func _ready() -> void:
	Utils.onGameStart.connect(self.onGameStart)
	_add_multiplayer_button()
	# 联机：房间的节奏由房主决定，各端跟随。
	# 少了这条，房主进了关卡而客户端还停在主菜单上 —— 「开始游戏」原本是
	# 各端各自的本地操作。
	if not Net.match_started.is_connected(_on_match_started):
		Net.match_started.connect(_on_match_started)

## 在主菜单按钮列里插入「联机」入口。
##
## 用代码插入而不是编辑 ControlUI.tscn：那个场景有 600+ 行，手改节点树
## 既容易出错，也让 diff 难以审查。这里只加一个按钮，其余不变。
func _add_multiplayer_button() -> void:
	var box = $VBoxContainer
	if box == null or box.has_node("multiplayer"):
		return
	var button = Button.new()
	button.name = "multiplayer"
	button.text = "联机"
	button.add_theme_font_size_override("font_size", 8)
	box.add_child(button)
	# 排在「开始游戏」之前，作为主入口之一。
	box.move_child(button, 0)
	button.pressed.connect(self._on_multiplayer_pressed)

func _on_multiplayer_pressed() -> void:
	if _lobby == null or not is_instance_valid(_lobby):
		_lobby = LOBBY.new()
		_lobby.name = "LobbyUI"
		add_child(_lobby)
	_lobby.open()

func _on_start_pressed() -> void:
	var ins = pre.instantiate()
	ins.onModeChoose.connect(self.onModeChoose)
	add_child(ins)

func onModeChoose(mode):
	if Net.is_multiplayer_active():
		if Net.is_host():
			# 房主选模式 = 宣布开局，广播给所有人（call_local 也会回到自己这里）。
			Net.start_match(mode)
		else:
			# 客户端不能自己开局：它得等房主，否则各端会进到不同的地图。
			Utils.showToast("等待房主开始游戏")
		return
	_enter_mode(mode)


## 房主宣布开局后，各端（含房主）走同一段进入逻辑。
func _on_match_started(mode: int) -> void:
	_enter_mode(mode)


func _enter_mode(mode):
	if mode == 0:
		Utils.gameStart()
	else:
		SceneManager.change_scene("res://game/map/SnowWorld/SnowWorld.tscn",
		{ "pattern": "scribbles", "pattern_leave": "squares" }
		)

func onGameStart():
	$VBoxContainer.visible = false
	get_tree().create_tween().tween_property($TextureRect,"modulate:a",0,0.5)

func _on_setting_pressed() -> void:
	setting_ui.visible = true

func _on_mod_pressed() -> void:
	#Utils.showToast("WAIT_MORE")
	pass
