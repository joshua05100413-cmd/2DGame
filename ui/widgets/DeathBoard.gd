extends Control

var click:Callable

func _enter_tree() -> void:
	get_tree().paused = true
	# 暂停整棵树之后，默认 PROCESS_MODE_INHERIT 的 Control 也会跟着暂停，
	# 于是这个面板自己的按钮不再响应点击 —— 症状就是「死了以后复活键点不动」。
	# 面板必须显式要求「暂停期间也要处理」，子节点会继承这个模式。
	process_mode = Node.PROCESS_MODE_ALWAYS

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
