# 协作指南

**新队友请先看 [`docs/ONBOARDING.md`](docs/ONBOARDING.md)** —— 从 clone 到跑通
联机、到提第一个 PR 的完整步骤都在那里。本文是常驻的规范细节。

四个人并行改一个 Godot 项目，最容易坏掉的不是代码本身，而是**互相的假设**：
RPC 的到达顺序、名单什么时候收敛、单机路径有没有被悄悄改坏。
所以本仓库的第一原则是：**任何改动都必须能被无头验证复现**。

---

## 0. 代码在哪个分支

**多人联机的全部改动都在 `feature/multiplayer` 上，`main` 还没有。**
`main` 目前是上游原作者的代码（带一个上游合并提交），没有联机层、没有大厅、
没有 `autoload/net/`。

```bat
git checkout feature/multiplayer
git pull
```

日常从 `feature/multiplayer` 开短分支；`main` 等 `feature/multiplayer` 稳定
之后整体合并。

---

## 1. 环境

| 项 | 版本 |
| --- | --- |
| Godot | **4.4.stable**（不要用 4.3 或 4.5 打开本项目） |
| GDScript | 项目把「从 Variant 推断类型」等警告**当作错误**，写代码时注意显式标注类型 |

Windows 上 Godot 的安装路径写在 `tools/verify.bat` 的 `GODOT_EXE` 里；
如果不在默认位置，改那一行。**这一行是本机路径，改完不要提交。**

### Steam 扩展

`addons/godotsteam/` **已被 `.gitignore`，不在仓库里**。要测 Steam 联机时用：

```bat
tools\setup_steam.bat
```

它会下载固定版本（4.22.1，兼容 Godot 4.4）并装好，**不要把它提交进去**：

- 完整插件解压后约 92 MB（光 Android 就 33 MB），而仓库本身 45 MB。
- 只提交 win64 更糟：`.gdextension` 按平台列库，运行平台缺库时 Godot 报
  `No GDExtension library found for current OS and architecture`，
  这条 ERROR 会让 **Linux CI 直接失败**（CI 现在根本看不到扩展，这正是它稳定的原因）。
- 仓库里原来那份是给 Godot 4.2 编译的，必须靠 `.gdignore` 隔离才不会让 4.4
  崩溃 —— 这个目录连同那个坑已经一起从仓库里删掉了。
  **现在不要再手动创建 `addons/godotsteam/.gdignore`**，那只会让扩展静默不加载。

> ⚠️ GodotSteam 上游明确**不接受任何 LLM 生成的 issue / patch / PR**。
> 我们只用它 MIT 授权的预编译产物，不向它提交任何东西。

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

想看**怎么实际把游戏跑起来、怎么双开测联机**，看
[`docs/TESTING.md`](docs/TESTING.md) —— 那里有完整的按钮流程和验收清单。

### 「假的绿」是被防着的

`tools\verify.bat 60 selftest` 会故意注入一条 `SCRIPT ERROR`，**必须报 FAIL**。
CI 里也有这一步。如果哪天它变成 PASS，说明审计坏了 —— 那么所有绿色的构建
都不再可信，请优先修验证脚本而不是业务代码。

---

## 3. 分支与提交流程

- `feature/multiplayer` 是当前的集成分支（多人联机都在这）。
- `main` 是上游原作者的代码，**暂时不往里合**，等联机稳定后整体合并。
- 从 `feature/multiplayer` 开短分支：`feat/xxx`、`fix/xxx`、`net/xxx`、`ui/xxx`。
  分支生命周期尽量短（1–3 天），减少和别人的冲突面。
- 提交信息用 [Conventional Commits](https://www.conventionalcommits.org/) 前缀：
  `feat:` `fix:` `net:` `ui:` `docs:` `chore:` `test:` `perf:` `refactor:`
- **一个提交只做一件事。** 网络层的改动不要顺手格式化 UI 文件。
- 提 PR 时写清楚：改了什么、为什么、**怎么验证的**（贴 `verify` 的输出）。
- PR 至少一个人 review。涉及 `autoload/net/` 的改动建议两人 review。
- 合并用 **Squash and merge**。

### 拿到写权限

仓库拥有者在 GitHub 上 **Settings → Collaborators and permissions → Add people**
里加上你的 GitHub 用户名，权限给 **Write**，你接受邮件邀请后即可推送分支。
外部贡献者走 Fork + PR，不需要加 collaborator。

### 推送

日常就一条：

```bat
git push
```

首次推送上游分支：

```bat
git push -u origin feature/multiplayer
```

- `origin` = 本项目仓库，`upstream` = 上游原作者（用于吸收上游修复）。
- 第一次推送时 Git Credential Manager 会弹 GitHub 登录窗，登录一次即可，
  之后凭据会被缓存。

> ⚠️ 本项目的历史被**重写过**（为了从历史里移除一个 100 MB 的 `Game.exe`），
> 所以它和上游不是同一条历史。**不要 `git push --force` 到 `main` 或
> `feature/multiplayer`** —— 已经有多个 clone 了，强推会让别人的仓库错乱。

新队友加入：

```bat
git clone https://github.com/joshua05100413-cmd/2DGame.git
cd 2DGame
git checkout feature/multiplayer
tools\verify.bat 0 all
```

要测 Steam 再加一条 `tools\setup_steam.bat`。完整版见
[`docs/ONBOARDING.md`](docs/ONBOARDING.md)。

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
