# Omni Bootloader & Task Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Target: Potassium](https://img.shields.io/badge/Target-Potassium%20%2F%20Banana-yellow.svg)](#)
[![Luau: 5.1+](https://img.shields.io/badge/Luau-5.1%2B-blueviolet.svg)](#)
[![Status: Production](https://img.shields.io/badge/Status-Release%20v1.0-brightgreen.svg)](#)

> **The first modular, adaptive frame-budgeted autoexec bootloader and Task Manager for Roblox.**  
> Designed specifically around executor sandboxing: drop `Bootloader.lua` once into your autoexec; it automatically provisions and keeps your Kernel Task Manager updated to the latest release on launch. Eliminates startup client freezes, caps background task CPU load, and provides microsecond-precision task profiling.

---

## 🚀 Installation & Setup

Roblox executors sandbox Luau file I/O (`readfile`, `writefile`, `listfiles`) strictly to the `workspace/` folder. The executor's real root `autoexec/` folder is located outside this sandbox and cannot be written to or updated from inside Roblox.

Omni solves this with a **zero-maintenance 2-component architecture**:
* **`Bootloader.lua` (Root Drop-In):** Placed once into your real `autoexec/` folder.
* **`KernelTaskManager.lua` (Sandboxed Kernel):** Automatically downloaded, cached, and updated by `Bootloader.lua` into `workspace/autoexec/kernel/`.

```
Potassium/
├── autoexec/
│   └── Bootloader.lua                         <-- Place this ONCE (outside sandbox)
│
└── workspace/
    └── autoexec/
        ├── kernel/
        │   └── KernelTaskManager.lua          <-- Auto-downloaded & auto-updated
        ├── preinit/                           <-- Runs immediately (game ~= nil)
        ├── 6764533218 - Washiez/              <-- PlaceId-scoped scripts
        └── account_Pymro/                     <-- Account-scoped scripts
```

### Option 1: Permanent Autoexec Setup *(Recommended)*

1. Download **[`Bootloader.lua`](Bootloader.lua)**.
2. Place it into your executor's real root `autoexec/` folder:
   ```text
   Potassium/
   └── autoexec/
       └── Bootloader.lua
   ```
3. Launch Roblox. That's it!
   * On boot, `Bootloader.lua` verifies your local `workspace/autoexec/kernel/KernelTaskManager.lua` against GitHub.
   * If a new version exists or the file is missing, it auto-downloads and updates it instantly.
   * If GitHub is unreachable (offline or rate-limited), it falls back seamlessly to your local cache.

### Option 2: In-Game Session Launch (No Installation)

To run the bootloader and Task Manager in memory for your current session without touching your files:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/Bootloader.lua"))()
```

* **Toggle HUD Hotkey:** Press **`Shift + F8`** (or call `getgenv().ToggleTaskManagerHUD()`) to open the Task Manager HUD.
* **Panic Switch:** Call `getgenv().UnloadAllTasks()` to cleanly disconnect all background tasks instantly.

---

## 💎 What Makes Omni Bootloader Different?

Traditional autoexec setups execute all scripts simultaneously as soon as the client injects. Heavy scripts, unthrottled loops, and simultaneous asset loading cause **micro-stutters, FPS drops, and complete client freezes on launch**.

Omni Bootloader solves this with adaptive frame budgeting and virtual scheduling:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Roblox Engine (RunService)                      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Intercepted Hook)
┌───────────────────────────────────▼────────────────────────────────────┐
│                    Omni Bootloader & Runtime Micro-Kernel              │
│  ├─ Ring 0: Auto-Updated Kernel Task Manager (Shift + F8 HUD)          │
│  ├─ Auto-Throttler: Demotes heavy loops (>2.5ms) from 60Hz             │
│  ├─ Adaptive 6ms Budget: Smoothly yields to Heartbeat during startup   │
│  └─ Error Boundary: xpcall + coroutine crash containment               │
└───────────┬───────────────────────┬───────────────────────┬────────────┘
            │ (High: 60Hz)          │ (Medium: 30Hz)        │ (Low: 15Hz)
┌───────────▼───────────┐ ┌─────────▼───────────┐ ┌─────────▼────────────┐
│  Physics & Movement   │ │   Visuals & ESPs    │ │ Stat Loggers & Farms │
│  (80 Priority)        │ │   (50 Priority)     │ │ (25 Priority)        │
└───────────────────────┘ └─────────────────────┘ └──────────────────────┘
```

### 1. Zero-Maintenance Auto-Updating
You never have to manually re-download or overwrite task manager files. Every launch checks GitHub Raw with cache-busting headers. If an update is published to `KernelTaskManager.lua`, your client updates itself automatically before Ring 0 loads.

### 2. 4-Tier Ring Lifecycle Organization
Scripts placed in your sandboxed `workspace/autoexec/` directory are executed in deterministic priority tiers:
* **Ring 0 (Kernel):** Loaded on Frame 0 before any game code executes (`workspace/autoexec/kernel/`).
* **Ring 1 (PreInit / DataModel):** Executed as soon as `game` exists (`workspace/autoexec/preinit/` or `autoexec/nodelay/`).
* **Ring 2 (GameLoaded / Network):** Executed when `game:IsLoaded()` passes under adaptive 6.0ms frame budgeting (`workspace/autoexec/GameLoaded/` or root `autoexec/`).
* **Ring 3 (CharacterReady & Account):** Executed after local character spawns and network idle finishes (`workspace/autoexec/account_<Name>/`).

### 3. Adaptive 6.0ms Frame Budgeting
Grants up to **6.0ms** of script execution per frame during startup, smoothly yielding to `Heartbeat` so Roblox never drops frames or freezes while loading 20+ autoexec scripts.

### 4. Transparent `RunService` Interception
Hooks `RunService.__index` and `RunService.__namecall`. Third-party scripts calling `RunService.Heartbeat:Connect(...)` or `RenderStepped:Connect(...)` are **automatically routed into the virtual scheduler without modifying a single line of their code**. If an unmodded loop consumes excessive CPU time (>2.5ms), the auto-throttler demotes it to 30Hz or 15Hz.

### 5. Windows 11 Fluent Task Manager GUI (`Shift + F8`)
A modern, dark-mode administrative dashboard right inside Roblox:
* **Microsecond CPU Profiling:** Live meters showing exact CPU time per task, peak spike tracking, and invocation rates.
* **Live Process Controls:** Pause, resume, kill, or lock task priority live.
* **Panic Controls:** Instant "Kill All Tasks", "Purge Drawings", and "Mute Remotes".
* **Telemetry Output:** Emits `workspace/Bootloader_Status.json` and `workspace/Scheduler_Profile.json` for external diagnostics.

---

## 🛠️ Developer API

Integrate your own scripts natively into the Omni Kernel using these global methods:

```lua
local RunService = game:GetService("RunService")

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

## 🗺️ Release Roadmap

* [x] **v1.0 (Current Release):** **Omni Bootloader & Task Manager** — Modular auto-updating bootloader with transparent virtual scheduling and Windows Task Manager GUI.
* [ ] **v2.0 (Next Release):** **Omni Shortcuts Automation Suite** — Zero-code visual automation pipelines with parameter cards, native triggers, and action gallery.

---

## 📜 License
Distributed under the MIT License. See [LICENSE](LICENSE) for details.
