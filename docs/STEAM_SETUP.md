# Steam P2P 真机联机验证

本文档面向**装了 Steam 客户端的机器**，目标是把 `SteamTransport` 从
「代码写完、无头可验证」推进到「真机跑通 P2P 握手」。

无头 CI 覆盖不到真实 Steam 网络（中继、NAT 穿透、SteamID ↔ peer id 映射），
所以这一步必须人工做。

---

## 0. 先明确两件事

### 0.1 用 Valve 官方的测试 AppID 480，不要用别人的 AppID

`steam_appid.txt` 现在写的是 **480（Spacewar）**。
这是 Valve 为**所有开发者**提供的公开测试 AppID，Steamworks 的 P2P、中继、
大厅等功能都能在它上面真跑。这是行业标准做法，不需要任何额外授权。

> 这个文件之前写的是 `2153420`，那是上游商业游戏《Don't Stop》的上架 AppID。
> 用别人的 AppID 做联机是不对的，已经在提交里改掉了。

等你们自己的游戏上架时，把它换成你们自己的 AppID 即可。

### 0.2 不要用 Steam 模拟器 / DRM 绕过补丁

Goldberg、SmartSteamEmu、CreamAPI 这类工具替换 `steam_api64.dll` 并伪造所有权
校验。本项目不使用它们，原因有两个：

1. 那是绕过 Steam 授权校验，不做。
2. **技术上它会把你们要测的东西替换掉** —— `Steam.getSteamID()`、
   `getPersonaName()`、`ISteamNetworkingSockets` 全部变成假实现。
   你们测的就不再是真实 Steam 路径，真机问题只会更晚暴露。

用 AppID 480 走的是**官方真实路径**，更省事也更可信。

---

## 1. 前置条件

- [ ] Steam 客户端已安装并**已登录**
- [ ] Godot **4.4.stable**（本项目声明版本）
- [ ] 从 `addons/godotsteam/` 的 `.gdignore` 说明里确认当前扩展已被隔离

---

## 2. 安装 Godot 4.4 兼容的 GodotSteam 扩展

仓库自带的 `addons/godotsteam/` 是为**旧版 Godot** 编译的，加载它会直接让
Godot 4.4 段错误，因此已被 `.gdignore` 隔离。必须换成 4.4+ 的构建。

1. 下载（二选一，后者更旧）：
   - <https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.17.1-gde>
   - <https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.16.2-gde>

2. 解压后，把对应平台的二进制覆盖到 `addons/godotsteam/`：
   - Windows：`win64/godotsteam.dll`、`win64/steam_api64.dll`
   - Linux：`linux/libgodotsteam.so`、`linux/libsteam_api.so`
     （历史里为了瘦身删掉了 linux/osx 的旧二进制，需要重新放进来）

3. **删除 `addons/godotsteam/.gdignore`**。

4. 用 Godot 编辑器打开项目一次，让引擎重建 `.godot/extension_list.cfg`
   （它记录要加载哪些 `.gdextension`）。

5. 确认扩展真的加载了，任选一种：
   - 编辑器 → 项目 → 工具 → 应该有 Steam 相关输出；
   - 或者跑下面这条命令，它会在日志里打印探测结果：

     ```bat
     tools\verify.bat 0 steam
     ```

     扩展**不可用**时日志里会有：
     `[steam] 真实探测结果：未检测到 Steam 单例…`
     扩展**可用**时则是：`[steam] 本机检测到 GodotSteam 扩展，跳过降级断言`

> ⚠️ 如果删掉 `.gdignore` 之后 Godot 一启动就 `signal 11`，说明拿到的扩展
> 仍然不兼容。恢复 `.gdignore`，确认下载的是 **GDExtension**（不是 GDNative
> 或 module 构建）且标称支持 Godot 4.4。

---

## 3. 跑联机

1. 确保 **Steam 客户端正在运行并已登录**。
2. 启动游戏（编辑器里按 F5，或运行导出后的可执行文件）。
   注意：可执行文件必须和 `steam_appid.txt` 在同一目录。
3. 主菜单 → **联机** → 传输后端选 **Steam P2P**。
4. 房主点「开房」。加入方需要填**房主的 64 位 SteamID**
   （在 Steam 客户端个人资料页 URL 里，或 `Steam.getSteamID()` 的返回值）。
5. 双方都能在大厅的房间成员列表里看到对方即握手成功。

---

## 4. 验证清单

按顺序确认，第一个失败的地方就是问题所在：

| # | 检查点 | 怎么看 |
| --- | --- | --- |
| 1 | 扩展已加载 | `Engine.has_singleton("Steam")` 为 true；`tools\verify.bat 0 steam` 的输出 |
| 2 | 后端可用 | 大厅里「Steam P2P」**没有**「（不可用）」后缀 |
| 3 | 开房成功 | 大厅状态显示「已开房，等待队友加入」 |
| 4 | 中继就绪 | 日志无 `InitRelayNetworkAccess 报告失败` 警告 |
| 5 | 握手成功 | 大厅状态显示「已发起连接…」后在成员列表里出现对方 |
| 6 | 名单一致 | 两端看到的成员数相同、昵称正确 |
| 7 | 世界复制 | 进入关卡后能看到对方的角色移动，怪物两端都在 |

第 5 步之后的问题属于 `CoopSession` 的复制问题，和无头 `coop` 套件覆盖的是
同一套协议；先跑 `tools\verify.bat 0 coop` 排除协议回归，再怀疑 Steam。

---

## 5. 排查

**「Steam P2P（不可用）」**
扩展没被加载。回到 §2 第 3–5 步。最常见的原因是忘了删 `.gdignore`，
或者删了但没让编辑器重建 `.godot/extension_list.cfg`。

**`SteamAPI_Init` 失败 / 单例存在但功能不可用**
Steam 客户端没运行或没登录。GameNetworkingSockets 需要已初始化的 Steam。

**能开房但连不上**
- SteamID 填错（必须是 64 位数字，不是好友代码、不是自定义 URL 名）。
- 双方不在同一个 Steam 下载区时可能走不同中继，稍等重试。
- 检查日志里有没有 `连接 Steam 主机 ... 失败`。

**大厅一直停在「已发起连接」**
`SteamTransport` 的握手超时是 8 秒（`CONNECT_TIMEOUT_SEC`）。超时后状态会变
`FAILED` 并在大厅显示原因。如果一直不超时，说明 `poll()` 没被驱动到 ——
检查 `NetworkManager._process` 是否在跑（节点 `process_mode` 是 `ALWAYS`）。

**引擎一启动就 signal 11**
拿到的扩展仍然不兼容（见 §2 的警告框）。恢复 `.gdignore` 后先确认
`tools\verify.bat 300 game` 能过，再排查扩展。

---

## 6. 代码在哪

不需要为了接 Steam 改任何游戏逻辑：

| 文件 | 作用 |
| --- | --- |
| `autoload/net/SteamTransport.gd` | Steam 后端实现；运行时探测扩展，缺失时优雅降级 |
| `autoload/net/TransportFactory.gd` | 后端枚举与可用性报告，大厅据此渲染下拉框 |
| `ui/LobbyUI.gd` | 后端选择、地址/端口输入；Steam 模式下地址栏填 SteamID |
| `autoload/net/NetworkManager.gd` | 会话生命周期；**不硬编码 peer id 1**，因为 Steam 下房主 id 由 SteamID 派生 |
| `autoload/net/CoopSession.gd` | 玩法复制，与后端无关 |

`SteamTransport` 有三个注入点（`_steam_override` / `_peer_factory` /
`_peer_invoke`），无头测试靠它们在**没有扩展**的环境里也能把状态机、超时、
参数传递真跑一遍。真机调试时也可以用它们把可疑调用打出来。
