extends RefCounted
class_name CoopWorld
## 一场关卡里用于联机复制的「世界上下文」。
##
## 关卡场景在 _ready() 里构造它并交给 Coop.attach_world()，从而把
## 「往哪儿放玩家 / 往哪儿放怪物 / 用什么资源造节点」告诉会话层。
## 关卡场景卸载时调用 Coop.detach_world()。
##
## 为什么要工厂函数而不是写死资源路径
##   1. 单机与联机走同一套生成流程，只是工厂不同。
##   2. 无头测试可以注入极简的替身节点，不必启动完整玩法。
##   3. Steam 版 / 打包版可以换资源而不动会话层。

## 玩家节点挂载点（每个 peer 一个节点）。
var player_root: Node2D = null
## 怪物节点挂载点。
var monster_root: Node2D = null
## 联机时新玩家的出生坐标。
var spawn_position := Vector2.ZERO

## 造「本机玩家」的工厂：带输入、绑定 PlayerData 与 Utils.player。
## 返回 null 表示本端不需要本地玩家（例如专用服务器）。
var local_player_factory: Callable = Callable()
## 场景里已经摆好的本地玩家节点（可选）。
## Town.tscn 把 Hero 直接实例化在 PlayerRoot 下，这时不必再造一个，
## 把这个现成节点交给会话层复用即可；用过一次就置空。
var local_player_node: Node2D = null
## 造「其他玩家代理」的工厂：只做表现，不碰全局单例。
var remote_player_factory: Callable = Callable()
## 怪物类型名 -> 造怪物的工厂 Callable。类型名在网络上传输，所以要稳定。
var monster_factories: Dictionary = {}
## 掉落物挂载点。为空时回退到 [member monster_root]（原版就是挂在怪物容器下的）。
var pickup_root: Node2D = null
## 掉落物类型名 -> 造掉落物的工厂 Callable。
var pickup_factories: Dictionary = {}
## 表现子弹工厂：接收 (shooter_peer: int, from: Vector2, direction: Vector2, speed: float)。
## 由场景自己创建并挂载节点（原版子弹是挂在场景树根下的）。
## 为空表示不做弹道表现，游戏照常运行。
var shot_visual_factory: Callable = Callable()


## 便捷构造：只填必填项。
static func create(p_player_root: Node2D, p_monster_root: Node2D, p_spawn: Vector2) -> CoopWorld:
	var world := CoopWorld.new()
	world.player_root = p_player_root
	world.monster_root = p_monster_root
	world.spawn_position = p_spawn
	return world


## 注册一种怪物的工厂。
func with_monster(monster_type: String, factory: Callable) -> CoopWorld:
	monster_factories[monster_type] = factory
	return self


## 注册一种掉落物的工厂。
func with_pickup(pickup_type: String, factory: Callable) -> CoopWorld:
	pickup_factories[pickup_type] = factory
	return self


## 掉落物应该挂在哪个容器下。
func pickup_container() -> Node2D:
	if is_instance_valid(pickup_root):
		return pickup_root
	return monster_root


## 注册表现子弹工厂。
func with_shot_visual(factory: Callable) -> CoopWorld:
	shot_visual_factory = factory
	return self


## 设置玩家工厂。
func with_players(local_factory: Callable, remote_factory: Callable) -> CoopWorld:
	local_player_factory = local_factory
	remote_player_factory = remote_factory
	return self


## 上下文是否可用（容器都还在树里）。
func is_valid() -> bool:
	return is_instance_valid(player_root) and is_instance_valid(monster_root)


func describe() -> String:
	return "CoopWorld(players=%d monsters=%d types=%s)" % [
		0 if player_root == null else player_root.get_child_count(),
		0 if monster_root == null else monster_root.get_child_count(),
		str(monster_factories.keys()),
	]
