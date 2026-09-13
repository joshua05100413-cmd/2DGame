extends Node2D
## 传送门。
##
## 联机改动：必须**所有玩家都进入范围**才允许传送。
##
## 为什么：合作生存里各走各的门会让队伍立刻散开，而关卡进程是房主权威的，
## 一个人先过去会让另一端的画面莫名其妙地跳。所以推进关卡变成一件需要
## 「大家一起」的事。
##
## 单机时场上只有 1 个玩家，[method expected_player_count] 返回 1，
## 行为与改动前完全一致。

@export var next_area:Node2D
@export var one_shot = false

signal moveIn(next_area)
signal moveOut()

var is_open = true

## 当前站在门范围内、需要一起过去的玩家。
## 本机 Hero 和远端队友的代理都算 —— 后者在本端只是一个 RemotePlayer。
var _players_inside: Array = []
## 上一次是否已凑齐，用来只在状态翻转时提示一次，避免刷屏。
var _was_complete := true


func _ready():
	add_to_group("Portal")
	$Area2D.body_entered.connect(self._on_area_2d_body_entered)
	$Area2D.body_exited.connect(self._on_area_2d_body_exited)


## 场上应有的玩家数：联机时是房间人数，单机是 1。
func expected_player_count() -> int:
	if Net.is_multiplayer_active():
		return maxi(Net.get_peer_count(), 1)
	return 1


## 是否所有玩家都到齐了。
func is_complete() -> bool:
	return _players_inside.size() >= expected_player_count()


func _on_area_2d_body_entered(body):
	# 按「组」判定而不是 `body is Player`：远端队友在本端是 RemotePlayer 代理，
	# 类型对不上，但它必须算进「到齐」的人数里。
	if not body.is_in_group("hero"):
		return
	if not _players_inside.has(body):
		_players_inside.append(body)
	_refresh_gate()
	_try_enter()


func _on_area_2d_body_exited(body):
	if not _players_inside.has(body):
		return
	_players_inside.erase(body)
	_refresh_gate()
	if next_area == null:
		return
	if one_shot:
		is_open = false
		close()
	else:
		next_area.is_open = true
		is_open = true
	emit_signal("moveOut")


## 所有玩家到齐才放行。
## 注意要在「每次有人进入」时都调用：最后一个人踏进来的那一刻才凑齐，
## 而那时先到的人不会再触发 body_entered。
func _try_enter():
	if not is_complete():
		return
	if next_area == null or not next_area.is_open or not is_open:
		return
	next_area.is_open = false
	emit_signal("moveIn", next_area)


## 到齐状态翻转时提示一句，免得玩家不知道在等谁。
func _refresh_gate():
	_players_inside = _players_inside.filter(func(p): return is_instance_valid(p))
	var complete := is_complete()
	if complete == _was_complete:
		return
	_was_complete = complete
	if complete:
		return
	if not Net.is_multiplayer_active():
		return
	Utils.showToast("等待队友到齐，一起进入")


func reset():
	is_open = true
	_players_inside.clear()
	_was_complete = true
	if next_area != null:
		next_area.is_open = true
	if $Area2D.body_entered.is_connected(self._on_area_2d_body_entered):
		$Area2D.body_entered.disconnect(self._on_area_2d_body_entered)
	if $Area2D.body_exited.is_connected(self._on_area_2d_body_exited):
		$Area2D.body_exited.disconnect(self._on_area_2d_body_exited)
	$Area2D.body_entered.connect(self._on_area_2d_body_entered)
	$Area2D.body_exited.connect(self._on_area_2d_body_exited)


func close():
	if $Area2D.body_entered.is_connected(self._on_area_2d_body_entered):
		$Area2D.body_entered.disconnect(self._on_area_2d_body_entered)
	if $Area2D.body_exited.is_connected(self._on_area_2d_body_exited):
		$Area2D.body_exited.disconnect(self._on_area_2d_body_exited)
