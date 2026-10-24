--!stage PreInit
--!priority 250
--!name RemoteExecute

--[[
    ==============================================================================
    OMNI PREINIT EXECUTION & FULL-AWARENESS TELEMETRY BRIDGE
    ==============================================================================
    - 50ms (20Hz) low-latency IPC execution loop (<Account>_External.lua).
    - 1Hz Live World & Session State Snapshot (<Account>_State.json + ActiveClients.json).
    - 2Hz Batched Event Black-Box Stream (<Account>_Events.jsonl, bounded at 256 KB).
    - 100% Hookless: uses only native RBXScriptSignal connections and pcall-guarded
      property reads (zero metamethod or function hooks; Adonis & Luarmor safe).
    ==============================================================================
]]

local genv = (getgenv and getgenv()) or _G

local currentDM = game
if genv._OmniRemoteExecuteDataModel and genv._OmniRemoteExecuteDataModel ~= currentDM then
    genv._OmniRemoteExecuteCleanUp = nil
    genv._OmniRemoteExecuteRunning = nil
end
genv._OmniRemoteExecuteDataModel = currentDM

local currentGen = (genv._OmniRemoteExecuteGen or 0) + 1
genv._OmniRemoteExecuteGen = currentGen

if type(genv._OmniRemoteExecuteCleanUp) == "function" then
    pcall(genv._OmniRemoteExecuteCleanUp)
end
genv._OmniRemoteExecuteGen = currentGen
genv._OmniRemoteExecuteRunning = true

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")
local Stats = game:GetService("Stats")
local GuiService = game:GetService("GuiService")

while not Players.LocalPlayer do
    task.wait(0.05)
    if genv._OmniRemoteExecuteGen ~= currentGen then return end
end
local LocalPlayer = Players.LocalPlayer

local AccountName = LocalPlayer.Name
local FileName = AccountName .. "_External.lua"
local StateFile = AccountName .. "_State.json"
local EventsFile = AccountName .. "_Events.jsonl"
local RegistryFile = "ActiveClients.json"
local LogFile = "RemoteExecute_Logs.txt"

local MAX_EVENTS_FILE_BYTES = 256 * 1024
local MAX_MEMORY_EVENTS = 150

local connections = {}
local charConnections = {}
local pendingEventLines = {}
local recentEventsRing = {}
local eventSeq = 0
local dedupCache = {} -- [sig] = { lastClock, count }
local startClock = os.clock()
local lastFrameClock = os.clock()
local frameCounter = 0
local currentFps = 60
local cachedPlaceName = nil
local latestStateSnapshot = nil

-- Fetch place name asynchronously once
task.spawn(function()
    pcall(function()
        local MarketplaceService = game:GetService("MarketplaceService")
        local info = MarketplaceService:GetProductInfo(game.PlaceId)
        if info and info.Name then
            cachedPlaceName = tostring(info.Name)
        end
    end)
end)

-- Track real-time FPS via RenderStepped / Heartbeat
table.insert(connections, RunService.Heartbeat:Connect(function()
    frameCounter = frameCounter + 1
    local now = os.clock()
    local elapsed = now - lastFrameClock
    if elapsed >= 0.5 then
        currentFps = math.floor((frameCounter / elapsed) + 0.5)
        frameCounter = 0
        lastFrameClock = now
    end
end))

-- Ensure log & external files exist
if not isfile(LogFile) then
    pcall(function() writefile(LogFile, "") end)
end
if not isfile(FileName) then
    pcall(function()
        writefile(FileName, "")
    end)
end
if not isfile(EventsFile) then
    pcall(function() writefile(EventsFile, "") end)
end

local LastContent = ""
pcall(function()
    LastContent = readfile(FileName)
end)

local function writeLog(prefix, msg)
    local timestamp = os.date("%H:%M:%S")
    local formatted = "[" .. timestamp .. "] " .. prefix .. tostring(msg) .. "\n"
    pcall(function()
        if appendfile then
            appendfile(LogFile, formatted)
        else
            local existing = isfile(LogFile) and readfile(LogFile) or ""
            if #existing > 32000 then
                existing = string.sub(existing, -16000)
            end
            writefile(LogFile, existing .. formatted)
        end
    end)
end

local function roundNum(n, decimals)
    if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
        return 0
    end
    local mult = 10 ^ (decimals or 2)
    return math.floor(n * mult + 0.5) / mult
end

local function vec3ToTable(v)
    if typeof(v) ~= "Vector3" then return nil end
    return { roundNum(v.X, 2), roundNum(v.Y, 2), roundNum(v.Z, 2) }
end

local function safeFullName(inst)
    if typeof(inst) ~= "Instance" then return tostring(inst) end
    local ok, full = pcall(function() return inst:GetFullName() end)
    return (ok and type(full) == "string") and full or tostring(inst)
end

local function sanitizeValue(val, depth)
    depth = depth or 0
    local t = typeof(val)
    if t == "nil" or t == "boolean" then
        return val
    elseif t == "number" then
        return roundNum(val, 3)
    elseif t == "string" then
        return #val > 240 and (val:sub(1, 240) .. "...") or val
    elseif t == "Vector3" then
        return vec3ToTable(val)
    elseif t == "Vector2" then
        return { roundNum(val.X, 2), roundNum(val.Y, 2) }
    elseif t == "CFrame" then
        return { pos = vec3ToTable(val.Position), look = vec3ToTable(val.LookVector) }
    elseif t == "Color3" then
        return { math.floor(val.R * 255 + 0.5), math.floor(val.G * 255 + 0.5), math.floor(val.B * 255 + 0.5) }
    elseif t == "Instance" then
        return safeFullName(val)
    elseif t == "EnumItem" then
        return tostring(val)
    elseif t == "table" then
        if depth >= 2 then return tostring(val) end
        local out = {}
        local count = 0
        for k, v in pairs(val) do
            count = count + 1
            if count > 16 then break end
            out[tostring(k)] = sanitizeValue(v, depth + 1)
        end
        return out
    else
        return tostring(val)
    end
end

-- ==============================================================================
-- STRUCTURED EVENT BLACK-BOX QUEUE & DEDUPLICATION
-- ==============================================================================
local function flushPendingEvents()
    if #pendingEventLines == 0 then return end
    local batch = table.concat(pendingEventLines, "\n") .. "\n"
    table.clear(pendingEventLines)

    pcall(function()
        if isfile(EventsFile) then
            local existing = readfile(EventsFile)
            if #existing > MAX_EVENTS_FILE_BYTES then
                -- Keep newest half of lines on rotation
                local half = string.sub(existing, math.floor(#existing / 2))
                local nl = string.find(half, "\n", 1, true)
                if nl then half = string.sub(half, nl + 1) end
                writefile(EventsFile, half .. batch)
                return
            end
        end
        if appendfile then
            appendfile(EventsFile, batch)
        else
            local existing = isfile(EventsFile) and readfile(EventsFile) or ""
            writefile(EventsFile, existing .. batch)
        end
    end)
end

local function emitEvent(evType, summary, dataTbl, forceImmediateFlush)
    if genv._OmniRemoteExecuteGen ~= currentGen then return end
    local nowClock = os.clock()
    local dedupKey = tostring(evType) .. "|" .. tostring(summary)
    local prev = dedupCache[dedupKey]
    if prev and (nowClock - prev.lastClock) < 0.75 then
        prev.count = prev.count + 1
        return
    end
    local suppressed = prev and prev.count and prev.count > 1 and (prev.count - 1) or 0
    dedupCache[dedupKey] = { lastClock = nowClock, count = 1 }

    eventSeq = eventSeq + 1
    local entry = {
        seq = eventSeq,
        ts = os.date("%H:%M:%S"),
        epoch = os.time(),
        clock = roundNum(nowClock - startClock, 3),
        account = AccountName,
        placeId = game.PlaceId,
        type = evType,
        summary = suppressed > 0 and (tostring(summary) .. string.format(" (x%d)", suppressed + 1)) or tostring(summary),
        data = dataTbl and sanitizeValue(dataTbl, 0) or nil,
    }

    table.insert(recentEventsRing, entry)
    if #recentEventsRing > MAX_MEMORY_EVENTS then
        table.remove(recentEventsRing, 1)
    end

    local okJson, line = pcall(function()
        return HttpService:JSONEncode(entry)
    end)
    if okJson and type(line) == "string" then
        table.insert(pendingEventLines, line)
        if forceImmediateFlush or #pendingEventLines >= 25 then
            flushPendingEvents()
        end
    end
end

-- ==============================================================================
-- LIVE EVENT LISTENERS (CONSOLE, CHAT, PROMPTS, KICKS, CHARACTER, TOOLS)
-- ==============================================================================
-- 1. Console Output / Runtime Errors (LogService.MessageOut)
table.insert(connections, LogService.MessageOut:Connect(function(message, messageType)
    local msg = tostring(message)
    if msg:find("^%[RemoteExecute%]") then return end
    if messageType == Enum.MessageType.MessageError then
        emitEvent("CONSOLE_ERROR", msg:sub(1, 200), { fullMessage = msg })
    elseif messageType == Enum.MessageType.MessageWarning then
        emitEvent("CONSOLE_WARN", msg:sub(1, 200), { fullMessage = msg })
    elseif messageType == Enum.MessageType.MessageOutput then
        emitEvent("CONSOLE_PRINT", msg:sub(1, 200), nil)
    end
end))

-- 2. Kick / Disconnect / Error Prompts
local function inspectKickState()
    local isKicked = false
    local errCode = nil
    local errMsg = nil
    pcall(function()
        local gm = GuiService:GetErrorMessage()
        if type(gm) == "string" and #gm > 0 then
            isKicked = true
            errMsg = gm
        end
        local ec = GuiService:GetErrorCode()
        if ec and ec ~= Enum.ConnectionError.OK then
            isKicked = true
            errCode = tostring(ec)
        end
    end)
    pcall(function()
        local cg = game:GetService("CoreGui")
        local rpg = cg:FindFirstChild("RobloxPromptGui")
        local po = rpg and rpg:FindFirstChild("promptOverlay")
        local ep = po and po:FindFirstChild("ErrorPrompt")
        if ep and ep.Visible then
            isKicked = true
            local msgLbl = ep:FindFirstChild("ErrorMessage", true)
            if msgLbl and type(msgLbl.Text) == "string" and #msgLbl.Text > 0 then
                errMsg = msgLbl.Text
            end
        end
    end)
    return {
        isKicked = isKicked,
        errorCode = errCode,
        errorMessage = errMsg,
    }
end

pcall(function()
    table.insert(connections, GuiService.ErrorMessageChanged:Connect(function(newMsg)
        if type(newMsg) == "string" and #newMsg > 0 then
            emitEvent("KICK_PROMPT", newMsg, inspectKickState(), true)
        end
    end))
end)

-- 3. In-Game Chat (TextChatService)
pcall(function()
    local TextChatService = game:GetService("TextChatService")
    table.insert(connections, TextChatService.MessageReceived:Connect(function(chatMsg)
        local txt = chatMsg and chatMsg.Text or ""
        if txt == "" then return end
        local sender = chatMsg.TextSource and chatMsg.TextSource.Name or "System"
        emitEvent("CHAT_IN", string.format("%s: %s", sender, txt), {
            sender = sender,
            userId = chatMsg.TextSource and chatMsg.TextSource.UserId or nil,
            text = txt,
        })
    end))
    table.insert(connections, TextChatService.SendingMessage:Connect(function(chatMsg)
        local txt = chatMsg and chatMsg.Text or ""
        if txt == "" then return end
        emitEvent("CHAT_OUT", string.format("%s: %s", AccountName, txt), {
            sender = AccountName,
            text = txt,
        })
    end))
end)

-- 4. ProximityPrompts
pcall(function()
    local ProximityPromptService = game:GetService("ProximityPromptService")
    table.insert(connections, ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
        local who = plr and plr.Name or AccountName
        local path = safeFullName(prompt)
        emitEvent("PROMPT_TRIGGERED", string.format("%s triggered %s (%s)", who, tostring(prompt.ActionText), tostring(prompt.ObjectText)), {
            player = who,
            path = path,
            actionText = prompt.ActionText,
            objectText = prompt.ObjectText,
        })
    end))
    table.insert(connections, ProximityPromptService.PromptShown:Connect(function(prompt)
        emitEvent("PROMPT_SHOWN", string.format("Prompt in range: %s (%s)", tostring(prompt.ActionText), safeFullName(prompt)), {
            path = safeFullName(prompt),
            actionText = prompt.ActionText,
            objectText = prompt.ObjectText,
            maxDistance = prompt.MaxActivationDistance,
        })
    end))
end)

-- 5. LocalPlayer & Character Lifecycle / Health / Tools / Attributes
pcall(function()
    table.insert(connections, LocalPlayer.AttributeChanged:Connect(function(attr)
        local val = LocalPlayer:GetAttribute(attr)
        emitEvent("ATTR_CHANGED", string.format("Player.%s = %s", tostring(attr), tostring(val)), {
            target = "LocalPlayer",
            attribute = attr,
            value = val,
        })
    end))
end)

local function bindCharacterSignals(char)
    for _, c in ipairs(charConnections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(charConnections)
    if not char then return end

    emitEvent("CHAR_SPAWNED", "Character spawned: " .. safeFullName(char), nil)

    table.insert(charConnections, char.AttributeChanged:Connect(function(attr)
        local val = char:GetAttribute(attr)
        emitEvent("ATTR_CHANGED", string.format("Character.%s = %s", tostring(attr), tostring(val)), {
            target = "Character",
            attribute = attr,
            value = val,
        })
    end))

    local function bindTool(tool)
        if not tool:IsA("Tool") then return end
        table.insert(charConnections, tool.Activated:Connect(function()
            emitEvent("TOOL_ACTIVATED", "Activated tool: " .. tostring(tool.Name), {
                tool = tool.Name,
                gripPos = vec3ToTable(tool.Grip.Position),
            })
        end))
    end

    for _, child in ipairs(char:GetChildren()) do
        if child:IsA("Tool") then bindTool(child) end
    end

    table.insert(charConnections, char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            bindTool(child)
            emitEvent("TOOL_EQUIPPED", "Equipped tool: " .. tostring(child.Name), { tool = child.Name })
        end
    end))

    table.insert(charConnections, char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") then
            emitEvent("TOOL_UNEQUIPPED", "Unequipped tool: " .. tostring(child.Name), { tool = child.Name })
        end
    end))

    task.spawn(function()
        local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
        if not hum or genv._OmniRemoteExecuteGen ~= currentGen then return end
        local lastHp = hum.Health
        table.insert(charConnections, hum.HealthChanged:Connect(function(newHp)
            local delta = newHp - lastHp
            lastHp = newHp
            if math.abs(delta) >= 0.5 then
                local evType = delta < 0 and "HEALTH_DAMAGE" or "HEALTH_HEAL"
                emitEvent(evType, string.format("Health %+.1f -> %.1f/%.1f", delta, newHp, hum.MaxHealth), {
                    delta = roundNum(delta, 1),
                    health = roundNum(newHp, 1),
                    maxHealth = roundNum(hum.MaxHealth, 1),
                })
            end
        end))
        table.insert(charConnections, hum.Died:Connect(function()
            local hrp = char:FindFirstChild("HumanoidRootPart")
            emitEvent("DIED", "LocalPlayer character died", {
                position = hrp and vec3ToTable(hrp.Position) or nil,
                attributes = char:GetAttributes(),
            }, true)
        end))
    end)
end

if LocalPlayer.Character then
    bindCharacterSignals(LocalPlayer.Character)
end
table.insert(connections, LocalPlayer.CharacterAdded:Connect(bindCharacterSignals))

-- ==============================================================================
-- 1HZ WORLD & SESSION SNAPSHOT BUILDER
-- ==============================================================================
local cachedPrompts = {}
local lastPromptScanClock = 0

local function getNearbyPrompts(originPos)
    if not originPos then return {} end
    local now = os.clock()
    if (now - lastPromptScanClock) > 3.0 then
        lastPromptScanClock = now
        table.clear(cachedPrompts)
        pcall(function()
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") then
                    table.insert(cachedPrompts, d)
                end
            end
        end)
    end

    local results = {}
    for _, p in ipairs(cachedPrompts) do
        if p and p.Parent and p.Enabled then
            local okPos, pPos = pcall(function()
                local par = p.Parent
                if par:IsA("BasePart") then return par.Position end
                if par:IsA("Attachment") then return par.WorldPosition end
                if par:IsA("Model") then return par:GetPivot().Position end
                local bp = par:FindFirstAncestorWhichIsA("BasePart")
                if bp then return bp.Position end
                return nil
            end)
            if okPos and pPos then
                local dist = (pPos - originPos).Magnitude
                if dist <= 65 then
                    table.insert(results, {
                        actionText = tostring(p.ActionText),
                        objectText = tostring(p.ObjectText),
                        path = safeFullName(p),
                        distance = roundNum(dist, 1),
                        maxDistance = roundNum(p.MaxActivationDistance, 1),
                        holdDuration = roundNum(p.HoldDuration, 2),
                        keyCode = tostring(p.KeyboardKeyCode.Name),
                    })
                end
            end
        end
    end
    table.sort(results, function(a, b) return a.distance < b.distance end)
    while #results > 8 do table.remove(results) end
    return results
end

local function buildLiveStateSnapshot()
    local nowEpoch = os.time()
    local pingMs = 0
    local luaHeapMB = roundNum(collectgarbage("count") / 1024, 2)
    pcall(function()
        local ssi = Stats.Network.ServerStatsItem
        local dp = ssi and (ssi:FindFirstChild("Data Ping") or ssi:FindFirstChild("Network Ping"))
        if dp then pingMs = roundNum(dp:GetValue(), 1) end
    end)

    local kickState = inspectKickState()

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    local myPos = hrp and hrp.Position or nil

    -- Camera & Raycast Look Target
    local camPos, camLook, lookTarget = nil, nil, nil
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then
            camPos = vec3ToTable(cam.CFrame.Position)
            camLook = vec3ToTable(cam.CFrame.LookVector)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            if char then params.FilterDescendantsInstances = { char } end
            local hit = workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 150, params)
            if hit and hit.Instance then
                lookTarget = {
                    instance = safeFullName(hit.Instance),
                    className = hit.Instance.ClassName,
                    distance = roundNum(hit.Distance, 1),
                    hitPos = vec3ToTable(hit.Position),
                }
            end
        end
    end)

    -- Equipped Tool & Backpack
    local equippedTools = {}
    if char then
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") then
                table.insert(equippedTools, c.Name)
            end
        end
    end
    local bpSample = {}
    local bpCount = 0
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        for _, c in ipairs(bp:GetChildren()) do
            if c:IsA("Tool") then
                bpCount = bpCount + 1
                if #bpSample < 12 then
                    table.insert(bpSample, c.Name)
                end
            end
        end
    end

    -- Combined Attributes & Leaderstats
    local attrs = {}
    pcall(function()
        for k, v in pairs(LocalPlayer:GetAttributes()) do attrs["Player." .. tostring(k)] = sanitizeValue(v, 1) end
        if char then
            for k, v in pairs(char:GetAttributes()) do attrs["Char." .. tostring(k)] = sanitizeValue(v, 1) end
        end
    end)
    local leaderstats = {}
    pcall(function()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        if ls then
            for _, item in ipairs(ls:GetChildren()) do
                pcall(function() leaderstats[item.Name] = sanitizeValue(item.Value, 1) end)
            end
        end
    end)

    -- Nearby Players
    local nearbyPlayers = {}
    local playerCharSet = {}
    if char then playerCharSet[char] = true end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local pChar = plr.Character
            if pChar then playerCharSet[pChar] = true end
            local pHrp = pChar and (pChar:FindFirstChild("HumanoidRootPart") or pChar.PrimaryPart)
            local pHum = pChar and pChar:FindFirstChildOfClass("Humanoid")
            local pTool = pChar and pChar:FindFirstChildOfClass("Tool")
            local dist = (myPos and pHrp) and roundNum((pHrp.Position - myPos).Magnitude, 1) or 9999
            table.insert(nearbyPlayers, {
                name = plr.Name,
                displayName = plr.DisplayName,
                distance = dist,
                health = pHum and roundNum(pHum.Health, 1) or nil,
                tool = pTool and pTool.Name or nil,
                position = pHrp and vec3ToTable(pHrp.Position) or nil,
            })
        end
    end
    table.sort(nearbyPlayers, function(a, b) return (a.distance or 9999) < (b.distance or 9999) end)
    while #nearbyPlayers > 10 do table.remove(nearbyPlayers) end

    -- Nearby Non-Player Entities / Models with Humanoids
    local nearbyEntities = {}
    if myPos then
        pcall(function()
            for _, child in ipairs(workspace:GetChildren()) do
                if child:IsA("Model") and not playerCharSet[child] then
                    local eHum = child:FindFirstChildOfClass("Humanoid")
                    local eRoot = child:FindFirstChild("HumanoidRootPart") or child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
                    if eRoot and (eHum or child:GetAttribute("IsEntity") or child.Name:find("Moving") or child.Name:find("Rig") or child.Name:find("NPC")) then
                        local dist = (eRoot.Position - myPos).Magnitude
                        if dist <= 250 then
                            table.insert(nearbyEntities, {
                                name = child.Name,
                                path = safeFullName(child),
                                distance = roundNum(dist, 1),
                                health = eHum and roundNum(eHum.Health, 1) or nil,
                                position = vec3ToTable(eRoot.Position),
                            })
                        end
                    end
                end
            end
        end)
        table.sort(nearbyEntities, function(a, b) return a.distance < b.distance end)
        while #nearbyEntities > 10 do table.remove(nearbyEntities) end
    end

    -- Visible PlayerGui ScreenGuis
    local visibleGuis = {}
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if pg then
            for _, g in ipairs(pg:GetChildren()) do
                if g:IsA("ScreenGui") and g.Enabled then
                    table.insert(visibleGuis, g.Name)
                end
            end
        end
    end)

    -- Omni Kernel & Packet Telemetry
    local pktMetrics = nil
    local recentPackets = {}
    if type(genv.GetOmniPacketMetrics) == "function" then
        pcall(function() pktMetrics = genv.GetOmniPacketMetrics() end)
    end
    if type(genv.GetOmniCapturedPackets) == "function" then
        pcall(function()
            local list = genv.GetOmniCapturedPackets()
            for i = math.max(1, #list - 4), #list do
                local p = list[i]
                if p then
                    table.insert(recentPackets, {
                        seq = p.seq,
                        dir = p.direction,
                        id = p.packetId,
                        target = p.targetName or p.remoteKey,
                        size = p.size,
                        args = p.decodedArgs,
                    })
                end
            end
        end)
    end

    local snapshot = {
        session = {
            account = AccountName,
            displayName = LocalPlayer.DisplayName,
            userId = LocalPlayer.UserId,
            placeId = game.PlaceId,
            placeName = cachedPlaceName,
            jobId = game.JobId,
            uptimeSec = roundNum(os.clock() - startClock, 1),
            lastSeen = nowEpoch,
            fps = currentFps,
            pingMs = pingMs,
            luaHeapMB = luaHeapMB,
        },
        kickState = kickState,
        player = {
            hasCharacter = char ~= nil,
            alive = (hum ~= nil and hum.Health > 0),
            health = hum and roundNum(hum.Health, 1) or 0,
            maxHealth = hum and roundNum(hum.MaxHealth, 1) or 0,
            walkSpeed = hum and roundNum(hum.WalkSpeed, 1) or 0,
            humanoidState = hum and tostring(hum:GetState().Name) or "None",
            sit = hum and hum.Sit or false,
            position = myPos and vec3ToTable(myPos) or nil,
            velocity = hrp and vec3ToTable(hrp.AssemblyLinearVelocity) or nil,
            speed = hrp and roundNum(hrp.AssemblyLinearVelocity.Magnitude, 1) or 0,
            lookVector = hrp and vec3ToTable(hrp.CFrame.LookVector) or nil,
            cameraPos = camPos,
            cameraLook = camLook,
            cameraLookTarget = lookTarget,
            equippedTool = #equippedTools > 0 and (#equippedTools == 1 and equippedTools[1] or string.format("%s (+%d)", equippedTools[1], #equippedTools - 1)) or nil,
            equippedCount = #equippedTools,
            backpackCount = bpCount,
            backpackSample = bpSample,
            attributes = attrs,
            leaderstats = leaderstats,
        },
        surroundings = {
            totalPlayersInServer = #Players:GetPlayers(),
            nearbyPlayers = nearbyPlayers,
            nearbyEntities = nearbyEntities,
            nearbyPrompts = getNearbyPrompts(myPos),
            visibleGuis = visibleGuis,
        },
        omni = {
            packetMetrics = pktMetrics,
            recentPackets = recentPackets,
            waitLeakAutoKills = genv._OmniWaitLeakAutoKills or 0,
        },
    }

    latestStateSnapshot = snapshot
    return snapshot
end

local function updateRegistryAndState()
    pcall(function()
        local snap = buildLiveStateSnapshot()
        writefile(StateFile, HttpService:JSONEncode(snap))

        local data = {}
        if isfile(RegistryFile) then
            local ok, parsed = pcall(function() return HttpService:JSONDecode(readfile(RegistryFile)) end)
            if ok and type(parsed) == "table" then
                data = parsed
            end
        end

        local now = os.time()
        for name, info in pairs(data) do
            if type(info) == "table" and info.LastSeen then
                if now - info.LastSeen > 6 then
                    data[name] = nil
                end
            end
        end

        data[AccountName] = {
            AccountName = AccountName,
            DisplayName = LocalPlayer.DisplayName,
            UserId = LocalPlayer.UserId,
            PlaceId = game.PlaceId,
            PlaceName = cachedPlaceName,
            JobId = game.JobId,
            LastSeen = now,
            FPS = snap.session.fps,
            PingMs = snap.session.pingMs,
            LuaHeapMB = snap.session.luaHeapMB,
            Health = snap.player.health,
            MaxHealth = snap.player.maxHealth,
            Position = snap.player.position,
            EquippedTool = snap.player.equippedTool,
            IsKicked = snap.kickState.isKicked,
            KickMessage = snap.kickState.errorMessage,
        }

        writefile(RegistryFile, HttpService:JSONEncode(data))
    end)
end

-- Expose in-memory getters for instant access
genv.GetOmniLiveState = function()
    return latestStateSnapshot or buildLiveStateSnapshot()
end

genv.GetOmniRecentEvents = function(limit)
    local n = tonumber(limit) or 50
    local out = {}
    for i = math.max(1, #recentEventsRing - n + 1), #recentEventsRing do
        table.insert(out, recentEventsRing[i])
    end
    return out
end

genv._OmniRemoteExecuteCleanUp = function()
    genv._OmniRemoteExecuteRunning = false
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    for _, c in ipairs(charConnections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(connections)
    table.clear(charConnections)
    flushPendingEvents()
end

print("[RemoteExecute] Active & Listening on: " .. FileName)
writeLog("[SYSTEM]: ", "RemoteExecute Full-Awareness Bridge Initialized on " .. AccountName)
emitEvent("BRIDGE_INIT", "Omni Telemetry Bridge active on " .. AccountName, { placeId = game.PlaceId, jobId = game.JobId }, true)
updateRegistryAndState()

-- Main 50ms IPC Execution & Telemetry Flush Loop
task.spawn(function()
    local flushTimer = 0
    local stateTimer = 0

    while genv._OmniRemoteExecuteGen == currentGen and genv._OmniRemoteExecuteRunning do
        task.wait(0.05)
        flushTimer = flushTimer + 0.05
        stateTimer = stateTimer + 0.05

        if flushTimer >= 0.5 then
            flushTimer = 0
            flushPendingEvents()
        end

        if stateTimer >= 1.0 then
            stateTimer = 0
            updateRegistryAndState()
        end

        local success, content = pcall(function()
            return readfile(FileName)
        end)

        if success and content ~= LastContent then
            LastContent = content

            if content:gsub("%s+", "") ~= "" then
                local payloadCopy = content
                pcall(function()
                    writefile(FileName, "")
                    LastContent = ""
                end)

                task.spawn(function()
                    local compiledCode, syntaxError = loadstring(payloadCopy, "=" .. AccountName .. "_External")
                    if compiledCode then
                        local runtimeSuccess, runtimeError = xpcall(compiledCode, function(err)
                            return debug.traceback(tostring(err), 2)
                        end)
                        if not runtimeSuccess then
                            local err = "[" .. AccountName .. " Exec | RUNTIME ERROR]:\n" .. tostring(runtimeError)
                            warn(err)
                            writeLog("", err)
                            emitEvent("EXEC_ERROR", tostring(runtimeError):sub(1, 200), { traceback = tostring(runtimeError) }, true)
                        else
                            local msg = "[" .. AccountName .. " Exec]: Successfully executed."
                            print(msg)
                            writeLog("", msg)
                            emitEvent("EXEC_OK", "External payload executed cleanly", { bytes = #payloadCopy })
                        end
                    else
                        local err = "[" .. AccountName .. " Exec | SYNTAX ERROR]:\n" .. tostring(syntaxError)
                        warn(err)
                        writeLog("", err)
                        emitEvent("EXEC_SYNTAX_ERROR", tostring(syntaxError), nil, true)
                    end
                end)
            end
        end
    end
end)
