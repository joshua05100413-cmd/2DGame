extends Control

var click:Callable

func _enter_tree() -> void:
	get_tree().paused = true
	# 暂停整棵树之后，默认 PROCESS_MODE_INHERIT 的 Control 也会跟着暂停，
	# 于是这个面板自己的按钮不再响应点击 —— 症状就是「死了以后复活键点不动」。
	# 面板必须显式要求「暂停期间也要处理」，子节点会继承这个模式。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 死亡面板弹出时把准星收起来：它已经不再有意义，留在屏幕上只会继续转，
	# 而且会盖在面板上（准星所在的 CanvasLayer 层号比场景里的 HUD 高）。
	Utils.crosshairChange(false)

func _exit_tree() -> void:
	# 复活/放弃之后把准星放回来。放在 _exit_tree 而不是两个按钮里，
	# 这样无论面板以哪条路径消失都能恢复。
	Utils.crosshairChange(true)

func setOnClick(callback:Callable):
	click = callback

func _on_button_pressed() -> void:
	get_tree().paused = false
	if PlayerData.gold >= 50:
		PlayerData.gold -= 50
		click.call(true)
	else:
		click.call(false)
		Utils.showToast("BUY_ERROR")
	queue_free()


func _on_button_2_pressed() -> void:
	get_tree().paused = false
	click.call(false)
	queue_free()
