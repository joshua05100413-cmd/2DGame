# 联机化改造 — 技术现状与决策记录

> 本项目基于 [SakuyaCN/TowDownGame](https://github.com/SakuyaCN/TowDownGame)
> （Godot 俯视角 2D 射击 roguelite，Steam 上名为 "Don't Stop"）。
> 目标：**合作生存联机**，传输层可插拔（先 ENet，后 Steam P2P）。

---

## 0. 四阶段完成情况

| 阶段 | 内容 | 状态 | 无头验证 |
| --- | --- | --- | --- |
| 1 | 升级并稳定到 Godot 4.4，修复启动/导入崩溃 | 完成 | `compile` / `driver` / `game` |
| 2 | 抽象可插拔网络传输层 | 完成 | `net`（39 项） |
| 3 | ENet 房主/直连合作生存（复制、同步、大厅） | 完成 | `coop`（50 项）/ `lobby`（26 项）/ `coopgame`（29 项） |
| 4 | 预留并接入 Steam P2P 后端 | 完成（真机待验） | `steam`（39 项） |

一条命令跑完全部：`tools\verify.bat 0 all`

---

## 1. 本机环境

| 项 | 值 |
| --- | --- |
| 引擎 | Godot 4.4.stable (`D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe`) |
| 项目声明版本 | 4.4（`project.godot` 的 `config/features`） |
| 渲染 | forward_plus |
| ENet / MultiplayerAPI / MultiplayerSpawner / MultiplayerSynchronizer | 全部可用 |
| GodotSteam GDExtension | **仓库自带的那份不可用**，见 §5 |

---

## 2. 沙箱相关的"坑"（重要，否则会误判为项目 bug）

1. **Godot 在默认 `%APPDATA%` 下会崩溃。**
   沙箱不允许写 `%APPDATA%\Godot\app_userdata\<项目>`，Godot 在
   `ERROR: Could not create directory: 'user://logs'` 之后直接 `signal 11`。
   → `tools/verify.bat` 会把 `APPDATA` 重定向到 `<项目>\_userdata`。

2. **Godot 的 win64 可执行文件是 GUI 子系统程序。**
   PowerShell 的 `&` 调用**不会等待它结束**，stdout 也会整段丢失，
   这会静默制造"假 PASS"。`cmd` 会等待，所以验证入口必须放在 `.bat` 里。

3. **`tools/verify.bat` 必须保持纯 ASCII。**
   cmd 用 OEM 代码页（本机 936）读取 .bat，而文件是 UTF-8。
   中文注释会被拆成乱码并**破坏批处理结构** —— 曾经因此出现
   "bat 报 PASS 但实际上一个测试都没跑"的情况。

4. `--import` 结束时也会 `signal 11`，但**资源导入本身是成功的**。
   属于 Godot 退出阶段的崩溃，`verify.bat` 的 `import` 模式会容忍它。

5. **崩溃会留下 `.recovery_mode_lock`**，Godot 之后会以恢复模式启动并
   静默跳过脚本执行。`verify.bat` 每次运行前会清掉它。

---

## 3. 阶段一：Godot 4.4 稳定性

### 3.1 启动崩溃的真正根因

**`addons/godotsteam/godotsteam.gdextension` 会让 Godot 4.4 在启动时崩溃。**

这个扩展是为更老的 Godot 编译的。Godot 会把 `res://` 下发现的每个
`*.gdextension` 写进 `.godot/extension_list.cfg`，并在**引擎启动早期**
（`WorkerThreadPool` 初始化之后、任何游戏代码执行之前）加载它们。
加载那个陈旧的 DLL 的结果是：

```
CrashHandlerException: Program crashed with signal 11
```

于是**游戏、编辑器、任何 `--script` 都起不来**，而且日志文件根本来不及写，
表现为"没有任何输出"。

之前的改动（从 `[editor_plugins]` 移除、补上
`configuration/compatibility_minimum`）都不够：`extension_list.cfg` 是
**自动扫描**生成的，跟 `[editor_plugins]` 无关。

### 3.2 修复方式

在 `addons/godotsteam/` 下放置 `.gdignore`，让资源扫描器整个忽略该目录：

```
addons/godotsteam/.gdignore
```

这样既保留了原始二进制与启用说明（文件里写清了替换步骤），又保证引擎
永远不会去碰它们。删掉 `.godot/extension_list.cfg` 后重建导入缓存即可。

### 3.3 其它已修复项

| 文件 | 问题 | 处理 |
| --- | --- | --- |
| `shader/SmoothPixel.shader` | Godot 3 时代的 `.shader` 扩展名，Godot 4 没有对应加载器；且内容与 `game/map/test.gdshader` 重复、无人引用 | 删除（`SmoothPixel.tres` 已指向 `game/map/test.gdshader`） |
| `game/monster/BaseMonster.gd` | `var navigationAgent2D := NavigationAgent2D.new()` 从未 `add_child`、也从未被调用，退出时导致 `RID allocations of type 'NavAgent' were leaked at exit` | 删除死代码 |
| `addons/scene_manager/SceneManager.gd` | `_set_singleton_entities()` 对 `_current_scene` 解引用，autoload 阶段为 `null` | 加空值回退（更早的提交） |
| `ui/widgets/Crosshair.gd` | `@tool` 脚本在编辑器里访问 `Utils.onGameStart` 失败 | 编辑器内直接 return（更早的提交） |

### 3.4 验证

- `tools\verify.bat 0 compile` —— 遍历 `res://` 下**每一个** `.gd/.tscn/.tres/.gdshader`
  并强制 `load()`，任何解析失败都算失败（230 个资源，0 失败）。
- `tools\verify.bat 300 driver` —— 驱动真实主场景跑 300 帧。
- `tools\verify.bat 300 game` —— 直接运行真实主场景。

---

## 4. 阶段二：可插拔网络传输层

### 4.1 结构

```
autoload/net/
  NetworkTransport.gd   抽象基类：状态机 + peer 事件 + MultiplayerAPI 注入点
  ENetTransport.gd      ENet 实现（IP 直连，永远可用）
  SteamTransport.gd     Steam P2P 实现（扩展缺失时优雅降级）
  TransportFactory.gd   按后端枚举创建实例、报告可用性
  NetworkManager.gd     自动加载为 `Net`：会话生命周期 + 权威名单 + RPC
  CoopSession.gd        自动加载为 `Coop`：玩法复制（阶段三）
  CoopWorld.gd          关卡场景交给会话层的"复制容器"配置
```

游戏代码只允许访问 `Net` / `Coop`，**绝不直接碰 ENet 或 Steam**。

`autoload` 顺序里 `Net`、`Coop` 必须排在最前：其余脚本（`LevelServer`、
`PlayerServer`、地图脚本、大厅 UI）会以标识符引用它们，而 GDScript 在
**编译期**解析 autoload 名字。

### 4.2 关键设计点

- **后端无关的 peer id。** 房主的 peer id 在 ENet 下是 1，在 Steam 下是由
  SteamID 派生的其它值。所以 `NetworkManager` 里**任何地方都不硬编码 1**，
  一律走 `get_server_id()`。
- **`MultiplayerAPI` 注入。** `NetworkTransport.set_multiplayer_api()` 允许
  一个进程内跑多个互相独立的会话。无头测试正是靠它在**同一棵场景树**里
  同时起房主和客户端，做真实 ENet 回环。
- **peer join/leave 靠轮询差分。** `MultiplayerAPI` 的
  `peer_connected/peer_disconnected` 信号语义在各后端不完全一致，
  所以在基类里对 `get_peers()` 做逐帧差分，ENet 与 Steam 共用一套逻辑。
- **不使用 `Net` 之类的标识符做编译期引用（在会被 `--script` preload 的
  脚本里）。** `--script` 指定的入口脚本在 autoload 注册**之前**就被编译，
  此时 `Identifier not found: Net` 会直接让脚本编译失败。`CoopSession`
  因此改为运行时从 `/root` 查找。

### 4.3 自测暴露并修复的三个真实 bug

| 现象 | 根因 | 修复 |
| --- | --- | --- |
| 每次 `host()/join()` 都报 `Invalid access to property 'multiplayer'` | `SceneTree` **没有** `multiplayer` 属性（只有 `Node` 有） | 改为读 `tree.root.multiplayer` |
| 房主永远不知道有 peer 加入，名单始终是 1 人 | `ENetTransport` 从不发出 `peer_joined` / `peer_left` | 基类新增 `_sync_peer_events()` 逐帧差分 |
| 客户端名字一直是占位的 "Player" | `SceneTree` 先 poll 网络包、后跑节点 `_process`，所以快速的 `_register_player` 会先到，随后 `_on_peer_joined` 把名字**覆盖回占位值** | `_on_peer_joined` 只在该 peer 尚无记录时写入 |

### 4.4 验证

`tools\verify.bat 0 net` —— 39 项检查，包含真实 ENet 回环握手（第 3 帧完成）、
名单双向同步、准备状态、断开收敛，以及 Steam 后端的降级行为。

---

## 5. 阶段三：ENet 合作生存

### 5.1 权威模型

- **房主权威**：怪物生成与移动、伤害结算、关卡进程（关卡号/剩余时间/击杀/金币）。
- **客户端本地预测**：本地角色即时响应输入，位置上报房主。
- **聚合点在房主**：ENet 是星型拓扑，客户端的 `rpc()` 只能到房主，
  客户端之间不直连。所以房主必须把**所有**玩家的位置聚合成一份快照广播
  （20 Hz），否则客户端 A 永远看不到客户端 B 在动。

### 5.2 复制协议（`CoopSession`）

| RPC | 方向 | 说明 |
| --- | --- | --- |
| `_spawn_player` / `_despawn_player` | 房主 → 全体 | 名单变化时生成/移除玩家节点 |
| `_report_player_state` | 客户端 → 房主 | 上报本地位置与朝向 |
| `_sync_player_states` | 房主 → 全体 | 聚合后的全部玩家位置 |
| `_spawn_monster` / `_despawn_monster` | 房主 → 全体 | 怪物生成/移除 |
| `_sync_monster_states` | 房主 → 全体 | 怪物位置 |
| `_report_monster_damage` | 客户端 → 房主 | 上报对怪物的伤害 |
| `_sync_monster_hp` | 房主 → 全体 | 权威血量，客户端影子对齐 |
| `_sync_level_state` | 房主 → 全体 | 关卡共享进度 |
| `_request_world` / `_resync_world` | 客户端 ⇄ 房主 | 中途加入补发 |

**本地玩家 vs 远端代理。** `Utils.player`、`PlayerData` 都是全局单例，
一棵树里放两个完整 `Hero` 会互相覆盖、远端角色还会响应本机按键。
所以远端玩家用轻量的 `RemotePlayer` 代理：复用 `Hero` 的 `SpriteFrames`
保证外观一致，但不碰任何全局状态，也不读输入。

**怪物影子。** 客户端上的怪物 `is_authoritative = false`：不跑 AI、
不本地结算伤害，位置与血量都由房主同步。`Bullet` 命中影子时会走
`BaseMonster.hitFlash` 内部的上报分支，所以**子弹代码本身不需要改**。

### 5.3 关卡场景接入

场景在 `_ready()` 里构造 `CoopWorld` 并交给 `Coop.attach_world()`；
**单机时这一段是空操作，玩法完全不变**。

- `game/map/mapTown/Town.gd`：复用场景里预置的 Hero 作为本机玩家
  （`CoopWorld.local_player_node`），怪物生成改走 `Coop.spawn_monster`。
- `game/map/SnowWorld/SnowWorld.gd` + `MonsterBuilder.gd`：同上，怪物类型 `ghoul`。
- `autoload/server/PlayerServer.gd`：联机时不再各自造玩家。
- `autoload/server/LevelServer.gd`：客户端不推进计时，只消费房主广播的状态。

> 注意：场景判断"是否联机"用的是 `Net.is_multiplayer_active()`，
> **不是** `Coop.is_active()` —— 后者要求世界已经挂载，在 `_ready()` 里
> 永远是 false。

### 5.4 大厅 UI

`ui/LobbyUI.gd`（纯代码构建，避免手改 600+ 行的 `ControlUI.tscn`），
由 `ui/MainUI.gd` 在主菜单里插入的「联机」按钮打开。功能：后端选择
（不可用的后端会列出原因）、昵称、地址/端口、开房/加入/断开、房间成员列表、状态提示。

### 5.5 验证

- `tools\verify.bat 0 coop` —— 50 项：替身节点下的完整复制协议
  （玩家复制、影子怪物、伤害路由、死亡收敛、关卡状态、位置同步、
  中途加入补发、世界卸载）。
- `tools\verify.bat 0 lobby` —— 26 项：大厅构建、后端列表、开房/断开、
  连接失败反馈。
- `tools\verify.bat 0 coopgame` —— 29 项：**真实 `Main.tscn` 作为房主**
  （走 autoload 的 `Net`/`Coop`）+ 轻量客户端，验证场景预置 Hero 被复用、
  `RemotePlayer` 代理生成、真实怪物生成流程走复制、客户端收到影子怪物。

---

## 6. 阶段四：Steam P2P 后端

### 6.1 当前状态

`SteamTransport.gd` 已完整实现房主/加入/断开/轮询/超时/错误信息，
但**默认不可用**：仓库自带的 GodotSteam 扩展是为旧版 Godot 编译的，
加载它会让 Godot 4.4 段错误（§3.1），因此已被 `.gdignore` 隔离。

运行时先探测 `Engine.has_singleton("Steam")` 与
`ClassDB.class_exists("SteamMultiplayerPeer")`，不可用就优雅报告原因并
保留 ENet 可用，**绝不让引擎崩溃**。

### 6.2 如何启用真实 Steam 联机

1. 下载兼容 Godot 4.4 的 GodotSteam GDExtension，例如
   [v4.17.1-gde](https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.17.1-gde)。
2. 替换 `addons/godotsteam/win64/` 下的 DLL。
3. 删除 `addons/godotsteam/.gdignore`。
4. 用编辑器打开项目一次，让 Godot 重建 `.godot/extension_list.cfg`，
   然后确认 `Engine.has_singleton("Steam")` 为 true。

**不需要改任何游戏代码**：大厅会自动把「Steam P2P」标为可用，
`NetworkManager` 会自动使用它。

### 6.3 无头验证做了什么

本机没有 Steam 客户端也没有可用扩展，所以分三层验证：

1. **真实降级路径**：扩展缺失时 `host()`/`join()` 返回错误码、状态为
   `FAILED`、给出可读原因，工厂返回 null 而不是抛异常。
2. **协议逻辑（注入替身）**：`SteamTransport` 有三个注入点
   （`_steam_override` / `_peer_factory` / `_peer_invoke`）。测试用
   `ENetMultiplayerPeer` 顶替 `SteamMultiplayerPeer` 提供真实传输，
   用一个回调接收 `create_host` / `create_client` /
   `get_peer_id_for_steam_id` 调用。于是状态机、握手超时、server id 解析、
   参数传递（virtual port 两端一致、SteamID 正确）都被真正执行到。
3. **可插拔性实证**：同一份 `NetworkManager` 代码换上 `SteamTransport` 后，
   能完成一次完整的连接与名单同步，且 `describe()` 正确显示后端名。

`tools\verify.bat 0 steam` —— 39 项检查。

### 6.4 仍未验证的部分

真实 Steam 网络传输（中继、NAT 穿透、SteamID ↔ peer id 的实际映射）
**必须**在装有 Steam 客户端与兼容扩展的机器上人工验证。
无头测试能覆盖的到此为止，不应被当作真机结论。

---

## 7. 验证入口

```bat
tools\verify.bat                     :: 启动主场景，跑 300 帧
tools\verify.bat 900                 :: 跑 900 帧
tools\verify.bat 300 game            :: 直接运行真实主场景
tools\verify.bat 0   import          :: （重新）导入资源并审计
tools\verify.bat 0   compile         :: 全项目脚本/资源编译检查
tools\verify.bat 0   net             :: 传输层 ENet 回环自测
tools\verify.bat 0   coop            :: 合作复制协议自测
tools\verify.bat 0   lobby           :: 大厅 UI 自测
tools\verify.bat 0   coopgame        :: 真实关卡场景联机集成自测
tools\verify.bat 0   steam           :: Steam 后端降级与协议自测
tools\verify.bat 0   all             :: 依次跑上面全部套件
tools\verify.bat 60  selftest        :: 故意的错误，必须 FAIL（证明审计有效）
```

`selftest` 是用来防止"假 PASS"的：它注入一条 `SCRIPT ERROR`，如果验证脚本
仍然报 PASS，说明审计逻辑坏了。审计同时会检查
`CrashHandlerException` —— 否则一个跑到一半就 `signal 11` 的自测会因为
"没来得及打印任何 FAIL"而被误判成 PASS。

---

## 8. 已知限制与后续工作

**已同步**：玩家位置/朝向、玩家名单与准备状态、怪物生成/位置/血量/死亡、
伤害归属、关卡号/剩余时间/击杀/金币。

**尚未同步**（合作体验可用，但这些内容各端独立）：

- 玩家受伤：房主负责怪物攻击判定，通过 `Coop.apply_player_damage()` 通知
  对应玩家扣血，但怪物目前只攻击房主本地的玩家节点，对远端代理的攻击
  判定还没接。
- 掉落物（金币）、装备、商店、奖励选择：都是各端独立的本地事件。
- 玩家经验与升级：只有击杀者所在端会加经验。
- 开火表现与子弹：子弹是本地生成的，因此队友看不到你射出的子弹
  （伤害结果仍然一致，因为走的是上报-结算）。

**架构上需要注意的**：`Utils.player`、`PlayerData`、`LevelServer` 都是全局
单例，天然假设"只有一个玩家/一份进度"。远端玩家走轻量代理就是为绕开这一点；
如果以后要让远端玩家也拥有完整逻辑（例如显示队友的枪械与技能特效），
需要先把这些单例拆成 per-peer 的数据容器。
