# Godot 2D Town-Down Game

use Godot4

> ## 🚀 新加入的开发者先看这里
>
> **[`docs/ONBOARDING.md`](docs/ONBOARDING.md)** —— 从 clone 到跑通双人联机、
> 到提第一个 PR 的完整步骤（约 20 分钟）。
>
> **两个必须先知道的事：**
>
> 1. **代码在 `feature/multiplayer` 分支上，`main` 还没有。**
>    `git clone` 之后要 `git checkout feature/multiplayer`，
>    否则你看到的是单机版本。
> 2. **验证脚本必须从 `cmd` 跑，不要从 PowerShell 跑** ——
>    Godot 是 GUI 子系统程序，PowerShell 调用它不等待还会丢输出，
>    你会看到一个假的「瞬间通过」。
>
> 一条命令确认环境正常：
>
> ```bat
> tools\verify.bat 0 all
> ```

---
Don't Stop is an exhilarating top-down 2D shooter that melds roguelite elements with a heart-pounding race against time. Dive into a world where every tick of the clock is critical, navigating through relentless challenges and making decisive moves to survive within stringent time limits.

As you battle for survival, confront a myriad of foes and obstacles. Arm yourself with a diverse collection of firearms and weapon enhancements to defeat adversaries. Don't Stop features an extensive selection of guns, each boasting unique traits and tactical applications. Customize and upgrade your weaponry with various attachments to tailor your arsenal for the varied combat situations and enemy encounters.

Experience a fresh adventure every time you play. The game leverages roguelite mechanics to generate ever-changing maps and adversaries, ensuring no two runs are alike. Your adaptability and strategic thinking are put to the test as you manage scarce resources and time, devising optimal strategies to endure in this unforgiving environment.

---
some screenshots.

![](https://cdn.akamai.steamstatic.com/steam/apps/2153420/ss_63b2c9ef793884f2350867f8a2e3de2736409658.600x338.jpg?t=1686724624)
![](https://cdn.akamai.steamstatic.com/steam/apps/2153420/ss_32937ef935edd2eb1c99160a6e07640e7c2c8419.600x338.jpg?t=1686724624)
![](https://cdn.akamai.steamstatic.com/steam/apps/2153420/ss_57261280329e2fe4f1d100070c94ad8e13b598e8.600x338.jpg?t=1686724624)
![](https://cdn.akamai.steamstatic.com/steam/apps/2153420/ss_a39d197c761923741c28c07edb45333ac540fbbd.600x338.jpg?t=1686724624)
![](https://cdn.akamai.steamstatic.com/steam/apps/2153420/ss_53b0d23c10bb63ff53dda98ee2bbaba2b99bf264.600x338.jpg?t=1686724624)
---
"If my code has been helpful to you, please consider supporting it on Steam at: https://store.steampowered.com/app/2153420/Dont_Stop/ I would greatly appreciate it!"
---
Licence
---
GNU General Public License

---
Multiplayer (co-op survival)
---
This fork adds a pluggable networking layer and host / direct-connect co-op on
top of the original single-player game:

* `Net` (`autoload/net/NetworkManager.gd`) owns the session and the authoritative
  player roster; `Coop` (`autoload/net/CoopSession.gd`) owns gameplay replication.
  Game code never talks to ENet or Steam directly.
* Backends: **ENet** (IP direct connect, always available) and **Steam P2P**
  (opt-in; needs a Godot 4.4-compatible GodotSteam GDExtension, see the docs).
  An unavailable backend degrades gracefully instead of crashing.
* Lobby UI: main menu -> `联机`.

The host is authoritative for monsters, damage and level progress; clients
predict their own character and report state back. Single-player behaviour is
unchanged — every networking path is a no-op when no session is active.

Design notes, the Godot 4.4 migration fixes, and the list of what is *not* synced
yet live in [docs/MULTIPLAYER_PLAN.md](docs/MULTIPLAYER_PLAN.md).

| 文档 | 内容 |
| --- | --- |
| [docs/ONBOARDING.md](docs/ONBOARDING.md) | **新队友上手指引**：clone、跑通、联机、提 PR、最容易踩的坑 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 协作规范：分支、提交、模块边界、代码风格 |
| [docs/TESTING.md](docs/TESTING.md) | 怎么实际跑起来：单机、双开、局域网、验收清单 |
| [docs/STEAM_SETUP.md](docs/STEAM_SETUP.md) | Steam P2P 真机联机：装扩展、两账号前提、排查表 |
| [docs/MULTIPLAYER_PLAN.md](docs/MULTIPLAYER_PLAN.md) | 设计：权威模型、RPC 清单、已踩过的坑 |

Headless verification (run from `cmd`, not PowerShell — see the docs):

```bat
tools\verify.bat 0 all
```

