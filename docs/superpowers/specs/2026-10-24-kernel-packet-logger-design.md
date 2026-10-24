# Omni Kernel Packet Logger (`KernelPacketLogger.lua`) Design Specification

- **Date**: 2026-10-24
- **Stage**: `Kernel` (`kernel/KernelPacketLogger.lua` -> `autoexec/kernel/KernelPacketLogger.lua`)
- **Shortcut**: `Shift + F5`
- **Theme**: Unified Omni Dark Theme (matching `KernelTaskManager` `Shift + F8`, `Bootloader` `Shift + F7`, and `OmniLoadstringManager` `Shift + F6`)

---

## 1. Overview & Goals

`KernelPacketLogger.lua` is a Ring-0 kernel telemetry and packet inspection module for Omni that hooks Potassium's native `raknet.add_receive_hook` and `raknet.add_send_hook` to provide:

1. **Zero-Overhead Always-On Wire Telemetry**:
   - Continuously tracks inbound and outbound byte rates (`KB/s`), packet rates (`pkt/s`), blocked packet counts, and per-`PacketId` histograms with zero table allocations on the hot path.
   - Exposes `getgenv().GetOmniPacketMetrics()` so `KernelTaskManager.lua` (`Shift + F8`) and external scripts can query live network telemetry.
2. **Bounded Circular Ring-Buffer Capture**:
   - Captures full packet payloads (`packet.AsBuffer` / `packet.AsString`) when the `Shift + F5` window is open or when `Pin Background Record` is enabled.
   - Enforces a strict `2,000` packet / `8 MB` memory ceiling with `O(1)` circular eviction so long sessions never leak RAM.
   - Mutes high-frequency noise (`0x85` Physics and `0x1B` TimeSync/Ping) by default via 1-click filter chips.
3. **Lazy On-Demand `0x83` Replication Dissector & Hex/ASCII Viewer**:
   - Dissects Roblox `0x83` (`ID_DATA`) replication packets into human-readable sub-items (`0x01` DeleteInstance, `0x02` NewInstance, `0x03` PropertyChange, `0x05` Ping/Timestamp, `0x07` EventInvocation/Remote, `0x0A` Ack, `0x12` Hash, `0x13`Tag, etc.) and extracts printable ASCII strings (`RemoteEvent` names, property/attribute names, chat strings, asset URLs) only when rows are rendered or selected.
   - Renders a formatted side-by-side Offset + Hex + ASCII dump for the selected packet.
4. **Active Packet Control (Block, Replay & Code Generation)**:
   - **Block**: 1-click blocking by `PacketId` (with safety warnings on critical handshake/keepalive IDs) or by substring match inside packet payloads.
   - **Replay**: Immediate outbound packet replay via `raknet.send(payloadBuffer, priority, reliability, orderingChannel)`.
   - **Copy Replay Script**: Generates a standalone Luau script using `buffer.fromstring(...)` and `raknet.send(...)` and copies it to the clipboard (`setclipboard`).

---

## 2. Architecture & Data Flow

### 2.1 Ring-0 Initialization (`--!stage Kernel`, `--!priority 90`)
- Synchronously registers `raknet.add_receive_hook` and `raknet.add_send_hook` at Frame 0 without yielding.
- Supports clean hot-reload and teardown via `getgenv()._KernelPacketLoggerCleanUp()`, removing hooks with `raknet.remove_receive_hook` / `raknet.remove_send_hook`, disconnecting UI connections, and unbinding the first-person cursor unlock step (`"OmniPacketLoggerCursor"`).

### 2.2 Hot-Path Hook Invariants
- Never hooks `game.__namecall` or modifies Luau environment globals (`getgenv().game`), maintaining 100% compatibility with Luarmor/Luraph.
- In `onReceive(pkt)` and `onSend(pkt)`:
  1. Read `pkt.PacketId`, `pkt.Size`, `pkt.Reliability`, `pkt.Priority`, `pkt.OrderingChannel`.
  2. Check `blockedPacketIds[dirKey]` and optional string block filters; if matched, call `pkt:Block()`.
  3. Increment 1-second rolling window and lifetime counters.
  4. If `isCapturing` (`(windowOpen or pinBackgroundRecord) and not isPaused`) and `not mutedPacketIds[packetId]`:
     - Copy `pkt.AsBuffer` (or truncated preview up to `65,536` bytes) and push a lightweight record into the `2,000`-slot circular ring buffer.

### 2.3 Lazy Dissector (`dissectPacket(entry)`)
- Cached on `entry._dissected` the first time an entry is rendered in the virtualized viewport or selected in the inspector:
  - Identifies known RakNet / Roblox packet types (`0x00`–`0x1B` RakNet control, `0x81` Schema/Descriptors, `0x82` Kick/Disconnect, `0x83` Replication DataStream, `0x84` Marker, `0x85` Physics/Humanoid, `0x86` Touch, `0x87` Chat, `0x8F` Voice/Stream, `0x90` Auth).
  - Extracts printable ASCII runs (`>= 4` chars) for instant summary previews and search matching.
  - For `0x83` packets, scans sub-packet framing and builds a structured tree of sub-items and embedded identifiers.

### 2.4 UI Layout (`Shift + F5`)
- **Window Frame**: `860 x 540` (resizable down to `680 x 400`), `Color3.fromRGB(15, 17, 23)`, `8px` corner radius, `1px` stroke `Color3.fromRGB(45, 52, 68)`.
- **Header (`38px`)**: Title `⚡ OMNI KERNEL PACKET LOGGER`, badge `Shift + F5`, and `[X]` close button.
- **Telemetry Bar (`54px`)**: 4 metric cards (`INBOUND`, `OUTBOUND`, `BLOCKED`, `RING BUFFER`).
- **Filter & Control Bar (`36px`)**: Direction & type chips (`All`, `↓ In`, `↑ Out`, `0x83 Data`, `Mute 0x85`, `Mute 0x1B`), search box, `Pause/Resume`, `Pin Rec`, and `Clear`.
- **Split Body**:
  - **Left (`52%` width)**: Virtualized `ScrollingFrame` packet table (`#`, `Dir`, `Type`, `Size`, `Rel`, `Summary`) rendering only visible rows (`26px` row height).
  - **Right (`48%` width)**: Tabbed Inspector (`Dissector & Strings` | `Hex & ASCII` | `Block Rules`) + bottom action buttons (`Block ID`, `Replay Outbound`, `Copy Luau`).
