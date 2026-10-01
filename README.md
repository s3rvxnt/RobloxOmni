# Omni

> **Zero lag. Adaptive budgeting. Silent auto-updates.**  
> The intelligent bootloader and task manager for Roblox.

---

### It just works.

Traditional autoexec setups inject every script at once. The client freezes. Frames drop. 

Omni changes that. It meters execution at 6.0ms per frame, dynamically throttles runaway loops, and keeps itself updated in the background before the game even loads.

---

### Get Started

#### 1-Click Setup (Recommended)
Paste into Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.ps1 | iex
```

* Auto-detects every executor installed on your machine (Potassium, Solara, Wave, etc.)
* Migrates existing loose scripts from `autoexec/` to `workspace/autoexec/`
* Deploys `Bootloader.lua` instantly

#### Or Manual Setup:
Drop **[`Bootloader.lua`](Bootloader.lua)** into your executor's `autoexec` folder (right next to your `workspace` folder).

```text
YourExecutor/
├── autoexec/
│   └── Bootloader.lua
└── workspace/
```

**That's it.** Omni builds its own directories, fetches the latest kernel, and keeps everything up to date forever.

#### Or run it live:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/Bootloader.lua"))()
```

---

### The Experience

* **`Shift + F8`** — Instant Task Manager HUD. Microsecond CPU metrics, spike tracking, and live priority controls.
* **6.0ms Adaptive Budget** — Smoothly yields to the host engine. 20+ scripts load with zero frame drops.
* **Silent Auto-Updates** — Checks GitHub on boot and updates the kernel seamlessly. Zero maintenance.
* **Panic Switch** — `getgenv().UnloadAllTasks()`. Every task, disconnected cleanly in one click.

---

### Developer API

```lua
local RunService = game:GetService("RunService")

-- Throttled to 15Hz. Zero wasted frames.
local conn = getgenv().ThrottledConnect(RunService.Heartbeat, "Low", function(dt)
    update()
end)
```

| Band | Rate | Priority | Best For |
| :--- | :--- | :--- | :--- |
| **High** | 60Hz | 80 | Physics, movement |
| **Medium** | 30Hz | 50 | Visuals, ESP |
| **Low** | 15Hz | 25 | UI, automation |
| **Idle** | Spare | 10 | Garbage cleanup |

---

### License

MIT
