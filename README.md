# Omni Kernel & Windows Task Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Target: Potassium](https://img.shields.io/badge/Target-Potassium%20%2F%20Banana-yellow.svg)](#)
[![Luau: 5.1+](https://img.shields.io/badge/Luau-5.1%2B-blueviolet.svg)](#)
[![Status: Production](https://img.shields.io/badge/Status-Release%20v1.0-brightgreen.svg)](#)

> **The first adaptive, frame-budgeted runtime micro-kernel and Windows 11 Fluent Task Manager for Roblox.**  
> Eliminates autoexec startup freezes, caps background task execution time, and provides microsecond-precision process profiling with zero script modifications.

---

## ⚡ Instant In-Game Launch (1-Line Loadstring)

Execute this single line in your executor terminal or script hub to mount the Omni Kernel and Task Manager GUI immediately:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/TaskManagerLoader.lua"))()
```

* **Toggle Hotkey:** `Shift + F8` (or call `getgenv().ToggleTaskManagerHUD()`)
* **Panic Switch:** `getgenv().UnloadAllTasks()` to cleanly disconnect all background tasks instantly.

---

## 🚀 Permanent Autoexec Installation

To have the Omni Kernel automatically protect your game session every time you join a server:

1. Download [`CustomAutoExec.lua`](CustomAutoExec.lua).
2. Place it into your executor's `autoexec/` directory:
   ```text
   Potassium/
   └── autoexec/
       └── CustomAutoExec.lua
   ```
3. That's it! `CustomAutoExec` will automatically create your ring directories, mirror the latest kernel from GitHub, and budget all incoming scripts with zero lag.

---

## 💎 What Makes Omni Kernel Different?

Traditional autoexec setups execute all scripts simultaneously as soon as the game opens. Heavy scripts, infinite `while true do` loops, and unthrottled `RenderStepped` connections cause **micro-stutters, FPS drops, and full game freezes**.

Omni Kernel introduces an **operating-system-style microkernel** between your scripts and Roblox:

```
┌───────────────────────────────────────────────────────────────┐
│                    Roblox Engine (RunService)                 │
└──────────────────────────────┬────────────────────────────────┘
                               │ (Intercepted Hook)
┌──────────────────────────────▼────────────────────────────────┐
│             Omni Runtime Micro-Kernel (8.0ms Budget)           │
│  ├─ Auto-Throttler: Demotes heavy loops (>2.5ms) from 60Hz     │
│  ├─ Phase Protection: Eliminates Heartbeat starvation          │
│  └─ Error Boundary: xpcall + coroutine crash containment       │
└──────┬───────────────────────┬───────────────────────┬────────┘
       │ (High: 60Hz)          │ (Medium: 30Hz)        │ (Low: 15Hz)
┌──────▼──────────────┐ ┌──────▼──────────────┐ ┌──────▼──────────────┐
│  Physics & Movement │ │   Visuals & ESPs    │ │ Stat Loggers & Farms │
└─────────────────────┘ └─────────────────────┘ └─────────────────────┘
```

### 1. Adaptive 6ms / 8ms Frame Budgeting
* **Bootloader Phase:** Grants up to **6.0ms** of script execution per frame during startup, smoothly yielding to `Heartbeat` so Roblox never drops frames while loading 50+ scripts.
* **Runtime Phase:** Caps cumulative task execution at **8.0ms** per frame, queuing remaining tasks to the next frame to prevent stutter during intense gameplay.

### 2. Transparent `RunService` Interception
Hooks `RunService.__index` and `RunService.__namecall`. Any third-party script calling `RunService.Heartbeat:Connect(...)` or `RenderStepped:Connect(...)` is **automatically routed into the virtual scheduler without modifying a single line of their code**.

### 3. Windows 11 Fluent Task Manager GUI (`Shift + F8`)
A modern, dark-mode administrative dashboard right inside Roblox:
* **Microsecond CPU Profiling:** Live meters showing exact CPU time per task, peak spike tracking, and invocation rates.
* **Live Process Controls:** Pause, resume, kill, or lock task priority live.
* **Panic Controls:** Instant "Kill All Tasks", "Purge Drawings", and "Mute Remotes".

### 4. 4-Tier Ring Bootloader Architecture
`CustomAutoExec.lua` organizes scripts into deterministic lifecycle stages:
* **Ring 0 (Kernel):** Loaded on Frame 0 before anything else (`autoexec/kernel/`).
* **Ring 1 (PreInit / DataModel):** Executed as soon as `game` exists (`autoexec/preinit/`).
* **Ring 2 (GameLoaded / Network):** Executed when `game:IsLoaded()` passes (`autoexec/GameLoaded/`).
* **Ring 3 (CharacterReady & Deferred):** Executed when your character spawns and network idle completes.

---

## 🛠️ Developer API

You can integrate your own scripts natively into the Omni Kernel using these global methods:

### `getgenv().ThrottledConnect(signal, priority, callback)`
Connects a callback to a RunService event with an assigned priority band:
```lua
-- Runs every 4th frame (15Hz), ideal for UI updates or background farms
local conn = getgenv().ThrottledConnect(RunService.Heartbeat, "Low", function(dt)
    updateStats()
end)

-- Disconnect whenever needed
conn:Disconnect()
```

### Priority Bands & Numeric Scales:
| Band Name | Execution Rate | Typical Priority Value | Best Used For |
| :--- | :---: | :---: | :--- |
| **`"High"`** | Every Frame (60Hz) | `80` | Movement, physics, flight controllers |
| **`"Medium"`** | Every 2nd Frame (30Hz) | `50` | ESP chams, radars, aiming updates |
| **`"Low"`** | Every 4th Frame (15Hz) | `25` | Auto-farms, leaderstat checks, UI meters |
| **`"Idle"`** | When Frame Budget Permits | `10` | Cleanup tasks, cache garbage collection |

### `getgenv().UnloadAllTasks()`
The panic switch. Instantly disconnects all managed connections across all scripts cleanly without crashing or requiring a server rejoin.

### `getgenv().ToggleTaskManagerHUD()`
Opens or closes the Windows 11 Task Manager interface programmatically.

---

## 🗺️ Roadmap & Ecosystem

* [x] **v1.0 (Current Release):** Omni Kernel Micro-Scheduler, Windows Task Manager GUI, and Adaptive Bootloader.
* [ ] **v2.0 (Coming Soon):** **Omni Shortcuts Automation Engine** — A zero-code, Apple Shortcuts-style visual pipeline builder featuring 38+ visual drag-and-drop primitives, hardware hotkey triggers, and shareable recipes.

---

## 📜 License
Distributed under the MIT License. See [LICENSE](LICENSE) for details.
