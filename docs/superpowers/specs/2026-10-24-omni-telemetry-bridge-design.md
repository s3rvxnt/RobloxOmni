# Omni Live State & Event Black-Box Telemetry Bridge Design (`RemoteExecute` + `roblox_client.py`)

**Date:** 2026-10-24  
**Stage:** `PreInit` (`--!priority 250`, `--!name RemoteExecute`)  
**Files:**
- `preinit/RemoteExecute.lua` (deployed to `<workspace>/autoexec/preinit/RemoteExecute.txt`)
- `C:\Users\admin\.gemini\config\skills\roblox-execution-environment\scripts\roblox_client.py`

---

## 1. Objectives
Upgrade the file-based IPC bridge (`RemoteExecute.txt` and `roblox_client.py`) into a full-awareness, zero-hook telemetry and execution bridge so the agent is continuously aware of everything happening in the live Roblox session without needing blind `--eval` queries.

### Core Invariants
1. **100% Hookless & Anticheat/Obfuscator Safe**:
   - Never call `hookmetamethod`, `hookfunction`, or modify `getgenv().game`.
   - Rely exclusively on native `RBXScriptSignal` connections (`LogService.MessageOut`, `TextChatService.MessageReceived`, `ProximityPromptService.PromptTriggered`, `GuiService.ErrorMessageChanged`, character/humanoid/tool signals) and `pcall`-guarded property reads.
2. **Zero Frame Stutter**:
   - Command polling runs at `50ms` (`20Hz`).
   - Event stream (`<Account>_Events.jsonl`) flushes batched lines at `0.5s` (`2Hz`) and auto-rotates at `256 KB`.
   - Full state snapshot (`<Account>_State.json` and `ActiveClients.json`) updates at `1.0s` (`1Hz`).
3. **Clean Hot-Reload Lifecycle**:
   - Exposes `getgenv()._OmniRemoteExecuteCleanUp()` so re-executing `RemoteExecute` tears down all previous connections and loops cleanly before starting the new generation.

---

## 2. Client-Side Architecture (`preinit/RemoteExecute.lua`)

### 2.1 Fast IPC Execution Loop (`50ms`)
- Polls `<Account>_External.lua` every `0.05s`.
- Wraps execution in `xpcall(compiledCode, function(err) return debug.traceback(tostring(err), 2) end)` so runtime errors include full stack traces in both `RemoteExecute_Logs.txt` and `<Account>_Events.jsonl` (`EXEC_ERROR`).
- Emits `EXEC_START` and `EXEC_OK` / `EXEC_ERROR` events to the black-box stream.

### 2.2 1Hz Live World Snapshot (`<Account>_State.json` & `ActiveClients.json`)
Every `1.0s`, writes a structured JSON snapshot to `<Account>_State.json` (and embeds a compact summary inside `ActiveClients.json[AccountName]`):
- **`session`**: `account`, `displayName`, `userId`, `placeId`, `jobId`, `placeName`, `uptimeSec`, `timestamp`, `fps`, `pingMs`, `luaHeapMB`.
- **`kickState`**: `isKicked`, `errorCode`, `errorMessage` (inspected from `GuiService:GetErrorMessage()` and `CoreGui.RobloxPromptGui.promptOverlay.ErrorPrompt`).
- **`player`**:
  - `alive`, `health`, `maxHealth`, `walkSpeed`, `jumpPower`, `humanoidState`, `sit`, `platformStand`
  - `position` (`[x, y, z]`), `velocity` (`[vx, vy, vz]`), `speed`, `lookVector` (`[lx, ly, lz]`)
  - `cameraCFrame` (`pos`, `look`), `cameraLookTarget` (raycast up to 150 studs from camera center: `instance`, `className`, `distance`, `hitPos`)
  - `equippedTool` (`name`, `gripPos`, `attributes`), `backpackCount`, `backpackSample` (up to 15 tool names)
  - `attributes` (combined `LocalPlayer:GetAttributes()` and `Character:GetAttributes()`)
  - `leaderstats` (key-value map from `LocalPlayer:FindFirstChild("leaderstats")`)
- **`surroundings`**:
  - `nearbyPlayers`: up to 10 nearest players sorted by distance (`name`, `displayName`, `distance`, `health`, `tool`, `position`)
  - `nearbyEntities`: up to 10 nearest non-player models with a `Humanoid` or primary part in `Workspace` (`name`, `path`, `distance`, `health`)
  - `nearbyPrompts`: up to 8 nearest enabled `ProximityPrompt`s within 65 studs (`actionText`, `objectText`, `path`, `distance`, `holdDuration`, `keyCode`)
  - `visibleGuis`: list of enabled top-level `ScreenGui` names in `PlayerGui`
- **`omni`**:
  - `packetMetrics`: live output from `getgenv().GetOmniPacketMetrics()` (inbound/outbound KB/s, pkt/s, buffered count)
  - `recentPackets`: last 5 dissected replication packets from `getgenv().GetOmniCapturedPackets()` (`dir`, `id`, `target`, `size`, `args`)
  - `taskMetrics`: active loop count, auto-killed `:Wait()` leak count (`getgenv()._OmniWaitLeakAutoKills`)

### 2.3 Bounded Event Black-Box (`<Account>_Events.jsonl`)
Event-driven listeners push structured JSON objects `{ ts, clock, seq, type, summary, data }` into an in-memory queue (with per-key deduplication over a `1.0s` window so spam loops never flood the log) and flush every `0.5s`:
- `CONSOLE_ERROR` / `CONSOLE_WARN` / `CONSOLE_PRINT` (via `LogService.MessageOut`)
- `CHAT_IN` / `CHAT_OUT` (via `TextChatService.MessageReceived` and `SendingMessage`)
- `PROMPT_TRIGGERED` / `PROMPT_SHOWN` (via `ProximityPromptService.PromptTriggered` and `PromptShown`)
- `TOOL_EQUIPPED` / `TOOL_UNEQUIPPED` / `TOOL_ACTIVATED`
- `HEALTH_DAMAGE` / `HEALTH_HEAL` / `DIED` / `CHAR_SPAWNED`
- `ATTR_CHANGED` (on `LocalPlayer` and `LocalPlayer.Character`)
- `KICK_OR_ERROR_PROMPT` (immediate flush when `GuiService.ErrorMessageChanged` or `ErrorPrompt` appears)
- `EXEC_OK` / `EXEC_ERROR`

---

## 3. Python CLI Enhancements (`roblox_client.py`)
1. **`--status`**:
   - Displays enriched columns / summary when `<Account>_State.json` is available (FPS, Ping, Health, Position, Equipped Tool, and immediate `KICKED` alert if `kickState.isKicked` is true).
2. **`--context` (`-c`)**:
   - Reads `<Account>_State.json` and the last N events from `<Account>_Events.jsonl` directly from disk in `< 5ms` (supports `--json` for raw JSON or human-readable dashboard output).
3. **`--events` (`--events-tail N`, `--events-type TYPE`, `--events-follow`)**:
   - Displays or tails the structured `<Account>_Events.jsonl` stream with optional event-type filtering.
