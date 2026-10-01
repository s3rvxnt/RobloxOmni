# Omni Bootloader & Windows Task Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Target: Potassium](https://img.shields.io/badge/Target-Potassium%20%2F%20Banana-yellow.svg)](#)
[![Luau: 5.1+](https://img.shields.io/badge/Luau-5.1%2B-blueviolet.svg)](#)
[![Status: Production](https://img.shields.io/badge/Status-Release%20v1.0-brightgreen.svg)](#)

> **The first all-in-one adaptive, frame-budgeted autoexec bootloader and Windows 11 Task Manager for Roblox.**  
> Built as a single, self-contained Luau script. Eliminates startup client freezes, caps background task CPU load, and provides microsecond-precision task profiling with zero dependencies.

---

## ⚡ Quick Start

### Option 1: One-Click Autoexec Installer *(Recommended)*
Run this in your executor to automatically download and install `OmniBootloader.lua` directly into your `autoexec/` folder:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.lua"))()
```
*Writes `autoexec/OmniBootloader.lua` and immediately boots the kernel.*

### Option 2: Instant 1-Line Launch (No Installation)
Run the bootloader and Task Manager in memory for your current session without touching your files:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/OmniBootloader.lua"))()
```

### Option 3: Manual Autoexec Drop-In
1. Download [`OmniBootloader.lua`](OmniBootloader.lua).
2. Place it into your executor's `autoexec/` directory:
   ```text
   Potassium/
   └── autoexec/
       └── OmniBootloader.lua
   ```

* **Toggle Hotkey:** `Shift + F8` (or call `getgenv().ToggleTaskManagerHUD()`)
* **Panic Switch:** `getgenv().UnloadAllTasks()` to cleanly disconnect all background tasks instantly.

---

## 💎 What Makes Omni Bootloader Different?

Traditional autoexec setups execute all scripts simultaneously as soon as the game opens. Heavy scripts, infinite loops, and unthrottled `RenderStepped` connections cause **micro-stutters, FPS drops, and full game freezes**.

Omni Bootloader solves this in **ONE single script**:

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

### 1. Unified Single-File Deployment
No multi-folder setup. No external dependencies. No GitHub network requests required at runtime. The entire micro-kernel, auto-throttler, Windows 11 Task Manager GUI, and adaptive bootloader engine live together in **[`OmniBootloader.lua`](OmniBootloader.lua)**.

### 2. Adaptive 6.0ms Frame-Budgeting
Grants up to **6.0ms** of script execution per frame during startup, smoothly yielding to `Heartbeat` so Roblox never drops frames or freezes while loading your scripts.

### 3. Transparent `RunService` Interception
Hooks `RunService.__index` and `RunService.__namecall`. Any third-party script calling `RunService.Heartbeat:Connect(...)` or `RenderStepped:Connect(...)` is **automatically routed into the virtual scheduler without modifying a single line of their code**.

### 4. Task Manager GUI (`Shift + F8`)
A modern, dark-mode administrative dashboard right inside Roblox:
* **Microsecond CPU Profiling:** Live meters showing exact CPU time per task, peak spike tracking, and invocation rates.
* **Live Process Controls:** Pause, resume, kill, or lock task priority live.
* **Panic Controls:** Instant "Kill All Tasks", "Purge Drawings", and "Mute Remotes".

### 5. 4-Tier Ring Bootloader Architecture
Automatically organizes your other scripts into deterministic lifecycle stages:
* **Ring 0 (Kernel):** Embedded in OmniBootloader, boots on Frame 0.
* **Ring 1 (PreInit / DataModel):** Executed as soon as `game` exists (`autoexec/preinit/`).
* **Ring 2 (GameLoaded / Network):** Executed when `game:IsLoaded()` passes (`autoexec/GameLoaded/`).
* **Ring 3 (CharacterReady & Deferred):** Executed when your character spawns and network idle completes.

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

* [x] **v1.0 (Current Release):** **Omni Bootloader & Windows Task Manager** — The single-file adaptive runtime micro-kernel.
* [ ] **v2.0 (Coming Soon):** **Omni Shortcuts Automation Suite**

---

## 📜 License
Distributed under the MIT License. See [LICENSE](LICENSE) for details.
