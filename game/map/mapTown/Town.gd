extends Node2D

@onready var pos_start = $TileMap2/Level_1/pos_start
@onready var pos_end = $TileMap2/Level_1/pos_end
@onready var pos_level_1 = $TileMap2/Level_1
@onready var pos_level_5 = $TileMap2/Level_5/pos_start
@onready var pos_level_11 = $TileMap2/Level_11
@onready var pos_level_16 = $TileMap2/Level_16
@onready var pos_level_21 = $TileMap2/Level_21
@onready var pos_level_26 = $TileMap2/Level_26
@onready var monster_root = $TileMap2/MonsterRoot
@onready var shopBtn = $CanvasLayer/openShop
@onready var kill_playr = $Kill
@onready var portal_start = $TileMap2/PortalRoot/Portal 
@onready var portal_lv1 = $TileMap2/PortalRoot/Portal2 
@onready var portal_lv5 = $TileMap2/PortalRoot/Portal3 
@onready var portal_lv11 = $TileMap2/PortalRoot/Portal4 
@onready var portal_lv16 = $TileMap2/PortalRoot/Portal5
@onready var portal_lv21 = $TileMap2/PortalRoot/Portal6
@onready var portal_lv26 = $TileMap2/PortalRoot/Portal7

const gold = preload("res://game/items/Gold.tscn")
const weapon_choose = preload("res://ui/widgets/WeaponChoose.tscn")
const monster_pre = preload("res://game/monster/Monster 2/Monster2.tscn")
const death_borad = preload("res://ui/widgets/DeathBoard.tscn")
const HERO_SCENE = preload("res://game/hero/Hero.tscn")
const REMOTE_PLAYER = preload("res://game/net/RemotePlayer.gd")
## 联机时用来复现队友弹道的「表现子弹」。
##
## 必须挑一个带 PointLight2D 的子弹场景：这张地图用 CanvasModulate 压暗到
## 0.04，子弹基本靠自身的光照亮，用没有光的场景（例如 Bullet.tscn，它只有
## Bullet.gd 没有 Sprite2D/PointLight2D 子节点）在屏幕上等于隐形。
## 项目里绝大多数枪用的都是 SmpBullet，所以表现层统一用它。
const VISUAL_BULLET = preload("res://game/bullets/SmpBullet.tscn")

## 联机时这只怪物的类型键，必须与 CoopWorld 注册的一致。
const COOP_MONSTER_TYPE := "monster2"
## 联机时金币掉落物的类型键。
const COOP_PICKUP_GOLD := "gold"

func _ready():
	LevelServer.monsterCreate.connect(self.monsterCreate)
	LevelServer.roundVictory.connect(self.roundVictory)
	LevelServer.onTimeTick.connect(self.onTimeTick)
	LevelServer.onRoundStart.connect(self.onRoundStart)
	LevelServer.onRoundEnd.connect(self.onRoundEnd)
	LevelServer.onNextLevel.connect(self.onNextLevel)
	Utils.onGameStart.connect(self.onGameStart)
	PlayerData.onPlayerDeath.connect(self.onPlayerDeath)
	_setup_coop_world()
	# Town 和主菜单同属 Main.tscn，所以 _ready() 跑的时候玩家通常还在主菜单、
	# 还没开房或加入 —— 那一刻 _setup_coop_world() 会因为没联机而直接返回。
	# 联机是之后才建立的，所以必须在这里再挂一次监听，否则「普通模式」下的
	# 联机永远不会生效（雪地模式是切场景加载的，不受影响）。
	if not Net.state_changed.is_connected(_on_net_state_changed):
		Net.state_changed.connect(_on_net_state_changed)


## 会话建立或断开时重试挂载世界。
func _on_net_state_changed() -> void:
	if Coop.world != null:
		return
	if not Net.is_multiplayer_active():
		return
	_setup_coop_world()


## 联机：把本关卡的复制容器交给会话层。单机时是空操作。
func _setup_coop_world() -> void:
	if not Net.is_multiplayer_active():
		return
	var world := CoopWorld.create($TileMap2/PlayerRoot, monster_root, $PositionHome.global_position)
	# Town.tscn 里已经摆好了一个 Hero 实例，直接把它作为本机玩家复用，
	# 不必再生成一个（否则会出现两个自己）。
	var preset := $TileMap2/PlayerRoot/Hero as Node2D
	world.local_player_node = preset
	world.with_players(
		func() -> Node2D: return HERO_SCENE.instantiate(),
		func() -> Node2D: return REMOTE_PLAYER.new())
	world.with_monster(COOP_MONSTER_TYPE, func() -> Node2D:
		var spawn := monster_pre.instantiate()
		spawn.setDeathCallBack(self.onMonsterDeath)
		return spawn)
	world.with_pickup(COOP_PICKUP_GOLD, func() -> Node2D:
		return gold.instantiate())
	world.with_shot_visual(_spawn_shot_visual)
	# 金币归属由房主裁定；裁定后由房主累加关卡统计。
	# 客户端的 level_info 会被房主广播的状态覆盖，所以只有房主需要累加。
	if not Coop.pickup_claimed.is_connected(_on_coop_pickup_claimed):
		Coop.pickup_claimed.connect(_on_coop_pickup_claimed)
	Coop.attach_world(world)


## 联机：房主确认某枚金币被拾取后累加关卡统计。
func _on_coop_pickup_claimed(_net_id: int, _by_peer: int) -> void:
	if Coop.is_host():
		LevelServer.level_info.gold += 1


## 联机：在本地复现队友开火。
## 这只是表现 —— 子弹的碰撞层是空的，飞出去就消失，不会造成任何伤害。
func _spawn_shot_visual(_shooter: int, from: Vector2, direction: Vector2, speed: float) -> void:
	var bullet: Bullet = VISUAL_BULLET.instantiate()
	bullet.setup_as_visual()
	bullet.speed = speed
	# 原版子弹就是挂在场景树根下的，保持一致。
	get_tree().root.add_child(bullet)
	bullet.global_position = from
	bullet.rotation = direction.angle()
	bullet.fire()

func _unhandled_input(event: InputEvent) -> void:
	if $CanvasLayer/openShop.visible && Input.is_action_just_pressed("e"):
		var ins = Utils.shop_pre.instantiate()
		$CanvasLayer.add_child(ins)

func onGameStart():
	$CanvasLayer/level.visible = true
	$CanvasLayer/timeout.visible = true

func onPlayerDeath():
	LevelServer.isPause(true)
	var ins = death_borad.instantiate()
	ins.setOnClick(func callback(success):
		if success:
			LevelServer.isPause(false)
			PlayerData.resurrectPlayer(PlayerData.player_hp_max, 100)
		else:
			PlayerData.resurrectPlayer(1, 20)
			onRoundEnd()
		)
	$CanvasLayer.add_child(ins)

func _on_portal_2_move_out() -> void:
	LevelServer.roundStart()

func onTimeTick(timeout) -> void:
	if Utils.player.is_dead == false:
		$CanvasLayer/timeout.text =tr("REMAINING TIME") + str(timeout)

#回合开始
func onRoundStart():
	Utils.showToast("START_TIP",2)
	$CanvasLayer/timeout.visible = true
	$CanvasLayer/level.visible = true
	$CanvasLayer/level.text = tr("DIFFICULTY LEVEL") + " " + str(LevelServer.level)

#回合结束
func onRoundEnd():
	Utils.player.global_position = $PositionHome.global_position
	$CanvasLayer/timeout.text =tr("REMAINING TIME")
	for item in monster_root.get_children():
		item.queue_free()
	await get_tree().create_timer(1).timeout
	for item in $TileMap2/PortalRoot.get_children():
		item.reset()

#回合胜利
func roundVictory():
	Utils.showToast("VICTORY IN THE ROUND",1)
	$CanvasLayer.add_child(LevelServer.getScoreboard())

#获取坐标点
func getPoint():
	var random_point
	if [1,2,3,4,5].has(LevelServer.level):
		var node = pos_level_1.get_child(randi()%pos_level_1.get_child_count())
		random_point = node.global_position
	elif [6,7,8,9,10].has(LevelServer.level):
		random_point = pos_level_5.global_position
	elif [11,12,13,14,15].has(LevelServer.level):
		var node = pos_level_11.get_child(randi()%pos_level_11.get_child_count())
		random_point = node.global_position
	elif [16,17,18,19,20].has(LevelServer.level):
		var node = pos_level_16.get_child(randi()%pos_level_16.get_child_count())
		random_point = node.global_position
	elif [21,22,23,24,25].has(LevelServer.level):
		var node = pos_level_21.get_child(randi()%pos_level_21.get_child_count())
		random_point = node.global_position
	elif [26,27,28,29,30].has(LevelServer.level):
		var node = pos_level_26.get_child(randi()%pos_level_26.get_child_count())
		random_point = node.global_position
	return random_point

func _on_shop_body_entered(body: Node2D) -> void:
	if body is Player:
		shopBtn.visible = true

func _on_shop_body_exited(body: Node2D) -> void:
	if body is Player:
		shopBtn.visible = false

#进入地图
func _on_portal_move_in(next_area):
	if Utils.player.gun == null:
		Utils.showToast("PLEASE PURCHASE A WEAPON FIRST")
	else:
		Utils.player.global_position = next_area.global_position

#下一关通知
func onNextLevel(level):
	if [1,2,3,4,5].has(LevelServer.level):
		portal_start.next_area = portal_lv1
	elif [6,7,8,9,10].has(LevelServer.level):
		portal_start.next_area = portal_lv5
	elif [11,12,13,14,15].has(LevelServer.level):
		portal_start.next_area = portal_lv11
	elif [16,17,18,19,20].has(LevelServer.level):
		portal_start.next_area = portal_lv16
	elif [21,22,23,24,25].has(LevelServer.level):
		portal_start.next_area = portal_lv21
	elif [26,27,28,29,30].has(LevelServer.level):
		portal_start.next_area = portal_lv26

#怪物生成
func monsterCreate():
	# 联机：只有房主决定怪物何时、在哪儿生成，客户端等房主广播。
	# 两端都跑各自的随机数会让怪物位置与数量对不上。
	if Net.is_multiplayer_active():
		if Coop.is_host():
			Coop.spawn_monster(COOP_MONSTER_TYPE, getPoint(), LevelServer.getLevelMonsterData())
		return
	var ins = monster_pre.instantiate()
	ins.global_position = getPoint()
	ins.setData(LevelServer.getLevelMonsterData())
	ins.setDeathCallBack(self.onMonsterDeath)
	monster_root.add_child(ins)

#怪物死亡
func onMonsterDeath(monster_ins):
	LevelServer.level_info.kill += 1
	if randi() % 3 <= 1:
		_spawn_gold_at(monster_ins.global_position)
	kill_playr.play()


# 掉落一枚金币。
# 联机：只有房主决定掉不掉、掉在哪，其余端由 CoopSession 复制出来；
# 各端各自跑随机数的话，队友看到的掉落会完全不一样。
func _spawn_gold_at(drop_position: Vector2) -> void:
	if Net.is_multiplayer_active():
		if Coop.is_host():
			Coop.spawn_pickup(COOP_PICKUP_GOLD, drop_position)
		return
	var ins = gold.instantiate()
	ins.global_position = drop_position
	ins.setGiveCallBack(func onGive():
		LevelServer.level_info.gold += 1)
	monster_root.add_child(ins)
