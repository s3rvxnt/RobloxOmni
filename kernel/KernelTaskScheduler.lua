--[[
    Omni Kernel Task Scheduler (Apple Shortcuts Edition)
    Advanced Event-Driven Automation Dispatcher & Visual Shortcuts Pipeline Builder
    Author: Omni Development Team
    Design System: Apple Shortcuts (iOS / macOS Fluent Glass)
]]

-- Services
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait(0.1)
    LocalPlayer = Players.LocalPlayer
end

-- Clean up previous instance on reload
if getgenv()._KernelTaskSchedulerCleanUp then
    pcall(getgenv()._KernelTaskSchedulerCleanUp)
end

-- ==============================================================================
-- 0. THEME PALETTE & GLYPH SYSTEM (Apple Shortcuts)
-- ==============================================================================
local SHORTCUT_COLORS = {
    blue = {
        name = "Blue",
        bg = Color3.fromRGB(0, 115, 230),
        stroke = Color3.fromRGB(80, 170, 255),
        badge = Color3.fromRGB(0, 85, 175),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(215, 238, 255)
    },
    green = {
        name = "Green",
        bg = Color3.fromRGB(35, 155, 70),
        stroke = Color3.fromRGB(75, 215, 120),
        badge = Color3.fromRGB(25, 115, 50),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(210, 250, 225)
    },
    orange = {
        name = "Orange",
        bg = Color3.fromRGB(220, 105, 15),
        stroke = Color3.fromRGB(255, 155, 60),
        badge = Color3.fromRGB(165, 75, 10),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(255, 235, 210)
    },
    purple = {
        name = "Purple",
        bg = Color3.fromRGB(135, 55, 190),
        stroke = Color3.fromRGB(190, 110, 255),
        badge = Color3.fromRGB(95, 35, 140),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(240, 215, 255)
    },
    red = {
        name = "Red",
        bg = Color3.fromRGB(200, 40, 65),
        stroke = Color3.fromRGB(255, 90, 120),
        badge = Color3.fromRGB(145, 25, 45),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(255, 215, 225)
    },
    teal = {
        name = "Teal",
        bg = Color3.fromRGB(25, 140, 160),
        stroke = Color3.fromRGB(65, 200, 225),
        badge = Color3.fromRGB(18, 100, 115),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(215, 250, 255)
    },
    amber = {
        name = "Amber",
        bg = Color3.fromRGB(195, 130, 15),
        stroke = Color3.fromRGB(255, 185, 50),
        badge = Color3.fromRGB(140, 92, 10),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(255, 245, 210)
    },
    indigo = {
        name = "Indigo",
        bg = Color3.fromRGB(75, 65, 185),
        stroke = Color3.fromRGB(130, 120, 250),
        badge = Color3.fromRGB(50, 42, 130),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(225, 220, 255)
    },
    cyan = {
        name = "Cyan",
        bg = Color3.fromRGB(0, 145, 175),
        stroke = Color3.fromRGB(50, 215, 245),
        badge = Color3.fromRGB(0, 105, 130),
        text = Color3.fromRGB(255, 255, 255),
        sub = Color3.fromRGB(215, 245, 255)
    }
}
local COLOR_ORDER = { "blue", "green", "orange", "purple", "red", "teal", "amber", "indigo", "cyan" }
local SHORTCUT_ICONS = { "⚡", "🚗", "🛡️", "💰", "⏱️", "📍", "🔄", "👻", "🚪", "💊", "🎯", "📡", "✨", "📋", "💃", "🎥" }

-- ==============================================================================
-- 1. PERSISTENCE ENGINE & DATA STORE
-- ==============================================================================
local Storage = {
    file = "TaskScheduler_Tasks.json",
    data = {
        version = 2,
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
    if type(pathStr) ~= "string" then return nil end

    local cur = game
    local cleaned = pathStr:gsub('%["([^"]+)"%]', ".%1"):gsub("%['([^']+)'%]", ".%1")
    for seg in string.gmatch(cleaned, "[^%.]+") do
        if cur == game and (seg == "game" or seg == "workspace" or seg == "Workspace") then
            if seg == "workspace" or seg == "Workspace" then cur = workspace end
        else
            cur = cur:FindFirstChild(seg)
        end
        if not cur then break end
    end
    if cur and typeof(cur) == "Instance" then return cur end

    local wsInst = workspace:FindFirstChild(tostring(pathStr)) or workspace:FindFirstChild(tostring(pathStr), true)
    if wsInst and typeof(wsInst) == "Instance" then return wsInst end

    return nil
end

local function resolveSignal(pathStr, signalName)
    if not pathStr or pathStr == "" then return nil end
    if typeof(pathStr) == "RBXScriptSignal" then return pathStr end

    if signalName and signalName ~= "" then
        local inst = resolveInstance(pathStr)
        if inst and typeof(inst) == "Instance" then
            local ok, sig = pcall(function() return inst[signalName] end)
            if ok and typeof(sig) == "RBXScriptSignal" then
                return sig
            end
        end
    end

    local instPath, sigMember = tostring(pathStr):match("^(.*)%.([^%.]+)$")
    if instPath and sigMember then
        local inst = resolveInstance(instPath)
        if inst and typeof(inst) == "Instance" then
            local ok, sig = pcall(function() return inst[sigMember] end)
            if ok and typeof(sig) == "RBXScriptSignal" then
                return sig
            end
        end
    end

    local inst = resolveInstance(pathStr)
    if inst and typeof(inst) == "Instance" and signalName then
        local ok, sig = pcall(function() return inst[signalName] end)
        if ok and typeof(sig) == "RBXScriptSignal" then
            return sig
        end
    end

    return nil
end

local evalValue -- Forward declaration

local function resolveCFrame(target)
    if not target then return nil end
    if typeof(target) == "CFrame" then return target end
    if typeof(target) == "Vector3" then return CFrame.new(target) end
    if typeof(target) == "Instance" then
        if target:IsA("Player") and target.Character then
            local hrp = target.Character:FindFirstChild("HumanoidRootPart")
            return hrp and hrp.CFrame or target.Character:GetPivot()
        elseif target:IsA("Model") then
            local hrp = target:FindFirstChild("HumanoidRootPart")
            return hrp and hrp.CFrame or target:GetPivot()
        elseif target:IsA("BasePart") then
            return target.CFrame
        elseif target:IsA("Attachment") then
            return target.WorldCFrame
        end
    end
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

local function substituteArg(arg, ctx)
    if type(arg) == "string" then
        return evalValue(arg, ctx)
    end
    return arg
end

local function evalValue(expr, ctx)
    if type(expr) ~= "string" then return expr end
    if expr == "" then return "" end

    ctx = ctx or { vars = {}, inputs = {} }
    ctx.vars = ctx.vars or {}

    local myChar = LocalPlayer.Character
    local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local myHum = myChar and myChar:FindFirstChildOfClass("Humanoid")

    -- 1. Direct standalone token matches (preserves object reference)
    if expr == "$input" or expr == "$1" or expr == "$arg1" then
        return ctx.input
    elseif expr == "$inputs" then
        return ctx.inputs
    elseif expr == "$player" or expr == "$localplayer" or expr == "$username" or expr == "$name" then
        return LocalPlayer.Name
    elseif expr == "$character" or expr == "$char" then
        return myChar
    elseif expr == "$userId" or expr == "$userid" then
        return LocalPlayer.UserId
    elseif expr == "$placeId" or expr == "$placeid" then
        return game.PlaceId
    elseif expr == "$jobId" or expr == "$jobid" then
        return game.JobId
    elseif expr == "$position" or expr == "$pos" then
        return myHrp and myHrp.Position or Vector3.zero
    elseif expr == "$cframe" then
        return myHrp and myHrp.CFrame or CFrame.identity
    elseif expr == "$health" or expr == "$hp" then
        return myHum and myHum.Health or 100
    elseif expr == "$maxHealth" or expr == "$maxHp" then
        return myHum and myHum.MaxHealth or 100
    elseif expr:find("^%$leaderstat:") then
        local statName = expr:match("^%$leaderstat:([%w_]+)$")
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local st = ls and ls:FindFirstChild(statName)
        return st and st.Value or 0
    end

    -- 2. Direct variable match: "$Owner"
    local singleVar = expr:match("^%$([%w_]+)$")
    if singleVar and ctx.vars[singleVar] ~= nil then
        return ctx.vars[singleVar]
    end

    -- 3. Direct property match: "$input.Name", "$position.X", "$character.HumanoidRootPart", "$Car.Position"
    local objVar, prop = expr:match("^%$([%w_]+)%.([%w_]+)$")
    if objVar and prop then
        local obj = nil
        if objVar == "input" then
            obj = ctx.input
        elseif objVar == "character" or objVar == "char" then
            obj = myChar
        elseif objVar == "position" or objVar == "pos" then
            obj = myHrp and myHrp.Position or Vector3.zero
        elseif objVar == "cframe" then
            obj = myHrp and myHrp.CFrame or CFrame.identity
        elseif objVar == "player" then
            obj = LocalPlayer
        elseif ctx.vars[objVar] ~= nil then
            obj = ctx.vars[objVar]
        elseif getgenv()[objVar] ~= nil then
            obj = getgenv()[objVar]
        end

        if obj ~= nil then
            if typeof(obj) == "Instance" then
                local ok, val = pcall(function() return obj[prop] end)
                if ok and val ~= nil then return val end
            elseif typeof(obj) == "Vector3" or typeof(obj) == "CFrame" or type(obj) == "table" then
                local ok, val = pcall(function() return obj[prop] end)
                if ok and val ~= nil then return val end
            end
        end
    end

    -- 4. Check if it's a code expression (arithmetic/logic)
    local isCodeExpr = (expr:find("%(") and expr:find("%)")) or expr:find("[%+%-%*/%%]") or expr:find("[><=]=")
    if isCodeExpr and not expr:find("^https?://") then
        local SAFE_EVAL_GLOBALS = {
            string = string,
            math = math,
            table = table,
            tostring = tostring,
            tonumber = tonumber,
            print = print,
            warn = warn,
            typeof = typeof,
            type = type,
            Vector3 = Vector3,
            Vector2 = Vector2,
            CFrame = CFrame,
            Color3 = Color3,
            UDim = UDim,
            UDim2 = UDim2,
            Ray = Ray,
            Region3 = Region3,
            NumberRange = NumberRange,
            Rect = Rect,
            BrickColor = BrickColor,
            Enum = Enum,
            tick = tick,
            time = time,
            pairs = pairs,
            ipairs = ipairs,
            next = next,
            select = select,
            pcall = pcall,
            xpcall = xpcall,
            assert = assert,
        }

        local codeExpr = expr:gsub("%$([%w_]+)", "%1")
        local env = setmetatable({
            input = ctx.input,
            inputs = ctx.inputs,
            workspace = workspace,
            Workspace = workspace,
            game = game,
            Players = Players,
            LocalPlayer = LocalPlayer,
            position = myHrp and myHrp.Position or Vector3.zero,
            pos = myHrp and myHrp.Position or Vector3.zero,
            cframe = myHrp and myHrp.CFrame or CFrame.identity,
            character = myChar,
            char = myChar,
            health = myHum and myHum.Health or 100,
            userId = LocalPlayer.UserId,
            placeId = game.PlaceId,
        }, {
            __index = function(_, k)
                if ctx.vars and ctx.vars[k] ~= nil then return ctx.vars[k] end
                return SAFE_EVAL_GLOBALS[k]
            end,
            __newindex = function(_, k, v)
                if ctx.vars then ctx.vars[k] = v end
            end
        })

        local fn = loadstring("return " .. codeExpr)
        if fn then
            setfenv(fn, env)
            local ok, res = pcall(fn)
            if ok and res ~= nil then
                return res
            end
        end
    end

    -- 5. Fallback: String template interpolation (e.g. "Player $player at $position in Place $placeId")
    -- First expand leaderstats: $leaderstat:Cash
    local substituted = expr:gsub("%$leaderstat:([%w_]+)", function(statName)
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local st = ls and ls:FindFirstChild(statName)
        return tostring(st and st.Value or 0)
    end)

    -- Next expand standard $var or $var.property
    substituted = substituted:gsub("%$([%w_]+)%.?([%w_]*)", function(varName, propName)
        local val = nil
        if varName == "input" then
            val = ctx.input
        elseif varName == "player" or varName == "username" or varName == "name" then
            val = LocalPlayer.Name
        elseif varName == "userId" or varName == "userid" then
            val = tostring(LocalPlayer.UserId)
        elseif varName == "placeId" or varName == "placeid" then
            val = tostring(game.PlaceId)
        elseif varName == "jobId" or varName == "jobid" then
            val = tostring(game.JobId)
        elseif varName == "position" or varName == "pos" then
            val = myHrp and string.format("%.1f, %.1f, %.1f", myHrp.Position.X, myHrp.Position.Y, myHrp.Position.Z) or "0, 0, 0"
        elseif varName == "cframe" then
            val = myHrp and tostring(myHrp.CFrame) or "0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1"
        elseif varName == "character" or varName == "char" then
            val = myChar
        elseif varName == "health" or varName == "hp" then
            val = myHum and tostring(math.floor(myHum.Health)) or "0"
        elseif varName == "maxHealth" or varName == "maxHp" then
            val = myHum and tostring(math.floor(myHum.MaxHealth)) or "100"
        elseif ctx.vars[varName] ~= nil then
            val = ctx.vars[varName]
        elseif getgenv()[varName] ~= nil then
            val = getgenv()[varName]
        end

        if val ~= nil then
            if propName and propName ~= "" then
                if typeof(val) == "Instance" then
                    local ok, pVal = pcall(function() return val[propName] end)
                    if ok and pVal ~= nil then return tostring(pVal) end
                elseif typeof(val) == "Vector3" or typeof(val) == "CFrame" or type(val) == "table" then
                    local ok, pVal = pcall(function() return val[propName] end)
                    if ok and pVal ~= nil then return tostring(pVal) end
                end
            end
            if typeof(val) == "Instance" then
                return val.Name
            elseif typeof(val) == "Vector3" then
                return string.format("%.1f, %.1f, %.1f", val.X, val.Y, val.Z)
            end
            return tostring(val)
        end
        return "$" .. varName .. (propName ~= "" and ("." .. propName) or "")
    end)

    return substituted
end

local executeSingleAction -- forward declaration

local function evaluateIfCondition(act, ctx)
    local left = evalValue(act.left or "", ctx)
    local right = evalValue(act.right or "", ctx)
    local op = act.op or "=="

    local nLeft, nRight = tonumber(left), tonumber(right)
    if nLeft and nRight then
        left, right = nLeft, nRight
    end

    if op == "==" then return left == right
    elseif op == "!=" then return left ~= right
    elseif op == ">" then return left > right
    elseif op == "<" then return left < right
    elseif op == ">=" then return left >= right
    elseif op == "<=" then return left <= right
    elseif op == "contains" then
        return tostring(left):find(tostring(right), 1, true) ~= nil
    end
    return false
end

local function executeBlock(actionList, ctx)
    local i = 1
    local maxSteps = 5000
    local stepCount = 0

    while i <= #actionList and stepCount < maxSteps do
        stepCount = stepCount + 1
        local act = actionList[i]
        local actType = act.type

        if actType == "SetVariable" then
            local vName = act.varName or "var"
            local vVal = evalValue(act.value, ctx)
            ctx.vars[vName] = vVal
            i = i + 1
        elseif actType == "Wait" or actType == "Delay" then
            local dur = tonumber(evalValue(act.duration, ctx)) or 1.0
            task.wait(math.max(0.01, dur))
            i = i + 1
        elseif actType == "Print" then
            local msg = evalValue(act.message or "", ctx)
            print("[Shortcut]: " .. tostring(msg))
            i = i + 1
        elseif actType == "Toast" then
            if showToastNotification then
                local tTitle = tostring(evalValue(act.title or "Shortcut Alert", ctx))
                local tMsg = tostring(evalValue(act.message or "Triggered", ctx))
                showToastNotification(tTitle, tMsg, 3.5)
            end
            i = i + 1
        elseif actType == "Repeat" then
            local count = tonumber(evalValue(act.count, ctx)) or 1
            count = math.clamp(count, 1, 500)
            local depth = 1
            local j = i + 1
            while j <= #actionList do
                if actionList[j].type == "Repeat" or actionList[j].type == "ForEach" or actionList[j].type == "If" then
                    depth = depth + 1
                elseif actionList[j].type == "EndBlock" or actionList[j].type == "EndRepeat" or actionList[j].type == "EndIf" then
                    depth = depth - 1
                    if depth == 0 then break end
                end
                j = j + 1
            end
            local subActions = {}
            for k = i + 1, j - 1 do table.insert(subActions, actionList[k]) end
            for iter = 1, count do
                ctx.vars["index"] = iter
                ctx.vars["repeatIndex"] = iter
                executeBlock(subActions, ctx)
            end
            i = j + 1
        elseif actType == "ForEach" then
            local targetObj = evalValue(act.target or "", ctx)
            local items = {}
            if typeof(targetObj) == "Instance" then
                items = targetObj:GetChildren()
            elseif type(targetObj) == "string" then
                local inst = resolveInstance(targetObj)
                if inst then items = inst:GetChildren() end
            elseif type(targetObj) == "table" then
                items = targetObj
            end
            local depth = 1
            local j = i + 1
            while j <= #actionList do
                if actionList[j].type == "Repeat" or actionList[j].type == "ForEach" or actionList[j].type == "If" then
                    depth = depth + 1
                elseif actionList[j].type == "EndBlock" or actionList[j].type == "EndRepeat" or actionList[j].type == "EndIf" then
                    depth = depth - 1
                    if depth == 0 then break end
                end
                j = j + 1
            end
            local subActions = {}
            for k = i + 1, j - 1 do table.insert(subActions, actionList[k]) end
            local varName = (act.varName and act.varName ~= "") and act.varName or "item"
            for idx, item in ipairs(items) do
                ctx.vars[varName] = item
                ctx.vars["item"] = item
                ctx.vars["index"] = idx
                executeBlock(subActions, ctx)
            end
            i = j + 1
        elseif actType == "If" then
            local condPass = evaluateIfCondition(act, ctx)
            local depth = 1
            local j = i + 1
            while j <= #actionList do
                if actionList[j].type == "Repeat" or actionList[j].type == "ForEach" or actionList[j].type == "If" then
                    depth = depth + 1
                elseif actionList[j].type == "EndBlock" or actionList[j].type == "EndRepeat" or actionList[j].type == "EndIf" then
                    depth = depth - 1
                    if depth == 0 then break end
                end
                j = j + 1
            end
            if condPass then
                local subActions = {}
                for k = i + 1, j - 1 do table.insert(subActions, actionList[k]) end
                executeBlock(subActions, ctx)
            end
            i = j + 1
        elseif actType == "EndBlock" or actType == "EndRepeat" or actType == "EndIf" then
            i = i + 1
        else
            executeSingleAction(act, ctx)
            i = i + 1
        end
    end
end

executeSingleAction = function(act, ctx)
    local ok, err = pcall(function()
        if act.type == "PauseAllLoops" then
            if getgenv().PauseAllLoops then getgenv().PauseAllLoops(true) end
        elseif act.type == "ResumeAllLoops" then
            if getgenv().ResumeAllLoops then getgenv().ResumeAllLoops() end
        elseif act.type == "SetTaskPriority" then
            if getgenv().SetSchedulerTaskPriority and act.target then
                getgenv().SetSchedulerTaskPriority(act.target, tonumber(evalValue(act.priority, ctx)) or 80)
            end
        elseif act.type == "SetTaskHz" then
            if getgenv().SetSchedulerTaskHz and act.target then
                getgenv().SetSchedulerTaskHz(act.target, tonumber(evalValue(act.hz, ctx)) or 60)
            end
        elseif act.type == "RunLuau" then
            if act.code and act.code ~= "" then
                local env = setmetatable({
                    input = ctx.input,
                    inputs = ctx.inputs,
                    vars = ctx.vars,
                    workspace = workspace,
                    game = game,
                    Players = Players,
                    LocalPlayer = LocalPlayer,
                }, {
                    __index = function(_, k) return ctx.vars[k] or getgenv()[k] end,
                    __newindex = function(_, k, v)
                        ctx.vars[k] = v
                        pcall(function() getgenv()[k] = v end)
                    end,
                })
                local fn, compileErr = loadstring(act.code)
                if fn then
                    setfenv(fn, env)
                    if act.async == true then
                        task.spawn(fn, ctx.input, ctx.vars)
                    else
                        local ok, err = pcall(fn, ctx.input, ctx.vars)
                        if not ok then warn("[TaskScheduler] Luau runtime error:", err) end
                    end
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
            local kcName = tostring(evalValue(act.key or "E", ctx))
            local kc = Enum.KeyCode[kcName]
            if VIM and kc then
                VIM:SendKeyEvent(true, kc, false, game)
                task.wait(math.max(0.05, tonumber(evalValue(act.duration, ctx)) or 0.1))
                VIM:SendKeyEvent(false, kc, false, game)
            end
        elseif act.type == "FollowRoute" then
            local targetNode = tostring(evalValue(act.targetNode or act.node or "Yard", ctx))
            local routeFile = tostring(evalValue(act.route or act.fileName or "road_network.json", ctx))
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
            if _G.StopBot then _G.StopBot() end
        elseif act.type == "TweenTo" then
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp and act.target then
                local rawTarget = evalValue(act.target, ctx)
                local targetCF = resolveCFrame(rawTarget)
                if targetCF then
                    local dist = (hrp.Position - targetCF.Position).Magnitude
                    local dur = tonumber(evalValue(act.duration, ctx))
                    if not dur or dur <= 0 then
                        local spd = tonumber(evalValue(act.speed, ctx)) or 50
                        dur = dist / spd
                    end
                    dur = math.clamp(dur, 0.05, 120)
                    local ti = TweenInfo.new(dur, Enum.EasingStyle.Linear)
                    local tw = TweenService:Create(hrp, ti, { CFrame = targetCF })
                    tw:Play()
                    if act.wait ~= false then tw.Completed:Wait() end
                end
            end
        elseif act.type == "InstantTeleport" then
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if char and hrp and act.target then
                local rawTarget = evalValue(act.target, ctx)
                local targetCF = resolveCFrame(rawTarget)
                if targetCF then
                    char:PivotTo(targetCF)
                    pcall(function()
                        hrp.AssemblyLinearVelocity = Vector3.zero
                        hrp.AssemblyAngularVelocity = Vector3.zero
                    end)
                end
            end
        elseif act.type == "FindNearest" then
            local myChar = LocalPlayer.Character
            local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
            if myHrp then
                local maxDist = tonumber(evalValue(act.maxDistance, ctx)) or math.huge
                local sourceVal = evalValue(act.source or "Players", ctx)
                local varName = (act.varName and act.varName ~= "") and act.varName or "nearest"
                local nameFilter = tostring(evalValue(act.filter or act.nameFilter or "", ctx)):lower()
                local candidates = {}
                if tostring(sourceVal):lower() == "players" or sourceVal == Players then
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                            if nameFilter == "" or p.Name:lower():find(nameFilter, 1, true) or p.DisplayName:lower():find(nameFilter, 1, true) then
                                table.insert(candidates, { obj = p, pos = p.Character.HumanoidRootPart.Position })
                            end
                        end
                    end
                else
                    local parentObj = typeof(sourceVal) == "Instance" and sourceVal or resolveInstance(sourceVal)
                    if not parentObj and type(sourceVal) == "string" and sourceVal ~= "" then
                        parentObj = workspace:FindFirstChild(sourceVal, true)
                    end
                    if parentObj then
                        for _, ch in ipairs(parentObj:GetChildren()) do
                            local matchesFilter = (nameFilter == "") or ch.Name:lower():find(nameFilter, 1, true)
                            if matchesFilter then
                                if ch:IsA("BasePart") then
                                    table.insert(candidates, { obj = ch, pos = ch.Position })
                                elseif ch:IsA("Model") then
                                    local piv = ch:GetPivot()
                                    table.insert(candidates, { obj = ch, pos = piv.Position })
                                end
                            end
                        end
                    end
                end
                local closestObj = nil
                local closestPos = nil
                local bestDist = maxDist
                for _, cand in ipairs(candidates) do
                    local d = (myHrp.Position - cand.pos).Magnitude
                    if d < bestDist then
                        bestDist = d
                        closestObj = cand.obj
                        closestPos = cand.pos
                    end
                end
                ctx.vars[varName] = closestObj
                ctx.vars["nearest"] = closestObj
                ctx.vars["nearestDistance"] = (closestObj and bestDist or nil)
                ctx.vars["nearestPosition"] = closestPos
                ctx.vars[varName .. "Position"] = closestPos
                ctx.vars["nearestFound"] = (closestObj ~= nil)
            end
        elseif act.type == "PathfindTo" then
            local myChar = LocalPlayer.Character
            local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
            local hum = myChar and myChar:FindFirstChildOfClass("Humanoid")
            if myChar and myHrp and hum and act.target then
                local rawTarget = evalValue(act.target, ctx)
                local targetCF = resolveCFrame(rawTarget)
                if targetCF then
                    local targetPos = targetCF.Position
                    local stopDist = tonumber(evalValue(act.stopDistance, ctx)) or 4
                    local timeout = tonumber(evalValue(act.timeout, ctx)) or 30
                    local PathfindingService = game:GetService("PathfindingService")
                    local path = PathfindingService:CreatePath({
                        AgentRadius = 2,
                        AgentHeight = 5,
                        AgentCanJump = true
                    })
                    local compOk = pcall(function() path:ComputeAsync(myHrp.Position, targetPos) end)
                    if compOk and path.Status == Enum.PathStatus.Success then
                        local startTime = tick()
                        for _, wp in ipairs(path:GetWaypoints()) do
                            if (tick() - startTime) > timeout then break end
                            if not (myChar and myChar.Parent and hum.Health > 0) then break end
                            if (myHrp.Position - targetPos).Magnitude <= stopDist then break end
                            if wp.Action == Enum.PathWaypointAction.Jump then
                                hum.Jump = true
                            end
                            hum:MoveTo(wp.Position)
                            hum.MoveToFinished:Wait()
                        end
                    else
                        hum:MoveTo(targetPos)
                        local startTime = tick()
                        while myChar and myChar.Parent and hum.Health > 0 and (myHrp.Position - targetPos).Magnitude > stopDist and (tick() - startTime) < timeout do
                            task.wait(0.1)
                        end
                    end
                end
            end
        elseif act.type == "ResetCharacter" then
            local myChar = LocalPlayer.Character
            if myChar then
                local hum = myChar:FindFirstChildOfClass("Humanoid")
                if hum then
                    hum.Health = 0
                else
                    myChar:BreakJoints()
                end
            end
        elseif act.type == "EquipTool" then
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
            if hum and bp then
                local tName = tostring(evalValue(act.toolName or act.name or "", ctx)):lower()
                for _, item in ipairs(bp:GetChildren()) do
                    if item:IsA("Tool") then
                        if tName == "" or tName == "first" or item.Name:lower():find(tName, 1, true) then
                            hum:EquipTool(item)
                            break
                        end
                    end
                end
            end
        elseif act.type == "UseTool" then
            local char = LocalPlayer.Character
            local subAct = tostring(evalValue(act.action or "activate", ctx)):lower()
            if subAct == "unequip" then
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if hum then hum:UnequipTools() end
            else
                local tool = char and char:FindFirstChildOfClass("Tool")
                if tool then
                    tool:Activate()
                end
            end
        elseif act.type == "ClickGuiButton" then
            local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            if pg then
                local targetQuery = tostring(evalValue(act.target or "", ctx)):lower()
                local foundBtn = nil
                local directInst = resolveInstance(targetQuery)
                if directInst and directInst:IsA("GuiButton") then
                    foundBtn = directInst
                else
                    for _, desc in ipairs(pg:GetDescendants()) do
                        if desc:IsA("GuiButton") and desc.Visible then
                            if desc.Name:lower() == targetQuery
                               or (desc:IsA("TextButton") and desc.Text:lower():find(targetQuery, 1, true))
                               or desc.Name:lower():find(targetQuery, 1, true) then
                                foundBtn = desc
                                break
                            end
                        end
                    end
                end
                if foundBtn then
                    pcall(function()
                        if firesignal then
                            firesignal(foundBtn.MouseButton1Click)
                            firesignal(foundBtn.Activated)
                        else
                            foundBtn.MouseButton1Click:Fire()
                        end
                    end)
                else
                    warn("[TaskScheduler] ClickGuiButton: Button not found matching:", targetQuery)
                end
            end
        elseif act.type == "SendChat" then
            local msg = evalValue(act.message or "", ctx)
            if msg and msg ~= "" then
                local sent = false
                local ok, res = pcall(function()
                    local TCS = game:GetService("TextChatService")
                    if TCS and TCS.ChatVersion == Enum.ChatVersion.TextChatService then
                        local genChan = TCS.TextChannels:FindFirstChild("RBXGeneral")
                        if genChan then
                            genChan:SendAsync(tostring(msg))
                            return true
                        end
                    end
                    return false
                end)
                if ok and res == true then
                    sent = true
                end
                if not sent then
                    pcall(function()
                        local SayMsg = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
                        local SayReq = SayMsg and SayMsg:FindFirstChild("SayMessageRequest")
                        if SayReq then
                            SayReq:FireServer(tostring(msg), "All")
                            sent = true
                        end
                    end)
                end
            end
        elseif act.type == "SetCharacterState" then
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local prop = tostring(evalValue(act.property or "WalkSpeed", ctx)):lower()
            local val = evalValue(act.value, ctx)
            if hum then
                if prop == "walkspeed" or prop == "speed" then
                    hum.WalkSpeed = tonumber(val) or 16
                elseif prop == "jumppower" or prop == "jump" then
                    hum.UseJumpPower = true
                    hum.JumpPower = tonumber(val) or 50
                elseif prop == "jumpheight" then
                    hum.UseJumpPower = false
                    hum.JumpHeight = tonumber(val) or 7.2
                elseif prop == "hipheight" then
                    hum.HipHeight = tonumber(val) or 2.0
                elseif prop == "sit" then
                    hum.Sit = (tostring(val):lower() == "true" or val == true or val == 1 or val == "1")
                elseif prop == "gravity" then
                    workspace.Gravity = tonumber(val) or 196.2
                elseif prop == "fov" then
                    local cam = workspace.CurrentCamera
                    if cam then cam.FieldOfView = tonumber(val) or 70 end
                elseif prop == "health" then
                    hum.Health = tonumber(val) or hum.Health
                elseif prop == "noclip" then
                    local enableNoclip = (tostring(val):lower() == "true" or val == true or val == 1 or val == "1")
                    if enableNoclip then
                        if not getgenv()._OmniNoclipConn then
                            getgenv()._OmniNoclipConn = RunService.Stepped:Connect(function()
                                local c = LocalPlayer.Character
                                if c then
                                    for _, part in ipairs(c:GetDescendants()) do
                                        if part:IsA("BasePart") and part.CanCollide then
                                            part.CanCollide = false
                                        end
                                    end
                                end
                            end)
                        end
                    else
                        if getgenv()._OmniNoclipConn then
                            pcall(function() getgenv()._OmniNoclipConn:Disconnect() end)
                            getgenv()._OmniNoclipConn = nil
                        end
                        for _, part in ipairs(char:GetDescendants()) do
                            if part:IsA("BasePart") then
                                part.CanCollide = true
                            end
                        end
                    end
                end
            end
        elseif act.type == "LookAt" then
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp and act.target then
                local rawTarget = evalValue(act.target, ctx)
                local targetCF = resolveCFrame(rawTarget)
                if targetCF then
                    local targetPos = targetCF.Position
                    local myPos = hrp.Position
                    local flatTarget = Vector3.new(targetPos.X, myPos.Y, targetPos.Z)
                    if (flatTarget - myPos).Magnitude > 0.1 then
                        hrp.CFrame = CFrame.lookAt(myPos, flatTarget)
                    end
                end
            end
        elseif act.type == "PlaySound" then
            local sPreset = tostring(evalValue(act.sound or act.soundId or "Ping", ctx)):lower()
            local soundMap = {
                ping = "rbxassetid://4590662766",
                success = "rbxassetid://6026987820",
                alert = "rbxassetid://6026987850",
                buzzer = "rbxassetid://3761307659",
                chime = "rbxassetid://138090596"
            }
            local sId = soundMap[sPreset] or (sPreset:find("^rbxassetid://") and sPreset or ("rbxassetid://" .. sPreset))
            local snd = Instance.new("Sound")
            snd.SoundId = sId
            snd.Volume = tonumber(evalValue(act.volume, ctx)) or 1.0
            snd.Parent = game:GetService("SoundService")
            snd:Play()
            game:GetService("Debris"):AddItem(snd, 5)
        elseif act.type == "HighlightInstance" then
            local rawTarget = evalValue(act.target or "$nearest", ctx)
            local colStr = tostring(evalValue(act.color or "cyan", ctx)):lower()
            local dur = tonumber(evalValue(act.duration, ctx)) or 0
            local subAct = tostring(evalValue(act.action or "highlight", ctx)):lower()

            if not getgenv()._OmniHighlights then getgenv()._OmniHighlights = {} end

            if rawTarget == "clear" or subAct == "clear" then
                for _, hl in pairs(getgenv()._OmniHighlights) do
                    pcall(function() hl:Destroy() end)
                end
                getgenv()._OmniHighlights = {}
                for _, desc in ipairs(workspace:GetDescendants()) do
                    if desc:IsA("Highlight") and desc.Name == "OmniHighlight" then
                        pcall(function() desc:Destroy() end)
                    end
                end
            else
                local targetInst = nil
                if typeof(rawTarget) == "Instance" then
                    targetInst = rawTarget
                elseif type(rawTarget) == "string" then
                    local p = Players:FindFirstChild(rawTarget)
                    if p and p.Character then
                        targetInst = p.Character
                    else
                        targetInst = resolveInstance(rawTarget)
                    end
                end

                if targetInst and targetInst:IsA("Player") and targetInst.Character then
                    targetInst = targetInst.Character
                end

                -- If target is a part inside a character model, highlight the character model
                if targetInst and targetInst:IsA("BasePart") and targetInst.Parent and targetInst.Parent:FindFirstChildOfClass("Humanoid") then
                    targetInst = targetInst.Parent
                end

                if targetInst and (targetInst:IsA("Model") or targetInst:IsA("BasePart")) then
                    if subAct == "remove" or subAct == "disable" then
                        local existing = getgenv()._OmniHighlights[targetInst] or targetInst:FindFirstChild("OmniHighlight")
                        if existing then
                            pcall(function() existing:Destroy() end)
                            getgenv()._OmniHighlights[targetInst] = nil
                        end
                    else
                        local colorMap = {
                            cyan = Color3.fromRGB(0, 255, 255),
                            red = Color3.fromRGB(255, 60, 60),
                            green = Color3.fromRGB(60, 255, 100),
                            blue = Color3.fromRGB(60, 160, 255),
                            yellow = Color3.fromRGB(255, 230, 0),
                            gold = Color3.fromRGB(255, 200, 0),
                            purple = Color3.fromRGB(180, 80, 255),
                            magenta = Color3.fromRGB(255, 60, 220),
                            orange = Color3.fromRGB(255, 140, 0),
                            white = Color3.fromRGB(255, 255, 255),
                            pink = Color3.fromRGB(255, 105, 180),
                            lime = Color3.fromRGB(50, 255, 50),
                            teal = Color3.fromRGB(0, 200, 180),
                            amber = Color3.fromRGB(255, 180, 0),
                        }
                        local mainColor = colorMap[colStr]
                        if not mainColor then
                            local hex = colStr:match("#?([%da-fA-F]{6})")
                            if hex then
                                local r = tonumber(hex:sub(1, 2), 16)
                                local g = tonumber(hex:sub(3, 4), 16)
                                local b = tonumber(hex:sub(5, 6), 16)
                                mainColor = Color3.fromRGB(r, g, b)
                            else
                                local r, g, b = colStr:match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
                                if r and g and b then
                                    mainColor = Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
                                else
                                    mainColor = Color3.fromRGB(0, 255, 255)
                                end
                            end
                        end

                        local hl = getgenv()._OmniHighlights[targetInst] or targetInst:FindFirstChild("OmniHighlight")
                        if not hl then
                            hl = Instance.new("Highlight")
                            hl.Name = "OmniHighlight"
                        end
                        hl.Adornee = targetInst
                        hl.FillColor = mainColor
                        hl.FillTransparency = tonumber(evalValue(act.fillTransparency, ctx)) or 0.5
                        hl.OutlineColor = mainColor
                        hl.OutlineTransparency = tonumber(evalValue(act.outlineTransparency, ctx)) or 0
                        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        hl.Parent = targetInst
                        getgenv()._OmniHighlights[targetInst] = hl

                        local token = (hl:GetAttribute("OmniToken") or 0) + 1
                        hl:SetAttribute("OmniToken", token)

                        if dur > 0 then
                            task.delay(dur, function()
                                if hl and hl.Parent and hl:GetAttribute("OmniToken") == token then
                                    pcall(function() hl:Destroy() end)
                                    if getgenv()._OmniHighlights[targetInst] == hl then
                                        getgenv()._OmniHighlights[targetInst] = nil
                                    end
                                end
                            end)
                        end
                    end
                end
            end
        elseif act.type == "SendWebhook" then
            local url = tostring(evalValue(act.url or "", ctx))
            local msg = tostring(evalValue(act.message or act.content or "", ctx))
            local title = tostring(evalValue(act.title or "Omni Shortcuts Notification", ctx))

            if url and url ~= "" and msg and msg ~= "" then
                if url:find("YOUR_WEBHOOK_URL") or url:find("discord%.com/api/webhooks/%.%.%.") then
                    warn("[TaskScheduler] SendWebhook: Dummy webhook URL detected. Configure your Discord webhook in shortcut parameters.")
                else
                    local httpReq = request or http_request or (syn and syn.request) or (http and http.request)
                    if httpReq then
                        local isDiscord = url:find("discord%.com/api/webhooks") or url:find("discordapp%.com/api/webhooks")
                        local payloadData = {}
                        if isDiscord then
                            payloadData = {
                                content = msg,
                                embeds = {
                                    {
                                        title = title ~= "" and title or "Omni Notification",
                                        description = msg,
                                        color = 5814783,
                                        footer = { text = "Roblox Omni Scheduler • " .. LocalPlayer.Name },
                                        timestamp = DateTime.now():ToIsoDate()
                                    }
                                }
                            }
                        else
                            payloadData = {
                                title = title,
                                message = msg,
                                player = LocalPlayer.Name,
                                userId = LocalPlayer.UserId,
                                placeId = game.PlaceId,
                                timestamp = os.time()
                            }
                        end

                        task.spawn(function()
                            pcall(function()
                                httpReq({
                                    Url = url,
                                    Method = "POST",
                                    Headers = { ["Content-Type"] = "application/json" },
                                    Body = HttpService:JSONEncode(payloadData)
                                })
                            end)
                        end)
                    else
                        warn("[TaskScheduler] SendWebhook: Executor does not support HTTP requests")
                    end
                end
            end
        elseif act.type == "SetClipboard" then
            local clipText = tostring(evalValue(act.text or act.content or "", ctx))
            local clipFn = setclipboard or toclipboard or set_clipboard or (Clipboard and Clipboard.set)
            if clipFn then
                clipFn(clipText)
            else
                warn("[TaskScheduler] SetClipboard: setclipboard function unavailable")
            end
        elseif act.type == "PlayAnimation" then
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local animator = hum and (hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum))
            local animTarget = tostring(evalValue(act.animation or act.name or "dance", ctx)):lower()
            local subAct = tostring(evalValue(act.action or "play", ctx)):lower()
            local dur = tonumber(evalValue(act.duration, ctx)) or 0
            local spd = tonumber(evalValue(act.speed, ctx)) or 1.0

            if not getgenv()._OmniActiveTracks then getgenv()._OmniActiveTracks = {} end

            if subAct == "stop" then
                if animator then
                    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                        pcall(function() track:Stop() end)
                    end
                end
                getgenv()._OmniActiveTracks = {}
            elseif animator then
                local builtInEmotes = {
                    wave = "rbxassetid://507770239",
                    cheer = "rbxassetid://507770677",
                    laugh = "rbxassetid://507770818",
                    point = "rbxassetid://507770453",
                    dance = "rbxassetid://507771019",
                    dance1 = "rbxassetid://507771019",
                    dance2 = "rbxassetid://507776720",
                    dance3 = "rbxassetid://507777268",
                    salute = "rbxassetid://3360686498",
                    stadium = "rbxassetid://3360689775",
                    tilt = "rbxassetid://3360692915"
                }

                local animId = builtInEmotes[animTarget]
                if not animId then
                    if animTarget:find("^rbxassetid://") then
                        animId = animTarget
                    elseif tonumber(animTarget) then
                        animId = "rbxassetid://" .. animTarget
                    end
                end

                if animId then
                    local anim = Instance.new("Animation")
                    anim.AnimationId = animId
                    local track = animator:LoadAnimation(anim)
                    if spd ~= 1.0 then track:AdjustSpeed(spd) end
                    track:Play()
                    table.insert(getgenv()._OmniActiveTracks, track)
                    if dur > 0 then
                        task.delay(dur, function()
                            pcall(function() track:Stop() end)
                        end)
                    end
                else
                    pcall(function() hum:PlayEmote(animTarget) end)
                end
            end
        elseif act.type == "Spectate" then
            local rawTarget = evalValue(act.target or "$nearest", ctx)
            local cam = workspace.CurrentCamera
            if cam then
                if not rawTarget or rawTarget == "" or rawTarget == "me" or rawTarget == "reset" or rawTarget == LocalPlayer.Name then
                    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                    local fallback = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character.PrimaryPart)
                    if hum or fallback then
                        cam.CameraSubject = hum or fallback
                        cam.CameraType = Enum.CameraType.Custom
                    end
                else
                    local targetInst = nil
                    if typeof(rawTarget) == "Instance" then
                        targetInst = rawTarget
                    elseif type(rawTarget) == "string" then
                        local p = Players:FindFirstChild(rawTarget)
                        if p and p.Character then
                            targetInst = p.Character
                        else
                            targetInst = resolveInstance(rawTarget)
                        end
                    end

                    if targetInst then
                        if targetInst:IsA("Player") and targetInst.Character then
                            targetInst = targetInst.Character
                        end
                        local subject = nil
                        if targetInst:IsA("Humanoid") then
                            subject = targetInst
                        elseif targetInst:IsA("Model") then
                            subject = targetInst:FindFirstChildOfClass("Humanoid") or targetInst.PrimaryPart or targetInst:FindFirstChild("HumanoidRootPart") or targetInst:FindFirstChildWhichIsA("BasePart")
                        elseif targetInst:IsA("BasePart") then
                            if targetInst.Parent and targetInst.Parent:FindFirstChildOfClass("Humanoid") then
                                subject = targetInst.Parent:FindFirstChildOfClass("Humanoid")
                            else
                                subject = targetInst
                            end
                        end
                        if subject then
                            cam.CameraSubject = subject
                        end
                    end
                end
            end
        elseif act.type == "ResetCamera" then
            local cam = workspace.CurrentCamera
            local char = LocalPlayer.Character
            local subject = char and (char:FindFirstChildOfClass("Humanoid") or char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
            if cam and subject then
                cam.CameraSubject = subject
                cam.CameraType = Enum.CameraType.Custom
            end
        elseif act.type == "ActivatePrompt" then
            local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local bestPrompt = nil
                local bestDist = tonumber(evalValue(act.maxDistance, ctx)) or 35
                local promptName = tostring(evalValue(act.target or "", ctx)):lower()
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
                    local holdDur = tonumber(evalValue(act.holdDuration, ctx)) or bestPrompt.HoldDuration or 0
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
            local remPath = evalValue(act.remote, ctx)
            local remoteObj = resolveInstance(remPath)
            if remoteObj then
                local processedArgs = {}
                local rawArgs = act.args
                if type(rawArgs) == "string" then
                    rawArgs = evalValue(rawArgs, ctx)
                    if type(rawArgs) == "string" and rawArgs:sub(1,1) == "[" then
                        local okJ, dec = pcall(function() return HttpService:JSONDecode(rawArgs) end)
                        rawArgs = (okJ and type(dec) == "table") and dec or { rawArgs }
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
    if not ok then
        warn("[TaskScheduler] Action failed (" .. tostring(act.type) .. "):", err)
    end
end

local function executeActions(taskObj, triggerArgs)
    local actions = taskObj.actions or {}
    local ctx = {
        input = triggerArgs and triggerArgs[1],
        inputs = triggerArgs or {},
        vars = {},
    }

    local ok, err = pcall(function()
        executeBlock(actions, ctx)
    end)
    if not ok then
        warn("[TaskScheduler] Pipeline error:", err)
    end

    taskObj.telemetry = taskObj.telemetry or {}
    taskObj.telemetry.invocations = (taskObj.telemetry.invocations or 0) + 1
    taskObj.telemetry.lastRun = os.time()
    taskObj.telemetry.lastResult = ok and "Completed pipeline" or ("Error: " .. tostring(err))
    Storage.save(false)
end

local function evaluateCondition(taskObj, triggerArgs)
    local cond = taskObj.condition or { type = "Always" }
    if not cond.type or cond.type == "Always" then
        return true
    elseif cond.type == "InVehicle" then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.SeatPart and (hum.SeatPart:IsA("VehicleSeat") or hum.SeatPart:IsA("Seat")) then
            return true
        end
        return false
    elseif cond.type == "LowHealth" then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local threshold = tonumber(cond.threshold) or 25
        return hum and (hum.Health <= threshold)
    elseif cond.type == "StaffRank" then
        local player = triggerArgs and triggerArgs[1]
        if player and typeof(player) == "Instance" and player:IsA("Player") then
            local grp = tonumber(cond.groupId) or 0
            if grp == 0 and game.CreatorType == Enum.CreatorType.Group then
                grp = game.CreatorId
            end
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
    elseif cond.type == "StatThreshold" then
        local statName = cond.stat or "Cash"
        local op = cond.operator or ">="
        local val = tonumber(cond.value) or 0
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local statObj = ls and ls:FindFirstChild(statName)
        if statObj then
            local curVal = tonumber(statObj.Value) or 0
            if op == ">=" then return curVal >= val
            elseif op == "<=" then return curVal <= val
            elseif op == ">" then return curVal > val
            elseif op == "<" then return curVal < val
            elseif op == "==" then return curVal == val
            elseif op == "!=" then return curVal ~= val
            end
        end
        return false
    elseif cond.type == "ObjectProximity" then
        local targetName = cond.target or "Door"
        local maxDist = tonumber(cond.distance) or 25
        local mode = cond.mode or "within"
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            local targetInst = resolveInstance(targetName)
            if not targetInst then
                for _, desc in ipairs(workspace:GetDescendants()) do
                    if desc.Name:lower():find(targetName:lower(), 1, true) and (desc:IsA("BasePart") or desc:IsA("Model")) then
                        targetInst = desc
                        break
                    end
                end
            end
            if targetInst then
                local tPos = targetInst:IsA("BasePart") and targetInst.Position or targetInst:GetPivot().Position
                local d = (hrp.Position - tPos).Magnitude
                if mode == "outside" then
                    return d > maxDist
                else
                    return d <= maxDist
                end
            end
        end
        return false
    elseif cond.type == "ClockElapsed" then
        local threshold = tonumber(cond.threshold) or 0
        return os.clock() >= threshold
    elseif cond.type == "CustomLua" then
        if cond.code and cond.code ~= "" then
            local fn = loadstring("return function(args) " .. cond.code .. " end")
            if fn then
                local ok, res = pcall(fn(), triggerArgs)
                return ok and (res == true)
            end
        end
        return true
    end
    return true
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
        local intv = math.max(0.05, tonumber(trig.interval) or 5)
        local lastClock = os.clock()
        local c = RunService.Heartbeat:Connect(function()
            local now = os.clock()
            if now - lastClock >= intv then
                lastClock = now
                fireTask(taskObj)
            end
        end)
        table.insert(conns, c)
    elseif trig.type == "ClockTarget" then
        local target = tonumber(trig.target) or (os.clock() + 60)
        local fired = false
        local c = RunService.Heartbeat:Connect(function()
            if not fired and os.clock() >= target then
                fired = true
                fireTask(taskObj)
            end
        end)
        table.insert(conns, c)
    elseif trig.type == "Signal" then
        local preset = trig.preset
        if preset == "Seated" then
            local function hookChar(char)
                local hum = char:WaitForChild("Humanoid", 5)
                if hum then
                    local c = hum.Seated:Connect(function(active, seat)
                        if active then fireTask(taskObj, seat) end
                    end)
                    table.insert(conns, c)
                end
            end
            if LocalPlayer.Character then hookChar(LocalPlayer.Character) end
            local c2 = LocalPlayer.CharacterAdded:Connect(hookChar)
            table.insert(conns, c2)
        elseif preset == "PlayerAdded" then
            local c = Players.PlayerAdded:Connect(function(p) fireTask(taskObj, p) end)
            table.insert(conns, c)
        elseif preset == "PlayerRemoving" then
            local c = Players.PlayerRemoving:Connect(function(p) fireTask(taskObj, p) end)
            table.insert(conns, c)
        elseif preset == "CharacterAdded" then
            local c = LocalPlayer.CharacterAdded:Connect(function(char) fireTask(taskObj, char) end)
            table.insert(conns, c)
        elseif preset == "Died" then
            local function hookDied(char)
                local hum = char:WaitForChild("Humanoid", 5)
                if hum then
                    local c = hum.Died:Connect(function() fireTask(taskObj) end)
                    table.insert(conns, c)
                end
            end
            if LocalPlayer.Character then hookDied(LocalPlayer.Character) end
            local c2 = LocalPlayer.CharacterAdded:Connect(hookDied)
            table.insert(conns, c2)
        elseif preset == "WindowFocus" then
            local c = UserInputService.WindowFocused:Connect(function() fireTask(taskObj, "FocusGained") end)
            local c2 = UserInputService.WindowFocusReleased:Connect(function() fireTask(taskObj, "FocusLost") end)
            table.insert(conns, c)
            table.insert(conns, c2)
        elseif preset == "Idled" then
            local c = LocalPlayer.Idled:Connect(function(timeVal) fireTask(taskObj, timeVal) end)
            table.insert(conns, c)
        end
    elseif trig.type == "CustomSignal" then
        local sig = resolveSignal(trig.path, trig.signal or trig.signalName or trig.event)
        if sig and typeof(sig) == "RBXScriptSignal" then
            local c = sig:Connect(function(...) fireTask(taskObj, ...) end)
            table.insert(conns, c)
        else
            warn(string.format("[KernelTaskScheduler]: CustomSignal could not resolve signal on path '%s'", tostring(trig.path)))
        end
    elseif trig.type == "Keybind" then
        local targetKey = tostring(trig.key or "G"):upper():gsub("%s+", "")
        local digitToWord = {
            ["0"] = "ZERO", ["1"] = "ONE", ["2"] = "TWO", ["3"] = "THREE", ["4"] = "FOUR",
            ["5"] = "FIVE", ["6"] = "SIX", ["7"] = "SEVEN", ["8"] = "EIGHT", ["9"] = "NINE"
        }
        local c = UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if UserInputService:GetFocusedTextBox() ~= nil then return end
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local kName = input.KeyCode.Name:upper()
                local matches = (kName == targetKey) or (digitToWord[targetKey] == kName)
                if matches then
                    fireTask(taskObj, kName)
                end
            end
        end)
        table.insert(conns, c)
    end

    Engine.liveConnections[taskObj.id] = conns
    Engine.activeTasks[taskObj.id] = taskObj
end

-- ==============================================================================
-- 3. CURATED SHORTCUTS GALLERY RECIPES
-- ==============================================================================
local GALLERY_RECIPES = {
    {
        id = "gallery_bounty_hunter",
        name = "Bounty Hunter Protocol",
        description = "Target lock nearest player, drone spectate, pathfind sprint, announce, emote & log to clipboard [Hotkey: Z]",
        icon = "🎯",
        color = "red",
        scope = "universal",
        trigger = { type = "Keybind", key = "Z" },
        condition = { type = "Always" },
        actions = {
            { type = "PlaySound", sound = "Alert", volume = 1.0 },
            { type = "FindNearest", source = "Players", varName = "bounty", maxDistance = 1000 },
            { type = "HighlightInstance", target = "$bounty", color = "gold", duration = 15 },
            { type = "Toast", title = "TARGET LOCKED", message = "Bounty: $bounty.Name ($nearestDistance studs away)" },
            { type = "Spectate", target = "$bounty" },
            { type = "Wait", duration = 1.5 },
            { type = "ResetCamera" },
            { type = "SetCharacterState", property = "WalkSpeed", value = "32" },
            { type = "PathfindTo", target = "$bounty", stopDistance = 5 },
            { type = "LookAt", target = "$bounty" },
            { type = "EquipTool", toolName = "first" },
            { type = "SendChat", message = "Target spotted: $bounty.Name! Identified by $player." },
            { type = "PlaySound", sound = "Success", volume = 1.0 },
            { type = "PlayAnimation", animation = "dance", action = "play" },
            { type = "SetClipboard", text = "Target: $bounty.Name | Pos: $position | Server: $placeId" },
            { type = "Toast", title = "INTERCEPTION COMPLETE", message = "Dossier copied to clipboard! Standing down." },
            { type = "Wait", duration = 2.0 },
            { type = "SetCharacterState", property = "WalkSpeed", value = "16" }
        }
    },
    {
        id = "gallery_anti_afk",
        name = "Anti-AFK Ghost",
        description = "Periodically pokes virtual mouse input to bypass Roblox's 20-minute idle disconnect",
        icon = "👻",
        color = "indigo",
        scope = "universal",
        trigger = { type = "Timer", interval = 120 },
        condition = { type = "Always" },
        actions = {
            { type = "VirtualPoke" },
            { type = "Toast", title = "Anti-AFK Ghost", message = "Poked virtual heartbeat" }
        }
    },
    {
        id = "gallery_emergency_rejoin",
        name = "Emergency Low-HP Exit",
        description = "Safely rejoins server before dying when health drops critical to preserve gear",
        icon = "💊",
        color = "red",
        scope = "universal",
        trigger = { type = "ClockInterval", interval = 0.5 },
        condition = { type = "LowHealth", threshold = 20 },
        actions = {
            { type = "Toast", title = "CRITICAL HEALTH", message = "Health <= 20! Initiating emergency rejoin..." },
            { type = "Delay", duration = 0.5 },
            { type = "Rejoin" }
        }
    },
    {
        id = "gallery_prompt_harvester",
        name = "Prompt Auto-Harvester",
        description = "Continuously scans and triggers nearby proximity prompts (doors, registers, items)",
        icon = "⚡",
        color = "green",
        scope = "universal",
        trigger = { type = "Timer", interval = 1.0 },
        condition = { type = "Always" },
        actions = {
            { type = "ActivatePrompt", target = "nearest", maxDistance = 25, holdDuration = 0 },
            { type = "Toast", title = "Harvester", message = "Interacted with proximity prompt" }
        }
    },
    {
        id = "gallery_washiez_patrol",
        name = "Washiez Route Patrol",
        description = "Drives automated patrol route between Yard and Station exit when seated in car",
        icon = "🚗",
        color = "blue",
        scope = "place",
        trigger = { type = "Timer", interval = 60 },
        condition = { type = "InVehicle" },
        actions = {
            { type = "Toast", title = "Washiez Patrol", message = "Navigating to Yard Node..." },
            { type = "FollowRoute", targetNode = "Yard", route = "road_network.json" },
            { type = "Delay", duration = 2.0 },
            { type = "FollowRoute", targetNode = "Exit", route = "road_network.json" }
        }
    },
    {
        id = "gallery_cash_alert",
        name = "Cash Milestone Notifier",
        description = "Celebrates and alerts when leaderstats Cash crosses your savings threshold",
        icon = "💰",
        color = "amber",
        scope = "universal",
        trigger = { type = "ClockInterval", interval = 5.0 },
        condition = { type = "StatThreshold", stat = "Cash", operator = ">=", value = 50000 },
        actions = {
            { type = "Toast", title = "💰 Goal Reached", message = "Cash reached over $50,000!" },
            { type = "VirtualPoke" }
        }
    },
    {
        id = "gallery_staff_radar",
        name = "Staff Radar & Panic Stop",
        description = "Detects staff or moderators joining the server and freezes automation loops",
        icon = "🛡️",
        color = "purple",
        scope = "universal",
        trigger = { type = "Signal", preset = "PlayerAdded" },
        condition = { type = "StaffRank", minRank = 100, groupId = 0 },
        actions = {
            { type = "Toast", title = "⚠️ STAFF DETECTED", message = "Moderator joined! Pausing all loops for safety." },
            { type = "PauseAllLoops" }
        }
    },
    {
        id = "gallery_safe_respawn",
        name = "Post-Death Safe Teleport",
        description = "Waits for character spawn and tweens immediately to high ground coordinates",
        icon = "📍",
        color = "teal",
        scope = "universal",
        trigger = { type = "Signal", preset = "CharacterAdded" },
        condition = { type = "Always" },
        actions = {
            { type = "Delay", duration = 2.0 },
            { type = "TweenTo", target = "0, 100, 0", duration = 3.0 },
            { type = "Toast", title = "Safety Transit", message = "Relocated to safe respawn coordinates" }
        }
    },
    {
        id = "gallery_anti_idle_jiggle",
        name = "Anti-AFK Jiggle & Jump",
        description = "Sends spacebar jump and micro-poke whenever Roblox signals player idled",
        icon = "🔄",
        color = "orange",
        scope = "universal",
        trigger = { type = "Signal", preset = "Idled" },
        condition = { type = "Always" },
        actions = {
            { type = "VirtualInput", key = "Space", duration = 0.1 },
            { type = "Delay", duration = 0.2 },
            { type = "VirtualPoke" },
            { type = "Toast", title = "Anti-Idle", message = "Reset idle state timer" }
        }
    },
    {
        id = "gallery_nearest_chams",
        name = "Nearest Player ESP & Spectate",
        description = "Press [G] to find the nearest player, highlight them with Cyan chams, look at them, and spectate for 8s",
        icon = "✨",
        color = "cyan",
        scope = "universal",
        trigger = { type = "Keybind", key = "G" },
        condition = { type = "Always" },
        actions = {
            { type = "FindNearest", source = "Players", varName = "targetPlayer", maxDistance = 1000 },
            { type = "HighlightInstance", target = "$targetPlayer", color = "cyan", duration = 8 },
            { type = "LookAt", target = "$targetPlayer" },
            { type = "Spectate", target = "$targetPlayer" },
            { type = "PlaySound", sound = "Ping", volume = 1.0 },
            { type = "Toast", title = "ESP & Spectate Active", message = "Tracking $targetPlayer for 8s" },
            { type = "Wait", duration = 8 },
            { type = "ResetCamera" }
        }
    },
    {
        id = "gallery_loot_copier",
        name = "Loot Spot Webhook & Clipboard",
        description = "Press [H] to copy your current coordinates and dispatch an alert to your Discord webhook",
        icon = "📋",
        color = "amber",
        scope = "universal",
        trigger = { type = "Keybind", key = "H" },
        condition = { type = "Always" },
        actions = {
            { type = "SetVariable", varName = "locInfo", value = "Player $player at $position in Place $placeId" },
            { type = "SetClipboard", text = "$locInfo" },
            { type = "SendWebhook", url = "https://discord.com/api/webhooks/YOUR_WEBHOOK_URL", message = "$locInfo", title = "Loot Coordinates Logged" },
            { type = "PlaySound", sound = "Success", volume = 1.0 },
            { type = "Toast", title = "Coords Copied & Webhook Sent", message = "Saved location to clipboard!" }
        }
    },
    {
        id = "gallery_celebrate_emote",
        name = "Victory Dance & Chat Shout",
        description = "Press [Z] to play a victory celebration dance emote, sound chime, and broadcast celebratory chat",
        icon = "💃",
        color = "purple",
        scope = "universal",
        trigger = { type = "Keybind", key = "Z" },
        condition = { type = "Always" },
        actions = {
            { type = "PlayAnimation", animation = "dance", action = "play" },
            { type = "PlaySound", sound = "Chime", volume = 1.0 },
            { type = "SendChat", message = "Victory! Automated via Omni Shortcuts 🎉" },
            { type = "Toast", title = "Victory Dance", message = "Celebrating completed task!" }
        }
    }
}

-- ==============================================================================
-- 4. APPLE SHORTCUTS GUI & DESIGN SYSTEM
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

-- Destroy any existing instance
if parentContainer:FindFirstChild("WindowsTaskSchedulerGui") then
    pcall(function() parentContainer.WindowsTaskSchedulerGui:Destroy() end)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "WindowsTaskSchedulerGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Enabled = true
ScreenGui.Parent = parentContainer

-- Toast Notification System
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
    tCorner.CornerRadius = UDim.new(0, 8)
    tCorner.Parent = toast

    local tStroke = Instance.new("UIStroke")
    tStroke.Color = Color3.fromRGB(0, 122, 255)
    tStroke.Thickness = 1
    tStroke.Transparency = 0.4
    tStroke.Parent = toast

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.Size = UDim2.new(0, 4, 1, -12)
    accent.Position = UDim2.new(0, 6, 0, 6)
    accent.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
    accent.BorderSizePixel = 0
    accent.ZIndex = 502
    accent.Parent = toast
    local acCorner = Instance.new("UICorner")
    acCorner.CornerRadius = UDim.new(1, 0)
    acCorner.Parent = accent

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Name = "TitleLbl"
    titleLbl.Size = UDim2.new(1, -28, 0, 18)
    titleLbl.Position = UDim2.new(0, 18, 0, 8)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 12
    titleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Text = tostring(title or "Shortcuts Alert")
    titleLbl.ZIndex = 502
    titleLbl.Parent = toast

    local descLbl = Instance.new("TextLabel")
    descLbl.Name = "DescLbl"
    descLbl.Size = UDim2.new(1, -28, 0, 16)
    descLbl.Position = UDim2.new(0, 18, 0, 28)
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
MainFrame.Size = UDim2.new(0, 760, 0, 520)
MainFrame.Position = UDim2.new(0.5, -380, 0.5, -260)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 17, 24)
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Active = true
MainFrame.Visible = false
MainFrame.Parent = ScreenGui

local mCorner = Instance.new("UICorner")
mCorner.CornerRadius = UDim.new(0, 12)
mCorner.Parent = MainFrame

local mStroke = Instance.new("UIStroke")
mStroke.Thickness = 1.5
mStroke.Color = Color3.fromRGB(45, 55, 75)
mStroke.Transparency = 0.25
mStroke.Parent = MainFrame

-- Title Bar (macOS / iOS style)
local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 44)
TitleBar.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame

local tbCorner = Instance.new("UICorner")
tbCorner.CornerRadius = UDim.new(0, 12)
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

-- Icon & Title in Header
local HeaderBadge = Instance.new("Frame")
HeaderBadge.Name = "HeaderBadge"
HeaderBadge.Size = UDim2.new(0, 26, 0, 26)
HeaderBadge.Position = UDim2.new(0, 14, 0.5, -13)
HeaderBadge.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
HeaderBadge.BorderSizePixel = 0
HeaderBadge.Parent = TitleBar
local hbCorner = Instance.new("UICorner")
hbCorner.CornerRadius = UDim.new(0, 7)
hbCorner.Parent = HeaderBadge

local HeaderBadgeIcon = Instance.new("TextLabel")
HeaderBadgeIcon.Size = UDim2.new(1, 0, 1, 0)
HeaderBadgeIcon.BackgroundTransparency = 1
HeaderBadgeIcon.Font = Enum.Font.GothamBold
HeaderBadgeIcon.TextSize = 14
HeaderBadgeIcon.TextColor3 = Color3.fromRGB(255, 255, 255)
HeaderBadgeIcon.Text = "⚡"
HeaderBadgeIcon.Parent = HeaderBadge

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Name = "TitleLbl"
TitleLbl.Size = UDim2.new(0, 180, 1, 0)
TitleLbl.Position = UDim2.new(0, 48, 0, 0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.Font = Enum.Font.GothamBold
TitleLbl.TextSize = 14
TitleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
TitleLbl.TextXAlignment = Enum.TextXAlignment.Left
TitleLbl.Text = "Shortcuts"
TitleLbl.Parent = TitleBar

local SubtitleLbl = Instance.new("TextLabel")
SubtitleLbl.Name = "SubtitleLbl"
SubtitleLbl.Size = UDim2.new(0, 150, 1, 0)
SubtitleLbl.Position = UDim2.new(0, 126, 0, 1)
SubtitleLbl.BackgroundTransparency = 1
SubtitleLbl.Font = Enum.Font.Gotham
SubtitleLbl.TextSize = 11
SubtitleLbl.TextColor3 = Color3.fromRGB(130, 145, 175)
SubtitleLbl.TextXAlignment = Enum.TextXAlignment.Left
SubtitleLbl.Text = "Omni Automation Engine"
SubtitleLbl.Parent = TitleBar

local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.Size = UDim2.new(0, 28, 0, 28)
CloseBtn.Position = UDim2.new(1, -38, 0.5, -14)
CloseBtn.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
CloseBtn.BorderSizePixel = 0
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 12
CloseBtn.TextColor3 = Color3.fromRGB(220, 225, 240)
CloseBtn.Text = "✕"
CloseBtn.Parent = TitleBar
local cbCorner = Instance.new("UICorner")
cbCorner.CornerRadius = UDim.new(1, 0)
cbCorner.Parent = CloseBtn

CloseBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
end)

-- Top Control Ribbon (Segmented Pills, Search, Export, Import, + New Shortcut)
local Ribbon = Instance.new("Frame")
Ribbon.Name = "Ribbon"
Ribbon.Size = UDim2.new(1, -28, 0, 36)
Ribbon.Position = UDim2.new(0, 14, 0, 52)
Ribbon.BackgroundTransparency = 1
Ribbon.Parent = MainFrame

-- Segmented Navigation Pill Container
local SegmentContainer = Instance.new("Frame")
SegmentContainer.Name = "SegmentContainer"
SegmentContainer.Size = UDim2.new(0, 210, 0, 32)
SegmentContainer.Position = UDim2.new(0, 0, 0, 2)
SegmentContainer.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
SegmentContainer.BorderSizePixel = 0
SegmentContainer.Parent = Ribbon
local scCorner = Instance.new("UICorner")
scCorner.CornerRadius = UDim.new(0, 8)
scCorner.Parent = SegmentContainer

local TabShortcutsBtn = Instance.new("TextButton")
TabShortcutsBtn.Name = "TabShortcutsBtn"
TabShortcutsBtn.Size = UDim2.new(0.5, -2, 1, -4)
TabShortcutsBtn.Position = UDim2.new(0, 2, 0, 2)
TabShortcutsBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
TabShortcutsBtn.BorderSizePixel = 0
TabShortcutsBtn.Font = Enum.Font.GothamBold
TabShortcutsBtn.TextSize = 11
TabShortcutsBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
TabShortcutsBtn.Text = "📱 Shortcuts"
TabShortcutsBtn.Parent = SegmentContainer
local tsbCorner = Instance.new("UICorner")
tsbCorner.CornerRadius = UDim.new(0, 6)
tsbCorner.Parent = TabShortcutsBtn

local TabGalleryBtn = Instance.new("TextButton")
TabGalleryBtn.Name = "TabGalleryBtn"
TabGalleryBtn.Size = UDim2.new(0.5, -2, 1, -4)
TabGalleryBtn.Position = UDim2.new(0.5, 0, 0, 2)
TabGalleryBtn.BackgroundTransparency = 1
TabGalleryBtn.BorderSizePixel = 0
TabGalleryBtn.Font = Enum.Font.GothamBold
TabGalleryBtn.TextSize = 11
TabGalleryBtn.TextColor3 = Color3.fromRGB(150, 165, 190)
TabGalleryBtn.Text = "🌟 Gallery"
TabGalleryBtn.Parent = SegmentContainer
local tgbCorner = Instance.new("UICorner")
tgbCorner.CornerRadius = UDim.new(0, 6)
tgbCorner.Parent = TabGalleryBtn

-- Search Box
local SearchBox = Instance.new("TextBox")
SearchBox.Name = "SearchBox"
SearchBox.Size = UDim2.new(0, 160, 0, 32)
SearchBox.Position = UDim2.new(0, 220, 0, 2)
SearchBox.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
SearchBox.BorderSizePixel = 0
SearchBox.Font = Enum.Font.Gotham
SearchBox.TextSize = 11
SearchBox.TextColor3 = Color3.fromRGB(235, 240, 255)
SearchBox.PlaceholderText = "🔍 Search..."
SearchBox.PlaceholderColor3 = Color3.fromRGB(120, 135, 160)
SearchBox.TextXAlignment = Enum.TextXAlignment.Left
SearchBox.ClearTextOnFocus = false
SearchBox.Text = ""
SearchBox.Parent = Ribbon
local sbCorner = Instance.new("UICorner")
sbCorner.CornerRadius = UDim.new(0, 8)
sbCorner.Parent = SearchBox
local sbPad = Instance.new("UIPadding")
sbPad.PaddingLeft = UDim.new(0, 10)
sbPad.PaddingRight = UDim.new(0, 10)
sbPad.Parent = SearchBox

-- Right action buttons
local ExportAllBtn = Instance.new("TextButton")
ExportAllBtn.Name = "ExportAllBtn"
ExportAllBtn.Size = UDim2.new(0, 86, 0, 32)
ExportAllBtn.Position = UDim2.new(1, -320, 0, 2)
ExportAllBtn.BackgroundColor3 = Color3.fromRGB(32, 45, 68)
ExportAllBtn.BorderSizePixel = 0
ExportAllBtn.Font = Enum.Font.GothamBold
ExportAllBtn.TextSize = 11
ExportAllBtn.TextColor3 = Color3.fromRGB(160, 210, 255)
ExportAllBtn.Text = "📤 Export"
ExportAllBtn.Parent = Ribbon
local eabCorner = Instance.new("UICorner")
eabCorner.CornerRadius = UDim.new(0, 8)
eabCorner.Parent = ExportAllBtn

local ImportBtn = Instance.new("TextButton")
ImportBtn.Name = "ImportBtn"
ImportBtn.Size = UDim2.new(0, 86, 0, 32)
ImportBtn.Position = UDim2.new(1, -226, 0, 2)
ImportBtn.BackgroundColor3 = Color3.fromRGB(28, 55, 42)
ImportBtn.BorderSizePixel = 0
ImportBtn.Font = Enum.Font.GothamBold
ImportBtn.TextSize = 11
ImportBtn.TextColor3 = Color3.fromRGB(120, 235, 170)
ImportBtn.Text = "📥 Import"
ImportBtn.Parent = Ribbon
local ibCorner = Instance.new("UICorner")
ibCorner.CornerRadius = UDim.new(0, 8)
ibCorner.Parent = ImportBtn

local NewShortcutBtn = Instance.new("TextButton")
NewShortcutBtn.Name = "NewShortcutBtn"
NewShortcutBtn.Size = UDim2.new(0, 130, 0, 32)
NewShortcutBtn.Position = UDim2.new(1, -132, 0, 2)
NewShortcutBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
NewShortcutBtn.BorderSizePixel = 0
NewShortcutBtn.Font = Enum.Font.GothamBold
NewShortcutBtn.TextSize = 11
NewShortcutBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
NewShortcutBtn.Text = "+ New Shortcut"
NewShortcutBtn.Parent = Ribbon
local nsbCorner = Instance.new("UICorner")
nsbCorner.CornerRadius = UDim.new(0, 8)
nsbCorner.Parent = NewShortcutBtn

-- Views
local ShortcutsView = Instance.new("Frame")
ShortcutsView.Name = "ShortcutsView"
ShortcutsView.Size = UDim2.new(1, -28, 1, -100)
ShortcutsView.Position = UDim2.new(0, 14, 0, 94)
ShortcutsView.BackgroundTransparency = 1
ShortcutsView.Parent = MainFrame

local GalleryView = Instance.new("Frame")
GalleryView.Name = "GalleryView"
GalleryView.Size = UDim2.new(1, -28, 1, -100)
GalleryView.Position = UDim2.new(0, 14, 0, 94)
GalleryView.BackgroundTransparency = 1
GalleryView.Visible = false
GalleryView.Parent = MainFrame

-- Shortcuts Tile Grid
local ShortcutsScroll = Instance.new("ScrollingFrame")
ShortcutsScroll.Name = "ShortcutsScroll"
ShortcutsScroll.Size = UDim2.new(1, 0, 1, 0)
ShortcutsScroll.BackgroundTransparency = 1
ShortcutsScroll.BorderSizePixel = 0
ShortcutsScroll.ScrollBarThickness = 5
ShortcutsScroll.ScrollBarImageColor3 = Color3.fromRGB(60, 75, 100)
ShortcutsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
ShortcutsScroll.Parent = ShortcutsView

local ShortcutsGrid = Instance.new("UIGridLayout")
ShortcutsGrid.CellSize = UDim2.new(0, 230, 0, 118)
ShortcutsGrid.CellPadding = UDim2.new(0, 14, 0, 14)
ShortcutsGrid.SortOrder = Enum.SortOrder.LayoutOrder
ShortcutsGrid.Parent = ShortcutsScroll

ShortcutsGrid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    ShortcutsScroll.CanvasSize = UDim2.new(0, 0, 0, ShortcutsGrid.AbsoluteContentSize.Y + 20)
end)

-- Shortcuts Empty State
local ShortcutsEmpty = Instance.new("Frame")
ShortcutsEmpty.Name = "ShortcutsEmpty"
ShortcutsEmpty.Size = UDim2.new(1, 0, 0, 220)
ShortcutsEmpty.Position = UDim2.new(0, 0, 0, 40)
ShortcutsEmpty.BackgroundTransparency = 1
ShortcutsEmpty.Visible = false
ShortcutsEmpty.Parent = ShortcutsView

local seIcon = Instance.new("TextLabel")
seIcon.Size = UDim2.new(1, 0, 0, 50)
seIcon.Position = UDim2.new(0, 0, 0, 10)
seIcon.BackgroundTransparency = 1
seIcon.Font = Enum.Font.GothamBold
seIcon.TextSize = 42
seIcon.Text = "⚡"
seIcon.TextColor3 = Color3.fromRGB(80, 140, 220)
seIcon.Parent = ShortcutsEmpty

local seTitle = Instance.new("TextLabel")
seTitle.Size = UDim2.new(1, 0, 0, 24)
seTitle.Position = UDim2.new(0, 0, 0, 68)
seTitle.BackgroundTransparency = 1
seTitle.Font = Enum.Font.GothamBold
seTitle.TextSize = 14
seTitle.TextColor3 = Color3.fromRGB(220, 230, 250)
seTitle.Text = "No Shortcuts Scheduled"
seTitle.Parent = ShortcutsEmpty

local seDesc = Instance.new("TextLabel")
seDesc.Size = UDim2.new(1, 0, 0, 20)
seDesc.Position = UDim2.new(0, 0, 0, 96)
seDesc.BackgroundTransparency = 1
seDesc.Font = Enum.Font.Gotham
seDesc.TextSize = 11
seDesc.TextColor3 = Color3.fromRGB(140, 155, 180)
seDesc.Text = "Get started with pre-built recipes from the Gallery or build a custom workflow."
seDesc.Parent = ShortcutsEmpty

local seBrowseBtn = Instance.new("TextButton")
seBrowseBtn.Size = UDim2.new(0, 160, 0, 32)
seBrowseBtn.Position = UDim2.new(0.5, -80, 0, 130)
seBrowseBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
seBrowseBtn.BorderSizePixel = 0
seBrowseBtn.Font = Enum.Font.GothamBold
seBrowseBtn.TextSize = 11
seBrowseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
seBrowseBtn.Text = "🌟 Browse Gallery"
seBrowseBtn.Parent = ShortcutsEmpty
local sebCorn = Instance.new("UICorner")
sebCorn.CornerRadius = UDim.new(0, 8)
sebCorn.Parent = seBrowseBtn

-- Gallery Grid
local GalleryScroll = Instance.new("ScrollingFrame")
GalleryScroll.Name = "GalleryScroll"
GalleryScroll.Size = UDim2.new(1, 0, 1, 0)
GalleryScroll.BackgroundTransparency = 1
GalleryScroll.BorderSizePixel = 0
GalleryScroll.ScrollBarThickness = 5
GalleryScroll.ScrollBarImageColor3 = Color3.fromRGB(60, 75, 100)
GalleryScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
GalleryScroll.Parent = GalleryView

local GalleryGrid = Instance.new("UIGridLayout")
GalleryGrid.CellSize = UDim2.new(0, 350, 0, 132)
GalleryGrid.CellPadding = UDim2.new(0, 16, 0, 14)
GalleryGrid.SortOrder = Enum.SortOrder.LayoutOrder
GalleryGrid.Parent = GalleryScroll

GalleryGrid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    GalleryScroll.CanvasSize = UDim2.new(0, 0, 0, GalleryGrid.AbsoluteContentSize.Y + 20)
end)

-- Forward declarations
local refreshShortcutsGrid
local openShortcutEditor
local switchToTab

switchToTab = function(tabName)
    if tabName == "shortcuts" then
        ShortcutsView.Visible = true
        GalleryView.Visible = false
        TabShortcutsBtn.BackgroundTransparency = 0
        TabShortcutsBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        TabGalleryBtn.BackgroundTransparency = 1
        TabGalleryBtn.TextColor3 = Color3.fromRGB(150, 165, 190)
        refreshShortcutsGrid()
    else
        ShortcutsView.Visible = false
        GalleryView.Visible = true
        TabShortcutsBtn.BackgroundTransparency = 1
        TabShortcutsBtn.TextColor3 = Color3.fromRGB(150, 165, 190)
        TabGalleryBtn.BackgroundTransparency = 0
        TabGalleryBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
        TabGalleryBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    end
end

TabShortcutsBtn.MouseButton1Click:Connect(function() switchToTab("shortcuts") end)
TabGalleryBtn.MouseButton1Click:Connect(function() switchToTab("gallery") end)
seBrowseBtn.MouseButton1Click:Connect(function() switchToTab("gallery") end)

-- Export single / all functions
local function exportTaskToJson(taskObj)
    local exportCopy = {
        name = taskObj.name,
        description = taskObj.description,
        icon = taskObj.icon or "⚡",
        color = taskObj.color or "blue",
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
                writefile("Exported_Shortcut.json", json)
            end
        end)
        if showToastNotification then
            showToastNotification("Shortcut Exported", string.format("Copied '%s' JSON to clipboard", taskObj.name), 3.0)
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
                icon = t.icon or "⚡",
                color = t.color or "blue",
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
                icon = t.icon or "⚡",
                color = t.color or "blue",
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
                writefile("Exported_All_Shortcuts.json", json)
            end
        end)
        if showToastNotification then
            showToastNotification("All Shortcuts Exported", string.format("Copied %d shortcuts to clipboard", #all), 3.0)
        end
    end
end

ExportAllBtn.MouseButton1Click:Connect(exportAllTasksToJson)

-- Render Shortcut Tile (Apple Shortcuts Tile)
local cachedTiles = {}

local function renderShortcutTile(taskObj, idx)
    local tile = cachedTiles[taskObj.id]
    local colorKey = taskObj.color or "blue"
    local colorTheme = SHORTCUT_COLORS[colorKey] or SHORTCUT_COLORS.blue

    if not tile then
        tile = Instance.new("TextButton")
        tile.Name = taskObj.id
        tile.Size = UDim2.new(0, 230, 0, 118)
        tile.BackgroundColor3 = colorTheme.bg
        tile.BorderSizePixel = 0
        tile.AutoButtonColor = false
        tile.Text = ""
        tile.LayoutOrder = idx
        tile.Parent = ShortcutsScroll

        local tCorner = Instance.new("UICorner")
        tCorner.CornerRadius = UDim.new(0, 12)
        tCorner.Parent = tile

        local tStroke = Instance.new("UIStroke")
        tStroke.Thickness = 1.2
        tStroke.Color = colorTheme.stroke
        tStroke.Transparency = 0.35
        tStroke.Parent = tile

        -- Icon Badge Pill (top-left)
        local iconBadge = Instance.new("Frame")
        iconBadge.Name = "IconBadge"
        iconBadge.Size = UDim2.new(0, 32, 0, 32)
        iconBadge.Position = UDim2.new(0, 12, 0, 12)
        iconBadge.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        iconBadge.BackgroundTransparency = 0.65
        iconBadge.BorderSizePixel = 0
        iconBadge.Parent = tile
        local ibCorn = Instance.new("UICorner")
        ibCorn.CornerRadius = UDim.new(1, 0)
        ibCorn.Parent = iconBadge

        local iconGlyph = Instance.new("TextLabel")
        iconGlyph.Name = "IconGlyph"
        iconGlyph.Size = UDim2.new(1, 0, 1, 0)
        iconGlyph.BackgroundTransparency = 1
        iconGlyph.Font = Enum.Font.GothamBold
        iconGlyph.TextSize = 16
        iconGlyph.TextColor3 = Color3.fromRGB(255, 255, 255)
        iconGlyph.Text = taskObj.icon or "⚡"
        iconGlyph.Parent = iconBadge

        -- Status Indicator Pill
        local statusPill = Instance.new("TextButton")
        statusPill.Name = "StatusPill"
        statusPill.Size = UDim2.new(0, 56, 0, 22)
        statusPill.Position = UDim2.new(1, -94, 0, 12)
        statusPill.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        statusPill.BackgroundTransparency = 0.65
        statusPill.BorderSizePixel = 0
        statusPill.Font = Enum.Font.GothamBold
        statusPill.TextSize = 9
        statusPill.TextColor3 = taskObj.enabled and Color3.fromRGB(140, 255, 180) or Color3.fromRGB(210, 215, 225)
        statusPill.Text = taskObj.enabled and "● Active" or "○ Off"
        statusPill.Parent = tile
        local spCorn = Instance.new("UICorner")
        spCorn.CornerRadius = UDim.new(1, 0)
        spCorn.Parent = statusPill

        -- Context Export / Delete buttons
        local cardExport = Instance.new("TextButton")
        cardExport.Name = "CardExport"
        cardExport.Size = UDim2.new(0, 22, 0, 22)
        cardExport.Position = UDim2.new(1, -62, 0, 12)
        cardExport.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        cardExport.BackgroundTransparency = 0.65
        cardExport.BorderSizePixel = 0
        cardExport.Font = Enum.Font.GothamBold
        cardExport.TextSize = 10
        cardExport.TextColor3 = Color3.fromRGB(255, 255, 255)
        cardExport.Text = "📋"
        cardExport.Parent = tile
        local ceCorn = Instance.new("UICorner")
        ceCorn.CornerRadius = UDim.new(1, 0)
        ceCorn.Parent = cardExport

        local cardDelete = Instance.new("TextButton")
        cardDelete.Name = "CardDelete"
        cardDelete.Size = UDim2.new(0, 22, 0, 22)
        cardDelete.Position = UDim2.new(1, -34, 0, 12)
        cardDelete.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        cardDelete.BackgroundTransparency = 0.65
        cardDelete.BorderSizePixel = 0
        cardDelete.Font = Enum.Font.GothamBold
        cardDelete.TextSize = 10
        cardDelete.TextColor3 = Color3.fromRGB(255, 140, 140)
        cardDelete.Text = "✕"
        cardDelete.Parent = tile
        local cdCorn = Instance.new("UICorner")
        cdCorn.CornerRadius = UDim.new(1, 0)
        cdCorn.Parent = cardDelete

        -- Title & Summary
        local nameLbl = Instance.new("TextLabel")
        nameLbl.Name = "NameLbl"
        nameLbl.Size = UDim2.new(1, -24, 0, 20)
        nameLbl.Position = UDim2.new(0, 12, 0, 50)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamBold
        nameLbl.TextSize = 13
        nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Text = taskObj.name or "Untitled Shortcut"
        nameLbl.Parent = tile

        local summaryLbl = Instance.new("TextLabel")
        summaryLbl.Name = "SummaryLbl"
        summaryLbl.Size = UDim2.new(1, -66, 0, 16)
        summaryLbl.Position = UDim2.new(0, 12, 0, 72)
        summaryLbl.BackgroundTransparency = 1
        summaryLbl.Font = Enum.Font.Gotham
        summaryLbl.TextSize = 10
        summaryLbl.TextColor3 = colorTheme.sub
        summaryLbl.TextXAlignment = Enum.TextXAlignment.Left
        summaryLbl.TextTruncate = Enum.TextTruncate.AtEnd
        summaryLbl.Parent = tile

        local scopeChip = Instance.new("TextLabel")
        scopeChip.Name = "ScopeChip"
        scopeChip.Size = UDim2.new(0, 72, 0, 16)
        scopeChip.Position = UDim2.new(0, 12, 1, -24)
        scopeChip.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        scopeChip.BackgroundTransparency = 0.7
        scopeChip.BorderSizePixel = 0
        scopeChip.Font = Enum.Font.GothamBold
        scopeChip.TextSize = 8
        scopeChip.TextColor3 = Color3.fromRGB(255, 255, 255)
        scopeChip.Text = (taskObj.scope == "universal") and "🌐 UNIVERSAL" or "📍 PLACE"
        scopeChip.Parent = tile
        local scpCorn = Instance.new("UICorner")
        scpCorn.CornerRadius = UDim.new(0, 4)
        scpCorn.Parent = scopeChip

        -- Quick Run ▶ Play Button
        local runNowBtn = Instance.new("TextButton")
        runNowBtn.Name = "RunNowBtn"
        runNowBtn.Size = UDim2.new(0, 30, 0, 30)
        runNowBtn.Position = UDim2.new(1, -42, 1, -38)
        runNowBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        runNowBtn.BackgroundTransparency = 0.65
        runNowBtn.BorderSizePixel = 0
        runNowBtn.Font = Enum.Font.GothamBold
        runNowBtn.TextSize = 13
        runNowBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        runNowBtn.Text = "▶"
        runNowBtn.Parent = tile
        local rnbCorn = Instance.new("UICorner")
        rnbCorn.CornerRadius = UDim.new(1, 0)
        rnbCorn.Parent = runNowBtn

        -- Connect Play Button
        runNowBtn.MouseButton1Click:Connect(function()
            task.spawn(executeActions, taskObj, {})
            if showToastNotification then
                showToastNotification("Shortcut Executed", string.format("Ran '%s' (%d action%s)", taskObj.name, #(taskObj.actions or {}), #(taskObj.actions or {}) == 1 and "" or "s"), 2.5)
            end
        end)

        -- Connect Toggle Button
        statusPill.MouseButton1Click:Connect(function()
            taskObj.enabled = not taskObj.enabled
            if taskObj.enabled then
                Engine.bindTask(taskObj)
            else
                Engine.unbindTask(taskObj.id)
            end
            Storage.save(true)
            renderShortcutTile(taskObj, idx)
        end)

        -- Connect Export Button
        cardExport.MouseButton1Click:Connect(function()
            exportTaskToJson(taskObj)
        end)

        -- Connect Delete Button
        cardDelete.MouseButton1Click:Connect(function()
            Engine.unbindTask(taskObj.id)
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
            tile:Destroy()
            cachedTiles[taskObj.id] = nil
            if refreshShortcutsGrid then refreshShortcutsGrid() end
        end)

        -- Click tile to open Block Stack Editor
        tile.MouseButton1Click:Connect(function()
            openShortcutEditor(taskObj)
        end)

        cachedTiles[taskObj.id] = tile
    end

    tile.LayoutOrder = idx
    tile.BackgroundColor3 = colorTheme.bg
    local tStroke = tile:FindFirstChildOfClass("UIStroke")
    if tStroke then tStroke.Color = colorTheme.stroke end

    local iconGlyph = tile:FindFirstChild("IconBadge") and tile.IconBadge:FindFirstChild("IconGlyph")
    if iconGlyph then iconGlyph.Text = taskObj.icon or "⚡" end

    local nameLbl = tile:FindFirstChild("NameLbl")
    if nameLbl then nameLbl.Text = taskObj.name or "Untitled Shortcut" end

    local statusPill = tile:FindFirstChild("StatusPill")
    if statusPill then
        statusPill.Text = taskObj.enabled and "● Active" or "○ Off"
        statusPill.TextColor3 = taskObj.enabled and Color3.fromRGB(140, 255, 180) or Color3.fromRGB(210, 215, 225)
    end

    local scopeChip = tile:FindFirstChild("ScopeChip")
    if scopeChip then
        scopeChip.Text = (taskObj.scope == "universal") and "🌐 UNIVERSAL" or "📍 PLACE"
    end

    local summaryLbl = tile:FindFirstChild("SummaryLbl")
    if summaryLbl then
        local trig = taskObj.trigger or {}
        local trigStr = "Trigger"
        if trig.type == "Timer" then
            trigStr = string.format("⏱ Every %ds", trig.interval or 60)
        elseif trig.type == "ClockInterval" then
            trigStr = string.format("🕒 clock: %0.1fs", tonumber(trig.interval) or 5)
        elseif trig.type == "ClockTarget" then
            trigStr = string.format("⏰ clock >= %ds", tonumber(trig.target) or 0)
        elseif trig.type == "Signal" then
            trigStr = string.format("⚡ %s", trig.preset or "Signal")
        elseif trig.type == "Keybind" then
            trigStr = string.format("⌨️ Key [%s]", tostring(trig.key or "G"):upper())
        else
            trigStr = "⚡ Custom"
        end
        local actCount = #(taskObj.actions or {})
        summaryLbl.Text = string.format("%s • %d Action%s", trigStr, actCount, actCount == 1 and "" or "s")
        summaryLbl.TextColor3 = colorTheme.sub
    end

    tile.Visible = true
    return tile
end

refreshShortcutsGrid = function()
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
            renderShortcutTile(t, i)
            visibleCount = visibleCount + 1
        else
            local c = cachedTiles[t.id]
            if c then c.Visible = false end
        end
    end

    for id, c in pairs(cachedTiles) do
        if not seen[id] then
            c:Destroy()
            cachedTiles[id] = nil
        end
    end

    ShortcutsEmpty.Visible = (visibleCount == 0)
end

SearchBox:GetPropertyChangedSignal("Text"):Connect(refreshShortcutsGrid)

-- Render Gallery Cards
local function buildGalleryCards()
    for i, recipe in ipairs(GALLERY_RECIPES) do
        local card = Instance.new("Frame")
        card.Name = recipe.id
        card.Size = UDim2.new(0, 350, 0, 132)
        card.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
        card.BorderSizePixel = 0
        card.LayoutOrder = i
        card.Parent = GalleryScroll

        local cCorner = Instance.new("UICorner")
        cCorner.CornerRadius = UDim.new(0, 10)
        cCorner.Parent = card

        local cStroke = Instance.new("UIStroke")
        cStroke.Thickness = 1
        cStroke.Color = Color3.fromRGB(42, 50, 70)
        cStroke.Parent = card

        -- Left icon badge with theme color
        local col = SHORTCUT_COLORS[recipe.color] or SHORTCUT_COLORS.blue
        local iconBox = Instance.new("Frame")
        iconBox.Size = UDim2.new(0, 36, 0, 36)
        iconBox.Position = UDim2.new(0, 12, 0, 12)
        iconBox.BackgroundColor3 = col.bg
        iconBox.BorderSizePixel = 0
        iconBox.Parent = card
        local ibCorn = Instance.new("UICorner")
        ibCorn.CornerRadius = UDim.new(0, 8)
        ibCorn.Parent = iconBox

        local ibLbl = Instance.new("TextLabel")
        ibLbl.Size = UDim2.new(1, 0, 1, 0)
        ibLbl.BackgroundTransparency = 1
        ibLbl.Font = Enum.Font.GothamBold
        ibLbl.TextSize = 18
        ibLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
        ibLbl.Text = recipe.icon or "⚡"
        ibLbl.Parent = iconBox

        local titleLbl = Instance.new("TextLabel")
        titleLbl.Size = UDim2.new(1, -140, 0, 20)
        titleLbl.Position = UDim2.new(0, 56, 0, 12)
        titleLbl.BackgroundTransparency = 1
        titleLbl.Font = Enum.Font.GothamBold
        titleLbl.TextSize = 13
        titleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
        titleLbl.TextXAlignment = Enum.TextXAlignment.Left
        titleLbl.Text = recipe.name
        titleLbl.Parent = card

        local descLbl = Instance.new("TextLabel")
        descLbl.Size = UDim2.new(1, -24, 0, 30)
        descLbl.Position = UDim2.new(0, 12, 0, 52)
        descLbl.BackgroundTransparency = 1
        descLbl.Font = Enum.Font.Gotham
        descLbl.TextSize = 10
        descLbl.TextColor3 = Color3.fromRGB(150, 165, 190)
        descLbl.TextXAlignment = Enum.TextXAlignment.Left
        descLbl.TextYAlignment = Enum.TextYAlignment.Top
        descLbl.TextWrapped = true
        descLbl.Text = recipe.description
        descLbl.Parent = card

        -- Pipeline preview chip
        local previewChip = Instance.new("TextLabel")
        previewChip.Size = UDim2.new(1, -120, 0, 22)
        previewChip.Position = UDim2.new(0, 12, 1, -32)
        previewChip.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
        previewChip.BorderSizePixel = 0
        previewChip.Font = Enum.Font.GothamBold
        previewChip.TextSize = 9
        previewChip.TextColor3 = Color3.fromRGB(160, 210, 255)
        previewChip.TextXAlignment = Enum.TextXAlignment.Left
        previewChip.Text = string.format("  ⚙ %s ➔ %d Action%s", recipe.trigger.type, #(recipe.actions or {}), #(recipe.actions or {}) == 1 and "" or "s")
        previewChip.Parent = card
        local pcCorn = Instance.new("UICorner")
        pcCorn.CornerRadius = UDim.new(0, 6)
        pcCorn.Parent = previewChip

        -- + Get Shortcut button
        local getBtn = Instance.new("TextButton")
        getBtn.Name = "GetBtn"
        getBtn.Size = UDim2.new(0, 96, 0, 26)
        getBtn.Position = UDim2.new(1, -108, 1, -34)
        getBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
        getBtn.BorderSizePixel = 0
        getBtn.Font = Enum.Font.GothamBold
        getBtn.TextSize = 10
        getBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        getBtn.Text = "+ Get Shortcut"
        getBtn.Parent = card
        local gbCorn = Instance.new("UICorner")
        gbCorn.CornerRadius = UDim.new(0, 6)
        gbCorn.Parent = getBtn

        getBtn.MouseButton1Click:Connect(function()
            local newId = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(100, 999))
            local cloned = {
                id = newId,
                name = recipe.name,
                description = recipe.description,
                icon = recipe.icon or "⚡",
                color = recipe.color or "blue",
                enabled = true,
                scope = recipe.scope or "universal",
                trigger = HttpService:JSONDecode(HttpService:JSONEncode(recipe.trigger)),
                condition = HttpService:JSONDecode(HttpService:JSONEncode(recipe.condition)),
                actions = HttpService:JSONDecode(HttpService:JSONEncode(recipe.actions)),
                telemetry = { invocations = 0, lastRun = 0, lastResult = "Ready" }
            }

            if cloned.scope == "universal" then
                Storage.data.universal = Storage.data.universal or {}
                table.insert(Storage.data.universal, cloned)
            else
                local placeIdStr = tostring(game.PlaceId or "0")
                Storage.data.places[placeIdStr] = Storage.data.places[placeIdStr] or {}
                table.insert(Storage.data.places[placeIdStr], cloned)
            end

            Engine.bindTask(cloned)
            Storage.save(true)

            if showToastNotification then
                showToastNotification("Added to Shortcuts", string.format("Installed '%s' recipe", cloned.name), 3.0)
            end

            switchToTab("shortcuts")
        end)
    end
end

buildGalleryCards()

-- ==============================================================================
-- 5. VISUAL MULTI-ACTION BLOCK STACK BUILDER (Apple Shortcuts Editor)
-- ==============================================================================
local BuilderModal = Instance.new("Frame")
BuilderModal.Name = "BuilderModal"
BuilderModal.Size = UDim2.new(1, -16, 1, -16)
BuilderModal.Position = UDim2.new(0.5, 0, 0.5, 0)
BuilderModal.AnchorPoint = Vector2.new(0.5, 0.5)
BuilderModal.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
BuilderModal.BorderSizePixel = 0
BuilderModal.Visible = false
BuilderModal.ZIndex = 200
BuilderModal.Parent = MainFrame

local bmCorner = Instance.new("UICorner")
bmCorner.CornerRadius = UDim.new(0, 10)
bmCorner.Parent = BuilderModal

local bmStroke = Instance.new("UIStroke")
bmStroke.Thickness = 1.5
bmStroke.Color = Color3.fromRGB(0, 122, 255)
bmStroke.Parent = BuilderModal

-- Builder Header Bar
local BuilderHeader = Instance.new("Frame")
BuilderHeader.Name = "BuilderHeader"
BuilderHeader.Size = UDim2.new(1, 0, 0, 42)
BuilderHeader.BackgroundColor3 = Color3.fromRGB(22, 27, 40)
BuilderHeader.BorderSizePixel = 0
BuilderHeader.ZIndex = 201
BuilderHeader.Parent = BuilderModal
local bhCorner = Instance.new("UICorner")
bhCorner.CornerRadius = UDim.new(0, 10)
bhCorner.Parent = BuilderHeader

local BuilderTitle = Instance.new("TextLabel")
BuilderTitle.Size = UDim2.new(0, 180, 1, 0)
BuilderTitle.Position = UDim2.new(0, 16, 0, 0)
BuilderTitle.BackgroundTransparency = 1
BuilderTitle.Font = Enum.Font.GothamBold
BuilderTitle.TextSize = 13
BuilderTitle.TextColor3 = Color3.fromRGB(240, 245, 255)
BuilderTitle.TextXAlignment = Enum.TextXAlignment.Left
BuilderTitle.Text = "Shortcut Pipeline Editor"
BuilderTitle.ZIndex = 202
BuilderTitle.Parent = BuilderHeader

local BuilderScopeBtn = Instance.new("TextButton")
BuilderScopeBtn.Name = "BuilderScopeBtn"
BuilderScopeBtn.Size = UDim2.new(0, 140, 0, 26)
BuilderScopeBtn.Position = UDim2.new(0, 200, 0.5, -13)
BuilderScopeBtn.BackgroundColor3 = Color3.fromRGB(35, 30, 50)
BuilderScopeBtn.BorderSizePixel = 0
BuilderScopeBtn.Font = Enum.Font.GothamBold
BuilderScopeBtn.TextSize = 10
BuilderScopeBtn.TextColor3 = Color3.fromRGB(210, 140, 255)
BuilderScopeBtn.Text = "Scope: Place-Specific"
BuilderScopeBtn.ZIndex = 202
BuilderScopeBtn.Parent = BuilderHeader
local bscCorn = Instance.new("UICorner")
bscCorn.CornerRadius = UDim.new(0, 6)
bscCorn.Parent = BuilderScopeBtn

local BuilderCancelBtn = Instance.new("TextButton")
BuilderCancelBtn.Name = "BuilderCancelBtn"
BuilderCancelBtn.Size = UDim2.new(0, 74, 0, 26)
BuilderCancelBtn.Position = UDim2.new(1, -210, 0.5, -13)
BuilderCancelBtn.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
BuilderCancelBtn.BorderSizePixel = 0
BuilderCancelBtn.Font = Enum.Font.GothamBold
BuilderCancelBtn.TextSize = 11
BuilderCancelBtn.TextColor3 = Color3.fromRGB(200, 210, 230)
BuilderCancelBtn.Text = "Cancel"
BuilderCancelBtn.ZIndex = 202
BuilderCancelBtn.Parent = BuilderHeader
local bcbCorn = Instance.new("UICorner")
bcbCorn.CornerRadius = UDim.new(0, 6)
bcbCorn.Parent = BuilderCancelBtn

local BuilderSaveBtn = Instance.new("TextButton")
BuilderSaveBtn.Name = "BuilderSaveBtn"
BuilderSaveBtn.Size = UDim2.new(0, 120, 0, 26)
BuilderSaveBtn.Position = UDim2.new(1, -128, 0.5, -13)
BuilderSaveBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
BuilderSaveBtn.BorderSizePixel = 0
BuilderSaveBtn.Font = Enum.Font.GothamBold
BuilderSaveBtn.TextSize = 11
BuilderSaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
BuilderSaveBtn.Text = "Save Shortcut"
BuilderSaveBtn.ZIndex = 202
BuilderSaveBtn.Parent = BuilderHeader
local bsbCorn = Instance.new("UICorner")
bsbCorn.CornerRadius = UDim.new(0, 6)
bsbCorn.Parent = BuilderSaveBtn

-- Builder Scroll Body
local BuilderScroll = Instance.new("ScrollingFrame")
BuilderScroll.Name = "BuilderScroll"
BuilderScroll.Size = UDim2.new(1, -24, 1, -54)
BuilderScroll.Position = UDim2.new(0, 12, 0, 48)
BuilderScroll.BackgroundTransparency = 1
BuilderScroll.BorderSizePixel = 0
BuilderScroll.ScrollBarThickness = 5
BuilderScroll.ScrollBarImageColor3 = Color3.fromRGB(60, 75, 100)
BuilderScroll.CanvasSize = UDim2.new(0, 0, 0, 700)
BuilderScroll.ZIndex = 201
BuilderScroll.Parent = BuilderModal

local BuilderLayout = Instance.new("UIListLayout")
BuilderLayout.SortOrder = Enum.SortOrder.LayoutOrder
BuilderLayout.Padding = UDim.new(0, 12)
BuilderLayout.Parent = BuilderScroll

BuilderLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    BuilderScroll.CanvasSize = UDim2.new(0, 0, 0, BuilderLayout.AbsoluteContentSize.Y + 30)
end)

-- Helper to make text inputs
local function createBuilderInput(name, placeholder, sizeX, sizeY, parent)
    local tb = Instance.new("TextBox")
    tb.Name = name
    tb.Size = sizeX
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
    tb.ZIndex = 202
    tb.Parent = parent
    local tbc = Instance.new("UICorner")
    tbc.CornerRadius = UDim.new(0, 6)
    tbc.Parent = tb
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = tb
    return tb
end

-- ==========================================
-- Builder Section 1: Details & Customization
-- ==========================================
local CardDetails = Instance.new("Frame")
CardDetails.Name = "CardDetails"
CardDetails.Size = UDim2.new(1, 0, 0, 114)
CardDetails.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
CardDetails.BorderSizePixel = 0
CardDetails.LayoutOrder = 1
CardDetails.ZIndex = 202
CardDetails.Parent = BuilderScroll
local cdCorn = Instance.new("UICorner")
cdCorn.CornerRadius = UDim.new(0, 8)
cdCorn.Parent = CardDetails

local InputName = createBuilderInput("InputName", "Shortcut Name (e.g. Anti-AFK Ghost)", UDim2.new(0.55, -12, 0, 28), UDim2.new(0, 28), CardDetails)
InputName.Position = UDim2.new(0, 10, 0, 10)

local InputDesc = createBuilderInput("InputDesc", "Description / Notes", UDim2.new(0.45, -16, 0, 28), UDim2.new(0, 28), CardDetails)
InputDesc.Position = UDim2.new(0.55, 6, 0, 10)

-- Color Picker Swatches Row
local ColorRow = Instance.new("Frame")
ColorRow.Name = "ColorRow"
ColorRow.Size = UDim2.new(0.55, -12, 0, 26)
ColorRow.Position = UDim2.new(0, 10, 0, 46)
ColorRow.BackgroundTransparency = 1
ColorRow.ZIndex = 202
ColorRow.Parent = CardDetails

local colorButtons = {}
local selectedColor = "blue"

for i, colName in ipairs(COLOR_ORDER) do
    local cTheme = SHORTCUT_COLORS[colName]
    local btn = Instance.new("TextButton")
    btn.Name = "ColorBtn_" .. colName
    btn.Size = UDim2.new(0, 24, 0, 24)
    btn.Position = UDim2.new(0, (i - 1) * 28, 0, 1)
    btn.BackgroundColor3 = cTheme.bg
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.ZIndex = 203
    btn.Parent = ColorRow
    local bCorn = Instance.new("UICorner")
    bCorn.CornerRadius = UDim.new(1, 0)
    bCorn.Parent = btn

    local bStroke = Instance.new("UIStroke")
    bStroke.Thickness = 2
    bStroke.Color = Color3.fromRGB(255, 255, 255)
    bStroke.Transparency = (colName == selectedColor) and 0 or 1
    bStroke.Parent = btn

    btn.MouseButton1Click:Connect(function()
        selectedColor = colName
        for cN, b in pairs(colorButtons) do
            local st = b:FindFirstChildOfClass("UIStroke")
            if st then st.Transparency = (cN == selectedColor) and 0 or 1 end
        end
    end)
    colorButtons[colName] = btn
end

-- Icon Picker Row
local IconRow = Instance.new("Frame")
IconRow.Name = "IconRow"
IconRow.Size = UDim2.new(1, -20, 0, 28)
IconRow.Position = UDim2.new(0, 10, 0, 78)
IconRow.BackgroundTransparency = 1
IconRow.ZIndex = 202
IconRow.Parent = CardDetails

local iconButtons = {}
local selectedIcon = "⚡"

for i, ic in ipairs(SHORTCUT_ICONS) do
    local btn = Instance.new("TextButton")
    btn.Name = "IconBtn_" .. tostring(i)
    btn.Size = UDim2.new(0, 26, 0, 26)
    btn.Position = UDim2.new(0, (i - 1) * 30, 0, 1)
    btn.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Text = ic
    btn.ZIndex = 203
    btn.Parent = IconRow
    local bCorn = Instance.new("UICorner")
    bCorn.CornerRadius = UDim.new(0, 6)
    bCorn.Parent = btn

    local bStroke = Instance.new("UIStroke")
    bStroke.Thickness = 1.5
    bStroke.Color = Color3.fromRGB(0, 122, 255)
    bStroke.Transparency = (ic == selectedIcon) and 0 or 1
    bStroke.Parent = btn

    btn.MouseButton1Click:Connect(function()
        selectedIcon = ic
        for icN, b in pairs(iconButtons) do
            local st = b:FindFirstChildOfClass("UIStroke")
            if st then st.Transparency = (icN == selectedIcon) and 0 or 1 end
        end
    end)
    iconButtons[ic] = btn
end

-- ==========================================
-- Builder Section 2: When & If (Trigger & Condition)
-- ==========================================
local CardRules = Instance.new("Frame")
CardRules.Name = "CardRules"
CardRules.Size = UDim2.new(1, 0, 0, 80)
CardRules.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
CardRules.BorderSizePixel = 0
CardRules.LayoutOrder = 2
CardRules.ZIndex = 202
CardRules.Parent = BuilderScroll
local crCorn = Instance.new("UICorner")
crCorn.CornerRadius = UDim.new(0, 8)
crCorn.Parent = CardRules

-- Options definitions
local TRIGGER_OPTIONS = {
    { label = "⏱ Timer (task.wait)", type = "Timer", placeholder = "Interval sec (e.g. 60)", defaultParam = "60" },
    { label = "🕒 Clock Interval (os.clock)", type = "ClockInterval", placeholder = "Interval sec (e.g. 5.0)", defaultParam = "5.0" },
    { label = "⏰ Clock Target (os.clock >= T)", type = "ClockTarget", placeholder = "Target os.clock uptime (e.g. 120)", defaultParam = "120" },
    { label = "⚡ Seated in Vehicle", type = "Signal", preset = "Seated", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Player Added", type = "Signal", preset = "PlayerAdded", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Player Removing", type = "Signal", preset = "PlayerRemoving", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Character Added", type = "Signal", preset = "CharacterAdded", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Character Died", type = "Signal", preset = "Died", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚡ Window Focus Lost", type = "Signal", preset = "WindowFocus", placeholder = "No parameter needed", defaultParam = "" },
    { label = "💤 LocalPlayer Idled", type = "Signal", preset = "Idled", placeholder = "No parameter needed", defaultParam = "" },
    { label = "⚙️ Custom Signal Path", type = "CustomSignal", placeholder = "Signal expr (e.g. workspace.ChildAdded)", defaultParam = "workspace.ChildAdded" },
    { label = "⌨️ Keybind Press", type = "Keybind", placeholder = "Key (e.g. G, H, Z, LeftAlt)", defaultParam = "G" },
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

local curTrigIdx = 1
local curCondIdx = 1

local TriggerBtn = Instance.new("TextButton")
TriggerBtn.Name = "TriggerBtn"
TriggerBtn.Size = UDim2.new(0.5, -14, 0, 28)
TriggerBtn.Position = UDim2.new(0, 10, 0, 10)
TriggerBtn.BackgroundColor3 = Color3.fromRGB(30, 42, 65)
TriggerBtn.BorderSizePixel = 0
TriggerBtn.Font = Enum.Font.GothamBold
TriggerBtn.TextSize = 10
TriggerBtn.TextColor3 = Color3.fromRGB(120, 200, 255)
TriggerBtn.Text = "WHEN: " .. TRIGGER_OPTIONS[1].label
TriggerBtn.ZIndex = 203
TriggerBtn.Parent = CardRules
local tbCorn2 = Instance.new("UICorner")
tbCorn2.CornerRadius = UDim.new(0, 6)
tbCorn2.Parent = TriggerBtn

local InputTriggerParam = createBuilderInput("InputTriggerParam", "Interval sec (e.g. 60)", UDim2.new(0.5, -14, 0, 26), UDim2.new(0, 26), CardRules)
InputTriggerParam.Position = UDim2.new(0, 10, 0, 44)
InputTriggerParam.Text = "60"

local ConditionBtn = Instance.new("TextButton")
ConditionBtn.Name = "ConditionBtn"
ConditionBtn.Size = UDim2.new(0.5, -14, 0, 28)
ConditionBtn.Position = UDim2.new(0.5, 4, 0, 10)
ConditionBtn.BackgroundColor3 = Color3.fromRGB(26, 48, 40)
ConditionBtn.BorderSizePixel = 0
ConditionBtn.Font = Enum.Font.GothamBold
ConditionBtn.TextSize = 10
ConditionBtn.TextColor3 = Color3.fromRGB(110, 230, 170)
ConditionBtn.Text = "IF: " .. CONDITION_OPTIONS[1].label
ConditionBtn.ZIndex = 203
ConditionBtn.Parent = CardRules
local cbCorn2 = Instance.new("UICorner")
cbCorn2.CornerRadius = UDim.new(0, 6)
cbCorn2.Parent = ConditionBtn

local InputConditionParam = createBuilderInput("InputConditionParam", "Always evaluates true", UDim2.new(0.5, -14, 0, 26), UDim2.new(0, 26), CardRules)
InputConditionParam.Position = UDim2.new(0.5, 4, 0, 44)

TriggerBtn.MouseButton1Click:Connect(function()
    curTrigIdx = (curTrigIdx % #TRIGGER_OPTIONS) + 1
    local opt = TRIGGER_OPTIONS[curTrigIdx]
    TriggerBtn.Text = "WHEN: " .. opt.label
    InputTriggerParam.PlaceholderText = opt.placeholder
    InputTriggerParam.Text = opt.defaultParam
end)

ConditionBtn.MouseButton1Click:Connect(function()
    curCondIdx = (curCondIdx % #CONDITION_OPTIONS) + 1
    local opt = CONDITION_OPTIONS[curCondIdx]
    ConditionBtn.Text = "IF: " .. opt.label
    InputConditionParam.PlaceholderText = opt.placeholder
    InputConditionParam.Text = opt.defaultParam
end)

-- ==========================================
-- Builder Section 3: Sequential Action Stack
-- ==========================================
local PipelineHeader = Instance.new("Frame")
PipelineHeader.Name = "PipelineHeader"
PipelineHeader.Size = UDim2.new(1, 0, 0, 32)
PipelineHeader.BackgroundTransparency = 1
PipelineHeader.LayoutOrder = 3
PipelineHeader.ZIndex = 202
PipelineHeader.Parent = BuilderScroll

local phTitle = Instance.new("TextLabel")
phTitle.Size = UDim2.new(0, 250, 1, 0)
phTitle.Position = UDim2.new(0, 4, 0, 0)
phTitle.BackgroundTransparency = 1
phTitle.Font = Enum.Font.GothamBold
phTitle.TextSize = 12
phTitle.TextColor3 = Color3.fromRGB(220, 230, 250)
phTitle.TextXAlignment = Enum.TextXAlignment.Left
phTitle.Text = "ACTIONS PIPELINE (Sequential Execution)"
phTitle.ZIndex = 202
phTitle.Parent = PipelineHeader

local AddActionBtn = Instance.new("TextButton")
AddActionBtn.Name = "AddActionBtn"
AddActionBtn.Size = UDim2.new(0, 110, 0, 26)
AddActionBtn.Position = UDim2.new(1, -114, 0, 2)
AddActionBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
AddActionBtn.BorderSizePixel = 0
AddActionBtn.Font = Enum.Font.GothamBold
AddActionBtn.TextSize = 10
AddActionBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AddActionBtn.Text = "+ Add Action"
AddActionBtn.ZIndex = 203
AddActionBtn.Parent = PipelineHeader
local aabCorn = Instance.new("UICorner")
aabCorn.CornerRadius = UDim.new(0, 6)
aabCorn.Parent = AddActionBtn

-- Action Stack Container
local ActionStack = Instance.new("Frame")
ActionStack.Name = "ActionStack"
ActionStack.Size = UDim2.new(1, 0, 0, 0)
ActionStack.BackgroundTransparency = 1
ActionStack.LayoutOrder = 4
ActionStack.ZIndex = 202
ActionStack.Parent = BuilderScroll

local ActionStackLayout = Instance.new("UIListLayout")
ActionStackLayout.SortOrder = Enum.SortOrder.LayoutOrder
ActionStackLayout.Padding = UDim.new(0, 8)
ActionStackLayout.Parent = ActionStack

ActionStackLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    ActionStack.Size = UDim2.new(1, 0, 0, ActionStackLayout.AbsoluteContentSize.Y)
end)

-- Action Primitive Definitions
local ACTION_PRIMITIVES = {
    { type = "SetVariable", name = "Set Variable", icon = "📦", cat = "Variables", def = { varName = "MyVar", value = "$input" } },
    { type = "Wait", name = "Wait (Delay)", icon = "⏱️", cat = "Flow", def = { duration = 1.0 } },
    { type = "Repeat", name = "Repeat (Loop)", icon = "🔂", cat = "Control", def = { count = 3 } },
    { type = "ForEach", name = "For Each Item", icon = "🔄", cat = "Control", def = { target = "workspace", varName = "item" } },
    { type = "If", name = "If Condition", icon = "❓", cat = "Control", def = { left = "$input", op = "==", right = "" } },
    { type = "EndBlock", name = "End Block (Loop/If)", icon = "🔚", cat = "Control", def = {} },
    { type = "Print", name = "Print to Console", icon = "🖨️", cat = "Flow", def = { message = "Value is: $MyVar" } },
    { type = "Toast", name = "Toast Alert", icon = "🔔", cat = "Flow", def = { title = "Alert", message = "Notice: $MyVar" } },
    { type = "TweenTo", name = "Tween To (CFrame)", icon = "📍", cat = "Navigation", def = { target = "0, 10, 0", duration = 2.0 } },
    { type = "InstantTeleport", name = "Instant Teleport", icon = "⚡", cat = "Navigation", def = { target = "0, 10, 0" } },
    { type = "PathfindTo", name = "Pathfind To", icon = "🗺️", cat = "Navigation", def = { target = "$nearest", stopDistance = 4 } },
    { type = "FindNearest", name = "Find Nearest", icon = "🧭", cat = "World", def = { source = "Players", varName = "nearest", maxDistance = 500 } },
    { type = "ResetCharacter", name = "Reset Character", icon = "💀", cat = "Player", def = {} },
    { type = "FollowRoute", name = "Follow Route", icon = "🚶", cat = "Navigation", def = { targetNode = "Yard", route = "road_network.json" } },
    { type = "StopRoute", name = "Stop Route", icon = "🛑", cat = "Navigation", def = {} },
    { type = "ActivatePrompt", name = "Activate Prompt", icon = "🎯", cat = "Interaction", def = { target = "nearest", maxDistance = 35 } },
    { type = "VirtualInput", name = "Virtual Keypress", icon = "⌨️", cat = "Interaction", def = { key = "E", duration = 0.1 } },
    { type = "VirtualPoke", name = "Virtual Poke (Anti-AFK)", icon = "👻", cat = "Interaction", def = {} },
    { type = "FireRemote", name = "Fire Remote Event", icon = "📡", cat = "Network", def = { remote = "ReplicatedStorage.RemoteEvent", args = '["$position"]' } },
    { type = "InvokeServer", name = "Invoke Remote Func", icon = "📥", cat = "Network", def = { remote = "ReplicatedStorage.RemoteFunction", args = '["$userId"]' } },
    { type = "EquipTool", name = "Equip Tool", icon = "🎒", cat = "Player", def = { toolName = "first" } },
    { type = "UseTool", name = "Use / Click Tool", icon = "✋", cat = "Player", def = { action = "activate" } },
    { type = "ClickGuiButton", name = "Click UI Button", icon = "🖱️", cat = "Interaction", def = { target = "Accept" } },
    { type = "SendChat", name = "Send Chat", icon = "💬", cat = "Flow", def = { message = "Hello from Shortcut!" } },
    { type = "SetCharacterState", name = "Set Character State", icon = "⚡", cat = "Player", def = { property = "WalkSpeed", value = "32" } },
    { type = "LookAt", name = "Look At Target", icon = "👀", cat = "Navigation", def = { target = "$nearest" } },
    { type = "PlaySound", name = "Play Sound Chime", icon = "🔊", cat = "Flow", def = { sound = "Success", volume = 1.0 } },
    { type = "HighlightInstance", name = "Highlight (ESP / Chams)", icon = "✨", cat = "World", def = { target = "$nearest", color = "cyan", duration = 10 } },
    { type = "SendWebhook", name = "Send Discord Webhook", icon = "🌐", cat = "Network", def = { url = "https://discord.com/api/webhooks/...", message = "Alert from $player", title = "Omni Alert" } },
    { type = "SetClipboard", name = "Copy to Clipboard", icon = "📋", cat = "Flow", def = { text = "$player at $position" } },
    { type = "PlayAnimation", name = "Play Emote / Animation", icon = "💃", cat = "Player", def = { animation = "dance", action = "play" } },
    { type = "Spectate", name = "Spectate Target", icon = "🎥", cat = "Navigation", def = { target = "$nearest" } },
    { type = "ResetCamera", name = "Reset Camera View", icon = "🔄", cat = "Navigation", def = {} },
    { type = "PauseAllLoops", name = "Pause All Loops", icon = "⏸️", cat = "Flow", def = {} },
    { type = "ResumeAllLoops", name = "Resume All Loops", icon = "▶️", cat = "Flow", def = {} },
    { type = "Rejoin", name = "Rejoin Server", icon = "🔄", cat = "Flow", def = {} },
    { type = "ServerHop", name = "Server Hop", icon = "🌐", cat = "Flow", def = {} },
    { type = "RunLuau", name = "Run Luau Code", icon = "💻", cat = "Flow", def = { code = "print('Executed step!')" } },
}

-- Current Builder State
local builderState = {
    editingTask = nil,
    scope = "place",
    actions = {}
}

local renderActionStack -- forward declaration

renderActionStack = function()
    -- Clear current stack
    for _, ch in ipairs(ActionStack:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end

    if #builderState.actions == 0 then
        local emptyCard = Instance.new("Frame")
        emptyCard.Size = UDim2.new(1, 0, 0, 48)
        emptyCard.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
        emptyCard.BorderSizePixel = 0
        emptyCard.ZIndex = 202
        emptyCard.Parent = ActionStack
        local ecCorn = Instance.new("UICorner")
        ecCorn.CornerRadius = UDim.new(0, 8)
        ecCorn.Parent = emptyCard

        local ecLbl = Instance.new("TextLabel")
        ecLbl.Size = UDim2.new(1, 0, 1, 0)
        ecLbl.BackgroundTransparency = 1
        ecLbl.Font = Enum.Font.Gotham
        ecLbl.TextSize = 11
        ecLbl.TextColor3 = Color3.fromRGB(140, 155, 180)
        ecLbl.Text = "No actions in pipeline. Click '+ Add Action' above to add a step."
        ecLbl.ZIndex = 203
        ecLbl.Parent = emptyCard
        return
    end

    for idx, act in ipairs(builderState.actions) do
        local isLuau = (act.type == "RunLuau")
        local blockH = isLuau and 96 or 58

        local block = Instance.new("Frame")
        block.Name = "Block_" .. tostring(idx)
        block.Size = UDim2.new(1, 0, 0, blockH)
        block.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
        block.BorderSizePixel = 0
        block.LayoutOrder = idx
        block.ZIndex = 202
        block.Parent = ActionStack
        local bCorn = Instance.new("UICorner")
        bCorn.CornerRadius = UDim.new(0, 8)
        bCorn.Parent = block

        local bStroke = Instance.new("UIStroke")
        bStroke.Thickness = 1
        bStroke.Color = Color3.fromRGB(45, 55, 78)
        bStroke.Parent = block

        -- Step Number Badge
        local stepBadge = Instance.new("Frame")
        stepBadge.Size = UDim2.new(0, 22, 0, 22)
        stepBadge.Position = UDim2.new(0, 8, 0, 8)
        stepBadge.BackgroundColor3 = Color3.fromRGB(0, 122, 255)
        stepBadge.BorderSizePixel = 0
        stepBadge.ZIndex = 203
        stepBadge.Parent = block
        local sbCorn = Instance.new("UICorner")
        sbCorn.CornerRadius = UDim.new(1, 0)
        sbCorn.Parent = stepBadge

        local sbLbl = Instance.new("TextLabel")
        sbLbl.Size = UDim2.new(1, 0, 1, 0)
        sbLbl.BackgroundTransparency = 1
        sbLbl.Font = Enum.Font.GothamBold
        sbLbl.TextSize = 10
        sbLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
        sbLbl.Text = tostring(idx)
        sbLbl.ZIndex = 204
        sbLbl.Parent = stepBadge

        -- Action Type Label
        local actNameLbl = Instance.new("TextLabel")
        actNameLbl.Size = UDim2.new(0, 140, 0, 22)
        actNameLbl.Position = UDim2.new(0, 36, 0, 8)
        actNameLbl.BackgroundTransparency = 1
        actNameLbl.Font = Enum.Font.GothamBold
        actNameLbl.TextSize = 11
        actNameLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
        actNameLbl.TextXAlignment = Enum.TextXAlignment.Left
        actNameLbl.Text = tostring(act.type)
        actNameLbl.ZIndex = 203
        actNameLbl.Parent = block

        -- Reorder & Delete controls (Right side)
        local btnUp = Instance.new("TextButton")
        btnUp.Size = UDim2.new(0, 22, 0, 22)
        btnUp.Position = UDim2.new(1, -74, 0, 8)
        btnUp.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
        btnUp.BorderSizePixel = 0
        btnUp.Font = Enum.Font.GothamBold
        btnUp.TextSize = 10
        btnUp.TextColor3 = Color3.fromRGB(200, 215, 240)
        btnUp.Text = "▲"
        btnUp.ZIndex = 203
        btnUp.Parent = block
        local buCorn = Instance.new("UICorner")
        buCorn.CornerRadius = UDim.new(0, 4)
        buCorn.Parent = btnUp

        local btnDown = Instance.new("TextButton")
        btnDown.Size = UDim2.new(0, 22, 0, 22)
        btnDown.Position = UDim2.new(1, -48, 0, 8)
        btnDown.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
        btnDown.BorderSizePixel = 0
        btnDown.Font = Enum.Font.GothamBold
        btnDown.TextSize = 10
        btnDown.TextColor3 = Color3.fromRGB(200, 215, 240)
        btnDown.Text = "▼"
        btnDown.ZIndex = 203
        btnDown.Parent = block
        local bdCorn = Instance.new("UICorner")
        bdCorn.CornerRadius = UDim.new(0, 4)
        bdCorn.Parent = btnDown

        local btnDel = Instance.new("TextButton")
        btnDel.Size = UDim2.new(0, 22, 0, 22)
        btnDel.Position = UDim2.new(1, -22, 0, 8)
        btnDel.BackgroundColor3 = Color3.fromRGB(55, 25, 35)
        btnDel.BorderSizePixel = 0
        btnDel.Font = Enum.Font.GothamBold
        btnDel.TextSize = 10
        btnDel.TextColor3 = Color3.fromRGB(255, 120, 120)
        btnDel.Text = "✕"
        btnDel.ZIndex = 203
        btnDel.Parent = block
        local bdelCorn = Instance.new("UICorner")
        bdelCorn.CornerRadius = UDim.new(0, 4)
        bdelCorn.Parent = btnDel

        btnUp.MouseButton1Click:Connect(function()
            if idx > 1 then
                local tmp = builderState.actions[idx]
                builderState.actions[idx] = builderState.actions[idx - 1]
                builderState.actions[idx - 1] = tmp
                renderActionStack()
            end
        end)

        btnDown.MouseButton1Click:Connect(function()
            if idx < #builderState.actions then
                local tmp = builderState.actions[idx]
                builderState.actions[idx] = builderState.actions[idx + 1]
                builderState.actions[idx + 1] = tmp
                renderActionStack()
            end
        end)

        btnDel.MouseButton1Click:Connect(function()
            table.remove(builderState.actions, idx)
            renderActionStack()
        end)

                -- Inline parameter fields based on Action Type
        if act.type == "SetVariable" then
            local p1 = createBuilderInput("P1", "Var Name (e.g. Owner)", UDim2.new(0.24, -5, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.varName or "var")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.varName = p1.Text end)

            local eqLbl = Instance.new("TextLabel")
            eqLbl.Size = UDim2.new(0, 16, 0, 22)
            eqLbl.Position = UDim2.new(0.24, 180, 0, 8)
            eqLbl.BackgroundTransparency = 1
            eqLbl.Font = Enum.Font.GothamBold
            eqLbl.TextSize = 12
            eqLbl.TextColor3 = Color3.fromRGB(150, 170, 205)
            eqLbl.Text = "="
            eqLbl.ZIndex = 203
            eqLbl.Parent = block

            local p2 = createBuilderInput("P2", "Value / Expr (e.g. $input.Name)", UDim2.new(0.48, -10, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.24, 200, 0, 8)
            p2.Text = tostring(act.value or "$input")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.value = p2.Text end)
        elseif act.type == "Wait" or act.type == "Delay" then
            local p1 = createBuilderInput("P1", "Wait Duration seconds (e.g. 1.0)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.duration or 1.0)
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.duration = p1.Text end)
        elseif act.type == "Repeat" then
            local p1 = createBuilderInput("P1", "Count (e.g. 5)", UDim2.new(0.2, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.count or 3)
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.count = p1.Text end)

            local rLbl = Instance.new("TextLabel")
            rLbl.Size = UDim2.new(0.5, 0, 0, 22)
            rLbl.Position = UDim2.new(0.2, 190, 0, 8)
            rLbl.BackgroundTransparency = 1
            rLbl.Font = Enum.Font.Gotham
            rLbl.TextSize = 10
            rLbl.TextColor3 = Color3.fromRGB(140, 160, 190)
            rLbl.TextXAlignment = Enum.TextXAlignment.Left
            rLbl.Text = "times (actions run until End Block)"
            rLbl.ZIndex = 203
            rLbl.Parent = block
        elseif act.type == "ForEach" then
            local p1 = createBuilderInput("P1", "Item Var (e.g. item)", UDim2.new(0.2, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.varName or "item")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.varName = p1.Text end)

            local inLbl = Instance.new("TextLabel")
            inLbl.Size = UDim2.new(0, 20, 0, 22)
            inLbl.Position = UDim2.new(0.2, 185, 0, 8)
            inLbl.BackgroundTransparency = 1
            inLbl.Font = Enum.Font.GothamBold
            inLbl.TextSize = 10
            inLbl.TextColor3 = Color3.fromRGB(140, 160, 190)
            inLbl.Text = "in"
            inLbl.ZIndex = 203
            inLbl.Parent = block

            local p2 = createBuilderInput("P2", "Container (e.g. workspace.SpawnedCars)", UDim2.new(0.48, -10, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.2, 210, 0, 8)
            p2.Text = tostring(act.target or "workspace")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.target = p2.Text end)
        elseif act.type == "If" then
            local p1 = createBuilderInput("P1", "Left (e.g. $Owner)", UDim2.new(0.25, -5, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.left or "$input")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.left = p1.Text end)

            local opBtn = Instance.new("TextButton")
            opBtn.Size = UDim2.new(0, 40, 0, 22)
            opBtn.Position = UDim2.new(0.25, 180, 0, 8)
            opBtn.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
            opBtn.BorderSizePixel = 0
            opBtn.Font = Enum.Font.GothamBold
            opBtn.TextSize = 10
            opBtn.TextColor3 = Color3.fromRGB(100, 200, 255)
            opBtn.Text = tostring(act.op or "==")
            opBtn.ZIndex = 203
            opBtn.Parent = block
            local opc = Instance.new("UICorner")
            opc.CornerRadius = UDim.new(0, 4)
            opc.Parent = opBtn

            local OPS = { "==", "!=", ">", "<", ">=", "<=", "contains" }
            opBtn.MouseButton1Click:Connect(function()
                local cur = 1
                for oIdx, o in ipairs(OPS) do if o == act.op then cur = oIdx; break end end
                cur = (cur % #OPS) + 1
                act.op = OPS[cur]
                opBtn.Text = act.op
            end)

            local p2 = createBuilderInput("P2", "Right (e.g. $player)", UDim2.new(0.38, -10, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.25, 225, 0, 8)
            p2.Text = tostring(act.right or "")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.right = p2.Text end)
        elseif act.type == "EndBlock" or act.type == "EndRepeat" or act.type == "EndIf" then
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0.65, 0, 0, 22)
            lbl.Position = UDim2.new(0, 180, 0, 8)
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 10
            lbl.TextColor3 = Color3.fromRGB(130, 145, 175)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Text = "─── End of Repeat / If Block ───"
            lbl.ZIndex = 203
            lbl.Parent = block
        elseif act.type == "Print" then
            local p1 = createBuilderInput("P1", "Message to print (supports $vars)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.message or "Value is: $input")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.message = p1.Text end)
        elseif act.type == "Toast" then
            local p1 = createBuilderInput("P1", "Message (supports $vars)", UDim2.new(0.4, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.message or "Triggered")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.message = p1.Text end)

            local p2 = createBuilderInput("P2", "Title", UDim2.new(0.3, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.4, 175, 0, 8)
            p2.Text = tostring(act.title or "Scheduler")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.title = p2.Text end)
        elseif act.type == "TweenTo" then
            local p1 = createBuilderInput("P1", "Target Pos/Part (e.g. 0, 10, 0)", UDim2.new(0.55, -20, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "0, 10, 0")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)

            local p2 = createBuilderInput("P2", "Duration s", UDim2.new(0.2, -10, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.75, 5, 0, 8)
            p2.Text = tostring(act.duration or 2.0)
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.duration = tonumber(p2.Text) or 2.0 end)
        elseif act.type == "InstantTeleport" then
            local p1 = createBuilderInput("P1", "Target Pos/Part (e.g. 0, 10, 0)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "0, 10, 0")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)
        elseif act.type == "PathfindTo" then
            local p1 = createBuilderInput("P1", "Target ($nearest / Pos / Part)", UDim2.new(0.42, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "$nearest")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)

            local p2 = createBuilderInput("P2", "Stop Dist", UDim2.new(0.23, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.42, 175, 0, 8)
            p2.Text = tostring(act.stopDistance or 4)
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.stopDistance = tonumber(p2.Text) or 4 end)
        elseif act.type == "FindNearest" then
            local p1 = createBuilderInput("P1", "Source (e.g. Players, folder)", UDim2.new(0.38, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.source or "Players")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.source = p1.Text end)

            local p2 = createBuilderInput("P2", "Save to Var", UDim2.new(0.27, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.38, 175, 0, 8)
            p2.Text = tostring(act.varName or "nearest")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.varName = p2.Text end)
        elseif act.type == "ResetCharacter" then
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0.65, 0, 0, 22)
            lbl.Position = UDim2.new(0, 180, 0, 8)
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = 11
            lbl.TextColor3 = Color3.fromRGB(150, 165, 190)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Text = "Resets character (respawns at spawn point)"
            lbl.ZIndex = 203
            lbl.Parent = block
        elseif act.type == "EquipTool" then
            local p1 = createBuilderInput("P1", "Tool Name (or 'first')", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.toolName or "first")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.toolName = p1.Text end)
        elseif act.type == "UseTool" then
            local p1 = createBuilderInput("P1", "Action (activate / unequip)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.action or "activate")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.action = p1.Text end)
        elseif act.type == "ClickGuiButton" then
            local p1 = createBuilderInput("P1", "Button Name / Text / Path", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "Accept")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)
        elseif act.type == "SendChat" then
            local p1 = createBuilderInput("P1", "Chat Message (e.g. Hello $player)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.message or "Hello!")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.message = p1.Text end)
        elseif act.type == "SetCharacterState" then
            local p1 = createBuilderInput("P1", "Property (Speed/Jump/Sit/Noclip)", UDim2.new(0.38, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.property or "WalkSpeed")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.property = p1.Text end)

            local p2 = createBuilderInput("P2", "Value (e.g. 32 / true)", UDim2.new(0.27, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.38, 175, 0, 8)
            p2.Text = tostring(act.value or "32")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.value = p2.Text end)
        elseif act.type == "LookAt" then
            local p1 = createBuilderInput("P1", "Target ($nearest / Pos / Part)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "$nearest")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)
        elseif act.type == "PlaySound" then
            local p1 = createBuilderInput("P1", "Preset (Success/Ping/Alert/Buzzer) or ID", UDim2.new(0.42, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.sound or "Success")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.sound = p1.Text end)

            local p2 = createBuilderInput("P2", "Vol (0-1)", UDim2.new(0.23, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.42, 175, 0, 8)
            p2.Text = tostring(act.volume or 1.0)
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.volume = tonumber(p2.Text) or 1.0 end)
        elseif act.type == "HighlightInstance" then
            local p1 = createBuilderInput("P1", "Target ($nearest / Player / Part)", UDim2.new(0.32, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "$nearest")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)

            local p2 = createBuilderInput("P2", "Color (cyan/red/gold)", UDim2.new(0.2, -5, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.32, 175, 0, 8)
            p2.Text = tostring(act.color or "cyan")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.color = p2.Text end)

            local p3 = createBuilderInput("P3", "Dur s (0=perm)", UDim2.new(0.16, 0, 0, 22), UDim2.new(0, 22), block)
            p3.Position = UDim2.new(0.52, 175, 0, 8)
            p3.Text = tostring(act.duration or 10)
            p3:GetPropertyChangedSignal("Text"):Connect(function() act.duration = tonumber(p3.Text) or 0 end)
        elseif act.type == "SendWebhook" then
            local p1 = createBuilderInput("P1", "Webhook URL", UDim2.new(0.36, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.url or "")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.url = p1.Text end)

            local p2 = createBuilderInput("P2", "Message (e.g. Alert $player)", UDim2.new(0.32, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.36, 175, 0, 8)
            p2.Text = tostring(act.message or "")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.message = p2.Text end)
        elseif act.type == "SetClipboard" then
            local p1 = createBuilderInput("P1", "Text to Copy (e.g. $player at $position)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.text or "")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.text = p1.Text end)
        elseif act.type == "PlayAnimation" then
            local p1 = createBuilderInput("P1", "Emote / ID (dance/wave/salute)", UDim2.new(0.42, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.animation or "dance")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.animation = p1.Text end)

            local p2 = createBuilderInput("P2", "Action (play / stop)", UDim2.new(0.23, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.42, 175, 0, 8)
            p2.Text = tostring(act.action or "play")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.action = p2.Text end)
        elseif act.type == "Spectate" then
            local p1 = createBuilderInput("P1", "Target ($nearest / Player / reset)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "$nearest")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)
        elseif act.type == "ResetCamera" then
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0.65, 0, 0, 22)
            lbl.Position = UDim2.new(0, 180, 0, 8)
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = 11
            lbl.TextColor3 = Color3.fromRGB(150, 165, 190)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Text = "Resets camera view back to local character"
            lbl.ZIndex = 203
            lbl.Parent = block
        elseif act.type == "FollowRoute" then
            local p1 = createBuilderInput("P1", "Target Node (e.g. Yard)", UDim2.new(0.35, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.targetNode or "Yard")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.targetNode = p1.Text end)

            local p2 = createBuilderInput("P2", "Route file (e.g. road_network.json)", UDim2.new(0.35, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.35, 175, 0, 8)
            p2.Text = tostring(act.route or "road_network.json")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.route = p2.Text end)
        elseif act.type == "ActivatePrompt" then
            local p1 = createBuilderInput("P1", "Prompt Name / nearest", UDim2.new(0.4, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.target or "nearest")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.target = p1.Text end)

            local p2 = createBuilderInput("P2", "Max Distance studs", UDim2.new(0.3, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.4, 175, 0, 8)
            p2.Text = tostring(act.maxDistance or 35)
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.maxDistance = tonumber(p2.Text) or 35 end)
        elseif act.type == "VirtualInput" then
            local p1 = createBuilderInput("P1", "KeyCode (e.g. E, Space)", UDim2.new(0.35, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.key or "E")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.key = p1.Text end)

            local p2 = createBuilderInput("P2", "Hold sec", UDim2.new(0.3, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.35, 175, 0, 8)
            p2.Text = tostring(act.duration or 0.1)
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.duration = tonumber(p2.Text) or 0.1 end)
        elseif act.type == "Delay" then
            local p1 = createBuilderInput("P1", "Delay duration sec (e.g. 1.0)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.duration or 1.0)
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.duration = tonumber(p1.Text) or 1.0 end)
        elseif act.type == "Toast" then
            local p1 = createBuilderInput("P1", "Message", UDim2.new(0.4, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.message or "Triggered")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.message = p1.Text end)

            local p2 = createBuilderInput("P2", "Title", UDim2.new(0.3, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.4, 175, 0, 8)
            p2.Text = tostring(act.title or "Scheduler")
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.title = p2.Text end)
        elseif act.type == "Print" then
            local p1 = createBuilderInput("P1", "Message (e.g. $vehicleOwner spawned $vehicleName)", UDim2.new(0.65, 0, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.message or "Spawned by: $vehicleOwner ($vehicleName)")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.message = p1.Text end)
        elseif act.type == "FireRemote" or act.type == "InvokeServer" then
            local p1 = createBuilderInput("P1", "Remote Path (e.g. ReplicatedStorage.Remote)", UDim2.new(0.4, -10, 0, 22), UDim2.new(0, 22), block)
            p1.Position = UDim2.new(0, 180, 0, 8)
            p1.Text = tostring(act.remote or "")
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.remote = p1.Text end)

            local p2 = createBuilderInput("P2", "Args JSON array (e.g. [\"$position\"])", UDim2.new(0.3, 0, 0, 22), UDim2.new(0, 22), block)
            p2.Position = UDim2.new(0.4, 175, 0, 8)
            p2.Text = type(act.args) == "string" and act.args or "[\"$position\"]"
            p2:GetPropertyChangedSignal("Text"):Connect(function() act.args = p2.Text end)
        elseif act.type == "RunLuau" then
            local p1 = Instance.new("TextBox")
            p1.Size = UDim2.new(1, -24, 0, 50)
            p1.Position = UDim2.new(0, 12, 0, 36)
            p1.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
            p1.BorderSizePixel = 0
            p1.Font = Enum.Font.Code
            p1.TextSize = 10
            p1.TextColor3 = Color3.fromRGB(240, 245, 255)
            p1.PlaceholderText = "-- Luau code here"
            p1.PlaceholderColor3 = Color3.fromRGB(110, 120, 140)
            p1.TextXAlignment = Enum.TextXAlignment.Left
            p1.TextYAlignment = Enum.TextYAlignment.Top
            p1.ClearTextOnFocus = false
            p1.MultiLine = true
            p1.Text = tostring(act.code or "")
            p1.ZIndex = 203
            p1.Parent = block
            local p1c = Instance.new("UICorner")
            p1c.CornerRadius = UDim.new(0, 4)
            p1c.Parent = p1
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft = UDim.new(0, 6)
            pad.PaddingTop = UDim.new(0, 4)
            pad.Parent = p1
            p1:GetPropertyChangedSignal("Text"):Connect(function() act.code = p1.Text end)
        else
            -- No extra parameters needed
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0.65, 0, 0, 22)
            lbl.Position = UDim2.new(0, 180, 0, 8)
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = 10
            lbl.TextColor3 = Color3.fromRGB(150, 165, 190)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Text = "(No additional parameters required)"
            lbl.ZIndex = 203
            lbl.Parent = block
        end
    end
end

-- ==========================================
-- Action Primitive Picker Modal Drawer
-- ==========================================
local PickerDrawer = Instance.new("Frame")
PickerDrawer.Name = "PickerDrawer"
PickerDrawer.Size = UDim2.new(0, 360, 0, 380)
PickerDrawer.Position = UDim2.new(0.5, -180, 0.5, -190)
PickerDrawer.BackgroundColor3 = Color3.fromRGB(18, 22, 34)
PickerDrawer.BorderSizePixel = 0
PickerDrawer.Visible = false
PickerDrawer.ZIndex = 250
PickerDrawer.Parent = BuilderModal
local pdCorn = Instance.new("UICorner")
pdCorn.CornerRadius = UDim.new(0, 10)
pdCorn.Parent = PickerDrawer
local pdStroke = Instance.new("UIStroke")
pdStroke.Thickness = 1.5
pdStroke.Color = Color3.fromRGB(0, 122, 255)
pdStroke.Parent = PickerDrawer

local pdTitle = Instance.new("TextLabel")
pdTitle.Size = UDim2.new(1, -24, 0, 32)
pdTitle.Position = UDim2.new(0, 12, 0, 6)
pdTitle.BackgroundTransparency = 1
pdTitle.Font = Enum.Font.GothamBold
pdTitle.TextSize = 12
pdTitle.TextColor3 = Color3.fromRGB(240, 245, 255)
pdTitle.TextXAlignment = Enum.TextXAlignment.Left
pdTitle.Text = "Select Action Primitive to Add"
pdTitle.ZIndex = 251
pdTitle.Parent = PickerDrawer

local pdCloseBtn = Instance.new("TextButton")
pdCloseBtn.Name = "CloseBtn"
pdCloseBtn.Size = UDim2.new(0, 24, 0, 24)
pdCloseBtn.Position = UDim2.new(1, -34, 0, 10)
pdCloseBtn.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
pdCloseBtn.BorderSizePixel = 0
pdCloseBtn.Font = Enum.Font.GothamBold
pdCloseBtn.TextSize = 11
pdCloseBtn.TextColor3 = Color3.fromRGB(220, 225, 240)
pdCloseBtn.Text = "✕"
pdCloseBtn.ZIndex = 251
pdCloseBtn.Parent = PickerDrawer
local pdcCorn = Instance.new("UICorner")
pdcCorn.CornerRadius = UDim.new(1, 0)
pdcCorn.Parent = pdCloseBtn

pdCloseBtn.MouseButton1Click:Connect(function()
    PickerDrawer.Visible = false
end)

local PickerScroll = Instance.new("ScrollingFrame")
PickerScroll.Name = "PickerScroll"
PickerScroll.Size = UDim2.new(1, -24, 1, -50)
PickerScroll.Position = UDim2.new(0, 12, 0, 42)
PickerScroll.BackgroundTransparency = 1
PickerScroll.BorderSizePixel = 0
PickerScroll.ScrollBarThickness = 4
PickerScroll.ScrollBarImageColor3 = Color3.fromRGB(60, 75, 100)
PickerScroll.ZIndex = 251
PickerScroll.Parent = PickerDrawer

local PickerLayout = Instance.new("UIListLayout")
PickerLayout.SortOrder = Enum.SortOrder.LayoutOrder
PickerLayout.Padding = UDim.new(0, 6)
PickerLayout.Parent = PickerScroll

PickerLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    PickerScroll.CanvasSize = UDim2.new(0, 0, 0, PickerLayout.AbsoluteContentSize.Y + 10)
end)

for i, prim in ipairs(ACTION_PRIMITIVES) do
    local pBtn = Instance.new("TextButton")
    pBtn.Name = "Prim_" .. prim.type
    pBtn.Size = UDim2.new(1, 0, 0, 32)
    pBtn.BackgroundColor3 = Color3.fromRGB(25, 32, 48)
    pBtn.BorderSizePixel = 0
    pBtn.LayoutOrder = i
    pBtn.Text = ""
    pBtn.ZIndex = 252
    pBtn.Parent = PickerScroll
    local pbCorn = Instance.new("UICorner")
    pbCorn.CornerRadius = UDim.new(0, 6)
    pbCorn.Parent = pBtn

    local pIcon = Instance.new("TextLabel")
    pIcon.Size = UDim2.new(0, 24, 1, 0)
    pIcon.Position = UDim2.new(0, 8, 0, 0)
    pIcon.BackgroundTransparency = 1
    pIcon.Font = Enum.Font.GothamBold
    pIcon.TextSize = 13
    pIcon.TextColor3 = Color3.fromRGB(255, 255, 255)
    pIcon.Text = prim.icon
    pIcon.ZIndex = 253
    pIcon.Parent = pBtn

    local pName = Instance.new("TextLabel")
    pName.Size = UDim2.new(0.65, 0, 1, 0)
    pName.Position = UDim2.new(0, 36, 0, 0)
    pName.BackgroundTransparency = 1
    pName.Font = Enum.Font.GothamBold
    pName.TextSize = 11
    pName.TextColor3 = Color3.fromRGB(240, 245, 255)
    pName.TextXAlignment = Enum.TextXAlignment.Left
    pName.Text = prim.name
    pName.ZIndex = 253
    pName.Parent = pBtn

    local pCat = Instance.new("TextLabel")
    pCat.Size = UDim2.new(0.25, 0, 1, 0)
    pCat.Position = UDim2.new(0.72, 0, 0, 0)
    pCat.BackgroundTransparency = 1
    pCat.Font = Enum.Font.Gotham
    pCat.TextSize = 9
    pCat.TextColor3 = Color3.fromRGB(140, 160, 190)
    pCat.TextXAlignment = Enum.TextXAlignment.Right
    pCat.Text = prim.cat
    pCat.ZIndex = 253
    pCat.Parent = pBtn

    pBtn.MouseButton1Click:Connect(function()
        local newAct = { type = prim.type }
        for k, v in pairs(prim.def) do newAct[k] = v end
        table.insert(builderState.actions, newAct)
        PickerDrawer.Visible = false
        renderActionStack()
    end)
end

AddActionBtn.MouseButton1Click:Connect(function()
    PickerDrawer.Visible = true
end)

-- Scope Toggle Button
BuilderScopeBtn.MouseButton1Click:Connect(function()
    builderState.scope = (builderState.scope == "universal") and "place" or "universal"
    BuilderScopeBtn.Text = (builderState.scope == "universal") and "Scope: Universal (All Games)" or "Scope: Place-Specific"
    BuilderScopeBtn.BackgroundColor3 = (builderState.scope == "universal") and Color3.fromRGB(25, 45, 65) or Color3.fromRGB(35, 30, 50)
    BuilderScopeBtn.TextColor3 = (builderState.scope == "universal") and Color3.fromRGB(100, 190, 255) or Color3.fromRGB(210, 140, 255)
end)

BuilderCancelBtn.MouseButton1Click:Connect(function()
    BuilderModal.Visible = false
end)

-- Open Shortcut Editor
openShortcutEditor = function(taskObj)
    if taskObj then
        builderState.editingTask = taskObj
        builderState.scope = taskObj.scope or "place"
        selectedColor = taskObj.color or "blue"
        selectedIcon = taskObj.icon or "⚡"
        InputName.Text = taskObj.name or "Untitled Shortcut"
        InputDesc.Text = taskObj.description or ""

        -- Clone actions
        builderState.actions = {}
        for _, a in ipairs(taskObj.actions or {}) do
            local cloneAct = {}
            for k, v in pairs(a) do cloneAct[k] = v end
            table.insert(builderState.actions, cloneAct)
        end

        -- Match Trigger
        local trig = taskObj.trigger or { type = "Timer", interval = 60 }
        curTrigIdx = 1
        for i, opt in ipairs(TRIGGER_OPTIONS) do
            if opt.type == trig.type and (opt.preset == trig.preset) then
                curTrigIdx = i
                break
            end
        end
        TriggerBtn.Text = "WHEN: " .. TRIGGER_OPTIONS[curTrigIdx].label
        InputTriggerParam.PlaceholderText = TRIGGER_OPTIONS[curTrigIdx].placeholder
        if trig.type == "Timer" then
            InputTriggerParam.Text = tostring(trig.interval or 60)
        elseif trig.type == "ClockInterval" then
            InputTriggerParam.Text = tostring(trig.interval or 5.0)
        elseif trig.type == "ClockTarget" then
            InputTriggerParam.Text = tostring(trig.target or 120)
        elseif trig.type == "CustomSignal" then
            InputTriggerParam.Text = tostring(trig.path or "workspace.ChildAdded")
        elseif trig.type == "Keybind" then
            InputTriggerParam.Text = tostring(trig.key or "G")
        else
            InputTriggerParam.Text = ""
        end

        -- Match Condition
        local cond = taskObj.condition or { type = "Always" }
        curCondIdx = 1
        for i, opt in ipairs(CONDITION_OPTIONS) do
            if opt.type == cond.type then
                curCondIdx = i
                break
            end
        end
        ConditionBtn.Text = "IF: " .. CONDITION_OPTIONS[curCondIdx].label
        InputConditionParam.PlaceholderText = CONDITION_OPTIONS[curCondIdx].placeholder
        if cond.type == "LowHealth" then
            InputConditionParam.Text = tostring(cond.threshold or 25)
        elseif cond.type == "StaffRank" then
            InputConditionParam.Text = string.format("%d:%d", cond.minRank or 100, cond.groupId or 0)
        elseif cond.type == "StatThreshold" then
            InputConditionParam.Text = string.format("%s:%s:%s", cond.stat or "Cash", cond.operator or ">=", tostring(cond.value or 0))
        elseif cond.type == "ObjectProximity" then
            InputConditionParam.Text = string.format("%s:%s:%s", cond.target or "Door", tostring(cond.distance or 25), cond.mode or "within")
        elseif cond.type == "ClockElapsed" then
            InputConditionParam.Text = tostring(cond.threshold or 60)
        elseif cond.type == "CustomLua" then
            InputConditionParam.Text = tostring(cond.code or "return true")
        else
            InputConditionParam.Text = ""
        end
    else
        builderState.editingTask = nil
        builderState.scope = "place"
        selectedColor = "blue"
        selectedIcon = "⚡"
        InputName.Text = "New Shortcut"
        InputDesc.Text = "Automated workflow pipeline"
        builderState.actions = {
            { type = "Toast", title = "Shortcut Fired", message = "Action completed" }
        }
        curTrigIdx = 1
        curCondIdx = 1
        TriggerBtn.Text = "WHEN: " .. TRIGGER_OPTIONS[1].label
        InputTriggerParam.Text = TRIGGER_OPTIONS[1].defaultParam
        ConditionBtn.Text = "IF: " .. CONDITION_OPTIONS[1].label
        InputConditionParam.Text = CONDITION_OPTIONS[1].defaultParam
    end

    -- Update Color & Icon selection strokes
    for cN, b in pairs(colorButtons) do
        local st = b:FindFirstChildOfClass("UIStroke")
        if st then st.Transparency = (cN == selectedColor) and 0 or 1 end
    end
    for icN, b in pairs(iconButtons) do
        local st = b:FindFirstChildOfClass("UIStroke")
        if st then st.Transparency = (icN == selectedIcon) and 0 or 1 end
    end

    BuilderScopeBtn.Text = (builderState.scope == "universal") and "Scope: Universal (All Games)" or "Scope: Place-Specific"
    BuilderScopeBtn.BackgroundColor3 = (builderState.scope == "universal") and Color3.fromRGB(25, 45, 65) or Color3.fromRGB(35, 30, 50)
    BuilderScopeBtn.TextColor3 = (builderState.scope == "universal") and Color3.fromRGB(100, 190, 255) or Color3.fromRGB(210, 140, 255)

    renderActionStack()
    BuilderModal.Visible = true
end

NewShortcutBtn.MouseButton1Click:Connect(function()
    openShortcutEditor(nil)
end)

-- Save Shortcut Logic
BuilderSaveBtn.MouseButton1Click:Connect(function()
    local name = InputName.Text
    if name == "" then name = "New Automated Shortcut" end
    local desc = InputDesc.Text
    if desc == "" then desc = "Multi-action automated shortcut" end

    local tOpt = TRIGGER_OPTIONS[curTrigIdx]
    local cOpt = CONDITION_OPTIONS[curCondIdx]

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
    elseif tOpt.type == "Keybind" then
        local rawKey = InputTriggerParam.Text ~= "" and InputTriggerParam.Text or "G"
        triggerObj.key = rawKey:upper():gsub("%s+", "")
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

    -- Ensure at least one action
    local actions = builderState.actions
    if #actions == 0 then
        table.insert(actions, { type = "Toast", title = name, message = "Executed successfully" })
    end

    local placeIdStr = tostring(game.PlaceId or "0")

    if builderState.editingTask then
        local taskObj = builderState.editingTask
        Engine.unbindTask(taskObj.id)

        taskObj.name = name
        taskObj.description = desc
        taskObj.icon = selectedIcon
        taskObj.color = selectedColor
        taskObj.trigger = triggerObj
        taskObj.condition = conditionObj
        taskObj.actions = actions

        -- Handle scope change
        if taskObj.scope ~= builderState.scope then
            if taskObj.scope == "universal" then
                for i, t in ipairs(Storage.data.universal) do
                    if t.id == taskObj.id then table.remove(Storage.data.universal, i); break end
                end
                Storage.data.places[placeIdStr] = Storage.data.places[placeIdStr] or {}
                table.insert(Storage.data.places[placeIdStr], taskObj)
            else
                if Storage.data.places[placeIdStr] then
                    for i, t in ipairs(Storage.data.places[placeIdStr]) do
                        if t.id == taskObj.id then table.remove(Storage.data.places[placeIdStr], i); break end
                    end
                end
                Storage.data.universal = Storage.data.universal or {}
                table.insert(Storage.data.universal, taskObj)
            end
            taskObj.scope = builderState.scope
        end

        if taskObj.enabled then
            Engine.bindTask(taskObj)
        end
    else
        local newId = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(100, 999))
        local newTask = {
            id = newId,
            name = name,
            description = desc,
            icon = selectedIcon,
            color = selectedColor,
            enabled = true,
            scope = builderState.scope,
            trigger = triggerObj,
            condition = conditionObj,
            actions = actions,
            telemetry = { invocations = 0, lastRun = 0, lastResult = "Ready" }
        }

        if newTask.scope == "universal" then
            Storage.data.universal = Storage.data.universal or {}
            table.insert(Storage.data.universal, newTask)
        else
            Storage.data.places[placeIdStr] = Storage.data.places[placeIdStr] or {}
            table.insert(Storage.data.places[placeIdStr], newTask)
        end

        Engine.bindTask(newTask)
    end

    Storage.save(true)
    BuilderModal.Visible = false
    refreshShortcutsGrid()

    if showToastNotification then
        showToastNotification("Shortcut Saved", string.format("Saved '%s' with %d action%s", name, #actions, #actions == 1 and "" or "s"), 3.0)
    end
end)

-- ==============================================================================
-- 6. IMPORT WORKFLOW MODAL
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
ImportTextBox.PlaceholderText = '{\n  "name": "My Shared Shortcut",\n  "icon": "⚡",\n  "color": "blue",\n  "trigger": { "type": "Timer", "interval": 10 },\n  "actions": [...]\n}'
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
DoImportBtn.Text = "Import Shortcut"
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
            name = tostring(taskData.name or "Imported Shortcut"),
            description = tostring(taskData.description or "Imported workflow"),
            icon = taskData.icon or "⚡",
            color = taskData.color or "blue",
            enabled = false, -- Security hardening: Always import disabled for user review
            scope = (taskData.scope == "universal") and "universal" or "place",
            trigger = type(taskData.trigger) == "table" and taskData.trigger or { type = "Timer", interval = 60 },
            condition = type(taskData.condition) == "table" and taskData.condition or { type = "Always" },
            actions = type(taskData.actions) == "table" and taskData.actions or {},
            telemetry = { invocations = 0, lastRun = 0, lastResult = "Imported (Disabled for review)" }
        }

        if cloned.scope == "universal" then
            Storage.data.universal = Storage.data.universal or {}
            table.insert(Storage.data.universal, cloned)
        else
            Storage.data.places[placeIdStr] = Storage.data.places[placeIdStr] or {}
            table.insert(Storage.data.places[placeIdStr], cloned)
        end

        -- Note: Imported shortcuts remain disabled until user reviews and toggles them on.
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
        refreshShortcutsGrid()
        ImportModal.Visible = false
        ImportTextBox.Text = ""
        if showToastNotification then
            showToastNotification("Import Successful", string.format("Imported %d shortcut(s)", importedCount), 3.5)
        end
    else
        if showToastNotification then
            showToastNotification("Import Failed", "No valid task definitions found in JSON", 3.0)
        end
    end
end)

-- ==============================================================================
-- 7. HOTKEY & GLOBAL EXPORTS
-- ==============================================================================
local function toggleSchedulerHUD()
    MainFrame.Visible = not MainFrame.Visible
    if MainFrame.Visible then
        refreshShortcutsGrid()
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
    end
end

local keybindConnection
keybindConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
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
    taskDef.icon = taskDef.icon or "⚡"
    taskDef.color = taskDef.color or "blue"
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
    if getgenv()._OmniNoclipConn then
        pcall(function() getgenv()._OmniNoclipConn:Disconnect() end)
        getgenv()._OmniNoclipConn = nil
    end
    getgenv().UnloadAllScheduledTasks()
    if ScreenGui then
        ScreenGui:Destroy()
    end
end

-- Initialize Storage & Bind existing tasks
Storage.load()

for _, t in pairs(Storage.data.universal or {}) do
    if type(t) == "table" and t.enabled then
        Engine.bindTask(t)
    end
end
local placeIdStr = tostring(game.PlaceId or "0")
for _, t in pairs(Storage.data.places[placeIdStr] or {}) do
    if type(t) == "table" and t.enabled then
        Engine.bindTask(t)
    end
end

refreshShortcutsGrid()
print("[AutomationScheduler]: Omni Shortcuts Engine loaded successfully! (Shift + F7 to open)")
