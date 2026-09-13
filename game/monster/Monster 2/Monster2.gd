extends "res://game/monster/BaseMonster.gd"

var area_player = null
## 当前站在攻击范围内的所有玩家。
## 原版只记一个 body，多人时后进的人会顶掉先前的目标，而且先离开的那个会把
## 攻击整个关掉（is_atk = false），导致还站在原地的队友反而不再被打。
var _targets: Array = []

func _ready():
	super._ready()
	anim.play("idle")

func _on_area_2d_body_entered(body):
	# 远端队友在房主端是 RemotePlayer 代理，不是 Player，但同样必须能被打到，
	# 所以这里按「能力」判定（有 onHit）而不是按具体类型。
	if is_die || !body.has_method("onHit") || _targets.has(body):
		return
	_targets.append(body)
	_pick_target()


## 从范围内的玩家里挑一个最近的作为目标。
func _pick_target():
	_targets = _targets.filter(func(t): return is_instance_valid(t))
	if _targets.is_empty():
		area_player = null
		is_atk = false
		return
	var nearest: Node2D = null
	var best := INF
	for candidate in _targets:
		var node: Node2D = candidate
		var distance := global_position.distance_squared_to(node.global_position)
		if distance < best:
			best = distance
			nearest = node
	area_player = nearest
	if not is_atk:
		# 只在「从没目标变成有目标」时启动攻击循环；
		# 已经有目标时新目标进来不该把攻击节奏打断。
		is_atk = true
		$AtkTimer.start()

func onAtk():
	if is_die:
		return
	anim.play("atk")
	await anim.animation_finished
	anim.play("idle")

func _on_animated_sprite_2d_frame_changed():
	if anim.animation == "atk" && anim.frame == 5 && area_player != null && !is_die:
		area_player.onHit(hurt)


func _on_area_2d_body_exited(body):
	if !_targets.has(body):
		return
	_targets.erase(body)
	_pick_target()

func _on_atk_timer_timeout():
	onAtk()
