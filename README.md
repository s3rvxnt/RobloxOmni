# Omni

[![License: PolyForm Noncommercial](https://img.shields.io/badge/License-PolyForm%20Noncommercial-orange.svg)](LICENSE)

> **Zero lag. Adaptive frame budgeting. Zero-trust security gate.**  
> The intelligent bootloader, runtime kernel, visual automation engine, and enhancement suite for Roblox.

---

### It just works.

Traditional autoexec setups inject every script at once. The client freezes. Frames drop. Untrusted scripts run silently with zero transparency.

**Omni changes that.** It meters execution at 6.0ms per frame, dynamically throttles runaway loops, isolates runtime errors, and protects you with an in-game **Zero-Trust Transparency & Update Gate** that lets you audit, inspect, and approve updates line-by-line before any remote code touches your machine.

---

### Key Capabilities

#### 🛡️ 1. Zero-Trust Transparency & Update Gate (`Shift + F7`)
* **Zero Blind Updates**: Remote components are never silently overwritten without your explicit consent.
* **Line-by-Line Git Diff Inspector**: Review color-coded `+` additions and `-` removals in a monospaced code viewer directly in-game.
* **Static Security & Obfuscation Audit**: Automatically scans incoming code for obfuscators (Luarmor, Luraph, IronBrew, MoonSec, packed bytecode/VM decoders), Discord webhooks, HTTP requests, and file I/O. Enforces a 2-click confirmation before any obfuscated update can be applied.
* **User Sovereignty & Persistent Ledger**: Tracks component versions in `Omni_Ledger.json` and strictly respects user-deleted components.

#### 📊 2. 100% Offline Kernel Task Manager HUD (`Shift + F8`)
* **Zero Network Calls**: Verified 100% offline runtime micro-kernel with zero external HTTP requests.
* **Transparent RunService Interception**: Seamlessly hooks `Heartbeat`, `Stepped`, and `RenderStepped` connections with zero script modifications.
* **Microsecond CPU Profiling**: Real-time per-task CPU consumption, spike tracking, and dynamic auto-throttling (60Hz ➔ 30Hz ➔ 15Hz).
* **Interactive Process & Loop Controls**: Dedicated tabs for **Runtime** processes, **Loops** governor, **Performance** graphs, and **Startup** management. Pause, resume, throttle, priority-lock, or terminate individual runaway threads.
* **Panic Switch**: Global panic controls (`getgenv().UnloadAllTasks()`) to instantly disconnect and terminate background threads cleanly.

#### 🌌 3. Omni Enhancement Suite (Stage: `GameLoaded`)
* **Streamer Mode**: Visual-only username, display name, and UserID redaction/spoofing across leaderboards and overhead billboards.
* **Personal Space Bubble**: Smooth distance falloff and temporal lerp fade that makes crowded player avatars vanish within your personal bubble radius.
* **Player Locator & ESP**: Hardware-efficient box adornments, on-demand highlight pool (up to 255), raycast tracers, and team filters.
* **Anti-AFK**: Engine-level inactivity kick prevention.
* **Native ESC Menu Integration**: Seamlessly injected at the top of the Roblox in-game ESC Settings menu.

#### ⏱️ 4. 5-Stage Adaptive Frame Budgeting
Drop scripts into stage folders inside your executor's `workspace/autoexec/`:
* `kernel/` — Critical low-level engines and schedulers (executes first).
* `preinit/` — Initialization scripts executed before game assets load.
* `gameloaded/` — Scripts requiring full `game.Loaded` resolution.
* `characterloaded/` — Scripts dependent on `LocalPlayer.Character` and humanoid rigs.
* `deferred/` — Non-essential utilities and background tasks.

---

### Get Started

#### Option 1: 1-Click Setup *(Recommended)*
Download and run **[`install.bat`](install.bat)**, or run this single command in PowerShell:

```powershell
irm https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.ps1 | iex
```

* Automatically discovers your executor installation (Potassium, Solara, Wave, etc.).
* Safely migrates existing loose scripts to `workspace/autoexec/preinit/` (preserving immediate Frame-0 execution without overwriting colliding files).
* Deploys `Bootloader.lua` into your executor's `autoexec/` folder in under a second (UTF-8 without BOM).

#### Option 2: Manual Setup
Drop **[`Bootloader.lua`](Bootloader.lua)** into your executor's `autoexec` folder (sibling to `workspace/`):

```text
YourExecutor/
├── autoexec/
│   └── Bootloader.lua
└── workspace/
    └── autoexec/
        ├── kernel/
        ├── preinit/
        ├── gameloaded/
        ├── characterloaded/
        └── deferred/
```

---

### Hotkeys & Controls

| Shortcut | Interface | Description |
| :--- | :--- | :--- |
| **`Shift + F7`** | **Security & Update Gate** | Release changelog, line-by-line git diff viewer, static security & obfuscation audit |
| **`Shift + F8`** | **Kernel Task Manager HUD** | Live CPU metrics, loop governor, thread throttling, interactive process controls |
| **`Hold Shift at Launch`** | **Safe Mode Recovery** | Instant 0ms recovery: bypasses all third-party autoexec scripts if one crashes the game |

---

### Developer API

```lua
local RunService = game:GetService("RunService")

-- Throttled to 15Hz. Zero wasted frames.
local conn = getgenv().ThrottledConnect(RunService.Heartbeat, "Low", function(dt)
    -- Your update loop here
end)
```

| Band | Rate | Priority | Best For |
| :--- | :--- | :--- | :--- |
| **High** | 60Hz | 75 | Physics, movement |
| **Medium** | 30Hz | 50 | Visuals, ESP |
| **Low** | 15Hz | 25 | UI, automation |
| **Eco** | 10Hz | 10 | Stat trackers, background polling |
| **Idle** | Spare | 5 | Memory cleanup, garbage collection |

---

### License

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).  
Free to use, modify, and share for personal, non-commercial use. Commercial resale, monetization gates, and paid key systems are strictly prohibited.
