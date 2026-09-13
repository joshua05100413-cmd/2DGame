extends "res://game/items/BaseItem.gd"
#金币

## 联机：房主分配的掉落物网络 id。0 表示单机（不走 Coop）。
var net_id := 0
## 已经有人捡走了它。防止同一帧内 Area2D 多次触发导致重复加钱。
var _claimed := false


func _ready():
	var tween = create_tween().set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(self,"scale",Vector2(1,1),0.3).from(Vector2.ZERO)


## 联机：由 CoopSession 在生成时写入。
func set_network_id(id: int) -> void:
	net_id = id


func _on_area_2d_body_entered(body):
	if _claimed:
		return
	# 只有本机玩家能拾取。远端队友是 RemotePlayer 代理，不参与本地碰撞判定，
	# 他们的拾取由他们自己那端上报。
	if not (body is Player):
		return
	_claimed = true
	if giveCallBack:
		giveCallBack.call()
	PlayerData.gold += 1
	# 联机：归属由房主裁定并广播移除。
	# 少了这一步，两个玩家会各自捡到"同一枚"金币，而且金币不会在对方屏幕上消失。
	if net_id > 0 and Net.is_multiplayer_active():
		Coop.report_pickup_claimed(net_id)
	var tween = create_tween().set_ease(Tween.EASE_IN_OUT).set_parallel(true)
	tween.tween_property(self,"position:y",position.y - 20,0.3)
	tween.tween_property(self,"modulate:a",0.0,0.3)
	tween.tween_callback(self.queue_free).set_delay(0.3)
	Utils.showHitLabel("+1",body)
