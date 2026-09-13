extends Node2D

@onready var builder = $MonsterBuilder
@onready var land = $Land

const HERO_SCENE = preload("res://game/hero/Hero.tscn")
const REMOTE_PLAYER = preload("res://game/net/RemotePlayer.gd")
const GHOUL_PRE = preload("res://game/monster/Ghoul/Ghoul.tscn")
## 联机时用来复现队友弹道的「表现子弹」。
##
## 必须挑一个带 PointLight2D 的子弹场景：这张地图用 CanvasModulate 压暗到
## 0.04，子弹基本靠自身的光照亮，用没有光的场景（例如 Bullet.tscn，它只有
## Bullet.gd 没有 Sprite2D/PointLight2D 子节点）在屏幕上等于隐形。
## 项目里绝大多数枪用的都是 SmpBullet，所以表现层统一用它。
const VISUAL_BULLET = preload("res://game/bullets/SmpBullet.tscn")

## 联机时这只怪物的类型键，必须与 CoopWorld 注册的一致。
const COOP_MONSTER_TYPE := "ghoul"

func _init() -> void:
	Utils.onGameStart.connect(self.onGameStart)

func _ready() -> void:
	$MonsterBuilder.land = land
	$MonsterBuilder.monsterRoot = $MonsterRoot
	$CanvasLayer.onMonsterJoin.connect(self.onMonsterJoin)
	PlayerServer.addPlayerToScene($PlayerRoot)
	PlayerServer.setPlayerPosition($CreatePosition.global_position)
	Utils.gameStart()
	Utils.crosshairChange(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_setup_coop_world()


## 联机：把本关卡的复制容器交给会话层。单机时是空操作。
func _setup_coop_world() -> void:
	if not Net.is_multiplayer_active():
		return
	var world := CoopWorld.create($PlayerRoot, $MonsterRoot, $CreatePosition.global_position)
	world.with_players(
		func() -> Node2D: return HERO_SCENE.instantiate(),
		func() -> Node2D: return REMOTE_PLAYER.new())
	world.with_monster(COOP_MONSTER_TYPE, func() -> Node2D: return GHOUL_PRE.instantiate())
	world.with_shot_visual(_spawn_shot_visual)
	Coop.attach_world(world)


## 联机：在本地复现队友开火。只是表现，不结算伤害。
func _spawn_shot_visual(_shooter: int, from: Vector2, direction: Vector2, speed: float) -> void:
	var bullet: Bullet = VISUAL_BULLET.instantiate()
	bullet.setup_as_visual()
	bullet.speed = speed
	get_tree().root.add_child(bullet)
	bullet.global_position = from
	bullet.rotation = direction.angle()
	bullet.fire()

func onGameStart():
	$ControlUI.visible = true
	$CanvasLayer/Panel.visible = true
	PlayerData.player_ammo = 9999999
	var gun = Utils.weapon_list['0']
	PlayerData.add_weapon(gun.instantiate())
	await get_tree().create_timer(0.7).timeout
	create_tween().tween_property($PlayerRoot/Anchor/Camera2D/PointLight2D,"texture_scale",0.8,1)
	
func onMonsterJoin():
	Utils.crosshairChange(true)
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED_HIDDEN
	builder.start()
	
	EquipServer.addEquipOnFloor(preload("res://game/equip/High-Energy Particle Cannon.tscn").instantiate(),Utils.player.global_position)
	EquipServer.addEquipOnFloor(preload("res://game/equip/Flamethrower.tscn").instantiate(),Utils.player.global_position+ Vector2(20,20))

func addEffectNode(node):
	$EffectRoot.add_child(node)

func addEquip(ins):
	$EquipRoot.add_child(ins)
