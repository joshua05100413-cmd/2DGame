extends Control

@onready var setting_ui = $SettingUI

const pre = preload("res://ui/ModeSelect.tscn")
const LOBBY = preload("res://ui/LobbyUI.gd")

var _lobby = null

func _ready() -> void:
	Utils.onGameStart.connect(self.onGameStart)
	_add_multiplayer_button()

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
