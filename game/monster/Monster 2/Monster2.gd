extends "res://game/monster/BaseMonster.gd"

## 玩家角色所在的组。Hero.tscn 里已经声明为 ["hero"]，RemotePlayer 也会加入。
## 怪物只攻击这个组里的东西 —— 见 _on_area_2d_body_entered 里的说明。
const PLAYER_GROUP := "hero"

var area_player = null
## 当前站在攻击范围内的所有玩家。
## 原版只记一个 body，多人时后进的人会顶掉先前的目标，而且先离开的那个会把
## 攻击整个关掉（is_atk = false），导致还站在原地的队友反而不再被打。
var _targets: Array = []

func _ready():
	super._ready()
	anim.play("idle")

func _on_area_2d_body_entered(body):
	# 只认玩家角色，而且必须按「组」判定，不能用能力判定。
	#
	# 这里踩过一次坑：为了让房主端的 RemotePlayer 代理也能被打到，曾经改成
	# `body.has_method("onHit")`。但 BaseMonster 自己也有 onHit，于是怪物会把
	# 彼此当成目标 —— 互相攻击、停在原地，反而放着玩家不管。
	# Hero 在 ["hero"] 组里（Hero.tscn），RemotePlayer 也会加入同一个组。
	if is_die || !body.is_in_group(PLAYER_GROUP) || _targets.has(body):
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
