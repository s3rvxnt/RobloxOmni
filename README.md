# Omni Bootloader & Task Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Target: Potassium](https://img.shields.io/badge/Target-Potassium%20%2F%20Banana-yellow.svg)](#)
[![Luau: 5.1+](https://img.shields.io/badge/Luau-5.1%2B-blueviolet.svg)](#)
[![Status: Production](https://img.shields.io/badge/Status-Release%20v1.0-brightgreen.svg)](#)

> **The first all-in-one adaptive, frame-budgeted autoexec bootloader and Task Manager for Roblox.**  
> Built as a **single, self-contained Luau script**. Eliminates startup client freezes, caps background task CPU load, and provides microsecond-precision task profiling with zero dependencies and zero runtime downloads.

---

## 🚀 Installation & Usage

Because all Roblox executors sandbox Luau file I/O (`readfile`, `writefile`, `listfiles`) to the `workspace/` folder, the executor's real `autoexec/` directory cannot be written to from inside a game. 

Omni Bootloader is built as **ONE standalone script**:

### Option 1: Permanent Autoexec Setup *(Recommended)*
1. Download **[`OmniBootloader.lua`](OmniBootloader.lua)**.
2. Place it into your executor's real `autoexec/` folder on your machine:
   ```text
   Potassium/
   └── autoexec/
       └── OmniBootloader.lua
   ```
3. Launch Roblox. That's it! It will automatically protect every game launch with 6.0ms frame budgeting.

### Option 2: In-Game Session Launch (No Installation)
To run the bootloader and Task Manager in memory for your current session without touching your files:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/OmniBootloader.lua"))()
```

* **Toggle Hotkey:** Press **`Shift + F8`** (or call `getgenv().ToggleTaskManagerHUD()`) to open the Task Manager HUD.
* **Panic Switch:** Call `getgenv().UnloadAllTasks()` to cleanly disconnect all background tasks instantly.

---

## 💎 What Makes Omni Bootloader Different?

Traditional autoexec setups execute all scripts simultaneously as soon as the client injects. Heavy scripts, unthrottled loops, and simultaneous asset loading cause **micro-stutters, FPS drops, and complete client freezes on launch**.

Omni Bootloader solves this in **ONE single script**:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Roblox Engine (RunService)                      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Intercepted Hook)
┌───────────────────────────────────▼────────────────────────────────────┐
│                    Omni Bootloader & Runtime Micro-Kernel              │
│  ├─ Ring 0: Embedded Virtual Scheduler & Task Manager (Shift + F8)     │
│  ├─ Auto-Throttler: Demotes heavy loops (>2.5ms) from 60Hz             │
│  ├─ Adaptive 6ms Budget: Smoothly yields to Heartbeat during startup   │
│  └─ Error Boundary: xpcall + coroutine crash containment               │
└───────────┬───────────────────────┬───────────────────────┬────────────┘
            │ (High: 60Hz)          │ (Medium: 30Hz)        │ (Low: 15Hz)
┌───────────▼───────────┐ ┌─────────▼───────────┐ ┌─────────▼────────────┐
│  Physics & Movement   │ │   Visuals & ESPs    │ │ Stat Loggers & Farms │
└───────────────────────┘ └─────────────────────┘ └──────────────────────┘
```

### 1. Truly Self-Contained (One File)
No separate loaders. No multi-folder setup. No runtime GitHub downloads that fail when offline or rate-limited. The entire micro-kernel, auto-throttler, Task Manager GUI, and adaptive bootloader engine live together in that single script.

### 2. 4-Tier Ring Lifecycle Organization
Omni Bootloader automatically organizes any scripts you place in your sandboxed `workspace/autoexec/` directory into deterministic execution rings:
* **Ring 0 (Kernel):** Built directly into Omni Bootloader, boots on Frame 0 before any game code runs.
* **Ring 1 (PreInit / DataModel):** Executed as soon as `game` exists (`workspace/autoexec/preinit/`).
* **Ring 2 (GameLoaded / Network):** Executed when `game:IsLoaded()` passes (`workspace/autoexec/GameLoaded/`).
* **Ring 3 (CharacterReady & Deferred):** Executed when your character spawns and network idle completes.

### 3. Adaptive 6.0ms Frame Budgeting
Grants up to **6.0ms** of script execution per frame during startup, smoothly yielding to `Heartbeat` so Roblox never drops frames or freezes while loading 20+ autoexec scripts.

### 4. Transparent `RunService` Interception
Hooks `RunService.__index` and `RunService.__namecall`. Any third-party script calling `RunService.Heartbeat:Connect(...)` or `RenderStepped:Connect(...)` is **automatically routed into the virtual scheduler without modifying a single line of their code**.

### 5. Task Manager GUI (`Shift + F8`)
A modern, dark-mode administrative dashboard right inside Roblox:
* **Microsecond CPU Profiling:** Live meters showing exact CPU time per task, peak spike tracking, and invocation rates.
* **Live Process Controls:** Pause, resume, kill, or lock task priority live.
* **Panic Controls:** Instant "Kill All Tasks", "Purge Drawings", and "Mute Remotes".

---

## 🛠️ Developer API

You can integrate your own scripts natively into the Omni Kernel using these global methods:

```lua
-- Runs every 4th frame (15Hz), ideal for UI updates or background farms
local conn = getgenv().ThrottledConnect(RunService.Heartbeat, "Low", function(dt)
    updateStats()
end)

-- Disconnect whenever needed
conn:Disconnect()
```

### Priority Bands & Numeric Scales:
| Band Name | Execution Rate | Priority Value | Best Used For |
| :--- | :---: | :---: | :--- |
| **`"High"`** | Every Frame (60Hz) | `80` | Movement, physics, flight controllers |
| **`"Medium"`** | Every 2nd Frame (30Hz) | `50` | ESP chams, radars, aiming updates |
| **`"Low"`** | Every 4th Frame (15Hz) | `25` | Auto-farms, leaderstat checks, UI meters |
| **`"Idle"`** | When Frame Budget Permits | `10` | Cleanup tasks, cache garbage collection |

---

## 🗺️ Roadmap

* [x] **v1.0 (Current Release):** **Omni Bootloader & Task Manager** — The single-file adaptive runtime micro-kernel.
* [ ] **v2.0 (Coming Soon):** **Omni Shortcuts Automation Suite**

---

## 📜 License
Distributed under the MIT License. See [LICENSE](LICENSE) for details.
