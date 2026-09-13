extends CharacterBody2D
class_name RemotePlayer
## 联机时「其他玩家」的可视代理。
##
## 为什么不直接复用 Hero.tscn
##   Hero 会绑定全局单例（_init 里连 PlayerData 信号、_ready 里写
##   Utils.player）并处理键鼠输入。一棵树里出现多个 Hero 时它们会互相覆盖，
##   远端角色还会响应本机的按键。远端玩家只需要「看起来对、位置对、能被怪
##   物打到」，所以这里用轻量代理：复用 Hero 的 SpriteFrames 保证外观一致，
##   但完全不碰全局状态，也不读输入。
##
## 位置来源
##   房主聚合所有玩家的位置后广播，本节点通过 [method apply_remote_state]
##   收到目标点并做插值，避免 20Hz 的网络更新看起来一跳一跳。

## 位置插值速度（越大越跟手，越小越平滑）。
const INTERP_SPEED := 14.0
## 名字标签的显示高度（相对角色原点）。
const LABEL_OFFSET := Vector2(0, -26)
## 碰撞层级：**只占「玩家」层（bit3 = 8）**，不要用 Hero 的 25。
##
## Hero 的 CollisionShape2D 没有显式设置 collision_mask，默认是 1（bit0）。
## 如果代理也放在 25（含 bit0），本地 Hero 就会把队友的代理当成实体障碍：
## 被队友顶住、推着走，最后卡进地形里出不来。
##
## 放在 bit3 之后：
##   * Hero（mask=1）检测不到代理 → 不会被挡住 ✓
##   * 代理（mask=0）也不检测任何东西 ✓
##   * 怪物的攻击 Area2D 额外加上 bit3，仍然打得到队友（见 Monster2.tscn）
const PLAYER_COLLISION_LAYER := 8
## 代理不需要主动检测任何东西，它只是被检测方；位置完全由网络驱动，
## 所以 mask 留 0，免得被怪物的物理体推着走。
const PLAYER_COLLISION_MASK := 0
## 与 Hero 一致的碰撞体形状。
const BODY_RADIUS := 7.0
const BODY_OFFSET := Vector2(-1, -7)

const HERO_SCENE := preload("res://game/hero/Hero.tscn")

## Hero 的 SpriteFrames 只需要提取一次，之后所有远端代理共用。
static var _shared_frames: SpriteFrames = null
## 枪的视觉信息缓存：res:// 枪场景路径 -> {texture, offset, position}。
## 每种枪只从场景里提取一次，之后所有代理共用。
static var _gun_visuals: Dictionary = {}

var peer_id := 0
var player_name := ""

var _body: Node2D = null
var _sprite: AnimatedSprite2D = null
var _label: Label = null
var _target := Vector2.ZERO
var _has_target := false
var _flip := false
## 远端玩家手上的枪。
var _gun_root: Node2D = null
var _gun_sprite: Sprite2D = null
var _gun_path := ""
var _aim := 0.0


func _ready() -> void:
	_build_visuals()
	_build_collision()
	# 怪物按 ["hero"] 组找目标（见 Monster2._on_area_2d_body_entered），
	# 所以代理必须加入同一个组，否则房主端的怪物打不到远端队友。
	add_to_group("hero")
	global_position = _target


## 由 CoopSession 调用：告诉本代理它代表哪个 peer。
func setup_remote_player(id: int, name: String) -> void:
	peer_id = id
	player_name = name
	if _label != null:
		_label.text = name


## 由 CoopSession 调用：收到权威位置与表现状态。
##
## [param gun_path] / [param aim] 是对方手上的枪：枪场景的 res:// 路径和朝向。
## 武器本来完全没同步，症状是「互相看不到对方的武器」—— 代理只画了身体。
## 两个参数有默认值，老的调用点不受影响。
func apply_remote_state(pos: Vector2, flip: bool, gun_path: String = "", aim: float = 0.0) -> void:
	_target = pos
	if not _has_target:
		# 第一次同步直接吸附，避免从出生点滑过去。
		_has_target = true
		global_position = pos
	if flip != _flip:
		_flip = flip
		if _body != null:
			_body.scale.x = -1.0 if flip else 1.0
	if gun_path != _gun_path:
		_gun_path = gun_path
		_apply_gun_visual()
	_aim = aim


func _process(delta: float) -> void:
	if not _has_target:
		return
	global_position = global_position.lerp(_target, clampf(delta * INTERP_SPEED, 0.0, 1.0))
	if _sprite != null:
		var moving := global_position.distance_to(_target) > 1.0
		var want := "run" if moving else "idle"
		if _sprite.animation != want:
			_sprite.play(want)
	# 朝向直接照抄对方的枪角度，不本地猜（本机鼠标位置和对方没关系）。
	if _gun_root != null and _gun_root.visible:
		_gun_root.global_rotation = _aim


## 怪物攻击的落点。
##
## 关键：血量是**每个客户端各自的本机数据**（PlayerData 是本地单例），
## 房主端的这个代理并没有真正的血量。所以房主上的怪物打中代理时，这里只负责
## 把伤害转给那名玩家自己的客户端去扣，而不是在房主本地扣。
func onHit(hurt: float) -> void:
	if peer_id <= 0:
		return
	if not Net.is_multiplayer_active():
		return
	Coop.apply_player_damage(peer_id, hurt)


# --- 内部 ---------------------------------------------------------------------

## 建立碰撞体，让房主端的怪物 Area2D 能打到这个代理。
## 少了它，怪物在联机时只会攻击房主自己 —— 队友站在怪堆里也不会掉血。
func _build_collision() -> void:
	collision_layer = PLAYER_COLLISION_LAYER
	collision_mask = PLAYER_COLLISION_MASK
	var shape := CollisionShape2D.new()
	shape.name = "CollisionShape2D"
	var circle := CircleShape2D.new()
	circle.radius = BODY_RADIUS
	shape.shape = circle
	shape.position = BODY_OFFSET
	add_child(shape)

func _build_visuals() -> void:
	_body = Node2D.new()
	_body.name = "Body"
	add_child(_body)

	_sprite = AnimatedSprite2D.new()
	_sprite.name = "AnimatedSprite2D"
	var frames := _hero_frames()
	if frames != null:
		_sprite.sprite_frames = frames
		if frames.has_animation("idle"):
			_sprite.play("idle")
	_body.add_child(_sprite)

	# 枪：挂在和 Hero 一样的层级（body 之下），这样身体的翻转会带着枪一起翻。
	# 初始不可见，等第一次收到对方的武器路径再显示。
	_gun_root = Node2D.new()
	_gun_root.name = "GunRoot"
	_gun_sprite = Sprite2D.new()
	_gun_sprite.name = "Sprite2D"
	_gun_root.add_child(_gun_sprite)
	_gun_root.visible = false
	_body.add_child(_gun_root)

	_label = Label.new()
	_label.name = "NameLabel"
	_label.text = player_name
	_label.position = LABEL_OFFSET
	_label.add_theme_font_size_override("font_size", 8)
	_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 4)
	# 名字不参与角色翻转，也不吃鼠标事件。
	_label.scale = Vector2.ONE
	add_child(_label)


## 换枪：把对方的枪画出来。
##
## 只取枪场景里 Sprite2D 的贴图与偏移，**不实例化枪的逻辑**——直接 instantiate
## 一把真枪会带上 BaseGun 的射击/计时器/子弹逻辑，那是一个远端代理绝对不该有的。
func _apply_gun_visual() -> void:
	if _gun_root == null:
		return
	if _gun_path.is_empty():
		_gun_root.visible = false
		return
	var visual := _gun_visual_info(_gun_path)
	if visual.is_empty():
		_gun_root.visible = false
		return
	_gun_root.position = visual.get("position", Vector2.ZERO)
	_gun_sprite.texture = visual.get("texture")
	_gun_sprite.offset = visual.get("offset", Vector2.ZERO)
	_gun_root.visible = true


## 从枪场景里提取视觉信息并缓存。
##
## 实例化一个没进树的枪节点不会跑它的 _ready()，free() 时 Godot 会自动断开
## _init 里连的信号，所以没有残留副作用 —— 和 _hero_frames() 是同一套做法。
static func _gun_visual_info(scene_path: String) -> Dictionary:
	if _gun_visuals.has(scene_path):
		return _gun_visuals[scene_path]
	var info := {}
	if ResourceLoader.exists(scene_path):
		var packed := load(scene_path) as PackedScene
		if packed != null:
			var gun := packed.instantiate()
			if gun != null:
				var sprite := gun.get_node_or_null("Sprite2D") as Sprite2D
				var gun_node := gun as Node2D
				if sprite != null and gun_node != null:
					info = {
						"texture": sprite.texture,
						"offset": sprite.offset,
						"position": gun_node.position,
					}
				gun.free()
	_gun_visuals[scene_path] = info
	return info


## 从 Hero 场景里取出 AnimatedSprite2D 的 SpriteFrames 并缓存。
##
## 实例化 Hero 会跑它 _init() 里的信号连接，但节点没有进树、_ready() 不会
## 执行，free() 时 Godot 会自动断开那些连接，所以没有残留副作用。
static func _hero_frames() -> SpriteFrames:
	if _shared_frames != null:
		return _shared_frames
	var hero: Node = HERO_SCENE.instantiate()
	if hero != null:
		var sprite := hero.get_node_or_null("body/AnimatedSprite2D") as AnimatedSprite2D
		if sprite != null:
			_shared_frames = sprite.sprite_frames
		hero.free()
	return _shared_frames
