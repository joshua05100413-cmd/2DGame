extends Node

const player_node = preload("res://game/hero/Hero.tscn")

var player_scene : Player = null

func addPlayerToScene(sence:Node2D):
	# 联机：玩家（含本机玩家）统一由 CoopSession 按权威名单生成。
	# 如果这里再各自造一个「自己的」玩家，双方就互相看不见了。
	if Net.is_multiplayer_active():
		return
	if player_scene == null:
		player_scene = player_node.instantiate()
	if  player_scene.is_inside_tree():
		player_scene.get_parent().remove_child(player_scene)
	sence.add_child(player_scene)

func setPlayerPosition(position):
	if player_scene:
		player_scene.global_position = position
