# Omni

[![License: PolyForm Noncommercial](https://img.shields.io/badge/License-PolyForm%20Noncommercial-orange.svg)](LICENSE)

Modular Luau runtime micro-kernel, frame-budgeted bootloader, and execution scheduler for Roblox executors.

---

## Overview

Standard autoexec configurations inject all discovered scripts simultaneously during Frame 0 initialization. On modern Roblox client versions, unmetered script injection saturates Luau thread allocation, spikes CPU execution during asset streaming, drops rendering frames, and risks engine deadlocks. Furthermore, running third-party scripts without execution accounting obscures performance bottlenecks and leaves remote auto-updates unchecked.

Omni replaces uncoordinated execution with an isolated multi-stage bootloader and runtime micro-kernel:

* **Staged Frame Budgeting**: Meters script execution under an adaptive 6.0ms per-frame budget across 5 distinct lifecycle rings, isolating errors per script via coroutine wrappers.
* **Kernel Task Manager HUD (`Shift + F8`)**: Provides a 100% offline, zero-network diagnostic interface with real-time microsecond CPU profiling, RunService task prioritization, and an automated loop governor ("Memory Foam Rebound") that clamps runaway loops to 15Hz before smoothly recovering them.
* **Security & Update Gate (`Shift + F7`)**: Features an in-game 40-line lookahead Git diff viewer, an Anti-Trojan Source sanitizer (CVE-2021-42574), and a static AST security scanner that audits obfuscated code, Discord webhooks, and filesystem operations before applying remote updates.
* **Cryptographic Loadstring Manager (`Shift + F6` / `F6`)**: Stores authorized remote script URLs in an offline ledger (`Omni_TrustedUrls.json`), caches verified payloads locally (`omni_trusted_scripts/`), validates SHA-256 return hashes, and enables per-script auto-update policies.
* **Monitor-Only Engine Isolation**: Intercepts `task.wait` and `wait` through pristine Frame 0 C-closure trampolines for CPU accounting, while guaranteeing that native Roblox game scripts are never clamped, never paused, and never suspended.

---

## Architecture & Execution Lifecycle

### Execution Rings

Omni structures script execution across 5 deterministic rings, ensuring game state dependencies (DataModel availability, network replication, and character spawning) are fully met before dependent code runs.

```
[Injection / Frame 0]
        │
        ▼
├── Ring 0: Kernel (autoexec/kernel/)
│   └── Synchronous, 0ms delay, unyielding. Core schedulers, trampolines, micro-kernel.
│
├── Ring 1: PreInit (autoexec/preinit/)
│   └── Concurrent via task.spawn once DataModel is ready (game ~= nil).
│   └── Disarms crash sentinel lockfile (Bootloader_Running.lock).
│
├── Ring 2: GameLoaded (autoexec/gameloaded/)
│   └── Triggered when game:IsLoaded() passes (8.0s timeout) + 1 render step settle.
│   └── Metered under 6.0ms frame budget. UI hubs, visual enhancements, place suites.
│
├── Ring 3: CharacterReady (autoexec/characterloaded/)
│   └── Triggered once Players.LocalPlayer and LocalPlayer.Character resolve.
│   └── Metered under 6.0ms frame budget. Movement modifications, character controllers.
│
└── Ring 4: Deferred (autoexec/deferred/)
    └── Post-startup idle stage (0.5s settling buffer).
    └── Sequential execution: 1 script per frame via Heartbeat:Wait().
```

| Ring | Stage Name | Target Directory | Trigger / Dependency | Scheduling Strategy | Intended Workload |
| :---: | :--- | :--- | :--- | :--- | :--- |
| **0** | **Kernel** | `autoexec/kernel/` | Injection Frame 0; initial DataModel access | Synchronous, strictly unyielding | Core schedulers, primitive hooks, Task Manager micro-kernel |
| **1** | **PreInit** | `autoexec/preinit/` | DataModel available (`game ~= nil`) | Concurrent via `task.spawn` | Anticheat bypasses, remote spies, environment configuration |
| **2** | **GameLoaded** | `autoexec/gameloaded/` | `game:IsLoaded()` passes (8.0s timeout) | Metered under 6.0ms budget (`runStageWithBudget`) | UI hubs, visual ESP, game-specific enhancement suites |
| **3** | **CharacterReady** | `autoexec/characterloaded/` | `LocalPlayer` (10s) & `Character` (12s) ready | Metered under 6.0ms budget (`runStageWithBudget`) | Character controllers, tool equippers, movement modifications |
| **4** | **Deferred** | `autoexec/deferred/` | Post-startup idle (0.5s settling buffer) | Sequential: 1 script per frame (`Heartbeat:Wait()`) | Webhook loggers, memory cleanup routines, anti-idle bots |

### Frame Budget Mechanics

Omni operates frame budgeting at two distinct layers:

1. **Bootloader Startup Budget (`Bootloader.lua`)**:
   During the initialization of Ring 2 (`gameloaded/`) and Ring 3 (`characterloaded/`), `runStageWithBudget` enforces a 6.0ms execution window per frame (`TARGET_BUDGET_MS = 6.0`). Scripts are compiled with an unhooked C-primitive clone of `loadstring` and executed within isolated coroutines wrapped in `xpcall` with `debug.traceback`:
   ```lua
   local function runStageWithBudget(stageName, queue)
       if #queue == 0 then return end
       local frameStart = os.clock()
       for _, meta in ipairs(queue) do
           if not executedFiles[meta.file] then
               if (os.clock() - frameStart) * 1000 >= TARGET_BUDGET_MS then
                   RunService.Heartbeat:Wait()
                   frameStart = os.clock()
               end
               executeScript(meta)
           end
       end
   end
   ```
   Because scripts execute in isolated coroutines, top-level infinite loops (such as `while true do task.wait() end`) or network yields suspend only their respective thread. The coroutine immediately yields control back to `coroutine.resume`, allowing the bootloader to proceed without blocking subsequent scripts or freezing the client. Detailed startup metrics are exported to `workspace/Bootloader_Status.json`.

2. **Kernel Runtime Scheduler Budget (`KernelTaskManager.lua`)**:
   During active gameplay, the micro-kernel virtual scheduler samples frame delta times (`dt`) on `RunService.Heartbeat` to compute `smoothedDeltaTime = (smoothedDeltaTime * 0.92) + (dt * 0.08)`. It allocates approximately 48% of available frame time (`math.clamp(smoothedDeltaTime * 0.48, 0.0015, 0.0080)`, or 1.5ms to 8.0ms) to executor tasks, while reserving a 25% minimum share per simulation phase (`Heartbeat`, `Stepped`, `RenderStepped`). If cumulative task execution exceeds this boundary, remaining non-realtime tasks are pushed to `deferredQueue` and execute at the start of the next frame.

### Directory Scoping & Script Pragmas

#### Scoped Subdirectories
Scripts can be organized into context-specific directories that Omni maps into the execution lifecycle automatically:
* **Universal**: `autoexec/universal/`, `autoexec/common/`, `autoexec/shared/` (queued into `gameloaded/`).
* **Place-Specific**: Folders matching `game.PlaceId` (e.g. `autoexec/189707/`, `autoexec/place_189707/`).
* **Universe-Specific**: Folders matching `game.GameId` (e.g. `autoexec/universe_928172/`).
* **Account-Specific**: Discovered once `LocalPlayer` resolves (e.g. `autoexec/account_<Username>/`, `autoexec/user_<Username>/`).
* **Ignored Items**: Folders named `off`, `disabled`, `.ignore`, or prefixed with `_` or `.` are ignored. Files ending in `.off`, `.disabled`, `.bak`, `.tmp`, `.json`, or `.png` are skipped. If files with identical base names exist in the same folder, `.lua` / `.luau` takes precedence over `.txt`.

#### Script Pragmas
Individual scripts can configure their stage, execution priority, and display name by declaring pragmas within the first 4,000 bytes of the file:
```lua
--!stage GameLoaded
--!priority 100
--!name VisualEnhancements
```
Queued scripts are sorted first by priority descending (`a.priority > b.priority`, default 0), and second by lowercase filename ascending (`a.name:lower() < b.name:lower()`).

---

## Task Manager HUD & Loop Governor

The Kernel Task Manager (`Shift + F8`) is a 100% offline runtime inspection dashboard and scheduler interface embedded directly into the Roblox environment.

```
+-----------------------------------------------------------------------------------------+
| KERNEL TASK MANAGER HUD                                            [Shift + F8 to Toggle]|
+-------------------+--------------------+--------------------+---------------------------+
| ENGINE REFRESH    | TOTAL CPU LOAD     | LUAU HEAP          | ACTIVE WORKLOAD           |
| 60 FPS (8.0ms bud)| 1.42 ms (17.8%)    | 42.6 MB (+12 KB)   | 14 Tasks | 8 Loops        |
+-------------------+--------------------+--------------------+---------------------------+
| [Runtime]              [Loops]              [Performance]              [Startup]        |
+-----------------------------------------------------------------------------------------+
| PRIORITY | NAME & SOURCE        | EVENT         | TARGET HZ | LOCK | CPU TIME | ACTIONS |
| 90 (High)| VisualESP.lua:42     | RenderStepped | 60 Hz     | [X]  | 0.38 ms  | [||] [X]|
| 60 (Med) | RadarTracker.lua:18  | Heartbeat     | 30 Hz     | [ ]  | 0.22 ms  | [||] [X]|
| 30 (Low) | StatScanner.lua:88   | Heartbeat     | 15 Hz     | [ ]  | 0.11 ms  | [||] [X]|
+-----------------------------------------------------------------------------------------+
```

### HUD Telemetry & Navigation Tabs

The HUD mounts to `gethui()` or `CoreGui` (with a fallback to `PlayerGui`). It makes zero network requests.

#### Top Metric Cards
* **Engine Refresh**: Displays live rendering FPS (sampled from smoothed `RenderStepped` deltas) and remaining frame budget in milliseconds (`currentBudgetMs`, dynamically scaled between 3.4ms and 8.0ms).
* **Total CPU Load**: Displays total amortized CPU time in milliseconds burned across all managed tasks and loops, alongside frame budget percentage.
* **Luau Heap**: Displays memory usage (`math.floor(((gcinfo() or 0) / 1024) * 10) / 10 MB`) and recent garbage collection delta.
* **Active Workload**: Displays total active RunService scheduled tasks count and active tracked coroutine loops count.

#### Navigation Tabs
* **Runtime**: Displays all tasks managed via `ThrottledConnect` or ingested from engine events. Columns include `Priority` (1–100, drag-to-reorder, double-click edit), `Name & Source`, `Event` (`RenderStepped`, `Stepped`, `Heartbeat`), `Target Hz`, `Lock` status, `CPU Time`, and interactive buttons to pause, resume, inspect, or kill tasks. Includes a sub-mode button `Native Tasks (N)` to scan, inspect, ingest, or eject native game engine callbacks.
* **Loops**: Tracks continuous coroutine loops intercepted through `task.wait` and `wait`. Columns include `Priority`, `Location` (caller file and line number), `Cycles` (iteration count), `Speed` (live Hz and target speed picker: 60, 30, 15, 5, 1, uncapped), `Lock` toggle, `CPU Time` (per-cycle, moving average, and peak ms), and controls to pause, resume, or terminate threads.
* **Performance**: Features 60-second rolling graphs tracking FPS stability (live, 60s average, min, max), CPU load spikes against frame boundaries, Luau heap allocations, and round-trip network ping.
* **Startup**: Lists all autoexec boot stages, execution sequences, script paths, and boot execution durations in milliseconds, with interactive toggles to enable or disable scripts across future launches.

### Loop Governor & Memory Foam Rebound

The loop governor continuously monitors intercepted `task.wait` and `wait` calls to prevent runaway loops from freezing the client:

1. **Idle Discounting**: If a coroutine yields on an engine signal or remote invocation (`:Wait()`) between wait calls for > 25ms (e.g. `Tween.Completed:Wait()`, `RemoteFunction:InvokeServer()`), the idle interval is discounted so engine-side suspensions do not artificially inflate Lua CPU execution metrics.
2. **Moving Average CPU Accounting**: Per-cycle CPU time is smoothed using an exponential moving average:
   ```lua
   loop.avgTimeMs = (loop.avgTimeMs * 0.85) + (cpuMs * 0.15)
   ```
3. **Compression**: If an unlocked executor loop exceeds 2.5ms average CPU time while executing at >= 15Hz, the governor flags it as auto-throttled and immediately clamps its execution frequency to 15Hz (`minDelay = 1 / 15`).
4. **Memory Foam Rebound**: When CPU pressure drops below 0.8ms, the governor smoothly relaxes the frequency clamp over 1.2s (`_OmniMemoryFoamDuration`) using a cubic S-curve formula:
   ```lua
   local progress = math.clamp((os.clock() - loop.reboundStart) / 1.2, 0, 1)
   local smooth = progress * progress * (3 - 2 * progress)
   ```
   This transitions the loop frequency smoothly from 15Hz back to uncapped 60Hz. If a fresh CPU burst (>= 1.5ms) occurs during recovery, the clamp re-engages immediately.

---

## Update Gate & Security Engine

The Update Gate (`Shift + F7`) provides an in-game inspection layer for remote script updates and bootloader revisions. Keystroke detection checks `UserInputService:GetFocusedTextBox()`, ensuring the UI does not trigger while typing in chat or text inputs.

### In-Game Git Diff Viewer

The diff engine implements a 40-line lookahead search window (`searchWindow = 40`) with 3-line context compaction (`idx - 3` to `idx + 3`). It renders line-by-line additions (`+`) in green and removals (`-`) in red inside a draggable, resizable monospaced code viewer (`Enum.Font.Code`). Output is capped at 500 lines to prevent UI frame hitches.

### Anti-Trojan Source Sanitizer (CVE-2021-42574)

The diff sanitizer unmasks invisible Unicode characters and directional override tokens before code is rendered in the viewer:
* **Zero-Width Characters**: Replaced with explicit visual tokens:
  * `\239\187\191` &rarr; `[BOM]`
  * `\226\128\139` &rarr; `[ZWSP]`
  * `\226\128\140` &rarr; `[ZWNJ]`
  * `\226\128\141` &rarr; `[ZWJ]`
  * `\226\128\142` &rarr; `[LRM]`
  * `\226\128\143` &rarr; `[RLM]`
  * `\226\128[\128-\138]` &rarr; `[INV-SP]`
  * `\226\129\160` &rarr; `[WJ]`
  * `\194\173` &rarr; `[SHY]`
* **Bidirectional Overrides (BiDi)**: Unmasks spoofed text direction tokens: `[LRE]`, `[RLE]`, `[PDF]`, `[LRO]`, `[RLO]`, `[LRI]`, `[RLI]`, `[FSI]`, `[PDI]`.
* **Control Characters**: Converts non-printable ASCII bytes to `\xNN`. Text labels enforce a 1,200-character safety clamp to avoid font buffer overflow crashes.

### Static AST & Security Heuristics Audit

Incoming code updates are scanned across 8 heuristic security categories:
* **Obfuscation**: Identifies precompiled bytecode headers (`\27Lua`), barcode variables (`[Il1]{8,}` >= 5), hex patterns (`_0x%x{4,}` >= 8), packed decimal byte streams (`\[0-9]{3}` > 80), packed hex streams (`\x%x%x` > 80), single-line VM dispatchers (> 2500 characters), excessive `string.char` cascades (>= 15), and signatures for known obfuscators (Luarmor, Luraph, IronBrew, MoonSec, Prometheus, PSU, Aztup, Boron, WeAreDevs, Xen).
* **Trojan Source (BiDi)**: Flags bidirectional Unicode override sequences.
* **Unicode Smuggling**: Flags homoglyphs disguised within variable and identifier tokens.
* **Webhooks**: Scans for exfiltration endpoints targeting Discord webhooks (`discord.com/api/webhooks`, `discordapp.com/api/webhooks`, `webhook.site`, `pipedream.net`, `hooks.hyra.io`, `requestcatcher.com`).
* **Dynamic Code**: Detects `loadstring()` invocations.
* **Web Traffic**: Flags HTTP primitives (`HttpGet`, `request`, `http_request`, `syn.request`).
* **File I/O**: Detects filesystem write or delete calls (`writefile`, `appendfile`, `delfile`).
* **Large Files**: Identifies scripts exceeding 100,000 bytes.

### Two-Click Obfuscation Confirmation

When an incoming update triggers obfuscation heuristics, single-clicking `Apply` will not install the file. The interface activates `forceInstallConfirmActive` and starts a 4.5-second countdown timer. The user must click a second time before the countdown expires to authorize the installation.

### Dynamic Bootloader Handoff Bridge

Updated bootloader payloads are staged to `autoexec/Bootloader_Updated.lua`. SHA-256 hashes are verified against `manifest.json` before transfer. The bootloader writes `Bootloader_Handoff.lock` containing the target version; if an unexpected crash occurs during handoff initialization, the subsequent launch detects the lock, logs the version to `Bootloader_FailedVersion.txt`, deletes the lock, and reverts safely to the base bootloader.

---

## Loadstring & Trust Manager

The Loadstring Manager (`Shift + F6` or `F6`, `Escape` to close) provides an offline ledger and execution manager for remote scripts.

* **Ledger Schema (`workspace/Omni_TrustedUrls.json`)**: Tracks approved URLs, friendly labels, SHA-256 content hashes, local cache file paths, verification timestamps, and auto-update policies.
* **Offline Script Caching**: Approved scripts are cached locally in `workspace/omni_trusted_scripts/<sanitized_domain>_<hash10>.lua`. If a script URL is invoked while offline or without changes, it executes directly from local storage.
* **Per-Script Auto-Update Policies**:
  * **Silent Auto-Update** (`auto_update = true`): Automatically downloads and runs upstream updates when content hashes change.
  * **Diff Review** (`auto_update = false`): Intercepts upstream hash changes and routes them to the Update Gate for mandatory line-by-line diff inspection.
* **Zero-Trust Loadstring Shimming**: The bootloader shims `getgenv().loadstring`, `loadfile`, and `dofile` via `loadstringShim`. Unapproved URLs or modified payloads trigger an interactive modal displaying source code and security badges. A passive integrity watchdog periodically verifies the shim without modifying the global environment's metatable, preserving full compatibility with Luraph and Luarmor anti-tamper routines.

---

## Controls & Safe Mode

### Hotkey Reference

| Shortcut | Target File | Controlling Function | Operational Scope |
| :--- | :--- | :--- | :--- |
| **`Shift + F8`** | `kernel/KernelTaskManager.lua` | `toggleHUD()` | Toggles Kernel Task Manager HUD. Keystroke ignored if Shift is not held. |
| **`Shift + F7`** | `Bootloader.lua` | `openUpdateModal()` | Toggles Update Gate and diff viewer. Ignored if a textbox is focused. |
| **`Shift + F6` / `F6`** | `gameloaded/OmniLoadstringManager.lua` | `toggleManager()` | Toggles Loadstring & Trust Manager. Pressing `Escape` closes modal. |
| **`Hold Shift at Launch`** | `Bootloader.lua` | Frame 0 Early Check | Engages Safe Mode. Bypasses third-party autoexec scripts with 0ms added delay. |

### Safe Mode Architecture & Trigger Vectors

Safe Mode isolates the client environment if a third-party script causes a crash, infinite loop, or hook corruption.

#### Trigger Vectors (Frame 0)
1. **Pre-Held Shift Key**: `UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)` checked synchronously at Frame 0 with **0ms artificial delay**.
2. **Manual Lockfile**: `workspace/SAFE_MODE.lock` detected on disk (generated via `install.bat -s` or `getgenv().RejoinSafeMode()`), deleted immediately upon detection.
3. **Crash Sentinel**: `workspace/Bootloader_Running.lock` detected on disk. The bootloader writes this lockfile on startup and deletes it only when Ring 1 (`preinit/`) completes. If an autoexec script causes a crash or freeze during boot, the sentinel persists, automatically engaging Safe Mode on the next launch.
4. **Hook Poisoning**: Detected if an earlier autoexec script hijacked or tampered with core primitives (`clonefunction`, `iscclosure`, `debug.info`).

#### Safe Mode Suppression Matrix
* **Rings 0–4 (`kernel/`, `preinit/`, `gameloaded/`, `characterloaded/`, `deferred/`)**: Bypassed completely.
* **Remote GitHub Bootstrap**: Bypassed.
* **Dynamic Bootloader Handoff**: Bypassed.
* **Update Gate HUD (`Shift + F7`)**: Remains operational, allowing users to view diffs, roll back changes, or reinstall components.
* **Diagnostic Backdoor (`autoexec/preinit/RemoteExecute.txt`)**: If present, this file is explicitly executed via `task.spawn`. This provides an out-of-band channel for external launchers (Potassium, RAM, Voidstrap) or developers to inject diagnostic code into an otherwise clean environment.
* **Helper Function**: `getgenv().RejoinSafeMode()` remains exported to allow automated safe restarts.

### Remote Safety Advisory

The bootloader checks `manifest.json` on startup for an emergency lockdown advisory (`lockdown == true`). If active:
* Omni immediately halts all execution rings and removes `Bootloader_Running.lock`.
* An advisory notice is displayed in the Update Gate (`Shift + F7`).
* Omni **never** disconnects the client or closes the game session. The player remains connected, while third-party rings remain unloaded to protect accounts against unexpected engine updates or detection vectors.

---

## Global Wait Hooking & Game Isolation

### Trampoline Architecture & Primitive Cloning

During Frame 0 initialization, Omni clones pristine native C-closures of `task.wait` and `wait` before any third-party script can tamper with the environment:
```lua
local _clonedTaskWait = _capturePrimitive(_rawTaskWait, "task.wait")
local _clonedWait = _capturePrimitive(_rawWait, "wait")
getgenv()._KernelOrigTaskWait = _clonedTaskWait
getgenv()._KernelOrigWait = _clonedWait
```
Lightweight trampolines are installed using `hookfunction(task.wait, newcclosure(taskWaitTrampoline))` and `hookfunction(wait, newcclosure(waitTrampoline))`. A thread re-entrancy guard (`activeWaitThreads[curThread]`) ensures internal kernel calls bypass interception.

### Caller Attribution & Monitor-Only Guarantee

Every wait call is attributed via `isExecutorOrigin`:
* Inspects `checkcaller()` if supported by the executor.
* Inspects call-stack paths via `debug.info`. Paths matching engine containers (`workspace.`, `playerscripts`, `playergui`, `replicatedstorage`, `starterplayer`, `_clientcontrols`, `chatscript`, `bubblescript`, `camerascrip`, `animate`) are classified as native game scripts (`isExecutor = false`).
* Paths containing executor indicators (`executorscript`, `.lua`, `.txt`, `.iy`, `autoexec`, `potassium`, `banana`, `infiniteyield`, `dex`, `spy`) are classified as executor scripts (`isExecutor = true`). Unrecognized paths default safely to `false`.

```lua
-- Game Script Isolation Boundary (KernelTaskManager.lua)
if not loop.isExecutor and not loop.allowGameOverride then
    local res = waitFn(duration)
    loop.iterationStart = os.clock()
    return res
end
```

**Monitor-Only Invariant**: Native game loops are timed exclusively for HUD CPU accounting and telemetry. They are:
* **Never paused**: `loop.paused` checks are bypassed.
* **Never delay-clamped**: Frequency throttling clamps (`effectiveDelay = loop.minDelay`) are bypassed.
* **Never permanently suspended**: Termination checks (`coroutine.yield()`) are bypassed.
* Control functions (`SetLoopPaused`, `SetLoopFrequency`, `KillLoop`) explicitly reject non-executor game loops.
* Bulk actions (`PauseAllLoops`, `KillAllLoops`) iterate strictly over executor loops.
* Game physics, character movement, animations, weapons, and network replication run at 100% native engine timing.

### Wait Hook Off-Switch & Fast-Path Bypass

Wait hooking can be completely bypassed through either of two mechanisms:

1. **Static Configuration (`Omni_Settings.json`)**:
   Add `"disable_wait_hooks": true` to `workspace/Omni_Settings.json`:
   ```json
   {
     "disable_wait_hooks": true
   }
   ```
   At startup, the bootloader sets `getgenv()._OmniEnableWaitHooks = false`. The kernel skips calling `hookfunction` entirely, leaving pristine C-closures untouched.

2. **Zero-Latency Dynamic Runtime Switch**:
   ```lua
   getgenv()._OmniDisableWaitHooks = true
   ```
   Evaluated at the very first line of `hookedTaskWait` and `hookedWait`:
   ```lua
   local function hookedTaskWait(duration)
       if getgenv()._OmniEnableWaitHooks == false or getgenv()._OmniDisableWaitHooks == true then
           local waitFn = getgenv()._KernelOrigTaskWait or origTaskWait or rawTaskWait
           return waitFn(duration)
       end
       -- [hooked logic]
   end
   ```
   Takes effect on the very next `wait` invocation across the client. Requires **no client restart, no rejoin, and no teleport**.

---

## Developer API

The virtual scheduler exports `getgenv().ThrottledConnect` for frequency-capped, priority-sorted event bindings.

### ThrottledConnect Specification

```lua
local conn = getgenv().ThrottledConnect(event, priorityBand, callback, [taskName])
```

#### Supported Overloads
* `ThrottledConnect(event, priorityBand, callback, [taskName])`
* `ThrottledConnect(taskName, event, priorityBand, callback)`
* `ThrottledConnect(event, callback)` (defaults priority to `"High"`)
* `ThrottledConnect(callback)` (defaults event to `RunService.Heartbeat`, priority to `"High"`)

### Priority Bands & Execution Frequencies

| Band Name | Accepted Aliases | Default Priority | Numeric Range | Target Rate (at 60 FPS) | Frame Interval | Intended Workload |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| **High** | `"physics"`, `"movement"`, `"60hz"`, `"60"`, `"1"`, `"max"` | 90 | >= 75 | 60Hz (live max) | 1 (every frame) | CFrame lerping, movement mods, physics calculations |
| **Medium** | `"med"`, `"esp"`, `"radar"`, `"30hz"`, `"30"`, `"2"` | 60 | 45..74 | 30Hz (`maxHz * 0.5`) | 2 (every 2nd frame) | Visual adornments, ESP boxes, player tracers |
| **Low** | `"farm"`, `"autofarm"`, `"stat"`, `"ui"`, `"15hz"`, `"15"`, `"4"` | 30 | 20..44 | 15Hz (`maxHz * 0.25`) | 4 (every 4th frame) | UI counters, automated farming, inventory scanners |
| **Eco** | `"5hz"`, `"5"` | 15 | 10..19 | 5Hz (fixed) | `maxHz / 5` | Background stat polling, remote keepalives |
| **Idle** | `"1hz"`, `"1"` | 5 | < 10 | 1Hz (fixed) | `maxHz / 1` | Cache garbage collection, memory cleanup |

*Note: Custom target frequencies can also be specified directly as numbers (e.g. `20`) or frequency strings (e.g. `"20hz"`).*

### Connection Methods

The connection object returned by `ThrottledConnect` exposes the following methods:
* `conn:Disconnect()`: Unregisters the task from the scheduler and cleans queued frames.
* `conn:Pause()`: Temporarily suspends callback execution while retaining connection state.
* `conn:Resume()`: Resumes execution of a paused connection.
* `conn:SetPriority(newPri)`: Updates task priority (band string or 1–100 number) and recalculates schedule order.
* `conn:SetTargetHz(newHz)`: Updates target frequency in Hertz and recalculates frame interval.
* `conn:Lock()`: Protects the task from automatic governor down-throttling.
* `conn:Unlock()`: Re-enables automatic governor down-throttling.

### Global Helpers
* `getgenv().UnloadAllTasks()`: Global panic switch that disconnects all active tasks and terminates executor loops.
* `getgenv().ToggleTaskManagerHUD()`: Programmatically toggles the Task Manager HUD.

### Implementation Examples

#### Example 1: Capped Visual ESP Loop (30Hz / Medium)
```lua
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Connects an ESP rendering loop capped at 30Hz to conserve frame time
local espConn = getgenv().ThrottledConnect(
    "PlayerESP",
    RunService.RenderStepped,
    "Medium",
    function(deltaTime)
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= Players.LocalPlayer and player.Character then
                -- Update billboard or box adornments
            end
        end
    end
)

-- Lock priority so heavy scenes do not down-throttle ESP below 30Hz
espConn:Lock()

-- To clean up on script unload:
-- espConn:Disconnect()
```

#### Example 2: Background State Polling (5Hz / Eco)
```lua
local RunService = game:GetService("RunService")

-- Connects a state poll running at 5Hz
local farmConn = getgenv().ThrottledConnect(
    "QuestScanner",
    RunService.Heartbeat,
    "Eco",
    function(dt)
        -- Poll remote data or quest progression
    end
)

-- Pause when player is in combat
farmConn:Pause()

-- Resume when safe
farmConn:Resume()
```

#### Example 3: Dynamic Frequency Scaling
```lua
local RunService = game:GetService("RunService")

-- Connects a telemetry task defaulting to 15Hz
local telemetry = getgenv().ThrottledConnect(RunService.Heartbeat, 15, function(dt)
    -- Telemetry logic
end, "Telemetry")

-- Throttle down to 1Hz when client window loses focus
game:GetService("UserInputService").WindowFocused:Connect(function()
    telemetry:SetTargetHz(15)
end)

game:GetService("UserInputService").WindowFocusReleased:Connect(function()
    telemetry:SetTargetHz(1)
end)
```

---

## Installation & Configuration

### Automated Setup (install.ps1)

Run this command in PowerShell to automatically deploy Omni:

```powershell
irm https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.ps1 | iex
```

* **Executor Auto-Discovery**: Scans `$env:LOCALAPPDATA`, `$env:APPDATA`, Desktop, Downloads, and Documents for directories containing sibling `workspace` and `autoexec` (or `autoexe`) folders.
* **BOM-Less UTF-8 Deployment**: Writes all script files using `[Text.UTF8Encoding]::new($false)` (UTF-8 without Byte Order Mark) to prevent executor Luau syntax errors caused by 3-byte `\xEF\xBB\xBF` prefixes.
* **Legacy Script Migration**: Moves existing loose scripts from `autoexec/` to `workspace/autoexec/preinit/` so they retain immediate Frame 0 execution. Original scripts are backed up to `autoexec/_legacy_backup_<timestamp>/`. If duplicate filenames exist in `preinit/`, the installer preserves the destination file and leaves the original in the backup folder.
* **Batch Recovery Wrapper (`install.bat`)**: Provides a local Windows batch launcher supporting `install.bat --safemode` (or `-s`) to write `workspace/SAFE_MODE.lock` across all discovered executors.

### Manual Directory Layout

If configuring manually, place `Bootloader.lua` into your executor's `autoexec/` directory and organize components within `workspace/autoexec/`:

```text
YourExecutor/
├── autoexec/
│   └── Bootloader.lua                  # Primary entry point (Frame 0 bootloader)
└── workspace/
    ├── Omni_Settings.json              # Optional configuration overrides
    ├── Omni_Ledger.json                # Installed component version ledger
    ├── manifest.json                   # Component checksums and metadata
    └── autoexec/
        ├── kernel/                     # Ring 0: Micro-kernel & scheduler
        │   └── KernelTaskManager.lua
        ├── preinit/                    # Ring 1: Concurrent Frame 0 scripts
        ├── gameloaded/                 # Ring 2: Executes after game:IsLoaded() (6.0ms budget)
        │   ├── OmniEnhancementSuite.lua
        │   └── OmniLoadstringManager.lua
        ├── characterloaded/            # Ring 3: Executes after LocalPlayer.Character (6.0ms budget)
        └── deferred/                   # Ring 4: Idle background routines (1 script/frame)
```

### Runtime Configuration (Omni_Settings.json)

Settings are configured via `workspace/Omni_Settings.json`:

```json
{
  "disable_wait_hooks": false
}
```

* `disable_wait_hooks` (`boolean`): When set to `true`, completely disables kernel `task.wait` and `wait` trampolines at boot.

---

## Optional Modules

### Omni Enhancement Suite

Located at `workspace/autoexec/gameloaded/OmniEnhancementSuite.lua`:
* **Streamer Mode**: Redacts or spoofs usernames, display names, and UserIDs across leaderboards and overhead player tags.
* **Personal Space Bubble**: Smoothly fades avatar transparencies within a configurable radius around the local character using distance falloff and temporal lerping.
* **Player Locator & ESP**: Hardware-efficient box adornments, an on-demand highlight pool (up to 255 adornments), raycast tracers, and team filtering.
* **Anti-AFK**: Engine-level inactivity kick prevention via simulated input dispatch.
* **Native ESC Menu Integration**: Injects enhancement toggles directly into the native Roblox in-game ESC Settings menu without external overlay frames.

---

## Licensing

Omni is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).

### Permitted Uses
* Free to use, modify, adapt, and distribute for noncommercial purposes, personal gameplay, private research, and educational study.
* Contributing modifications back to the open-source repository.

### Explicit Prohibitions
* Commercial sale, resale, licensing, sublicensing, or charging fees for access, hosting, or distribution.
* Packaging or gating the software behind paywalls, monetized link shorteners (explicitly including **Linkvertise** and **Lootlabs**), monetization services, or paid key systems.
* Commercial deployment in any revenue-generating product or service without an explicit commercial license from the author.
