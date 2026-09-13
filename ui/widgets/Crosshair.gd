@tool
extends TextureRect

var rotation_speed = PI

func _ready() -> void:
	set_process(false)
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
