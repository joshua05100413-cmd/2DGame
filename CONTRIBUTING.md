# 协作指南

四个人并行改一个 Godot 项目，最容易坏掉的不是代码本身，而是**互相的假设**：
RPC 的到达顺序、名单什么时候收敛、单机路径有没有被悄悄改坏。
所以本仓库的第一原则是：**任何改动都必须能被无头验证复现**。

---

## 1. 环境

| 项 | 版本 |
| --- | --- |
| Godot | **4.4.stable**（不要用 4.3 或 4.5 打开本项目） |
| GDScript | 项目把「从 Variant 推断类型」等警告**当作错误**，写代码时注意显式标注类型 |

Windows 上 Godot 的安装路径写在 `tools/verify.bat` 的 `GODOT_EXE` 里；
如果不在默认位置，改那一行或把它设成环境变量。

> ⚠️ **不要**打开 `addons/godotsteam/` 里的扩展。
> 它是为旧版 Godot 编译的，加载会让 Godot 4.4 直接段错误（见
> `docs/MULTIPLAYER_PLAN.md` §3）。该目录已被 `.gdignore` 隔离，保持原样。

---

## 2. 跑验证

Windows：

```bat
tools\verify.bat 0 all
```

Linux / macOS / CI：

```bash
GODOT_EXE=/path/to/godot tools/verify.sh 0 all
```

单独跑某一套：

```bat
tools\verify.bat 0 compile     :: 全项目脚本/资源强制加载
tools\verify.bat 0 net         :: 传输层真实 ENet 回环
tools\verify.bat 0 coop        :: 合作复制协议
tools\verify.bat 0 lobby       :: 大厅 UI
tools\verify.bat 0 coopgame    :: 真实关卡场景联机集成
tools\verify.bat 0 steam       :: Steam 后端降级与协议
tools\verify.bat 300 driver    :: 驱动主场景跑 300 帧
tools\verify.bat 300 game      :: 直接运行真实主场景
```

**提 PR 前必须本地跑过 `all`**，CI 也会跑同一套。

### 「假的绿」是被防着的

`tools\verify.bat 60 selftest` 会故意注入一条 `SCRIPT ERROR`，**必须报 FAIL**。
CI 里也有这一步。如果哪天它变成 PASS，说明审计坏了 —— 那么所有绿色的构建
都不再可信，请优先修验证脚本而不是业务代码。

---

## 3. 分支与提交流程

- `main` 永远是**可运行**的。不直接往 `main` 推。
- 从 `main` 开短分支：`feat/xxx`、`fix/xxx`、`net/xxx`、`ui/xxx`。
  分支生命周期尽量短（1–3 天），减少和别人的冲突面。
- 提交信息用 [Conventional Commits](https://www.conventionalcommits.org/) 前缀：
  `feat:` `fix:` `net:` `ui:` `docs:` `chore:` `test:` `perf:` `refactor:`
- **一个提交只做一件事。** 网络层的改动不要顺手格式化 UI 文件。
- 提 PR 时写清楚：改了什么、为什么、**怎么验证的**（贴 `verify` 的输出）。
- PR 至少一个人 review。涉及 `autoload/net/` 的改动建议两人 review。
- 合并用 **Squash and merge**，保持 `main` 的历史可读。

---

## 4. 模块边界（按这个分工，冲突最少）

| 目录 | 职责 | 建议负责人 |
| --- | --- | --- |
| `autoload/net/` | 传输层、会话生命周期、复制协议 | 网络 |
| `game/hero/` `game/monster/` `game/map/` `autoload/server/` | 玩法与场景接入 | 玩法 |
| `ui/` | 大厅、HUD、表现与反馈 | UI |
| `tools/` `.github/` `export_presets.cfg` | 验证、CI、打包 | 构建 |
| `docs/` | 设计与决策记录 | 所有人 |

**硬规则：**

- 游戏代码**只能**通过 `Net` / `Coop` 访问网络，**永远不要**直接 new
  `ENetMultiplayerPeer` 或调用 `Steam`。这条是「换后端不改玩法」的前提。
- 新增可联网的玩法事件时，先在 `CoopSession` 里加协议方法，再在玩法侧调用。
- 单机路径必须保持可用：所有联机分支都要有 `Net.is_multiplayer_active()` 守卫。

### 改 `autoload/net/` 前请先读

`docs/MULTIPLAYER_PLAN.md` §4–§6 记录了权威模型、RPC 清单，以及几个**已经踩过
的坑**（peer id 不能硬编码 1、`SceneTree` 没有 `multiplayer` 属性、
`_on_peer_joined` 会覆盖刚报到的真名……）。改之前先看，能省几个小时。

---

## 5. 代码规范

- GDScript 用 **Tab** 缩进（`.editorconfig` 已配置）。
- 新脚本请写**中文注释说明「为什么」**，而不是复述代码在做什么。
  本项目里所有非显然的决定都带了原因，请保持这个风格。
- 注释里如果提到某个坑，写清楚**现象 + 根因**，例如：
  ```gdscript
  # SceneTree 本身没有 `multiplayer` 属性（只有 Node 有），必须从 tree root 读。
  # 写成 tree.multiplayer 会在每次 host()/join() 时静默报错。
  ```
- 避免 `var x := <Variant 表达式>`：项目把该警告当错误。
  用 `var x: Variant = ...` 或显式类型。
- 不要新增对 autoload 标识符的**编译期**依赖到会被 `--script` 预加载的脚本里，
  否则会报 `Identifier not found`（原因见 `CoopSession._net()` 的注释）。

---

## 6. 不要提交这些

- 构建产物：`Game.exe`、`*.pck`、`export/`、`exe/`（`.gitignore` 已覆盖）。
  仓库历史里曾经有一个 100 MB 的 `Game.exe`，为了瘦身已经重写过历史，
  请不要再加回来。
- `_userdata/`、`.godot/`（已在 `.gitignore`）。
- **任何 Steam 模拟器 / DRM 绕过补丁**（Goldberg、SmartSteamEmu、CreamAPI 等）。
  我们不做这件事，也不需要：测试 Steam 联机请用 Valve 官方公开的测试 AppID
  **480 (Spacewar)**，`steam_appid.txt` 已经指向它。详见
  `docs/STEAM_SETUP.md`。

---

## 7. 大文件

仓库目前约 45 MB，几乎全是必需的音频、字体和贴图。加新资源前想一想：

- 一张图 / 一段音频超过 1 MB 就先压缩。
- 超过 10 MB 的单个文件请先和大家讨论（Git LFS 还是别放进仓库）。
- 不要提交 `res://` 之外的产物。

---

## 8. 同步上游

本项目 fork 自 [SakuyaCN/TowDownGame](https://github.com/SakuyaCN/TowDownGame)
（GPL）。上游的修复值得吸收：

```bat
git fetch upstream
git log --oneline upstream/main ^main     :: 看上游有什么新东西
git cherry-pick <commit>                  :: 按需挑，不要整分支合并
```

注意：本地仓库为了瘦身删掉了指向旧历史的 remote-tracking 引用。
`git fetch upstream` 会把上游的完整历史（含那个 100 MB 的 `Game.exe`）
重新拉到本地，本地体积会变大 —— 这是可接受的，**推上去的分支仍然是干净的**。
