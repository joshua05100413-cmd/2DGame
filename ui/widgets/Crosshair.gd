@tool
extends TextureRect

var rotation_speed = PI

func _ready() -> void:
	set_process(false)
	# 准星**永远**不该吃鼠标事件。
	#
	# Control 的 mouse_filter 默认是 STOP，而准星每帧把自己摆在光标正下方
	# （见 _process），于是它正好挡在每一个点击上面 —— 点什么都变成点在准星上。
	# 症状就是「死亡后复活键点不动」：DeathBoard 的按钮看得见，但点击被准星截走了。
	# 原本只有把 UI 的 z_index 抬到准星之上才能用（大厅就是这么绕过去的），
	# 但那要求每个面板都知道这件事；让准星彻底忽略鼠标才是根上的解法。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# This script is @tool, so _ready() also runs inside the editor. Autoload
	# singletons are not reliably available there, and the original code crashed
	# with:
	#   SCRIPT ERROR: Invalid access to property or key 'onGameStart' on a base
	#   object of type 'Node (Utils.gd)'
	# Only wire up the signal when actually running the game.
	if Engine.is_editor_hint():
		return
	var utils := get_node_or_null("/root/Utils")
	if utils == null or not utils.has_signal("onGameStart"):
		return
	if not utils.onGameStart.is_connected(self.onGameStart):
		utils.onGameStart.connect(self.onGameStart)

func onGameStart():
	set_process(true)
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED_HIDDEN

func _process(delta: float) -> void:
	rotation += rotation_speed * delta
	global_position = get_global_mouse_position() - size  / 2
