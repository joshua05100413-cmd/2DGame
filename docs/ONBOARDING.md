# 新队友上手指引

从零到「能在自己机器上跑起来、能和人联机、能提 PR」，大约 20 分钟。

仓库：<https://github.com/joshua05100413-cmd/2DGame>

---

## 0. 先看这一条：代码在哪个分支

> **多人联机的全部改动都在 `feature/multiplayer` 分支上，`main` 还没有。**
>
> `main` 目前是上游原作者的代码（带一个上游的合并提交），**没有**联机层、
> 没有大厅、没有 `autoload/net/`。如果你 clone 完直接跑，看到的会是单机版本。

所以**先切分支**：

```bat
git clone https://github.com/joshua05100413-cmd/2DGame.git
cd 2DGame
git checkout feature/multiplayer
```

---

## 1. 拿到仓库写权限

这一步只有仓库拥有者能做，需要你的 **GitHub 用户名**。

**做法（推荐，内部队友）** —— 仓库拥有者操作：

1. 打开 <https://github.com/joshua05100413-cmd/2DGame/settings/access>
2. **Add people** → 输入对方的 GitHub 用户名
3. 权限选 **Write**（能推分支、开 PR；不能改仓库设置）
4. 对方会收到邮件邀请，**点接受**才算生效

接受之后就能直接 `git push` 到自己开的分支了。

**另一种（外部贡献者）**：不用加 collaborator，直接 Fork → 改 → 发 PR。

> 注意：**不要**给 `main` 开直推。见第 6 节的流程。

---

## 2. 装 Godot 4.4.stable

必须是 **4.4.stable**，不要用 4.3 或 4.5 打开本项目（4.5 会把 `project.godot`
重写成新格式，污染 diff）。

下载：<https://github.com/godotengine/godot/releases/tag/4.4-stable>
选 `Godot_v4.4-stable_win64.exe.zip`，解压到任意位置。

然后告诉验证脚本它在哪 —— 打开 `tools/verify.bat`，第 50 行左右：

```bat
set "GODOT_EXE=D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe"
```

改成你自己的路径。**这一行不要提交**（它是本机路径，改了会互相冲突），
如果改了记得 `git checkout tools/verify.bat` 再提交。

---

## 3. 跑第一次验证

**必须从 `cmd` 里跑，不要从 PowerShell 跑。**

```bat
tools\verify.bat 0 all
```

第一次会自动导入资源（几十秒到几分钟）。看到这一行才算成功：

```
RESULT: PASS - all headless suites passed
```

> **这就是你的基线。** 全绿再往下走；不绿先别改代码，把输出发出来一起看。
>
> 为什么不能用 PowerShell：Godot 是 GUI 子系统程序，PowerShell 调用它时
> 不等待、还会丢掉 stdout，你会看到一个「瞬间返回、什么都没有」的假结果。

顺带一提，`--import` / 关编辑器时报崩溃（退出码非 0）是**本仓库原有的**
Godot 4.4 无头编辑器退出问题，与本项目代码和 Steam 都无关（把扩展整个移除
后一样崩）。`verify.bat` 的 import 模式按产物判定，所以不受影响，不用管。

---

## 4. 打开编辑器跑一局单机

1. Godot 4.4 → **导入** → 选 `project.godot`
2. 第一次打开会导入资源，等它跑完
3. 按 <kbd>F5</kbd> 运行

单机应该能走、能开枪、能打怪、怪掉金币、能进传送门。
**单机坏了先别测联机。**

---

## 5. 两个人的联机测试

### 5.1 先做零成本的：ENet 直连

这一步**在同一台电脑上双开就能测**，不需要第二个人，也不需要 Steam。
先用它确认联机层是好的：

```bat
:: 第一个窗口
set APPDATA=D:\2DGame\_userdata\inst_a
"D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe" --path D:\2DGame
```
```bat
:: 另开一个 cmd，第二个窗口
set APPDATA=D:\2DGame\_userdata\inst_b
"D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe" --path D:\2DGame
```

`APPDATA` 隔离是为了让两个实例的存档和日志互不覆盖 —— 不隔离的话两边会抢
同一个日志文件，排查时看到的是别人的日志（我们踩过）。

然后：两边都点 **联机** → A 点 **开房** → B 填 `127.0.0.1` 点 **加入** →
两边都 **返回** → **房主**点 **开始游戏**（客户端会自动跟着进）。

逐项验收清单在 [`TESTING.md`](TESTING.md) 第 3 节。

### 5.2 再跨机器：局域网 / 虚拟局域网

开房后大厅状态栏会直接写出房主该报的地址：

```
已开房 10.236.7.166:27015 ｜ 本机双开填 127.0.0.1（另有 2 个网卡地址）
```

把**最前面那个地址**报给对方。跨网络（各自在家）ENet 直连不通 —— 那是 NAT 的
问题，不是 bug；要么双方装个虚拟局域网（Tailscale / ZeroTier），要么走 Steam。
详见 [`TESTING.md`](TESTING.md) 第 4 节。

### 5.3 最后才是 Steam P2P

> ⚠️ **Steam 联机需要两个不同的 Steam 账号。**
> 同一台电脑双开时两个实例共用一个 Steam 客户端会话，`getSteamID()` 返回同一个
> 值，房主和客户端会撞成同一个 peer，握手没有意义。
> **一台电脑是测不了 Steam 路径的。**

装扩展（一条命令，约 26 MB，不需要管理员）：

```bat
tools\setup_steam.bat
```

然后两人都启动并登录 Steam → 游戏里「联机」→ 后端选 **Steam P2P**
（选中时才会初始化 Steam，状态栏会显示「Steam 已就绪」）→
房主开房，把状态栏里的 **64 位 SteamID** 发给对方 → 对方填进地址栏点加入。

那一串数字在 Steam 界面上是找不到的（个人资料页只有好友代码或自定义 URL），
所以必须由开房的一端报出来。

完整验收清单和排查表：**[`STEAM_SETUP.md`](STEAM_SETUP.md)**。

---

## 6. 日常开发流程

```bat
git checkout feature/multiplayer
git pull
git checkout -b fix/lobby-something      :: 短分支，1-3 天
:: ...改代码...
tools\verify.bat 0 all                   :: 提之前必须本地全绿
git add -A
git commit -m "fix(lobby): ..."
git push -u origin fix/lobby-something
```

然后在 GitHub 上开 PR 到 `feature/multiplayer`。

- 分支命名：`feat/` `fix/` `net/` `ui/` `docs/` `chore/`
- 提交信息用 Conventional Commits 前缀
- **一个提交只做一件事**
- PR 里写清楚：改了什么、为什么、**怎么验证的**（贴 `verify` 输出）
- 合并用 **Squash and merge**

细节看 [`../CONTRIBUTING.md`](../CONTRIBUTING.md)。

---

## 7. 新队友最容易踩的七个坑

按踩到的概率排序：

1. **从 PowerShell 跑 `verify.bat`** → 假结果（不等待、丢输出）。**用 `cmd`。**
2. **在 `main` 上找联机代码** → 没有。切 `feature/multiplayer`。
3. **用 Godot 4.5 打开项目** → `project.godot` 被重写成新格式，diff 一片红。
4. **想把 `addons/godotsteam/` 提交进去** → 不用提交，它已被 `.gitignore`，
   用 `tools\setup_steam.bat` 装。提交二进制会让 Linux CI 直接红。
5. **两个窗口共用同一个 `--log-file`** → 日志互相覆盖，看到的是别人的。
   用 `APPDATA` 隔离（见 5.1）。
6. **在游戏代码里直接 `new ENetMultiplayerPeer()` 或调 `Steam`** →
   破坏「换后端不改玩法」的前提。只准通过 `Net` / `Coop`。
7. **写 `var x := <Variant 表达式>`** → 本项目把「从 Variant 推断类型」的警告
   **当作错误**，会直接编译失败。用 `var x: Variant = ...`。

---

## 8. 绝对不要做的事

- **不要引入任何 Steam 模拟器 / DRM 绕过补丁**（Goldberg、SmartSteamEmu、
  CreamAPI、以及各种「盗版游戏联机补丁」）。
  理由有两条，第二条更实际：它们替换 `steam_api64.dll` 并伪造所有权校验，
  于是 `getSteamID()` / `getPersonaName()` / `ISteamNetworkingSockets`
  **全部变成假实现** —— 你要测的东西被替换掉了，真机问题只会更晚暴露。
  测试用 Valve 官方公开的测试 AppID **480 (Spacewar)**，
  `steam_appid.txt` 已经指向它。
- **不要把构建产物提交进去**（`Game.exe` / `*.pck` / `export/`）。
  仓库历史里曾经有一个 100 MB 的 `Game.exe`，为了瘦身已经重写过历史。
- **不要碰历史重写**。本地为了瘦身删过 remote-tracking 引用，别去 `gc` 或者
  重新整理历史，会和其他人的 clone 冲突。

---

## 9. 遇到问题先看哪里

| 现象 | 先看 |
| --- | --- |
| `verify` 挂了 | 输出里的 `[FAIL]` 行 + `_userdata/reports/*.log` |
| 不知道怎么实际跑起来 / 怎么双开 | [`TESTING.md`](TESTING.md) |
| 联机看不到队友 / 状态不同步 | `docs/MULTIPLAYER_PLAN.md` §4-§6（权威模型 + 踩过的坑） |
| Steam 相关问题 | [`STEAM_SETUP.md`](STEAM_SETUP.md) §4 排查表 |
| 想知道哪些**还没**同步 | `docs/MULTIPLAYER_PLAN.md` 末尾的清单 |
| 想确认某次 CI 为什么红 | <https://github.com/joshua05100413-cmd/2DGame/actions> |

---

## 10. 一分钟速查

```bat
git clone https://github.com/joshua05100413-cmd/2DGame.git
cd 2DGame
git checkout feature/multiplayer
:: 改 tools\verify.bat 里的 GODOT_EXE
tools\verify.bat 0 all          :: 必须全绿
tools\verify.bat 300 game       :: 真实主场景冒烟
tools\setup_steam.bat           :: 只在要测 Steam 时装
```
