--!stage Kernel
--!name KernelTaskScheduler
--!priority 990
--[[
    ==============================================================================
    ANTIGRAVITY KERNEL TASK SCHEDULER (Windows 11 Fluent Automation Engine)
    ==============================================================================
    Standalone trigger & action automation subsystem for Roblox.
    Separate from Task Manager (taskmgr vs taskschd).

    Hotkey: Shift + F7 (or getgenv().ToggleTaskScheduler())

    Features:
    - Event Triggers: PlayerAdded, CharacterAdded, Died, Seated, WindowFocus, Timers, Custom Signals
    - Condition Guards: Staff Rank, InVehicle, Health, Custom Luau Filter
    - Action Multi-Tool: Task/Loop Controls, Run Luau Code, Toast Notifications, Server Hop, Rejoin
    - Win11 Modern Action Cards View with in-game Visual Rule Creation Wizard
    - Persistent Storage: workspace/TaskScheduler_Tasks.json (Universal + Place-Specific)
    ==============================================================================
]]

if not game or not game.GetService then return end

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then return end

-- Clean up any prior instance
if getgenv()._KernelTaskSchedulerCleanUp and type(getgenv()._KernelTaskSchedulerCleanUp) == "function" then
    pcall(getgenv()._KernelTaskSchedulerCleanUp)
end

-- ==============================================================================
-- 1. PERSISTENCE ENGINE & DATA STORE
-- ==============================================================================
local Storage = {
    file = "TaskScheduler_Tasks.json",
    data = {
        version = 1,
        universal = {},
        places = {},
    },
    saveTimer = nil,
}

Storage.load = function()
    if not (isfile and readfile and HttpService) then return end
    local filePath = Storage.file
    if not isfile(filePath) and isfile("workspace/" .. filePath) then
        filePath = "workspace/" .. filePath
    end
    if not isfile(filePath) then
        -- Default starter tasks
        Storage.data.universal = {
            {
                id = "anti_afk_timer",
                name = "Anti-AFK Heartbeat",
                description = "Periodic virtual heartbeat to bypass Roblox 20-minute idle disconnect",
                enabled = true,
                scope = "universal",
                trigger = { type = "Timer", interval = 600 },
                condition = { type = "Always" },
                actions = {
                    { type = "VirtualPoke" },
                    { type = "Toast", title = "Anti-AFK", message = "Virtual heartbeat poked" }
                },
                telemetry = { invocations = 0, lastRun = 0, lastResult = "Ready" }
            },
            {
                id = "staff_detector",
                name = "Staff / Mod Alert",
                description = "Notifies when a high-ranking group member or moderator joins the server",
                enabled = false,
                scope = "universal",
                trigger = { type = "Signal", preset = "PlayerAdded" },
                condition = { type = "StaffRank", minRank = 100, groupId = 0 },
                actions = {
                    { type = "Toast", title = "⚠️ STAFF JOINED", message = "A staff member has entered the server!" },
                    { type = "PauseAllLoops" }
                },
                telemetry = { invocations = 0, lastRun = 0, lastResult = "Ready" }
            }
        }

        local placeIdStr = tostring(game.PlaceId or "0")
        if game.PlaceId == 6764533218 then -- Washiez
            Storage.data.places[placeIdStr] = {
                {
                    id = "washiez_mount_align",
                    name = "Auto-Car Alignment on Seat",
                    description = "Boosts vehicle alignment loop when mounting a car seat",
                    enabled = true,
                    scope = "place",
                    trigger = { type = "Signal", preset = "Seated" },
                    condition = { type = "InVehicle" },
                    actions = {
                        { type = "SetTaskPriority", target = "AutomaticCarAlignmentWashiez", priority = 95 },
                        { type = "Toast", title = "Vehicle Mounted", message = "Engaged car alignment at 95 Priority" }
                    },
                    telemetry = { invocations = 0, lastRun = 0, lastResult = "Ready" }
                }
            }
        end

        Storage.save(true)
        return
    end

    local ok, raw = pcall(readfile, filePath)
    if ok and raw and raw ~= "" then
        local decOk, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
        if decOk and type(decoded) == "table" then
            Storage.data.universal = decoded.universal or {}
            Storage.data.places = decoded.places or {}
        end
    end
end

Storage.save = function(immediate)
    if not (writefile and HttpService) then return end
    local function doWrite()
        pcall(function()
            writefile(Storage.file, HttpService:JSONEncode(Storage.data))
        end)
    end

    if immediate then
        if Storage.saveTimer then task.cancel(Storage.saveTimer); Storage.saveTimer = nil end
        doWrite()
    else
        if not Storage.saveTimer then
            Storage.saveTimer = task.delay(0.25, function()
                Storage.saveTimer = nil
                doWrite()
            end)
        end
    end
end

-- ==============================================================================
-- 2. AUTOMATION DISPATCHER & TRIGGER ENGINE
-- ==============================================================================
local Engine = {
    activeTasks = {},       -- [taskId] = taskObj
    liveConnections = {},   -- [taskId] = { conn1, conn2, ... }
    timerThreads = {},      -- [taskId] = thread
    lastTriggered = {},     -- [taskId] = timestamp
}

local function resolveInstance(pathStr)
    if not pathStr or pathStr == "" then return nil end
    if typeof(pathStr) == "Instance" then return pathStr end
    local cur = game
    for seg in string.gmatch(tostring(pathStr), "[^%.]+") do
        if cur == game and (seg == "game" or seg == "workspace" or seg == "Workspace") then
            if seg == "workspace" or seg == "Workspace" then cur = workspace end
        else
            cur = cur:FindFirstChild(seg)
        end
        if not cur then break end
    end
    if cur then return cur end
    local fn = loadstring("return " .. tostring(pathStr))
    if fn then
        local ok, res = pcall(fn)
        if ok and typeof(res) == "Instance" then return res end
    end
    return nil
end

local function resolveCFrame(target)
    if not target then return nil end
    if typeof(target) == "CFrame" then return target end
    if typeof(target) == "Vector3" then return CFrame.new(target) end
    if type(target) == "table" and target.x and target.y and target.z then
        return CFrame.new(tonumber(target.x) or 0, tonumber(target.y) or 0, tonumber(target.z) or 0)
    end
    if type(target) == "string" then
        local x, y, z = target:match("([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)")
        if x and y and z and tonumber(x) and tonumber(y) and tonumber(z) then
            return CFrame.new(tonumber(x), tonumber(y), tonumber(z))
        end
        local inst = resolveInstance(target)
        if inst then
            if inst:IsA("BasePart") then return inst.CFrame end
            if inst:IsA("Model") then return inst:GetPivot() end
            if inst:IsA("Attachment") then return inst.WorldCFrame end
        end
        local otherPlayer = Players:FindFirstChild(target)
        if otherPlayer and otherPlayer.Character then
            local otherHrp = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
            if otherHrp then return otherHrp.CFrame end
        end
    end
    return nil
end

local function substituteArg(arg)
    if type(arg) == "string" then
        if arg == "$position" then
            local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            return hrp and hrp.Position or Vector3.zero
        elseif arg == "$cframe" then
            local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            return hrp and hrp.CFrame or CFrame.identity
        elseif arg == "$player" or arg == "$localplayer" then
            return LocalPlayer
        elseif arg == "$userId" or arg == "$userid" then
            return LocalPlayer.UserId
        elseif arg == "$name" or arg == "$username" then
            return LocalPlayer.Name
        elseif arg == "$character" or arg == "$char" then
            return LocalPlayer.Character
        elseif arg == "$placeId" or arg == "$placeid" then
            return game.PlaceId
        elseif arg:find("^$leaderstat:") then
            local statName = arg:sub(13)
            local ls = LocalPlayer:FindFirstChild("leaderstats")
            local st = ls and ls:FindFirstChild(statName)
            if st then return st.Value end
        end
    end
    return arg
end

local function evaluateCondition(taskObj, triggerArgs)
    local cond = taskObj.condition or { type = "Always" }
    if cond.type == "Always" then
        return true
    elseif cond.type == "InVehicle" then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.SeatPart and hum.SeatPart:IsA("VehicleSeat") then
            return true
        end
        return false
    elseif cond.type == "StaffRank" then
        local player = triggerArgs and triggerArgs[1]
        if player and player:IsA("Player") then
            local grp = tonumber(cond.groupId) or 0
            local minR = tonumber(cond.minRank) or 100
            if grp > 0 then
                local ok, r = pcall(function() return player:GetRankInGroup(grp) end)
                if ok and r >= minR then return true end
            else
                local gi = player:FindFirstChild("GroupInfo")
                local rank = gi and gi:FindFirstChild("Rank")
                if rank and rank.Value >= minR then return true end
            end
        end
        return false
    elseif cond.type == "LowHealth" then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local threshold = tonumber(cond.threshold) or 25
        return hum and hum.Health <= threshold
    elseif cond.type == "ClockElapsed" then
        local threshold = tonumber(cond.threshold) or 0
        return os.clock() >= threshold
    elseif cond.type == "StatThreshold" then
        local statName = cond.stat or "Cash"
        local op = cond.operator or ">="
        local targetVal = tonumber(cond.value) or 0
        local curVal = 0
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local st = ls and ls:FindFirstChild(statName)
        if st and type(st.Value) == "number" then
            curVal = st.Value
        else
            local attr = LocalPlayer:GetAttribute(statName)
            if type(attr) == "number" then curVal = attr end
        end
        if op == ">=" then return curVal >= targetVal
        elseif op == "<=" then return curVal <= targetVal
        elseif op == ">" then return curVal > targetVal
        elseif op == "<" then return curVal < targetVal
        elseif op == "==" then return curVal == targetVal
        elseif op == "!=" then return curVal ~= targetVal end
        return false
    elseif cond.type == "ObjectProximity" then
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return false end
        local targetCF = resolveCFrame(cond.target)
        if not targetCF then return false end
        local dist = (hrp.Position - targetCF.Position).Magnitude
        local threshold = tonumber(cond.distance) or 30
        local mode = cond.mode or "within"
        if mode == "within" then
            return dist <= threshold
        else
            return dist > threshold
        end
    elseif cond.type == "CustomLua" then
        if cond.code and cond.code ~= "" then
            local fn, err = loadstring("return function(args) " .. cond.code .. " end")
            if fn then
                local ok, res = pcall(fn(), triggerArgs)
                return ok and (res == true)
            end
        end
        return false
    end
    return true
end

local showToastNotification -- forward declaration

local function executeActions(taskObj, triggerArgs)
    local actions = taskObj.actions or {}
    local successCount = 0

    for _, act in ipairs(actions) do
        local ok, err = pcall(function()
            if act.type == "Toast" then
                if showToastNotification then
                    showToastNotification(act.title or taskObj.name, act.message or "Triggered", 3.5)
                end
            elseif act.type == "Delay" then
                task.wait(math.max(0.01, tonumber(act.duration) or 1.0))
            elseif act.type == "PauseAllLoops" then
                if getgenv().PauseAllLoops then getgenv().PauseAllLoops(true) end
            elseif act.type == "ResumeAllLoops" then
                if getgenv().ResumeAllLoops then getgenv().ResumeAllLoops() end
            elseif act.type == "SetTaskPriority" then
                if getgenv().SetSchedulerTaskPriority and act.target then
                    getgenv().SetSchedulerTaskPriority(act.target, tonumber(act.priority) or 80)
                end
            elseif act.type == "SetTaskHz" then
                if getgenv().SetSchedulerTaskHz and act.target then
                    getgenv().SetSchedulerTaskHz(act.target, tonumber(act.hz) or 60)
                end
            elseif act.type == "RunLuau" then
                if act.code and act.code ~= "" then
                    local fn, compileErr = loadstring(act.code)
                    if fn then
                        task.spawn(fn, triggerArgs)
                    else
                        warn("[TaskScheduler] Luau compilation failed:", compileErr)
                    end
                end
            elseif act.type == "VirtualPoke" then
                pcall(function()
                    local VirtualUser = game:GetService("VirtualUser")
                    if VirtualUser then
                        VirtualUser:CaptureController()
                        VirtualUser:ClickButton2(Vector2.new(10, 10))
                    end
                end)
            elseif act.type == "VirtualInput" then
                local VIM = game:GetService("VirtualInputManager")
                local kcName = act.key or "E"
                local kc = Enum.KeyCode[kcName]
                if VIM and kc then
                    VIM:SendKeyEvent(true, kc, false, game)
                    task.wait(math.max(0.05, tonumber(act.duration) or 0.1))
                    VIM:SendKeyEvent(false, kc, false, game)
                end
            elseif act.type == "FollowRoute" then
                local targetNode = act.targetNode or act.node
                local routeFile = act.route or act.fileName or "road_network.json"
                if not _G.RunBot then
                    if isfile and isfile("prison_follower.lua") then
                        pcall(function() loadstring(readfile("prison_follower.lua"))() end)
                    end
                end
                if _G.RunBot and targetNode then
                    _G.RunBot(targetNode, routeFile)
                else
                    warn("[TaskScheduler] FollowRoute: _G.RunBot unavailable or targetNode missing")
                end
            elseif act.type == "StopRoute" then
                if _G.StopBot then
                    _G.StopBot()
                end
            elseif act.type == "TweenTo" then
                local TweenService = game:GetService("TweenService")
                local char = LocalPlayer.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp and act.target then
                    local targetCF = resolveCFrame(act.target)
                    if targetCF then
                        local dist = (hrp.Position - targetCF.Position).Magnitude
                        local dur = tonumber(act.duration)
                        if not dur or dur <= 0 then
                            local spd = tonumber(act.speed) or 50
                            dur = dist / spd
                        end
                        dur = math.clamp(dur, 0.05, 120)
                        local ti = TweenInfo.new(dur, Enum.EasingStyle.Linear)
                        local tw = TweenService:Create(hrp, ti, { CFrame = targetCF })
                        tw:Play()
                        if act.wait ~= false then
                            tw.Completed:Wait()
                        end
                    end
                end
            elseif act.type == "InstantTeleport" then
                local char = LocalPlayer.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if char and hrp and act.target then
                    local targetCF = resolveCFrame(act.target)
                    if targetCF then
                        char:PivotTo(targetCF)
                        pcall(function()
                            hrp.AssemblyLinearVelocity = Vector3.zero
                            hrp.AssemblyAngularVelocity = Vector3.zero
                        end)
                    end
                end
            elseif act.type == "ActivatePrompt" then
                local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local bestPrompt = nil
                    local bestDist = tonumber(act.maxDistance) or 35
                    local promptName = act.target and act.target:lower() or ""
                    for _, desc in ipairs(workspace:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") and desc.Enabled then
                            local promptPos = nil
                            if desc.Parent then
                                if desc.Parent:IsA("BasePart") then
                                    promptPos = desc.Parent.Position
                                elseif desc.Parent:IsA("Model") then
                                    promptPos = desc.Parent:GetPivot().Position
                                elseif desc.Parent:IsA("Attachment") then
                                    promptPos = desc.Parent.WorldPosition
                                end
                            end
                            if promptPos then
                                local d = (hrp.Position - promptPos).Magnitude
                                if d <= bestDist then
                                    if promptName == "" or promptName == "nearest" or desc.Name:lower():find(promptName, 1, true) or (desc.Parent and desc.Parent.Name:lower():find(promptName, 1, true)) then
                                        bestPrompt = desc
                                        bestDist = d
                                    end
                                end
                            end
                        end
                    end
                    if bestPrompt then
                        local holdDur = tonumber(act.holdDuration) or bestPrompt.HoldDuration or 0
                        if type(fireproximityprompt) == "function" then
                            fireproximityprompt(bestPrompt, holdDur)
                        else
                            bestPrompt:InputHoldBegin()
                            if holdDur > 0 then task.wait(holdDur) end
                            bestPrompt:InputHoldEnd()
                        end
                    end
                end
            elseif act.type == "FireRemote" or act.type == "InvokeServer" then
                local remoteObj = resolveInstance(act.remote)
                if remoteObj then
                    local processedArgs = {}
                    local rawArgs = act.args
                    if type(rawArgs) == "string" then
                        if rawArgs:sub(1,1) == "[" then
                            local okJ, dec = pcall(function() return HttpService:JSONDecode(rawArgs) end)
                            if okJ and type(dec) == "table" then
                                rawArgs = dec
                            else
                                rawArgs = { rawArgs }
                            end
                        else
                            rawArgs = { rawArgs }
                        end
                    elseif type(rawArgs) ~= "table" then
                        rawArgs = rawArgs and { rawArgs } or {}
                    end

                    for _, v in ipairs(rawArgs) do
                        table.insert(processedArgs, substituteArg(v))
                    end

                    if act.type == "FireRemote" and remoteObj:IsA("RemoteEvent") then
                        remoteObj:FireServer(unpack(processedArgs))
                    elseif act.type == "InvokeServer" and remoteObj:IsA("RemoteFunction") then
                        remoteObj:InvokeServer(unpack(processedArgs))
                    elseif remoteObj:IsA("RemoteEvent") then
                        remoteObj:FireServer(unpack(processedArgs))
                    elseif remoteObj:IsA("RemoteFunction") then
                        remoteObj:InvokeServer(unpack(processedArgs))
                    end
                end
            elseif act.type == "ServerHop" then
                pcall(function()
                    local TeleportService = game:GetService("TeleportService")
                    TeleportService:Teleport(game.PlaceId, LocalPlayer)
                end)
            elseif act.type == "Rejoin" then
                pcall(function()
                    local TeleportService = game:GetService("TeleportService")
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
                end)
            end
        end)
        if ok then
            successCount = successCount + 1
        else
            warn("[TaskScheduler] Action failed (" .. tostring(act.type) .. "):", err)
        end
    end

    taskObj.telemetry = taskObj.telemetry or {}
    taskObj.telemetry.invocations = (taskObj.telemetry.invocations or 0) + 1
    taskObj.telemetry.lastRun = os.time()
    taskObj.telemetry.lastResult = string.format("Executed %d/%d actions", successCount, #actions)
    Storage.save(false)
end

local function fireTask(taskObj, ...)
    if not taskObj.enabled then return end

    local now = os.clock()
    local cooldown = tonumber(taskObj.cooldown) or 1.0
    local last = Engine.lastTriggered[taskObj.id] or 0
    if now - last < cooldown then return end

    local triggerArgs = { ... }
    local pass = evaluateCondition(taskObj, triggerArgs)
    if pass then
        Engine.lastTriggered[taskObj.id] = now
        task.spawn(executeActions, taskObj, triggerArgs)
    end
end

Engine.unbindTask = function(taskId)
    local conns = Engine.liveConnections[taskId]
    if conns then
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        Engine.liveConnections[taskId] = nil
    end
    local thread = Engine.timerThreads[taskId]
    if thread then
        pcall(task.cancel, thread)
        Engine.timerThreads[taskId] = nil
    end
end

Engine.bindTask = function(taskObj)
    if not taskObj or not taskObj.enabled then return end
    Engine.unbindTask(taskObj.id)

    local trig = taskObj.trigger or {}
    local conns = {}

    if trig.type == "Timer" then
        local intv = math.max(0.1, tonumber(trig.interval) or 60)
        local thread = task.spawn(function()
            while taskObj.enabled do
                task.wait(intv)
                if taskObj.enabled then
                    fireTask(taskObj)
                end
            end
        end)
        Engine.timerThreads[taskObj.id] = thread

    elseif trig.type == "ClockInterval" then
        local intv = math.max(0.05, tonumber(trig.interval) or 5.0)
        local thread = task.spawn(function()
            local nextTick = os.clock() + intv
            while taskObj.enabled do
                local now = os.clock()
                if now >= nextTick then
                    nextTick = now + intv
                    fireTask(taskObj, now)
                end
                task.wait(math.min(0.1, intv / 2))
            end
        end)
        Engine.timerThreads[taskObj.id] = thread

    elseif trig.type == "ClockTarget" then
        local targetTime = tonumber(trig.target) or (os.clock() + (tonumber(trig.interval) or 10))
        local thread = task.spawn(function()
            while taskObj.enabled do
                local now = os.clock()
                if now >= targetTime then
                    fireTask(taskObj, now)
                    break
                end
                task.wait(0.5)
            end
        end)
        Engine.timerThreads[taskObj.id] = thread

    elseif trig.type == "Signal" then
        local preset = trig.preset
        if preset == "PlayerAdded" then
            local c = Players.PlayerAdded:Connect(function(plr) fireTask(taskObj, plr) end)
            table.insert(conns, c)
        elseif preset == "PlayerRemoving" then
            local c = Players.PlayerRemoving:Connect(function(plr) fireTask(taskObj, plr) end)
            table.insert(conns, c)
        elseif preset == "CharacterAdded" then
            local c = LocalPlayer.CharacterAdded:Connect(function(char) fireTask(taskObj, char) end)
            table.insert(conns, c)
        elseif preset == "Died" then
            local function hookChar(char)
                if not char then return end
                local hum = char:WaitForChild("Humanoid", 3)
                if hum then
                    local c = hum.Died:Connect(function() fireTask(taskObj) end)
                    table.insert(conns, c)
                end
            end
            if LocalPlayer.Character then hookChar(LocalPlayer.Character) end
            local c = LocalPlayer.CharacterAdded:Connect(hookChar)
            table.insert(conns, c)
        elseif preset == "Seated" then
            local function hookSeat(char)
                if not char then return end
                local hum = char:WaitForChild("Humanoid", 3)
                if hum then
                    local c = hum.Seated:Connect(function(active, seat) fireTask(taskObj, active, seat) end)
                    table.insert(conns, c)
                end
            end
            if LocalPlayer.Character then hookSeat(LocalPlayer.Character) end
            local c = LocalPlayer.CharacterAdded:Connect(hookSeat)
            table.insert(conns, c)
        elseif preset == "WindowFocus" then
            local c = UserInputService.WindowFocusReleased:Connect(function() fireTask(taskObj) end)
            table.insert(conns, c)
        elseif preset == "Idled" then
            local c = LocalPlayer.Idled:Connect(function(time) fireTask(taskObj, time) end)
            table.insert(conns, c)
        end

    elseif trig.type == "CustomSignal" and trig.path and trig.path ~= "" then
        pcall(function()
            local sig = nil
            local fn = loadstring("return " .. trig.path)
            if fn then
                local ok, res = pcall(fn)
                if ok and (typeof(res) == "RBXScriptSignal" or (type(res) == "table" and type(res.Connect) == "function")) then
                    sig = res
                end
            end
            if not sig then
                local cur = game
                for seg in string.gmatch(trig.path, "[^%.]+") do
                    cur = cur:FindFirstChild(seg)
                    if not cur then break end
                end
                if cur and (typeof(cur) == "RBXScriptSignal" or (type(cur) == "table" and type(cur.Connect) == "function")) then
                    sig = cur
                end
            end
            if sig and sig.Connect then
                local c = sig:Connect(function(...) fireTask(taskObj, ...) end)
                table.insert(conns, c)
            end
        end)
    end

    Engine.liveConnections[taskObj.id] = conns
end

Engine.syncAll = function()
    -- Clear current active
    for id in pairs(Engine.activeTasks) do
        Engine.unbindTask(id)
    end
    Engine.activeTasks = {}

    -- Bind universal
    for _, t in pairs(Storage.data.universal or {}) do
        if type(t) == "table" and t.id then
            Engine.activeTasks[t.id] = t
            if t.enabled then Engine.bindTask(t) end
        end
    end

    -- Bind place-specific
    local placeIdStr = tostring(game.PlaceId or "0")
    for _, t in pairs(Storage.data.places[placeIdStr] or {}) do
        if type(t) == "table" and t.id then
            Engine.activeTasks[t.id] = t
            if t.enabled then Engine.bindTask(t) end
        end
    end
end

Storage.load()
Engine.syncAll()

-- ==============================================================================
-- 3. WINDOWS 11 FLUENT GUI & ACTION CARDS
-- ==============================================================================
local function getGuiContainer()
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, coreGui = pcall(function() return CoreGui end)
    if ok and coreGui then return coreGui end
    return LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local parentContainer = getGuiContainer()
if not parentContainer then return end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "WindowsTaskSchedulerGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Enabled = false
ScreenGui.Parent = parentContainer

-- Toast Notification Container
local ToastContainer = Instance.new("Frame")
ToastContainer.Name = "ToastContainer"
ToastContainer.Size = UDim2.new(0, 320, 1, -20)
ToastContainer.Position = UDim2.new(1, -330, 0, 10)
ToastContainer.BackgroundTransparency = 1
ToastContainer.ZIndex = 500
ToastContainer.Parent = ScreenGui

local ToastLayout = Instance.new("UIListLayout")
ToastLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
ToastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
ToastLayout.Padding = UDim.new(0, 8)
ToastLayout.Parent = ToastContainer

showToastNotification = function(title, message, duration)
    if not ScreenGui then return end
    duration = duration or 3.5

    local toast = Instance.new("Frame")
    toast.Name = "Toast"
    toast.Size = UDim2.new(1, 0, 0, 56)
    toast.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    toast.BorderSizePixel = 0
    toast.ZIndex = 501
    toast.Parent = ToastContainer

    local tCorner = Instance.new("UICorner")
    tCorner.CornerRadius = UDim.new(0, 6)
    tCorner.Parent = toast

    local tStroke = Instance.new("UIStroke")
    tStroke.Color = Color3.fromRGB(60, 130, 240)
    tStroke.Thickness = 1
    tStroke.Transparency = 0.4
    tStroke.Parent = toast

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.Size = UDim2.new(0, 4, 1, -8)
    accent.Position = UDim2.new(0, 4, 0, 4)
    accent.BackgroundColor3 = Color3.fromRGB(60, 150, 255)
    accent.BorderSizePixel = 0
    accent.ZIndex = 502
    accent.Parent = toast
    local acCorner = Instance.new("UICorner")
    acCorner.CornerRadius = UDim.new(1, 0)
    acCorner.Parent = accent

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Name = "TitleLbl"
    titleLbl.Size = UDim2.new(1, -24, 0, 18)
    titleLbl.Position = UDim2.new(0, 16, 0, 8)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 12
    titleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Text = tostring(title or "Scheduler Alert")
    titleLbl.ZIndex = 502
    titleLbl.Parent = toast

    local descLbl = Instance.new("TextLabel")
    descLbl.Name = "DescLbl"
    descLbl.Size = UDim2.new(1, -24, 0, 16)
    descLbl.Position = UDim2.new(0, 16, 0, 28)
    descLbl.BackgroundTransparency = 1
    descLbl.Font = Enum.Font.Gotham
    descLbl.TextSize = 10
    descLbl.TextColor3 = Color3.fromRGB(160, 175, 205)
    descLbl.TextXAlignment = Enum.TextXAlignment.Left
    descLbl.Text = tostring(message or "")
    descLbl.ZIndex = 502
    descLbl.Parent = toast

    task.delay(duration, function()
        if toast and toast.Parent then
            local tw = TweenService:Create(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 })
            tw:Play()
            tw.Completed:Wait()
            toast:Destroy()
        end
    end)
end

-- Main Window Frame
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 720, 0, 480)
MainFrame.Position = UDim2.new(0.5, -360, 0.5, -240)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Active = true
MainFrame.Parent = ScreenGui

local mCorner = Instance.new("UICorner")
mCorner.CornerRadius = UDim.new(0, 8)
mCorner.Parent = MainFrame

local mStroke = Instance.new("UIStroke")
mStroke.Thickness = 1.5
mStroke.Color = Color3.fromRGB(45, 55, 75)
mStroke.Transparency = 0.2
mStroke.Parent = MainFrame

-- Title Bar
local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 42)
TitleBar.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame

local tbCorner = Instance.new("UICorner")
tbCorner.CornerRadius = UDim.new(0, 8)
tbCorner.Parent = TitleBar

-- Window Dragging
local isDragging = false
local dragStart = Vector3.new()
local startPos = UDim2.new()

TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        isDragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if isDragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
        isDragging = false
    end
end)

local IconLbl = Instance.new("TextLabel")
IconLbl.Name = "IconLbl"
IconLbl.Size = UDim2.new(0, 32, 1, 0)
IconLbl.Position = UDim2.new(0, 12, 0, 0)
IconLbl.BackgroundTransparency = 1
IconLbl.Font = Enum.Font.GothamBold
IconLbl.TextSize = 16
IconLbl.Text = "⚡"
IconLbl.TextColor3 = Color3.fromRGB(70, 160, 255)
IconLbl.Parent = TitleBar

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Name = "TitleLbl"
TitleLbl.Size = UDim2.new(0, 220, 1, 0)
TitleLbl.Position = UDim2.new(0, 44, 0, 0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.Font = Enum.Font.GothamBold
TitleLbl.TextSize = 13
TitleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
TitleLbl.TextXAlignment = Enum.TextXAlignment.Left
TitleLbl.Text = "Automation Scheduler"
TitleLbl.Parent = TitleBar

local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.Size = UDim2.new(0, 32, 0, 26)
CloseBtn.Position = UDim2.new(1, -38, 0.5, -13)
CloseBtn.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
CloseBtn.BorderSizePixel = 0
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 11
CloseBtn.TextColor3 = Color3.fromRGB(220, 225, 240)
CloseBtn.Text = "X"
CloseBtn.Parent = TitleBar
local cbCorner = Instance.new("UICorner")
cbCorner.CornerRadius = UDim.new(0, 4)
cbCorner.Parent = CloseBtn

CloseBtn.MouseButton1Click:Connect(function()
    ScreenGui.Enabled = false
end)

-- Top Control Ribbon (Search, Filter, New Task Button)
local Ribbon = Instance.new("Frame")
Ribbon.Name = "Ribbon"
Ribbon.Size = UDim2.new(1, -24, 0, 38)
Ribbon.Position = UDim2.new(0, 12, 0, 48)
Ribbon.BackgroundTransparency = 1
Ribbon.Parent = MainFrame

local SearchBox = Instance.new("TextBox")
SearchBox.Name = "SearchBox"
SearchBox.Size = UDim2.new(0, 220, 0, 30)
SearchBox.Position = UDim2.new(0, 0, 0, 4)
SearchBox.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
SearchBox.BorderSizePixel = 0
SearchBox.Font = Enum.Font.Gotham
SearchBox.TextSize = 11
SearchBox.TextColor3 = Color3.fromRGB(235, 240, 255)
SearchBox.PlaceholderText = "Search scheduled tasks..."
SearchBox.PlaceholderColor3 = Color3.fromRGB(120, 135, 160)
SearchBox.TextXAlignment = Enum.TextXAlignment.Left
SearchBox.ClearTextOnFocus = false
SearchBox.Text = ""
SearchBox.Parent = Ribbon
local sbCorner = Instance.new("UICorner")
sbCorner.CornerRadius = UDim.new(0, 4)
sbCorner.Parent = SearchBox
local sbPad = Instance.new("UIPadding")
sbPad.PaddingLeft = UDim.new(0, 10)
sbPad.Parent = SearchBox

local ExportAllBtn = Instance.new("TextButton")
ExportAllBtn.Name = "ExportAllBtn"
ExportAllBtn.Size = UDim2.new(0, 95, 0, 30)
ExportAllBtn.Position = UDim2.new(1, -315, 0, 4)
ExportAllBtn.BackgroundColor3 = Color3.fromRGB(35, 55, 80)
ExportAllBtn.BorderSizePixel = 0
ExportAllBtn.Font = Enum.Font.GothamBold
ExportAllBtn.TextSize = 11
ExportAllBtn.TextColor3 = Color3.fromRGB(160, 210, 255)
ExportAllBtn.Text = "📤 Export All"
ExportAllBtn.Parent = Ribbon
local eabCorner = Instance.new("UICorner")
eabCorner.CornerRadius = UDim.new(0, 4)
eabCorner.Parent = ExportAllBtn

local ImportBtn = Instance.new("TextButton")
ImportBtn.Name = "ImportBtn"
ImportBtn.Size = UDim2.new(0, 85, 0, 30)
ImportBtn.Position = UDim2.new(1, -210, 0, 4)
ImportBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 45)
ImportBtn.BorderSizePixel = 0
ImportBtn.Font = Enum.Font.GothamBold
ImportBtn.TextSize = 11
ImportBtn.TextColor3 = Color3.fromRGB(120, 235, 170)
ImportBtn.Text = "📥 Import"
ImportBtn.Parent = Ribbon
local ibCorner = Instance.new("UICorner")
ibCorner.CornerRadius = UDim.new(0, 4)
ibCorner.Parent = ImportBtn

local NewTaskBtn = Instance.new("TextButton")
NewTaskBtn.Name = "NewTaskBtn"
NewTaskBtn.Size = UDim2.new(0, 95, 0, 30)
NewTaskBtn.Position = UDim2.new(1, -115, 0, 4)
NewTaskBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 220)
NewTaskBtn.BorderSizePixel = 0
NewTaskBtn.Font = Enum.Font.GothamBold
NewTaskBtn.TextSize = 11
NewTaskBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
NewTaskBtn.Text = "+ New Task"
NewTaskBtn.Parent = Ribbon
local ntbCorner = Instance.new("UICorner")
ntbCorner.CornerRadius = UDim.new(0, 4)
ntbCorner.Parent = NewTaskBtn

-- Card Scroll List
local ScrollList = Instance.new("ScrollingFrame")
ScrollList.Name = "ScrollList"
ScrollList.Size = UDim2.new(1, -24, 1, -100)
ScrollList.Position = UDim2.new(0, 12, 0, 90)
ScrollList.BackgroundTransparency = 1
ScrollList.BorderSizePixel = 0
ScrollList.ScrollBarThickness = 5
ScrollList.ScrollBarImageColor3 = Color3.fromRGB(50, 65, 90)
ScrollList.CanvasSize = UDim2.new(0, 0, 0, 0)
ScrollList.Parent = MainFrame

local ListLayout = Instance.new("UIListLayout")
ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListLayout.Padding = UDim.new(0, 8)
ListLayout.Parent = ScrollList

ListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    ScrollList.CanvasSize = UDim2.new(0, 0, 0, ListLayout.AbsoluteContentSize.Y + 20)
end)

-- Empty Placeholder Label
local EmptyLbl = Instance.new("TextLabel")
EmptyLbl.Name = "EmptyLbl"
EmptyLbl.Size = UDim2.new(1, 0, 0, 100)
EmptyLbl.Position = UDim2.new(0, 0, 0, 40)
EmptyLbl.BackgroundTransparency = 1
EmptyLbl.Font = Enum.Font.GothamMedium
EmptyLbl.TextSize = 12
EmptyLbl.TextColor3 = Color3.fromRGB(110, 125, 150)
EmptyLbl.Text = "No automation tasks scheduled. Click '+ New Task' to build one."
EmptyLbl.Visible = false
EmptyLbl.Parent = ScrollList

-- Export Helpers
local function exportTaskToJson(taskObj)
    local exportCopy = {
        name = taskObj.name,
        description = taskObj.description,
        enabled = taskObj.enabled,
        scope = taskObj.scope,
        trigger = taskObj.trigger,
        condition = taskObj.condition,
        actions = taskObj.actions
    }
    local ok, json = pcall(function() return HttpService:JSONEncode(exportCopy) end)
    if ok and json then
        pcall(function()
            if setclipboard then
                setclipboard(json)
            elseif toclipboard then
                toclipboard(json)
            else
                writefile("Exported_Workflow.json", json)
            end
        end)
        if showToastNotification then
            showToastNotification("Workflow Exported", string.format("Copied '%s' JSON to clipboard", taskObj.name), 3.0)
        end
    end
end

local function exportAllTasksToJson()
    local all = {}
    for _, t in pairs(Storage.data.universal or {}) do
        if type(t) == "table" and t.name then
            table.insert(all, {
                name = t.name,
                description = t.description,
                enabled = t.enabled,
                scope = t.scope,
                trigger = t.trigger,
                condition = t.condition,
                actions = t.actions
            })
        end
    end
    local placeIdStr = tostring(game.PlaceId or "0")
    for _, t in pairs(Storage.data.places[placeIdStr] or {}) do
        if type(t) == "table" and t.name then
            table.insert(all, {
                name = t.name,
                description = t.description,
                enabled = t.enabled,
                scope = t.scope,
                trigger = t.trigger,
                condition = t.condition,
                actions = t.actions
            })
        end
    end
    local ok, json = pcall(function() return HttpService:JSONEncode(all) end)
    if ok and json then
        pcall(function()
            if setclipboard then
                setclipboard(json)
            elseif toclipboard then
                toclipboard(json)
            else
                writefile("Exported_All_Workflows.json", json)
            end
        end)
        if showToastNotification then
            showToastNotification("All Workflows Exported", string.format("Copied %d workflows to clipboard", #all), 3.0)
        end
    end
end

ExportAllBtn.MouseButton1Click:Connect(exportAllTasksToJson)

local refreshCardList -- forward declaration

-- Render Task Card
local cachedCards = {}

local function renderCard(taskObj, idx)
    local card = cachedCards[taskObj.id]
    if not card then
        card = Instance.new("Frame")
        card.Name = taskObj.id
        card.Size = UDim2.new(1, 0, 0, 72)
        card.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
        card.BorderSizePixel = 0
        card.LayoutOrder = idx
        card.Parent = ScrollList

        local cCorner = Instance.new("UICorner")
        cCorner.CornerRadius = UDim.new(0, 6)
        cCorner.Parent = card

        local cStroke = Instance.new("UIStroke")
        cStroke.Thickness = 1
        cStroke.Color = Color3.fromRGB(38, 46, 64)
        cStroke.Parent = card

        local dot = Instance.new("Frame")
        dot.Name = "Dot"
        dot.Size = UDim2.new(0, 8, 0, 8)
        dot.Position = UDim2.new(0, 14, 0, 16)
        dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120)
        dot.BorderSizePixel = 0
        dot.Parent = card
        local dCorn = Instance.new("UICorner")
        dCorn.CornerRadius = UDim.new(1, 0)
        dCorn.Parent = dot

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Name = "NameLbl"
        nameLbl.Size = UDim2.new(0.45, 0, 0, 18)
        nameLbl.Position = UDim2.new(0, 30, 0, 11)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamBold
        nameLbl.TextSize = 12
        nameLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.Parent = card

        local descLbl = Instance.new("TextLabel")
        descLbl.Name = "DescLbl"
        descLbl.Size = UDim2.new(0.55, 0, 0, 14)
        descLbl.Position = UDim2.new(0, 30, 0, 31)
        descLbl.BackgroundTransparency = 1
        descLbl.Font = Enum.Font.Gotham
        descLbl.TextSize = 10
        descLbl.TextColor3 = Color3.fromRGB(150, 165, 190)
        descLbl.TextXAlignment = Enum.TextXAlignment.Left
        descLbl.TextTruncate = Enum.TextTruncate.AtEnd
        descLbl.Parent = card

        local triggerBadge = Instance.new("TextLabel")
        triggerBadge.Name = "TriggerBadge"
        triggerBadge.Size = UDim2.new(0, 120, 0, 18)
        triggerBadge.Position = UDim2.new(0, 30, 0, 48)
        triggerBadge.BackgroundColor3 = Color3.fromRGB(30, 40, 60)
        triggerBadge.BorderSizePixel = 0
        triggerBadge.Font = Enum.Font.GothamBold
        triggerBadge.TextSize = 9
        triggerBadge.TextColor3 = Color3.fromRGB(100, 180, 255)
        triggerBadge.Parent = card
        local tbCorn = Instance.new("UICorner")
        tbCorn.CornerRadius = UDim.new(0, 3)
        tbCorn.Parent = triggerBadge

        local condBadge = Instance.new("TextLabel")
        condBadge.Name = "ConditionBadge"
        condBadge.Size = UDim2.new(0, 110, 0, 18)
        condBadge.Position = UDim2.new(0, 156, 0, 48)
        condBadge.BackgroundColor3 = Color3.fromRGB(25, 45, 40)
        condBadge.BorderSizePixel = 0
        condBadge.Font = Enum.Font.GothamBold
        condBadge.TextSize = 9
        condBadge.TextColor3 = Color3.fromRGB(100, 230, 170)
        condBadge.Parent = card
        local cbCorn = Instance.new("UICorner")
        cbCorn.CornerRadius = UDim.new(0, 3)
        cbCorn.Parent = condBadge

        local scopeBadge = Instance.new("TextLabel")
        scopeBadge.Name = "ScopeBadge"
        scopeBadge.Size = UDim2.new(0, 65, 0, 18)
        scopeBadge.Position = UDim2.new(0, 272, 0, 48)
        scopeBadge.BackgroundColor3 = Color3.fromRGB(35, 30, 50)
        scopeBadge.BorderSizePixel = 0
        scopeBadge.Font = Enum.Font.GothamBold
        scopeBadge.TextSize = 9
        scopeBadge.TextColor3 = Color3.fromRGB(200, 120, 255)
        scopeBadge.Parent = card
        local sbCorn2 = Instance.new("UICorner")
        sbCorn2.CornerRadius = UDim.new(0, 3)
        sbCorn2.Parent = scopeBadge

        -- Right Action Controls
        local ToggleBtn = Instance.new("TextButton")
        ToggleBtn.Name = "ToggleBtn"
        ToggleBtn.Size = UDim2.new(0, 64, 0, 26)
        ToggleBtn.Position = UDim2.new(1, -244, 0.5, -13)
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
        ToggleBtn.BorderSizePixel = 0
        ToggleBtn.Font = Enum.Font.GothamBold
        ToggleBtn.TextSize = 10
        ToggleBtn.TextColor3 = Color3.fromRGB(220, 230, 250)
        ToggleBtn.Parent = card
        local togCorn = Instance.new("UICorner")
        togCorn.CornerRadius = UDim.new(0, 4)
        togCorn.Parent = ToggleBtn

        local RunNowBtn = Instance.new("TextButton")
        RunNowBtn.Name = "RunNowBtn"
        RunNowBtn.Size = UDim2.new(0, 70, 0, 26)
        RunNowBtn.Position = UDim2.new(1, -172, 0.5, -13)
        RunNowBtn.BackgroundColor3 = Color3.fromRGB(30, 70, 130)
        RunNowBtn.BorderSizePixel = 0
        RunNowBtn.Font = Enum.Font.GothamBold
        RunNowBtn.TextSize = 10
        RunNowBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        RunNowBtn.Text = "▶ Run Now"
        RunNowBtn.Parent = card
        local rnCorn = Instance.new("UICorner")
        rnCorn.CornerRadius = UDim.new(0, 4)
        rnCorn.Parent = RunNowBtn

        local CardExportBtn = Instance.new("TextButton")
        CardExportBtn.Name = "CardExportBtn"
        CardExportBtn.Size = UDim2.new(0, 32, 0, 26)
        CardExportBtn.Position = UDim2.new(1, -94, 0.5, -13)
        CardExportBtn.BackgroundColor3 = Color3.fromRGB(25, 45, 65)
        CardExportBtn.BorderSizePixel = 0
        CardExportBtn.Font = Enum.Font.GothamBold
        CardExportBtn.TextSize = 11
        CardExportBtn.TextColor3 = Color3.fromRGB(140, 200, 255)
        CardExportBtn.Text = "📋"
        CardExportBtn.Parent = card
        local cebCorn = Instance.new("UICorner")
        cebCorn.CornerRadius = UDim.new(0, 4)
        cebCorn.Parent = CardExportBtn

        local TrashBtn = Instance.new("TextButton")
        TrashBtn.Name = "TrashBtn"
        TrashBtn.Size = UDim2.new(0, 32, 0, 26)
        TrashBtn.Position = UDim2.new(1, -54, 0.5, -13)
        TrashBtn.BackgroundColor3 = Color3.fromRGB(60, 25, 30)
        TrashBtn.BorderSizePixel = 0
        TrashBtn.Font = Enum.Font.GothamBold
        TrashBtn.TextSize = 11
        TrashBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
        TrashBtn.Text = "X"
        TrashBtn.Parent = card
        local trCorn = Instance.new("UICorner")
        trCorn.CornerRadius = UDim.new(0, 4)
        trCorn.Parent = TrashBtn

        ToggleBtn.MouseButton1Click:Connect(function()
            taskObj.enabled = not taskObj.enabled
            if taskObj.enabled then
                Engine.bindTask(taskObj)
            else
                Engine.unbindTask(taskObj.id)
            end
            Storage.save(true)
            renderCard(taskObj, idx)
        end)

        RunNowBtn.MouseButton1Click:Connect(function()
            task.spawn(executeActions, taskObj, {})
            renderCard(taskObj, idx)
        end)

        CardExportBtn.MouseButton1Click:Connect(function()
            exportTaskToJson(taskObj)
        end)

        TrashBtn.MouseButton1Click:Connect(function()
            Engine.unbindTask(taskObj.id)
            -- Remove from data
            local placeIdStr = tostring(game.PlaceId or "0")
            for i, t in ipairs(Storage.data.universal) do
                if t.id == taskObj.id then table.remove(Storage.data.universal, i); break end
            end
            if Storage.data.places[placeIdStr] then
                for i, t in ipairs(Storage.data.places[placeIdStr]) do
                    if t.id == taskObj.id then table.remove(Storage.data.places[placeIdStr], i); break end
                end
            end
            Storage.save(true)
            card:Destroy()
            cachedCards[taskObj.id] = nil
            if refreshCardList then refreshCardList() end
        end)

        cachedCards[taskObj.id] = card
    end

    card.LayoutOrder = idx

    -- Update content
    local dot = card:FindFirstChild("Dot")
    local nameLbl = card:FindFirstChild("NameLbl")
    local descLbl = card:FindFirstChild("DescLbl")
    local triggerBadge = card:FindFirstChild("TriggerBadge")
    local condBadge = card:FindFirstChild("ConditionBadge")
    local scopeBadge = card:FindFirstChild("ScopeBadge")
    local toggleBtn = card:FindFirstChild("ToggleBtn")

    if dot then
        dot.BackgroundColor3 = taskObj.enabled and Color3.fromRGB(50, 220, 120) or Color3.fromRGB(120, 130, 145)
    end
    if nameLbl then nameLbl.Text = taskObj.name or "Untitled Task" end
    if descLbl then
        local inv = (taskObj.telemetry and taskObj.telemetry.invocations) or 0
        descLbl.Text = string.format("%s  (Runs: %d)", taskObj.description or "Automated rule", inv)
    end
    if triggerBadge then
        local trig = taskObj.trigger or {}
        local trigStr = "⚡ Signal"
        if trig.type == "Timer" then
            trigStr = string.format("⏱ Every %ds", trig.interval or 60)
        elseif trig.type == "ClockInterval" then
            trigStr = string.format("🕒 clock: %0.1fs", tonumber(trig.interval) or 5)
        elseif trig.type == "ClockTarget" then
            trigStr = string.format("⏰ clock >= %ds", tonumber(trig.target) or 0)
        elseif trig.type == "CustomSignal" then
            trigStr = string.format("⚙ %s", trig.path or "Custom")
        else
            trigStr = string.format("⚡ %s", trig.preset or "Signal")
        end
        triggerBadge.Text = trigStr
    end
    if condBadge then
        local cond = taskObj.condition or { type = "Always" }
        local condText = "🛡 Always"
        if cond.type == "InVehicle" then
            condText = "🛡 In Vehicle"
        elseif cond.type == "StaffRank" then
            condText = string.format("🛡 Staff >= %d", tonumber(cond.minRank) or 100)
        elseif cond.type == "LowHealth" then
            condText = string.format("🛡 HP <= %d", tonumber(cond.threshold) or 25)
        elseif cond.type == "ClockElapsed" then
            condText = string.format("🛡 Clock >= %ds", tonumber(cond.threshold) or 0)
        elseif cond.type == "StatThreshold" then
            condText = string.format("🛡 %s %s %s", cond.stat or "Stat", cond.operator or ">=", tostring(cond.value or 0))
        elseif cond.type == "ObjectProximity" then
            condText = string.format("🛡 Near %s (%ds)", cond.target or "Object", tonumber(cond.distance) or 30)
        elseif cond.type == "CustomLua" then
            condText = "🛡 Custom Lua"
        end
        condBadge.Text = condText
    end
    if scopeBadge then
        scopeBadge.Text = (taskObj.scope == "place") and "PLACE" or "UNIVERSAL"
    end
    if toggleBtn then
        toggleBtn.Text = taskObj.enabled and "Active" or "Paused"
        toggleBtn.BackgroundColor3 = taskObj.enabled and Color3.fromRGB(25, 60, 40) or Color3.fromRGB(40, 45, 60)
        toggleBtn.TextColor3 = taskObj.enabled and Color3.fromRGB(100, 230, 150) or Color3.fromRGB(180, 190, 210)
    end

    card.Visible = true
    return card
end

refreshCardList = function()
    local filter = SearchBox.Text:lower()
    local allTasks = {}

    for _, t in pairs(Storage.data.universal or {}) do
        if type(t) == "table" and t.id then
            table.insert(allTasks, t)
        end
    end
    local placeIdStr = tostring(game.PlaceId or "0")
    for _, t in pairs(Storage.data.places[placeIdStr] or {}) do
        if type(t) == "table" and t.id then
            table.insert(allTasks, t)
        end
    end

    local visibleCount = 0
    local seen = {}

    for i, t in ipairs(allTasks) do
        seen[t.id] = true
        local matches = (filter == "") or (t.name and t.name:lower():find(filter, 1, true)) or (t.description and t.description:lower():find(filter, 1, true))
        if matches then
            renderCard(t, i)
            visibleCount = visibleCount + 1
        else
            local c = cachedCards[t.id]
            if c then c.Visible = false end
        end
    end

    for id, c in pairs(cachedCards) do
        if not seen[id] then
            c:Destroy()
            cachedCards[id] = nil
        end
    end

    EmptyLbl.Visible = (visibleCount == 0)
end

SearchBox:GetPropertyChangedSignal("Text"):Connect(refreshCardList)

-- ==============================================================================
-- 4. VISUAL RULE CREATION WIZARD MODAL
-- ==============================================================================
local WizardModal = Instance.new("Frame")
WizardModal.Name = "WizardModal"
WizardModal.Size = UDim2.new(0, 580, 0, 410)
WizardModal.Position = UDim2.new(0.5, -290, 0.5, -205)
WizardModal.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
WizardModal.BorderSizePixel = 0
WizardModal.Visible = false
WizardModal.ZIndex = 200
WizardModal.Parent = MainFrame

local wmCorner = Instance.new("UICorner")
wmCorner.CornerRadius = UDim.new(0, 8)
wmCorner.Parent = WizardModal

local wmStroke = Instance.new("UIStroke")
wmStroke.Thickness = 1.5
wmStroke.Color = Color3.fromRGB(60, 130, 240)
wmStroke.Parent = WizardModal

local wmTitle = Instance.new("TextLabel")
wmTitle.Size = UDim2.new(1, -32, 0, 20)
wmTitle.Position = UDim2.new(0, 16, 0, 8)
wmTitle.BackgroundTransparency = 1
wmTitle.Font = Enum.Font.GothamBold
wmTitle.TextSize = 13
wmTitle.TextColor3 = Color3.fromRGB(240, 245, 255)
wmTitle.TextXAlignment = Enum.TextXAlignment.Left
wmTitle.Text = "Create Automation Task"
wmTitle.ZIndex = 201
wmTitle.Parent = WizardModal

local wmSub = Instance.new("TextLabel")
wmSub.Size = UDim2.new(1, -32, 0, 14)
wmSub.Position = UDim2.new(0, 16, 0, 28)
wmSub.BackgroundTransparency = 1
wmSub.Font = Enum.Font.Gotham
wmSub.TextSize = 10
wmSub.TextColor3 = Color3.fromRGB(140, 155, 180)
wmSub.TextXAlignment = Enum.TextXAlignment.Left
wmSub.Text = "Configure event trigger, condition guard filter, and automated actions"
wmSub.ZIndex = 201
wmSub.Parent = WizardModal

local function createInputBox(name, placeholder, posX, posY, sizeX, sizeY, z)
    local tb = Instance.new("TextBox")
    tb.Name = name
    tb.Size = UDim2.new(sizeX.Scale, sizeX.Offset, sizeY.Scale, sizeY.Offset)
    tb.Position = UDim2.new(posX.Scale, posX.Offset, posY.Scale, posY.Offset)
    tb.BackgroundColor3 = Color3.fromRGB(25, 30, 44)
    tb.BorderSizePixel = 0
    tb.Font = Enum.Font.Gotham
    tb.TextSize = 11
    tb.TextColor3 = Color3.fromRGB(240, 245, 255)
    tb.PlaceholderText = placeholder
    tb.PlaceholderColor3 = Color3.fromRGB(120, 135, 160)
    tb.TextXAlignment = Enum.TextXAlignment.Left
    tb.ClearTextOnFocus = false
    tb.Text = ""
    tb.ZIndex = z or 201
    tb.Parent = WizardModal
    local tbc = Instance.new("UICorner")
    tbc.CornerRadius = UDim.new(0, 4)
    tbc.Parent = tb
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = tb
    return tb
end

-- Row 1: Name & Description
local InputName = createInputBox("InputName", "Task Name (e.g. Anti-AFK)", UDim.new(0, 16), UDim.new(0, 46), UDim.new(0.5, -22), UDim.new(0, 26))
local InputDesc = createInputBox("InputDesc", "Description / Notes", UDim.new(0.5, 6), UDim.new(0, 46), UDim.new(0.5, -22), UDim.new(0, 26))

-- Row 2: Trigger Selector & Parameter
local TriggerBtn = Instance.new("TextButton")
TriggerBtn.Name = "TriggerBtn"
TriggerBtn.Size = UDim2.new(0.5, -22, 0, 26)
TriggerBtn.Position = UDim2.new(0, 16, 0, 78)
TriggerBtn.BackgroundColor3 = Color3.fromRGB(30, 40, 60)
TriggerBtn.BorderSizePixel = 0
TriggerBtn.Font = Enum.Font.GothamBold
TriggerBtn.TextSize = 10
TriggerBtn.TextColor3 = Color3.fromRGB(120, 200, 255)
TriggerBtn.Text = "Trigger: ⏱ Timer (task.wait)"
TriggerBtn.ZIndex = 201
TriggerBtn.Parent = WizardModal
local trgCorn = Instance.new("UICorner")
trgCorn.CornerRadius = UDim.new(0, 4)
trgCorn.Parent = TriggerBtn

local InputTriggerParam = createInputBox("InputTriggerParam", "Interval seconds (e.g. 60)", UDim.new(0.5, 6), UDim.new(0, 78), UDim.new(0.5, -22), UDim.new(0, 26))
InputTriggerParam.Text = "60"

-- Row 3: Condition Selector & Parameter
local ConditionBtn = Instance.new("TextButton")
ConditionBtn.Name = "ConditionBtn"
ConditionBtn.Size = UDim2.new(0.5, -22, 0, 26)
ConditionBtn.Position = UDim2.new(0, 16, 0, 110)
ConditionBtn.BackgroundColor3 = Color3.fromRGB(26, 44, 38)
ConditionBtn.BorderSizePixel = 0
ConditionBtn.Font = Enum.Font.GothamBold
ConditionBtn.TextSize = 10
ConditionBtn.TextColor3 = Color3.fromRGB(110, 230, 170)
ConditionBtn.Text = "Condition: 🛡️ Always (No Filter)"
ConditionBtn.ZIndex = 201
ConditionBtn.Parent = WizardModal
local cndCorn = Instance.new("UICorner")
cndCorn.CornerRadius = UDim.new(0, 4)
cndCorn.Parent = ConditionBtn

local InputConditionParam = createInputBox("InputConditionParam", "Always evaluates true", UDim.new(0.5, 6), UDim.new(0, 110), UDim.new(0.5, -22), UDim.new(0, 26))

-- Row 4: Action Selector & Action Parameter
local ActionBtn = Instance.new("TextButton")
ActionBtn.Name = "ActionBtn"
ActionBtn.Size = UDim2.new(0.5, -22, 0, 26)
ActionBtn.Position = UDim2.new(0, 16, 0, 142)
ActionBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
ActionBtn.BorderSizePixel = 0
ActionBtn.Font = Enum.Font.GothamBold
ActionBtn.TextSize = 10
ActionBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
ActionBtn.Text = "Action: Toast Alert"
ActionBtn.ZIndex = 201
ActionBtn.Parent = WizardModal
local actCorn = Instance.new("UICorner")
actCorn.CornerRadius = UDim.new(0, 4)
actCorn.Parent = ActionBtn

local InputActionParam = createInputBox("InputActionParam", "Toast Message", UDim.new(0.5, 6), UDim.new(0, 142), UDim.new(0.5, -22), UDim.new(0, 26))
InputActionParam.Text = "Task activated"

-- Row 5: Scope & Action Extra Parameter
local ScopeBtn = Instance.new("TextButton")
ScopeBtn.Name = "ScopeBtn"
ScopeBtn.Size = UDim2.new(0.5, -22, 0, 26)
ScopeBtn.Position = UDim2.new(0, 16, 0, 174)
ScopeBtn.BackgroundColor3 = Color3.fromRGB(35, 30, 50)
ScopeBtn.BorderSizePixel = 0
ScopeBtn.Font = Enum.Font.GothamBold
ScopeBtn.TextSize = 10
ScopeBtn.TextColor3 = Color3.fromRGB(210, 140, 255)
ScopeBtn.Text = "Scope: Place-Specific"
ScopeBtn.ZIndex = 201
ScopeBtn.Parent = WizardModal
local scCorn = Instance.new("UICorner")
scCorn.CornerRadius = UDim.new(0, 4)
scCorn.Parent = ScopeBtn

local InputActionExtra = createInputBox("InputActionExtra", "Toast Title", UDim.new(0.5, 6), UDim.new(0, 174), UDim.new(0.5, -22), UDim.new(0, 26))
InputActionExtra.Text = "Scheduler"

-- Row 6: Action Luau Code
local CodeHeader = Instance.new("TextLabel")
CodeHeader.Size = UDim2.new(1, -32, 0, 14)
CodeHeader.Position = UDim2.new(0, 16, 0, 204)
CodeHeader.BackgroundTransparency = 1
CodeHeader.Font = Enum.Font.GothamBold
CodeHeader.TextSize = 10
CodeHeader.TextColor3 = Color3.fromRGB(160, 175, 205)
CodeHeader.TextXAlignment = Enum.TextXAlignment.Left
CodeHeader.Text = "Optional Action Luau Code (runs when triggered & conditions pass):"
CodeHeader.ZIndex = 201
CodeHeader.Parent = WizardModal

local InputCode = Instance.new("TextBox")
InputCode.Name = "InputCode"
InputCode.Size = UDim2.new(1, -32, 0, 56)
InputCode.Position = UDim2.new(0, 16, 0, 220)
InputCode.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
InputCode.BorderSizePixel = 0
InputCode.Font = Enum.Font.Code
InputCode.TextSize = 10
InputCode.TextColor3 = Color3.fromRGB(240, 245, 255)
InputCode.PlaceholderText = "-- Luau code here (e.g. print('Triggered!'))"
InputCode.PlaceholderColor3 = Color3.fromRGB(110, 120, 145)
InputCode.TextXAlignment = Enum.TextXAlignment.Left
InputCode.TextYAlignment = Enum.TextYAlignment.Top
InputCode.ClearTextOnFocus = false
InputCode.MultiLine = true
InputCode.TextWrapped = true
InputCode.Text = ""
InputCode.ZIndex = 201
InputCode.Parent = WizardModal
local icCorn = Instance.new("UICorner")
icCorn.CornerRadius = UDim.new(0, 4)
icCorn.Parent = InputCode
local icPad = Instance.new("UIPadding")
icPad.PaddingLeft = UDim.new(0, 8)
icPad.PaddingRight = UDim.new(0, 8)
icPad.PaddingTop = UDim.new(0, 6)
icPad.Parent = InputCode

-- Row 7: Summary Banner
local SummaryBanner = Instance.new("Frame")
SummaryBanner.Name = "SummaryBanner"
SummaryBanner.Size = UDim2.new(1, -32, 0, 36)
SummaryBanner.Position = UDim2.new(0, 16, 0, 284)
SummaryBanner.BackgroundColor3 = Color3.fromRGB(22, 27, 40)
SummaryBanner.BorderSizePixel = 0
SummaryBanner.ZIndex = 201
SummaryBanner.Parent = WizardModal
local sumCorn = Instance.new("UICorner")
sumCorn.CornerRadius = UDim.new(0, 4)
sumCorn.Parent = SummaryBanner

local SummaryLbl = Instance.new("TextLabel")
SummaryLbl.Name = "SummaryLbl"
SummaryLbl.Size = UDim2.new(1, -16, 1, 0)
SummaryLbl.Position = UDim2.new(0, 8, 0, 0)
SummaryLbl.BackgroundTransparency = 1
SummaryLbl.Font = Enum.Font.Gotham
SummaryLbl.TextSize = 10
SummaryLbl.TextColor3 = Color3.fromRGB(160, 185, 225)
SummaryLbl.TextXAlignment = Enum.TextXAlignment.Left
SummaryLbl.TextWrapped = true
SummaryLbl.Text = "📋 Rule: When Timer fires → IF Always → Execute Toast Alert"
SummaryLbl.ZIndex = 202
SummaryLbl.Parent = SummaryBanner

-- Footer Controls
local CancelBtn = Instance.new("TextButton")
CancelBtn.Name = "CancelBtn"
CancelBtn.Size = UDim2.new(0, 84, 0, 30)
CancelBtn.Position = UDim2.new(1, -242, 0, 330)
CancelBtn.BackgroundColor3 = Color3.fromRGB(30, 35, 48)
CancelBtn.BorderSizePixel = 0
CancelBtn.Font = Enum.Font.GothamBold
CancelBtn.TextSize = 11
CancelBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
CancelBtn.Text = "Cancel"
CancelBtn.ZIndex = 201
CancelBtn.Parent = WizardModal
local cc = Instance.new("UICorner")
cc.CornerRadius = UDim.new(0, 4)
cc.Parent = CancelBtn

local SaveTaskBtn = Instance.new("TextButton")
SaveTaskBtn.Name = "SaveTaskBtn"
SaveTaskBtn.Size = UDim2.new(0, 140, 0, 30)
SaveTaskBtn.Position = UDim2.new(1, -150, 0, 330)
SaveTaskBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 240)
SaveTaskBtn.BorderSizePixel = 0
SaveTaskBtn.Font = Enum.Font.GothamBold
SaveTaskBtn.TextSize = 11
SaveTaskBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SaveTaskBtn.Text = "Save & Activate"
SaveTaskBtn.ZIndex = 201
SaveTaskBtn.Parent = WizardModal
local stc = Instance.new("UICorner")
stc.CornerRadius = UDim.new(0, 4)
stc.Parent = SaveTaskBtn

-- Options & Logic
local TRIGGER_OPTIONS = {
    { label = "⏱ Timer (task.wait)", type = "Timer", placeholder = "Interval in sec (e.g. 60)", defaultParam = "60" },
    { label = "🕒 Clock Interval (os.clock)", type = "ClockInterval", placeholder = "os.clock interval sec (e.g. 5.0)", defaultParam = "5.0" },
    { label = "⏰ Clock Target (os.clock >= T)", type = "ClockTarget", placeholder = "Target os.clock uptime sec (e.g. 120)", defaultParam = "120" },
    { label = "⚡ Seated in Vehicle", type = "Signal", preset = "Seated", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Player Added", type = "Signal", preset = "PlayerAdded", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Player Removing", type = "Signal", preset = "PlayerRemoving", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Character Added", type = "Signal", preset = "CharacterAdded", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Character Died", type = "Signal", preset = "Died", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Window Focus Lost", type = "Signal", preset = "WindowFocus", placeholder = "No parameter needed", defaultParam = "" },
    { label = "💤 LocalPlayer Idled", type = "Signal", preset = "Idled", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚙️ Custom Signal / Path", type = "CustomSignal", placeholder = "Signal expr (e.g. workspace.ChildAdded)", defaultParam = "workspace.ChildAdded" },
}

local CONDITION_OPTIONS = {
    { label = "🛡️ Always (No Filter)", type = "Always", placeholder = "Always evaluates true", defaultParam = "" },
    { label = "🛡️ In Vehicle Seat", type = "InVehicle", placeholder = "Must be seated in VehicleSeat", defaultParam = "" },
    { label = "🛡️ Low Health (< Threshold)", type = "LowHealth", placeholder = "Health threshold (default 25)", defaultParam = "25" },
    { label = "🛡️ Staff / Mod Rank", type = "StaffRank", placeholder = "MinRank:GroupId (e.g. 100:0)", defaultParam = "100" },
    { label = "🛡️ Stat Threshold", type = "StatThreshold", placeholder = "Stat:Op:Val (e.g. Cash:>=:1000)", defaultParam = "Cash:>=:1000" },
    { label = "🛡️ Object Proximity", type = "ObjectProximity", placeholder = "Target:Dist:within (e.g. Door:25)", defaultParam = "Door:25" },
    { label = "🛡️ Clock Elapsed (os.clock)", type = "ClockElapsed", placeholder = "Clock threshold sec (e.g. 60)", defaultParam = "60" },
    { label = "🛡️ Custom Luau Filter", type = "CustomLua", placeholder = "Luau expr (e.g. args[1] ~= nil)", defaultParam = "return true" },
}

local ACTION_OPTIONS = {
    { label = "Toast Alert", type = "Toast", p1 = "Toast Message", def1 = "Task activated", p2 = "Toast Title", def2 = "Scheduler" },
    { label = "Follow Route", type = "FollowRoute", p1 = "Target Node (e.g. Yard)", def1 = "Yard", p2 = "Route File (e.g. road_network.json)", def2 = "road_network.json" },
    { label = "Stop Route", type = "StopRoute", p1 = "No parameter needed", def1 = "", p2 = "No parameter needed", def2 = "" },
    { label = "Tween To (CFrame)", type = "TweenTo", p1 = "Target Pos/Part (e.g. 0, 10, 0)", def1 = "0, 10, 0", p2 = "Duration sec (e.g. 2.0)", def2 = "2.0" },
    { label = "Instant Teleport", type = "InstantTeleport", p1 = "Target Pos/Part (e.g. 0, 10, 0)", def1 = "0, 10, 0", p2 = "No parameter needed", def2 = "" },
    { label = "Activate Prompt", type = "ActivatePrompt", p1 = "Prompt/Part Name or 'nearest'", def1 = "nearest", p2 = "Max Distance studs (e.g. 35)", def2 = "35" },
    { label = "Fire Remote Event", type = "FireRemote", p1 = "Remote Path (e.g. ReplicatedStorage.Remote)", def1 = "ReplicatedStorage.RemoteEvent", p2 = "Args array (e.g. [\"$position\"])", def2 = "[\"$position\"]" },
    { label = "Invoke Remote Func", type = "InvokeServer", p1 = "Remote Path (e.g. ReplicatedStorage.Func)", def1 = "ReplicatedStorage.RemoteFunction", p2 = "Args array (e.g. [\"$userId\"])", def2 = "[\"$userId\"]" },
    { label = "Virtual Keypress", type = "VirtualInput", p1 = "KeyCode (e.g. E, Space, F)", def1 = "E", p2 = "Hold duration sec (e.g. 0.1)", def2 = "0.1" },
    { label = "Virtual Poke (Anti-AFK)", type = "VirtualPoke", p1 = "No parameter needed", def1 = "", p2 = "No parameter needed", def2 = "" },
    { label = "Delay (Pipeline Wait)", type = "Delay", p1 = "Delay duration sec (e.g. 1.0)", def1 = "1.0", p2 = "No parameter needed", def2 = "" },
    { label = "Pause All Loops", type = "PauseAllLoops", p1 = "No parameter needed", def1 = "", p2 = "No parameter needed", def2 = "" },
    { label = "Resume All Loops", type = "ResumeAllLoops", p1 = "No parameter needed", def1 = "", p2 = "No parameter needed", def2 = "" },
    { label = "Server Hop", type = "ServerHop", p1 = "No parameter needed", def1 = "", p2 = "No parameter needed", def2 = "" },
    { label = "Rejoin Server", type = "Rejoin", p1 = "No parameter needed", def1 = "", p2 = "No parameter needed", def2 = "" },
    { label = "Run Luau Code", type = "RunLuau", p1 = "Custom Luau (see box below)", def1 = "", p2 = "No parameter needed", def2 = "" },
}

local curTrigIdx = 1
local curCondIdx = 1
local curActIdx = 1
local isUniversalScope = false

local function updateWizardSummary()
    local tOpt = TRIGGER_OPTIONS[curTrigIdx]
    local cOpt = CONDITION_OPTIONS[curCondIdx]
    local aOpt = ACTION_OPTIONS[curActIdx]
    SummaryLbl.Text = string.format("📋 Rule: When %s fires → IF %s → Execute %s", tOpt.label, cOpt.label, aOpt.label)
end

TriggerBtn.MouseButton1Click:Connect(function()
    curTrigIdx = (curTrigIdx % #TRIGGER_OPTIONS) + 1
    local opt = TRIGGER_OPTIONS[curTrigIdx]
    TriggerBtn.Text = "Trigger: " .. opt.label
    InputTriggerParam.PlaceholderText = opt.placeholder
    if opt.defaultParam ~= "" then
        InputTriggerParam.Text = opt.defaultParam
    else
        InputTriggerParam.Text = ""
    end
    updateWizardSummary()
end)

ConditionBtn.MouseButton1Click:Connect(function()
    curCondIdx = (curCondIdx % #CONDITION_OPTIONS) + 1
    local opt = CONDITION_OPTIONS[curCondIdx]
    ConditionBtn.Text = "Condition: " .. opt.label
    InputConditionParam.PlaceholderText = opt.placeholder
    if opt.defaultParam ~= "" then
        InputConditionParam.Text = opt.defaultParam
    else
        InputConditionParam.Text = ""
    end
    updateWizardSummary()
end)

ActionBtn.MouseButton1Click:Connect(function()
    curActIdx = (curActIdx % #ACTION_OPTIONS) + 1
    local opt = ACTION_OPTIONS[curActIdx]
    ActionBtn.Text = "Action: " .. opt.label
    InputActionParam.PlaceholderText = opt.p1
    InputActionParam.Text = opt.def1
    InputActionExtra.PlaceholderText = opt.p2
    InputActionExtra.Text = opt.def2
    updateWizardSummary()
end)

ScopeBtn.MouseButton1Click:Connect(function()
    isUniversalScope = not isUniversalScope
    ScopeBtn.Text = isUniversalScope and "Scope: Universal (All Games)" or "Scope: Place-Specific"
    ScopeBtn.BackgroundColor3 = isUniversalScope and Color3.fromRGB(25, 45, 65) or Color3.fromRGB(35, 30, 50)
    ScopeBtn.TextColor3 = isUniversalScope and Color3.fromRGB(100, 190, 255) or Color3.fromRGB(210, 140, 255)
end)

CancelBtn.MouseButton1Click:Connect(function()
    WizardModal.Visible = false
end)

NewTaskBtn.MouseButton1Click:Connect(function()
    InputName.Text = ""
    InputDesc.Text = ""
    InputCode.Text = ""
    curTrigIdx = 1
    curCondIdx = 1
    curActIdx = 1
    TriggerBtn.Text = "Trigger: " .. TRIGGER_OPTIONS[1].label
    InputTriggerParam.PlaceholderText = TRIGGER_OPTIONS[1].placeholder
    InputTriggerParam.Text = TRIGGER_OPTIONS[1].defaultParam
    ConditionBtn.Text = "Condition: " .. CONDITION_OPTIONS[1].label
    InputConditionParam.PlaceholderText = CONDITION_OPTIONS[1].placeholder
    InputConditionParam.Text = CONDITION_OPTIONS[1].defaultParam
    ActionBtn.Text = "Action: " .. ACTION_OPTIONS[1].label
    InputActionParam.PlaceholderText = ACTION_OPTIONS[1].p1
    InputActionParam.Text = ACTION_OPTIONS[1].def1
    InputActionExtra.PlaceholderText = ACTION_OPTIONS[1].p2
    InputActionExtra.Text = ACTION_OPTIONS[1].def2
    updateWizardSummary()
    WizardModal.Visible = true
end)

SaveTaskBtn.MouseButton1Click:Connect(function()
    local name = InputName.Text
    if name == "" then name = "New Automated Task" end
    local desc = InputDesc.Text
    local tOpt = TRIGGER_OPTIONS[curTrigIdx]
    local cOpt = CONDITION_OPTIONS[curCondIdx]
    local aOpt = ACTION_OPTIONS[curActIdx]
    if desc == "" then
        desc = string.format("When %s fires, execute %s", tOpt.label, aOpt.label)
    end

    -- Build Trigger
    local triggerObj = { type = tOpt.type }
    if tOpt.type == "Timer" then
        triggerObj.interval = math.max(0.1, tonumber(InputTriggerParam.Text) or 60)
    elseif tOpt.type == "ClockInterval" then
        triggerObj.interval = math.max(0.05, tonumber(InputTriggerParam.Text) or 5.0)
    elseif tOpt.type == "ClockTarget" then
        triggerObj.target = tonumber(InputTriggerParam.Text) or (os.clock() + 120)
    elseif tOpt.type == "Signal" then
        triggerObj.preset = tOpt.preset
    elseif tOpt.type == "CustomSignal" then
        triggerObj.path = InputTriggerParam.Text ~= "" and InputTriggerParam.Text or "workspace.ChildAdded"
    end

    -- Build Condition
    local conditionObj = { type = cOpt.type }
    if cOpt.type == "LowHealth" then
        conditionObj.threshold = tonumber(InputConditionParam.Text) or 25
    elseif cOpt.type == "StaffRank" then
        local r, g = string.match(InputConditionParam.Text or "", "(%d+):?(%d*)")
        conditionObj.minRank = tonumber(r) or 100
        conditionObj.groupId = tonumber(g) or 0
    elseif cOpt.type == "StatThreshold" then
        local st, op, val = string.match(InputConditionParam.Text or "", "([^:]+):?([^:]*):?(.*)")
        if not op or op == "" then op = ">=" end
        if tonumber(op) then
            val = op
            op = ">="
        end
        conditionObj.stat = st or "Cash"
        conditionObj.operator = op
        conditionObj.value = tonumber(val) or 0
    elseif cOpt.type == "ObjectProximity" then
        local tgt, dist, mode = string.match(InputConditionParam.Text or "", "([^:]+):?([^:]*):?(.*)")
        conditionObj.target = tgt or "Door"
        conditionObj.distance = tonumber(dist) or 25
        conditionObj.mode = (mode == "outside") and "outside" or "within"
    elseif cOpt.type == "ClockElapsed" then
        conditionObj.threshold = tonumber(InputConditionParam.Text) or 60
    elseif cOpt.type == "CustomLua" then
        conditionObj.code = InputConditionParam.Text ~= "" and InputConditionParam.Text or "return true"
    end

    -- Build Actions
    local actions = {}
    if aOpt.type == "Toast" then
        table.insert(actions, { type = "Toast", title = InputActionExtra.Text ~= "" and InputActionExtra.Text or name, message = InputActionParam.Text ~= "" and InputActionParam.Text or "Trigger activated" })
    elseif aOpt.type == "FollowRoute" then
        table.insert(actions, { type = "FollowRoute", targetNode = InputActionParam.Text ~= "" and InputActionParam.Text or "Yard", route = InputActionExtra.Text ~= "" and InputActionExtra.Text or "road_network.json" })
    elseif aOpt.type == "StopRoute" then
        table.insert(actions, { type = "StopRoute" })
    elseif aOpt.type == "TweenTo" then
        table.insert(actions, { type = "TweenTo", target = InputActionParam.Text ~= "" and InputActionParam.Text or "0, 10, 0", duration = tonumber(InputActionExtra.Text) or 2.0 })
    elseif aOpt.type == "InstantTeleport" then
        table.insert(actions, { type = "InstantTeleport", target = InputActionParam.Text ~= "" and InputActionParam.Text or "0, 10, 0" })
    elseif aOpt.type == "ActivatePrompt" then
        table.insert(actions, { type = "ActivatePrompt", target = InputActionParam.Text ~= "" and InputActionParam.Text or "nearest", maxDistance = tonumber(InputActionExtra.Text) or 35 })
    elseif aOpt.type == "FireRemote" then
        table.insert(actions, { type = "FireRemote", remote = InputActionParam.Text ~= "" and InputActionParam.Text or "ReplicatedStorage.RemoteEvent", args = InputActionExtra.Text ~= "" and InputActionExtra.Text or "[\"$position\"]" })
    elseif aOpt.type == "InvokeServer" then
        table.insert(actions, { type = "InvokeServer", remote = InputActionParam.Text ~= "" and InputActionParam.Text or "ReplicatedStorage.RemoteFunction", args = InputActionExtra.Text ~= "" and InputActionExtra.Text or "[\"$userId\"]" })
    elseif aOpt.type == "VirtualInput" then
        table.insert(actions, { type = "VirtualInput", key = InputActionParam.Text ~= "" and InputActionParam.Text or "E", duration = tonumber(InputActionExtra.Text) or 0.1 })
    elseif aOpt.type == "VirtualPoke" then
        table.insert(actions, { type = "VirtualPoke" })
    elseif aOpt.type == "Delay" then
        table.insert(actions, { type = "Delay", duration = tonumber(InputActionParam.Text) or 1.0 })
    elseif aOpt.type == "PauseAllLoops" then
        table.insert(actions, { type = "PauseAllLoops" })
    elseif aOpt.type == "ResumeAllLoops" then
        table.insert(actions, { type = "ResumeAllLoops" })
    elseif aOpt.type == "ServerHop" then
        table.insert(actions, { type = "ServerHop" })
    elseif aOpt.type == "Rejoin" then
        table.insert(actions, { type = "Rejoin" })
    end

    if InputCode.Text ~= "" then
        table.insert(actions, { type = "RunLuau", code = InputCode.Text })
    end

    local newTask = {
        id = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(100, 999)),
        name = name,
        description = desc,
        enabled = true,
        scope = isUniversalScope and "universal" or "place",
        trigger = triggerObj,
        condition = conditionObj,
        actions = actions,
        telemetry = { invocations = 0, lastRun = 0, lastResult = "Ready" }
    }

    if isUniversalScope then
        Storage.data.universal = Storage.data.universal or {}
        table.insert(Storage.data.universal, newTask)
    else
        local placeIdStr = tostring(game.PlaceId or "0")
        Storage.data.places[placeIdStr] = Storage.data.places[placeIdStr] or {}
        table.insert(Storage.data.places[placeIdStr], newTask)
    end

    Engine.bindTask(newTask)
    Storage.save(true)
    WizardModal.Visible = false
    refreshCardList()

    if showToastNotification then
        showToastNotification("Automation Scheduler", string.format("Activated '%s'", newTask.name), 3.0)
    end
end)

-- ==============================================================================
-- 4.5 IMPORT WORKFLOW MODAL
-- ==============================================================================
local ImportModal = Instance.new("Frame")
ImportModal.Name = "ImportModal"
ImportModal.Size = UDim2.new(0, 520, 0, 320)
ImportModal.Position = UDim2.new(0.5, -260, 0.5, -160)
ImportModal.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
ImportModal.BorderSizePixel = 0
ImportModal.Visible = false
ImportModal.ZIndex = 300
ImportModal.Parent = MainFrame

local imCorner = Instance.new("UICorner")
imCorner.CornerRadius = UDim.new(0, 8)
imCorner.Parent = ImportModal

local imStroke = Instance.new("UIStroke")
imStroke.Thickness = 1.5
imStroke.Color = Color3.fromRGB(60, 180, 110)
imStroke.Parent = ImportModal

local imTitle = Instance.new("TextLabel")
imTitle.Size = UDim2.new(1, -32, 0, 20)
imTitle.Position = UDim2.new(0, 16, 0, 12)
imTitle.BackgroundTransparency = 1
imTitle.Font = Enum.Font.GothamBold
imTitle.TextSize = 13
imTitle.TextColor3 = Color3.fromRGB(240, 245, 255)
imTitle.TextXAlignment = Enum.TextXAlignment.Left
imTitle.Text = "Import Automation Workflow"
imTitle.ZIndex = 301
imTitle.Parent = ImportModal

local imSub = Instance.new("TextLabel")
imSub.Size = UDim2.new(1, -32, 0, 14)
imSub.Position = UDim2.new(0, 16, 0, 32)
imSub.BackgroundTransparency = 1
imSub.Font = Enum.Font.Gotham
imSub.TextSize = 10
imSub.TextColor3 = Color3.fromRGB(140, 155, 180)
imSub.TextXAlignment = Enum.TextXAlignment.Left
imSub.Text = "Paste exported JSON workflow data below and click Import"
imSub.ZIndex = 301
imSub.Parent = ImportModal

local ImportTextBox = Instance.new("TextBox")
ImportTextBox.Name = "ImportTextBox"
ImportTextBox.Size = UDim2.new(1, -32, 0, 180)
ImportTextBox.Position = UDim2.new(0, 16, 0, 56)
ImportTextBox.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
ImportTextBox.BorderSizePixel = 0
ImportTextBox.Font = Enum.Font.Code
ImportTextBox.TextSize = 10
ImportTextBox.TextColor3 = Color3.fromRGB(240, 245, 255)
ImportTextBox.PlaceholderText = '{\n  "name": "My Shared Task",\n  "trigger": { "type": "Timer", "interval": 10 },\n  "actions": [...]\n}'
ImportTextBox.PlaceholderColor3 = Color3.fromRGB(100, 115, 135)
ImportTextBox.TextXAlignment = Enum.TextXAlignment.Left
ImportTextBox.TextYAlignment = Enum.TextYAlignment.Top
ImportTextBox.ClearTextOnFocus = false
ImportTextBox.MultiLine = true
ImportTextBox.TextWrapped = true
ImportTextBox.Text = ""
ImportTextBox.ZIndex = 301
ImportTextBox.Parent = ImportModal

local itbCorn = Instance.new("UICorner")
itbCorn.CornerRadius = UDim.new(0, 4)
itbCorn.Parent = ImportTextBox

local itbPad = Instance.new("UIPadding")
itbPad.PaddingLeft = UDim.new(0, 8)
itbPad.PaddingRight = UDim.new(0, 8)
itbPad.PaddingTop = UDim.new(0, 6)
itbPad.Parent = ImportTextBox

local CancelImportBtn = Instance.new("TextButton")
CancelImportBtn.Name = "CancelImportBtn"
CancelImportBtn.Size = UDim2.new(0, 80, 0, 30)
CancelImportBtn.Position = UDim2.new(1, -220, 0, 254)
CancelImportBtn.BackgroundColor3 = Color3.fromRGB(30, 35, 48)
CancelImportBtn.BorderSizePixel = 0
CancelImportBtn.Font = Enum.Font.GothamBold
CancelImportBtn.TextSize = 11
CancelImportBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
CancelImportBtn.Text = "Cancel"
CancelImportBtn.ZIndex = 301
CancelImportBtn.Parent = ImportModal
local cibCorn = Instance.new("UICorner")
cibCorn.CornerRadius = UDim.new(0, 4)
cibCorn.Parent = CancelImportBtn

local DoImportBtn = Instance.new("TextButton")
DoImportBtn.Name = "DoImportBtn"
DoImportBtn.Size = UDim2.new(0, 120, 0, 30)
DoImportBtn.Position = UDim2.new(1, -132, 0, 254)
DoImportBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 90)
DoImportBtn.BorderSizePixel = 0
DoImportBtn.Font = Enum.Font.GothamBold
DoImportBtn.TextSize = 11
DoImportBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
DoImportBtn.Text = "Import Workflow"
DoImportBtn.ZIndex = 301
DoImportBtn.Parent = ImportModal
local dibCorn = Instance.new("UICorner")
dibCorn.CornerRadius = UDim.new(0, 4)
dibCorn.Parent = DoImportBtn

CancelImportBtn.MouseButton1Click:Connect(function()
    ImportModal.Visible = false
end)

ImportBtn.MouseButton1Click:Connect(function()
    ImportTextBox.Text = ""
    ImportModal.Visible = true
end)

DoImportBtn.MouseButton1Click:Connect(function()
    local raw = ImportTextBox.Text
    if raw == "" then
        if showToastNotification then
            showToastNotification("Import Error", "Please paste valid JSON text first", 3.0)
        end
        return
    end

    local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(decoded) ~= "table" then
        if showToastNotification then
            showToastNotification("Import Error", "Malformed JSON syntax", 3.0)
        end
        return
    end

    local importedCount = 0
    local placeIdStr = tostring(game.PlaceId or "0")

    local function importSingleTask(taskData)
        if type(taskData) ~= "table" or not taskData.name then return false end
        local newId = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
        local cloned = {
            id = newId,
            name = tostring(taskData.name or "Imported Task"),
            description = tostring(taskData.description or "Imported workflow"),
            enabled = (taskData.enabled ~= false),
            scope = (taskData.scope == "universal") and "universal" or "place",
            trigger = type(taskData.trigger) == "table" and taskData.trigger or { type = "Timer", interval = 60 },
            condition = type(taskData.condition) == "table" and taskData.condition or { type = "Always" },
            actions = type(taskData.actions) == "table" and taskData.actions or {},
            telemetry = { invocations = 0, lastRun = 0, lastResult = "Imported" }
        }

        if cloned.scope == "universal" then
            Storage.data.universal = Storage.data.universal or {}
            table.insert(Storage.data.universal, cloned)
        else
            Storage.data.places[placeIdStr] = Storage.data.places[placeIdStr] or {}
            table.insert(Storage.data.places[placeIdStr], cloned)
        end

        if cloned.enabled then
            Engine.bindTask(cloned)
        end
        return true
    end

    if decoded.name and (decoded.trigger or decoded.actions) then
        if importSingleTask(decoded) then importedCount = 1 end
    elseif #decoded > 0 then
        for _, t in ipairs(decoded) do
            if importSingleTask(t) then importedCount = importedCount + 1 end
        end
    elseif decoded.universal or decoded.places then
        for _, t in ipairs(decoded.universal or {}) do
            if importSingleTask(t) then importedCount = importedCount + 1 end
        end
        for _, placeTasks in pairs(decoded.places or {}) do
            for _, t in ipairs(placeTasks) do
                if importSingleTask(t) then importedCount = importedCount + 1 end
            end
        end
    end

    if importedCount > 0 then
        Storage.save(true)
        refreshCardList()
        ImportModal.Visible = false
        ImportTextBox.Text = ""
        if showToastNotification then
            showToastNotification("Import Successful", string.format("Imported %d workflow(s)", importedCount), 3.5)
        end
    else
        if showToastNotification then
            showToastNotification("Import Failed", "No valid task definitions found in JSON", 3.0)
        end
    end
end)

-- ==============================================================================
-- 5. HOTKEY & GLOBAL EXPORTS
-- ==============================================================================
local function toggleSchedulerHUD()
    ScreenGui.Enabled = not ScreenGui.Enabled
    if ScreenGui.Enabled then
        refreshCardList()
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
    end
end

local keybindConnection
keybindConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- Do not check gameProcessed: Shift and Function keys are often marked gameProcessed by Roblox CoreGui/ShiftLock
    if input.KeyCode == Enum.KeyCode.F7 then
        local isShiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
        if isShiftHeld then
            toggleSchedulerHUD()
        end
    elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
        local isF7Held = UserInputService:IsKeyDown(Enum.KeyCode.F7)
        if isF7Held then
            toggleSchedulerHUD()
        end
    end
end)

getgenv().ToggleTaskScheduler = toggleSchedulerHUD
getgenv().GetScheduledTasks = function() return Storage.data end
getgenv().RegisterAutomationTask = function(taskDef)
    if not taskDef or not taskDef.name then return false end
    taskDef.id = taskDef.id or ("task_" .. tostring(os.time()) .. "_" .. tostring(math.random(100, 999)))
    taskDef.enabled = (taskDef.enabled ~= false)
    taskDef.scope = taskDef.scope or "place"
    if taskDef.scope == "universal" then
        Storage.data.universal = Storage.data.universal or {}
        table.insert(Storage.data.universal, taskDef)
    else
        local placeIdStr = tostring(game.PlaceId or "0")
        Storage.data.places[placeIdStr] = Storage.data.places[placeIdStr] or {}
        table.insert(Storage.data.places[placeIdStr], taskDef)
    end
    Engine.bindTask(taskDef)
    Storage.save(true)
    return true, taskDef.id
end
getgenv().UnloadAllScheduledTasks = function()
    for id in pairs(Engine.activeTasks) do
        Engine.unbindTask(id)
    end
    Engine.activeTasks = {}
end

getgenv()._KernelTaskSchedulerCleanUp = function()
    if keybindConnection then
        pcall(function() keybindConnection:Disconnect() end)
        keybindConnection = nil
    end
    getgenv().UnloadAllScheduledTasks()
    if ScreenGui then
        ScreenGui:Destroy()
    end
end

refreshCardList()
print("[AutomationScheduler]: Automation Scheduler engine loaded successfully! (Shift + F7 to open)")