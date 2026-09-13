extends CharacterBody2D
class_name BaseMonster

@export var is_boss = false
@export var SPEED = 50.0
@export var hurt = 1
@export var HP = 5
@export var knockback_def = 5 #击退抵抗
var movement_delta: float
# NOTE: 这里原本有一个 `var navigationAgent2D := NavigationAgent2D.new()`，
# 它从未 add_child、也从未被真正调用（唯一的用处在一行注释里），
# 却会在退出时让引擎报 "RID allocations of type 'NavAgent' were leaked at exit"。
# 直接删掉：怪物现在用的是「朝玩家直线追击」。
var audio_hit = AudioStreamPlayer2D.new()
@onready var sprite_body = get_node("body")
@onready var anim :AnimatedSprite2D = get_node("body/AnimatedSprite2D")

var target_player:Player = Utils.player
var state_array = []
var hit = false
var is_die = false
var is_flip
var is_atk = false

var death_callback :Callable

# --- 联机相关 -----------------------------------------------------------------
## 本端是否权威地模拟这只怪物。房主为 true；客户端拿到的是「影子」，
## 不跑 AI、不本地结算伤害，位置与血量都由房主同步。
var is_authoritative := true
## 房主分配的怪物网络 id；0 表示单机（没有联机会话）。
var net_id := 0

## 影子插值速度。
const NET_INTERP_SPEED := 12.0
var _net_target := Vector2.ZERO
var _has_net_target := false

func _ready():
	var node = Node2D.new()
	node.name = "EffectRoot"
	add_child(node)
	# 联机时名字由 CoopSession 统一命名为 M<net_id>，不能被时间戳覆盖。
	if net_id == 0:
		name = str(Time.get_ticks_usec())
	audio_hit.stream = load("res://audio/body_hit_finisher_52.wav")
	add_child(audio_hit)

func setData(data):
	SPEED = data['speed']
	hurt = data['hurt']
	HP = data['hp']
	knockback_def = 5

# --- 联机接口（由 CoopSession 调用）------------------------------------------

## 标记本端是否权威模拟这只怪物。
func set_authoritative(value: bool) -> void:
	is_authoritative = value
	if not value and anim != null:
		anim.play("idle")

## 绑定房主分配的怪物网络 id。
func set_network_id(id: int) -> void:
	net_id = id

## 影子收到房主的位置，做插值并本地推断朝向。
func apply_remote_position(pos: Vector2) -> void:
	_net_target = pos
	if not _has_net_target:
		# 首次同步直接吸附，避免从出生点滑过来。
		_has_net_target = true
		global_position = pos

## 非权威端：把血量对齐房主的权威值。
func set_network_hp(value: float) -> void:
	if is_authoritative:
		return
	HP = value

## 权威端：结算一次来自其他客户端上报的伤害。
func apply_network_damage(amount: float) -> void:
	if is_die or not is_authoritative:
		return
	onHit(amount, true, true)

func _physics_process(delta):
	# 伤害数字所有端都要显示，**包括客户端上的影子**，所以必须放在影子分支之前。
	# 曾经把它放在后面，影子直接 return 掉了，于是联机时打怪没有伤害数字
	# （但伤害是生效的 —— 怪照样会死、照样掉金币，只是玩家看不到反馈）。
	if idle_frame_num > 0:
		Utils.showHitLabel(idle_frame_num,self)
		idle_frame_num = 0
	# 影子：不跑 AI，只跟随房主同步过来的位置。
	if not is_authoritative:
		_update_shadow(delta)
		return
	#if Engine.get_physics_frames() % 60 :
	if is_atk || is_die:
		return
	if hit:
		move_and_slide()
	elif target_player != null:
		var next_path_position = target_player.global_position
		#var next_path_position = navigationAgent2D.get_next_path_position()
		var current_agent_position: Vector2 = global_position
		var new_velocity: Vector2 = current_agent_position.direction_to(next_path_position) * SPEED
		_on_velocity_computed(new_velocity)

	if velocity != Vector2.ZERO:
		anim.play("run")
		if velocity.x > 0:
			flip_h(false)
		elif velocity.x < 0 && scale.x == 1:
			flip_h(true)
	else:
		anim.play("idle")

func _on_velocity_computed(safe_velocity: Vector2) -> void:
	if state_array.has(Utils.STATE_TYPE.STUN):
		anim.play("idle")
		return
	velocity = safe_velocity
	move_and_slide()

func flip_h(flip:bool):
	if is_flip == flip:
		return
	is_flip = flip
	var x_axis = sprite_body.global_transform.x
	sprite_body.global_transform.x.x = (-1 if flip else 1) * abs(x_axis.x)


## 影子每帧的表现更新：插值到房主给的位置，并按位移方向翻转。
func _update_shadow(delta: float) -> void:
	if not _has_net_target or is_die:
		return
	var before := global_position
	global_position = global_position.lerp(_net_target, clampf(delta * NET_INTERP_SPEED, 0.0, 1.0))
	if anim == null:
		return
	if global_position.distance_to(_net_target) > 1.0:
		anim.play("run")
		var dx := _net_target.x - before.x
		if absf(dx) > 0.01:
			flip_h(dx < 0.0)
	else:
		anim.play("idle")


func hitFlash(collisionResult,bullet:Bullet):
	if is_die:
		return
	# 联机时客户端本地不结算伤害：只上报房主，由房主决定死活并广播结果。
	# 这样两端的血量与击杀数不会因为各自算各自的而漂移。
	if not is_authoritative:
		if net_id > 0:
			Coop.apply_monster_damage(net_id, bullet.hurt)
		audio_hit.play(0.17)
		return
	Utils.freezeFrame(bullet.gun.time_scale)
	onHit(bullet.hurt)
	audio_hit.play(0.17)
	var speed = bullet.knockback_speed - knockback_def
	if speed > 0:
		velocity = -(global_position.direction_to(Utils.player.global_position)) * speed
		hit = true
	#var materialFlash = ShaderMaterial.new()
	#materialFlash.shader = load("res://shader/Monster1.gdshader")
	#sprite_body.get_node("AnimatedSprite2D").material = materialFlash
	await get_tree().create_timer(bullet.knockback_time).timeout.connect(func timeout():
		sprite_body.get_node("AnimatedSprite2D").material = null; hit = false )

var idle_frame_num = 0
func onHit(hit_num,is_show_label = true,is_death_effect = true):
	if PlayerData.base_aim_enh > 0 && PlayerData.base_aim_enh > randi()%100:
		hit_num *= 1.5
	var nodes = get_tree().get_nodes_in_group("reward")
	var temp_hurt = 0
	for node in nodes:
		if node.connect_beforeAtk:
			var num = node.call("beforeAtk",self,hit_num)
			temp_hurt += num
	hit_num += temp_hurt
	hit_num = snapped(hit_num,0.01)
	if is_show_label:
		idle_frame_num += hit_num
	if HP:
		HP -= hit_num
		if HP <= 0:
			onDie(is_death_effect)
	for node in nodes:
		if node.connect_afterAtk:
			node.call("afterAtk",self,hit_num)
	# 联机：把权威血量同步给客户端影子。
	# 本地子弹命中与客户端上报的伤害都走这条路径，所以两端不会各算各的。
	if is_authoritative and net_id > 0 and not is_die:
		Coop.broadcast_monster_hp(net_id, HP)

func onDie(is_death_effect = true):
	is_die = true
	# 联机：告诉会话层这只怪物死了，房主会广播移除事件。
	if is_authoritative and net_id > 0:
		Coop.notify_monster_died(net_id)
	PlayerData.player_exp += 1
	if death_callback:
		death_callback.call(self)
	var nodes = get_tree().get_nodes_in_group("reward")
	var temp_hurt = 0
	if is_death_effect:
		for node in nodes:
			if node.connect_kill:
				node.call("onKill",self)
	set_physics_process(false)
	for item in get_node("EffectRoot").get_children():
		item.queue_free()
	get_node("CollisionShape2D").call_deferred("set_disabled",true)
	anim.play("die")
	get_tree().create_tween().tween_property(get_node("UndeadShadow"),"scale",Vector2.ZERO,0.3)
	await anim.animation_finished
	queue_free()
	
func setDeathCallBack(death_callback:Callable):
	self.death_callback = death_callback

func addEffect(node):
	get_node("EffectRoot").add_child(node)
