# 联机化改造 — 技术现状与决策记录

> 本项目基于 [SakuyaCN/TowDownGame](https://github.com/SakuyaCN/TowDownGame)（Godot 俯视角 2D 射击 roguelite，Steam 上名为 "Don't Stop"）。
> 目标：**合作生存联机**，传输层可插拔（先 ENet，后 Steam P2P）。

## 1. 本机环境

| 项 | 值 |
| --- | --- |
| 引擎 | Godot 4.4.stable (`D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe`) |
| 项目声明版本 | 4.2（`project.godot` 的 `config/features`） |
| 渲染 | forward_plus |
| ENet / MultiplayerAPI / MultiplayerSpawner / MultiplayerSynchronizer | 全部可用 |

## 2. 沙箱相关的"坑"（重要，否则会误判为项目 bug）

1. **Godot 在默认 `%APPDATA%` 下会崩溃。**
   沙箱不允许写 `%APPDATA%\Godot\app_userdata\<项目>`，Godot 在
   `ERROR: Could not create directory: 'user://logs'` 之后直接 `signal 11`。
   → `tools/verify.bat` 会把 `APPDATA` 重定向到 `<项目>\_userdata`。
   这是环境问题，**不是项目问题**。

2. **Godot 的输出在这个沙箱里无法用管道/变量捕获。**
   把输出赋给变量得到 **0 行**，会静默制造“假 PASS”。
   `Start-Process -RedirectStandardOutput` 被沙箱拒绝。
   → 审计改为读取 Godot 自己的 `user://logs/godot.log`。

3. **PowerShell 脚本被禁用**，且嵌套 `powershell -File` 不可靠。
   → 验证入口用 `.bat`。

4. `--import` 结束时也会 `signal 11`，但**资源导入本身是成功的**
   （`.godot/imported` 生成 2000+ 文件）。属于 Godot 退出阶段的崩溃。

## 3. 已修复的既有问题

| 文件 | 问题 | 处理 |
| --- | --- | --- |
| `addons/scene_manager/SceneManager.gd` | `_set_singleton_entities()` 对 `_current_scene` 解引用，autoload 阶段为 `null` → `SCRIPT ERROR: Cannot call method 'get_tree' on a null value` | 加空值回退到 `get_tree()` |
| `ui/widgets/Crosshair.gd` | `@tool` 脚本在编辑器里 `_ready()` 访问 `Utils.onGameStart` 失败 → `SCRIPT ERROR` | 编辑器内直接 return，并先检查 signal 是否存在 |

## 4. GodotSteam 扩展：当前不可用（已确认）

仓库自带的 `addons/godotsteam/` 是**为旧版 Godot 构建的 GDExtension**，有两个问题：

1. `.gdextension` 缺少 Godot ≥ 4.2 必需的 `configuration/compatibility_minimum`
   → 报 `GDExtension configuration file must contain a "configuration/compatibility_minimum" key`。
2. 补上该键之后，加载 DLL 会让 Godot 4.4 **直接崩溃**（GDExtension API 版本不匹配）。

结论：**这份自带的 Steam 扩展无法在 4.4 上使用**，必须换成对应版本。
可用替代版本：
- [GodotSteam GDExtension 4.17.1（Godot 4.4+ / Steamworks 1.63）](https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.17.1-gde)
- [GodotSteam GDExtension 4.16.2（Godot 4.4+）](https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.16.2-gde)
- [Godot 资源库条目](https://godotengine.org/asset-library/asset/2445)

因此架构上 **Steam 只作为可选传输后端**：运行时先探测
`Engine.has_singleton("Steam")`，不可用就优雅降级，绝不让引擎崩溃。

## 5. 验证方式

```bat
tools\verify.bat                 :: 驱动主场景跑 300 帧，有错误则 FAIL
tools\verify.bat 60 selftest     :: 故意的错误，必须 FAIL（证明审计有效）
tools\verify.bat 300 game        :: 直接跑真实主场景
```

`selftest` 是用来防止“假 PASS”的：它注入一条 `SCRIPT ERROR`，如果验证脚本仍然报 PASS，
说明审计逻辑坏了。

## 6. 架构设计（进行中）

- **权威模型**：房主（Host）权威 + 客户端本地预测。
  - 怪物、掉落、关卡进程、伤害结算 → 房主权威
  - 本地玩家移动/瞄准/开火 → 客户端本地即时响应，上报房主校验
- **传输层抽象**：`NetworkTransport` 基类 + `ENetTransport` / `SteamTransport` 实现。
- **全局状态**：`PlayerData` / `Utils` / `LevelServer` 目前是单例全局状态，
  多人化时需要区分“本地玩家数据”与“房间共享状态”。
