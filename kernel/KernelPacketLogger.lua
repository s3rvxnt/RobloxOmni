--!stage Kernel
--!priority 90
--!name KernelPacketLogger

--[[
    ==============================================================================
    OMNI KERNEL PACKET LOGGER & 0x83 REPLICATION DISSECTOR (Shift + F5)
    ==============================================================================
    - Ring-0 inbound & outbound RakNet replication packet logger and analyzer.
    - Zero-allocation hot path: passive bandwidth & PacketId histograms run
      continuously; full buffer capture activates when Shift + F5 is open or
      when Pin Record is enabled.
    - Bounded 2,000-packet / 8 MB circular ring buffer with O(1) eviction.
    - On-demand Roblox 0x83 replication stream dissector, ASCII string extractor,
      side-by-side Hex + ASCII viewer, per-PacketId mute/block rules, outbound
      packet replay (raknet.send), and Luau replay script generator.
    ==============================================================================
]]

local genv = (getgenv and getgenv()) or _G

-- Teleport / DataModel boundary detection
local currentDM = game
if genv._OmniPacketLoggerDataModel and genv._OmniPacketLoggerDataModel ~= currentDM then
    genv._KernelPacketLoggerCleanUp = nil
    genv._KernelPacketLoggerLoaded = nil
    genv._KernelPacketLoggerRunning = nil
    genv._KernelPacketLoggerGui = nil
end
genv._OmniPacketLoggerDataModel = currentDM

local currentGen = (genv._OmniPacketLoggerGeneration or 0) + 1
genv._OmniPacketLoggerGeneration = currentGen

if type(genv._KernelPacketLoggerCleanUp) == "function" then
    pcall(genv._KernelPacketLoggerCleanUp)
end

genv._OmniPacketLoggerGeneration = currentGen
genv._KernelPacketLoggerLoaded = true
genv._KernelPacketLoggerRunning = true

-- ==============================================================================
-- RAKNET CAPABILITY DETECTION
-- ==============================================================================
local raknetTable = type(raknet) == "table" and raknet or nil
local raknetAddReceiveHook = raknetTable and raknetTable.add_receive_hook
local raknetRemoveReceiveHook = raknetTable and raknetTable.remove_receive_hook
local raknetAddSendHook = raknetTable and raknetTable.add_send_hook
local raknetRemoveSendHook = raknetTable and raknetTable.remove_send_hook
local raknetSend = raknetTable and raknetTable.send

local hasRakNetHooks = type(raknetAddReceiveHook) == "function" and type(raknetAddSendHook) == "function"
local hasRakNetSend = type(raknetSend) == "function"

-- ==============================================================================
-- CONSTANTS & PACKET CLASSIFICATION TABLES
-- ==============================================================================
local MAX_RING_PACKETS = 2000
local MAX_RING_BYTES = 8 * 1024 * 1024 -- 8 MB hard cap
local MAX_SINGLE_PACKET_BYTES = 65536

local PACKET_NAMES = {
    [0x00] = "ID_CONNECTED_PING",
    [0x01] = "ID_UNCONNECTED_PING",
    [0x03] = "ID_CONNECTED_PONG",
    [0x04] = "ID_DETECT_LOST_CONNECTIONS",
    [0x05] = "ID_OPEN_CONNECTION_REQ_1",
    [0x06] = "ID_OPEN_CONNECTION_REPLY_1",
    [0x07] = "ID_OPEN_CONNECTION_REQ_2",
    [0x08] = "ID_OPEN_CONNECTION_REPLY_2",
    [0x09] = "ID_CONNECTION_REQUEST",
    [0x10] = "ID_CONNECTION_REQUEST_ACCEPTED",
    [0x15] = "ID_DISCONNECTION_NOTIFICATION",
    [0x16] = "ID_CONNECTION_LOST",
    [0x1B] = "ID_TIMESTAMP (Ping)",
    [0x81] = "ID_SCHEMA (Descriptors)",
    [0x82] = "ID_KICK (Disconnect)",
    [0x83] = "ID_DATA (Replication)",
    [0x84] = "ID_MARKER (Sync)",
    [0x85] = "ID_PHYSICS (CFrame/Vel)",
    [0x86] = "ID_TOUCH (Collision)",
    [0x87] = "ID_CHAT (Message)",
    [0x89] = "ID_REPORT_STATS",
    [0x8A] = "ID_CLUSTER (Terrain)",
    [0x8F] = "ID_STREAM_DATA",
    [0x90] = "ID_AUTH_CHALLENGE",
    [0xA1] = "ID_UNRELIABLE_STREAM",
}

local RELIABILITY_NAMES = {
    [0] = "Unrel",
    [1] = "UnrelSeq",
    [2] = "Rel",
    [3] = "RelOrd",
    [4] = "RelSeq",
}

local SUBPACKET_0X83_NAMES = {
    [0x01] = "DeleteInstance",
    [0x02] = "CreateInstance",
    [0x03] = "PropertyChange",
    [0x04] = "InstanceMarker",
    [0x05] = "PingSync",
    [0x06] = "PingAck",
    [0x07] = "EventInvocation (Remote)",
    [0x08] = "RequestCharacter",
    [0x09] = "CallbackResult",
    [0x0A] = "NetStatsAck",
    [0x0B] = "JoinDataStream",
    [0x0C] = "UpdateOwnership",
    [0x0D] = "StreamRegion",
    [0x10] = "ReplicationTag",
    [0x11] = "MemoryStats",
    [0x12] = "SecurityHash",
    [0x13] = "DataModelAttr",
    [0x14] = "StreamingPause",
    [0x15] = "UnreliableRemote",
}

-- ==============================================================================
-- CIRCULAR RING BUFFER & TELEMETRY STATE
-- ==============================================================================
local ringStorage = {}
local ringHead = 1
local ringCount = 0
local ringBytes = 0
local sequenceCounter = 0

local isWindowOpen = false
local isPinnedRecording = false
local isPaused = false

-- Noisy high-frequency packets muted from ring buffer capture by default (still counted in stats)
local mutedPacketIds = {
    [0x85] = true, -- ID_PHYSICS (60Hz movement stream)
    [0x1B] = true, -- ID_TIMESTAMP (Ping)
    [0x00] = true, -- ID_CONNECTED_PING
    [0x03] = true, -- ID_CONNECTED_PONG
}

-- Block rules: blockedPacketIds[packetId] = "both" | "in" | "out" | nil
local blockedPacketIds = {}
local blockedSubstrings = {}

-- Filter state for UI
local filterDirection = "all" -- "all" | "in" | "out"
local filterOnly0x83 = false
local searchQuery = ""
local selectedEntry = nil
local activeInspectorTab = "Dissector" -- "Dissector" | "Hex" | "Rules"

-- Rolling 1-second counters & lifetime totals
local windowInBytes = 0
local windowOutBytes = 0
local windowInPackets = 0
local windowOutPackets = 0
local windowBlockedPackets = 0

local totalInBytes = 0
local totalOutBytes = 0
local totalInPackets = 0
local totalOutPackets = 0
local totalBlockedPackets = 0

local inKBps = 0.0
local outKBps = 0.0
local inPktsSec = 0
local outPktsSec = 0
local blockedPktsSec = 0
local lastRollClock = os.clock()

-- Per-PacketId stats: packetStats[packetId] = { id, inPkts, outPkts, inBytes, outBytes, blocked }
local packetStats = {}

local function getPacketStat(pktId)
    local id = tonumber(pktId) or -1
    local st = packetStats[id]
    if not st then
        st = {
            id = id,
            name = PACKET_NAMES[id] or string.format("0x%02X (%d)", id >= 0 and id or 0, id),
            inPkts = 0,
            outPkts = 0,
            inBytes = 0,
            outBytes = 0,
            blocked = 0,
        }
        packetStats[id] = st
    end
    return st
end

-- ==============================================================================
-- RING BUFFER OPERATIONS (O(1) PUSH & EVICTION)
-- ==============================================================================
local function ringPhysicalIndex(logicalIdx)
    return ringHead + logicalIdx - 1
end

local function ringCompact()
    local nextStorage = table.create(ringCount)
    for i = 1, ringCount do
        nextStorage[i] = ringStorage[ringPhysicalIndex(i)]
    end
    ringStorage = nextStorage
    ringHead = 1
end

local function ringPopOldest()
    if ringCount <= 0 then return nil end
    local old = ringStorage[ringHead]
    ringStorage[ringHead] = nil
    ringHead = ringHead + 1
    ringCount = ringCount - 1
    if old and old.storedBytes then
        ringBytes = math.max(0, ringBytes - old.storedBytes)
    end
    if ringCount == 0 then
        ringStorage = {}
        ringHead = 1
    elseif ringHead > 1024 and (ringHead - 1) > ringCount then
        ringCompact()
    end
    return old
end

local function ringPush(entry)
    local eb = entry.storedBytes or 0
    while ringCount > 0 and (ringCount >= MAX_RING_PACKETS or (ringBytes + eb) > MAX_RING_BYTES) do
        ringPopOldest()
    end
    ringCount = ringCount + 1
    ringStorage[ringPhysicalIndex(ringCount)] = entry
    ringBytes = ringBytes + eb
end

local function ringClear()
    ringStorage = {}
    ringHead = 1
    ringCount = 0
    ringBytes = 0
    selectedEntry = nil
end

local function ringGet(logicalIdx)
    if logicalIdx < 1 or logicalIdx > ringCount then return nil end
    return ringStorage[ringPhysicalIndex(logicalIdx)]
end

-- ==============================================================================
-- BUFFER & PAYLOAD EXTRACTION HELPERS
-- ==============================================================================
local function extractPayloadString(pkt, declaredSize)
    local okBuf, rawBuf = pcall(function() return pkt.AsBuffer end)
    if okBuf and rawBuf ~= nil and type(buffer) == "table" then
        if type(buffer.len) == "function" and type(buffer.tostring) == "function" then
            local okLen, len = pcall(buffer.len, rawBuf)
            if okLen and type(len) == "number" then
                if len <= MAX_SINGLE_PACKET_BYTES then
                    local okStr, str = pcall(buffer.tostring, rawBuf)
                    if okStr and type(str) == "string" then
                        return str, false
                    end
                elseif type(buffer.readu8) == "function" then
                    local cap = math.min(len, 1024)
                    local chars = table.create(cap)
                    for i = 0, cap - 1 do
                        chars[i + 1] = string.char(buffer.readu8(rawBuf, i))
                    end
                    return table.concat(chars), true
                end
            end
        end
    end

    local okStr, rawStr = pcall(function() return pkt.AsString end)
    if okStr and type(rawStr) == "string" then
        if #rawStr > MAX_SINGLE_PACKET_BYTES then
            return rawStr:sub(1, 1024), true
        end
        return rawStr, false
    end

    return "", false
end

-- ==============================================================================
-- LAZY ON-DEMAND 0x83 DISSECTOR & HEX FORMATTER
-- ==============================================================================
local function dissectPacket(entry)
    if entry._dissected then
        return entry._dissected
    end

    local bytes = entry.payload or ""
    local len = #bytes
    local pktId = entry.packetId
    if pktId == nil and len >= 1 then
        pktId = bytes:byte(1)
        entry.packetId = pktId
    end

    local pktName = PACKET_NAMES[pktId] or (pktId and string.format("0x%02X", pktId) or "UNKNOWN")

    -- 1. Extract printable ASCII runs (>= 3 chars)
    local strings = {}
    local seenStrings = {}
    local runStart = nil
    for i = 1, math.min(len, 8192) do
        local b = bytes:byte(i)
        if b >= 32 and b <= 126 then
            if not runStart then runStart = i end
        else
            if runStart and (i - runStart) >= 3 then
                local s = bytes:sub(runStart, i - 1)
                if s:match("[A-Za-z0-9_]") and not seenStrings[s] then
                    seenStrings[s] = true
                    table.insert(strings, { offset = runStart - 1, text = s })
                end
            end
            runStart = nil
        end
    end
    if runStart and (math.min(len, 8192) + 1 - runStart) >= 3 then
        local s = bytes:sub(runStart, math.min(len, 8192))
        if s:match("[A-Za-z0-9_]") and not seenStrings[s] then
            seenStrings[s] = true
            table.insert(strings, { offset = runStart - 1, text = s })
        end
    end

    -- 2. Dissect Roblox 0x83 (ID_DATA) sub-packet headers
    local subItems = {}
    if pktId == 0x83 and len >= 2 then
        -- Scan initial sub-item byte and subsequent framed sub-items
        local firstSub = bytes:byte(2)
        if SUBPACKET_0X83_NAMES[firstSub] then
            table.insert(subItems, {
                offset = 1,
                id = firstSub,
                name = SUBPACKET_0X83_NAMES[firstSub],
            })
        end

        -- Scan for length-prefixed strings and adjacent sub-packet markers in the first 512 bytes
        local scanMax = math.min(len - 4, 512)
        local idx = 3
        while idx <= scanMax and #subItems < 16 do
            local b = bytes:byte(idx)
            -- Check for uint16/uint8 length-prefixed ASCII identifier
            local strLen = b
            if strLen >= 3 and strLen <= 48 and (idx + strLen) <= len then
                local validAscii = true
                for k = idx + 1, idx + strLen do
                    local cb = bytes:byte(k)
                    if not ((cb >= 48 and cb <= 57) or (cb >= 65 and cb <= 90) or (cb >= 97 and cb <= 122) or cb == 95 or cb == 46 or cb == 32 or cb == 47) then
                        validAscii = false
                        break
                    end
                end
                if validAscii then
                    local prevByte = bytes:byte(idx - 1)
                    if SUBPACKET_0X83_NAMES[prevByte] and (#subItems == 0 or subItems[#subItems].offset ~= (idx - 2)) then
                        table.insert(subItems, {
                            offset = idx - 2,
                            id = prevByte,
                            name = SUBPACKET_0X83_NAMES[prevByte],
                            ident = bytes:sub(idx + 1, idx + strLen),
                        })
                    end
                    idx = idx + strLen + 1
                    continue
                end
            end
            idx = idx + 1
        end
    end

    -- 3. Build concise 1-line summary for table row
    local summaryParts = {}
    if #subItems > 0 then
        local names = {}
        for i = 1, math.min(2, #subItems) do
            local item = subItems[i]
            if item.ident then
                table.insert(names, string.format("[%s: %s]", item.name, item.ident))
            else
                table.insert(names, string.format("[%s]", item.name))
            end
        end
        table.insert(summaryParts, table.concat(names, " "))
    end
    if #strings > 0 then
        local strPreview = {}
        for i = 1, math.min(4, #strings) do
            table.insert(strPreview, '"' .. strings[i].text .. '"')
        end
        table.insert(summaryParts, table.concat(strPreview, " "))
    end
    local summary = #summaryParts > 0 and table.concat(summaryParts, " • ") or pktName

    local result = {
        packetName = pktName,
        strings = strings,
        subItems = subItems,
        summary = summary,
        searchBlob = (pktName .. " " .. summary):lower(),
    }
    entry._dissected = result
    return result
end

local function formatHexAsciiDump(bytes, maxBytes)
    if type(bytes) ~= "string" or #bytes == 0 then
        return "(Empty payload — 0 bytes)"
    end
    local limit = math.min(#bytes, maxBytes or 1024)
    local lines = {}
    for offset = 0, limit - 1, 16 do
        local hexCols = {}
        local asciiCols = {}
        for col = 0, 15 do
            local idx = offset + col + 1
            if idx <= limit then
                local b = bytes:byte(idx)
                hexCols[col + 1] = string.format("%02X", b)
                asciiCols[col + 1] = (b >= 32 and b <= 126) and string.char(b) or "."
            else
                hexCols[col + 1] = "  "
                asciiCols[col + 1] = " "
            end
        end
        local leftHex = table.concat(hexCols, " ", 1, 8)
        local rightHex = table.concat(hexCols, " ", 9, 16)
        local asciiStr = table.concat(asciiCols)
        table.insert(lines, string.format("%04X:  %s  %s  |%s|", offset, leftHex, rightHex, asciiStr))
    end
    if #bytes > limit then
        table.insert(lines, string.format("\n... (%d additional bytes truncated in preview; total %d bytes)", #bytes - limit, #bytes))
    end
    return table.concat(lines, "\n")
end

local function generateReplayScript(entry)
    if not entry or type(entry.payload) ~= "string" or #entry.payload == 0 then
        return "-- No payload bytes available to replay"
    end
    local bytes = entry.payload
    local chunks = { '"' }
    for i = 1, math.min(#bytes, 16384) do
        local b = bytes:byte(i)
        if b == 34 then
            table.insert(chunks, '\\"')
        elseif b == 92 then
            table.insert(chunks, "\\\\")
        elseif b >= 32 and b <= 126 then
            table.insert(chunks, string.char(b))
        else
            table.insert(chunks, string.format("\\%03d", b))
        end
    end
    table.insert(chunks, '"')
    local quoted = table.concat(chunks)
    local prio = tonumber(entry.priority) or 1
    local rel = tonumber(entry.reliability) or 3
    local ch = tonumber(entry.channel) or 0
    local pktId = tonumber(entry.packetId) or 0

    if entry.direction == "in" then
        return string.format(
            "-- Omni Kernel Packet Logger — Inbound Hook Template (PacketId 0x%02X)\n"
            .. "local TARGET_ID = 0x%02X\n"
            .. "local hook\n"
            .. "hook = raknet.add_receive_hook(function(pkt)\n"
            .. "    if pkt.PacketId == TARGET_ID then\n"
            .. "        print('[OmniPacketHook] Intercepted 0x' .. string.format('%%02X', pkt.PacketId), 'Size:', pkt.Size)\n"
            .. "        -- pkt:Block()\n"
            .. "    end\n"
            .. "end)\n"
            .. "-- To remove: raknet.remove_receive_hook(hook)",
            pktId, pktId
        )
    end

    return string.format(
        "-- Omni Kernel Packet Logger — Outbound Packet Replay (PacketId 0x%02X, %d bytes)\n"
        .. "local payload = buffer.fromstring(%s)\n"
        .. "return raknet.send(payload, %d, %d, %d)",
        pktId, #bytes, quoted, prio, rel, ch
    )
end

-- ==============================================================================
-- RAKNET RECEIVE & SEND HOOKS (FAST PATH)
-- ==============================================================================
local function shouldBlockPacket(pktId, direction, pkt)
    local rule = blockedPacketIds[pktId]
    if rule == "both" or rule == direction then
        return true
    end
    if #blockedSubstrings > 0 then
        local payload = extractPayloadString(pkt, pkt.Size or 0)
        if payload ~= "" then
            for i = 1, #blockedSubstrings do
                local pat = blockedSubstrings[i]
                if pat ~= "" and payload:find(pat, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

local function handlePacket(pkt, direction)
    if genv._OmniPacketLoggerGeneration ~= currentGen then return end

    local okId, pktId = pcall(function() return pkt.PacketId end)
    if not okId or type(pktId) ~= "number" then pktId = -1 end

    local okSz, sz = pcall(function() return pkt.Size end)
    if not okSz or type(sz) ~= "number" then sz = 0 end

    local st = getPacketStat(pktId)
    if direction == "in" then
        windowInPackets = windowInPackets + 1
        totalInPackets = totalInPackets + 1
        windowInBytes = windowInBytes + sz
        totalInBytes = totalInBytes + sz
        st.inPkts = st.inPkts + 1
        st.inBytes = st.inBytes + sz
    else
        windowOutPackets = windowOutPackets + 1
        totalOutPackets = totalOutPackets + 1
        windowOutBytes = windowOutBytes + sz
        totalOutBytes = totalOutBytes + sz
        st.outPkts = st.outPkts + 1
        st.outBytes = st.outBytes + sz
    end

    -- 1. Check active block rules
    local blocked = false
    if shouldBlockPacket(pktId, direction, pkt) then
        local okBlk = pcall(function() pkt:Block() end)
        if okBlk then
            blocked = true
            windowBlockedPackets = windowBlockedPackets + 1
            totalBlockedPackets = totalBlockedPackets + 1
            st.blocked = st.blocked + 1
        end
    end

    -- 2. Check if full payload capture is active
    local capturing = (isWindowOpen or isPinnedRecording) and not isPaused
    if not capturing then return end
    if mutedPacketIds[pktId] and not blocked then return end

    local okRel, rel = pcall(function() return pkt.Reliability end)
    local okPrio, prio = pcall(function() return pkt.Priority end)
    local okCh, ch = pcall(function() return pkt.OrderingChannel end)

    local payload, truncated = extractPayloadString(pkt, sz)
    if pktId < 0 and #payload >= 1 then
        pktId = payload:byte(1)
    end

    sequenceCounter = sequenceCounter + 1
    local entry = {
        seq = sequenceCounter,
        direction = direction,
        timestamp = os.clock(),
        packetId = pktId,
        size = sz > 0 and sz or #payload,
        reliability = okRel and rel or 0,
        priority = okPrio and prio or 0,
        channel = okCh and ch or 0,
        payload = payload,
        truncated = truncated,
        blocked = blocked,
        storedBytes = #payload + 64,
    }

    ringPush(entry)
end

local receiveCallback = function(pkt)
    pcall(handlePacket, pkt, "in")
end

local sendCallback = function(pkt)
    pcall(handlePacket, pkt, "out")
end

local receiveHookInstalled = false
local sendHookInstalled = false

if hasRakNetHooks then
    local okR = pcall(raknetAddReceiveHook, receiveCallback)
    receiveHookInstalled = okR
    local okS = pcall(raknetAddSendHook, sendCallback)
    sendHookInstalled = okS
end

-- ==============================================================================
-- GLOBAL API EXPORTS (FOR TASK MANAGER & EXTERNAL SCRIPTS)
-- ==============================================================================
genv.GetOmniPacketMetrics = function()
    return {
        available = hasRakNetHooks,
        receiveHookInstalled = receiveHookInstalled,
        sendHookInstalled = sendHookInstalled,
        inKBps = inKBps,
        outKBps = outKBps,
        inPktsSec = inPktsSec,
        outPktsSec = outPktsSec,
        blockedPktsSec = blockedPktsSec,
        totalInBytes = totalInBytes,
        totalOutBytes = totalOutBytes,
        totalInPackets = totalInPackets,
        totalOutPackets = totalOutPackets,
        totalBlockedPackets = totalBlockedPackets,
        bufferedCount = ringCount,
        bufferedBytes = ringBytes,
        isWindowOpen = isWindowOpen,
        isPinnedRecording = isPinnedRecording,
        isPaused = isPaused,
    }
end

genv.GetOmniCapturedPackets = function()
    local list = table.create(ringCount)
    for i = 1, ringCount do
        list[i] = ringGet(i)
    end
    return list
end

genv.ClearOmniCapturedPackets = function()
    ringClear()
end

genv.SetOmniPacketBlock = function(pktId, mode)
    local id = tonumber(pktId)
    if not id then return false end
    if not mode or mode == false or mode == "off" or mode == "none" then
        blockedPacketIds[id] = nil
    elseif mode == true or mode == "both" then
        blockedPacketIds[id] = "both"
    elseif mode == "in" or mode == "out" then
        blockedPacketIds[id] = mode
    end
    return true
end

-- ==============================================================================
-- DEFERRED UI & TELEMETRY LOOP (SPAWNED SO RING-0 NEVER YIELDS)
-- ==============================================================================
local uiConnections = {}
local hudScreenGui = nil

local function setCursorUnlock(active)
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    pcall(function() RunService:UnbindFromRenderStep("OmniPacketLoggerCursor") end)
    if active then
        pcall(function()
            RunService:BindToRenderStep("OmniPacketLoggerCursor", Enum.RenderPriority.Camera.Value + 1, function()
                if not hudScreenGui or not hudScreenGui.Parent or not isWindowOpen then
                    pcall(function() RunService:UnbindFromRenderStep("OmniPacketLoggerCursor") end)
                    return
                end
                if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
                    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                end
                if not UserInputService.MouseIconEnabled then
                    UserInputService.MouseIconEnabled = true
                end
            end)
        end)
    end
end

genv._KernelPacketLoggerCleanUp = function()
    genv._KernelPacketLoggerRunning = false
    genv._KernelPacketLoggerLoaded = false
    setCursorUnlock(false)

    if receiveHookInstalled and type(raknetRemoveReceiveHook) == "function" then
        pcall(raknetRemoveReceiveHook, receiveCallback)
        receiveHookInstalled = false
    end
    if sendHookInstalled and type(raknetRemoveSendHook) == "function" then
        pcall(raknetRemoveSendHook, sendCallback)
        sendHookInstalled = false
    end

    for _, c in ipairs(uiConnections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(uiConnections)

    if hudScreenGui then
        pcall(function() hudScreenGui:Destroy() end)
        hudScreenGui = nil
    end
    genv._KernelPacketLoggerGui = nil
end

task.spawn(function()
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local GuiService = game:GetService("GuiService")

    local LocalPlayer = Players.LocalPlayer
    while not LocalPlayer do
        task.wait(0.1)
        if genv._OmniPacketLoggerGeneration ~= currentGen then return end
        LocalPlayer = Players.LocalPlayer
    end

    local function getGuiParent()
        if type(gethui) == "function" then
            local ok, hui = pcall(gethui)
            if ok and hui then return hui end
        end
        local okCG, cg = pcall(function() return game:GetService("CoreGui") end)
        if okCG and cg then return cg end
        return LocalPlayer:WaitForChild("PlayerGui")
    end

    -- 1-Second Telemetry Rolling Loop
    task.spawn(function()
        while genv._OmniPacketLoggerGeneration == currentGen and genv._KernelPacketLoggerRunning do
            task.wait(1.0)
            local now = os.clock()
            local dt = math.max(0.001, now - lastRollClock)
            lastRollClock = now

            inKBps = (windowInBytes / 1024) / dt
            outKBps = (windowOutBytes / 1024) / dt
            inPktsSec = math.floor(windowInPackets / dt + 0.5)
            outPktsSec = math.floor(windowOutPackets / dt + 0.5)
            blockedPktsSec = math.floor(windowBlockedPackets / dt + 0.5)

            windowInBytes = 0
            windowOutBytes = 0
            windowInPackets = 0
            windowOutPackets = 0
            windowBlockedPackets = 0
        end
    end)

    -- ==========================================================================
    -- UNIFIED OMNI DARK THEME TOKENS
    -- ==========================================================================
    local Theme = {
        WindowBg = Color3.fromRGB(15, 17, 23),
        HeaderBg = Color3.fromRGB(20, 24, 33),
        CardBg = Color3.fromRGB(22, 27, 38),
        WellBg = Color3.fromRGB(12, 14, 19),
        RowEven = Color3.fromRGB(18, 22, 31),
        RowOdd = Color3.fromRGB(15, 18, 26),
        RowSelected = Color3.fromRGB(28, 52, 82),
        Stroke = Color3.fromRGB(45, 52, 68),
        AccentCyan = Color3.fromRGB(64, 196, 255),
        PrimaryBtn = Color3.fromRGB(30, 80, 140),
        TextPrimary = Color3.fromRGB(235, 240, 248),
        TextSecondary = Color3.fromRGB(150, 165, 190),
        TextMuted = Color3.fromRGB(100, 115, 140),
        StatusGreen = Color3.fromRGB(80, 220, 135),
        StatusAmber = Color3.fromRGB(255, 190, 64),
        StatusDanger = Color3.fromRGB(255, 85, 85),
        InboundColor = Color3.fromRGB(80, 210, 255),
        OutboundColor = Color3.fromRGB(255, 180, 75),
    }

    hudScreenGui = Instance.new("ScreenGui")
    hudScreenGui.Name = "OmniKernelPacketLogger"
    hudScreenGui.ResetOnSpawn = false
    hudScreenGui.IgnoreGuiInset = true
    hudScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    hudScreenGui.DisplayOrder = 999992
    hudScreenGui.Enabled = isWindowOpen
    hudScreenGui.Parent = getGuiParent()
    genv._KernelPacketLoggerGui = hudScreenGui

    local MainWin = Instance.new("Frame")
    MainWin.Name = "MainWindow"
    MainWin.Size = UDim2.fromOffset(880, 540)
    MainWin.Position = UDim2.new(0.5, -440, 0.5, -270)
    MainWin.BackgroundColor3 = Theme.WindowBg
    MainWin.BorderSizePixel = 0
    MainWin.Active = true
    MainWin.Parent = hudScreenGui
    Instance.new("UICorner", MainWin).CornerRadius = UDim.new(0, 8)
    local winStroke = Instance.new("UIStroke", MainWin)
    winStroke.Color = Theme.Stroke
    winStroke.Thickness = 1

    -- ==========================================================================
    -- TITLE BAR (38px Standardized Omni Header)
    -- ==========================================================================
    local Header = Instance.new("Frame")
    Header.Name = "Header"
    Header.Size = UDim2.new(1, 0, 0, 38)
    Header.BackgroundColor3 = Theme.HeaderBg
    Header.BorderSizePixel = 0
    Header.Parent = MainWin
    Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 8)

    local HeaderBottomMask = Instance.new("Frame")
    HeaderBottomMask.Size = UDim2.new(1, 0, 0, 8)
    HeaderBottomMask.Position = UDim2.new(0, 0, 1, -8)
    HeaderBottomMask.BackgroundColor3 = Theme.HeaderBg
    HeaderBottomMask.BorderSizePixel = 0
    HeaderBottomMask.Parent = Header

    local HeaderDivider = Instance.new("Frame")
    HeaderDivider.Size = UDim2.new(1, 0, 0, 1)
    HeaderDivider.Position = UDim2.new(0, 0, 1, -1)
    HeaderDivider.BackgroundColor3 = Theme.Stroke
    HeaderDivider.BorderSizePixel = 0
    HeaderDivider.Parent = Header

    local TitleLbl = Instance.new("TextLabel")
    TitleLbl.Size = UDim2.new(0, 340, 1, 0)
    TitleLbl.Position = UDim2.fromOffset(14, 0)
    TitleLbl.BackgroundTransparency = 1
    TitleLbl.Font = Enum.Font.GothamBold
    TitleLbl.TextSize = 13
    TitleLbl.TextColor3 = Theme.AccentCyan
    TitleLbl.TextXAlignment = Enum.TextXAlignment.Left
    TitleLbl.Text = "⚡ OMNI KERNEL PACKET LOGGER"
    TitleLbl.Parent = Header

    local KeyBadge = Instance.new("TextLabel")
    KeyBadge.Size = UDim2.fromOffset(68, 20)
    KeyBadge.Position = UDim2.new(1, -112, 0.5, -10)
    KeyBadge.BackgroundColor3 = Color3.fromRGB(30, 36, 50)
    KeyBadge.BorderSizePixel = 0
    KeyBadge.Font = Enum.Font.GothamBold
    KeyBadge.TextSize = 10
    KeyBadge.TextColor3 = Color3.fromRGB(160, 175, 200)
    KeyBadge.Text = "Shift + F5"
    KeyBadge.Parent = Header
    Instance.new("UICorner", KeyBadge).CornerRadius = UDim.new(0, 4)

    local CloseBtn = Instance.new("TextButton")
    CloseBtn.Size = UDim2.fromOffset(28, 28)
    CloseBtn.Position = UDim2.new(1, -36, 0.5, -14)
    CloseBtn.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
    CloseBtn.BorderSizePixel = 0
    CloseBtn.Font = Enum.Font.GothamBold
    CloseBtn.TextSize = 13
    CloseBtn.TextColor3 = Color3.fromRGB(200, 210, 225)
    CloseBtn.Text = "X"
    CloseBtn.Parent = Header
    Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)

    -- ==========================================================================
    -- TOP TELEMETRY CARDS (4 Cards)
    -- ==========================================================================
    local TelemetryRow = Instance.new("Frame")
    TelemetryRow.Size = UDim2.new(1, -24, 0, 52)
    TelemetryRow.Position = UDim2.fromOffset(12, 46)
    TelemetryRow.BackgroundTransparency = 1
    TelemetryRow.Parent = MainWin

    local function createMetricCard(index, title, accentColor)
        local card = Instance.new("Frame")
        card.Size = UDim2.new(0.25, -6, 1, 0)
        card.Position = UDim2.new((index - 1) * 0.25, (index - 1) * 2, 0, 0)
        card.BackgroundColor3 = Theme.CardBg
        card.BorderSizePixel = 0
        card.Parent = TelemetryRow
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)
        local st = Instance.new("UIStroke", card)
        st.Color = Color3.fromRGB(40, 50, 68)
        st.Thickness = 1

        local hdr = Instance.new("TextLabel")
        hdr.Size = UDim2.new(1, -16, 0, 16)
        hdr.Position = UDim2.fromOffset(8, 5)
        hdr.BackgroundTransparency = 1
        hdr.Font = Enum.Font.GothamBold
        hdr.TextSize = 10
        hdr.TextColor3 = Theme.TextSecondary
        hdr.TextXAlignment = Enum.TextXAlignment.Left
        hdr.Text = title
        hdr.Parent = card

        local val = Instance.new("TextLabel")
        val.Size = UDim2.new(1, -16, 0, 20)
        val.Position = UDim2.fromOffset(8, 22)
        val.BackgroundTransparency = 1
        val.Font = Enum.Font.RobotoMono
        val.TextSize = 14
        val.TextColor3 = accentColor
        val.TextXAlignment = Enum.TextXAlignment.Left
        val.Text = "0.0 KB/s (0/s)"
        val.Parent = card

        return val
    end

    local LblInbound = createMetricCard(1, "↓ INBOUND STREAM", Theme.InboundColor)
    local LblOutbound = createMetricCard(2, "↑ OUTBOUND STREAM", Theme.OutboundColor)
    local LblBlocked = createMetricCard(3, "🚫 BLOCKED PACKETS", Theme.StatusDanger)
    local LblBuffer = createMetricCard(4, "📦 RING BUFFER (MAX 2K)", Theme.AccentCyan)

    -- ==========================================================================
    -- FILTER & CONTROL TOOLBAR
    -- ==========================================================================
    local Toolbar = Instance.new("Frame")
    Toolbar.Size = UDim2.new(1, -24, 0, 32)
    Toolbar.Position = UDim2.fromOffset(12, 104)
    Toolbar.BackgroundTransparency = 1
    Toolbar.Parent = MainWin

    local function createChip(text, xOffset, width)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(width, 28)
        btn.Position = UDim2.fromOffset(xOffset, 2)
        btn.BackgroundColor3 = Theme.CardBg
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.TextColor3 = Theme.TextSecondary
        btn.Text = text
        btn.Parent = Toolbar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
        local st = Instance.new("UIStroke", btn)
        st.Color = Theme.Stroke
        st.Thickness = 1
        return btn
    end

    local ChipAll = createChip("All", 0, 42)
    local ChipIn = createChip("↓ In", 46, 46)
    local ChipOut = createChip("↑ Out", 96, 50)
    local Chip0x83 = createChip("0x83 Data", 150, 72)
    local ChipMute85 = createChip("Mute 0x85", 226, 74)
    local ChipMute1B = createChip("Mute Ping", 304, 72)

    local SearchBox = Instance.new("TextBox")
    SearchBox.Size = UDim2.new(1, -616, 0, 28)
    SearchBox.Position = UDim2.fromOffset(382, 2)
    SearchBox.BackgroundColor3 = Theme.WellBg
    SearchBox.BorderSizePixel = 0
    SearchBox.Font = Enum.Font.RobotoMono
    SearchBox.TextSize = 11
    SearchBox.TextColor3 = Theme.TextPrimary
    SearchBox.PlaceholderColor3 = Theme.TextMuted
    SearchBox.PlaceholderText = "Search string, 0x83 item, or hex ID..."
    SearchBox.Text = ""
    SearchBox.ClearTextOnFocus = false
    SearchBox.TextXAlignment = Enum.TextXAlignment.Left
    SearchBox.Parent = Toolbar
    Instance.new("UICorner", SearchBox).CornerRadius = UDim.new(0, 5)
    local sbPad = Instance.new("UIPadding", SearchBox)
    sbPad.PaddingLeft = UDim.new(0, 8)
    sbPad.PaddingRight = UDim.new(0, 8)
    local sbStroke = Instance.new("UIStroke", SearchBox)
    sbStroke.Color = Theme.Stroke
    sbStroke.Thickness = 1

    local BtnPause = Instance.new("TextButton")
    BtnPause.Size = UDim2.fromOffset(72, 28)
    BtnPause.Position = UDim2.new(1, -228, 0, 2)
    BtnPause.BackgroundColor3 = Theme.CardBg
    BtnPause.BorderSizePixel = 0
    BtnPause.Font = Enum.Font.GothamBold
    BtnPause.TextSize = 11
    BtnPause.TextColor3 = Theme.StatusGreen
    BtnPause.Text = "● Live"
    BtnPause.Parent = Toolbar
    Instance.new("UICorner", BtnPause).CornerRadius = UDim.new(0, 5)

    local BtnPin = Instance.new("TextButton")
    BtnPin.Size = UDim2.fromOffset(88, 28)
    BtnPin.Position = UDim2.new(1, -152, 0, 2)
    BtnPin.BackgroundColor3 = Theme.CardBg
    BtnPin.BorderSizePixel = 0
    BtnPin.Font = Enum.Font.GothamBold
    BtnPin.TextSize = 11
    BtnPin.TextColor3 = Theme.TextSecondary
    BtnPin.Text = "📌 Pin BG: OFF"
    BtnPin.Parent = Toolbar
    Instance.new("UICorner", BtnPin).CornerRadius = UDim.new(0, 5)

    local BtnClear = Instance.new("TextButton")
    BtnClear.Size = UDim2.fromOffset(60, 28)
    BtnClear.Position = UDim2.new(1, -60, 0, 2)
    BtnClear.BackgroundColor3 = Color3.fromRGB(48, 26, 30)
    BtnClear.BorderSizePixel = 0
    BtnClear.Font = Enum.Font.GothamBold
    BtnClear.TextSize = 11
    BtnClear.TextColor3 = Color3.fromRGB(255, 140, 140)
    BtnClear.Text = "Clear"
    BtnClear.Parent = Toolbar
    Instance.new("UICorner", BtnClear).CornerRadius = UDim.new(0, 5)

    -- ==========================================================================
    -- SPLIT BODY: LEFT PACKET STREAM (52%) + RIGHT INSPECTOR (48%)
    -- ==========================================================================
    local BodyFrame = Instance.new("Frame")
    BodyFrame.Size = UDim2.new(1, -24, 1, -152)
    BodyFrame.Position = UDim2.fromOffset(12, 140)
    BodyFrame.BackgroundTransparency = 1
    BodyFrame.Parent = MainWin

    -- Left Pane: Packet Table
    local LeftPane = Instance.new("Frame")
    LeftPane.Size = UDim2.new(0.53, -6, 1, 0)
    LeftPane.BackgroundColor3 = Theme.WellBg
    LeftPane.BorderSizePixel = 0
    LeftPane.Parent = BodyFrame
    Instance.new("UICorner", LeftPane).CornerRadius = UDim.new(0, 6)
    local lpStroke = Instance.new("UIStroke", LeftPane)
    lpStroke.Color = Theme.Stroke
    lpStroke.Thickness = 1

    local TableHeader = Instance.new("Frame")
    TableHeader.Size = UDim2.new(1, 0, 0, 24)
    TableHeader.BackgroundColor3 = Theme.HeaderBg
    TableHeader.BorderSizePixel = 0
    TableHeader.Parent = LeftPane
    Instance.new("UICorner", TableHeader).CornerRadius = UDim.new(0, 6)

    local function createColHeader(text, xScale, xOffset, wScale, wOffset)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(wScale, wOffset, 1, 0)
        lbl.Position = UDim2.new(xScale, xOffset, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 10
        lbl.TextColor3 = Theme.TextSecondary
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Text = text
        lbl.Parent = TableHeader
    end

    createColHeader("#", 0, 8, 0, 44)
    createColHeader("DIR", 0, 52, 0, 36)
    createColHeader("ID", 0, 90, 0, 42)
    createColHeader("LEN", 0, 134, 0, 46)
    createColHeader("REL", 0, 182, 0, 52)
    createColHeader("DISSECTED SUMMARY / ASCII", 0, 236, 1, -242)

    local PacketScroll = Instance.new("ScrollingFrame")
    PacketScroll.Size = UDim2.new(1, 0, 1, -25)
    PacketScroll.Position = UDim2.fromOffset(0, 25)
    PacketScroll.BackgroundTransparency = 1
    PacketScroll.BorderSizePixel = 0
    PacketScroll.ScrollBarThickness = 5
    PacketScroll.ScrollBarImageColor3 = Theme.AccentCyan
    PacketScroll.CanvasSize = UDim2.fromOffset(0, 0)
    PacketScroll.Parent = LeftPane

    -- Right Pane: Inspector & Controls
    local RightPane = Instance.new("Frame")
    RightPane.Size = UDim2.new(0.47, -6, 1, 0)
    RightPane.Position = UDim2.new(0.53, 6, 0, 0)
    RightPane.BackgroundColor3 = Theme.WellBg
    RightPane.BorderSizePixel = 0
    RightPane.Parent = BodyFrame
    Instance.new("UICorner", RightPane).CornerRadius = UDim.new(0, 6)
    local rpStroke = Instance.new("UIStroke", RightPane)
    rpStroke.Color = Theme.Stroke
    rpStroke.Thickness = 1

    local TabBar = Instance.new("Frame")
    TabBar.Size = UDim2.new(1, 0, 0, 30)
    TabBar.BackgroundColor3 = Theme.HeaderBg
    TabBar.BorderSizePixel = 0
    TabBar.Parent = RightPane
    Instance.new("UICorner", TabBar).CornerRadius = UDim.new(0, 6)

    local function createTabBtn(text, idx)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1 / 3, 0, 1, 0)
        btn.Position = UDim2.new((idx - 1) / 3, 0, 0, 0)
        btn.BackgroundColor3 = Color3.fromRGB(30, 38, 52)
        btn.BackgroundTransparency = 1
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.TextColor3 = Theme.TextSecondary
        btn.Text = text
        btn.Parent = TabBar

        local ind = Instance.new("Frame")
        ind.Name = "Indicator"
        ind.Size = UDim2.new(1, -16, 0, 2)
        ind.Position = UDim2.new(0, 8, 1, -2)
        ind.BackgroundColor3 = Theme.AccentCyan
        ind.BorderSizePixel = 0
        ind.Visible = false
        ind.Parent = btn
        return btn
    end

    local TabDissectBtn = createTabBtn("Dissector & Strings", 1)
    local TabHexBtn = createTabBtn("Hex + ASCII Dump", 2)
    local TabRulesBtn = createTabBtn("ID Stats & Block", 3)

    local InspectorScroll = Instance.new("ScrollingFrame")
    InspectorScroll.Size = UDim2.new(1, -16, 1, -76)
    InspectorScroll.Position = UDim2.fromOffset(8, 34)
    InspectorScroll.BackgroundTransparency = 1
    InspectorScroll.BorderSizePixel = 0
    InspectorScroll.ScrollBarThickness = 5
    InspectorScroll.ScrollBarImageColor3 = Theme.AccentCyan
    InspectorScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    InspectorScroll.CanvasSize = UDim2.fromOffset(0, 0)
    InspectorScroll.Parent = RightPane

    local InspectorText = Instance.new("TextBox")
    InspectorText.Size = UDim2.new(1, -6, 0, 0)
    InspectorText.AutomaticSize = Enum.AutomaticSize.Y
    InspectorText.BackgroundTransparency = 1
    InspectorText.Font = Enum.Font.RobotoMono
    InspectorText.TextSize = 11
    InspectorText.TextColor3 = Theme.TextPrimary
    InspectorText.TextXAlignment = Enum.TextXAlignment.Left
    InspectorText.TextYAlignment = Enum.TextYAlignment.Top
    InspectorText.TextEditable = false
    InspectorText.ClearTextOnFocus = false
    InspectorText.MultiLine = true
    InspectorText.TextWrapped = true
    InspectorText.Text = "Select a packet on the left to inspect its 0x83 sub-items, strings, and hex payload."
    InspectorText.Parent = InspectorScroll

    local RulesScroll = Instance.new("ScrollingFrame")
    RulesScroll.Size = UDim2.new(1, -16, 1, -76)
    RulesScroll.Position = UDim2.fromOffset(8, 34)
    RulesScroll.BackgroundTransparency = 1
    RulesScroll.BorderSizePixel = 0
    RulesScroll.ScrollBarThickness = 5
    RulesScroll.ScrollBarImageColor3 = Theme.AccentCyan
    RulesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    RulesScroll.CanvasSize = UDim2.fromOffset(0, 0)
    RulesScroll.Visible = false
    RulesScroll.Parent = RightPane

    local RulesLayout = Instance.new("UIListLayout")
    RulesLayout.Padding = UDim.new(0, 4)
    RulesLayout.SortOrder = Enum.SortOrder.LayoutOrder
    RulesLayout.Parent = RulesScroll

    -- Action Bar at bottom of RightPane
    local ActionBar = Instance.new("Frame")
    ActionBar.Size = UDim2.new(1, -16, 0, 32)
    ActionBar.Position = UDim2.new(0, 8, 1, -38)
    ActionBar.BackgroundTransparency = 1
    ActionBar.Parent = RightPane

    local function createActionBtn(text, scaleX, scaleW, bg)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(scaleW, -4, 1, 0)
        btn.Position = UDim2.new(scaleX, 2, 0, 0)
        btn.BackgroundColor3 = bg
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.TextColor3 = Theme.TextPrimary
        btn.Text = text
        btn.Parent = ActionBar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
        return btn
    end

    local BtnBlockId = createActionBtn("🚫 Block ID", 0, 0.32, Color3.fromRGB(65, 28, 32))
    local BtnReplay = createActionBtn("🔁 Replay Out", 0.32, 0.34, Theme.PrimaryBtn)
    local BtnCopyCode = createActionBtn("📋 Copy Luau", 0.66, 0.34, Color3.fromRGB(28, 45, 68))

    -- ==========================================================================
    -- INSPECTOR RENDERING
    -- ==========================================================================
    local function refreshInspector()
        local tabs = {
            { btn = TabDissectBtn, key = "Dissector" },
            { btn = TabHexBtn, key = "Hex" },
            { btn = TabRulesBtn, key = "Rules" },
        }
        for _, t in ipairs(tabs) do
            local active = (activeInspectorTab == t.key)
            t.btn.BackgroundTransparency = active and 0 or 1
            t.btn.TextColor3 = active and Theme.TextPrimary or Theme.TextSecondary
            local ind = t.btn:FindFirstChild("Indicator")
            if ind then ind.Visible = active end
        end

        InspectorScroll.Visible = (activeInspectorTab ~= "Rules")
        RulesScroll.Visible = (activeInspectorTab == "Rules")

        if activeInspectorTab == "Rules" then
            return
        end

        if not selectedEntry then
            InspectorText.Text = hasRakNetHooks
                and "Select any captured packet on the left to dissect its 0x83 replication stream, ASCII strings, and hex dump."
                or "[Notice]: Potassium raknet hooks (raknet.add_receive_hook / add_send_hook) were not detected in this environment."
            BtnBlockId.Text = "🚫 Block ID"
            return
        end

        local e = selectedEntry
        local d = dissectPacket(e)
        local pktId = tonumber(e.packetId) or -1
        local isBlk = blockedPacketIds[pktId] ~= nil
        BtnBlockId.Text = isBlk and string.format("✓ Unblock 0x%02X", math.max(0, pktId)) or string.format("🚫 Block 0x%02X", math.max(0, pktId))
        BtnBlockId.BackgroundColor3 = isBlk and Color3.fromRGB(30, 80, 55) or Color3.fromRGB(65, 28, 32)

        if activeInspectorTab == "Hex" then
            InspectorText.Text = string.format(
                "Packet #%d | %s | %s (0x%02X) | %d bytes | Rel: %s | Ch: %d\n%s\n\n%s",
                e.seq,
                e.direction == "in" and "↓ INBOUND" or "↑ OUTBOUND",
                d.packetName,
                math.max(0, pktId),
                e.size,
                RELIABILITY_NAMES[e.reliability] or tostring(e.reliability),
                e.channel or 0,
                string.rep("─", 58),
                formatHexAsciiDump(e.payload, 2048)
            )
        else
            local lines = {
                string.format("PACKET #%d (%s)", e.seq, e.direction == "in" and "↓ INBOUND RECEIVE" or "↑ OUTBOUND SEND"),
                string.rep("─", 54),
                string.format("Packet ID   : 0x%02X (%d) — %s", math.max(0, pktId), pktId, d.packetName),
                string.format("Payload Len : %d bytes%s", e.size, e.truncated and " [Truncated Preview]" or ""),
                string.format("Reliability : %s (%d) | Priority: %d | Channel: %d", RELIABILITY_NAMES[e.reliability] or "?", e.reliability, e.priority, e.channel),
                string.format("Status      : %s", e.blocked and "BLOCKED BY RULE" or "PASSED"),
                "",
            }

            if #d.subItems > 0 then
                table.insert(lines, string.format("0x83 REPLICATION SUB-ITEMS (%d):", #d.subItems))
                for idx, sub in ipairs(d.subItems) do
                    if sub.ident then
                        table.insert(lines, string.format("  [%02d] @+0x%04X  0x%02X %-22s -> \"%s\"", idx, sub.offset, sub.id, sub.name, sub.ident))
                    else
                        table.insert(lines, string.format("  [%02d] @+0x%04X  0x%02X %s", idx, sub.offset, sub.id, sub.name))
                    end
                end
                table.insert(lines, "")
            end

            if #d.strings > 0 then
                table.insert(lines, string.format("EXTRACTED ASCII STRINGS (%d):", #d.strings))
                for idx = 1, math.min(40, #d.strings) do
                    local s = d.strings[idx]
                    table.insert(lines, string.format("  @+0x%04X : \"%s\"", s.offset, s.text))
                end
                if #d.strings > 40 then
                    table.insert(lines, string.format("  ... (+%d more strings)", #d.strings - 40))
                end
            else
                table.insert(lines, "EXTRACTED ASCII STRINGS: (None >= 3 chars)")
            end

            InspectorText.Text = table.concat(lines, "\n")
        end
    end

    -- ==========================================================================
    -- RULES & STATS TAB RENDERING
    -- ==========================================================================
    local ruleRowPool = {}

    local function refreshRulesTab()
        if activeInspectorTab ~= "Rules" then return end
        local list = {}
        for _, st in pairs(packetStats) do
            table.insert(list, st)
        end
        table.sort(list, function(a, b)
            return (a.inBytes + a.outBytes) > (b.inBytes + b.outBytes)
        end)

        for idx, st in ipairs(list) do
            local row = ruleRowPool[idx]
            if not row then
                row = Instance.new("Frame")
                row.Size = UDim2.new(1, -6, 0, 28)
                row.BackgroundColor3 = Theme.CardBg
                row.BorderSizePixel = 0
                row.Parent = RulesScroll
                Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

                local lbl = Instance.new("TextLabel")
                lbl.Name = "Info"
                lbl.Size = UDim2.new(1, -136, 1, 0)
                lbl.Position = UDim2.fromOffset(8, 0)
                lbl.BackgroundTransparency = 1
                lbl.Font = Enum.Font.RobotoMono
                lbl.TextSize = 11
                lbl.TextColor3 = Theme.TextPrimary
                lbl.TextXAlignment = Enum.TextXAlignment.Left
                lbl.TextTruncate = Enum.TextTruncate.AtEnd
                lbl.Parent = row

                local muteBtn = Instance.new("TextButton")
                muteBtn.Name = "MuteBtn"
                muteBtn.Size = UDim2.fromOffset(58, 22)
                muteBtn.Position = UDim2.new(1, -124, 0.5, -11)
                muteBtn.BorderSizePixel = 0
                muteBtn.Font = Enum.Font.GothamBold
                muteBtn.TextSize = 10
                muteBtn.Parent = row
                Instance.new("UICorner", muteBtn).CornerRadius = UDim.new(0, 4)

                local blkBtn = Instance.new("TextButton")
                blkBtn.Name = "BlkBtn"
                blkBtn.Size = UDim2.fromOffset(58, 22)
                blkBtn.Position = UDim2.new(1, -62, 0.5, -11)
                blkBtn.BorderSizePixel = 0
                blkBtn.Font = Enum.Font.GothamBold
                blkBtn.TextSize = 10
                blkBtn.Parent = row
                Instance.new("UICorner", blkBtn).CornerRadius = UDim.new(0, 4)

                muteBtn.MouseButton1Click:Connect(function()
                    local pid = row:GetAttribute("PktId")
                    if pid then
                        mutedPacketIds[pid] = not mutedPacketIds[pid] or nil
                        refreshRulesTab()
                    end
                end)

                blkBtn.MouseButton1Click:Connect(function()
                    local pid = row:GetAttribute("PktId")
                    if pid then
                        if blockedPacketIds[pid] then
                            blockedPacketIds[pid] = nil
                        else
                            blockedPacketIds[pid] = "both"
                        end
                        refreshRulesTab()
                    end
                end)

                ruleRowPool[idx] = row
            end

            row.Visible = true
            row.LayoutOrder = idx
            row:SetAttribute("PktId", st.id)

            local totalKB = (st.inBytes + st.outBytes) / 1024
            local infoLbl = row:FindFirstChild("Info")
            if infoLbl then
                infoLbl.Text = string.format(
                    "0x%02X %-20s | ↓%d ↑%d (%.1f KB)",
                    math.max(0, st.id),
                    st.name:sub(1, 20),
                    st.inPkts,
                    st.outPkts,
                    totalKB
                )
            end

            local muteBtn = row:FindFirstChild("MuteBtn")
            if muteBtn then
                local m = mutedPacketIds[st.id] == true
                muteBtn.Text = m and "Muted" or "Mute"
                muteBtn.BackgroundColor3 = m and Color3.fromRGB(60, 50, 24) or Color3.fromRGB(30, 36, 50)
                muteBtn.TextColor3 = m and Theme.StatusAmber or Theme.TextSecondary
            end

            local blkBtn = row:FindFirstChild("BlkBtn")
            if blkBtn then
                local b = blockedPacketIds[st.id] ~= nil
                blkBtn.Text = b and "Blocked" or "Block"
                blkBtn.BackgroundColor3 = b and Color3.fromRGB(80, 28, 32) or Color3.fromRGB(30, 36, 50)
                blkBtn.TextColor3 = b and Theme.StatusDanger or Theme.TextSecondary
            end
        end

        for idx = #list + 1, #ruleRowPool do
            ruleRowPool[idx].Visible = false
        end
    end

    -- ==========================================================================
    -- VIRTUALIZED PACKET LIST RENDERING
    -- ==========================================================================
    local ROW_HEIGHT = 24
    local MAX_VISIBLE_ROWS = 22
    local rowPool = {}
    local filteredEntries = {}

    local function getOrCreateRow(poolIdx)
        local row = rowPool[poolIdx]
        if row then return row end

        row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -6, 0, ROW_HEIGHT)
        row.BorderSizePixel = 0
        row.AutoButtonColor = false
        row.Text = ""
        row.Parent = PacketScroll

        local function mkCell(name, x, w, color, align)
            local lbl = Instance.new("TextLabel")
            lbl.Name = name
            lbl.Size = UDim2.new(0, w, 1, 0)
            lbl.Position = UDim2.fromOffset(x, 0)
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.RobotoMono
            lbl.TextSize = 11
            lbl.TextColor3 = color
            lbl.TextXAlignment = align or Enum.TextXAlignment.Left
            lbl.TextTruncate = Enum.TextTruncate.AtEnd
            lbl.Parent = row
            return lbl
        end

        mkCell("Seq", 8, 42, Theme.TextMuted)
        mkCell("Dir", 52, 34, Theme.InboundColor)
        mkCell("PktId", 90, 42, Theme.AccentCyan)
        mkCell("Len", 134, 44, Theme.TextPrimary)
        mkCell("Rel", 182, 50, Theme.TextSecondary)

        local sumLbl = Instance.new("TextLabel")
        sumLbl.Name = "Summary"
        sumLbl.Size = UDim2.new(1, -242, 1, 0)
        sumLbl.Position = UDim2.fromOffset(236, 0)
        sumLbl.BackgroundTransparency = 1
        sumLbl.Font = Enum.Font.RobotoMono
        sumLbl.TextSize = 11
        sumLbl.TextColor3 = Theme.TextPrimary
        sumLbl.TextXAlignment = Enum.TextXAlignment.Left
        sumLbl.TextTruncate = Enum.TextTruncate.AtEnd
        sumLbl.Parent = row

        row.MouseButton1Click:Connect(function()
            local idx = row:GetAttribute("FilteredIdx")
            local entry = idx and filteredEntries[idx]
            if entry then
                selectedEntry = entry
                refreshInspector()
            end
        end)

        rowPool[poolIdx] = row
        return row
    end

    local function updateFilterChipsUI()
        local function styleChip(btn, active, activeColor)
            btn.BackgroundColor3 = active and (activeColor or Theme.PrimaryBtn) or Theme.CardBg
            btn.TextColor3 = active and Color3.fromRGB(255, 255, 255) or Theme.TextSecondary
        end
        styleChip(ChipAll, filterDirection == "all")
        styleChip(ChipIn, filterDirection == "in")
        styleChip(ChipOut, filterDirection == "out")
        styleChip(Chip0x83, filterOnly0x83)
        styleChip(ChipMute85, mutedPacketIds[0x85] == true, Color3.fromRGB(55, 45, 22))
        styleChip(ChipMute1B, mutedPacketIds[0x1B] == true, Color3.fromRGB(55, 45, 22))

        BtnPause.Text = isPaused and "⏸ Paused" or "● Live"
        BtnPause.TextColor3 = isPaused and Theme.StatusAmber or Theme.StatusGreen

        BtnPin.Text = isPinnedRecording and "📌 Pin BG: ON" or "📌 Pin BG: OFF"
        BtnPin.TextColor3 = isPinnedRecording and Theme.AccentCyan or Theme.TextSecondary
    end

    local function rebuildFilteredListAndRender()
        table.clear(filteredEntries)
        local q = searchQuery:lower():gsub("^%s+", ""):gsub("%s+$", "")

        -- Iterate newest-first so most recent packets appear at top
        for i = ringCount, 1, -1 do
            local entry = ringGet(i)
            if entry then
                if filterDirection ~= "all" and entry.direction ~= filterDirection then
                    continue
                end
                if filterOnly0x83 and entry.packetId ~= 0x83 then
                    continue
                end
                if q ~= "" then
                    local d = dissectPacket(entry)
                    local idHex = string.format("0x%02x", math.max(0, entry.packetId or 0))
                    if not (d.searchBlob:find(q, 1, true) or idHex:find(q, 1, true) or tostring(entry.packetId):find(q, 1, true)) then
                        continue
                    end
                end
                table.insert(filteredEntries, entry)
            end
        end

        local totalRows = #filteredEntries
        PacketScroll.CanvasSize = UDim2.fromOffset(0, totalRows * ROW_HEIGHT)

        local scrollY = PacketScroll.CanvasPosition.Y
        local firstIdx = math.max(1, math.floor(scrollY / ROW_HEIGHT) + 1)
        local lastIdx = math.min(totalRows, firstIdx + MAX_VISIBLE_ROWS - 1)

        local poolUsed = 0
        for fIdx = firstIdx, lastIdx do
            poolUsed = poolUsed + 1
            local row = getOrCreateRow(poolUsed)
            local entry = filteredEntries[fIdx]
            local d = dissectPacket(entry)

            row.Visible = true
            row.Position = UDim2.fromOffset(0, (fIdx - 1) * ROW_HEIGHT)
            row:SetAttribute("FilteredIdx", fIdx)

            local isSel = (selectedEntry == entry)
            if isSel then
                row.BackgroundColor3 = Theme.RowSelected
            elseif entry.blocked then
                row.BackgroundColor3 = Color3.fromRGB(50, 22, 26)
            else
                row.BackgroundColor3 = (fIdx % 2 == 0) and Theme.RowEven or Theme.RowOdd
            end

            row.Seq.Text = tostring(entry.seq)
            row.Dir.Text = entry.direction == "in" and "↓ IN" or "↑ OUT"
            row.Dir.TextColor3 = entry.direction == "in" and Theme.InboundColor or Theme.OutboundColor
            row.PktId.Text = string.format("0x%02X", math.max(0, entry.packetId or 0))
            row.Len.Text = tostring(entry.size)
            row.Rel.Text = RELIABILITY_NAMES[entry.reliability] or tostring(entry.reliability)
            row.Summary.Text = d.summary
        end

        for i = poolUsed + 1, #rowPool do
            rowPool[i].Visible = false
        end
    end

    -- ==========================================================================
    -- INTERACTION WIRING (CHIPS, TABS, DRAGGING, RESIZING, HOTKEY)
    -- ==========================================================================
    ChipAll.MouseButton1Click:Connect(function()
        filterDirection = "all"
        updateFilterChipsUI()
        rebuildFilteredListAndRender()
    end)
    ChipIn.MouseButton1Click:Connect(function()
        filterDirection = "in"
        updateFilterChipsUI()
        rebuildFilteredListAndRender()
    end)
    ChipOut.MouseButton1Click:Connect(function()
        filterDirection = "out"
        updateFilterChipsUI()
        rebuildFilteredListAndRender()
    end)
    Chip0x83.MouseButton1Click:Connect(function()
        filterOnly0x83 = not filterOnly0x83
        updateFilterChipsUI()
        rebuildFilteredListAndRender()
    end)
    ChipMute85.MouseButton1Click:Connect(function()
        mutedPacketIds[0x85] = not mutedPacketIds[0x85] or nil
        updateFilterChipsUI()
    end)
    ChipMute1B.MouseButton1Click:Connect(function()
        mutedPacketIds[0x1B] = not mutedPacketIds[0x1B] or nil
        updateFilterChipsUI()
    end)

    SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
        searchQuery = SearchBox.Text
        rebuildFilteredListAndRender()
    end)

    BtnPause.MouseButton1Click:Connect(function()
        isPaused = not isPaused
        updateFilterChipsUI()
    end)

    BtnPin.MouseButton1Click:Connect(function()
        isPinnedRecording = not isPinnedRecording
        updateFilterChipsUI()
    end)

    BtnClear.MouseButton1Click:Connect(function()
        ringClear()
        rebuildFilteredListAndRender()
        refreshInspector()
    end)

    TabDissectBtn.MouseButton1Click:Connect(function()
        activeInspectorTab = "Dissector"
        refreshInspector()
    end)
    TabHexBtn.MouseButton1Click:Connect(function()
        activeInspectorTab = "Hex"
        refreshInspector()
    end)
    TabRulesBtn.MouseButton1Click:Connect(function()
        activeInspectorTab = "Rules"
        refreshInspector()
        refreshRulesTab()
    end)

    BtnBlockId.MouseButton1Click:Connect(function()
        if not selectedEntry then return end
        local pid = tonumber(selectedEntry.packetId)
        if not pid or pid < 0 then return end
        if blockedPacketIds[pid] then
            blockedPacketIds[pid] = nil
        else
            blockedPacketIds[pid] = "both"
        end
        refreshInspector()
        refreshRulesTab()
    end)

    BtnReplay.MouseButton1Click:Connect(function()
        if not selectedEntry then return end
        if selectedEntry.direction ~= "out" then
            BtnReplay.Text = "⚠ Outbound Only"
            task.delay(1.2, function()
                if BtnReplay then BtnReplay.Text = "🔁 Replay Out" end
            end)
            return
        end
        if not hasRakNetSend or type(buffer) ~= "table" or type(buffer.fromstring) ~= "function" then
            BtnReplay.Text = "⚠ Send Unavail"
            task.delay(1.2, function()
                if BtnReplay then BtnReplay.Text = "🔁 Replay Out" end
            end)
            return
        end
        local ok, err = pcall(function()
            local buf = buffer.fromstring(selectedEntry.payload or "")
            raknetSend(buf, selectedEntry.priority or 1, selectedEntry.reliability or 3, selectedEntry.channel or 0)
        end)
        BtnReplay.Text = ok and "✓ Sent!" or "⚠ Failed"
        if not ok then warn("[OmniPacketLogger] Replay error:", err) end
        task.delay(1.2, function()
            if BtnReplay then BtnReplay.Text = "🔁 Replay Out" end
        end)
    end)

    BtnCopyCode.MouseButton1Click:Connect(function()
        if not selectedEntry then return end
        local code = generateReplayScript(selectedEntry)
        if type(setclipboard) == "function" then
            pcall(setclipboard, code)
            BtnCopyCode.Text = "✓ Copied!"
        else
            BtnCopyCode.Text = "⚠ No Clipboard"
        end
        task.delay(1.2, function()
            if BtnCopyCode then BtnCopyCode.Text = "📋 Copy Luau" end
        end)
    end)

    PacketScroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        rebuildFilteredListAndRender()
    end)

    -- Window Dragging
    local dragging = false
    local dragStart, startPos
    Header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = MainWin.Position
        end
    end)
    table.insert(uiConnections, UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            MainWin.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end))
    table.insert(uiConnections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end))

    local function toggleWindow(forceState)
        if type(forceState) == "boolean" then
            isWindowOpen = forceState
        else
            isWindowOpen = not isWindowOpen
        end
        if hudScreenGui then
            hudScreenGui.Enabled = isWindowOpen
        end
        setCursorUnlock(isWindowOpen)
        if isWindowOpen then
            updateFilterChipsUI()
            rebuildFilteredListAndRender()
            refreshInspector()
            refreshRulesTab()
        end
    end

    genv.ToggleOmniPacketLogger = toggleWindow

    CloseBtn.MouseButton1Click:Connect(function()
        toggleWindow(false)
    end)

    table.insert(uiConnections, UserInputService.InputBegan:Connect(function(input, gp)
        if input.KeyCode == Enum.KeyCode.F5 and (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) then
            toggleWindow()
        end
    end))

    updateFilterChipsUI()

    -- 5Hz UI Refresh Loop (only active while Shift + F5 is open)
    while genv._OmniPacketLoggerGeneration == currentGen and genv._KernelPacketLoggerRunning do
        task.wait(0.2)
        if isWindowOpen and hudScreenGui and hudScreenGui.Enabled then
            LblInbound.Text = string.format("%.1f KB/s (%d/s)", inKBps, inPktsSec)
            LblOutbound.Text = string.format("%.1f KB/s (%d/s)", outKBps, outPktsSec)
            LblBlocked.Text = string.format("%d total (%d/s)", totalBlockedPackets, blockedPktsSec)
            LblBuffer.Text = string.format("%d pkts (%.2f MB)", ringCount, ringBytes / (1024 * 1024))

            if not isPaused then
                rebuildFilteredListAndRender()
                if activeInspectorTab == "Rules" then
                    refreshRulesTab()
                end
            end
        end
    end
end)
