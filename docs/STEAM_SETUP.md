# Steam P2P 真机联机

目标：把 `SteamTransport` 从「代码写完、无头可验证」推进到「两个人在 Steam 上真跑一局」。

无头 CI 覆盖不到真实 Steam 网络（NAT 穿透、中继、SteamID ↔ peer id 映射），
所以最后这一步必须人工做。

---

## 0. 先明确三件事

### 0.1 必须准备**两个不同的 Steam 账号**

这是最容易踩的坑，写在最前面：

> **同一台电脑双开没法测 Steam 联机。**
> 两个实例共用同一个 Steam 客户端会话，`Steam.getSteamID()` 返回的是**同一个**
> SteamID。房主和客户端会是同一个 peer，握手毫无意义。

所以 Steam 路径**至少需要两个人**（或者你有第二个 Steam 账号 + 第二台机器 / 沙盒）。
ENet 路径没有这个限制，一台电脑双开就能测，这也是为什么本地快速迭代仍然用 ENet。

### 0.2 用 Valve 官方的测试 AppID 480，不要用别人的 AppID

`steam_appid.txt` 现在写的是 **480（Spacewar）**。
这是 Valve 为**所有开发者**提供的公开测试 AppID，Steamworks 的 P2P、中继、
大厅等功能都能在它上面真跑。这是行业标准做法，不需要任何额外授权。

> 这个文件之前写的是 `2153420`，那是上游商业游戏《Don't Stop》的上架 AppID。
> 用别人的 AppID 做联机是不对的，已经在提交里改掉了。

等你们自己的游戏上架时，把它换成你们自己的 AppID 即可。

### 0.3 不要用 Steam 模拟器 / DRM 绕过补丁

Goldberg、SmartSteamEmu、CreamAPI 这类工具替换 `steam_api64.dll` 并伪造所有权
校验。本项目不使用它们，原因有两个：

1. 那是绕过 Steam 授权校验，不做。
2. **技术上它会把你们要测的东西替换掉** —— `Steam.getSteamID()`、
   `getPersonaName()`、`ISteamNetworkingSockets` 全部变成假实现。
   你们测的就不再是真实 Steam 路径，真机问题只会更晚暴露。

用 AppID 480 走的是**官方真实路径**，更省事也更可信。

---

## 1. 安装扩展（一条命令）

```bat
tools\setup_steam.bat
```

它会：

1. 从 Codeberg 下载固定版本的 GodotSteam GDExtension
   （**4.22.1**，`compatibility_minimum = "4.4"`，对应 Steamworks SDK 1.65）
2. 解压到 `addons/godotsteam/`
3. 删掉可能残留的 `.gdignore`（旧版本靠它把扩展关掉）
4. 删除 `.godot/extension_list.cfg`，让引擎下次重新扫描
5. 自动跑一遍 `tools\verify.bat 0 steam` 确认装好

下载会缓存在 `_userdata/godotsteam-4.22.1-gde.zip`，重跑不用重新下。
脚本不需要管理员权限。

### 为什么扩展不在仓库里

`.gitignore` 里屏蔽了 `addons/godotsteam/`，原因：

- 完整插件解压后约 **92 MB** 预编译二进制（光 Android 就 33 MB），而仓库本身 45 MB。
- **只提交 win64 比两头都糟**：`.gdextension` 是按平台列库的，运行平台缺库时
  Godot 会报 `No GDExtension library found for current OS and architecture`，
  这条 ERROR 会让 **Linux CI runner 上的无头审计直接失败**。
  现在 CI 根本看不到扩展，这正是它稳定的原因。
- 固定版本的下载脚本可复现；提交进来的 DLL 会过期。
  仓库里原来那份是给 Godot 4.2 编译的，必须靠 `.gdignore` 隔离才不会让 4.4 崩溃 ——
  这正是要避开的陷阱。

> ⚠️ 顺带一提：GodotSteam 上游有明确政策**不接受任何 LLM 生成的 issue / patch /
> PR**。我们只是使用它 MIT 授权的预编译产物，不向它提交任何东西。

---

## 2. 跑联机

1. 两台机器都**启动 Steam 并登录**（各自不同的账号）。
2. 两台机器都启动游戏（编辑器里按 F5，或跑导出后的可执行文件）。
   可执行文件必须和 `steam_appid.txt` 在同一目录。
3. 主菜单 → **联机** → 传输后端选 **Steam P2P**。
   选中时游戏才会去初始化 SteamAPI，状态栏会显示「Steam 已就绪」，
   名字输入框会填上你的 Steam 昵称。
4. **房主**点「开房」。状态栏会直接写出房主的 64 位 SteamID：

   ```
   已开房 SteamID 76561198xxxxxxxxx ｜ 把它发给队友，队友填进地址栏
   ```

   **把这串数字复制给队友。** 这一串在 Steam 界面上是找不到的（个人资料页
   只显示好友代码或自定义 URL），所以必须由开房的一端报出来。
5. **客户端**把 SteamID 填进地址栏，点「加入」。
6. 双方都能在大厅的房间成员列表里看到对方即握手成功。

---

## 3. 验证清单

按顺序确认，第一个失败的地方就是问题所在：

| # | 检查点 | 怎么看 |
| --- | --- | --- |
| 1 | 扩展已加载 | `Engine.has_singleton("Steam")` 为 true；`tools\verify.bat 0 steam` 的输出 |
| 2 | 后端可用 | 大厅里「Steam P2P」**没有**「（不可用）」后缀 |
| 3 | Steam 初始化 | 选中 Steam P2P 后状态栏显示「Steam 已就绪」 |
| 4 | 中继就绪 | 日志无 `InitRelayNetworkAccess 报告失败` 警告 |
| 5 | 开房成功 | 状态栏显示「已开房 SteamID …」 |
| 6 | 握手成功 | 客户端加入后，成员列表里出现对方 |
| 7 | 名单一致 | 两端看到的成员数相同、昵称正确 |
| 8 | 世界复制 | 进入关卡后能看到对方的角色移动，怪物两端都在 |

第 6 步之后的问题属于 `CoopSession` 的复制问题，和无头 `coop` 套件覆盖的是
同一套协议；先跑 `tools\verify.bat 0 coop` 排除协议回归，再怀疑 Steam。

---

## 4. 连不上时怎么抓一份能查的日志

**默认日志里什么都没有。** 直接跑游戏只会得到一句「Steam 连接超时」，两边日志都
看不出原因 —— Steam 自己的连接诊断默认是关闭的
（`SteamMultiplayerPeer` 的 `debug_level` 默认是 `NONE`）。

所以联机失败时按这样跑，**两端都要**：

```bat
:: 第一端
set APPDATA=D:\2DGame\_userdata\inst_a
"D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe" --path D:\2DGame -- --net-verbose
```
```bat
:: 第二端（另开一个 cmd，APPDATA 必须不同，否则两个实例的日志会互相覆盖）
set APPDATA=D:\2DGame\_userdata\inst_b
"D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe" --path D:\2DGame -- --net-verbose
```

日志落在各自的：

```
_userdata\inst_a\Godot\app_userdata\Don't Stop\logs\godot.log
_userdata\inst_b\Godot\app_userdata\Don't Stop\logs\godot.log
```

打开 `--net-verbose` 之后会多出这些行，它们就是排查的全部依据：

```
[Steam] 本机 SteamID = 76561199372121221
[Steam] 昵称 = Joshua约书亚
[Steam] 目标 SteamID = 76561199563867700
[Steam] 中继网络状态 = 等待中（2 Waiting）
[Steam] 正在连接 SteamID 76561199563867700，超时 20 秒……
[Steam] 连接中… 剩余 15 秒，中继 等待中（2 Waiting）
```

**怎么读**：

| 看到什么 | 说明 |
| --- | --- |
| 房主端没有 `[Steam] 开房成功` | 房主根本没开成房，客户端连多久都会超时。房主端的状态栏也会有提示 |
| 两端的 SteamID 对不上彼此的地址栏 | 填错了人。房主的 ID 要**从房主自己的状态栏复制**，不要从别处找 |
| 中继一直是「等待中（2 Waiting）」 | Steam 中继还没就绪。多等几秒重试；一直如此就见下一条 |
| 超过 20 秒仍停在 `CONNECTING` | 对方多半没在跑本游戏。确认对方那边**游戏是开着的**（Steam 上应显示「正在玩 Spacewar」） |

> 顺带说明：`steam_appid.txt` 是 **480**，所以两端的 Steam 上都会显示在玩
> **Spacewar**，这是 Valve 给所有开发者用的公开测试 AppID，属于正常现象。

---

## 5. 排查

**「Steam P2P（不可用）」**
把鼠标移到下拉框上，或看状态栏 —— 会给出具体原因，两种最常见：
- `未检测到 Steam 单例：未安装…` → 扩展没装，回去跑 `tools\setup_steam.bat`
- `Steam 客户端未运行或未登录` → 先把 Steam 起起来再选后端

**引擎一启动就 signal 11 / 堆损坏**
历史上出现过一次，根因是**在 `SteamAPI_Init` 之前调用了需要初始化状态的 API**
（`NetworkManager._ready()` 里读了 `getPersonaName()`），日志里只有一行
`Friends class not found, Steam may not be initialized`。
现在所有 Steam 调用都收敛到 `SteamTransport.ensure_steam_ready()` 之后，
`steam_selftest` 有专门的回归断言守着。
如果又出现，先跑 `tools\verify.bat 0 steam` —— 那三条断言会直接指出是哪一步越界。

**开房报 `Invalid call. Expected 1 argument`**
说明 `create_host` 的实参个数又和真实签名对不上了。真实签名是
`create_host(virtual_port)`，**只有 1 个参数**，没有人数上限。
`steam_selftest` 会拿 `ClassDB` 里的真实方法表来交叉核对参数个数，
所以这类错误应该在无头阶段就被挡住。

**能开房但连不上（第一次真机测试最常遇到的）**
先按 **第 4 节**抓两端的 `--net-verbose` 日志，再对着那张表看。按出现频率排：

1. **对方其实没在开房。** 房主端必须有 `[Steam] 开房成功`；没有的话客户端连多久
   都会超时。注意较早的版本 `create_host` 传错了参数，Steam 上**开房一定失败**，
   所以两端代码必须是同一个提交。
2. **SteamID 填错。** 必须是房主**开房后状态栏里显示的那串 17 位数字**。好友代码、
   自定义 URL 名都不行。
3. **对方没在跑这个游戏。** Steam 上要能看到对方「正在玩 Spacewar」。
4. **中继一直没就绪。** 日志里 `中继 等待中（2 Waiting）` 持续到最后就是这种情况，
   稍等重试有时就好。

**大厅一直停在「已发起连接」**
`SteamTransport` 的握手超时是 20 秒（`CONNECT_TIMEOUT_SEC`）。超时后状态会变
`FAILED` 并在大厅显示原因。如果一直不超时，说明 `poll()` 没被驱动到 ——
检查 `NetworkManager._process` 是否在跑（节点 `process_mode` 是 `ALWAYS`）。

**`--import` / 关编辑器时崩溃**
这是**本仓库原有的** Godot 4.4 无头编辑器退出问题，与 Steam 无关 ——
把扩展整个移除后 `--import` 一样崩（实测退出码同为 `0xC0000005`）。
`tools/verify.bat` 的 `import` 模式本来就按**产物是否存在**判定成败，
所以它不受影响。不用管。

---

## 6. 代码在哪

不需要为了接 Steam 改任何游戏逻辑：

| 文件 | 作用 |
| --- | --- |
| `autoload/net/SteamTransport.gd` | Steam 后端实现；探测 / 初始化 / 降级都在这里 |
| `autoload/net/TransportFactory.gd` | 后端枚举与可用性报告，大厅据此渲染下拉框 |
| `ui/LobbyUI.gd` | 后端选择、地址/端口输入；Steam 模式下地址栏填 SteamID |
| `autoload/net/NetworkManager.gd` | 会话生命周期；**不硬编码 peer id 1**，因为 Steam 下房主 id 由 SteamID 派生 |
| `autoload/net/CoopSession.gd` | 玩法复制，与后端无关 |
| `tools/setup_steam.bat` | 安装 / 重装扩展 |
| `tools/diag_env.gd` | 打印 Steam 单例状态和 `SteamMultiplayerPeer` 的真实方法表 |

### 探测 / 初始化 / 使用 三段分离

`SteamTransport` 把 Steam 相关调用分成三层，边界很重要：

1. **`probe_reason()`** —— 无副作用。只问 `Engine.has_singleton("Steam")`、
   `ClassDB.class_exists("SteamMultiplayerPeer")` 和 `isSteamRunning()`。
   大厅每次刷新都会调它，**绝不能在这里初始化 Steam**，否则单机玩家打开一次
   大厅就会把 Steam 拉起来。
   `isSteamRunning()` 映射到 `SteamAPI_IsSteamRunning()`，是可以在 `Init` 之前
   安全调用的自由函数。
2. **`ensure_steam_ready()`** —— 真正调用 `steamInit()`。只在玩家选中 Steam P2P
   或 `host()/join()` 时触发。成功会缓存，**失败不缓存**，这样玩家中途启动
   Steam 之后重试还能成功。
3. **`steam_persona_name()` / `local_steam_id()`** —— 需要初始化状态的取值函数。
   未初始化时安静地返回 `""` / `0`，**绝不**去碰真实 Steam：
   `getPersonaName()` 在未初始化时不是返回空串，而是堆损坏崩溃。

`SteamTransport` 另有三个注入点（`_steam_override` / `_peer_factory` /
`_peer_invoke`），无头测试靠它们在**没有扩展**的环境里也能把状态机、超时、
参数传递真跑一遍。装了扩展之后，`steam_selftest` 还会读取 `ClassDB` 里
`SteamMultiplayerPeer` 的**真实方法表**，逐个核对实参个数 —— 这是唯一能在
无头阶段抓住「参数传多了」这类错误的手段。
