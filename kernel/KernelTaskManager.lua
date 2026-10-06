--!stage Kernel
--!name KernelTaskManager
--!priority 1000
--[[
    ==============================================================================
    OMNI KERNEL TASK MANAGER & RUNTIME MICRO-KERNEL (v1.0 Standalone)
    ==============================================================================
    A unified, single-file developer execution engine and administrative task manager.
    Zero external dependencies. Works out-of-the-box via loadstring or autoexec.

    [ SECTION 1: RUNTIME MICRO-KERNEL & VIRTUAL SCHEDULER ]
    - Transparent Global RunService Interception: Hooks RunService.__index & __namecall
      to seamlessly route third-party Heartbeat, Stepped, RenderStepped, PostSimulation,
      PreSimulation, PreRender, and BindToRenderStep connections into the scheduler
      with zero script modifications required.
    - Tiered Cumulative Frame-Budgeting (max 8.0ms per frame) shared across all phases,
      with guaranteed minimum phase share to eliminate Heartbeat starvation.
    - Dynamic Auto-Throttling: Automatically monitors per-task CPU consumption. If any
      unmodded script consumes > 2.5ms or spikes, it is dynamically demoted from High (60Hz)
      to Medium (30Hz) or Low (15Hz), and promoted back once stabilized.
    - Fault-Tolerant Error Boundaries: xpcall & coroutine isolation so errors/yields never freeze the engine.
    - Clean Teardown & Panic Switch: getgenv().UnloadAllTasks() + auto-teardown on Close.
    - Live Performance Profiling: microsecond tracking emitted to workspace/Scheduler_Profile.json every 2s.

    [ SECTION 2: FLUENT TASK MANAGER HUD ]
    - Admin Hotkey: Shift + F8 (or getgenv().ToggleTaskManagerHUD())
    - Real-Time Process Monitoring: Per-task CPU (ms), Spike (ms), Priority, Invocations
    - Interactive Context Controls: Pause/Resume, Lock Priority, Kill Task
    - Global Action Controls: Panic Kill All, Pause/Resume All Loops, Global Priority Override
    - Dynamic Refresh Rate (Hz) Button Scaling
    ==============================================================================
]]

if not game or not game.GetService then return end

local rawGame = (workspace and workspace.Parent) or game
if not getgenv()._KernelOrigGame then
    getgenv()._KernelOrigGame = rawGame
end

-- Common Engine Services & Pointers
local RunService = game:GetService("RunService")
local rawRunService = RunService
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

-- Forward declarations for signals & proxies
local ProxiedSignals = {}
local emitProfile
local findTask
local KillSchedulerTask
local IngestGameTask
local DiscardIngestedGameTask
local refreshStartupTab
local taskRowDragging = {}
local RequestIngestedLivenessCheck

-- Unified Idempotent Reload: Clean up any prior instances
if getgenv()._KernelTaskManagerUnifiedCleanUp and type(getgenv()._KernelTaskManagerUnifiedCleanUp) == "function" then
    pcall(getgenv()._KernelTaskManagerUnifiedCleanUp)
else
    if getgenv()._VirtualSchedulerCleanUp and type(getgenv()._VirtualSchedulerCleanUp) == "function" then
        pcall(getgenv()._VirtualSchedulerCleanUp)
    end
    if getgenv()._KernelTaskManagerCleanUp and type(getgenv()._KernelTaskManagerCleanUp) == "function" then
        pcall(getgenv()._KernelTaskManagerCleanUp)
    end
end

-- Self Source Identifier for Caller Attribution
local rawSelf = (debug and debug.info and debug.info(1, "s"))
local SELF_SRC = (rawSelf and rawSelf ~= "" and rawSelf ~= "[C]") and tostring(rawSelf) or nil

-- ==============================================================================
-- ADAPTIVE EXECUTION GATEWAY: Safe Passthrough & Obfuscation Immunity
-- ==============================================================================
-- Provides instant (<0.01ms) detection for obfuscated third-party scripts (Luraph,
-- Moonsec, Ironbrew, LuaAuth, etc.) and auto-exempts them across all scheduler
-- hooks and loop throttlers, guaranteeing virgin C-closure execution without
-- intrusive trampoline mutation.

local function isObfuscatedCode(src, chunkname)
    if chunkname and type(chunkname) == "string" and chunkname ~= "" then
        local cLower = chunkname:lower()
        if cLower:find("luraph", 1, true)
            or cLower:find("lph", 1, true)
            or cLower:find("luaauth", 1, true)
            or cLower:find("moonsec", 1, true)
            or cLower:find("ironbrew", 1, true)
            or cLower:find("plasmii", 1, true)
            or cLower:find("obf", 1, true) then
            return true
        end
        local exempt = getgenv()._KernelExemptScripts
        if exempt and (exempt[cLower] or exempt[cLower:gsub("^[@%[]", "")]) then
            return true
        end
    end

    if type(src) ~= "string" or #src < 10 then return false end
    local head = src:sub(1, 4000):lower()
    return head:find("luraph", 1, true) ~= nil
        or head:find("lph_", 1, true) ~= nil
        or head:find("lh={", 1, true) ~= nil
        or head:find("lh = {", 1, true) ~= nil
        or head:find(",lh={},", 1, true) ~= nil
        or head:find("luaauth", 1, true) ~= nil
        or head:find("la_script_id", 1, true) ~= nil
        or head:find("moonsec", 1, true) ~= nil
        or head:find("ironbrew", 1, true) ~= nil
        or head:find("prometheus", 1, true) ~= nil
        or head:find("psu obfuscator", 1, true) ~= nil
        or head:find("aztup", 1, true) ~= nil
        or head:find("synapse xen", 1, true) ~= nil
        or head:find("boron", 1, true) ~= nil
        or head:find("obfuscated with", 1, true) ~= nil
        or head:find("this file was obfuscated", 1, true) ~= nil
        or head:find("protected by", 1, true) ~= nil
        or src:sub(1, 4) == "\27Lua"
        or head:find("\\27lua", 1, true) ~= nil
        or head:find("\\x1blua", 1, true) ~= nil
end

-- Universal Scheduler Exemption Registry (API for external scripts/addons to opt out of loop management)
local _KernelExemptScripts = getgenv()._KernelExemptScripts or {}
getgenv()._KernelExemptScripts = _KernelExemptScripts
getgenv().ExemptScriptFromScheduler = function(pattern)
    if pattern and type(pattern) == "string" and pattern ~= "" then
        _KernelExemptScripts[pattern:lower()] = true
        return true
    end
    return false
end

-- Safe loadstring shim with Adaptive Execution Gateway
local origLoadstring = getgenv()._KernelOrigLoadstring or getgenv().loadstring or loadstring
getgenv()._KernelOrigLoadstring = origLoadstring
if type(origLoadstring) == "function" then
        local function loadstringShim(src, chunkname)
            if typeof(src) == "Instance" then
                if src:IsA("LuaSourceContainer") then
                    local fullName = pcall(function() return src:GetFullName() end) and src:GetFullName() or "Instance"
                    chunkname = chunkname or ("@" .. fullName)
                    local ok, code = pcall(function() return (decompile and decompile(src)) or src.Source end)
                    if ok and type(code) == "string" and code ~= "" then
                        src = code
                    else
                        return function() end
                    end
                else
                    return function() end
                end
            end

            -- Stack origin inspection: check if caller itself is an exempt/obfuscated script
            local isCallerExempt = false
            if debug and debug.info then
                for lvl = 2, 7 do
                    local cSrc = debug.info(lvl, "s")
                    if cSrc and type(cSrc) == "string" and cSrc ~= "" and cSrc ~= "[C]" then
                        local clean = cSrc:gsub("^[@%[]", ""):gsub("\"%]$", ""):lower()
                        if isObfuscatedCode("", clean) or (getgenv()._KernelExemptScripts and getgenv()._KernelExemptScripts[clean]) then
                            isCallerExempt = true
                            break
                        end
                    end
                end
            end

            -- Adaptive Execution Gateway: auto-exempt obfuscated scripts instantly
            local isObf = isCallerExempt or (type(src) == "string" and isObfuscatedCode(src, chunkname))
            local exempt = _KernelExemptScripts or getgenv()._KernelExemptScripts
            if isObf and exempt then
                if chunkname and type(chunkname) == "string" and chunkname ~= "" then
                    exempt[chunkname:lower()] = true
                    exempt[chunkname:gsub("^[@%[]", ""):lower()] = true
                end
                exempt["luraph"] = true
                exempt["moonsec"] = true
                exempt["ironbrew"] = true
                exempt["luaauth"] = true
                exempt["plasmii"] = true
            end

            if isObf then
                -- Dynamic Virgin Handoff: restore virgin engine DataModel and builtins to getgenv()
                -- Obfuscators (Luraph v14, LuaAuth) verify getfenv(1) == getgenv() and inspect metatables.
                local rawGame = (workspace and workspace.Parent) or getgenv()._KernelOrigGame or game
                getgenv().game = rawGame
                if getgenv()._KernelOrigTypeof then
                    getgenv().typeof = getgenv()._KernelOrigTypeof
                end
                if getgenv()._KernelOrigGetrawmetatable then
                    getgenv().getrawmetatable = getgenv()._KernelOrigGetrawmetatable
                end
                if getgenv()._KernelOrigCloneref then
                    getgenv().cloneref = getgenv()._KernelOrigCloneref
                end

                -- NEVER call setfenv on obfuscated code: it breaks Luau VM fastpaths, traps loader variables
                -- (like LuaAuth la_script_id), and trips Luraph integrity checks.
                return origLoadstring(src, chunkname)
            end

            local fn, compileErr = origLoadstring(src, chunkname)
            if fn and type(src) == "string" then
                local gameProxy = getgenv()._OmniGameProxy or (getgenv()._OmniCreateGameProxy and getgenv()._OmniCreateGameProxy())
                if gameProxy then
                    -- Re-assert gameProxy on getgenv().game if previously reset by an obfuscator
                    getgenv().game = gameProxy
                    if getgenv()._KernelWrappedTypeof then
                        getgenv().typeof = getgenv()._KernelWrappedTypeof
                    end
                    if getgenv()._KernelWrappedGetrawmetatable then
                        getgenv().getrawmetatable = getgenv()._KernelWrappedGetrawmetatable
                    end
                    if getgenv()._KernelWrappedCloneref then
                        getgenv().cloneref = getgenv()._KernelWrappedCloneref
                    end

                    local origCloneref = getgenv().cloneref or cloneref
                    local function safeCloneref(obj, ...)
                        if not obj or obj == gameProxy or obj == getgenv()._VirtualSchedulerProxiedRunService or typeof(obj) ~= "Instance" then
                            return obj
                        end
                        return origCloneref(obj, ...)
                    end
                    local scriptEnv = setmetatable({
                        game = gameProxy,
                        RunService = getgenv()._VirtualSchedulerProxiedRunService or getgenv().RunService,
                        cloneref = (type(origCloneref) == "function" and safeCloneref) or nil,
                    }, { __index = getfenv(fn) })
                    pcall(setfenv, fn, scriptEnv)
                end
            end

            return fn, compileErr
        end
        getgenv().loadstring = (newcclosure and newcclosure(loadstringShim)) or loadstringShim
        getgenv()._AdaptiveExecutionGatewayInstalled = true
        getgenv()._KernelLoadstringShimInstalled = true
    end

local function isSelfOrKernel(name)
    if not name or name == "" or name == "KernelInternal" then return true end
    local lower = tostring(name):lower()
    if lower:find("kerneltaskmanager", 1, true) ~= nil
        or lower:find("virtualscheduler", 1, true) ~= nil
        or lower:find("taskmanagerhud", 1, true) ~= nil
        or lower:find("utilities", 1, true) ~= nil
        or lower:find("utils", 1, true) ~= nil
        or lower:find("remoteexecute", 1, true) ~= nil
        or lower:find("customautoexec", 1, true) ~= nil
        or lower:find("bootloader", 1, true) ~= nil
        or lower:find("luraph", 1, true) ~= nil
        or lower:find("moonsec", 1, true) ~= nil
        or lower:find("ironbrew", 1, true) ~= nil
        or lower:find("luaauth", 1, true) ~= nil then
        return true
    end
    if _KernelExemptScripts then
        for pattern, _ in pairs(_KernelExemptScripts) do
            if lower:find(pattern, 1, true) ~= nil then
                return true
            end
        end
    end
    if SELF_SRC and SELF_SRC ~= "" and lower:find(SELF_SRC:lower(), 1, true) ~= nil then
        return true
    end
    return false
end

-- Source Origin Classifier: Distinguish Executor vs In-Game Scripts
local function isExecutorOrigin(name, caller, isExecFlag)
    -- 1. Trust caller identity / checkcaller flag above all else
    if isExecFlag ~= nil then
        return isExecFlag == true
    end

    if checkcaller then
        local ok, res = pcall(checkcaller)
        if ok and type(res) == "boolean" then
            return res
        end
    end

    local str = tostring(caller or name or ""):lower()

    -- 2. Explicit game script path indicators (Game containers in Roblox)
    if str:find("workspace.", 1, true)
        or str:find("playerscripts", 1, true)
        or str:find("playergui", 1, true)
        or str:find("replicatedstorage", 1, true)
        or str:find("starterplayer", 1, true)
        or str:find("_clientcontrols", 1, true)
        or str:find("chatscript", 1, true)
        or str:find("bubblescript", 1, true)
        or str:find("camerascrip", 1, true)
        or str:find("animate", 1, true) then
        return false
    end

    -- 3. Explicit executor indicators in caller path or name
    if str:find("executorscript", 1, true)
        or str:find(".lua", 1, true)
        or str:find(".txt", 1, true)
        or str:find(".iy", 1, true)
        or str:find("autoexec", 1, true)
        or str:find("potassium", 1, true)
        or str:find("banana", 1, true)
        or str:find("infiniteyield", 1, true)
        or str:find("dex", 1, true)
        or str:find("spy", 1, true) then
        return true
    end

    return false
end

-- Forward declaration for HUD controls
local cleanUpHUD
local toggleHUD

-- ==============================================================================
-- SECTION 1: RUNTIME MICRO-KERNEL & VIRTUAL SCHEDULER
-- ==============================================================================
local DEFAULT_BUDGET_MS = 8.0
local smoothedDeltaTime = 1 / 60 -- Default baseline: 60 FPS (16.67ms)
local currentBudgetSec = 0.0080
local currentBudgetMs = 8.0
local measuredFps = 60
local currentFrameTimestamp = 0
local frameSpentSec = 0

-- Idempotent reload: clean up any previously loaded scheduler instance
if getgenv()._VirtualSchedulerLoaded and type(getgenv()._VirtualSchedulerCleanUp) == "function" then
    pcall(getgenv()._VirtualSchedulerCleanUp)
end

-- Cache the original raw signals from RunService before any hooking
if not getgenv()._VirtualSchedulerRawSignals then
    local origIdx = getgenv()._VirtualSchedulerOrigIndex
    if origIdx then
        getgenv()._VirtualSchedulerRawSignals = {
            Heartbeat = origIdx(RunService, "Heartbeat"),
            Stepped = origIdx(RunService, "Stepped"),
            RenderStepped = origIdx(RunService, "RenderStepped"),
        }
    else
        getgenv()._VirtualSchedulerRawSignals = {
            Heartbeat = RunService.Heartbeat,
            Stepped = RunService.Stepped,
            RenderStepped = RunService.RenderStepped,
        }
    end
end
local rawSignals = getgenv()._VirtualSchedulerRawSignals

if not getgenv()._VirtualSchedulerRawBind then
    getgenv()._VirtualSchedulerRawBind = RunService.BindToRenderStep
    getgenv()._VirtualSchedulerRawUnbind = RunService.UnbindFromRenderStep
end
local rawBindToRenderStep = getgenv()._VirtualSchedulerRawBind
local rawUnbindFromRenderStep = getgenv()._VirtualSchedulerRawUnbind

local Events = {
    Heartbeat = {
        name = "Heartbeat",
        signal = rawSignals.Heartbeat,
        connection = nil,
        frameCount = 0,
        tasks = {},
        taskOrder = {},
        deferredQueue = {},
    },
    Stepped = {
        name = "Stepped",
        signal = rawSignals.Stepped,
        connection = nil,
        frameCount = 0,
        tasks = {},
        taskOrder = {},
        deferredQueue = {},
    },
    RenderStepped = {
        name = "RenderStepped",
        signal = rawSignals.RenderStepped,
        connection = nil,
        frameCount = 0,
        tasks = {},
        taskOrder = {},
        deferredQueue = {},
    },
    SuperStep = {
        name = "SuperStep",
        signal = nil,
        frameCount = 0,
        tasks = {},
        taskOrder = {},
        deferredQueue = {},
    },
}

local EVENT_NAMES = { "Heartbeat", "Stepped", "RenderStepped", "SuperStep" }

-- ==============================================================================
-- Persistent Scheduler & Loop Overrides Engine
-- ==============================================================================
local SchedulerPersistence = {
    file = "Scheduler_Overrides.json",
    data = { places = {}, global = { tasks = {}, loops = {} } },
    isSaving = false,
}

SchedulerPersistence.load = function()
    if not (isfile and readfile and HttpService and HttpService.JSONDecode) then return end
    local filePath = SchedulerPersistence.file
    if not isfile(filePath) and isfile("workspace/" .. filePath) then
        filePath = "workspace/" .. filePath
    end
    if not isfile(filePath) then return end

    local ok, raw = pcall(readfile, filePath)
    if not ok or not raw or raw == "" then return end

    local decOk, data = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if decOk and type(data) == "table" then
        if type(data.places) == "table" then
            SchedulerPersistence.data.places = data.places
            for _, pData in pairs(SchedulerPersistence.data.places) do
                if type(pData) == "table" and type(pData.loops) == "table" then
                    for lKey, _ in pairs(pData.loops) do
                        if isSelfOrKernel(lKey) then
                            pData.loops[lKey] = nil
                        end
                    end
                end
            end
        end
        if type(data.global) == "table" then
            SchedulerPersistence.data.global = data.global
            if type(SchedulerPersistence.data.global.loops) == "table" then
                for lKey, _ in pairs(SchedulerPersistence.data.global.loops) do
                    if isSelfOrKernel(lKey) then
                        SchedulerPersistence.data.global.loops[lKey] = nil
                    end
                end
            end
        end
    end
end

SchedulerPersistence.getTask = function(taskName, eventName)
    local placeKey = tostring(game.PlaceId or "0")
    local taskKey = (taskName or "") .. "@" .. (eventName or "Heartbeat")

    local placeData = SchedulerPersistence.data.places[placeKey]
    if placeData and placeData.tasks then
        if placeData.tasks[taskKey] then return placeData.tasks[taskKey] end
        if taskName and placeData.tasks[taskName] then return placeData.tasks[taskName] end
    end

    if SchedulerPersistence.data.global and SchedulerPersistence.data.global.tasks then
        if SchedulerPersistence.data.global.tasks[taskKey] then return SchedulerPersistence.data.global.tasks[taskKey] end
        if taskName and SchedulerPersistence.data.global.tasks[taskName] then return SchedulerPersistence.data.global.tasks[taskName] end
    end

    return nil
end

SchedulerPersistence.getLoop = function(callerStr, loopName)
    if isSelfOrKernel(callerStr) or isSelfOrKernel(loopName) then
        return nil
    end
    local callerFile = callerStr and callerStr:match("^([^:]+)")
    if callerFile and isSelfOrKernel(callerFile) then
        return nil
    end

    local placeKey = tostring(game.PlaceId or "0")

    local placeData = SchedulerPersistence.data.places[placeKey]
    if placeData and placeData.loops then
        if callerStr and placeData.loops[callerStr] then return placeData.loops[callerStr] end
        if loopName and placeData.loops[loopName] then return placeData.loops[loopName] end
        if callerFile and placeData.loops[callerFile] then return placeData.loops[callerFile] end
    end

    if SchedulerPersistence.data.global and SchedulerPersistence.data.global.loops then
        if callerStr and SchedulerPersistence.data.global.loops[callerStr] then return SchedulerPersistence.data.global.loops[callerStr] end
        if loopName and SchedulerPersistence.data.global.loops[loopName] then return SchedulerPersistence.data.global.loops[loopName] end
        if callerFile and SchedulerPersistence.data.global.loops[callerFile] then return SchedulerPersistence.data.global.loops[callerFile] end
    end

    return nil
end

SchedulerPersistence.save = function(...) end -- Forward declaration, implemented after buildProfile

local function saveSchedulerOverrides(...) SchedulerPersistence.save(...) end
local function getTaskOverride(...) return SchedulerPersistence.getTask(...) end
local function getLoopOverride(...) return SchedulerPersistence.getLoop(...) end

SchedulerPersistence.load()

local function getNumericTaskPriority(t)
    if not t then return 50 end
    local p = (type(t) == "table" and t.priority) or t
    if type(p) == "number" then return p end
    if p == "High" then return 80
    elseif p == "Medium" then return 50
    elseif p == "Low" then return 25
    elseif p == "Eco" then return 10
    elseif p == "Idle" then return 5
    end
    return tonumber(p) or 50
end

local nextTaskId = 0
local taskStaggerCounter = 0
local teardownConnections = {}
local boundRenderSteps = {}

-- Execute a single task under xpcall + coroutine boundary and record microsecond metrics
local function runTask(taskObj, ...)
    local t0 = os.clock()
    local ok, err
    local co = coroutine.create(function(...)
        if setthreadidentity then
            if taskObj.isIngested or taskObj.identity then
                pcall(setthreadidentity, taskObj.identity or 2)
            else
                pcall(setthreadidentity, 8)
            end
        end
        local xok, xerr = xpcall(taskObj.callback, function(e)
            return debug.traceback(tostring(e), 2)
        end, ...)
        if not xok then
            error(xerr, 0)
        end
    end)
    ok, err = coroutine.resume(co, ...)
    local durationSec = os.clock() - t0
    local durationMs = durationSec * 1000.0
    local durationUs = durationSec * 1000000.0

    taskObj.invocations = taskObj.invocations + 1
    taskObj.totalTimeMs = taskObj.totalTimeMs + durationMs
    taskObj.lastTimeMs = math.floor(durationMs * 1000) / 1000
    taskObj.lastDurationUs = math.floor(durationUs)
    if durationMs > taskObj.peakTimeMs then
        taskObj.peakTimeMs = math.floor(durationMs * 1000) / 1000
    end
    taskObj.avgTimeMs = math.floor((taskObj.totalTimeMs / taskObj.invocations) * 1000) / 1000
    if not taskObj.recentAvgMs or taskObj.invocations <= 1 then
        taskObj.recentAvgMs = durationMs
    else
        taskObj.recentAvgMs = (taskObj.recentAvgMs * 0.88) + (durationMs * 0.12)
    end

    if not ok then
        taskObj.errorCount = taskObj.errorCount + 1
        taskObj.lastError = tostring(err)
        warn(string.format("[VirtualScheduler Error][%s]: %s", taskObj.name, tostring(err)))
    end

    -- Dynamic Auto-Throttler & Smart Pipeline Partitioning:
    -- Hard real-time tasks (such as ingested game engine callbacks) MUST NEVER be partitioned or auto-throttled!
    if not taskObj.isHardRealTime and not taskObj.isIngested then
        -- Dynamically scales threshold to 35% of current frame budget (min 0.8ms), recovery threshold to 20% (min 0.4ms)
        local heavyThresholdMs = math.max(0.8, currentBudgetMs * 0.35)
        local lightRecoveryMs = math.max(0.4, currentBudgetMs * 0.20)

        -- Smart Pipeline Partitioning:
        if (durationMs > 16.0 or (taskObj.recentAvgMs and taskObj.recentAvgMs > 14.0)) and not taskObj.isAsync and taskObj.event ~= "SuperStep" then
            taskObj.isAsync = true
        elseif taskObj.isAsync and durationMs < 8.0 and (taskObj.recentAvgMs and taskObj.recentAvgMs < 8.0) then
            taskObj.isAsync = false
        end

        -- Continuous Fluid Auto-Throttler:
        if not taskObj.locked and taskObj.event ~= "SuperStep" and (taskObj.basePriority == "High" or (taskObj.targetHz and taskObj.targetHz >= 25)) then
        local isHeavy = durationMs > heavyThresholdMs or ((taskObj.recentAvgMs or 0) > heavyThresholdMs)
        if isHeavy then
            taskObj.heavyStreak = (taskObj.heavyStreak or 0) + 1
            taskObj.lightStreak = math.max(0, (taskObj.lightStreak or 0) - 2)
            if taskObj.heavyStreak >= 4 then
                -- Fluid cost-proportional scaling: smoothly scale effectiveHz down proportional to CPU overshoot
                local overshoot = math.max(0.02, heavyThresholdMs / math.max(0.1, taskObj.recentAvgMs or heavyThresholdMs))
                local targetHz = taskObj.targetHz or 60
                local newHz = math.clamp(targetHz * overshoot, 0.2, targetHz)
                taskObj.effectiveHz = math.round(newHz * 10) / 10
                taskObj.interval = math.max(1, math.round(measuredFps / math.max(0.1, taskObj.effectiveHz)))
                taskObj.autoThrottled = (taskObj.effectiveHz < (targetHz * 0.95))
                taskObj.demotions = (taskObj.demotions or 0) + 1

                -- Map semantic priority string based on effectiveHz
                if taskObj.effectiveHz >= 45 then
                    taskObj.priorityBand = "High"
                    taskObj.priority = 80
                elseif taskObj.effectiveHz >= 25 then
                    taskObj.priorityBand = "Medium"
                    taskObj.priority = 50
                elseif taskObj.effectiveHz >= 10 then
                    taskObj.priorityBand = "Low"
                    taskObj.priority = 25
                elseif taskObj.effectiveHz >= 3 then
                    taskObj.priorityBand = "Eco"
                    taskObj.priority = 10
                else
                    taskObj.priorityBand = "Idle"
                    taskObj.priority = 5
                end
            end
        elseif durationMs < lightRecoveryMs and ((taskObj.recentAvgMs or 0) < (lightRecoveryMs * 1.25)) then
            taskObj.lightStreak = (taskObj.lightStreak or 0) + 1
            taskObj.heavyStreak = math.max(0, (taskObj.heavyStreak or 0) - 1)
            if taskObj.autoThrottled and taskObj.lightStreak >= 8 then
                local targetHz = taskObj.targetHz or 60
                local newHz = math.min(targetHz, (taskObj.effectiveHz or 15) * 1.35 + 1.0)
                taskObj.effectiveHz = math.round(newHz * 10) / 10
                taskObj.interval = math.max(1, math.round(measuredFps / math.max(0.1, taskObj.effectiveHz)))
                taskObj.autoThrottled = (taskObj.effectiveHz < (targetHz * 0.95))
                taskObj.lightStreak = 0

                if taskObj.effectiveHz >= 45 then
                    taskObj.priorityBand = "High"
                    taskObj.priority = 80
                elseif taskObj.effectiveHz >= 25 then
                    taskObj.priorityBand = "Medium"
                    taskObj.priority = 50
                elseif taskObj.effectiveHz >= 10 then
                    taskObj.priorityBand = "Low"
                    taskObj.priority = 25
                elseif taskObj.effectiveHz >= 3 then
                    taskObj.priorityBand = "Eco"
                    taskObj.priority = 10
                else
                    taskObj.priorityBand = "Idle"
                    taskObj.priority = 5
                end
            end
        end
    end
    end

    return ok
end

-- Process a frame for a given event state
local function processFrame(eventState, ...)
    if setthreadidentity then
        setthreadidentity(8)
    end
    eventState.frameCount = eventState.frameCount + 1
    local frameNum = eventState.frameCount

    -- Adaptive Refresh-Rate Budget Engine:
    -- Dynamically track live framerate and allocate ~48% of the frame window
    if eventState.name == "Heartbeat" then
        Events.SuperStep.frameCount = Events.Heartbeat.frameCount
        local dt = ...
        if typeof(dt) == "number" and dt > 0.0005 and dt < 0.2 then
            smoothedDeltaTime = (smoothedDeltaTime * 0.92) + (dt * 0.08)
            local prevFps = measuredFps
            measuredFps = math.clamp(math.round(1 / smoothedDeltaTime), 10, 1000)
            local targetBudgetSec = smoothedDeltaTime * 0.48
            currentBudgetSec = math.clamp(targetBudgetSec, 0.0015, 0.0080)
            currentBudgetMs = math.floor(currentBudgetSec * 10000) / 10

            -- Dynamic Refresh Rate Ceiling Tracking:
            -- When live framerate changes, dynamically rescale tasks along the continuous spectrum
            if measuredFps ~= prevFps then
                local maxHz = math.max(60, measuredFps)
                for _, evState in pairs(Events) do
                    if evState.tasks then
                        for _, tObj in pairs(evState.tasks) do
                            if tObj.connected and not tObj.paused then
                                if tObj.isMax or tObj.basePriority == "High" or (tObj.targetRatio and tObj.targetRatio >= 0.95) then
                                    tObj.targetHz = maxHz
                                    if not tObj.autoThrottled then
                                        tObj.effectiveHz = maxHz
                                        tObj.interval = 1
                                    else
                                        tObj.interval = math.max(1, math.round(maxHz / math.max(0.1, tObj.effectiveHz)))
                                    end
                                    if tObj.connection then
                                        tObj.connection.TargetHz = maxHz
                                        tObj.connection.EffectiveHz = tObj.effectiveHz
                                    end
                                elseif tObj.targetRatio and tObj.targetRatio > 0 then
                                    local newTargetHz = math.clamp(math.round(tObj.targetRatio * maxHz), 1, maxHz)
                                    tObj.targetHz = newTargetHz
                                    if not tObj.autoThrottled then
                                        tObj.effectiveHz = newTargetHz
                                        tObj.interval = math.max(1, math.round(maxHz / math.max(0.1, tObj.effectiveHz)))
                                    else
                                        tObj.interval = math.max(1, math.round(maxHz / math.max(0.1, tObj.effectiveHz)))
                                    end
                                    if tObj.connection then
                                        tObj.connection.TargetHz = newTargetHz
                                        tObj.connection.EffectiveHz = tObj.effectiveHz
                                    end
                                elseif tObj.targetHz then
                                    local eff = tObj.effectiveHz or tObj.targetHz
                                    tObj.interval = math.max(1, math.round(maxHz / math.max(0.1, eff)))
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Snapshot taskOrder to prevent element skipping if tasks are added or disconnected during iteration
    local taskOrderSnapshot = table.clone(eventState.taskOrder)

    -- Build unified frame work queue ordered strictly by continuous priority spectrum:
    -- 0. SuperStep tasks (physics/CFrame locking, run across Stepped, RenderStepped, Heartbeat)
    -- 1. Deferred tasks from previous frame (prevents starvation)
    -- 2. Eligible tasks scheduled for this frame along the continuous spectrum
    local workQueue = {}
    local queuedSet = {}

    -- 0. SuperStep tasks: executed at the top of each engine simulation phase
    local superState = Events.SuperStep
    if superState and #superState.taskOrder > 0 then
        if #superState.deferredQueue > 0 then
            for _, taskId in ipairs(superState.deferredQueue) do
                local taskObj = superState.tasks[taskId]
                if taskObj and taskObj.connected and not taskObj.paused and not queuedSet[taskId] then
                    table.insert(workQueue, taskObj)
                    queuedSet[taskId] = true
                end
            end
            superState.deferredQueue = {}
        end

        local superSnapshot = table.clone(superState.taskOrder)
        for _, taskId in ipairs(superSnapshot) do
            local taskObj = superState.tasks[taskId]
            if taskObj and taskObj.connected and not taskObj.paused and not queuedSet[taskId] then
                local intv = taskObj.interval or 1
                if intv <= 1 or ((frameNum + (taskObj.offset or 0)) % intv == 0) then
                    table.insert(workQueue, taskObj)
                    queuedSet[taskId] = true
                end
            end
        end
    end

    -- 1. Prioritize tasks deferred from previous frame
    for _, taskId in ipairs(eventState.deferredQueue) do
        local taskObj = eventState.tasks[taskId]
        if taskObj and taskObj.connected and not taskObj.paused and not queuedSet[taskId] then
            table.insert(workQueue, taskObj)
            queuedSet[taskId] = true
        end
    end
    eventState.deferredQueue = {}

    -- 2. Schedule eligible tasks for this frame along the continuous spectrum
    local eligibleTasks = {}
    for _, taskId in ipairs(taskOrderSnapshot) do
        local taskObj = eventState.tasks[taskId]
        if taskObj and taskObj.connected and not taskObj.paused and not queuedSet[taskId] then
            local intv = taskObj.interval or 1
            if intv <= 1 or ((frameNum + (taskObj.offset or 0)) % intv == 0) then
                table.insert(eligibleTasks, taskObj)
            end
        end
    end

    -- Sort eligible tasks: highest priority first (descending 100 -> 1); tie-break on sortOrder, then lower interval, then lower recentAvgMs
    table.sort(eligibleTasks, function(a, b)
        local priA = getNumericTaskPriority(a)
        local priB = getNumericTaskPriority(b)
        if priA ~= priB then
            return priA > priB
        end
        local soA = tonumber(a.sortOrder) or 9999
        local soB = tonumber(b.sortOrder) or 9999
        if soA ~= soB then
            return soA < soB
        end
        local intA = a.interval or 1
        local intB = b.interval or 1
        if intA ~= intB then
            return intA < intB
        end
        return (a.recentAvgMs or 0) < (b.recentAvgMs or 0)
    end)

    for _, taskObj in ipairs(eligibleTasks) do
        table.insert(workQueue, taskObj)
        queuedSet[taskObj.id] = true
    end

    table.sort(workQueue, function(a, b)
        local priA = getNumericTaskPriority(a)
        local priB = getNumericTaskPriority(b)
        if priA ~= priB then
            return priA > priB
        end
        local soA = tonumber(a.sortOrder) or 9999
        local soB = tonumber(b.sortOrder) or 9999
        if soA ~= soB then
            return soA < soB
        end
        local intA = a.interval or 1
        local intB = b.interval or 1
        if intA ~= intB then
            return intA < intB
        end
        return (a.recentAvgMs or 0) < (b.recentAvgMs or 0)
    end)

    -- Execute tasks within strict adaptive frame budget (capped at currentBudgetSec)
    -- Guarantees total executor execution time per frame NEVER exceeds the budget window!
    local now = os.clock()
    if now - currentFrameTimestamp > (smoothedDeltaTime * 0.5) then
        currentFrameTimestamp = now
        frameSpentSec = 0
    end

    local phaseStart = os.clock()
    local phaseMinBudgetSec = currentBudgetSec * 0.25 -- Guaranteed 25% minimum budget share
    local deferredThisFrame = {}
    for i, taskObj in ipairs(workQueue) do
        if taskObj.connected and not taskObj.paused then
            if taskObj.isIngested and taskObj.nativeConn and taskObj.nativeConn.Connected == false then
                if taskObj.connection and taskObj.connection.Disconnect then
                    taskObj.connection:Disconnect()
                else
                    taskObj.connected = false
                end
                continue
            end

            local phaseElapsed = os.clock() - phaseStart
            local totalElapsed = frameSpentSec + phaseElapsed
            if totalElapsed >= currentBudgetSec and phaseElapsed >= phaseMinBudgetSec then
                for j = i, #workQueue do
                    local remainingObj = workQueue[j]
                    if remainingObj and remainingObj.connected and not remainingObj.paused then
                        if remainingObj.isHardRealTime or remainingObj.isIngested then
                            -- HARD REAL-TIME: Ingested game engine callbacks must NEVER be deferred!
                            local remDt1, remDt2 = ...
                            if remainingObj.event == "SuperStep" and eventState.name == "Stepped" then
                                local tVal, dVal = ...
                                remDt1 = dVal or tVal
                                remDt2 = tVal
                            end
                            runTask(remainingObj, remDt1, remDt2)
                        elseif remainingObj.event == "SuperStep" then
                            table.insert(Events.SuperStep.deferredQueue, remainingObj.id)
                        else
                            table.insert(deferredThisFrame, remainingObj.id)
                        end
                    end
                end
                break
            end

            -- Normalize SuperStep arguments so first arg is consistently deltaTime
            local dtArg1, dtArg2 = ...
            if taskObj.event == "SuperStep" and eventState.name == "Stepped" then
                local timeVal, dtVal = ...
                dtArg1 = dtVal or timeVal
                dtArg2 = timeVal
            end

            -- Asynchronous Worker Tasks:
            -- If task is explicitly marked isAsync and NOT hard real-time / ingested, run in detached worker thread
            if taskObj.isAsync and not taskObj.isHardRealTime and not taskObj.isIngested and taskObj.event ~= "SuperStep" then
                if not taskObj.isRunning then
                    taskObj.isRunning = true
                    task.spawn(function()
                        local sok, serr = pcall(runTask, taskObj, dtArg1, dtArg2)
                        taskObj.isRunning = false
                    end)
                end
            else
                runTask(taskObj, dtArg1, dtArg2)
            end
        end
    end
    frameSpentSec = frameSpentSec + (os.clock() - phaseStart)
    eventState.deferredQueue = deferredThisFrame
end

-- Connect engine frame hooks to raw signals forwarding all arguments (...)
Events.Heartbeat.connection = rawSignals.Heartbeat:Connect(function(...)
    processFrame(Events.Heartbeat, ...)
end)

Events.Stepped.connection = rawSignals.Stepped:Connect(function(...)
    processFrame(Events.Stepped, ...)
end)

-- Normalize event argument
local function normalizeEvent(ev)
    if typeof(ev) == "RBXScriptSignal" then
        if ev == rawSignals.Heartbeat or ev == RunService.Heartbeat then return "Heartbeat"
        elseif ev == rawSignals.Stepped or ev == RunService.Stepped then return "Stepped"
        elseif ev == rawSignals.RenderStepped or ev == RunService.RenderStepped then return "RenderStepped"
        else return "Heartbeat" end
    end
    if type(ev) == "table" then
        if ev == ProxiedSignals.Heartbeat or ev == ProxiedSignals.PostSimulation then return "Heartbeat"
        elseif ev == ProxiedSignals.Stepped or ev == ProxiedSignals.PreSimulation then return "Stepped"
        elseif ev == ProxiedSignals.RenderStepped or ev == ProxiedSignals.PreRender then return "RenderStepped"
        elseif ev._eventName then return normalizeEvent(ev._eventName)
        end
    end
    if type(ev) == "string" then
        local lower = ev:lower():gsub("[%s_]+", "")
        if lower == "superstep" or lower == "super" or lower == "allsteps" then return "SuperStep"
        elseif lower == "heartbeat" or lower == "postsimulation" then return "Heartbeat"
        elseif lower == "stepped" or lower == "presimulation" then return "Stepped"
        elseif lower:find("render") or lower == "prerender" then return "RenderStepped"
        end
    end
    return "Heartbeat"
end

-- ==============================================================================
-- DECOUPLED PRIORITY & TARGET HZ NORMALIZERS
-- ==============================================================================

local function normalizeSchedulerPriority(pri)
    local numPri = 80
    local band = "High"

    if type(pri) == "number" then
        if pri == 1 then
            numPri, band = 90, "High"
        elseif pri == 2 then
            numPri, band = 60, "Medium"
        elseif pri == 4 then
            numPri, band = 30, "Low"
        else
            numPri = math.clamp(math.round(pri), 1, 100)
            if numPri >= 75 then band = "High"
            elseif numPri >= 45 then band = "Medium"
            elseif numPri >= 20 then band = "Low"
            elseif numPri >= 10 then band = "Eco"
            else band = "Idle" end
        end
    elseif type(pri) == "string" then
        local lower = pri:lower():gsub("[%s_]+", "")
        if lower == "high" or lower == "physics" or lower == "movement" or lower == "max" or lower == "unlimited" then
            numPri, band = 90, "High"
        elseif lower == "medium" or lower == "med" or lower == "esp" or lower == "radar" then
            numPri, band = 60, "Medium"
        elseif lower == "low" or lower == "farm" or lower == "autofarm" or lower == "stat" or lower == "ui" then
            numPri, band = 30, "Low"
        elseif lower == "eco" then
            numPri, band = 15, "Eco"
        elseif lower == "idle" then
            numPri, band = 5, "Idle"
        else
            local num = tonumber((lower:gsub("hz", "")))
            if num and num > 0 then
                numPri = math.clamp(math.round(num), 1, 100)
                if numPri >= 75 then band = "High"
                elseif numPri >= 45 then band = "Medium"
                elseif numPri >= 20 then band = "Low"
                elseif numPri >= 10 then band = "Eco"
                else band = "Idle" end
            end
        end
    end

    return numPri, band
end

local function normalizeSchedulerTargetHz(hzArg, customRatio)
    local maxHz = math.max(60, measuredFps or 60)
    local targetHz = maxHz
    local interval = 1
    local isMax = true
    local targetRatio = customRatio or 1.0

    if customRatio and customRatio >= 0.95 then
        return maxHz, 1, true, 1.0
    end

    if type(hzArg) == "number" then
        if hzArg <= 0 or hzArg >= (maxHz - 0.5) then
            targetHz, interval, isMax, targetRatio = maxHz, 1, true, 1.0
        else
            targetHz = math.clamp(math.round(hzArg), 1, maxHz)
            interval = math.max(1, math.round(maxHz / targetHz))
            isMax = false
            targetRatio = customRatio or (targetHz / maxHz)
        end
    elseif type(hzArg) == "string" then
        local lower = hzArg:lower():gsub("[%s_]+", "")
        local num = tonumber((lower:gsub("hz", "")))
        if num and num > 0 then
            return normalizeSchedulerTargetHz(num, customRatio)
        elseif lower == "high" or lower == "max" or lower == "physics" or lower == "unlimited" then
            targetHz, interval, isMax, targetRatio = maxHz, 1, true, 1.0
        elseif lower == "medium" or lower == "med" or lower == "esp" or lower == "radar" then
            targetHz, interval, isMax, targetRatio = math.round(maxHz * 0.5), 2, false, 0.5
        elseif lower == "low" or lower == "farm" or lower == "autofarm" or lower == "stat" or lower == "ui" then
            targetHz, interval, isMax, targetRatio = math.round(maxHz * 0.25), 4, false, 0.25
        elseif lower == "eco" or lower == "5hz" or lower == "5" then
            targetHz, interval, isMax, targetRatio = 5, math.max(1, math.round(maxHz / 5)), false, 5 / maxHz
        elseif lower == "idle" or lower == "1hz" or lower == "1" then
            targetHz, interval, isMax, targetRatio = 1, maxHz, false, 1 / maxHz
        end
    end

    return targetHz, interval, isMax, targetRatio
end

-- Backwards-compatible legacy signature (returns band, interval, targetHz, isMax, targetRatio, numPri)
local function normalizePriority(pri, customRatio)
    local numPri, band = normalizeSchedulerPriority(pri)
    local targetHz, interval, isMax, targetRatio = normalizeSchedulerTargetHz(pri, customRatio)
    return band, interval, targetHz, isMax, targetRatio, numPri
end

local function isEventArg(x)
    if typeof(x) == "RBXScriptSignal" then return true end
    if type(x) == "table" then
        if x == ProxiedSignals.Heartbeat or x == ProxiedSignals.Stepped or x == ProxiedSignals.RenderStepped or x == ProxiedSignals.PostSimulation or x == ProxiedSignals.PreSimulation or x == ProxiedSignals.PreRender then
            return true
        end
        if x._eventName then return true end
    end
    if type(x) == "string" then
        local l = x:lower():gsub("[%s_]+", "")
        return l == "superstep" or l == "super" or l == "allsteps" or l == "heartbeat" or l == "stepped" or l:find("render") ~= nil or l == "postsimulation" or l == "presimulation" or l == "prerender"
    end
    return false
end

local function isPriorityArg(x)
    if type(x) == "number" then return true end
    if type(x) == "string" then
        local l = x:lower():gsub("[%s_]+", "")
        if l == "high" or l == "physics" or l == "movement" or l == "60hz" or l == "60" or l == "1"
            or l == "medium" or l == "med" or l == "esp" or l == "radar" or l == "30hz" or l == "30" or l == "2"
            or l == "low" or l == "farm" or l == "autofarm" or l == "stat" or l == "ui" or l == "15hz" or l == "15" or l == "4"
            or l == "eco" or l == "5hz" or l == "5" or l == "idle" or l == "1hz" then
            return true
        end
        local num = tonumber((l:gsub("hz", "")))
        if num and num > 0 then return true end
    end
    return false
end

local function parseThrottledConnectArgs(arg1, arg2, arg3, arg4)
    local name, eventName, priorityStr, callback

    if type(arg4) == "function" then
        name, eventName, priorityStr, callback = arg1, arg2, arg3, arg4
    elseif type(arg3) == "function" then
        callback = arg3
        if isEventArg(arg1) then
            eventName = arg1
            priorityStr = arg2
            name = arg4
        elseif isEventArg(arg2) then
            name = arg1
            eventName = arg2
            priorityStr = "High"
        elseif isPriorityArg(arg2) then
            name = arg1
            eventName = "Heartbeat"
            priorityStr = arg2
        else
            eventName = arg1
            priorityStr = arg2
            name = arg4
        end
    elseif type(arg2) == "function" then
        callback = arg2
        if isEventArg(arg1) then
            eventName = arg1
            priorityStr = "High"
        elseif isPriorityArg(arg1) then
            eventName = "Heartbeat"
            priorityStr = arg1
        else
            name = arg1
            eventName = "Heartbeat"
            priorityStr = "High"
        end
    elseif type(arg1) == "function" then
        callback = arg1
        eventName = "Heartbeat"
        priorityStr = "High"
    else
        error("[VirtualScheduler]: Invalid arguments to ThrottledConnect. Expected (event, priority, callback, [name])", 2)
    end

    return name, eventName, priorityStr, callback
end

-- ThrottledConnect implementation
local function ThrottledConnect(arg1, arg2, arg3, arg4, arg5)
    local name, eventName, priorityStr, callback = parseThrottledConnectArgs(arg1, arg2, arg3, arg4)
    local isExecFlag = nil
    if type(arg5) == "boolean" then
        isExecFlag = arg5
    elseif type(arg4) == "boolean" then
        isExecFlag = arg4
    end

    local normEvent = normalizeEvent(eventName)
    local normPri, interval, targetHz, isMax, targetRatio, numPri = normalizePriority(priorityStr)

    local eventState = Events[normEvent]
    if not eventState then
        eventState = Events.Heartbeat
        normEvent = "Heartbeat"
    end

    -- Lazy connect RenderStepped if requested
    if (normEvent == "RenderStepped" or normEvent == "SuperStep") and not Events.RenderStepped.connection then
        Events.RenderStepped.connection = rawSignals.RenderStepped:Connect(function(...)
            processFrame(Events.RenderStepped, ...)
        end)
    end

    nextTaskId = nextTaskId + 1
    taskStaggerCounter = (taskStaggerCounter + 1) % 60

    local taskId = "task_" .. tostring(nextTaskId)
    if not name or name == "" then
        name = taskId
    end

    local isExec = isExecutorOrigin(name, name, isExecFlag)

    local savedOverride = getTaskOverride(name, normEvent)
    local savedLocked = false
    local savedPaused = false
    local savedSortOrder = nil

    if savedOverride then
        if savedOverride.priority then
            numPri, normPri = normalizeSchedulerPriority(savedOverride.priority)
        end
        if savedOverride.targetHz ~= nil then
            targetHz, interval, isMax, targetRatio = normalizeSchedulerTargetHz(savedOverride.targetHz)
        end
        if savedOverride.locked ~= nil then
            savedLocked = (savedOverride.locked == true)
        end
        if savedOverride.paused ~= nil then
            savedPaused = (savedOverride.paused == true)
        end
        savedSortOrder = savedOverride.sortOrder
    end

    local connection = {
        Connected = true,
        connected = true,
        Id = taskId,
        Name = name,
        Priority = numPri or 80,
        PriorityBand = normPri,
        TargetHz = targetHz,
        EffectiveHz = targetHz,
        Event = normEvent,
        IsExecutor = isExec,
    }

    local taskObj = {
        id = taskId,
        name = name,
        event = normEvent,
        isExecutor = isExec,
        priority = numPri or 80,
        basePriority = numPri or 80,
        priorityBand = normPri,
        sortOrder = savedSortOrder,
        targetHz = targetHz,
        effectiveHz = targetHz,
        interval = interval,
        isMax = isMax,
        targetRatio = targetRatio,
        offset = taskStaggerCounter,
        callback = callback,
        connection = connection,
        connected = true,
        paused = savedPaused,
        locked = savedLocked,
        isAsync = false,
        isRunning = false,
        invocations = 0,
        totalTimeMs = 0,
        lastTimeMs = 0,
        avgTimeMs = 0,
        peakTimeMs = 0,
        lastDurationUs = 0,
        errorCount = 0,
        lastError = nil,
        autoThrottled = false,
        demotions = 0,
        heavyStreak = 0,
        lightStreak = 0,
    }

    eventState.tasks[taskId] = taskObj
    connection.Task = taskObj
    table.insert(eventState.taskOrder, taskId)

    table.sort(eventState.taskOrder, function(a, b)
        local tA = eventState.tasks[a]
        local tB = eventState.tasks[b]
        local priA = getNumericTaskPriority(tA)
        local priB = getNumericTaskPriority(tB)
        if priA ~= priB then return priA > priB end
        local soA = (tA and tA.sortOrder) or 9999
        local soB = (tB and tB.sortOrder) or 9999
        if soA ~= soB then return soA < soB end
        return ((tA and tA.name) or ""):lower() < ((tB and tB.name) or ""):lower()
    end)

    function connection:Disconnect()
        if not self.Connected then return end
        self.Connected = false
        self.connected = false
        taskObj.connected = false
        eventState.tasks[taskId] = nil

        for idx, tid in ipairs(eventState.taskOrder) do
            if tid == taskId then
                table.remove(eventState.taskOrder, idx)
                break
            end
        end

        for idx, tid in ipairs(eventState.deferredQueue) do
            if tid == taskId then
                table.remove(eventState.deferredQueue, idx)
                break
            end
        end
    end
    connection.disconnect = connection.Disconnect

    function connection:Pause()
        taskObj.paused = true
        for idx, tid in ipairs(eventState.deferredQueue) do
            if tid == taskId then
                table.remove(eventState.deferredQueue, idx)
                break
            end
        end
    end
    connection.pause = connection.Pause

    function connection:Resume()
        taskObj.paused = false
    end
    connection.resume = connection.Resume

    function connection:SetPriority(newPri)
        local np, band = normalizeSchedulerPriority(newPri)
        taskObj.priority = np
        taskObj.basePriority = np
        taskObj.priorityBand = band
        self.Priority = np
        self.PriorityBand = band
        local ev = Events[taskObj.event]
        if ev and ev.taskOrder then
            table.sort(ev.taskOrder, function(a, b)
                local tA = ev.tasks[a]
                local tB = ev.tasks[b]
                return getNumericTaskPriority(tA) > getNumericTaskPriority(tB)
            end)
        end
        emitProfile()
    end
    connection.setPriority = connection.SetPriority

    function connection:SetTargetHz(newHz, customRatio)
        local tHz, interv, isMax, tRatio = normalizeSchedulerTargetHz(newHz, customRatio)
        taskObj.targetHz = tHz
        taskObj.effectiveHz = tHz
        taskObj.interval = interv
        taskObj.isMax = isMax
        taskObj.targetRatio = tRatio
        self.TargetHz = tHz
        self.EffectiveHz = tHz
        emitProfile()
    end
    connection.setTargetHz = connection.SetTargetHz
    connection.SetFrequency = connection.SetTargetHz
    connection.setFrequency = connection.SetTargetHz

    function connection:Lock()
        taskObj.locked = true
        taskObj.autoThrottled = false
        local targetHz = taskObj.targetHz or 60
        taskObj.effectiveHz = targetHz
        taskObj.interval = math.max(1, math.round(measuredFps / math.max(0.1, targetHz)))
    end
    connection.lock = connection.Lock

    function connection:Unlock()
        taskObj.locked = false
    end
    connection.unlock = connection.Unlock

    function connection:SetLocked(isLocked)
        taskObj.locked = (isLocked == true)
        if taskObj.locked then
            taskObj.autoThrottled = false
            local targetHz = taskObj.targetHz or 60
            taskObj.effectiveHz = targetHz
            taskObj.interval = math.max(1, math.round(measuredFps / math.max(0.1, targetHz)))
        end
    end
    connection.setLocked = connection.SetLocked

    return connection
end

-- ==============================================================================
-- Transparent Global Interception & Proxy Signals
-- ==============================================================================

local function getCallingContext(minLvl)
    local startLvl = minLvl or 3
    local anonymousCaller = nil
    if debug and debug.info then
        for lvl = startLvl, 15 do
            local src, line, fn = debug.info(lvl, "slf")
            if src and src ~= "[C]" then
                if rawSelf and rawSelf ~= "" and rawSelf ~= "[C]" and src == rawSelf then
                    -- Kernel internal frame, skip
                elseif src == "" then
                    if not anonymousCaller and line and line > 0 then
                        anonymousCaller = string.format("ExecutorScript:%d", line)
                    end
                else
                    local cleanSrc = tostring(src):gsub("^[@%[]", ""):gsub("^string \"", ""):gsub("\"\]$", "")
                    local fileName = cleanSrc:match("([^/\\]+)$") or cleanSrc
                    if not isSelfOrKernel(fileName) and not isSelfOrKernel(cleanSrc) then
                        if line and line > 0 then
                            return string.format("%s:%d", fileName, line)
                        else
                            return fileName
                        end
                    end
                end
            end
        end
    end
    if anonymousCaller then
        return anonymousCaller
    end
    if getcallingscript then
        local s = getcallingscript()
        if s and s.Name then
            local sName = tostring(s.Name)
            if sName ~= "" and not isSelfOrKernel(sName) then
                return sName
            end
        end
    end
    return "KernelInternal"
end

local function createSignalProxy(eventName)
    local proxy = {}
    proxy._eventName = eventName
    local rawSig = rawSignals[eventName]

    function proxy:Connect(callback)
        local callerName = getCallingContext()
        local isExec = (checkcaller and checkcaller())
        return ThrottledConnect(callerName, eventName, "High", callback, isExec)
    end
    proxy.connect = proxy.Connect

    function proxy:Wait()
        if rawSig then
            return rawSig:Wait()
        end
    end
    proxy.wait = proxy.Wait

    function proxy:Once(callback)
        local conn
        conn = proxy:Connect(function(...)
            if conn then
                conn:Disconnect()
            end
            return callback(...)
        end)
        return conn
    end
    proxy.once = proxy.Once

    return proxy
end

ProxiedSignals.Heartbeat = createSignalProxy("Heartbeat")
ProxiedSignals.Stepped = createSignalProxy("Stepped")
ProxiedSignals.RenderStepped = createSignalProxy("RenderStepped")
ProxiedSignals.PostSimulation = ProxiedSignals.Heartbeat
ProxiedSignals.PreSimulation = ProxiedSignals.Stepped
ProxiedSignals.PreRender = ProxiedSignals.RenderStepped

local function ProxiedBindToRenderStep(self, name, priority, callback)
    local wrapped = function(dt)
        local ok, err = xpcall(callback, function(e)
            return debug.traceback(tostring(e), 2)
        end, dt)
        if not ok then
            warn(string.format("[VirtualScheduler BindToRenderStep Error][%s]: %s", tostring(name), tostring(err)))
        end
    end
    boundRenderSteps[name] = true
    if rawBindToRenderStep then
        return rawBindToRenderStep(RunService, name, priority, wrapped)
    end
end

local function ProxiedUnbindFromRenderStep(self, name)
    boundRenderSteps[name] = nil
    if rawUnbindFromRenderStep then
        return rawUnbindFromRenderStep(RunService, name)
    end
end

getgenv()._VirtualSchedulerProxiedSignals = ProxiedSignals
getgenv()._VirtualSchedulerBoundRenderSteps = boundRenderSteps

-- ==============================================================================
-- Native SuperStep Implementation
-- ==============================================================================

local function RegisterSuperStep(arg1, arg2, arg3)
    local name, priorityStr, callback

    if type(arg3) == "function" then
        name = arg1
        priorityStr = arg2
        callback = arg3
    elseif type(arg2) == "function" then
        if isPriorityArg(arg1) then
            priorityStr = arg1
            callback = arg2
        else
            name = arg1
            callback = arg2
            priorityStr = "High"
        end
    elseif type(arg1) == "function" then
        callback = arg1
        if isPriorityArg(arg2) then
            priorityStr = arg2
        else
            priorityStr = "High"
        end
    else
        error("[VirtualScheduler]: Invalid arguments to SuperStep. Expected (callback) or (name, callback) or (name, priority, callback)", 2)
    end

    if not name or name == "" or name == "KernelInternal" then
        name = getCallingContext(3)
    end
    if not name or name == "" or name == "KernelInternal" then
        name = "SuperStepTask"
    end

    local isExec = checkcaller and checkcaller()
    local mainConn = ThrottledConnect(name, "SuperStep", priorityStr or "High", callback, isExec)

    local function createSubDummy(subName)
        local sub = {
            Connected = true,
            connected = true,
            Name = subName,
        }
        function sub:Disconnect()
            self.Connected = false
            self.connected = false
            if mainConn.Connected then
                mainConn:Disconnect()
            end
        end
        sub.disconnect = sub.Disconnect
        return sub
    end

    local superConn = {
        Heartbeat = createSubDummy("Heartbeat"),
        PostSimulation = createSubDummy("PostSimulation"),
        PreAnimation = createSubDummy("PreAnimation"),
        PreRender = createSubDummy("PreRender"),
        PreSimulation = createSubDummy("PreSimulation"),
        Stepped = createSubDummy("Stepped"),
        _RenderHooks = createSubDummy("_RenderHooks"),
    }

    local meta = {
        __index = function(t, k)
            if k == "Connected" or k == "connected" then
                return mainConn.Connected
            elseif k == "Disconnect" or k == "disconnect" then
                return function(self)
                    for _, sub in pairs(t) do
                        if type(sub) == "table" then
                            sub.Connected = false
                            sub.connected = false
                        end
                    end
                    return mainConn:Disconnect()
                end
            elseif k == "Pause" or k == "pause" then
                return function() return mainConn:Pause() end
            elseif k == "Resume" or k == "resume" then
                return function() return mainConn:Resume() end
            elseif k == "SetPriority" or k == "setPriority" then
                return function(self, p) return mainConn:SetPriority(p) end
            elseif k == "Lock" or k == "lock" then
                return function() return mainConn:Lock() end
            elseif k == "Unlock" or k == "unlock" then
                return function() return mainConn:Unlock() end
            elseif k == "SetLocked" or k == "setLocked" then
                return function(self, l) return mainConn:SetLocked(l) end
            elseif k == "Id" or k == "id" then
                return mainConn.Id
            elseif k == "Name" or k == "name" then
                return mainConn.Name
            elseif k == "Event" or k == "event" then
                return mainConn.Event
            elseif k == "Priority" or k == "priority" then
                return mainConn.Priority
            elseif k == "Task" or k == "task" then
                return mainConn
            end
            return mainConn[k]
        end,
        __tostring = function()
            return string.format("SuperStepConnection(%s, %s)", tostring(mainConn.Id), tostring(name))
        end,
    }

    setmetatable(superConn, meta)
    return superConn
end

--

-- ==============================================================================
-- System Performance & AutoExec Inspector Subsystem
-- ==============================================================================
local perfHistory = {
    fps = {},
    cpu = {},
    mem = {},
    ping = {},
    maxSamples = 60,
    lastSampleTime = 0,
}

local function recordPerfSample(fpsVal, cpuMs, memMb, pingMs)
    table.insert(perfHistory.fps, fpsVal or 60)
    table.insert(perfHistory.cpu, cpuMs or 0.05)
    table.insert(perfHistory.mem, memMb or (math.floor(((gcinfo() or 0) / 1024) * 10) / 10))
    table.insert(perfHistory.ping, pingMs or 30)

    if #perfHistory.fps > perfHistory.maxSamples then
        table.remove(perfHistory.fps, 1)
        table.remove(perfHistory.cpu, 1)
        table.remove(perfHistory.mem, 1)
        table.remove(perfHistory.ping, 1)
    end
end

-- Pre-populate history baseline for instant smooth rendering
for i = 1, 60 do
    table.insert(perfHistory.fps, measuredFps or 60)
    table.insert(perfHistory.cpu, 0.05)
    table.insert(perfHistory.mem, math.floor(((gcinfo() or 0) / 1024) * 10) / 10)
    table.insert(perfHistory.ping, 35)
end

local function getPerfStats()
    local minFps, maxFps, sumFps = 999, 0, 0
    for _, f in ipairs(perfHistory.fps) do
        if f < minFps then minFps = f end
        if f > maxFps then maxFps = f end
        sumFps = sumFps + f
    end
    local avgFps = (#perfHistory.fps > 0) and math.round(sumFps / #perfHistory.fps) or (measuredFps or 60)
    if minFps == 999 then minFps = avgFps end

    local peakCpu, sumCpu = 0, 0
    for _, c in ipairs(perfHistory.cpu) do
        if c > peakCpu then peakCpu = c end
        sumCpu = sumCpu + c
    end
    local avgCpu = (#perfHistory.cpu > 0) and (sumCpu / #perfHistory.cpu) or 0.05

    return {
        fps = perfHistory.fps,
        cpu = perfHistory.cpu,
        mem = perfHistory.mem,
        ping = perfHistory.ping,
        minFps = minFps,
        maxFps = maxFps,
        avgFps = avgFps,
        peakCpu = peakCpu,
        avgCpu = avgCpu,
    }
end

-- Startup AutoExec Manager
local function normStartupPath(p)
    if not p then return "" end
    p = p:gsub("[/\\]+", "/")
    p = p:gsub("^C:[^/]+/[^/]+/workspace/", "")
    p = p:gsub("^workspace/", "")
    p = p:gsub("/nodelay/", "/preinit/")
    p = p:gsub("^nodelay/", "preinit/")
    return p
end

local function updateScriptPragmas(filePath, newStage, newPriority)
    if not isfile or not readfile or not writefile then return false end
    local target = normStartupPath(filePath)
    if not isfile(target) and isfile("workspace/" .. target) then
        target = "workspace/" .. target
    end
    if not isfile(target) then return false end

    local ok, content = pcall(readfile, target)
    if not ok or not content then return false end

    local lines = {}
    for line in (content:match("\n$") and content or content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        table.insert(lines, line)
    end

    local stageIdx = nil
    local priorityIdx = nil
    local lastPragmaIdx = 0

    for i, line in ipairs(lines) do
        if line:match("^%-%-!stage%s*") then
            stageIdx = i
            lastPragmaIdx = math.max(lastPragmaIdx, i)
        elseif line:match("^%-%-!priority%s*") then
            priorityIdx = i
            lastPragmaIdx = math.max(lastPragmaIdx, i)
        elseif line:match("^%-%-!") then
            lastPragmaIdx = math.max(lastPragmaIdx, i)
        elseif not line:match("^%s*%-%-") and not line:match("^%s*$") then
            break
        end
    end

    if newStage then
        if stageIdx then
            lines[stageIdx] = "--!stage " .. newStage
        else
            table.insert(lines, lastPragmaIdx + 1, "--!stage " .. newStage)
            lastPragmaIdx = lastPragmaIdx + 1
            if priorityIdx and priorityIdx >= lastPragmaIdx then
                priorityIdx = priorityIdx + 1
            end
        end
    end

    if newPriority ~= nil then
        if priorityIdx then
            lines[priorityIdx] = "--!priority " .. tostring(newPriority)
        else
            table.insert(lines, lastPragmaIdx + 1, "--!priority " .. tostring(newPriority))
        end
    end

    local newContent = table.concat(lines, "\n")
    local writeOk = pcall(writefile, target, newContent)

    -- Also keep Bootloader_Status.json synchronized if present
    pcall(function()
        if isfile and isfile("Bootloader_Status.json") then
            local raw = readfile("Bootloader_Status.json")
            local data = HttpService:JSONDecode(raw)
            if data and data.scripts then
                local normTarget = normStartupPath(filePath):lower()
                for _, s in ipairs(data.scripts) do
                    local sf = normStartupPath(s.file or s.name):lower()
                    if sf == normTarget or sf:match("([^/]+)$") == normTarget:match("([^/]+)$") then
                        if newStage then s.stage = newStage end
                        if newPriority ~= nil then s.priority = newPriority end
                        s.file = normStartupPath(filePath)
                        break
                    end
                end
                writefile("Bootloader_Status.json", HttpService:JSONEncode(data))
            end
        end
    end)

    return writeOk
end

local function readScriptPragmas(filePath)
    local meta = { stage = nil, priority = nil }
    pcall(function()
        if not isfile or not readfile then return end
        local target = normStartupPath(filePath)
        if not isfile(target) and isfile("workspace/" .. target) then target = "workspace/" .. target end
        if not isfile(target) then return end
        local content = readfile(target)
        local head = content:sub(1, 1000)
        local st = head:match("%-%-!stage%s+([%w_]+)")
        if st then meta.stage = st end
        local pr = head:match("%-%-!priority%s+([%-%d]+)")
        if pr and tonumber(pr) then meta.priority = tonumber(pr) end
    end)
    return meta
end

local function isStartupIgnoredPath(p)
    local lower = normStartupPath(p):lower()
    local name = lower:match("([^/]+)$") or lower
    if name == "bootloader.lua" or name == "customautoexec.lua" or name == "omnibootloader.lua" or name == "bootloader_updated.lua" then
        return true
    end
    for seg in lower:gmatch("[^/]+") do
        if seg:sub(1, 1) == "." or seg:sub(1, 1) == "_" then
            return true
        end
        if seg == "backup" or seg == "backups" or seg == "temp" or seg == "tmp" or seg == "legacy" or seg == "archive" or seg == "node_modules" then
            return true
        end
    end
    if lower:find("_backup") or lower:find("%-backup") or lower:find("%.backup") or lower:find("%.bak$") or lower:find("%.tmp$") then
        return true
    end
    if lower:match("%.json$") or lower:match("%.png$") or lower:match("%.jpg$") or lower:match("%.md$") then
        return true
    end
    return false
end

local function isStartupScriptDisabled(p)
    local lower = normStartupPath(p):lower()
    if lower:match("%.off$") or lower:match("%.disabled$") then
        return true
    end
    for seg in lower:gmatch("[^/]+") do
        if seg == "off" or seg == "disabled" then
            return true
        end
    end
    return false
end

local function isStartupRelevantFolder(folderName)
    local l = folderName:lower()
    if l == "kernel" or l == "root" or l == "preinit" or l == "nodelay"
        or l == "gameloaded" or l == "characterloaded" or l == "characterready" or l == "deferred"
        or l == "universal" or l == "common" or l == "shared" or l == "off" or l == "disabled" then
        return true
    end
    local placeIdStr = tostring(game.PlaceId)
    local gameIdStr = tostring(game.GameId or 0)
    local accName = game:GetService("Players").LocalPlayer and game:GetService("Players").LocalPlayer.Name:lower() or ""
    if folderName == placeIdStr or folderName:sub(1, #placeIdStr + 3) == placeIdStr .. " - " or folderName:sub(1, #placeIdStr + 1) == placeIdStr .. "_" or l == "place_" .. placeIdStr then
        return true
    end
    if gameIdStr ~= "0" and (folderName == gameIdStr or folderName:sub(1, #gameIdStr + 3) == gameIdStr .. " - ") then
        return true
    end
    if accName ~= "" and (l == "account_" .. accName or l == accName or l == "user_" .. accName) then
        return true
    end
    return false
end

local lastStartupScanTime = 0
local cachedStartupList = nil

local function scanStartupScripts(forceRefresh)
    local now = os.clock()
    if not forceRefresh and cachedStartupList and (now - lastStartupScanTime) < 1.0 then
        return cachedStartupList
    end
    lastStartupScanTime = now

    local scripts = {}
    local knownFiles = {}
    local registeredBasenames = {}

    local function addScriptEntry(entry)
        local rawName = entry.name:gsub("%.%w+$", ""):lower()
        local dedupKey = entry.stage .. ":" .. rawName
        local existingIdx = registeredBasenames[dedupKey]
        if existingIdx then
            local old = scripts[existingIdx]
            local oldTarget = normStartupPath(old.file)
            local oldExists = isfile(oldTarget) or isfile("workspace/" .. oldTarget)
            if not oldExists then
                scripts[existingIdx] = entry
                return
            end
            if entry.file:lower():match("%.lua$") or entry.file:lower():match("%.luau$") then
                scripts[existingIdx] = entry
            end
            return
        end
        table.insert(scripts, entry)
        registeredBasenames[dedupKey] = #scripts
    end

    -- 1. Try reading Bootloader_Status.json
    local bootStatus = nil
    if isfile and isfile("Bootloader_Status.json") then
        local ok, data = pcall(function()
            local content = readfile("Bootloader_Status.json")
            return HttpService:JSONDecode(content)
        end)
        if ok and type(data) == "table" and data.scripts then
            bootStatus = data.scripts
        end
    end

    if bootStatus then
        for _, s in ipairs(bootStatus) do
            local filePath = normStartupPath(s.file or s.name)
            local target = filePath
            if not isfile(target) and isfile("workspace/" .. target) then
                target = "workspace/" .. target
            end
            if isfile(target) and not isStartupIgnoredPath(filePath) then
                knownFiles[filePath:lower()] = true
                local isOff = isStartupScriptDisabled(filePath) or (s.status == "DISABLED") or (s.status == "SKIPPED")
                local baseName = filePath:match("([^/]+)$") or filePath
                local cleanName = s.name or baseName:gsub("%.off$", ""):gsub("%.disabled$", "")
                local pragmas = readScriptPragmas(filePath)
                local curStage = pragmas.stage or s.stage or "GameLoaded"
                local curPriority = (pragmas.priority ~= nil) and pragmas.priority or (s.priority or 0)
                addScriptEntry({
                    name = cleanName,
                    file = filePath,
                    stage = curStage,
                    priority = curPriority,
                    compileMs = s.compileMs or 0,
                    execMs = s.execMs or 0,
                    status = isOff and "DISABLED" or (s.status or "SUCCESS"),
                    enabled = not isOff,
                })
            end
        end
    end

    -- 2. Scan folders for any additional active or disabled (.off / Off/) scripts
    local function scanDir(dir, depth)
        if not listfiles or not isfolder or not isfolder(dir) then return end
        local files = {}
        pcall(function() files = listfiles(dir) end)
        for _, fullPath in ipairs(files) do
            local rel = normStartupPath(fullPath)
            if isfolder(fullPath) then
                local folderName = fullPath:match("[^/\\]+$") or ""
                if not isStartupIgnoredPath(rel) then
                    if depth == 1 then
                        if isStartupRelevantFolder(folderName) then
                            scanDir(fullPath, depth + 1)
                        end
                    else
                        scanDir(fullPath, depth + 1)
                    end
                end
            else
                if not isStartupIgnoredPath(rel) then
                    local ext = rel:match("%.([^/]+)$") or ""
                    local isOff = isStartupScriptDisabled(rel)
                    if ext == "lua" or ext == "txt" or ext == "iy" or isOff then
                        local relKey = rel:lower()
                        if not knownFiles[relKey] then
                            knownFiles[relKey] = true
                            local baseName = rel:match("([^/]+)$") or rel
                            local cleanName = baseName:gsub("%.off$", ""):gsub("%.disabled$", "")
                            local pragmas = readScriptPragmas(rel)
                            local stage = pragmas.stage
                            if not stage then
                                if relKey:find("/kernel/") or relKey:find("^kernel/") then
                                    stage = "Kernel"
                                elseif relKey:find("/preinit/") or relKey:find("^preinit/") or relKey:find("/nodelay/") or relKey:find("^nodelay/") then
                                    stage = "PreInit"
                                else
                                    stage = "GameLoaded"
                                end
                            end
                            addScriptEntry({
                                name = cleanName,
                                file = rel,
                                stage = stage,
                                priority = pragmas.priority or 0,
                                compileMs = 0,
                                execMs = 0,
                                status = isOff and "DISABLED" or "READY",
                                enabled = not isOff,
                            })
                        end
                    end
                end
            end
        end
    end

    pcall(scanDir, "autoexec", 1)

    local STAGE_ORDER = { Kernel = 1, PreInit = 2, GameLoaded = 3, CharacterReady = 4, Deferred = 5 }
    table.sort(scripts, function(a, b)
        local oa = STAGE_ORDER[a.stage] or 10
        local ob = STAGE_ORDER[b.stage] or 10
        if oa ~= ob then return oa < ob end
        local pa = a.priority or 0
        local pb = b.priority or 0
        if pa ~= pb then return pa > pb end
        return a.name:lower() < b.name:lower()
    end)

    cachedStartupList = scripts
    return scripts
end

local function toggleStartupScript(filePath)
    if not isfile or not readfile or not writefile or not delfile then
        return false, "Filesystem APIs not available"
    end
    local target = normStartupPath(filePath)
    if not isfile(target) and isfile("workspace/" .. target) then
        target = "workspace/" .. target
    end
    if not isfile(target) then
        return false, "File not found: " .. tostring(filePath)
    end

    local isCurrentlyDisabled = isStartupScriptDisabled(target)
    local newPath

    if isCurrentlyDisabled then
        -- ENABLE:
        if target:find("%.off$") then
            newPath = target:gsub("%.off$", "")
        elseif target:find("%.disabled$") then
            newPath = target:gsub("%.disabled$", "")
        elseif target:lower():find("/off/") then
            newPath = target:gsub("/[Oo][Ff][Ff]/", "/")
        elseif target:lower():find("/disabled/") then
            newPath = target:gsub("/[Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd]/", "/")
        else
            newPath = target:gsub("%.off$", "")
        end
    else
        -- DISABLE:
        local dir, fname = target:match("^(.-)/([^/]+)$")
        if dir and isfolder and makefolder then
            local offDir = dir .. "/Off"
            if not isfolder(offDir) then pcall(makefolder, offDir) end
            if isfolder(offDir) then
                newPath = offDir .. "/" .. fname
            else
                newPath = target .. ".off"
            end
        else
            newPath = target .. ".off"
        end
    end

    local ok, err = pcall(function()
        local content = readfile(target)
        writefile(newPath, content)
        delfile(target)
    end)
    if ok then
        return true, not isCurrentlyDisabled, normStartupPath(newPath)
    else
        return false, tostring(err)
    end
end

local ingestedConnections = getgenv()._VirtualSchedulerIngestedConnections or setmetatable({}, { __mode = "k" })
getgenv()._VirtualSchedulerIngestedConnections = ingestedConnections
local persistedIngestedKeys = getgenv()._VirtualSchedulerPersistedIngestedKeys or {}
getgenv()._VirtualSchedulerPersistedIngestedKeys = persistedIngestedKeys

local function installGlobalHooks()
    if hookfunction and getgenv()._VirtualSchedulerOrigFireServer then
        pcall(hookfunction, Instance.new("RemoteEvent").FireServer, getgenv()._VirtualSchedulerOrigFireServer)
        getgenv()._VirtualSchedulerOrigFireServer = nil
    end
    if hookfunction and getgenv()._VirtualSchedulerOrigInvokeServer then
        pcall(hookfunction, Instance.new("RemoteFunction").InvokeServer, getgenv()._VirtualSchedulerOrigInvokeServer)
        getgenv()._VirtualSchedulerOrigInvokeServer = nil
    end

    if hookfunction and getgenv()._VirtualSchedulerOrigInstanceNew then
        pcall(hookfunction, Instance.new, getgenv()._VirtualSchedulerOrigInstanceNew)
        getgenv()._VirtualSchedulerOrigInstanceNew = nil
    end
    if hookfunction and type(Drawing) == "table" and getgenv()._VirtualSchedulerOrigDrawingNew then
        pcall(hookfunction, Drawing.new, getgenv()._VirtualSchedulerOrigDrawingNew)
        getgenv()._VirtualSchedulerOrigDrawingNew = nil
    end

    local origInstanceIndex = getgenv()._VirtualSchedulerOrigIndex
    local origInstanceNamecall = getgenv()._VirtualSchedulerOrigNamecall
    local RealRunService = RunService

    -- Adaptive Execution Gateway: Instant caller obfuscation detection
    local function isCallerObfuscated()
        if not debug or not debug.info then return false end
        for lvl = 2, 12 do
            local s = debug.info(lvl, "s")
            if not s then break end
            local l = tostring(s):lower()
            if l:find("luraph", 1, true) or l:find("lph", 1, true)
                or l:find("moonsec", 1, true) or l:find("ironbrew", 1, true)
                or l:find("luaauth", 1, true) or l:find("prometheus", 1, true)
                or l:find("psu", 1, true) or l:find("aztup", 1, true)
                or l:find("synapse xen", 1, true) or l:find("boron", 1, true)
                or l:find("wearedevs", 1, true) then
                return true
            end
            local exempt = _KernelExemptScripts or getgenv()._KernelExemptScripts
            if exempt then
                for pattern, _ in pairs(exempt) do
                    if l:find(pattern, 1, true) ~= nil then
                        return true
                    end
                end
            end
        end
        return false
    end

    local customIndex
    customIndex = (newcclosure and newcclosure or function(fn) return fn end)(function(self, key)
        -- STRICT CALLER ISOLATION: Game scripts (checkcaller() == false) MUST NEVER be intercepted!
        if not (checkcaller and checkcaller()) then
            local orig = origInstanceIndex or getgenv()._VirtualSchedulerOrigIndex
            if orig then
                return orig(self, key)
            end
            return
        end

        -- ADAPTIVE EXECUTION GATEWAY: Obfuscated third-party scripts pass through untouched to virgin engine
        if isCallerObfuscated() then
            local orig = origInstanceIndex or getgenv()._VirtualSchedulerOrigIndex
            if orig then
                return orig(self, key)
            end
            return
        end

        if self == RealRunService then
            local sigs = getgenv()._VirtualSchedulerProxiedSignals or ProxiedSignals
            if key == "Heartbeat" or key == "PostSimulation" then
                return sigs.Heartbeat
            elseif key == "Stepped" or key == "PreSimulation" then
                return sigs.Stepped
            elseif key == "RenderStepped" or key == "PreRender" then
                return sigs.RenderStepped
            elseif key == "BindToRenderStep" then
                return ProxiedBindToRenderStep
            elseif key == "UnbindFromRenderStep" then
                return ProxiedUnbindFromRenderStep
            end
        end
        local orig = origInstanceIndex or getgenv()._VirtualSchedulerOrigIndex
        if orig then
            return orig(self, key)
        end
    end)

    -- Primary: hookmetamethod (Potassium, Synapse, modern Luau executors)
    -- Disabled by default to preserve 100% virgin metatables for third-party scripts (Luraph v14)
    if hookmetamethod and getgenv()._OmniEnableMetamethodHooks then
        local ok, oldIdx = pcall(hookmetamethod, game, "__index", customIndex)
        if ok and oldIdx and not origInstanceIndex then
            origInstanceIndex = oldIdx
            getgenv()._VirtualSchedulerOrigIndex = oldIdx
        end
    end

    -- Fallback: getrawmetatable + setreadonly (Sirhurt, older executors)
    if not origInstanceIndex and getrawmetatable and setreadonly and getgenv()._OmniEnableMetamethodHooks then
        local ok, mt = pcall(getrawmetatable, game)
        if ok and mt then
            pcall(setreadonly, mt, false)
            if not origInstanceIndex and mt.__index then
                origInstanceIndex = mt.__index
                getgenv()._VirtualSchedulerOrigIndex = origInstanceIndex
                mt.__index = customIndex
            end
            pcall(setreadonly, mt, true)
        end
    end

    getgenv()._VirtualSchedulerHooksActive = (getgenv()._OmniEnableMetamethodHooks == true)
    getgenv()._VirtualSchedulerOrigIndex = origInstanceIndex
    getgenv()._VirtualSchedulerOrigNamecall = nil
end

installGlobalHooks()

-- ==============================================================================
-- Transparent GameProxy Provider for Un-Obfuscated Scripts
-- ==============================================================================
local origGame = (workspace and workspace.Parent) or game
local function createGameProxy(proxiedRS)
    proxiedRS = proxiedRS or ProxiedRunService or getgenv()._VirtualSchedulerProxiedRunService or getgenv().RunService
    local gameProxy = newproxy(true)
    local mt = getmetatable(gameProxy)
    local function getRS()
        return proxiedRS or ProxiedRunService or getgenv()._VirtualSchedulerProxiedRunService or getgenv().RunService
    end
    mt.__index = function(self, key)
        if key == "GetService" or key == "FindService" or key == "service" then
            return function(_, serviceName)
                if serviceName == "RunService" then return getRS() end
                return origGame:GetService(serviceName)
            end
        elseif key == "RunService" then
            return getRS()
        end
        local val = origGame[key]
        if type(val) == "function" then
            return function(_, ...)
                return val(origGame, ...)
            end
        end
        return val
    end
    mt.__namecall = function(self, ...)
        local method = (getnamecallmethod and getnamecallmethod()) or ""
        if method == "GetService" or method == "FindService" or method == "service" then
            local serviceName = ...
            if serviceName == "RunService" then return getRS() end
            return origGame:GetService(serviceName)
        end
        return origGame[method](origGame, ...)
    end
    mt.__tostring = function() return tostring(origGame) end
    mt.__eq = function(a, b) return rawequal(a, b) or a == origGame or b == origGame end
    return gameProxy
end

getgenv()._OmniCreateGameProxy = createGameProxy
getgenv()._OmniGameProxy = createGameProxy(ProxiedRunService)
getgenv().game = getgenv()._OmniGameProxy

-- Wrap typeof so typeof(getgenv().game) and typeof(ProxiedRunService) return "Instance"
if not getgenv()._KernelOrigTypeof then
    local origTypeof = typeof
    getgenv()._KernelOrigTypeof = origTypeof
    getgenv().typeof = (newcclosure and newcclosure(function(obj)
        if rawequal(obj, getgenv()._OmniGameProxy)
            or (getgenv()._VirtualSchedulerProxiedRunService and rawequal(obj, getgenv()._VirtualSchedulerProxiedRunService))
            or (getgenv().RunService and rawequal(obj, getgenv().RunService)) then
            return "Instance"
        end
        return origTypeof(obj)
    end)) or function(obj)
        if rawequal(obj, getgenv()._OmniGameProxy)
            or (getgenv()._VirtualSchedulerProxiedRunService and rawequal(obj, getgenv()._VirtualSchedulerProxiedRunService))
            or (getgenv().RunService and rawequal(obj, getgenv().RunService)) then
            return "Instance"
        end
        return origTypeof(obj)
    end
end

-- Wrap getrawmetatable so getrawmetatable(getgenv().game) and getrawmetatable(RunService) return virgin metatables
if not getgenv()._KernelOrigGetrawmetatable and type(getrawmetatable) == "function" then
    local origGetrawmetatable = getrawmetatable
    getgenv()._KernelOrigGetrawmetatable = origGetrawmetatable
    getgenv().getrawmetatable = (newcclosure and newcclosure(function(obj)
        if rawequal(obj, getgenv()._OmniGameProxy) then
            return origGetrawmetatable(origGame)
        elseif (getgenv()._VirtualSchedulerProxiedRunService and rawequal(obj, getgenv()._VirtualSchedulerProxiedRunService))
            or (getgenv().RunService and rawequal(obj, getgenv().RunService)) then
            return origGetrawmetatable(rawRunService)
        end
        return origGetrawmetatable(obj)
    end)) or function(obj)
        if rawequal(obj, getgenv()._OmniGameProxy) then
            return origGetrawmetatable(origGame)
        elseif (getgenv()._VirtualSchedulerProxiedRunService and rawequal(obj, getgenv()._VirtualSchedulerProxiedRunService))
            or (getgenv().RunService and rawequal(obj, getgenv().RunService)) then
            return origGetrawmetatable(rawRunService)
        end
        return origGetrawmetatable(obj)
    end
end

-- Wrap cloneref so cloneref(ProxiedRunService) or cloneref(gameProxy) returns obj safely
if not getgenv()._KernelOrigCloneref and type(cloneref) == "function" then
    local origCloneref = cloneref
    getgenv()._KernelOrigCloneref = origCloneref
    getgenv().cloneref = (newcclosure and newcclosure(function(obj, ...)
        if not obj
            or rawequal(obj, getgenv()._OmniGameProxy)
            or (getgenv()._VirtualSchedulerProxiedRunService and rawequal(obj, getgenv()._VirtualSchedulerProxiedRunService))
            or (getgenv().RunService and rawequal(obj, getgenv().RunService))
            or typeof(obj) ~= "Instance" then
            return obj
        end
        return origCloneref(obj, ...)
    end)) or function(obj, ...)
        if not obj
            or rawequal(obj, getgenv()._OmniGameProxy)
            or (getgenv()._VirtualSchedulerProxiedRunService and rawequal(obj, getgenv()._VirtualSchedulerProxiedRunService))
            or (getgenv().RunService and rawequal(obj, getgenv().RunService))
            or typeof(obj) ~= "Instance" then
            return obj
        end
        return origCloneref(obj, ...)
    end
end

getgenv()._KernelWrappedTypeof = getgenv().typeof
getgenv()._KernelWrappedGetrawmetatable = getgenv().getrawmetatable
getgenv()._KernelWrappedCloneref = getgenv().cloneref

-- ==============================================================================
-- Game Tasks Discovery & Selective Ingestion Subsystem
-- ==============================================================================

local DiscoveredGameTaskGroups = {}  -- [groupKey] = groupEntry
local DiscoveredGameTaskOrder = {}   -- array of groupEntry
local nextGameTaskId = 0

local function buildGameTasksProfile()
    local list = {}
    for _, entry in ipairs(DiscoveredGameTaskOrder) do
        table.insert(list, {
            id = entry.id,
            name = entry.name,
            displayName = if (entry.count and entry.count > 1) then string.format("%s (x%d)", entry.name, entry.count) else entry.name,
            count = entry.count or 1,
            source = entry.source,
            line = entry.line,
            event = entry.event,
            isIngested = (entry.isIngested == true),
            taskId = entry.taskId,
            connected = (entry.connected ~= false)
        })
    end
    return list
end

DiscardIngestedGameTask = function(group)
    if not group then return end

    -- 1. Stop scheduler proxy task immediately
    if group.schedulerConn then
        pcall(function() group.schedulerConn:Disconnect() end)
        group.schedulerConn = nil
    end
    if group.taskId then
        local tid = group.taskId
        group.taskId = nil
        pcall(function() KillSchedulerTask(tid) end)
    end

    -- 2. Safely re-enable any still-connected native connections before clearing
    if group.connList then
        for _, c in ipairs(group.connList) do
            if c then
                pcall(function()
                    if c.Connected ~= false then
                        if c.Enable then
                            c:Enable()
                        elseif c.Enabled ~= nil then
                            c.Enabled = true
                        end
                    end
                end)
                if ingestedConnections then
                    ingestedConnections[c] = nil
                end
            end
        end
    end
    if ingestedConnections then
        for c, g in pairs(ingestedConnections) do
            if g == group then
                pcall(function()
                    if c.Connected ~= false then
                        if c.Enable then
                            c:Enable()
                        elseif c.Enabled ~= nil then
                            c.Enabled = true
                        end
                    end
                end)
                ingestedConnections[c] = nil
            end
        end
    end

    -- 3. Mark state as dead/cleared
    group.isIngested = false
    group.fnList = nil
    group.connList = {}
    group.count = 0
    group.connected = false

    -- 4. Unregister from groups and order
    if DiscoveredGameTaskGroups[group.key] == group then
        DiscoveredGameTaskGroups[group.key] = nil
    end
    for idx = #DiscoveredGameTaskOrder, 1, -1 do
        if DiscoveredGameTaskOrder[idx] == group then
            table.remove(DiscoveredGameTaskOrder, idx)
        end
    end

    if _G.KernelDebug then
        print(string.format("[VirtualScheduler]: Auto-cleared discarded game task: %s (%s)", tostring(group.name), tostring(group.event)))
    end

    emitProfile()
end

local function IsGroupAliveInSignal(group)
    if not group or not group.event then return false end

    -- 1. Direct connection state check: If any tracked connection in the group is still connected
    if group.connList and #group.connList > 0 then
        local anyLive = false
        for _, c in ipairs(group.connList) do
            if c and c.Connected ~= false then
                anyLive = true
                break
            end
        end
        if anyLive then
            return true
        end
    end

    -- 2. Fast script instance ancestry check: only discard if no live connections and parented out
    if group.scriptInstance then
        local ok, isDesc = pcall(function() return group.scriptInstance:IsDescendantOf(game) end)
        if ok and isDesc == false then
            return false
        end
    end

    -- 2. Check getconnections for this event signal
    local raw = getgenv()._VirtualSchedulerRawSignals or rawSignals
    local sig = raw and raw[group.event]
    if not sig or not getconnections then return true end

    local ok, conns = pcall(getconnections, sig)
    if not ok or type(conns) ~= "table" then return true end

    local fns = group.fnList
    if fns and #fns > 0 then
        local fnSet = {}
        for i = 1, #fns do
            fnSet[fns[i]] = true
        end
        for j = 1, #conns do
            local c = conns[j]
            if c and c.Connected ~= false and fnSet[c.Function] then
                return true
            end
        end
        return false
    end

    return true
end

local checkPendingIngested = false
local function CheckAllIngestedTasksLiveness()
    checkPendingIngested = false
    for idx = #DiscoveredGameTaskOrder, 1, -1 do
        local g = DiscoveredGameTaskOrder[idx]
        if g and g.isIngested then
            if not IsGroupAliveInSignal(g) then
                DiscardIngestedGameTask(g)
            end
        end
    end
end

RequestIngestedLivenessCheck = function()
    if not checkPendingIngested then
        checkPendingIngested = true
        task.defer(CheckAllIngestedTasksLiveness)
    end
end

local function ScanGameTasks()
    if not getconnections then return DiscoveredGameTaskOrder end
    local raw = getgenv()._VirtualSchedulerRawSignals or rawSignals
    if not raw then return DiscoveredGameTaskOrder end

    local targetEvents = { "Heartbeat", "Stepped", "RenderStepped" }
    local currentActiveKeys = {}
    local scanGroups = {}

    for _, evName in ipairs(targetEvents) do
        local sig = raw[evName]
        if sig then
            local ok, conns = pcall(getconnections, sig)
            if ok and type(conns) == "table" then
                for _, c in ipairs(conns) do
                    if c and type(c.Function) == "function" and c.Connected ~= false then
                        local src, line = debug.info(c.Function, "sl")
                        local sInst = c.Script
                        local sFullName = sInst and sInst:GetFullName() or tostring(src or "")
                        local sLower = sFullName:lower()
                        local srcLower = tostring(src or ""):lower()

                        local isInternal = isSelfOrKernel(src)
                            or isSelfOrKernel(sFullName)
                            or sLower:find("corepackages", 1, true) ~= nil
                            or sLower:find("robloxgui", 1, true) ~= nil
                            or sLower:find("corescripts", 1, true) ~= nil
                            or src == "[C]"
                            or src == ""

                        local isExec = sLower:find(".lua", 1, true) ~= nil
                            or sLower:find(".txt", 1, true) ~= nil
                            or sLower:find(".iy", 1, true) ~= nil
                            or sLower:find("autoexec", 1, true) ~= nil
                            or sLower:find("potassium", 1, true) ~= nil
                            or sLower:find("banana", 1, true) ~= nil
                            or srcLower:find(".lua", 1, true) ~= nil
                            or srcLower:find(".txt", 1, true) ~= nil
                            or srcLower:find("autoexec", 1, true) ~= nil

                        if not isInternal and not isExec then
                            local cleanSrc = sInst and sInst:GetFullName() or tostring(src):gsub("^[@%[]", ""):gsub("^string \"", ""):gsub("\"%]$", "")
                            local displayName = (line and line > 0) and string.format("%s:%d", cleanSrc, line) or cleanSrc
                            local groupKey = string.format("%s@%s", displayName, evName)

                            currentActiveKeys[groupKey] = true

                            if not scanGroups[groupKey] then
                                scanGroups[groupKey] = {
                                    key = groupKey,
                                    name = displayName,
                                    source = cleanSrc,
                                    line = line or 0,
                                    event = evName,
                                    scriptInstance = sInst,
                                    conns = {},
                                    seenFuncs = {},
                                }
                            end

                            local sg = scanGroups[groupKey]
                            if not sg.seenFuncs[c.Function] then
                                sg.seenFuncs[c.Function] = true
                                table.insert(sg.conns, c)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sync scanGroups into DiscoveredGameTaskGroups and DiscoveredGameTaskOrder
    for groupKey, sg in pairs(scanGroups) do
        local group = DiscoveredGameTaskGroups[groupKey]
        if not group then
            nextGameTaskId = nextGameTaskId + 1
            local gId = "game_" .. tostring(nextGameTaskId)
            group = {
                id = gId,
                key = groupKey,
                name = sg.name,
                source = sg.source,
                line = sg.line,
                event = sg.event,
                scriptInstance = sg.scriptInstance,
                connList = sg.conns,
                count = #sg.conns,
                isIngested = false,
                taskId = nil,
                schedulerConn = nil,
                connected = true,
            }
            DiscoveredGameTaskGroups[groupKey] = group
            table.insert(DiscoveredGameTaskOrder, group)

            -- PERSISTENT INGESTION AUTO-ADOPTION:
            -- If this task was previously marked for ingestion, automatically re-ingest the reconnected task!
            if persistedIngestedKeys[groupKey] then
                task.defer(function()
                    if not group.isIngested and DiscoveredGameTaskGroups[groupKey] == group then
                        IngestGameTask(group.id)
                    end
                end)
            end
        else
            group.scriptInstance = sg.scriptInstance or group.scriptInstance
            if not group.isIngested then
                group.connList = sg.conns
                group.count = #sg.conns
                group.connected = true
                if persistedIngestedKeys[groupKey] then
                    task.defer(function()
                        if not group.isIngested and DiscoveredGameTaskGroups[groupKey] == group then
                            IngestGameTask(group.id)
                        end
                    end)
                end
            else
                -- Group is currently ingested: synchronize live connection state without duplicating
                local fnSet = {}
                if group.fnList then
                    for _, fn in ipairs(group.fnList) do fnSet[fn] = true end
                else
                    group.fnList = {}
                end

                for _, c in ipairs(sg.conns) do
                    if c and c.Connected ~= false then
                        local fn = c.Function
                        if type(fn) == "function" and not fnSet[fn] then
                            fnSet[fn] = true
                            table.insert(group.fnList, fn)
                        end
                        -- In-flight re-adoption: If the game reconnected this function, disable it immediately
                        -- so it never double-fires natively!
                        if c.Enabled ~= false then
                            pcall(function()
                                if c.Disable then
                                    c:Disable()
                                elseif c.Enabled ~= nil then
                                    c.Enabled = false
                                end
                            end)
                        end
                        ingestedConnections[c] = group
                    end
                end

                -- Accurately reflect the current live count without accumulating duplicates
                group.connList = sg.conns
                group.count = #sg.conns
                group.connected = true
            end
        end
    end

    -- Clean up stale groups that disappeared (or were disconnected/discarded while ingested)
    local i = 1
    while i <= #DiscoveredGameTaskOrder do
        local group = DiscoveredGameTaskOrder[i]
        if group then
            if not currentActiveKeys[group.key] then
                if group.isIngested then
                    -- The game discarded / disconnected this real task while it was ingested!
                    -- Cleanly discard and tear down the proxy scheduler task!
                    DiscardIngestedGameTask(group)
                else
                    DiscoveredGameTaskGroups[group.key] = nil
                    table.remove(DiscoveredGameTaskOrder, i)
                end
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end

    return DiscoveredGameTaskOrder
end

local function findDiscoveredGameTask(identifier)
    if not identifier then return nil end
    if typeof(identifier) == "table" and (identifier.key or identifier.id) then
        return identifier
    end
    for _, group in ipairs(DiscoveredGameTaskOrder) do
        if group.id == identifier or group.name == identifier or group.key == identifier or group.taskId == identifier then
            return group
        end
        if typeof(identifier) == "userdata" or typeof(identifier) == "table" then
            if group.connList then
                for _, c in ipairs(group.connList) do
                    if c == identifier then return group end
                end
            end
        end
    end
    return nil
end

IngestGameTask = function(identifier)
    local group = findDiscoveredGameTask(identifier)
    if not group then return false, "Task not found" end
    if group.isIngested then return false, "Task already ingested" end

    -- Disable all native connections in group and pre-cache closures
    group.fnList = {}
    for _, c in ipairs(group.connList) do
        if c then
            local fn = nil
            pcall(function() fn = c.Function end)
            if type(fn) == "function" then
                table.insert(group.fnList, fn)
            end

            pcall(function()
                if c.Connected ~= false then
                    if c.Disable then
                        c:Disable()
                    elseif c.Enabled ~= nil then
                        c.Enabled = false
                    end
                end
            end)
            ingestedConnections[c] = group
        end
    end

    -- Group callback executing all member callbacks
    local function groupCallback(...)
        local fns = group.fnList
        if fns and #fns > 0 then
            for i = 1, #fns do
                local fn = fns[i]
                if type(fn) == "function" then
                    local ok, err = pcall(fn, ...)
                    if not ok and _G.KernelDebug then
                        warn("[GameTask Error]", group.name, err)
                    end
                end
            end
        else
            local conns = group.connList
            if conns then
                for i = 1, #conns do
                    local c = conns[i]
                    if c and c.Connected ~= false then
                        local fn = nil
                        pcall(function() fn = c.Function end)
                        if type(fn) == "function" then
                            local ok, err = pcall(fn, ...)
                            if not ok and _G.KernelDebug then
                                warn("[GameTask Error]", group.name, err)
                            end
                        end
                    end
                end
            end
        end
    end

    local taskLabel = if group.count > 1 then string.format("%s (x%d)", group.name, group.count) else group.name
    local conn = ThrottledConnect(taskLabel, group.event, "High", groupCallback, false)
    if conn and (conn.Task or conn.Id) then
        local tObj = conn.Task or (findTask and findTask(conn.Id))
        if tObj then
            tObj.isIngested = true
            tObj.isHardRealTime = true
            tObj.gameGroup = group
            tObj.nativeConn = group.connList and group.connList[1]
            tObj.identity = 2
        end
        group.taskId = conn.Id or (tObj and tObj.id)
        group.schedulerConn = conn
        group.isIngested = true
        if group.key then
            persistedIngestedKeys[group.key] = true
            getgenv()._VirtualSchedulerPersistedIngestedKeys = persistedIngestedKeys
        end
    end

    emitProfile()
    return true, group.taskId
end

local function EjectGameTask(identifier)
    local group = findDiscoveredGameTask(identifier)
    if not group then return false, "Task not found" end
    if not group.isIngested then return false, "Task is not ingested" end

    -- 1. Disconnect scheduler proxy FIRST
    if group.schedulerConn then
        pcall(function() group.schedulerConn:Disconnect() end)
        group.schedulerConn = nil
    end
    if group.taskId then
        local tid = group.taskId
        group.taskId = nil
        pcall(function() KillSchedulerTask(tid) end)
    end

    -- 2. Safely re-enable all native connections in this group
    if group.connList then
        for _, c in ipairs(group.connList) do
            if c then
                pcall(function()
                    if c.Connected ~= false then
                        if c.Enable then
                            c:Enable()
                        elseif c.Enabled ~= nil then
                            c.Enabled = true
                        end
                    end
                end)
                ingestedConnections[c] = nil
            end
        end
    end

    -- Ensure any connections associated with this group in the global registry are cleaned up
    if ingestedConnections then
        for c, g in pairs(ingestedConnections) do
            if g == group then
                pcall(function()
                    if c.Connected ~= false then
                        if c.Enable then
                            c:Enable()
                        elseif c.Enabled ~= nil then
                            c.Enabled = true
                        end
                    end
                end)
                ingestedConnections[c] = nil
            end
        end
    end

    group.isIngested = false
    group.fnList = nil
    group.connList = {}
    group.count = 0
    if group.key then
        persistedIngestedKeys[group.key] = nil
        getgenv()._VirtualSchedulerPersistedIngestedKeys = persistedIngestedKeys
    end

    task.defer(function()
        ScanGameTasks()
        emitProfile()
    end)

    emitProfile()
    return true
end

local function IngestEngineConnections(filterPattern)
    ScanGameTasks()
    local count = 0
    for _, group in ipairs(DiscoveredGameTaskOrder) do
        if not group.isIngested then
            local lower = group.name:lower()
            local shouldIngest = true
            if filterPattern and filterPattern ~= "" then
                shouldIngest = (lower:find(filterPattern:lower(), 1, true) ~= nil)
            else
                local isFragile = lower:find("rbxcharactersounds", 1, true)
                    or lower:find("bullet", 1, true)
                    or lower:find("emitter", 1, true)
                    or lower:find("ragdoll", 1, true)
                    or lower:find("anticheat", 1, true)
                if isFragile then
                    shouldIngest = false
                end
            end
            if shouldIngest then
                local ok = IngestGameTask(group.id)
                if ok then count = count + 1 end
            end
        end
    end
    emitProfile()
    return count
end

-- ==============================================================================
-- Loop Governor & Preemptive Thread Manager Subsystem
-- ==============================================================================

local loopRegistry = getgenv()._OmniLoopRegistry or setmetatable({}, { __mode = "k" })
getgenv()._OmniLoopRegistry = loopRegistry
local loopOrder = getgenv()._OmniLoopOrder or {}
getgenv()._OmniLoopOrder = loopOrder
local ignoredThreads = getgenv()._OmniIgnoredThreads or setmetatable({}, { __mode = "k" })
getgenv()._OmniIgnoredThreads = ignoredThreads
local loopIdCounter = getgenv()._OmniLoopIdCounter or 0
local loopsPausedAll = false

local origTaskWait = getgenv()._KernelOrigTaskWait
local origWait = getgenv()._KernelOrigWait
local rawTaskWait = origTaskWait or (task and task.wait) or (getgenv().task and getgenv().task.wait)
local rawWait = origWait or wait or getgenv().wait

local HZ_CYCLE_LIST = { 60, 30, 15, 5, 1, 0 } -- 0 means Max / Uncapped

local function buildLoopProfile()
    local now = os.clock()
    local list = {}
    local activeCount = 0
    local totalLoopCpuMs = 0
    local deadThreads = {}

    for thread, loop in pairs(loopRegistry) do
        local isDead = false
        pcall(function()
            if coroutine.status(thread) == "dead" then
                isDead = true
            end
        end)

        -- Check if thread is dead. If suspended/running, calculate stale threshold based on last requested wait duration
        local waitLimit = math.max(60.0, ((loop.lastWaitRequested or 0) * 2) + 15.0)
        if not isDead and not loop.paused and (now - (loop.lastYieldTime or now)) > waitLimit then
            isDead = true
        end

        if isDead or not loop.alive or isSelfOrKernel(loop.caller) or isSelfOrKernel(loop.file) then
            table.insert(deadThreads, thread)
        else
            if not loop.paused then
                activeCount = activeCount + 1
                totalLoopCpuMs = totalLoopCpuMs + (loop.avgTimeMs or 0)
            end

            -- Prune recent timestamps older than 1.0s
            local valid = {}
            for _, ts in ipairs(loop.recentTimestamps) do
                if now - ts <= 1.0 then
                    table.insert(valid, ts)
                end
            end
            loop.recentTimestamps = valid
            loop.frequencyHz = #valid

            table.insert(list, {
                id = loop.id,
                name = loop.name,
                file = loop.file,
                line = loop.line,
                caller = loop.caller,
                isExecutor = (loop.isExecutor ~= false),
                priority = loop.priority or 50,
                sortOrder = loop.sortOrder,
                iterations = loop.iterations,
                frequencyHz = loop.frequencyHz,
                targetHz = loop.targetHz,
                minDelay = loop.minDelay,
                lastDurationUs = loop.lastDurationUs,
                lastTimeMs = loop.lastTimeMs,
                avgTimeMs = loop.avgTimeMs,
                recentAvgMs = loop.recentAvgMs,
                peakTimeMs = loop.peakTimeMs,
                paused = loop.paused,
                locked = loop.locked,
                autoThrottled = loop.autoThrottled,
                lastWaitRequested = loop.lastWaitRequested,
                alive = loop.alive
            })
        end
    end

    -- Clean up dead threads to prevent leaks and unbounded iteration
    if #deadThreads > 0 then
        local deadIdSet = {}
        for _, dt in ipairs(deadThreads) do
            local deadLoop = loopRegistry[dt]
            if deadLoop and deadLoop.id then
                deadIdSet[deadLoop.id] = true
            end
            loopRegistry[dt] = nil
        end
        local newOrder = {}
        for _, id in ipairs(loopOrder) do
            if not deadIdSet[id] then
                table.insert(newOrder, id)
            end
        end
        loopOrder = newOrder
    end

    table.sort(list, function(a, b)
        local pa = tonumber(a.priority) or 50
        local pb = tonumber(b.priority) or 50
        if pa ~= pb then return pa > pb end
        local soA = tonumber(a.sortOrder) or 9999
        local soB = tonumber(b.sortOrder) or 9999
        if soA ~= soB then return soA < soB end
        return (a.iterations or 0) > (b.iterations or 0)
    end)

    return {
        loops = list,
        totalLoops = #list,
        activeLoops = activeCount,
        totalLoopCpuMs = math.floor(totalLoopCpuMs * 1000) / 1000,
        pausedAll = loopsPausedAll
    }
end

local function registerOrUpdateLoop(thread, caller, requestedDelay, isExecFlag)
    local now = os.clock()
    local loop = loopRegistry[thread]

    if not loop then
        local callerStr = caller or "UnknownScript:0"
        if isSelfOrKernel(callerStr) then
            ignoredThreads[thread] = true
            return nil
        end
        local callerFile = callerStr:match("^([^:]+)") or callerStr
        if isSelfOrKernel(callerFile) then
            ignoredThreads[thread] = true
            return nil
        end

        -- CULL STALE DUPLICATES: Only prune older thread if it is genuinely dead
        for oldThread, oldLoop in pairs(loopRegistry) do
            if oldLoop.caller == callerStr and oldThread ~= thread then
                if not oldLoop.paused and coroutine.status(oldThread) == "dead" then
                    oldLoop.alive = false
                    loopRegistry[oldThread] = nil
                end
            end
        end

        loopIdCounter = loopIdCounter + 1
        local callerLine = tonumber(callerStr:match(":(%d+)$")) or 0
        local isExec = isExecutorOrigin(callerStr, callerStr, isExecFlag)
        local savedOverride = getLoopOverride(callerStr, callerStr)
        local initialPri = math.max(10, 100 - (#loopOrder * 5))
        local savedSortOrder = nil
        local savedTargetHz = nil
        local savedMinDelay = nil
        local savedLocked = false
        local savedPaused = (loopsPausedAll and isExec)

        if savedOverride then
            if savedOverride.priority ~= nil then
                initialPri = math.clamp(math.round(tonumber(savedOverride.priority) or 50), 1, 100)
            end
            if savedOverride.sortOrder ~= nil then
                savedSortOrder = tonumber(savedOverride.sortOrder)
            end
            if savedOverride.targetHz ~= nil then
                local thz = tonumber(savedOverride.targetHz)
                if thz and thz > 0 then
                    savedTargetHz = thz
                    savedMinDelay = 1 / thz
                else
                    savedTargetHz = nil
                    savedMinDelay = nil
                end
            end
            if savedOverride.locked ~= nil then
                savedLocked = (savedOverride.locked == true)
            end
            if savedOverride.paused ~= nil then
                savedPaused = (savedOverride.paused == true)
            end
        end

        loop = {
            id = "loop_" .. tostring(loopIdCounter),
            thread = thread,
            caller = callerStr,
            file = callerFile,
            line = callerLine,
            name = callerStr,
            isExecutor = isExec,
            priority = initialPri,
            sortOrder = savedSortOrder,
            iterations = 0,
            firstSeen = now,
            lastYieldTime = now,
            iterationStart = now,
            lastDurationUs = 0,
            lastTimeMs = 0,
            avgTimeMs = 0,
            recentAvgMs = 0,
            peakTimeMs = 0,
            frequencyHz = 0,
            targetHz = savedTargetHz,
            minDelay = savedMinDelay,
            paused = savedPaused,
            locked = savedLocked,
            autoThrottled = false,
            alive = true,
            recentTimestamps = {},
        }
        loopRegistry[thread] = loop
        table.insert(loopOrder, loop.id)
    else
        if loop.caller and loop.caller:find("^ExecutorScript:") then
            local resolvedCaller = getCallingContext(2)
            if resolvedCaller and not resolvedCaller:find("^ExecutorScript:") and not isSelfOrKernel(resolvedCaller) then
                loop.caller = resolvedCaller
                loop.name = resolvedCaller
                loop.file = resolvedCaller:match("^([^:]+)") or resolvedCaller
                local savedOverride = getLoopOverride(resolvedCaller, resolvedCaller)
                if savedOverride then
                    if savedOverride.priority ~= nil then
                        loop.priority = math.clamp(math.round(tonumber(savedOverride.priority) or 50), 1, 100)
                    end
                    if savedOverride.sortOrder ~= nil then
                        loop.sortOrder = tonumber(savedOverride.sortOrder)
                    end
                    if savedOverride.targetHz ~= nil then
                        local thz = tonumber(savedOverride.targetHz)
                        if thz and thz > 0 then
                            loop.targetHz = thz
                            loop.minDelay = 1 / thz
                        else
                            loop.targetHz = nil
                            loop.minDelay = nil
                        end
                    end
                    if savedOverride.locked ~= nil then
                        loop.locked = (savedOverride.locked == true)
                    end
                    if savedOverride.paused ~= nil then
                        loop.paused = (savedOverride.paused == true)
                    end
                end
            end
        end
        local durationUs = math.max(0, (now - (loop.iterationStart or now)) * 1000000)
        local durationMs = durationUs / 1000
        -- If durationMs > 50ms, the coroutine yielded on an RBXScriptSignal / event (:Wait()) between task.waits
        -- Clamp cpuMs to prevent idle event wait time from inflating Lua execution load
        local cpuMs = math.min(durationMs, 10.0)
        loop.lastDurationUs = durationUs
        loop.lastTimeMs = durationMs
        loop.avgTimeMs = (loop.avgTimeMs * 0.85) + (cpuMs * 0.15)
        loop.recentAvgMs = math.floor(loop.avgTimeMs * 1000) / 1000
        if cpuMs > (loop.peakTimeMs or 0) then
            loop.peakTimeMs = cpuMs
        end

        -- Autonomous Auto-Throttler: only downshift rapid tight loops (frequencyHz >= 15) that burn > 2.5ms per frame
        if loop.isExecutor and not loop.locked and loop.avgTimeMs > 2.5 and (loop.frequencyHz or 0) >= 15 and not loop.autoThrottled then
            loop.autoThrottled = true
            loop.targetHz = 15
            loop.minDelay = 1 / 15
        elseif loop.autoThrottled and loop.avgTimeMs < 0.8 and not loop.locked then
            loop.autoThrottled = false
            loop.targetHz = nil
            loop.minDelay = nil
        end

        table.insert(loop.recentTimestamps, now)
        if #loop.recentTimestamps > 60 then
            local valid = {}
            for _, ts in ipairs(loop.recentTimestamps) do
                if now - ts <= 1.0 then
                    table.insert(valid, ts)
                end
            end
            loop.recentTimestamps = valid
        end
        loop.frequencyHz = #loop.recentTimestamps
    end

    loop.iterations = loop.iterations + 1
    loop.lastYieldTime = now
    loop.lastWaitRequested = requestedDelay
    return loop
end

local function hookedTaskWait(duration)
    local waitFn = origTaskWait or rawTaskWait
    local isCallerExec = (checkcaller and checkcaller()) or false

    local curThread = coroutine.running()

    if ignoredThreads[curThread] then
        return waitFn(duration)
    end

    local loop = loopRegistry[curThread]
    if not loop then
        local caller = getCallingContext(2)
        if isSelfOrKernel(caller) then
            ignoredThreads[curThread] = true
            return waitFn(duration)
        elseif not caller then
            return waitFn(duration)
        end
        local isExec = isExecutorOrigin(caller, caller, isCallerExec)
        loop = registerOrUpdateLoop(curThread, caller, duration, isExec)
    else
        registerOrUpdateLoop(curThread, loop.caller, duration, loop.isExecutor)
    end

    if not loop then
        return waitFn(duration)
    end

    -- 1. Pause Trap: freeze loop while paused (only pause executor loops on Pause All)
    while (loop.paused or (loopsPausedAll and loop.isExecutor)) and loop.alive do
        waitFn(0.1)
    end

    -- 2. Clean Termination Check: yield permanently if loop is dead
    if not loop.alive then
        coroutine.yield()
        return
    end

    -- 3. Frequency Throttling Clamp:
    local effectiveDelay = duration or 0
    if loop.minDelay and loop.minDelay > effectiveDelay then
        effectiveDelay = loop.minDelay
    end

    local res = waitFn(effectiveDelay)
    loop.iterationStart = os.clock()
    return res
end

local function hookedWait(duration)
    local waitFn = origWait or rawWait or origTaskWait or rawTaskWait
    local isCallerExec = (checkcaller and checkcaller()) or false

    local curThread = coroutine.running()

    if ignoredThreads[curThread] then
        local d, t = waitFn(duration)
        return d, t or (workspace and workspace.DistributedGameTime) or os.clock()
    end

    local loop = loopRegistry[curThread]
    if not loop then
        local caller = getCallingContext(2)
        if isSelfOrKernel(caller) then
            ignoredThreads[curThread] = true
            local d, t = waitFn(duration)
            return d, t or (workspace and workspace.DistributedGameTime) or os.clock()
        elseif not caller then
            local d, t = waitFn(duration)
            return d, t or (workspace and workspace.DistributedGameTime) or os.clock()
        end
        local isExec = isExecutorOrigin(caller, caller, isCallerExec)
        loop = registerOrUpdateLoop(curThread, caller, duration, isExec)
    else
        registerOrUpdateLoop(curThread, loop.caller, duration, loop.isExecutor)
    end

    if not loop then
        local d, t = waitFn(duration)
        return d, t or (workspace and workspace.DistributedGameTime) or os.clock()
    end

    -- 1. Pause Trap: freeze loop while paused (only pause executor loops on Pause All)
    while (loop.paused or (loopsPausedAll and loop.isExecutor)) and loop.alive do
        waitFn(0.1)
    end

    -- 2. Clean Termination Check: yield permanently if loop is dead
    if not loop.alive then
        coroutine.yield()
        return
    end

    -- 3. Frequency Throttling Clamp:
    local effectiveDelay = duration or 0
    if loop.minDelay and loop.minDelay > effectiveDelay then
        effectiveDelay = loop.minDelay
    end

    local d, t = waitFn(effectiveDelay)
    loop.iterationStart = os.clock()
    return d, t or (workspace and workspace.DistributedGameTime) or os.clock()
end

local function SetLoopPaused(loopIdOrThread, isPaused)
    for thread, loop in pairs(loopRegistry) do
        if loop.id == loopIdOrThread or thread == loopIdOrThread or loop.name == loopIdOrThread or loop.caller == loopIdOrThread then
            loop.paused = (isPaused == true)
            emitProfile()
            saveSchedulerOverrides()
            return true
        end
    end
    return false
end

local function SetLoopFrequency(loopIdOrThread, targetHz)
    for thread, loop in pairs(loopRegistry) do
        if loop.id == loopIdOrThread or thread == loopIdOrThread or loop.name == loopIdOrThread or loop.caller == loopIdOrThread then
            if targetHz and targetHz > 0 then
                loop.targetHz = targetHz
                loop.minDelay = 1 / targetHz
            else
                loop.targetHz = nil
                loop.minDelay = nil
            end
            emitProfile()
            saveSchedulerOverrides()
            return true
        end
    end
    return false
end

local function SetLoopLocked(loopIdOrThread, isLocked)
    for thread, loop in pairs(loopRegistry) do
        if loop.id == loopIdOrThread or thread == loopIdOrThread or loop.name == loopIdOrThread or loop.caller == loopIdOrThread then
            loop.locked = (isLocked == true)
            emitProfile()
            saveSchedulerOverrides()
            return true
        end
    end
    return false
end

local function SetLoopPriority(loopIdOrThread, newPriority, newSortOrder)
    for thread, loop in pairs(loopRegistry) do
        if loop.id == loopIdOrThread or thread == loopIdOrThread or loop.name == loopIdOrThread or loop.caller == loopIdOrThread then
            loop.priority = math.clamp(math.round(tonumber(newPriority) or 50), 1, 100)
            if newSortOrder ~= nil then
                loop.sortOrder = tonumber(newSortOrder)
            end
            emitProfile()
            saveSchedulerOverrides()
            return true, loop.priority
        end
    end
    return false
end

local function KillLoop(loopIdOrThread)
    for thread, loop in pairs(loopRegistry) do
        if loop.id == loopIdOrThread or thread == loopIdOrThread or loop.name == loopIdOrThread or loop.caller == loopIdOrThread then
            loop.alive = false
            loop.paused = false
            pcall(function()
                if coroutine.close then
                    coroutine.close(thread)
                end
            end)
            loopRegistry[thread] = nil
            for i, id in ipairs(loopOrder) do
                if id == loop.id then
                    table.remove(loopOrder, i)
                    break
                end
            end
            emitProfile()
            return true
        end
    end
    return false
end

local function PauseAllLoops(isPaused)
    loopsPausedAll = (isPaused ~= false)
    for _, loop in pairs(loopRegistry) do
        loop.paused = loopsPausedAll
    end
    emitProfile()
    return loopsPausedAll
end

local function KillAllLoops()
    local killedCount = 0
    for thread, loop in pairs(loopRegistry) do
        loop.alive = false
        loop.paused = false
        pcall(function()
            if coroutine.close then
                coroutine.close(thread)
            end
        end)
        killedCount = killedCount + 1
    end
    loopRegistry = {}
    loopOrder = {}
    emitProfile()
    return killedCount
end

local function ClearLoopRegistry()
    loopRegistry = {}
    loopOrder = {}
    emitProfile()
    return true
end

-- Install task.wait and wait hooks safely with dynamic delegation trampoline (Enabled by default; exempt scripts bypass via isSelfOrKernel)
getgenv()._OmniActiveHookedTaskWait = hookedTaskWait
getgenv()._OmniActiveHookedWait = hookedWait

if hookfunction and getgenv()._OmniEnableWaitHooks ~= false then
    if not getgenv()._OmniWaitTrampolineInstalled then
        if task and task.wait then
            pcall(function()
                local function taskWaitTrampoline(...)
                    local activeHook = getgenv()._OmniActiveHookedTaskWait
                    if activeHook then
                        return activeHook(...)
                    end
                    local orig = getgenv()._KernelOrigTaskWait
                    if orig then return orig(...) end
                    return ...
                end
                local hook = (newcclosure and newcclosure(taskWaitTrampoline)) or taskWaitTrampoline
                origTaskWait = hookfunction(task.wait, hook)
                getgenv()._KernelOrigTaskWait = origTaskWait
            end)
        else
            origTaskWait = getgenv()._KernelOrigTaskWait or (task and task.wait)
        end

        if wait then
            pcall(function()
                local function waitTrampoline(...)
                    local activeHook = getgenv()._OmniActiveHookedWait
                    if activeHook then
                        return activeHook(...)
                    end
                    local orig = getgenv()._KernelOrigWait
                    if orig then return orig(...) end
                    return ...
                end
                local hook = (newcclosure and newcclosure(waitTrampoline)) or waitTrampoline
                origWait = hookfunction(wait, hook)
                getgenv()._KernelOrigWait = origWait
            end)
        else
            origWait = getgenv()._KernelOrigWait or wait
        end
        getgenv()._OmniWaitTrampolineInstalled = true
    else
        origTaskWait = getgenv()._KernelOrigTaskWait or (task and task.wait)
        origWait = getgenv()._KernelOrigWait or wait
    end
else
    origTaskWait = getgenv()._KernelOrigTaskWait or (task and task.wait) or wait
    origWait = getgenv()._KernelOrigWait or wait or (task and task.wait)
end


-- ==============================================================================
-- Telemetry & Metrics
-- ==============================================================================

local function buildProfile()
    local now = os.time()
    local allTasks = {}
    local totalCpuMs = 0
    local activeCount = 0
    local totalErrors = 0

    for _, evName in ipairs(EVENT_NAMES) do
        local eventState = Events[evName]
        if eventState then
            for _, taskId in ipairs(eventState.taskOrder) do
                local taskObj = eventState.tasks[taskId]
                if taskObj then
                    local taskAvg = taskObj.recentAvgMs or taskObj.lastTimeMs or 0
                    local taskIntv = math.max(1, taskObj.interval or 1)
                    local amortizedMs = taskAvg / taskIntv

                    if taskObj.connected and not taskObj.paused then
                        activeCount = activeCount + 1
                        totalCpuMs = totalCpuMs + amortizedMs
                    end
                    totalErrors = totalErrors + (taskObj.errorCount or 0)

                    table.insert(allTasks, {
                        id = taskObj.id,
                        name = taskObj.name,
                        event = taskObj.event,
                        isExecutor = (taskObj.isExecutor ~= false),
                        isIngested = (taskObj.isIngested == true),
                        priority = taskObj.priority or 50,
                        priorityBand = taskObj.priorityBand or "High",
                        basePriority = taskObj.basePriority or taskObj.priority or 50,
                        sortOrder = taskObj.sortOrder,
                        targetHz = taskObj.targetHz or 60,
                        effectiveHz = taskObj.effectiveHz or taskObj.targetHz or 60,
                        interval = taskObj.interval,
                        isMax = taskObj.isMax or false,
                        targetRatio = taskObj.targetRatio,
                        autoThrottled = taskObj.autoThrottled or false,
                        demotions = taskObj.demotions or 0,
                        connected = taskObj.connected,
                        paused = taskObj.paused or false,
                        locked = taskObj.locked or false,
                        isAsync = taskObj.isAsync or false,
                        effectivePriority = taskObj.priority or 50,
                        invocations = taskObj.invocations,
                        lastDurationUs = taskObj.lastDurationUs,
                        lastTimeMs = taskObj.lastTimeMs,
                        avgTimeMs = taskObj.avgTimeMs,
                        recentAvgMs = math.floor((taskObj.recentAvgMs or taskObj.avgTimeMs or 0) * 1000) / 1000,
                        peakTimeMs = taskObj.peakTimeMs,
                        totalTimeMs = math.floor(taskObj.totalTimeMs * 1000) / 1000,
                        errorCount = taskObj.errorCount,
                        lastError = taskObj.lastError,
                        amortizedCpuMs = math.floor(amortizedMs * 1000) / 1000,
                        budgetPercent = math.floor((amortizedMs / (currentBudgetMs or 8.0)) * 10000) / 100,
                    })
                end
            end
        end
    end

    table.sort(allTasks, function(a, b)
        local pa = getNumericTaskPriority(a)
        local pb = getNumericTaskPriority(b)
        if pa ~= pb then return pa > pb end
        local soA = tonumber(a.sortOrder) or 9999
        local soB = tonumber(b.sortOrder) or 9999
        if soA ~= soB then return soA < soB end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    local activeFps = measuredFps or 60
    local physFps = 60
    pcall(function()
        if workspace and workspace.GetRealPhysicsFPS then
            physFps = math.floor(workspace:GetRealPhysicsFPS())
        end
    end)

        local loopProf = buildLoopProfile()
        local tasksCpuMs = math.floor(totalCpuMs * 1000) / 1000
        local loopsCpuMs = math.floor((loopProf.totalLoopCpuMs or 0) * 1000) / 1000
        local combinedCpuMs = math.floor((tasksCpuMs + loopsCpuMs) * 1000) / 1000
        local budgetPct = math.floor((combinedCpuMs / (currentBudgetMs or 8.0)) * 10000) / 100
        return {
            account = (Players.LocalPlayer and Players.LocalPlayer.Name) or "Unknown",
            placeId = game.PlaceId,
            jobId = game.JobId,
            timestamp = now,
            fps = activeFps,
            physicsFps = physFps,
            frameBudgetMs = currentBudgetMs,
            globalForceMode = "Off",
            totalActiveTasks = activeCount,
            totalTasks = #allTasks,
            taskCpuMs = tasksCpuMs,
            totalCpuMs = combinedCpuMs,
            budgetUsedPercent = budgetPct,
            totalErrors = totalErrors,
            events = {
                Heartbeat = {
                    frameCount = Events.Heartbeat.frameCount,
                    deferredCount = #Events.Heartbeat.deferredQueue,
                },
                Stepped = {
                    frameCount = Events.Stepped.frameCount,
                    deferredCount = #Events.Stepped.deferredQueue,
                },
                RenderStepped = {
                    frameCount = Events.RenderStepped.frameCount,
                    deferredCount = #Events.RenderStepped.deferredQueue,
                },
                SuperStep = {
                    frameCount = Events.SuperStep.frameCount,
                    deferredCount = #Events.SuperStep.deferredQueue,
                },
            },
            tasks = allTasks,
            memory = {
                heapMb = math.floor(((gcinfo() or 0) / 1024) * 10) / 10,
            },
            perf = getPerfStats(),
            startup = scanStartupScripts(),
            loops = loopProf.loops,
            totalActiveLoops = loopProf.activeLoops,
            totalLoops = loopProf.totalLoops,
            totalLoopCpuMs = loopProf.totalLoopCpuMs,
            gameTasks = buildGameTasksProfile(),
            totalGameTasks = #DiscoveredGameTaskOrder,
        }
    end

local lastProfileEmitTime = 0
local emitProfileScheduled = false
local cachedProfile = nil

emitProfile = function(force)
    if profilingActive == false then
        emitProfileScheduled = false
        return cachedProfile or (buildProfile and buildProfile())
    end
    local now = os.clock()
    if force or (now - lastProfileEmitTime >= 0.5) then
        lastProfileEmitTime = now
        emitProfileScheduled = false
        cachedProfile = buildProfile()
        pcall(function()
            if writefile and HttpService then
                writefile("Scheduler_Profile.json", HttpService:JSONEncode(cachedProfile))
            end
        end)
        return cachedProfile
    elseif not emitProfileScheduled then
        emitProfileScheduled = true
        task.delay(0.5, function()
            if emitProfileScheduled and profilingActive ~= false then
                emitProfile(true)
            end
        end)
    end
    return cachedProfile or (buildProfile and buildProfile())
end

SchedulerPersistence.save = function(immediate)
    if not (writefile and HttpService and HttpService.JSONEncode) then return end

    local placeKey = tostring(game.PlaceId or "0")
    SchedulerPersistence.data = SchedulerPersistence.data or {}
    SchedulerPersistence.data.places = SchedulerPersistence.data.places or {}
    SchedulerPersistence.data.global = SchedulerPersistence.data.global or { tasks = {}, loops = {} }

    local placeData = SchedulerPersistence.data.places[placeKey]
    if not placeData then
        placeData = { tasks = {}, loops = {} }
        SchedulerPersistence.data.places[placeKey] = placeData
    end
    placeData.tasks = placeData.tasks or {}
    placeData.loops = placeData.loops or {}

    -- Persist active tasks across all event queues
    for _, evName in ipairs(EVENT_NAMES) do
        local eventState = Events[evName]
        if eventState and eventState.tasks then
            for _, taskObj in pairs(eventState.tasks) do
                if taskObj and taskObj.name then
                    local taskKey = taskObj.name .. "@" .. (taskObj.event or evName)
                    placeData.tasks[taskKey] = {
                        priority = taskObj.basePriority or taskObj.userPriority or taskObj.priority,
                        sortOrder = taskObj.sortOrder,
                        targetHz = taskObj.targetHz,
                        interval = taskObj.interval,
                        isMax = taskObj.isMax,
                        locked = taskObj.locked,
                        paused = taskObj.paused,
                    }
                end
            end
        end
    end

    -- Persist active loops across thread registry (filter out exempt scripts & transient single yields)
    if loopRegistry then
        for thread, loop in pairs(loopRegistry) do
            local isAlive = loop.alive
            if isAlive then
                pcall(function()
                    if coroutine.status(thread) == "dead" then
                        isAlive = false
                    end
                end)
            end
            local loopKey = (loop.caller and loop.caller ~= "UnknownScript:0" and loop.caller) or loop.name
            if loopKey and loopKey ~= "" and not isSelfOrKernel(loopKey) and not isSelfOrKernel(loop.file or "") then
                -- Only persist verified recurring loops (iterations >= 2) or explicitly configured overrides
                if (loop.iterations and loop.iterations >= 2) or loop.locked or loop.targetHz or loop.sortOrder then
                    placeData.loops[loopKey] = {
                        priority = loop.priority,
                        sortOrder = loop.sortOrder,
                        targetHz = loop.targetHz,
                        locked = loop.locked,
                        paused = loop.paused,
                    }
                end
            end
        end
    end

    local function doWrite()
        pcall(function()
            local json = HttpService:JSONEncode(SchedulerPersistence.data)
            writefile(SchedulerPersistence.file, json)
        end)
    end

    if immediate then
        SchedulerPersistence.pendingSave = false
        doWrite()
    else
        if not SchedulerPersistence.pendingSave then
            SchedulerPersistence.pendingSave = true
            task.delay(0.25, function()
                if SchedulerPersistence.pendingSave then
                    SchedulerPersistence.pendingSave = false
                    doWrite()
                end
            end)
        end
    end
end

-- Unload all tasks across all events (Panic switch / clean teardown)
local function UnloadAllTasks(isTeardown)
    local unloadedCount = 0
    local unloadedNames = {}

    for _, evName in ipairs(EVENT_NAMES) do
        local eventState = Events[evName]
        if eventState then
            for _, taskId in ipairs(eventState.taskOrder) do
                local taskObj = eventState.tasks[taskId]
                if taskObj and taskObj.connected then
                    taskObj.connected = false
                    if taskObj.connection then
                        taskObj.connection.Connected = false
                        taskObj.connection.connected = false
                    end
                    unloadedCount = unloadedCount + 1
                    table.insert(unloadedNames, taskObj.name)
                end
            end
            eventState.tasks = {}
            eventState.taskOrder = {}
            eventState.deferredQueue = {}
        end
    end

    for name in pairs(boundRenderSteps) do
        pcall(function()
            RunService:UnbindFromRenderStep(name)
        end)
    end
    boundRenderSteps = {}

    if ingestedConnections then
        -- During game teardown, do NOT re-enable engine connections as the DataModel is dying
        if not isTeardown then
            for c, entry in pairs(ingestedConnections) do
                pcall(function()
                    if c.Connected ~= false then
                        if c.Enable then
                            c:Enable()
                        elseif c.Enabled ~= nil then
                            c.Enabled = true
                        end
                    end
                end)
                if entry and type(entry) == "table" then
                    entry.isIngested = false
                    entry.taskId = nil
                    entry.schedulerConn = nil
                end
            end
        end
        getgenv()._VirtualSchedulerIngestedConnections = setmetatable({}, { __mode = "k" })
        ingestedConnections = getgenv()._VirtualSchedulerIngestedConnections
    end

    if not isTeardown then
        print(string.format("[VirtualScheduler]: Unloaded %d active tasks.", unloadedCount))
        emitProfile()
    end

    return {
        success = true,
        unloaded = unloadedCount,
        tasks = unloadedNames,
        timestamp = os.time(),
    }
end

-- Task lookup by ID or Name
findTask = function(identifier)
    if not identifier then return nil, nil end
    local idStr = tostring(identifier)
    for _, evName in ipairs(EVENT_NAMES) do
        local eventState = Events[evName]
        if eventState then
            -- 1. Direct ID match
            if eventState.tasks[idStr] then
                return eventState.tasks[idStr], eventState
            end
            -- 2. Scan by name
            for _, tid in ipairs(eventState.taskOrder) do
                local taskObj = eventState.tasks[tid]
                if taskObj and (taskObj.id == idStr or taskObj.name == idStr) then
                    return taskObj, eventState
                end
            end
        end
    end
    return nil, nil
end

-- Pause or Resume an individual task
local function SetSchedulerTaskPaused(identifier, isPaused)
    local taskObj, eventState = findTask(identifier)
    if taskObj then
        taskObj.paused = (isPaused == true)
        if taskObj.paused and eventState then
            for idx, tid in ipairs(eventState.deferredQueue) do
                if tid == taskObj.id then
                    table.remove(eventState.deferredQueue, idx)
                    break
                end
            end
        end
        emitProfile()
        saveSchedulerOverrides()
        return true, taskObj.paused
    end
    return false, "Task not found"
end

-- Kill / End an individual task
KillSchedulerTask = function(identifier)
    local taskObj, eventState = findTask(identifier)
    if taskObj then
        local tid = taskObj.id
        if taskObj.connection and taskObj.connection.Disconnect then
            taskObj.connection:Disconnect()
        else
            taskObj.connected = false
            if eventState then
                eventState.tasks[tid] = nil
                for idx, id in ipairs(eventState.taskOrder) do
                    if id == tid then
                        table.remove(eventState.taskOrder, idx)
                        break
                    end
                end
                for idx, id in ipairs(eventState.deferredQueue) do
                    if id == tid then
                        table.remove(eventState.deferredQueue, idx)
                        break
                    end
                end
            end
        end

        if taskObj.isIngested then
            local grp = taskObj.gameGroup or (taskObj.nativeConn and findDiscoveredGameTask(taskObj.nativeConn))
            if grp then
                if grp.connList then
                    for _, c in ipairs(grp.connList) do
                        if c and c.Connected ~= false then
                            pcall(function()
                                if c.Enable then
                                    c:Enable()
                                elseif c.Enabled ~= nil then
                                    c.Enabled = true
                                end
                            end)
                        end
                        if ingestedConnections then
                            ingestedConnections[c] = nil
                        end
                    end
                end
                grp.isIngested = false
                grp.taskId = nil
                grp.schedulerConn = nil
                if grp.key then
                    persistedIngestedKeys[grp.key] = nil
                    getgenv()._VirtualSchedulerPersistedIngestedKeys = persistedIngestedKeys
                end
            elseif taskObj.nativeConn then
                pcall(function()
                    if taskObj.nativeConn.Enable then
                        taskObj.nativeConn:Enable()
                    elseif taskObj.nativeConn.Enabled ~= nil then
                        taskObj.nativeConn.Enabled = true
                    end
                end)
                if ingestedConnections then
                    ingestedConnections[taskObj.nativeConn] = nil
                end
                local gEntry = findDiscoveredGameTask(taskObj.nativeConn)
                if gEntry then
                    gEntry.isIngested = false
                    gEntry.taskId = nil
                    gEntry.schedulerConn = nil
                    if gEntry.key then
                        persistedIngestedKeys[gEntry.key] = nil
                        getgenv()._VirtualSchedulerPersistedIngestedKeys = persistedIngestedKeys
                    end
                end
            end
        end

        emitProfile()
        return true
    end
    return false, "Task not found"
end

-- Dynamically change a task's priority (order / precedence)
local function SetSchedulerTaskPriority(identifier, newPriority, newSortOrder)
    local taskObj = findTask(identifier)
    if taskObj then
        local np, band = normalizeSchedulerPriority(newPriority)
        taskObj.priority = np
        taskObj.basePriority = np
        taskObj.priorityBand = band
        taskObj.autoThrottled = false
        taskObj.heavyStreak = 0
        taskObj.lightStreak = 0
        if newSortOrder ~= nil then
            taskObj.sortOrder = tonumber(newSortOrder)
        end
        if taskObj.connection then
            taskObj.connection.Priority = np
            taskObj.connection.PriorityBand = band
        end
        local ev = Events[taskObj.event]
        if ev and ev.taskOrder then
            table.sort(ev.taskOrder, function(a, b)
                local tA = ev.tasks[a]
                local tB = ev.tasks[b]
                local priA = getNumericTaskPriority(tA)
                local priB = getNumericTaskPriority(tB)
                if priA ~= priB then return priA > priB end
                local soA = (tA and tA.sortOrder) or 9999
                local soB = (tB and tB.sortOrder) or 9999
                if soA ~= soB then return soA < soB end
                return a < b
            end)
        end
        emitProfile()
        saveSchedulerOverrides()
        return true, np
    end
    return false, "Task not found"
end

-- Dynamically change a task's target frequency (Hz)
local function SetSchedulerTaskHz(identifier, newHz, customRatio)
    local taskObj = findTask(identifier)
    if taskObj then
        local targetHz, interval, isMax, targetRatio = normalizeSchedulerTargetHz(newHz, customRatio)
        taskObj.targetHz = targetHz
        taskObj.effectiveHz = targetHz
        taskObj.interval = interval
        taskObj.isMax = isMax
        taskObj.targetRatio = targetRatio
        taskObj.autoThrottled = false
        taskObj.heavyStreak = 0
        taskObj.lightStreak = 0
        if taskObj.connection then
            taskObj.connection.TargetHz = targetHz
            taskObj.connection.EffectiveHz = targetHz
        end
        emitProfile()
        saveSchedulerOverrides()
        return true, targetHz
    end
    return false, "Task not found"
end

-- Lock / Force an individual task's priority (bypasses auto-throttling)
local function SetSchedulerTaskLocked(identifier, isLocked)
    local taskObj = findTask(identifier)
    if taskObj then
        taskObj.locked = (isLocked == true)
        if taskObj.locked then
            taskObj.autoThrottled = false
            local maxHz = math.max(60, measuredFps or 60)
            if taskObj.isMax or taskObj.basePriority == "High" or (taskObj.targetRatio and taskObj.targetRatio >= 0.95) then
                taskObj.targetHz = maxHz
                taskObj.effectiveHz = maxHz
                taskObj.interval = 1
            else
                local targetHz = taskObj.targetHz or maxHz
                taskObj.effectiveHz = targetHz
                taskObj.interval = math.max(1, math.round(maxHz / math.max(0.1, targetHz)))
            end
        end
        emitProfile()
        saveSchedulerOverrides()
        return true, taskObj.locked
    end
    return false, "Task not found"
end

-- Global Priority Override Mode (Deprecated - Per-Task Sliders Used)
local function SetGlobalPriorityOverride(mode)
    emitProfile()
    return true, "Off"
end

local function GetGlobalPriorityOverride()
    return "Off"
end

-- Background 2-second profiling loop
local profilingActive = true
task.spawn(function()
    while profilingActive do
        task.wait(2.0)
        if profilingActive then
            pcall(ScanGameTasks)
            pcall(emitProfile)
        end
    end
end)

-- Clean up hook for reload idempotence and teardown
local function cleanUpScheduler(isTeardown)
    profilingActive = false
    emitProfileScheduled = false

    UnloadAllTasks(isTeardown)
    for _, eventState in pairs(Events) do
        if eventState.connection then
            pcall(function() eventState.connection:Disconnect() end)
            eventState.connection = nil
        end
    end
    for _, conn in ipairs(teardownConnections) do
        pcall(function() conn:Disconnect() end)
    end
    teardownConnections = {}

    -- Release discovered game tasks to prevent memory retention across DataModels
    DiscoveredGameTaskGroups = {}
    DiscoveredGameTaskOrder = {}

    -- Disarm all registered loops and clear thread registry
    for thread, loop in pairs(loopRegistry) do
        loop.alive = false
        loop.paused = false
    end
    loopRegistry = setmetatable({}, { __mode = "k" })
    loopOrder = {}
    ignoredThreads = setmetatable({}, { __mode = "k" })

    -- Clear ingested connection table and global pointer
    if ingestedConnections then
        getgenv()._VirtualSchedulerIngestedConnections = setmetatable({}, { __mode = "k" })
        ingestedConnections = getgenv()._VirtualSchedulerIngestedConnections
    end
    getgenv()._VirtualSchedulerPersistedIngestedKeys = nil

    -- Clear global environment proxies pointing to this DataModel
    if rawequal(getgenv().game, getgenv()._OmniGameProxy) then
        getgenv().game = origGame
    end
    if getgenv()._KernelOrigTypeof then
        getgenv().typeof = getgenv()._KernelOrigTypeof
        getgenv()._KernelOrigTypeof = nil
    end
    if getgenv()._KernelOrigGetrawmetatable then
        getgenv().getrawmetatable = getgenv()._KernelOrigGetrawmetatable
        getgenv()._KernelOrigGetrawmetatable = nil
    end
    if getgenv()._KernelOrigCloneref then
        getgenv().cloneref = getgenv()._KernelOrigCloneref
        getgenv()._KernelOrigCloneref = nil
    end
    if getgenv().RunService == ProxiedRunService then
        getgenv().RunService = rawRunService
    end
    getgenv()._VirtualSchedulerCleanUp = nil
    getgenv()._VirtualSchedulerLoaded = nil
end

-- Export proxied RunService to getgenv() for direct executor script access
local ProxiedRunService = setmetatable({
    Heartbeat = ProxiedSignals.Heartbeat,
    Stepped = ProxiedSignals.Stepped,
    RenderStepped = ProxiedSignals.RenderStepped,
    PostSimulation = ProxiedSignals.Heartbeat,
    PreSimulation = ProxiedSignals.Stepped,
    PreRender = ProxiedSignals.RenderStepped,
    BindToRenderStep = function(self, ...)
        return ProxiedBindToRenderStep(rawRunService, ...)
    end,
    UnbindFromRenderStep = function(self, ...)
        return ProxiedUnbindFromRenderStep(rawRunService, ...)
    end,
}, {
    __index = function(_, key)
        if key == "ClassName" then return "RunService" end
        local val = rawRunService[key]
        if type(val) == "function" then
            return function(self, ...)
                return val(rawRunService, ...)
            end
        end
        return val
    end,
    __namecall = function(_, ...)
        local method = (getnamecallmethod and getnamecallmethod()) or ""
        if method == "BindToRenderStep" then
            return ProxiedBindToRenderStep(rawRunService, ...)
        elseif method == "UnbindFromRenderStep" then
            return ProxiedUnbindFromRenderStep(rawRunService, ...)
        elseif method ~= "" and type(rawRunService[method]) == "function" then
            return rawRunService[method](rawRunService, ...)
        end
        return rawRunService[method](rawRunService, ...)
    end,
    __tostring = function() return tostring(rawRunService) end,
    __eq = function(a, b) return rawequal(a, b) or a == rawRunService or b == rawRunService end,
})

-- Global environment exports
getgenv().RunService = ProxiedRunService
getgenv()._VirtualSchedulerProxiedRunService = ProxiedRunService
getgenv()._OmniGameProxy = createGameProxy(ProxiedRunService)
getgenv().game = getgenv()._OmniGameProxy
getgenv().ThrottledConnect = ThrottledConnect
getgenv().SuperStep = RegisterSuperStep
getgenv().RegisterSuperStep = RegisterSuperStep
getgenv().UnloadAllTasks = UnloadAllTasks

-- Active SuperStep Guard: Ensure SuperStep is never overwritten by rogue third-party or legacy scripts
task.spawn(function()
    while profilingActive do
        if getgenv().SuperStep ~= RegisterSuperStep then
            getgenv().SuperStep = RegisterSuperStep
        end
        task.wait(1)
    end
end)
getgenv().GetSchedulerProfile = buildProfile
getgenv().EmitSchedulerProfile = emitProfile
getgenv().GetAdaptiveBudget = function() return currentBudgetMs, measuredFps end
getgenv().SetSchedulerTaskPaused = SetSchedulerTaskPaused
getgenv().PauseSchedulerTask = function(taskId) return SetSchedulerTaskPaused(taskId, true) end
getgenv().ResumeSchedulerTask = function(taskId) return SetSchedulerTaskPaused(taskId, false) end
getgenv().findTask = findTask
getgenv().FindSchedulerTask = findTask
getgenv().KillSchedulerTask = KillSchedulerTask
getgenv().SetSchedulerTaskPriority = SetSchedulerTaskPriority
getgenv().SetSchedulerTaskHz = SetSchedulerTaskHz
getgenv().SetSchedulerTaskFrequency = SetSchedulerTaskHz
getgenv().SetSchedulerTaskLocked = SetSchedulerTaskLocked
getgenv().SetSchedulerTaskForced = SetSchedulerTaskLocked
getgenv().SetGlobalPriorityOverride = SetGlobalPriorityOverride
getgenv().SetGlobalForceMode = SetGlobalPriorityOverride
getgenv().GetGlobalPriorityOverride = GetGlobalPriorityOverride
getgenv().GetSchedulerLiveState = buildProfile
getgenv().GetPerfStats = getPerfStats
getgenv().GetStartupScripts = scanStartupScripts
getgenv().ToggleStartupScript = toggleStartupScript
getgenv().GetLoopProfile = buildLoopProfile
getgenv().SetLoopPaused = SetLoopPaused
getgenv().PauseLoop = function(id) return SetLoopPaused(id, true) end
getgenv().ResumeLoop = function(id) return SetLoopPaused(id, false) end
getgenv().SetLoopFrequency = SetLoopFrequency
getgenv().SetLoopPriority = SetLoopPriority
getgenv().SetLoopLocked = SetLoopLocked
getgenv().KillLoop = KillLoop
getgenv().PauseAllLoops = PauseAllLoops
getgenv().ResumeAllLoops = function() return PauseAllLoops(false) end
getgenv().KillAllLoops = KillAllLoops
getgenv().ClearLoopRegistry = ClearLoopRegistry
getgenv().GetDiscoveredGameTasks = function() return DiscoveredGameTaskOrder end
getgenv().ScanGameTasks = ScanGameTasks
getgenv().IngestGameTask = IngestGameTask
getgenv().EjectGameTask = EjectGameTask
getgenv().DiscardIngestedGameTask = DiscardIngestedGameTask
getgenv().CheckIngestedTasksLiveness = CheckAllIngestedTasksLiveness
getgenv().IngestEngineTasks = IngestEngineConnections
getgenv().SaveSchedulerOverrides = function(immediate) return SchedulerPersistence.save(immediate) end
getgenv().LoadSchedulerOverrides = function() return SchedulerPersistence.load() end
getgenv()._VirtualSchedulerCleanUp = cleanUpScheduler
getgenv()._VirtualSchedulerLoaded = true


-- ==============================================================================
-- OMNI UPDATE & SECURITY GATE (Transparency & Changelog Consent)
-- ==============================================================================
-- OMNI RUNTIME TASK MANAGER HUD (100% OFFLINE - ZERO WEB REQUESTS)
-- All network security auditing and update gating is enforced by Bootloader.lua
-- ==============================================================================
-- ==============================================================================

-- ==============================================================================
-- SHARED TASK MANAGER HUD STATE & CACHES (File Scope)
-- ==============================================================================
local cachedTaskRows = {}
local cachedStartupRows = {}
local cachedLoopRows = {}
local cachedGameRows = {}
local activeExpandedRowKey = nil

-- ==============================================================================
-- UNCORRUPTIBLE RUNTIME ICON DEFINITIONS (File Scope)
-- ==============================================================================
local ICONS = {
    LOCK_OPEN   = utf8.char(0x1F513), -- 🔓
    LOCK_CLOSED = utf8.char(0x1F512), -- 🔒
    PAUSE       = utf8.char(0x23F8),  -- ⏸
    PLAY        = utf8.char(0x25B6),  -- ▶
    KILL        = utf8.char(0x2715),  -- ✕
    GRIP        = utf8.char(0x2195),  -- ↕
    RESIZE      = utf8.char(0x2194),  -- ↔
    BOLT        = utf8.char(0x26A1),  -- ⚡
    GAME        = utf8.char(0x1F3AE), -- 🎮
    GLOBE       = utf8.char(0x1F310), -- 🌐
    EDIT        = utf8.char(0x270F) .. utf8.char(0xFE0F), -- ✏️
    DELETE      = utf8.char(0x1F5D1) .. utf8.char(0xFE0F), -- 🗑️
    WARN        = utf8.char(0x26A0) .. utf8.char(0xFE0F), -- ⚠️
    HOURGLASS   = utf8.char(0x23F3),  -- ⏳
    DOT_GREEN   = utf8.char(0x1F7E2), -- 🟢
    DOT_WHITE   = utf8.char(0x26AA),  -- ⚪
    INGEST      = utf8.char(0x1F4E5), -- 📥
    EJECT       = utf8.char(0x1F4E4), -- 📤
    CHECK       = utf8.char(0x2713),  -- ✓
    CROSS       = utf8.char(0x274C),  -- ❌
    ARROW_UP    = utf8.char(0x25B2),  -- ▲
    ARROW_DOWN  = utf8.char(0x25BC),  -- ▼
}

-- ==============================================================================
-- DYNAMIC MULTI-COLUMN CONFIGURATION & INTERACTIVE RESIZING STATE (File Scope)
-- ==============================================================================
local ColumnConfig = {
    Tasks = {
        cols = {
            { id = "Priority", name = "PRIORITY",                 align = Enum.TextXAlignment.Center, width = 0.10, minWidth = 0.06, maxWidth = 0.18, defaultWidth = 0.10 },
            { id = "Name",     name = "TASK IDENTIFIER & SOURCE", align = Enum.TextXAlignment.Center, width = 0.34, minWidth = 0.18, maxWidth = 0.65, defaultWidth = 0.34 },
            { id = "Event",    name = "EVENT",                    align = Enum.TextXAlignment.Center, width = 0.15, minWidth = 0.10, maxWidth = 0.25, defaultWidth = 0.15 },
            { id = "Hz",       name = "TARGET HZ",                align = Enum.TextXAlignment.Center, width = 0.11, minWidth = 0.085, maxWidth = 0.20, defaultWidth = 0.11 },
            { id = "Lock",     name = "LOCK",                     align = Enum.TextXAlignment.Center, width = 0.06, minWidth = 0.045, maxWidth = 0.12, defaultWidth = 0.06 },
            { id = "Cpu",      name = "CPU TIME",                 align = Enum.TextXAlignment.Center, width = 0.11, minWidth = 0.075, maxWidth = 0.20, defaultWidth = 0.11 },
            { id = "Actions",  name = "ACTIONS",                  align = Enum.TextXAlignment.Center, width = 0.13, minWidth = 0.085, maxWidth = 0.22, defaultWidth = 0.13 },
        }
    },
    Loops = {
        cols = {
            { id = "Priority", name = "PRIORITY",                 align = Enum.TextXAlignment.Center, width = 0.10, minWidth = 0.06, maxWidth = 0.18, defaultWidth = 0.10 },
            { id = "Name",     name = "LOOP CALLER & LOCATION",   align = Enum.TextXAlignment.Center, width = 0.34, minWidth = 0.18, maxWidth = 0.65, defaultWidth = 0.34 },
            { id = "Iters",    name = "ITERS",                    align = Enum.TextXAlignment.Center, width = 0.15, minWidth = 0.10, maxWidth = 0.25, defaultWidth = 0.15 },
            { id = "Hz",       name = "TARGET HZ",                align = Enum.TextXAlignment.Center, width = 0.11, minWidth = 0.085, maxWidth = 0.20, defaultWidth = 0.11 },
            { id = "Lock",     name = "LOCK",                     align = Enum.TextXAlignment.Center, width = 0.06, minWidth = 0.045, maxWidth = 0.12, defaultWidth = 0.06 },
            { id = "Cpu",      name = "CPU TIME",                 align = Enum.TextXAlignment.Center, width = 0.11, minWidth = 0.075, maxWidth = 0.20, defaultWidth = 0.11 },
            { id = "Actions",  name = "ACTIONS",                  align = Enum.TextXAlignment.Center, width = 0.13, minWidth = 0.085, maxWidth = 0.22, defaultWidth = 0.13 },
        }
    },
    Startup = {
        cols = {
            { id = "Priority", name = "PRIORITY",                          align = Enum.TextXAlignment.Center, width = 0.12, minWidth = 0.08, maxWidth = 0.18, defaultWidth = 0.12 },
            { id = "Name",     name = "SCRIPT IDENTIFIER & RELATIVE PATH", align = Enum.TextXAlignment.Center, width = 0.41, minWidth = 0.20, maxWidth = 0.70, defaultWidth = 0.41 },
            { id = "Stage",    name = "BOOT STAGE",                        align = Enum.TextXAlignment.Center, width = 0.17, minWidth = 0.11, maxWidth = 0.28, defaultWidth = 0.17 },
            { id = "Time",     name = "EXEC TIME",                         align = Enum.TextXAlignment.Center, width = 0.13, minWidth = 0.085, maxWidth = 0.22, defaultWidth = 0.13 },
            { id = "Toggle",   name = "STATE / TOGGLE",                    align = Enum.TextXAlignment.Center, width = 0.17, minWidth = 0.12, maxWidth = 0.28, defaultWidth = 0.17 },
        }
    },
    Game = {
        cols = {
            { id = "Stat",    name = "STAT",               align = Enum.TextXAlignment.Center, width = 0.06, minWidth = 0.045, maxWidth = 0.12, defaultWidth = 0.06 },
            { id = "Name",    name = "GAME SCRIPT & LINE", align = Enum.TextXAlignment.Center, width = 0.44, minWidth = 0.22, maxWidth = 0.70, defaultWidth = 0.44 },
            { id = "Event",   name = "EVENT",              align = Enum.TextXAlignment.Center, width = 0.18, minWidth = 0.11, maxWidth = 0.30, defaultWidth = 0.18 },
            { id = "Status",  name = "ENGINE STATUS",      align = Enum.TextXAlignment.Center, width = 0.17, minWidth = 0.11, maxWidth = 0.28, defaultWidth = 0.17 },
            { id = "Action",  name = "ACTION",             align = Enum.TextXAlignment.Center, width = 0.15, minWidth = 0.09, maxWidth = 0.25, defaultWidth = 0.15 },
        }
    },
}

-- Backward compatibility reference
local ColumnWidths = {
    Tasks = { name = 0.34, minName = 0.18, maxName = 0.65, defaultName = 0.34 },
    Loops = { name = 0.34, minName = 0.18, maxName = 0.65, defaultName = 0.34 },
    Startup = { name = 0.41, minName = 0.20, maxName = 0.70, defaultName = 0.41 },
    Game = { name = 0.44, minName = 0.22, maxName = 0.70, defaultName = 0.44 },
}

local TableHeaders = {}
local activeDividerDrag = nil
local allStartupScriptsRef = nil

local H_PAD = 6 -- Small, crisp inner padding ensuring header and row content never collides with divider lines

-- FORWARD DECLARATIONS (ensures mutual visibility and eliminates nil calls)
local updateTableColumnLayout
local applyRowColumnLayout
local handleDividerDrag
local autoFitColumn
local showTableNotice
local openPriorityEditModal

-- ==============================================================================
-- INTERACTIVE COLUMN SORTING ENGINE & STATE
-- ==============================================================================
local TableSortState = {
    Tasks = { colId = "Priority", ascending = false },
    Loops = { colId = "Priority", ascending = false },
    Startup = { colId = "Priority", ascending = false },
    Game = { colId = "Event", ascending = true },
}

local RS_EVENT_ORDER = {
    ["superstep"] = 0,
    ["renderstepped"] = 1,
    ["prerender"] = 1,
    ["stepped"] = 2,
    ["presimulation"] = 2,
    ["heartbeat"] = 3,
    ["postsimulation"] = 3,
}

local function getEventRank(ev)
    if not ev then return 99 end
    local clean = tostring(ev):lower():gsub("%s+", "")
    return RS_EVENT_ORDER[clean] or 50
end

local STARTUP_STAGE_RANKS = {
    ["kernel"] = 1,
    ["preinit"] = 2,
    ["nodelay"] = 2,
    ["gameloaded"] = 3,
    ["characterready"] = 4,
    ["characterloaded"] = 4,
    ["deferred"] = 5,
}

local function sortTaskList(tasks, colId, ascending)
    table.sort(tasks, function(a, b)
        if colId == "Priority" then
            local priA = getNumericTaskPriority(a)
            local priB = getNumericTaskPriority(b)
            if priA ~= priB then
                if ascending then return priA < priB else return priA > priB end
            end
        elseif colId == "Name" then
            local nA = tostring(a.name or a.id or ""):lower()
            local nB = tostring(b.name or b.id or ""):lower()
            if nA ~= nB then
                if ascending then return nA < nB else return nA > nB end
            end
        elseif colId == "Event" then
            local rA = getEventRank(a.event)
            local rB = getEventRank(b.event)
            if rA ~= rB then
                if ascending then return rA < rB else return rA > rB end
            end
        elseif colId == "Hz" then
            local hzA = tonumber(a.targetHz or a.effectiveHz) or 60
            local hzB = tonumber(b.targetHz or b.effectiveHz) or 60
            if hzA == 0 then hzA = 9999 end
            if hzB == 0 then hzB = 9999 end
            if hzA ~= hzB then
                if ascending then return hzA < hzB else return hzA > hzB end
            end
        elseif colId == "Lock" then
            local lA = (a.locked == true)
            local lB = (b.locked == true)
            if lA ~= lB then
                if ascending then return not lA and lB else return lA and not lB end
            end
        elseif colId == "Cpu" then
            local cA = tonumber(a.avgTimeMs) or 0
            local cB = tonumber(b.avgTimeMs) or 0
            if cA ~= cB then
                if ascending then return cA < cB else return cA > cB end
            end
        elseif colId == "Actions" then
            local pA = (a.paused == true)
            local pB = (b.paused == true)
            if pA ~= pB then
                if ascending then return not pA and pB else return pA and not pB end
            end
        end

        local pA = getNumericTaskPriority(a)
        local pB = getNumericTaskPriority(b)
        if pA ~= pB then return pA > pB end
        return tostring(a.id or "") < tostring(b.id or "")
    end)
end

local function sortLoopList(loops, colId, ascending)
    table.sort(loops, function(a, b)
        if colId == "Priority" then
            local priA = tonumber(a.priority) or 50
            local priB = tonumber(b.priority) or 50
            if priA ~= priB then
                if ascending then return priA < priB else return priA > priB end
            end
        elseif colId == "Name" then
            local nA = tostring(a.caller or a.name or a.id or ""):lower()
            local nB = tostring(b.caller or b.name or b.id or ""):lower()
            if nA ~= nB then
                if ascending then return nA < nB else return nA > nB end
            end
        elseif colId == "Iters" then
            local iA = tonumber(a.iterations) or 0
            local iB = tonumber(b.iterations) or 0
            if iA ~= iB then
                if ascending then return iA < iB else return iA > iB end
            end
        elseif colId == "Hz" then
            local hzA = tonumber(a.targetHz) or 60
            local hzB = tonumber(b.targetHz) or 60
            if hzA == 0 then hzA = 9999 end
            if hzB == 0 then hzB = 9999 end
            if hzA ~= hzB then
                if ascending then return hzA < hzB else return hzA > hzB end
            end
        elseif colId == "Lock" then
            local lA = (a.locked == true)
            local lB = (b.locked == true)
            if lA ~= lB then
                if ascending then return not lA and lB else return lA and not lB end
            end
        elseif colId == "Cpu" then
            local cA = tonumber(a.avgTimeMs) or 0
            local cB = tonumber(b.avgTimeMs) or 0
            if cA ~= cB then
                if ascending then return cA < cB else return cA > cB end
            end
        elseif colId == "Actions" then
            local pA = (a.paused == true)
            local pB = (b.paused == true)
            if pA ~= pB then
                if ascending then return not pA and pB else return pA and not pB end
            end
        end

        local pA = tonumber(a.priority) or 50
        local pB = tonumber(b.priority) or 50
        if pA ~= pB then return pA > pB end
        return tostring(a.id or "") < tostring(b.id or "")
    end)
end

local function sortStartupList(scripts, colId, ascending)
    table.sort(scripts, function(a, b)
        if colId == "Priority" then
            local sA = STARTUP_STAGE_RANKS[tostring(a.stage or ""):lower()] or 10
            local sB = STARTUP_STAGE_RANKS[tostring(b.stage or ""):lower()] or 10
            if sA ~= sB then
                if ascending then return sA > sB else return sA < sB end
            end
            local priA = tonumber(a.priority) or 0
            local priB = tonumber(b.priority) or 0
            if priA ~= priB then
                if ascending then return priA < priB else return priA > priB end
            end
        elseif colId == "Name" then
            local nA = tostring(a.name or a.file or ""):lower()
            local nB = tostring(b.name or b.file or ""):lower()
            if nA ~= nB then
                if ascending then return nA < nB else return nA > nB end
            end
        elseif colId == "Stage" then
            local sA = STARTUP_STAGE_RANKS[tostring(a.stage or ""):lower()] or 10
            local sB = STARTUP_STAGE_RANKS[tostring(b.stage or ""):lower()] or 10
            if sA ~= sB then
                if ascending then return sA < sB else return sA > sB end
            end
        elseif colId == "Time" then
            local tA = tonumber(a.execTime or a.compileTime) or 0
            local tB = tonumber(b.execTime or b.compileTime) or 0
            if tA ~= tB then
                if ascending then return tA < tB else return tA > tB end
            end
        elseif colId == "Toggle" then
            local eA = (a.enabled ~= false)
            local eB = (b.enabled ~= false)
            if eA ~= eB then
                if ascending then return not eA and eB else return eA and not eB end
            end
        end

        local pA = tonumber(a.priority) or 0
        local pB = tonumber(b.priority) or 0
        if pA ~= pB then return pA > pB end
        return tostring(a.file or "") < tostring(b.file or "")
    end)
end

local function sortGameTaskList(gameTasks, colId, ascending)
    table.sort(gameTasks, function(a, b)
        if colId == "Event" then
            local rA = getEventRank(a.event)
            local rB = getEventRank(b.event)
            if rA ~= rB then
                if ascending then return rA < rB else return rA > rB end
            end
        elseif colId == "Name" then
            local nA = tostring(a.name or a.id or ""):lower()
            local nB = tostring(b.name or b.id or ""):lower()
            if nA ~= nB then
                if ascending then return nA < nB else return nA > nB end
            end
        elseif colId == "Status" then
            local sA = tostring(a.status or ""):lower()
            local sB = tostring(b.status or ""):lower()
            if sA ~= sB then
                if ascending then return sA < sB else return sA > sB end
            end
        end
        return tostring(a.id or "") < tostring(b.id or "")
    end)
end

local function updateHeaderSortIndicators(tabKey)
    local state = TableSortState[tabKey]
    local cfg = ColumnConfig[tabKey]
    local header = TableHeaders[tabKey]
    if not state or not cfg or not header then return end

    for _, col in ipairs(cfg.cols) do
        local btn = header:FindFirstChild("Col_" .. col.id)
        if btn then
            if col.id == state.colId then
                local arrow = state.ascending and ICONS.ARROW_UP or ICONS.ARROW_DOWN
                btn.Text = col.name .. " " .. arrow
                btn.TextColor3 = Color3.fromRGB(240, 245, 255)
            else
                btn.Text = col.name
                btn.TextColor3 = Color3.fromRGB(140, 155, 180)
            end
        end
    end
end

local function toggleTableSort(tabKey, colId)
    local state = TableSortState[tabKey]
    if not state then return end

    if state.colId == colId then
        state.ascending = not state.ascending
    else
        state.colId = colId
        if colId == "Name" then
            state.ascending = true
        elseif colId == "Event" then
            state.ascending = true
        elseif colId == "Hz" then
            state.ascending = false
        elseif colId == "Priority" then
            state.ascending = false
        elseif colId == "Cpu" then
            state.ascending = false
        elseif colId == "Iters" then
            state.ascending = false
        elseif colId == "Lock" then
            state.ascending = false
        elseif colId == "Actions" then
            state.ascending = false
        elseif colId == "Stage" then
            state.ascending = true
        elseif colId == "Time" then
            state.ascending = false
        elseif colId == "Toggle" then
            state.ascending = false
        else
            state.ascending = true
        end
    end

    updateHeaderSortIndicators(tabKey)

    local isPriSort = (state.colId == "Priority")
    if tabKey == "Tasks" then
        for _, r in pairs(cachedTaskRows) do
            local grip = r:FindFirstChild("GripLbl")
            if grip then
                grip.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
            end
        end
    elseif tabKey == "Loops" then
        for _, r in pairs(cachedLoopRows) do
            local grip = r:FindFirstChild("GripLbl")
            if grip then
                grip.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
            end
        end
    elseif tabKey == "Startup" then
        for _, r in pairs(cachedStartupRows) do
            local grip = r:FindFirstChild("GripLbl")
            if grip then
                grip.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
            end
        end
    end

    if tabKey == "Startup" and refreshStartupTab then
        refreshStartupTab(true)
    end
end

getgenv()._OmniTaskManager_SortTable = toggleTableSort
getgenv()._OmniTaskManager_GetSortState = function() return TableSortState end

local function computeColumnPositions(tabKey)
    local cfg = ColumnConfig[tabKey]
    if not cfg then return {}, {} end
    local positions = {}
    local widths = {}
    local curX = 0.0
    for i, col in ipairs(cfg.cols) do
        positions[i] = curX
        widths[i] = col.width
        curX = curX + col.width
    end
    return positions, widths
end

local function allocateRemainingWidths(cols, startIdx, remSpace)
    local n = #cols
    local totalMin = 0
    local excess = {}
    local totalExcess = 0

    for j = startIdx, n do
        local minW = cols[j].minWidth or 0.05
        totalMin = totalMin + minW
        local exc = math.max(0, cols[j].width - minW)
        excess[j] = exc
        totalExcess = totalExcess + exc
    end

    local availableExcess = math.max(0, remSpace - totalMin)
    if totalExcess > 0.0001 then
        for j = startIdx, n do
            local minW = cols[j].minWidth or 0.05
            cols[j].width = minW + availableExcess * (excess[j] / totalExcess)
        end
    else
        local count = n - startIdx + 1
        local each = availableExcess / count
        for j = startIdx, n do
            local minW = cols[j].minWidth or 0.05
            cols[j].width = minW + each
        end
    end
end

handleDividerDrag = function(tabKey, dividerIdx, mouseFractionX)
    local cfg = ColumnConfig[tabKey]
    if not cfg then return end
    local k = dividerIdx
    local cols = cfg.cols

    local posX = 0.0
    for i = 1, k - 1 do
        posX = posX + cols[i].width
    end

    local minRemaining = 0
    for j = k + 1, #cols do
        minRemaining = minRemaining + (cols[j].minWidth or 0.05)
    end

    local minX = posX + (cols[k].minWidth or 0.05)
    local maxX = 1.0 - minRemaining
    if cols[k].maxWidth then
        maxX = math.min(maxX, posX + cols[k].maxWidth)
    end

    local clampedX = math.clamp(mouseFractionX, minX, math.max(minX, maxX))
    local newColKWidth = clampedX - posX
    cols[k].width = newColKWidth

    local remSpace = math.max(minRemaining, 1.0 - clampedX)
    allocateRemainingWidths(cols, k + 1, remSpace)

    if ColumnWidths[tabKey] and cols[2] then
        ColumnWidths[tabKey].name = cols[2].width
    end

    if updateTableColumnLayout then
        updateTableColumnLayout(tabKey)
    end
end

applyRowColumnLayout = function(row, tabKey)
    if not row or not row.Parent then return end
    local positions, widths = computeColumnPositions(tabKey)
    if #positions == 0 then return end

    if tabKey == "Startup" then
        local pPri, wPri = positions[1], widths[1]
        local pName, wName = positions[2], widths[2]
        local pStage, wStage = positions[3], widths[3]
        local pTime, wTime = positions[4], widths[4]
        local pToggle, wToggle = positions[5], widths[5]

        local isPriSort = TableSortState.Startup and TableSortState.Startup.colId == "Priority"
        local gripLbl = row:FindFirstChild("GripLbl")
        if gripLbl then
            gripLbl.Position = UDim2.new(pPri + wPri / 2, -33, 0, 8)
            gripLbl.Size = UDim2.new(0, 12, 0, 16)
            gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
        end
        local dot = row:FindFirstChild("Dot")
        if dot then
            dot.Position = UDim2.new(pPri + wPri / 2, -15, 0, 12)
            dot.Size = UDim2.new(0, 8, 0, 8)
        end
        local priLbl = row:FindFirstChild("PriLbl")
        if priLbl then
            priLbl.Position = UDim2.new(pPri + wPri / 2, -1, 0, 7)
            priLbl.Size = UDim2.new(0, 34, 0, 18)
            priLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local nameLbl = row:FindFirstChild("NameLbl")
        if nameLbl then
            nameLbl.Position = UDim2.new(pName, H_PAD, 0, 2)
            nameLbl.Size = UDim2.new(wName, -H_PAD * 2, 0, 15)
        end
        local pathLbl = row:FindFirstChild("PathLbl")
        if pathLbl then
            pathLbl.Position = UDim2.new(pName, H_PAD, 0, 17)
            pathLbl.Size = UDim2.new(wName, -H_PAD * 2, 0, 12)
        end
        local stageBadge = row:FindFirstChild("StageBadge")
        if stageBadge then
            stageBadge.Position = UDim2.new(pStage + wStage / 2, -40, 0, 7)
            stageBadge.Size = UDim2.new(0, 80, 0, 18)
        end
        local timeLbl = row:FindFirstChild("TimeLbl")
        if timeLbl then
            timeLbl.Position = UDim2.new(pTime, H_PAD, 0, 0)
            timeLbl.Size = UDim2.new(wTime, -H_PAD * 2, 0, 32)
            timeLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local toggleBtn = row:FindFirstChild("ToggleBtn")
        if toggleBtn then
            toggleBtn.Size = UDim2.new(0, 64, 0, 20)
            toggleBtn.Position = UDim2.new(pToggle + wToggle / 2, -36, 0, 6)
        end
        local accordion = row:FindFirstChild("AccordionPanel")
        if accordion then
            local btnContainer = accordion:FindFirstChild("BtnContainer")
            if btnContainer then
                btnContainer.Position = UDim2.new(pName, H_PAD, 0, 5)
                btnContainer.Size = UDim2.new(1 - pName, -H_PAD * 2, 1, -8)
            end
        end

    elseif tabKey == "Tasks" then
        local pPri, wPri = positions[1], widths[1]
        local pName, wName = positions[2], widths[2]
        local pEvt, wEvt = positions[3], widths[3]
        local pHz, wHz = positions[4], widths[4]
        local pLock, wLock = positions[5], widths[5]
        local pCpu, wCpu = positions[6], widths[6]
        local pAct, wAct = positions[7], widths[7]

        local isPriSort = TableSortState.Tasks and TableSortState.Tasks.colId == "Priority"
        local gripLbl = row:FindFirstChild("GripLbl")
        if gripLbl then
            gripLbl.Position = UDim2.new(pPri + wPri / 2, -29, 0.5, -8)
            gripLbl.Size = UDim2.new(0, 12, 0, 16)
            gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
        end
        local dot = row:FindFirstChild("Dot")
        if dot then
            dot.Position = UDim2.new(pPri + wPri / 2, -12, 0.5, -4)
            dot.Size = UDim2.new(0, 8, 0, 8)
        end
        local priLbl = row:FindFirstChild("PriLbl")
        if priLbl then
            priLbl.Position = UDim2.new(pPri + wPri / 2, 1, 0.5, -9)
            priLbl.Size = UDim2.new(0, 28, 0, 18)
            priLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local nameLbl = row:FindFirstChild("NameLbl")
        if nameLbl then
            nameLbl.Position = UDim2.new(pName, H_PAD, 0, 0)
            nameLbl.Size = UDim2.new(wName, -H_PAD * 2, 1, 0)
        end
        local eventLbl = row:FindFirstChild("EventLbl")
        if eventLbl then
            eventLbl.Position = UDim2.new(pEvt, H_PAD, 0, 0)
            eventLbl.Size = UDim2.new(wEvt, -H_PAD * 2, 1, 0)
            eventLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local priBtn = row:FindFirstChild("PriBtn")
        if priBtn then
            priBtn.Position = UDim2.new(pHz + wHz / 2, -32, 0.5, -10)
        end
        local lockBtn = row:FindFirstChild("LockBtn")
        if lockBtn then
            lockBtn.Position = UDim2.new(pLock + wLock / 2, -12, 0.5, -10)
        end
        local cpuLbl = row:FindFirstChild("CpuLbl")
        if cpuLbl then
            cpuLbl.Position = UDim2.new(pCpu, H_PAD, 0, 0)
            cpuLbl.Size = UDim2.new(wCpu, -H_PAD * 2, 1, 0)
            cpuLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local actions = row:FindFirstChild("Actions")
        if actions then
            actions.Position = UDim2.new(pAct, H_PAD, 0, 0)
            actions.Size = UDim2.new(wAct, -H_PAD * 2, 1, 0)
        end

    elseif tabKey == "Loops" then
        local pPri, wPri = positions[1], widths[1]
        local pName, wName = positions[2], widths[2]
        local pItr, wItr = positions[3], widths[3]
        local pHz, wHz = positions[4], widths[4]
        local pLock, wLock = positions[5], widths[5]
        local pCpu, wCpu = positions[6], widths[6]
        local pAct, wAct = positions[7], widths[7]

        local isPriSort = TableSortState.Loops and TableSortState.Loops.colId == "Priority"
        local gripLbl = row:FindFirstChild("GripLbl")
        if gripLbl then
            gripLbl.Position = UDim2.new(pPri + wPri / 2, -29, 0.5, -8)
            gripLbl.Size = UDim2.new(0, 12, 0, 16)
            gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
        end
        local dot = row:FindFirstChild("Dot")
        if dot then
            dot.Position = UDim2.new(pPri + wPri / 2, -12, 0.5, -4)
            dot.Size = UDim2.new(0, 8, 0, 8)
        end
        local priLbl = row:FindFirstChild("PriLbl")
        if priLbl then
            priLbl.Position = UDim2.new(pPri + wPri / 2, 1, 0.5, -9)
            priLbl.Size = UDim2.new(0, 28, 0, 18)
            priLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local nameLbl = row:FindFirstChild("NameLbl")
        if nameLbl then
            nameLbl.Position = UDim2.new(pName, H_PAD, 0, 0)
            nameLbl.Size = UDim2.new(wName, -H_PAD * 2, 1, 0)
        end
        local itersLbl = row:FindFirstChild("ItersLbl")
        if itersLbl then
            itersLbl.Position = UDim2.new(pItr, H_PAD, 0, 0)
            itersLbl.Size = UDim2.new(wItr, -H_PAD * 2, 1, 0)
            itersLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local hzBtn = row:FindFirstChild("HzBtn")
        if hzBtn then
            hzBtn.Position = UDim2.new(pHz + wHz / 2, -32, 0.5, -10)
        end
        local lockBtn = row:FindFirstChild("LockBtn")
        if lockBtn then
            lockBtn.Position = UDim2.new(pLock + wLock / 2, -12, 0.5, -10)
        end
        local cpuLbl = row:FindFirstChild("CpuLbl")
        if cpuLbl then
            cpuLbl.Position = UDim2.new(pCpu, H_PAD, 0, 0)
            cpuLbl.Size = UDim2.new(wCpu, -H_PAD * 2, 1, 0)
            cpuLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local actions = row:FindFirstChild("Actions")
        if actions then
            actions.Position = UDim2.new(pAct, H_PAD, 0, 0)
            actions.Size = UDim2.new(wAct, -H_PAD * 2, 1, 0)
        end

    elseif tabKey == "Game" then
        local pStat, wStat = positions[1], widths[1]
        local pName, wName = positions[2], widths[2]
        local pEvt, wEvt = positions[3], widths[3]
        local pSts, wSts = positions[4], widths[4]
        local pAct, wAct = positions[5], widths[5]

        local dot = row:FindFirstChild("Dot")
        if dot then
            dot.Position = UDim2.new(pStat + wStat / 2, -4, 0.5, -4)
        end
        local nameLbl = row:FindFirstChild("NameLbl")
        if nameLbl then
            nameLbl.Position = UDim2.new(pName, H_PAD, 0, 0)
            nameLbl.Size = UDim2.new(wName, -H_PAD * 2, 1, 0)
        end
        local eventLbl = row:FindFirstChild("EventLbl")
        if eventLbl then
            eventLbl.Position = UDim2.new(pEvt, H_PAD, 0, 0)
            eventLbl.Size = UDim2.new(wEvt, -H_PAD * 2, 1, 0)
            eventLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local statusLbl = row:FindFirstChild("StatusLbl")
        if statusLbl then
            statusLbl.Position = UDim2.new(pSts, H_PAD, 0, 0)
            statusLbl.Size = UDim2.new(wSts, -H_PAD * 2, 1, 0)
            statusLbl.TextXAlignment = Enum.TextXAlignment.Center
        end
        local disconnectBtn = row:FindFirstChild("DisconnectBtn")
        if disconnectBtn then
            disconnectBtn.Position = UDim2.new(pAct + wAct / 2, -32, 0.5, -10)
        end
    end
end

updateTableColumnLayout = function(tabKey)
    local cfg = ColumnConfig[tabKey]
    if not cfg then return end
    local positions, widths = computeColumnPositions(tabKey)
    if #positions == 0 then return end

    if ColumnWidths[tabKey] and cfg.cols[2] then
        ColumnWidths[tabKey].name = cfg.cols[2].width
    end

    local header = TableHeaders[tabKey]
    if header then
        for i, col in ipairs(cfg.cols) do
            local colLabel = header:FindFirstChild("Col_" .. col.id)
            if colLabel then
                colLabel.Position = UDim2.new(positions[i], H_PAD, 0, 0)
                colLabel.Size = UDim2.new(widths[i], -H_PAD * 2, 1, 0)
                colLabel.TextXAlignment = col.align or Enum.TextXAlignment.Center
            end
        end

        for i = 1, #cfg.cols - 1 do
            local divider = header:FindFirstChild("ColDivider_" .. i)
            if divider then
                divider.Position = UDim2.new(positions[i + 1], -9, 0, 0)
            end
        end
    end

    local cache = nil
    if tabKey == "Startup" then cache = cachedStartupRows
    elseif tabKey == "Tasks" then cache = cachedTaskRows
    elseif tabKey == "Loops" then cache = cachedLoopRows
    elseif tabKey == "Game" then cache = cachedGameRows
    end

    if cache then
        for _, row in pairs(cache) do
            applyRowColumnLayout(row, tabKey)
        end
    end
end

autoFitColumn = function(tabKey, divIdx)
    divIdx = divIdx or 2
    local cfg = ColumnConfig[tabKey]
    if not cfg or not cfg.cols[divIdx] then return end
    local targetCol = cfg.cols[divIdx]

    local header = TableHeaders[tabKey]
    local headerWidth = (header and header.AbsoluteSize.X > 50) and header.AbsoluteSize.X or 800
    local longestText = ""
    local TextService = game:GetService("TextService")

    if divIdx == 1 then
        longestText = "PRIORITY"
    elseif divIdx == 2 then
        if tabKey == "Startup" and allStartupScriptsRef then
            for _, s in ipairs(allStartupScriptsRef) do
                local t1 = s.name or ""
                local t2 = s.file or ""
                if #t1 > #longestText then longestText = t1 end
                if #t2 > #longestText then longestText = t2 end
            end
        elseif tabKey == "Tasks" then
            for _, r in pairs(cachedTaskRows) do
                local lbl = r:FindFirstChild("NameLbl")
                if lbl and lbl.Text and #lbl.Text > #longestText then longestText = lbl.Text end
            end
        elseif tabKey == "Loops" then
            for _, r in pairs(cachedLoopRows) do
                local lbl = r:FindFirstChild("NameLbl")
                if lbl and lbl.Text and #lbl.Text > #longestText then longestText = lbl.Text end
            end
        elseif tabKey == "Game" then
            for _, r in pairs(cachedGameRows) do
                local lbl = r:FindFirstChild("NameLbl")
                if lbl and lbl.Text and #lbl.Text > #longestText then longestText = lbl.Text end
            end
        end
    elseif divIdx == 3 then
        if tabKey == "Tasks" or tabKey == "Game" then
            for _, r in pairs(tabKey == "Tasks" and cachedTaskRows or cachedGameRows) do
                local lbl = r:FindFirstChild("EventLbl")
                if lbl and lbl.Text and #lbl.Text > #longestText then longestText = lbl.Text end
            end
        elseif tabKey == "Startup" and allStartupScriptsRef then
            for _, s in ipairs(allStartupScriptsRef) do
                local t = s.stage or ""
                if #t > #longestText then longestText = t end
            end
        elseif tabKey == "Loops" then
            for _, r in pairs(cachedLoopRows) do
                local lbl = r:FindFirstChild("ItersLbl")
                if lbl and lbl.Text and #lbl.Text > #longestText then longestText = lbl.Text end
            end
        end
    end

    local posX = 0.0
    for i = 1, divIdx - 1 do
        posX = posX + cfg.cols[i].width
    end

    if #longestText > 0 then
        local textSize = TextService:GetTextSize(longestText, 11, Enum.Font.GothamMedium, Vector2.new(10000, 20))
        local neededPx = textSize.X + 24
        local targetFraction = neededPx / headerWidth
        targetFraction = math.clamp(targetFraction, targetCol.minWidth or 0.05, targetCol.maxWidth or 0.65)
        handleDividerDrag(tabKey, divIdx, posX + targetFraction)
    else
        handleDividerDrag(tabKey, divIdx, posX + (targetCol.defaultWidth or targetCol.width))
    end
end

getgenv()._OmniTaskManager_HandleDividerDrag = handleDividerDrag
getgenv()._OmniTaskManager_AutoFitColumn = autoFitColumn

local function setupHeaderDividers(headerContainer, tabKey)
    local cfg = ColumnConfig[tabKey]
    if not cfg then return end
    local positions = computeColumnPositions(tabKey)

    for i = 1, #cfg.cols - 1 do
        local divIdx = i
        local divider = Instance.new("TextButton")
        divider.Name = "ColDivider_" .. divIdx
        divider.Size = UDim2.new(0, 18, 1, 0)
        divider.Position = UDim2.new(positions[divIdx + 1], -9, 0, 0)
        divider.BackgroundTransparency = 1
        divider.Text = ""
        divider.AutoButtonColor = false
        divider.ZIndex = 25
        divider.Parent = headerContainer

        local line = Instance.new("Frame")
        line.Name = "Line"
        line.Size = UDim2.new(0, 1, 0.7, 0)
        line.Position = UDim2.new(0.5, 0, 0.15, 0)
        line.BackgroundColor3 = Color3.fromRGB(55, 65, 85)
        line.BorderSizePixel = 0
        line.ZIndex = 26
        line.Parent = divider

        local gripIcon = Instance.new("TextLabel")
        gripIcon.Name = "GripIcon"
        gripIcon.Size = UDim2.new(0, 18, 0, 16)
        gripIcon.Position = UDim2.new(0.5, -9, 0.5, -8)
        gripIcon.BackgroundTransparency = 1
        gripIcon.Font = Enum.Font.GothamBold
        gripIcon.TextSize = 11
        gripIcon.TextColor3 = Color3.fromRGB(80, 200, 255)
        gripIcon.Text = ICONS.RESIZE
        gripIcon.Visible = false
        gripIcon.ZIndex = 28
        gripIcon.Parent = divider

        local lastClickTime = 0

        divider.MouseEnter:Connect(function()
            if not activeDividerDrag then
                line.BackgroundColor3 = Color3.fromRGB(80, 200, 255)
                line.Size = UDim2.new(0, 2, 0.85, 0)
                line.Position = UDim2.new(0.5, -1, 0.075, 0)
                gripIcon.Visible = true
            end
        end)

        divider.MouseLeave:Connect(function()
            if not activeDividerDrag then
                line.BackgroundColor3 = Color3.fromRGB(55, 65, 85)
                line.Size = UDim2.new(0, 1, 0.7, 0)
                line.Position = UDim2.new(0.5, 0, 0.15, 0)
                gripIcon.Visible = false
            end
        end)

        divider.MouseButton1Down:Connect(function()
            local now = tick()
            if now - lastClickTime < 0.35 then
                lastClickTime = 0
                autoFitColumn(tabKey, divIdx)
                return
            end
            lastClickTime = now

            activeDividerDrag = {
                tabKey = tabKey,
                dividerIdx = divIdx,
                header = headerContainer,
                divider = divider,
                line = line,
                gripIcon = gripIcon,
            }
            line.BackgroundColor3 = Color3.fromRGB(80, 200, 255)
            line.Size = UDim2.new(0, 2, 1, 0)
            line.Position = UDim2.new(0.5, -1, 0, 0)
            gripIcon.Visible = true
        end)
    end
end


local MIN_WIDTH = 640
local MIN_HEIGHT = 380
local MAX_WIDTH = 1600
local MAX_HEIGHT = 1000

-- ==============================================================================
-- LUAU SYNTAX HIGHLIGHTER LEXER ENGINE (File Scope)
-- ==============================================================================
local HL_KEYWORDS = {
    ["local"] = true, ["function"] = true, ["end"] = true, ["if"] = true,
    ["then"] = true, ["else"] = true, ["elseif"] = true, ["for"] = true,
    ["in"] = true, ["do"] = true, ["while"] = true, ["repeat"] = true,
    ["until"] = true, ["return"] = true, ["break"] = true, ["continue"] = true,
    ["not"] = true, ["and"] = true, ["or"] = true, ["type"] = true, ["export"] = true,
}

local HL_VALUES = {
    ["true"] = true, ["false"] = true, ["nil"] = true,
}

local HL_BUILTINS = {
    ["game"] = true, ["workspace"] = true, ["script"] = true, ["math"] = true,
    ["table"] = true, ["string"] = true, ["task"] = true, ["os"] = true,
    ["coroutine"] = true, ["debug"] = true, ["utf8"] = true, ["Instance"] = true,
    ["Vector2"] = true, ["Vector3"] = true, ["CFrame"] = true, ["Color3"] = true,
    ["UDim2"] = true, ["UDim"] = true, ["BrickColor"] = true, ["Ray"] = true,
    ["TweenInfo"] = true, ["Enum"] = true, ["pcall"] = true, ["xpcall"] = true,
    ["select"] = true, ["typeof"] = true, ["pairs"] = true, ["ipairs"] = true,
    ["next"] = true, ["print"] = true, ["warn"] = true, ["error"] = true,
    ["tick"] = true, ["time"] = true, ["wait"] = true, ["spawn"] = true,
    ["delay"] = true, ["loadstring"] = true, ["setfenv"] = true, ["getfenv"] = true,
    ["rawget"] = true, ["rawset"] = true, ["rawequal"] = true, ["setmetatable"] = true,
    ["getmetatable"] = true, ["getgenv"] = true, ["getrenv"] = true, ["readfile"] = true,
    ["writefile"] = true, ["appendfile"] = true, ["isfile"] = true, ["isfolder"] = true,
    ["listfiles"] = true, ["delfile"] = true, ["makefolder"] = true, ["delfolder"] = true,
    ["identifyexecutor"] = true, ["hookfunction"] = true, ["hookmetamethod"] = true,
    ["getconnections"] = true, ["firesignal"] = true,
}

local HL_C_KEYWORD  = "#c678dd" -- Purple
local HL_C_VALUE    = "#d19a66" -- Warm Orange
local HL_C_BUILTIN  = "#61afef" -- Sky Blue
local HL_C_STRING   = "#98c379" -- Mint Green
local HL_C_NUMBER   = "#e5c07b" -- Amber / Gold
local HL_C_COMMENT  = "#676e95" -- Slate Gray
local HL_C_OPERATOR = "#56b6c2" -- Cyan
local HL_C_DEFAULT  = "#abb2bf" -- Soft Light Gray

local function escapeXml(str)
    local s = str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
    return s
end

local function scanQuotedString(source, pos, quoteChar)
    local len = string.len(source)
    local p = pos + 1
    while p <= len do
        local c = source:sub(p, p)
        if c == "\\" then
            p = p + 2
        elseif c == quoteChar then
            return pos, p
        elseif c == "\n" or c == "\r" then
            return pos, p - 1
        else
            p = p + 1
        end
    end
    return pos, len
end

local function highlightLuau(source)
    local len = string.len(source)
    if len == 0 then return "" end
    if len > 65000 then
        return escapeXml(source)
    end

    local out = {}
    local pos = 1

    while pos <= len do
        local wsStart, wsEnd = source:find("^[ \t\r\n]+", pos)
        if wsStart then
            table.insert(out, source:sub(wsStart, wsEnd))
            pos = wsEnd + 1
        else
            if source:sub(pos, pos + 1) == "--" then
                local eq = source:sub(pos + 2):match("^%[(=*)%[")
                if eq then
                    local closeDelim = "]" .. eq .. "]"
                    local _, cEnd = source:find(closeDelim, pos + 4 + #eq, true)
                    if cEnd then
                        table.insert(out, '<font color="' .. HL_C_COMMENT .. '">' .. escapeXml(source:sub(pos, cEnd)) .. '</font>')
                        pos = cEnd + 1
                    else
                        table.insert(out, '<font color="' .. HL_C_COMMENT .. '">' .. escapeXml(source:sub(pos)) .. '</font>')
                        pos = len + 1
                    end
                else
                    local nl = source:find("[\r\n]", pos + 2)
                    local cEnd = nl and (nl - 1) or len
                    table.insert(out, '<font color="' .. HL_C_COMMENT .. '">' .. escapeXml(source:sub(pos, cEnd)) .. '</font>')
                    pos = cEnd + 1
                end
            else
                local c = source:sub(pos, pos)
                local eq = (c == "[") and source:sub(pos):match("^%[(=*)%[")
                if eq then
                    local closeDelim = "]" .. eq .. "]"
                    local _, sEnd = source:find(closeDelim, pos + 2 + #eq, true)
                    if sEnd then
                        table.insert(out, '<font color="' .. HL_C_STRING .. '">' .. escapeXml(source:sub(pos, sEnd)) .. '</font>')
                        pos = sEnd + 1
                    else
                        table.insert(out, '<font color="' .. HL_C_STRING .. '">' .. escapeXml(source:sub(pos)) .. '</font>')
                        pos = len + 1
                    end
                elseif c == '"' or c == "'" then
                    local sStart, sEnd = scanQuotedString(source, pos, c)
                    table.insert(out, '<font color="' .. HL_C_STRING .. '">' .. escapeXml(source:sub(sStart, sEnd)) .. '</font>')
                    pos = sEnd + 1
                else
                    local nStart, nEnd
                    if source:find("^%d+%.%.", pos) then
                        nStart, nEnd = source:find("^%d+", pos)
                    else
                        nStart, nEnd = source:find("^0[xX][0-9a-fA-F]+", pos)
                        if not nStart then nStart, nEnd = source:find("^0[bB][01]+", pos) end
                        if not nStart then nStart, nEnd = source:find("^%d+%.%d+[eE][%+%-]?%d+", pos) end
                        if not nStart then nStart, nEnd = source:find("^%d+[eE][%+%-]?%d+", pos) end
                        if not nStart then nStart, nEnd = source:find("^%d+%.%d+", pos) end
                        if not nStart then nStart, nEnd = source:find("^%d+", pos) end
                        if not nStart then nStart, nEnd = source:find("^%.%d+[eE][%+%-]?%d+", pos) end
                        if not nStart then nStart, nEnd = source:find("^%.%d+", pos) end
                    end

                    if nStart then
                        table.insert(out, '<font color="' .. HL_C_NUMBER .. '">' .. source:sub(nStart, nEnd) .. '</font>')
                        pos = nEnd + 1
                    else
                        local idStart, idEnd = source:find("^[a-zA-Z_][a-zA-Z0-9_]*", pos)
                        if idStart then
                            local word = source:sub(idStart, idEnd)
                            if HL_KEYWORDS[word] then
                                table.insert(out, '<font color="' .. HL_C_KEYWORD .. '">' .. word .. '</font>')
                            elseif HL_VALUES[word] then
                                table.insert(out, '<font color="' .. HL_C_VALUE .. '">' .. word .. '</font>')
                            elseif HL_BUILTINS[word] then
                                table.insert(out, '<font color="' .. HL_C_BUILTIN .. '">' .. word .. '</font>')
                            else
                                table.insert(out, '<font color="' .. HL_C_DEFAULT .. '">' .. escapeXml(word) .. '</font>')
                            end
                            pos = idEnd + 1
                        else
                            local three = source:sub(pos, pos + 2)
                            if three == "..." then
                                table.insert(out, '<font color="' .. HL_C_OPERATOR .. '">...</font>')
                                pos = pos + 3
                            else
                                local two = source:sub(pos, pos + 1)
                                if two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." or two == "::" or two == "+=" or two == "-=" or two == "*=" or two == "/=" then
                                    table.insert(out, '<font color="' .. HL_C_OPERATOR .. '">' .. escapeXml(two) .. '</font>')
                                    pos = pos + 2
                                else
                                    local ch = source:sub(pos, pos)
                                    if ch:find("[%+%-%*%/%%%^%#%=%<%>%:%.%,%;%(%)%{%}%[%]]") then
                                        table.insert(out, '<font color="' .. HL_C_OPERATOR .. '">' .. escapeXml(ch) .. '</font>')
                                    else
                                        table.insert(out, escapeXml(ch))
                                    end
                                    pos = pos + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return table.concat(out)
end

local function initHUD()
local function getGuiParent()
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if ok and coreGui then return coreGui end
    local lp = Players.LocalPlayer
    if lp then
        local pg = lp:FindFirstChild("PlayerGui")
        if pg then return pg end
    end
    return nil
end

local guiParent = getGuiParent()
if not guiParent then
    warn("[TaskManagerHUD]: Unable to locate valid GUI parent container.")
    return
end

if type(getgenv()._KernelTaskManagerCleanUp) == "function" then
    pcall(getgenv()._KernelTaskManagerCleanUp)
end
local existingGui = guiParent:FindFirstChild("KernelTaskManager_Protected")
if existingGui then
    pcall(function() existingGui:Destroy() end)
end
local existingUpdateGui = guiParent:FindFirstChild("OmniUpdateGate_Protected")
if existingUpdateGui then
    pcall(function() existingUpdateGui:Destroy() end)
end

-- ==============================================================================
-- GUI CONSTRUCTION
-- ==============================================================================

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "KernelTaskManager_Protected"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999999
ScreenGui.Enabled = false

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 760, 0, 520)
MainFrame.Position = UDim2.new(0.5, -380, 0.5, -260)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Active = true
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 8)
MainCorner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke")
MainStroke.Thickness = 1
MainStroke.Color = Color3.fromRGB(45, 52, 68)
MainStroke.Parent = MainFrame

-- Top Navigation / Title Bar
local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 38)
TitleBar.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
TitleBar.BorderSizePixel = 0
TitleBar.Active = true
TitleBar.Parent = MainFrame

local TitleBarCorner = Instance.new("UICorner")
TitleBarCorner.CornerRadius = UDim.new(0, 8)
TitleBarCorner.Parent = TitleBar

local TitleBarCover = Instance.new("Frame")
TitleBarCover.Size = UDim2.new(1, 0, 0, 8)
TitleBarCover.Position = UDim2.new(0, 0, 1, -8)
TitleBarCover.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
TitleBarCover.BorderSizePixel = 0
TitleBarCover.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Name = "TitleLabel"
TitleLabel.Size = UDim2.new(0, 260, 1, 0)
TitleLabel.Position = UDim2.new(0, 12, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Active = false
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 13
TitleLabel.TextColor3 = Color3.fromRGB(64, 196, 255)
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Text = "⚡ OMNI TASK MANAGER"
TitleLabel.Parent = TitleBar

local KeybindBadge = Instance.new("TextLabel")
KeybindBadge.Name = "KeybindBadge"
KeybindBadge.Size = UDim2.new(0, 80, 0, 20)
KeybindBadge.Position = UDim2.new(0, 230, 0.5, -10)
KeybindBadge.BackgroundColor3 = Color3.fromRGB(30, 36, 50)
KeybindBadge.Active = false
KeybindBadge.Font = Enum.Font.GothamBold
KeybindBadge.TextSize = 10
KeybindBadge.TextColor3 = Color3.fromRGB(160, 175, 200)
KeybindBadge.Text = "Shift + F8"
KeybindBadge.Parent = TitleBar

local KeybindBadgeCorner = Instance.new("UICorner")
KeybindBadgeCorner.CornerRadius = UDim.new(0, 4)
KeybindBadgeCorner.Parent = KeybindBadge

local UpdateBadge = Instance.new("TextButton")
UpdateBadge.Name = "UpdateBadge"
UpdateBadge.Size = UDim2.new(0, 126, 0, 20)
UpdateBadge.Position = UDim2.new(0, 320, 0.5, -10)
UpdateBadge.BackgroundColor3 = Color3.fromRGB(25, 60, 100)
UpdateBadge.Font = Enum.Font.GothamBold
UpdateBadge.TextSize = 10
UpdateBadge.TextColor3 = Color3.fromRGB(100, 210, 255)
UpdateBadge.Text = "⚡ Update Available"
UpdateBadge.Visible = (getgenv()._OmniUpdateAvailable == true and not getgenv()._OmniUpdateDismissed)
if getgenv()._OmniUpdateBadgeText then UpdateBadge.Text = getgenv()._OmniUpdateBadgeText end
UpdateBadge.Parent = TitleBar

local UpdateBadgeCorner = Instance.new("UICorner")
UpdateBadgeCorner.CornerRadius = UDim.new(0, 4)
UpdateBadgeCorner.Parent = UpdateBadge

local UpdateBadgeStroke = Instance.new("UIStroke")
UpdateBadgeStroke.Thickness = 1
UpdateBadgeStroke.Color = Color3.fromRGB(50, 130, 210)
UpdateBadgeStroke.Parent = UpdateBadge

local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.Size = UDim2.new(0, 28, 0, 28)
CloseBtn.Position = UDim2.new(1, -34, 0.5, -14)
CloseBtn.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 13
CloseBtn.TextColor3 = Color3.fromRGB(200, 210, 225)
CloseBtn.Text = "X"
CloseBtn.Modal = true
CloseBtn.Parent = TitleBar

local CloseBtnCorner = Instance.new("UICorner")
CloseBtnCorner.CornerRadius = UDim.new(0, 6)
CloseBtnCorner.Parent = CloseBtn

-- ==============================================================================
-- WINDOW DRAG & RESIZE ENGINE
-- ==============================================================================

local hudWindowConnections = {}

-- 1. Draggable Window via TitleBar
local dragging = false
local dragStart = Vector3.new()
local startPos = UDim2.new()

local function isInsideGui(guiObj, pos)
    if not guiObj or not guiObj.Visible then return false end
    local p = guiObj.AbsolutePosition
    local s = guiObj.AbsoluteSize
    return pos.X >= p.X and pos.X <= (p.X + s.X) and pos.Y >= p.Y and pos.Y <= (p.Y + s.Y)
end

local function handleDragStart(pos)
    if not ScreenGui.Enabled then return end
    -- Guard interactive title bar buttons
    if isInsideGui(CloseBtn, pos) or (UpdateBadge and isInsideGui(UpdateBadge, pos)) then
        return
    end
    -- Check if click originated within TitleBar bounds
    if isInsideGui(TitleBar, pos) then
        dragging = true
        dragStart = pos
        startPos = MainFrame.Position
    end
end

table.insert(hudWindowConnections, UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        handleDragStart(input.Position)
    end
end))

table.insert(hudWindowConnections, TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        handleDragStart(input.Position)
    end
end))

table.insert(hudWindowConnections, UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end))

table.insert(hudWindowConnections, UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end))

-- 2. Resizable Window via Bottom-Right Resize Handle
local ResizeGrip = Instance.new("TextButton")
ResizeGrip.Name = "ResizeGrip"
ResizeGrip.Size = UDim2.new(0, 16, 0, 16)
ResizeGrip.Position = UDim2.new(1, -16, 1, -16)
ResizeGrip.BackgroundTransparency = 1
ResizeGrip.BorderSizePixel = 0
ResizeGrip.Font = Enum.Font.GothamBold
ResizeGrip.TextSize = 11
ResizeGrip.TextColor3 = Color3.fromRGB(80, 95, 120)
ResizeGrip.Text = "◢"
ResizeGrip.ZIndex = 100
ResizeGrip.Parent = MainFrame


local resizing = false
local resizeStart = Vector3.new()
local startSize = Vector2.new()

ResizeGrip.MouseEnter:Connect(function()
    ResizeGrip.TextColor3 = Color3.fromRGB(64, 196, 255)
end)

ResizeGrip.MouseLeave:Connect(function()
    if not resizing then
        ResizeGrip.TextColor3 = Color3.fromRGB(80, 95, 120)
    end
end)

ResizeGrip.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        resizing = true
        resizeStart = input.Position
        startSize = Vector2.new(MainFrame.AbsoluteSize.X, MainFrame.AbsoluteSize.Y)
        ResizeGrip.TextColor3 = Color3.fromRGB(64, 196, 255)
    end
end)

table.insert(hudWindowConnections, UserInputService.InputChanged:Connect(function(input)
    if activeDividerDrag and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local mouseX = input.Position.X
        local header = activeDividerDrag.header
        local headerX = header.AbsolutePosition.X
        local headerW = header.AbsoluteSize.X
        if headerW > 50 then
            local relX = (mouseX - headerX) / headerW
            handleDividerDrag(activeDividerDrag.tabKey, activeDividerDrag.dividerIdx, relX)
        end
    end
    if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - resizeStart
        local newW = math.clamp(startSize.X + delta.X, MIN_WIDTH, MAX_WIDTH)
        local newH = math.clamp(startSize.Y + delta.Y, MIN_HEIGHT, MAX_HEIGHT)
        MainFrame.Size = UDim2.new(0, newW, 0, newH)
    end
end))

table.insert(hudWindowConnections, UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if activeDividerDrag then
            if activeDividerDrag.line then
                activeDividerDrag.line.BackgroundColor3 = Color3.fromRGB(55, 65, 85)
                activeDividerDrag.line.Size = UDim2.new(0, 1, 0.7, 0)
                activeDividerDrag.line.Position = UDim2.new(0.5, 0, 0.15, 0)
            end
            if activeDividerDrag.gripIcon then
                activeDividerDrag.gripIcon.Visible = false
            end
            activeDividerDrag = nil
        end
        if resizing then
            resizing = false
            ResizeGrip.TextColor3 = Color3.fromRGB(80, 95, 120)
        end
    end
end))

-- ==============================================================================
-- PERFORMANCE DASHBOARD (HEADER)
-- ==============================================================================

local DashContainer = Instance.new("Frame")
DashContainer.Name = "DashContainer"
DashContainer.Size = UDim2.new(1, -24, 0, 60)
DashContainer.Position = UDim2.new(0, 12, 0, 44)
DashContainer.BackgroundTransparency = 1
DashContainer.Parent = MainFrame

local DashLayout = Instance.new("UIListLayout")
DashLayout.FillDirection = Enum.FillDirection.Horizontal
DashLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
DashLayout.SortOrder = Enum.SortOrder.LayoutOrder
DashLayout.Padding = UDim.new(0, 8)
DashLayout.Parent = DashContainer

local function createMetricCard(name, order, title, primaryDefault, subDefault)
    local card = Instance.new("Frame")
    card.Name = name
    card.Size = UDim2.new(0.25, -6, 1, 0)
    card.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
    card.BorderSizePixel = 0
    card.LayoutOrder = order
    card.Parent = DashContainer

    local cardCorner = Instance.new("UICorner")
    cardCorner.CornerRadius = UDim.new(0, 6)
    cardCorner.Parent = card

    local cardStroke = Instance.new("UIStroke")
    cardStroke.Thickness = 1
    cardStroke.Color = Color3.fromRGB(35, 41, 55)
    cardStroke.Parent = card

    local header = Instance.new("TextLabel")
    header.Size = UDim2.new(1, -12, 0, 15)
    header.Position = UDim2.new(0, 8, 0, 5)
    header.BackgroundTransparency = 1
    header.Font = Enum.Font.Gotham
    header.TextSize = 9
    header.TextColor3 = Color3.fromRGB(130, 145, 170)
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = title
    header.Parent = card

    local primary = Instance.new("TextLabel")
    primary.Name = "Primary"
    primary.Size = UDim2.new(1, -12, 0, 20)
    primary.Position = UDim2.new(0, 8, 0, 19)
    primary.BackgroundTransparency = 1
    primary.Font = Enum.Font.GothamBold
    primary.TextSize = 13
    primary.TextColor3 = Color3.fromRGB(255, 255, 255)
    primary.TextXAlignment = Enum.TextXAlignment.Left
    primary.Text = primaryDefault
    primary.Parent = card

    local sub = Instance.new("TextLabel")
    sub.Name = "Sub"
    sub.Size = UDim2.new(1, -12, 0, 14)
    sub.Position = UDim2.new(0, 8, 0, 39)
    sub.BackgroundTransparency = 1
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 9
    sub.TextColor3 = Color3.fromRGB(110, 125, 150)
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.Text = subDefault
    sub.Parent = card

    return card, primary, sub
end

local CardFps, LblFps, LblBudget = createMetricCard("CardFps", 1, "ENGINE REFRESH", "60 FPS", "Budget: 3.40ms")
local CardCpu, LblCpu, LblBudgetPct = createMetricCard("CardCpu", 2, "TOTAL CPU LOAD", "0.00ms", "0.0% of Frame Budget")
local CardMem, LblMem, LblGc = createMetricCard("CardMem", 3, "LUAU HEAP", "0.0 MB", "0 KB GC")
local CardTasks, LblTasks, LblTaskSub = createMetricCard("CardTasks", 4, "ACTIVE WORKLOAD", "0 Tasks", "0 Loops Tracked")

-- ==============================================================================
-- TAB BAR NAVIGATION
-- ==============================================================================

local TabBar = Instance.new("Frame")
TabBar.Name = "TabBar"
TabBar.Size = UDim2.new(1, -24, 0, 28)
TabBar.Position = UDim2.new(0, 12, 0, 110)
TabBar.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
TabBar.BorderSizePixel = 0
TabBar.Parent = MainFrame

local TabBarCorner = Instance.new("UICorner")
TabBarCorner.CornerRadius = UDim.new(0, 6)
TabBarCorner.Parent = TabBar

local TabBarLayout = Instance.new("UIListLayout")
TabBarLayout.FillDirection = Enum.FillDirection.Horizontal
TabBarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
TabBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
TabBarLayout.Padding = UDim.new(0, 4)
TabBarLayout.Parent = TabBar

local currentTab = "Tasks" -- "Tasks" | "Loops" | "Performance" | "Startup"

local tasksSubMode = "active" -- "active" | "advanced"

local function createTabBtn(name, text, order)
    local btn = Instance.new("TextButton")
    btn.Name = name
    btn.Size = UDim2.new(0.25, -3, 1, 0)
    btn.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.TextColor3 = Color3.fromRGB(130, 145, 170)
    btn.Text = text
    btn.LayoutOrder = order
    btn.Parent = TabBar

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 6)
    btnCorner.Parent = btn

    return btn
end

local TabTasksBtn = createTabBtn("TabTasksBtn", "⚡ Runtime", 1)
local TabLoopsBtn = createTabBtn("TabLoopsBtn", "🔄 Loops", 2)
local TabPerfBtn = createTabBtn("TabPerfBtn", "📈 Performance", 3)
local TabStartupBtn = createTabBtn("TabStartupBtn", "🚀 Startup", 4)

-- ==============================================================================
-- SHARED COLUMN HEADER BUILDER
-- ==============================================================================

local function createHeaderContainer(name)
    local header = Instance.new("Frame")
    header.Name = name
    header.Size = UDim2.new(1, -24, 0, 26)
    header.Position = UDim2.new(0, 12, 0, 144)
    header.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
    header.BorderSizePixel = 0
    header.Visible = false
    header.Parent = MainFrame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = header

    return header
end

local function addHeaderColumn(parent, text, sizeX, posX, align, tabKey, colId)
    local btn = Instance.new("TextButton")
    btn.Name = "Col_" .. (colId or "")
    btn.Size = UDim2.new(sizeX, -H_PAD * 2, 1, 0)
    btn.Position = UDim2.new(posX, H_PAD, 0, 0)
    btn.BackgroundTransparency = 1
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 10
    btn.TextColor3 = Color3.fromRGB(140, 155, 180)
    btn.TextXAlignment = align or Enum.TextXAlignment.Center
    btn.Text = text
    btn.AutoButtonColor = false
    btn.ZIndex = 12
    btn.Parent = parent

    btn.MouseEnter:Connect(function()
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    end)
    btn.MouseLeave:Connect(function()
        local isSorted = (TableSortState[tabKey] and TableSortState[tabKey].colId == colId)
        btn.TextColor3 = isSorted and Color3.fromRGB(240, 245, 255) or Color3.fromRGB(140, 155, 180)
    end)

    btn.MouseButton1Click:Connect(function()
        toggleTableSort(tabKey, colId)
    end)

    return btn
end

-- 1. Tasks Header
local TableHeaderTasks = createHeaderContainer("TableHeaderTasks")
TableHeaders.Tasks = TableHeaderTasks
TableHeaderTasks.Visible = true
for _, col in ipairs(ColumnConfig.Tasks.cols) do
    addHeaderColumn(TableHeaderTasks, col.name, col.width, 0, col.align, "Tasks", col.id)
end
setupHeaderDividers(TableHeaderTasks, "Tasks")

-- 4. Loops Header
local TableHeaderLoops = createHeaderContainer("TableHeaderLoops")
TableHeaders.Loops = TableHeaderLoops
for _, col in ipairs(ColumnConfig.Loops.cols) do
    addHeaderColumn(TableHeaderLoops, col.name, col.width, 0, col.align, "Loops", col.id)
end
setupHeaderDividers(TableHeaderLoops, "Loops")

-- 3. Startup Header
local TableHeaderStartup = createHeaderContainer("TableHeaderStartup")
TableHeaders.Startup = TableHeaderStartup
for _, col in ipairs(ColumnConfig.Startup.cols) do
    addHeaderColumn(TableHeaderStartup, col.name, col.width, 0, col.align, "Startup", col.id)
end
setupHeaderDividers(TableHeaderStartup, "Startup")

-- 5. Game Tasks Header
local TableHeaderGame = createHeaderContainer("TableHeaderGame")
TableHeaders.Game = TableHeaderGame
for _, col in ipairs(ColumnConfig.Game.cols) do
    addHeaderColumn(TableHeaderGame, col.name, col.width, 0, col.align, "Game", col.id)
end
setupHeaderDividers(TableHeaderGame, "Game")

updateTableColumnLayout("Tasks")
updateTableColumnLayout("Loops")
updateTableColumnLayout("Startup")
updateTableColumnLayout("Game")

updateHeaderSortIndicators("Tasks")
updateHeaderSortIndicators("Loops")
updateHeaderSortIndicators("Startup")
updateHeaderSortIndicators("Game")

-- ==============================================================================
-- SCROLLING LIST CONTAINERS
-- ==============================================================================

local function createScrollList(name)
    local list = Instance.new("ScrollingFrame")
    list.Name = name
    list.Size = UDim2.new(1, -24, 1, -222)
    list.Position = UDim2.new(0, 12, 0, 174)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 4
    list.ScrollBarImageColor3 = Color3.fromRGB(50, 60, 80)
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Visible = false
    list.Parent = MainFrame

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 4)
    layout.Parent = list

    local empty = Instance.new("TextLabel")
    empty.Name = "EmptyLabel"
    empty.Size = UDim2.new(1, 0, 0, 100)
    empty.BackgroundTransparency = 1
    empty.Font = Enum.Font.Gotham
    empty.TextSize = 13
    empty.TextColor3 = Color3.fromRGB(110, 125, 150)
    empty.TextWrapped = true
    empty.Text = "No active data."
    empty.Parent = list

    return list, empty
end

local ScrollListTasks, EmptyTasks = createScrollList("ScrollListTasks")
ScrollListTasks.Visible = true
local ScrollListGame, EmptyGame = createScrollList("ScrollListGame")
local ScrollListLoops, EmptyLoops = createScrollList("ScrollListLoops")
local ScrollListStartup, EmptyStartup = createScrollList("ScrollListStartup")

-- ==============================================================================
-- PERFORMANCE DASHBOARD & SPARKLINE GRAPHS (PanelPerf)
-- ==============================================================================

local PanelPerf = Instance.new("Frame")
PanelPerf.Name = "PanelPerf"
PanelPerf.Size = UDim2.new(1, -24, 1, -192)
PanelPerf.Position = UDim2.new(0, 12, 0, 144)
PanelPerf.BackgroundTransparency = 1
PanelPerf.Visible = false
PanelPerf.Parent = MainFrame

-- Mini Stat Cards Row (Height: 46)
local PerfStatsRow = Instance.new("Frame")
PerfStatsRow.Name = "PerfStatsRow"
PerfStatsRow.Size = UDim2.new(1, 0, 0, 46)
PerfStatsRow.Position = UDim2.new(0, 0, 0, 0)
PerfStatsRow.BackgroundTransparency = 1
PerfStatsRow.Parent = PanelPerf

local PerfStatsLayout = Instance.new("UIListLayout")
PerfStatsLayout.FillDirection = Enum.FillDirection.Horizontal
PerfStatsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
PerfStatsLayout.SortOrder = Enum.SortOrder.LayoutOrder
PerfStatsLayout.Padding = UDim.new(0, 8)
PerfStatsLayout.Parent = PerfStatsRow

local function createPerfStatCard(name, order, title, primaryDef, subDef)
    local card = Instance.new("Frame")
    card.Name = name
    card.Size = UDim2.new(0.25, -6, 1, 0)
    card.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
    card.BorderSizePixel = 0
    card.LayoutOrder = order
    card.Parent = PerfStatsRow

    local cCorner = Instance.new("UICorner")
    cCorner.CornerRadius = UDim.new(0, 6)
    cCorner.Parent = card

    local cStroke = Instance.new("UIStroke")
    cStroke.Thickness = 1
    cStroke.Color = Color3.fromRGB(35, 41, 55)
    cStroke.Parent = card

    local lblTitle = Instance.new("TextLabel")
    lblTitle.Size = UDim2.new(1, -12, 0, 14)
    lblTitle.Position = UDim2.new(0, 8, 0, 4)
    lblTitle.BackgroundTransparency = 1
    lblTitle.Font = Enum.Font.Gotham
    lblTitle.TextSize = 9
    lblTitle.TextColor3 = Color3.fromRGB(130, 145, 170)
    lblTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblTitle.Text = title
    lblTitle.Parent = card

    local lblPri = Instance.new("TextLabel")
    lblPri.Name = "Primary"
    lblPri.Size = UDim2.new(1, -12, 0, 16)
    lblPri.Position = UDim2.new(0, 8, 0, 16)
    lblPri.BackgroundTransparency = 1
    lblPri.Font = Enum.Font.GothamBold
    lblPri.TextSize = 12
    lblPri.TextColor3 = Color3.fromRGB(255, 255, 255)
    lblPri.TextXAlignment = Enum.TextXAlignment.Left
    lblPri.Text = primaryDef
    lblPri.Parent = card

    local lblSub = Instance.new("TextLabel")
    lblSub.Name = "Sub"
    lblSub.Size = UDim2.new(1, -12, 0, 12)
    lblSub.Position = UDim2.new(0, 8, 0, 31)
    lblSub.BackgroundTransparency = 1
    lblSub.Font = Enum.Font.Gotham
    lblSub.TextSize = 9
    lblSub.TextColor3 = Color3.fromRGB(110, 125, 150)
    lblSub.TextXAlignment = Enum.TextXAlignment.Left
    lblSub.Text = subDef
    lblSub.Parent = card

    return card, lblPri, lblSub
end

local CardStatFps, LblStatFpsPri, LblStatFpsSub = createPerfStatCard("CardStatFps", 1, "FPS STABILITY", "60 FPS Avg", "Min: 60 | Max: 60")
local CardStatFrame, LblStatFramePri, LblStatFrameSub = createPerfStatCard("CardStatFrame", 2, "FRAME DURATION", "16.6 ms", "Target: 3.4ms Budget")
local CardStatCpu, LblStatCpuPri, LblStatCpuSub = createPerfStatCard("CardStatCpu", 3, "KERNEL CPU WORKLOAD", "0.05 ms Avg", "Peak: 0.12 ms (3.5%)")
local CardStatSys, LblStatSysPri, LblStatSysSub = createPerfStatCard("CardStatSys", 4, "MEMORY & LATENCY", "14.2 MB Luau", "35 ms Ping")

-- Dual Graph Containers Row (Height: fills remaining, from Y=54 down to bottom)
local PerfGraphsContainer = Instance.new("Frame")
PerfGraphsContainer.Name = "PerfGraphsContainer"
PerfGraphsContainer.Size = UDim2.new(1, 0, 1, -54)
PerfGraphsContainer.Position = UDim2.new(0, 0, 0, 54)
PerfGraphsContainer.BackgroundTransparency = 1
PerfGraphsContainer.Parent = PanelPerf

local PerfGraphsLayout = Instance.new("UIListLayout")
PerfGraphsLayout.FillDirection = Enum.FillDirection.Horizontal
PerfGraphsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
PerfGraphsLayout.SortOrder = Enum.SortOrder.LayoutOrder
PerfGraphsLayout.Padding = UDim.new(0, 8)
PerfGraphsLayout.Parent = PerfGraphsContainer

local function createGraphCard(name, order, title, defaultVal)
    local card = Instance.new("Frame")
    card.Name = name
    card.Size = UDim2.new(0.5, -4, 1, 0)
    card.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
    card.BorderSizePixel = 0
    card.LayoutOrder = order
    card.Parent = PerfGraphsContainer

    local cCorner = Instance.new("UICorner")
    cCorner.CornerRadius = UDim.new(0, 6)
    cCorner.Parent = card

    local cStroke = Instance.new("UIStroke")
    cStroke.Thickness = 1
    cStroke.Color = Color3.fromRGB(35, 41, 55)
    cStroke.Parent = card

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, -16, 0, 24)
    header.Position = UDim2.new(0, 8, 0, 6)
    header.BackgroundTransparency = 1
    header.Parent = card

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(0.65, 0, 1, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 11
    titleLbl.TextColor3 = Color3.fromRGB(200, 215, 240)
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Text = title
    titleLbl.Parent = header

    local valLbl = Instance.new("TextLabel")
    valLbl.Name = "ValLbl"
    valLbl.Size = UDim2.new(0.35, 0, 1, 0)
    valLbl.Position = UDim2.new(0.65, 0, 0, 0)
    valLbl.BackgroundTransparency = 1
    valLbl.Font = Enum.Font.GothamBold
    valLbl.TextSize = 11
    valLbl.TextColor3 = Color3.fromRGB(80, 200, 255)
    valLbl.TextXAlignment = Enum.TextXAlignment.Right
    valLbl.Text = defaultVal
    valLbl.Parent = header

    -- Canvas frame where bars are positioned
    local canvas = Instance.new("Frame")
    canvas.Name = "Canvas"
    canvas.Size = UDim2.new(1, -16, 1, -40)
    canvas.Position = UDim2.new(0, 8, 0, 32)
    canvas.BackgroundColor3 = Color3.fromRGB(14, 17, 24)
    canvas.BorderSizePixel = 0
    canvas.ClipsDescendants = true
    canvas.Parent = card

    local canCorner = Instance.new("UICorner")
    canCorner.CornerRadius = UDim.new(0, 4)
    canCorner.Parent = canvas

    -- Baseline grid line at 50%
    local midLine = Instance.new("Frame")
    midLine.Size = UDim2.new(1, 0, 0, 1)
    midLine.Position = UDim2.new(0, 0, 0.5, 0)
    midLine.BackgroundColor3 = Color3.fromRGB(30, 36, 50)
    midLine.BorderSizePixel = 0
    midLine.Parent = canvas

    local bars = {}
    local sampleCount = 60
    for i = 1, sampleCount do
        local bar = Instance.new("Frame")
        bar.Name = "Bar_" .. i
        bar.AnchorPoint = Vector2.new(0, 1)
        bar.Size = UDim2.new(1 / sampleCount, -1, 0.5, 0)
        bar.Position = UDim2.new((i - 1) / sampleCount, 0, 1, 0)
        bar.BackgroundColor3 = Color3.fromRGB(50, 180, 240)
        bar.BorderSizePixel = 0
        bar.Parent = canvas

        bars[i] = bar
    end

    return card, valLbl, canvas, bars
end

local CardFpsGraph, LblLiveFpsVal, CanvasFps, FpsBars = createGraphCard("CardFpsGraph", 1, "📈 FPS (60s HISTORY)", "60 FPS")
local CardCpuGraph, LblLiveCpuVal, CanvasCpu, CpuBars = createGraphCard("CardCpuGraph", 2, "⚡ CPU USAGE (60s HISTORY)", "0.05 ms")

local function updatePerformanceUI(profile)
    local stats = getPerfStats()
    local curFps = stats.fps[#stats.fps] or 60
    local curCpu = stats.cpu[#stats.cpu] or 0.05
    local curMem = stats.mem[#stats.mem] or 0
    local curPing = stats.ping[#stats.ping] or 30

    -- 1. Mini Stat Cards
    LblStatFpsPri.Text = string.format("%d FPS Avg", stats.avgFps)
    LblStatFpsSub.Text = string.format("Min: %d | Max: %d", stats.minFps, stats.maxFps)
    if stats.avgFps < 45 then
        LblStatFpsPri.TextColor3 = Color3.fromRGB(255, 80, 80)
    elseif stats.avgFps < 55 then
        LblStatFpsPri.TextColor3 = Color3.fromRGB(255, 180, 50)
    else
        LblStatFpsPri.TextColor3 = Color3.fromRGB(100, 230, 150)
    end

    local frameDurationMs = (curFps > 0) and (1000 / curFps) or 16.6
    local budgetMs = profile.frameBudgetMs or 3.4
    LblStatFramePri.Text = string.format("%.1f ms / frame", frameDurationMs)
    LblStatFrameSub.Text = string.format("Target: %.2fms Budget", budgetMs)

    local peakPct = (budgetMs > 0) and ((stats.peakCpu / budgetMs) * 100) or 0
    LblStatCpuPri.Text = string.format("%.2f ms Avg", stats.avgCpu)
    LblStatCpuSub.Text = string.format("Peak: %.2f ms (%.1f%%)", stats.peakCpu, peakPct)
    if stats.avgCpu > 2.0 then
        LblStatCpuPri.TextColor3 = Color3.fromRGB(255, 80, 80)
    elseif stats.avgCpu > 1.0 then
        LblStatCpuPri.TextColor3 = Color3.fromRGB(255, 180, 50)
    else
        LblStatCpuPri.TextColor3 = Color3.fromRGB(80, 200, 255)
    end

    LblStatSysPri.Text = string.format("%.1f MB Luau", curMem)
    LblStatSysSub.Text = string.format("%d ms Ping", curPing)

    -- 2. Graph Headers
    LblLiveFpsVal.Text = string.format("%d FPS", curFps)
    LblLiveCpuVal.Text = string.format("%.2f ms", curCpu)

    -- 3. Update 60 Bars for FPS
    local maxTargetFps = math.max(60, stats.maxFps)
    for i, bar in ipairs(FpsBars) do
        local sample = stats.fps[i] or 60
        local heightRatio = math.clamp(sample / maxTargetFps, 0.04, 1.0)
        bar.Size = UDim2.new(1 / 60, -1, heightRatio, 0)
        if sample >= 55 then
            bar.BackgroundColor3 = Color3.fromRGB(50, 210, 130)
        elseif sample >= 40 then
            bar.BackgroundColor3 = Color3.fromRGB(240, 190, 50)
        else
            bar.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
        end
    end

    -- 4. Update 60 Bars for CPU
    local maxScaleCpu = math.max(budgetMs, stats.peakCpu, 2.0)
    for i, bar in ipairs(CpuBars) do
        local sample = stats.cpu[i] or 0.05
        local heightRatio = math.clamp(sample / maxScaleCpu, 0.04, 1.0)
        bar.Size = UDim2.new(1 / 60, -1, heightRatio, 0)
        if sample > (budgetMs * 0.75) then
            bar.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
        elseif sample > (budgetMs * 0.40) then
            bar.BackgroundColor3 = Color3.fromRGB(255, 180, 50)
        else
            bar.BackgroundColor3 = Color3.fromRGB(60, 160, 255)
        end
    end
end

-- ==============================================================================
-- FOOTER & ACTION TOOLBAR
-- ==============================================================================

local currentSourceFilter = "all" -- "all" | "executor" | "game"

local Footer = Instance.new("Frame")
Footer.Name = "Footer"
Footer.Size = UDim2.new(1, -24, 0, 36)
Footer.Position = UDim2.new(0, 12, 1, -42)
Footer.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
Footer.BorderSizePixel = 0
Footer.Parent = MainFrame

local FooterCorner = Instance.new("UICorner")
FooterCorner.CornerRadius = UDim.new(0, 6)
FooterCorner.Parent = Footer

local SearchBox = Instance.new("TextBox")
SearchBox.Name = "SearchBox"
SearchBox.Size = UDim2.new(0, 180, 0, 26)
SearchBox.Position = UDim2.new(0, 6, 0.5, -13)
SearchBox.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
SearchBox.BorderSizePixel = 0
SearchBox.Font = Enum.Font.Gotham
SearchBox.TextSize = 11
SearchBox.TextColor3 = Color3.fromRGB(220, 230, 245)
SearchBox.PlaceholderColor3 = Color3.fromRGB(90, 105, 130)
SearchBox.PlaceholderText = "🔍 Filter items..."
SearchBox.Text = ""
SearchBox.ClearTextOnFocus = false
SearchBox.Parent = Footer

local SearchBoxCorner = Instance.new("UICorner")
SearchBoxCorner.CornerRadius = UDim.new(0, 4)
SearchBoxCorner.Parent = SearchBox

local BtnSourceFilter = Instance.new("TextButton")
BtnSourceFilter.Name = "BtnSourceFilter"
BtnSourceFilter.Size = UDim2.new(0, 110, 0, 26)
BtnSourceFilter.Position = UDim2.new(0, 192, 0.5, -13)
BtnSourceFilter.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
BtnSourceFilter.BorderSizePixel = 0
BtnSourceFilter.Font = Enum.Font.GothamBold
BtnSourceFilter.TextSize = 11
BtnSourceFilter.TextColor3 = Color3.fromRGB(180, 200, 230)
BtnSourceFilter.Text = "🌐 All Sources"
BtnSourceFilter.Visible = true
BtnSourceFilter.Parent = Footer

local BtnSourceCorner = Instance.new("UICorner")
BtnSourceCorner.CornerRadius = UDim.new(0, 4)
BtnSourceCorner.Parent = BtnSourceFilter

local function updateSourceFilterUI()
    if currentSourceFilter == "all" then
        BtnSourceFilter.Text = "🌐 All Sources"
        BtnSourceFilter.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
        BtnSourceFilter.TextColor3 = Color3.fromRGB(180, 200, 230)
    elseif currentSourceFilter == "executor" then
        BtnSourceFilter.Text = "⚡ Executor"
        BtnSourceFilter.BackgroundColor3 = Color3.fromRGB(45, 35, 15)
        BtnSourceFilter.TextColor3 = Color3.fromRGB(255, 200, 80)
    elseif currentSourceFilter == "game" then
        BtnSourceFilter.Text = "🎮 In-Game"
        BtnSourceFilter.BackgroundColor3 = Color3.fromRGB(20, 40, 35)
        BtnSourceFilter.TextColor3 = Color3.fromRGB(100, 230, 160)
    end
end

BtnSourceFilter.MouseButton1Click:Connect(function()
    if currentSourceFilter == "all" then
        currentSourceFilter = "executor"
    elseif currentSourceFilter == "executor" then
        currentSourceFilter = "game"
    else
        currentSourceFilter = "all"
    end
    updateSourceFilterUI()
end)

local function createFooterBtn(name, text, posX, sizeX, bgColor, fgColor)
    local btn = Instance.new("TextButton")
    btn.Name = name
    btn.Size = UDim2.new(0, sizeX, 0, 26)
    btn.Position = UDim2.new(1, posX, 0.5, -13)
    btn.BackgroundColor3 = bgColor
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.TextColor3 = fgColor
    btn.Text = text
    btn.Visible = false
    btn.Parent = Footer

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 4)
    btnCorner.Parent = btn

    return btn
end

-- Loops Footer Controls
local BtnPauseAllLoops = createFooterBtn("BtnPauseAllLoops", "⏸ Pause All Loops", -230, 125, Color3.fromRGB(28, 45, 70), Color3.fromRGB(100, 180, 255))
local BtnKillAllLoops = createFooterBtn("BtnKillAllLoops", "🛑 Kill All Loops", -100, 95, Color3.fromRGB(60, 25, 30), Color3.fromRGB(255, 120, 120))

-- Tasks Footer Controls
local BtnAdvanced = createFooterBtn("BtnAdvanced", "🌐 Native Tasks", -345, 140, Color3.fromRGB(28, 38, 55), Color3.fromRGB(120, 180, 255))
local BtnPauseAll = createFooterBtn("BtnPauseAll", "⏸ Pause All", -200, 95, Color3.fromRGB(28, 45, 70), Color3.fromRGB(100, 180, 255))
local BtnKillAll = createFooterBtn("BtnKillAll", "🛑 Kill All", -100, 92, Color3.fromRGB(60, 25, 30), Color3.fromRGB(255, 120, 120))

-- Game Tasks Footer Controls (shown in Advanced sub-mode)
local BtnRescanGame = createFooterBtn("BtnRescanGame", "🔄 Rescan", -418, 85, Color3.fromRGB(28, 45, 70), Color3.fromRGB(100, 180, 255))
local BtnIngestAllGame = createFooterBtn("BtnIngestAllGame", "📥 Ingest All", -325, 98, Color3.fromRGB(25, 50, 35), Color3.fromRGB(100, 240, 150))
local BtnEjectAllGame = createFooterBtn("BtnEjectAllGame", "📤 Eject All", -219, 95, Color3.fromRGB(60, 25, 30), Color3.fromRGB(255, 120, 120))

-- Performance Footer Controls
local BtnResetGraphs = createFooterBtn("BtnResetGraphs", "🔄 Reset History", -125, 120, Color3.fromRGB(28, 45, 70), Color3.fromRGB(100, 180, 255))

-- Startup Footer Controls
local openNewScriptModal = nil
local showDisabled = false
local BtnRescanStartup = createFooterBtn("BtnRescanStartup", "🔄 Rescan Autoexec", -160, 150, Color3.fromRGB(28, 45, 70), Color3.fromRGB(100, 180, 255))

local BtnShowDisabled = Instance.new("TextButton")
BtnShowDisabled.Name = "BtnShowDisabled"
BtnShowDisabled.Size = UDim2.new(0, 115, 0, 26)
BtnShowDisabled.Position = UDim2.new(0, 208, 0.5, -13)
BtnShowDisabled.BackgroundTransparency = 1
BtnShowDisabled.BorderSizePixel = 0
BtnShowDisabled.AutoButtonColor = false
BtnShowDisabled.Text = ""
BtnShowDisabled.Visible = false
BtnShowDisabled.Parent = Footer

local bsdLbl = Instance.new("TextLabel")
bsdLbl.Name = "Label"
bsdLbl.Size = UDim2.new(1, -24, 1, 0)
bsdLbl.Position = UDim2.new(0, 2, 0, 0)
bsdLbl.BackgroundTransparency = 1
bsdLbl.Font = Enum.Font.GothamMedium
bsdLbl.TextSize = 11
bsdLbl.TextColor3 = Color3.fromRGB(160, 175, 195)
bsdLbl.Text = "show disabled"
bsdLbl.TextXAlignment = Enum.TextXAlignment.Left
bsdLbl.Parent = BtnShowDisabled

local bsdBox = Instance.new("Frame")
bsdBox.Name = "Box"
bsdBox.Size = UDim2.new(0, 16, 0, 16)
bsdBox.Position = UDim2.new(1, -18, 0.5, -8)
bsdBox.BackgroundColor3 = showDisabled and Color3.fromRGB(28, 45, 70) or Color3.fromRGB(14, 18, 26)
bsdBox.BorderSizePixel = 0
bsdBox.Parent = BtnShowDisabled
local boxCorner = Instance.new("UICorner")
boxCorner.CornerRadius = UDim.new(0, 3)
boxCorner.Parent = bsdBox
local boxStroke = Instance.new("UIStroke")
boxStroke.Color = showDisabled and Color3.fromRGB(70, 125, 190) or Color3.fromRGB(48, 62, 85)
boxStroke.Thickness = 1
boxStroke.Parent = bsdBox

local xMark = Instance.new("Frame")
xMark.Name = "XMark"
xMark.Size = UDim2.new(1, 0, 1, 0)
xMark.BackgroundTransparency = 1
xMark.Visible = showDisabled
xMark.Parent = bsdBox

local xLine1 = Instance.new("Frame")
xLine1.Name = "Line1"
xLine1.Size = UDim2.new(0, 10, 0, 2)
xLine1.AnchorPoint = Vector2.new(0.5, 0.5)
xLine1.Position = UDim2.new(0.5, 0, 0.5, 0)
xLine1.Rotation = 45
xLine1.BackgroundColor3 = Color3.fromRGB(100, 180, 255)
xLine1.BorderSizePixel = 0
xLine1.Parent = xMark
local c1 = Instance.new("UICorner", xLine1)
c1.CornerRadius = UDim.new(0, 1)

local xLine2 = Instance.new("Frame")
xLine2.Name = "Line2"
xLine2.Size = UDim2.new(0, 10, 0, 2)
xLine2.AnchorPoint = Vector2.new(0.5, 0.5)
xLine2.Position = UDim2.new(0.5, 0, 0.5, 0)
xLine2.Rotation = -45
xLine2.BackgroundColor3 = Color3.fromRGB(100, 180, 255)
xLine2.BorderSizePixel = 0
xLine2.Parent = xMark
local c2 = Instance.new("UICorner", xLine2)
c2.CornerRadius = UDim.new(0, 1)

BtnShowDisabled.MouseButton1Click:Connect(function()
    showDisabled = not showDisabled
    xMark.Visible = showDisabled
    bsdBox.BackgroundColor3 = showDisabled and Color3.fromRGB(28, 45, 70) or Color3.fromRGB(14, 18, 26)
    boxStroke.Color = showDisabled and Color3.fromRGB(70, 125, 190) or Color3.fromRGB(48, 62, 85)
    if refreshStartupTab then
        refreshStartupTab()
    end
end)

BtnShowDisabled.MouseEnter:Connect(function()
    bsdLbl.TextColor3 = Color3.fromRGB(210, 225, 245)
    if not showDisabled then
        boxStroke.Color = Color3.fromRGB(70, 90, 120)
    end
end)
BtnShowDisabled.MouseLeave:Connect(function()
    bsdLbl.TextColor3 = Color3.fromRGB(160, 175, 195)
    if not showDisabled then
        boxStroke.Color = Color3.fromRGB(48, 62, 85)
    end
end)

local BtnAddNewStartup = Instance.new("TextButton")
BtnAddNewStartup.Name = "BtnAddNewStartup"
BtnAddNewStartup.Size = UDim2.new(0, 95, 0, 26)
BtnAddNewStartup.Position = UDim2.new(0, 332, 0.5, -13)
BtnAddNewStartup.BackgroundColor3 = Color3.fromRGB(28, 45, 70)
BtnAddNewStartup.BorderSizePixel = 0
BtnAddNewStartup.AutoButtonColor = false
BtnAddNewStartup.Font = Enum.Font.GothamBold
BtnAddNewStartup.TextSize = 11
BtnAddNewStartup.TextColor3 = Color3.fromRGB(100, 180, 255)
BtnAddNewStartup.Text = "+ Add new"
BtnAddNewStartup.Visible = false
BtnAddNewStartup.Parent = Footer
local addCorner = Instance.new("UICorner")
addCorner.CornerRadius = UDim.new(0, 4)
addCorner.Parent = BtnAddNewStartup
local addStroke = Instance.new("UIStroke")
addStroke.Color = Color3.fromRGB(45, 70, 105)
addStroke.Thickness = 1
addStroke.Parent = BtnAddNewStartup

BtnAddNewStartup.MouseEnter:Connect(function()
    BtnAddNewStartup.BackgroundColor3 = Color3.fromRGB(38, 62, 95)
    BtnAddNewStartup.TextColor3 = Color3.fromRGB(130, 205, 255)
end)
BtnAddNewStartup.MouseLeave:Connect(function()
    BtnAddNewStartup.BackgroundColor3 = Color3.fromRGB(28, 45, 70)
    BtnAddNewStartup.TextColor3 = Color3.fromRGB(100, 180, 255)
end)

BtnAddNewStartup.MouseButton1Click:Connect(function()
    if openNewScriptModal then
        openNewScriptModal()
    end
end)

-- Tasks Sub-View Toggle (Active Tasks vs Native Game Tasks Ingestion)
local function updateTasksSubView()
    if tasksSubMode == "advanced" then
        -- 1. Headers & Lists
        TableHeaderTasks.Visible = false
        ScrollListTasks.Visible = false
        TableHeaderGame.Visible = true
        ScrollListGame.Visible = true

        -- 2. Footer Buttons
        BtnSourceFilter.Visible = false
        BtnPauseAll.Visible = false
        BtnKillAll.Visible = false

        BtnRescanGame.Position = UDim2.new(1, -418, 0.5, -13)
        BtnRescanGame.Size = UDim2.new(0, 85, 0, 26)
        BtnRescanGame.Visible = true

        BtnIngestAllGame.Position = UDim2.new(1, -325, 0.5, -13)
        BtnIngestAllGame.Size = UDim2.new(0, 98, 0, 26)
        BtnIngestAllGame.Visible = true

        BtnEjectAllGame.Position = UDim2.new(1, -219, 0.5, -13)
        BtnEjectAllGame.Size = UDim2.new(0, 95, 0, 26)
        BtnEjectAllGame.Visible = true

        BtnAdvanced.Text = "◀ Active Tasks"
        BtnAdvanced.Position = UDim2.new(1, -116, 0.5, -13)
        BtnAdvanced.Size = UDim2.new(0, 108, 0, 26)
        BtnAdvanced.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
        BtnAdvanced.TextColor3 = Color3.fromRGB(140, 185, 255)
        BtnAdvanced.Visible = true

        SearchBox.Size = UDim2.new(0, 200, 0, 26)
        SearchBox.PlaceholderText = "🔍 Filter game tasks by script/line..."
        pcall(ScanGameTasks)
    else
        -- Active Tasks mode
        TableHeaderTasks.Visible = true
        ScrollListTasks.Visible = true
        TableHeaderGame.Visible = false
        ScrollListGame.Visible = false

        BtnSourceFilter.Visible = true
        BtnSourceFilter.Position = UDim2.new(0, 192, 0.5, -13)

        local count = #DiscoveredGameTaskOrder
        BtnAdvanced.Text = (count > 0) and string.format("🌐 Native Tasks (%d)", count) or "🌐 Native Tasks"
        BtnAdvanced.Position = UDim2.new(1, -345, 0.5, -13)
        BtnAdvanced.Size = UDim2.new(0, 140, 0, 26)
        BtnAdvanced.BackgroundColor3 = Color3.fromRGB(28, 38, 55)
        BtnAdvanced.TextColor3 = Color3.fromRGB(120, 180, 255)
        BtnAdvanced.Visible = true

        BtnPauseAll.Position = UDim2.new(1, -200, 0.5, -13)
        BtnPauseAll.Size = UDim2.new(0, 95, 0, 26)
        BtnPauseAll.Visible = true

        BtnKillAll.Position = UDim2.new(1, -100, 0.5, -13)
        BtnKillAll.Size = UDim2.new(0, 92, 0, 26)
        BtnKillAll.Visible = true

        BtnRescanGame.Visible = false
        BtnIngestAllGame.Visible = false
        BtnEjectAllGame.Visible = false

        SearchBox.Size = UDim2.new(0, 180, 0, 26)
        SearchBox.PlaceholderText = "🔍 Filter tasks by name..."
    end
end

BtnAdvanced.MouseButton1Click:Connect(function()
    if tasksSubMode == "active" then
        tasksSubMode = "advanced"
    else
        tasksSubMode = "active"
    end
    updateTasksSubView()
end)

-- Tab Switching Function
local function setTab(tabName)
    currentTab = tabName
    -- 1. Style Tab buttons
    TabTasksBtn.BackgroundColor3 = if tabName == "Tasks" then Color3.fromRGB(35, 45, 65) else Color3.fromRGB(20, 24, 33)
    TabTasksBtn.TextColor3 = if tabName == "Tasks" then Color3.fromRGB(80, 200, 255) else Color3.fromRGB(130, 145, 170)

    TabLoopsBtn.BackgroundColor3 = if tabName == "Loops" then Color3.fromRGB(35, 45, 65) else Color3.fromRGB(20, 24, 33)
    TabLoopsBtn.TextColor3 = if tabName == "Loops" then Color3.fromRGB(80, 200, 255) else Color3.fromRGB(130, 145, 170)

    TabPerfBtn.BackgroundColor3 = if tabName == "Performance" then Color3.fromRGB(35, 45, 65) else Color3.fromRGB(20, 24, 33)
    TabPerfBtn.TextColor3 = if tabName == "Performance" then Color3.fromRGB(80, 200, 255) else Color3.fromRGB(130, 145, 170)

    TabStartupBtn.BackgroundColor3 = if tabName == "Startup" then Color3.fromRGB(35, 45, 65) else Color3.fromRGB(20, 24, 33)
    TabStartupBtn.TextColor3 = if tabName == "Startup" then Color3.fromRGB(80, 200, 255) else Color3.fromRGB(130, 145, 170)

    -- 2. Toggle Header & List visibility
    TableHeaderLoops.Visible = (tabName == "Loops")
    ScrollListLoops.Visible = (tabName == "Loops")

    PanelPerf.Visible = (tabName == "Performance")

    TableHeaderStartup.Visible = (tabName == "Startup")
    ScrollListStartup.Visible = (tabName == "Startup")

    -- 3. Toggle Footer Buttons
    BtnPauseAllLoops.Visible = (tabName == "Loops")
    BtnKillAllLoops.Visible = (tabName == "Loops")

    BtnResetGraphs.Visible = (tabName == "Performance")
    BtnRescanStartup.Visible = (tabName == "Startup")
    BtnShowDisabled.Visible = (tabName == "Startup")
    BtnAddNewStartup.Visible = (tabName == "Startup")

    if tabName == "Tasks" then
        updateTasksSubView()
    else
        TableHeaderTasks.Visible = false
        ScrollListTasks.Visible = false
        TableHeaderGame.Visible = false
        ScrollListGame.Visible = false
        BtnAdvanced.Visible = false
        BtnPauseAll.Visible = false
        BtnKillAll.Visible = false
        BtnRescanGame.Visible = false
        BtnIngestAllGame.Visible = false
        BtnEjectAllGame.Visible = false

        if tabName == "Loops" then
            BtnSourceFilter.Visible = true
            BtnSourceFilter.Position = UDim2.new(0, 192, 0.5, -13)
            SearchBox.Visible = true
            SearchBox.Size = UDim2.new(0, 180, 0, 26)
            SearchBox.PlaceholderText = "🔍 Filter loops by caller/location..."
        elseif tabName == "Performance" then
            BtnSourceFilter.Visible = false
            SearchBox.Visible = false
        elseif tabName == "Startup" then
            BtnSourceFilter.Visible = false
            SearchBox.Visible = true
            SearchBox.Size = UDim2.new(0, 190, 0, 26)
            SearchBox.PlaceholderText = "🔍 Filter startup scripts..."
            if refreshStartupTab then
                refreshStartupTab()
            end
        end
    end
end

TabTasksBtn.MouseButton1Click:Connect(function() setTab("Tasks") end)
TabLoopsBtn.MouseButton1Click:Connect(function() setTab("Loops") end)
TabPerfBtn.MouseButton1Click:Connect(function() setTab("Performance") end)
TabStartupBtn.MouseButton1Click:Connect(function() setTab("Startup") end)
setTab("Tasks")

-- ==============================================================================
-- ROW RENDERING ENGINES & WINDOWS TASK MANAGER COLLAPSIBLE SECTIONS
-- ==============================================================================


local TaskDrag = {
    pending = nil,
    isDragging = false,
    active = nil,
    targetIndex = nil,
    indicator = Instance.new("Frame"),
}
TaskDrag.indicator.Name = "TaskDropIndicator"
TaskDrag.indicator.Size = UDim2.new(1, -8, 0, 3)
TaskDrag.indicator.BackgroundColor3 = Color3.fromRGB(60, 170, 255)
TaskDrag.indicator.BorderSizePixel = 0
TaskDrag.indicator.Visible = false
TaskDrag.indicator.ZIndex = 120
TaskDrag.indicator.Parent = ScrollListTasks
local taskIndCorner = Instance.new("UICorner")
taskIndCorner.CornerRadius = UDim.new(1, 0)
taskIndCorner.Parent = TaskDrag.indicator

local LoopDrag = {
    pending = nil,
    isDragging = false,
    active = nil,
    targetIndex = nil,
    indicator = Instance.new("Frame"),
}
LoopDrag.indicator.Name = "LoopDropIndicator"
LoopDrag.indicator.Size = UDim2.new(1, -8, 0, 3)
LoopDrag.indicator.BackgroundColor3 = Color3.fromRGB(60, 170, 255)
LoopDrag.indicator.BorderSizePixel = 0
LoopDrag.indicator.Visible = false
LoopDrag.indicator.ZIndex = 120
LoopDrag.indicator.Parent = ScrollListLoops
local loopIndCorner = Instance.new("UICorner")
loopIndCorner.CornerRadius = UDim.new(1, 0)
loopIndCorner.Parent = LoopDrag.indicator

local PRIORITY_COLORS = {
    High = Color3.fromRGB(50, 130, 240),
    Medium = Color3.fromRGB(40, 190, 210),
    Low = Color3.fromRGB(230, 160, 40),
    Eco = Color3.fromRGB(240, 100, 60),
    Idle = Color3.fromRGB(160, 70, 220),
}
local PRIORITY_CYCLE = { High = "Medium", Medium = "Low", Low = "Eco", Eco = "Idle", Idle = "High" }

local function getHzColor(hz, maxHz)
    maxHz = maxHz or math.max(60, measuredFps or 60)
    if not hz then return Color3.fromRGB(50, 130, 240) end
    local ratio = hz / maxHz
    if ratio >= 0.75 then return Color3.fromRGB(50, 130, 240)
    elseif ratio >= 0.40 then return Color3.fromRGB(40, 190, 210)
    elseif ratio >= 0.15 then return Color3.fromRGB(230, 160, 40)
    elseif ratio >= 0.05 then return Color3.fromRGB(240, 100, 60)
    else return Color3.fromRGB(160, 70, 220) end
end

-- Row 1: Task Row
local function renderTaskRow(taskObj, idx)
    local row = cachedTaskRows[taskObj.id]
    if not row then
        row = Instance.new("Frame")
        row.Name = taskObj.id
        row.Size = UDim2.new(1, 0, 0, 32)
        row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)
        row.BorderSizePixel = 0
        row.LayoutOrder = idx * 10
        row.Active = true
        row.Parent = ScrollListTasks

        local rCorner = Instance.new("UICorner")
        rCorner.CornerRadius = UDim.new(0, 4)
        rCorner.Parent = row

        local isPriSort = TableSortState.Tasks and TableSortState.Tasks.colId == "Priority"
        local gripLbl = Instance.new("TextLabel")
        gripLbl.Name = "GripLbl"
        gripLbl.Size = UDim2.new(0, 12, 0, 16)
        gripLbl.Position = UDim2.new(0, 4, 0.5, -8)
        gripLbl.BackgroundTransparency = 1
        gripLbl.Font = Enum.Font.GothamBold
        gripLbl.TextSize = 12
        gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
        gripLbl.Text = ICONS.GRIP
        gripLbl.Parent = row

        local dot = Instance.new("Frame")
        dot.Name = "Dot"
        dot.Size = UDim2.new(0, 8, 0, 8)
        dot.Position = UDim2.new(0, 20, 0.5, -4)
        dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120)
        dot.BorderSizePixel = 0
        dot.Parent = row
        local dotCorner = Instance.new("UICorner")
        dotCorner.CornerRadius = UDim.new(1, 0)
        dotCorner.Parent = dot

        local priLbl = Instance.new("TextButton")
        priLbl.Name = "PriLbl"
        priLbl.Size = UDim2.new(0, 28, 0, 18)
        priLbl.Position = UDim2.new(0, 32, 0.5, -9)
        priLbl.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
        priLbl.BorderSizePixel = 0
        priLbl.AutoButtonColor = false
        priLbl.Font = Enum.Font.GothamBold
        priLbl.TextSize = 10
        priLbl.TextColor3 = Color3.fromRGB(210, 230, 255)
        priLbl.TextXAlignment = Enum.TextXAlignment.Center
        priLbl.Text = tostring(taskObj.priority or taskObj.basePriority or 50)
        priLbl.Parent = row
        local priCorner = Instance.new("UICorner")
        priCorner.CornerRadius = UDim.new(0, 3)
        priCorner.Parent = priLbl
        local priStroke = Instance.new("UIStroke")
        priStroke.Thickness = 1
        priStroke.Color = Color3.fromRGB(45, 60, 85)
        priStroke.Parent = priLbl

        priLbl.MouseEnter:Connect(function()
            priLbl.BackgroundColor3 = Color3.fromRGB(38, 52, 75)
            priStroke.Color = Color3.fromRGB(80, 130, 200)
        end)
        priLbl.MouseLeave:Connect(function()
            priLbl.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
            priStroke.Color = Color3.fromRGB(45, 60, 85)
        end)
        priLbl.MouseButton1Click:Connect(function()
            if openPriorityEditModal then
                openPriorityEditModal("Task", taskObj, taskObj.priority or taskObj.basePriority or 50)
            end
        end)

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Name = "NameLbl"
        nameLbl.Size = UDim2.new(0.32, 0, 1, 0)
        nameLbl.Position = UDim2.new(0, 34, 0, 0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamMedium
        nameLbl.TextSize = 11
        nameLbl.TextColor3 = Color3.fromRGB(225, 235, 250)
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Parent = row

        local eventLbl = Instance.new("TextLabel")
        eventLbl.Name = "EventLbl"
        eventLbl.Size = UDim2.new(0.13, 0, 1, 0)
        eventLbl.Position = UDim2.new(0.42, 0, 0, 0)
        eventLbl.BackgroundTransparency = 1
        eventLbl.Font = Enum.Font.Gotham
        eventLbl.TextSize = 10
        eventLbl.TextColor3 = Color3.fromRGB(140, 155, 180)
        eventLbl.TextXAlignment = Enum.TextXAlignment.Left
        eventLbl.Parent = row

        local priBtn = Instance.new("TextButton")
        priBtn.Name = "PriBtn"
        priBtn.Size = UDim2.new(0, 64, 0, 20)
        priBtn.Position = UDim2.new(0.61, -32, 0.5, -10)
        priBtn.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
        priBtn.BorderSizePixel = 0
        priBtn.Text = ""
        priBtn.AutoButtonColor = false
        priBtn.Parent = row
        local priCorner = Instance.new("UICorner")
        priCorner.CornerRadius = UDim.new(0, 4)
        priCorner.Parent = priBtn

        local sliderFill = Instance.new("Frame")
        sliderFill.Name = "SliderFill"
        sliderFill.Size = UDim2.new(1, 0, 1, 0)
        sliderFill.Position = UDim2.new(0, 0, 0, 0)
        sliderFill.BackgroundColor3 = Color3.fromRGB(50, 130, 240)
        sliderFill.BorderSizePixel = 0
        sliderFill.Parent = priBtn
        local fillCorner = Instance.new("UICorner")
        fillCorner.CornerRadius = UDim.new(0, 4)
        fillCorner.Parent = sliderFill

        local sliderLbl = Instance.new("TextLabel")
        sliderLbl.Name = "SliderLbl"
        sliderLbl.Size = UDim2.new(1, 0, 1, 0)
        sliderLbl.BackgroundTransparency = 1
        sliderLbl.Font = Enum.Font.GothamBold
        sliderLbl.TextSize = 10
        sliderLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
        sliderLbl.Text = "60Hz"
        sliderLbl.ZIndex = 3
        sliderLbl.Parent = priBtn

        local lockBtn = Instance.new("TextButton")
        lockBtn.Name = "LockBtn"
        lockBtn.Size = UDim2.new(0, 24, 0, 20)
        lockBtn.Position = UDim2.new(0.695, -12, 0.5, -10)
        lockBtn.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
        lockBtn.BorderSizePixel = 0
        lockBtn.Font = Enum.Font.GothamBold
        lockBtn.TextSize = 10
        lockBtn.TextColor3 = Color3.fromRGB(120, 135, 160)
        lockBtn.Text = ICONS.LOCK_OPEN
        lockBtn.Parent = row
        local lockCorner = Instance.new("UICorner")
        lockCorner.CornerRadius = UDim.new(0, 4)
        lockCorner.Parent = lockBtn

        local cpuLbl = Instance.new("TextLabel")
        cpuLbl.Name = "CpuLbl"
        cpuLbl.Size = UDim2.new(0.11, 0, 1, 0)
        cpuLbl.Position = UDim2.new(0.73, 0, 0, 0)
        cpuLbl.BackgroundTransparency = 1
        cpuLbl.Font = Enum.Font.GothamBold
        cpuLbl.TextSize = 11
        cpuLbl.TextColor3 = Color3.fromRGB(100, 220, 140)
        cpuLbl.TextXAlignment = Enum.TextXAlignment.Right
        cpuLbl.Parent = row

        local actions = Instance.new("Frame")
        actions.Name = "Actions"
        actions.Size = UDim2.new(0.12, 0, 1, 0)
        actions.Position = UDim2.new(0.86, 0, 0, 0)
        actions.BackgroundTransparency = 1
        actions.Parent = row
        local actionsLayout = Instance.new("UIListLayout")
        actionsLayout.FillDirection = Enum.FillDirection.Horizontal
        actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        actionsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        actionsLayout.Padding = UDim.new(0, 4)
        actionsLayout.Parent = actions

        local pauseBtn = Instance.new("TextButton")
        pauseBtn.Name = "PauseBtn"
        pauseBtn.Size = UDim2.new(0, 24, 0, 20)
        pauseBtn.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
        pauseBtn.BorderSizePixel = 0
        pauseBtn.Font = Enum.Font.GothamBold
        pauseBtn.TextSize = 10
        pauseBtn.TextColor3 = Color3.fromRGB(200, 215, 240)
        pauseBtn.Text = ICONS.PAUSE
        pauseBtn.Parent = actions
        local pauseCorner = Instance.new("UICorner")
        pauseCorner.CornerRadius = UDim.new(0, 4)
        pauseCorner.Parent = pauseBtn

        local killBtn = Instance.new("TextButton")
        killBtn.Name = "KillBtn"
        killBtn.Size = UDim2.new(0, 24, 0, 20)
        killBtn.BackgroundColor3 = Color3.fromRGB(60, 25, 30)
        killBtn.BorderSizePixel = 0
        killBtn.Font = Enum.Font.GothamBold
        killBtn.TextSize = 10
        killBtn.TextColor3 = Color3.fromRGB(255, 140, 140)
        killBtn.Text = ICONS.KILL
        killBtn.Parent = actions
        local killCorner = Instance.new("UICorner")
        killCorner.CornerRadius = UDim.new(0, 4)
        killCorner.Parent = killBtn

        local isDragging = false
        local function updateSlider(posX)
            local barX = priBtn.AbsolutePosition.X
            local barW = math.max(1, priBtn.AbsoluteSize.X)
            local rel = math.clamp((posX - barX) / barW, 0.01, 1.0)
            local maxHz = math.max(60, measuredFps or 60)
            local targetHz
            if rel >= 0.95 then
                targetHz = maxHz
            else
                targetHz = math.clamp(math.round(rel * maxHz), 1, maxHz)
            end

            -- Instantaneous visual feedback while dragging
            local sliderFill = priBtn:FindFirstChild("SliderFill")
            local sliderLbl = priBtn:FindFirstChild("SliderLbl")
            if sliderFill then
                sliderFill.Size = UDim2.new(rel, 0, 1, 0)
                sliderFill.BackgroundColor3 = getHzColor(targetHz, maxHz)
            end
            if sliderLbl then
                local text = (rel >= 0.95) and string.format("%dHz", maxHz) or string.format("%dHz", targetHz)
                if taskObj.isAsync then text = ICONS.BOLT .. " " .. text end
                sliderLbl.Text = text
            end

            if getgenv().SetSchedulerTaskHz then
                getgenv().SetSchedulerTaskHz(taskObj.id, targetHz, rel)
            elseif getgenv().SetSchedulerTaskPriority then
                getgenv().SetSchedulerTaskPriority(taskObj.id, targetHz, rel)
            end
        end

        local dragMoveConn, dragEndConn
        local function stopDrag()
            isDragging = false
            taskRowDragging[taskObj.id] = false
            if dragMoveConn then dragMoveConn:Disconnect(); dragMoveConn = nil end
            if dragEndConn then dragEndConn:Disconnect(); dragEndConn = nil end
        end

        row.Destroying:Connect(stopDrag)

        priBtn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isDragging = true
                taskRowDragging[taskObj.id] = true
                updateSlider(input.Position.X)

                if dragMoveConn then dragMoveConn:Disconnect() end
                if dragEndConn then dragEndConn:Disconnect() end

                dragMoveConn = UserInputService.InputChanged:Connect(function(moveInput)
                    if isDragging and (moveInput.UserInputType == Enum.UserInputType.MouseMovement or moveInput.UserInputType == Enum.UserInputType.Touch) then
                        updateSlider(moveInput.Position.X)
                    end
                end)
                dragEndConn = UserInputService.InputEnded:Connect(function(endInput)
                    if endInput.UserInputType == Enum.UserInputType.MouseButton1 or endInput.UserInputType == Enum.UserInputType.Touch then
                        stopDrag()
                    end
                end)
            end
        end)

        lockBtn.MouseButton1Click:Connect(function()
            local willLock = not (lockBtn.Text == ICONS.LOCK_CLOSED)
            if getgenv().SetSchedulerTaskLocked then
                getgenv().SetSchedulerTaskLocked(taskObj.id, willLock)
            end
        end)

        pauseBtn.MouseButton1Click:Connect(function()
            if getgenv().SetSchedulerTaskPaused then
                local willPause = (pauseBtn.Text == ICONS.PAUSE)
                getgenv().SetSchedulerTaskPaused(taskObj.id, willPause)
            end
        end)

        killBtn.MouseButton1Click:Connect(function()
            if getgenv().KillSchedulerTask then
                getgenv().KillSchedulerTask(taskObj.id)
            end
        end)

        row.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                if isInsideGui(priBtn, input.Position) or isInsideGui(lockBtn, input.Position) or isInsideGui(actions, input.Position) or isInsideGui(priLbl, input.Position) then
                    return
                end
                TaskDrag.pending = {
                    task = taskObj,
                    row = row,
                    startPos = input.Position,
                    startIdx = idx,
                }
            end
        end)

        cachedTaskRows[taskObj.id] = row
        applyRowColumnLayout(row, "Tasks")
    end

    row.LayoutOrder = idx * 10
    row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)

    -- Update row content
    local dot = row:FindFirstChild("Dot")
    local gripLbl = row:FindFirstChild("GripLbl")
    if gripLbl then
        local isPriSort = TableSortState.Tasks and TableSortState.Tasks.colId == "Priority"
        gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
    end
    local priLbl = row:FindFirstChild("PriLbl")
    local priVal = taskObj.priority or taskObj.basePriority or 50
    if priLbl then
        priLbl.Text = tostring(priVal)
    end
    local nameLbl = row:FindFirstChild("NameLbl")
    local eventLbl = row:FindFirstChild("EventLbl")
    local priBtn = row:FindFirstChild("PriBtn")
    local lockBtn = row:FindFirstChild("LockBtn")
    local cpuLbl = row:FindFirstChild("CpuLbl")
    local actions = row:FindFirstChild("Actions")
    local pauseBtn = actions and actions:FindFirstChild("PauseBtn")

    if taskObj.paused then
        if dot then dot.BackgroundColor3 = Color3.fromRGB(120, 130, 150) end
        if pauseBtn then pauseBtn.Text = ICONS.PLAY; pauseBtn.TextColor3 = Color3.fromRGB(100, 220, 140) end
    elseif taskObj.errorCount and taskObj.errorCount > 0 then
        if dot then dot.BackgroundColor3 = Color3.fromRGB(255, 75, 75) end
        if pauseBtn then pauseBtn.Text = ICONS.PAUSE; pauseBtn.TextColor3 = Color3.fromRGB(200, 215, 240) end
    elseif taskObj.autoThrottled and not taskObj.locked then
        if dot then dot.BackgroundColor3 = Color3.fromRGB(255, 180, 50) end
        if pauseBtn then pauseBtn.Text = ICONS.PAUSE; pauseBtn.TextColor3 = Color3.fromRGB(200, 215, 240) end
    else
        if dot then dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120) end
        if pauseBtn then pauseBtn.Text = ICONS.PAUSE; pauseBtn.TextColor3 = Color3.fromRGB(200, 215, 240) end
    end

    if lockBtn then
        if taskObj.locked then
            lockBtn.Text = ICONS.LOCK_CLOSED
            lockBtn.BackgroundColor3 = Color3.fromRGB(60, 45, 15)
            lockBtn.TextColor3 = Color3.fromRGB(255, 200, 50)
        else
            lockBtn.Text = ICONS.LOCK_OPEN
            lockBtn.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
            lockBtn.TextColor3 = Color3.fromRGB(120, 135, 160)
        end
    end

    if nameLbl then
        local displayName = tostring(taskObj.name or taskObj.id)
        if taskObj.errorCount and taskObj.errorCount > 0 then
            displayName = string.format("%s (ERR: %d)", displayName, taskObj.errorCount)
        end
        local badge = (taskObj.isExecutor ~= false) and (ICONS.BOLT .. " ") or (ICONS.GAME .. " ")
        nameLbl.Text = badge .. displayName
    end
    if eventLbl then
        local ev = tostring(taskObj.event or "Heartbeat")
        eventLbl.Text = ev
        if ev == "SuperStep" then
            eventLbl.TextColor3 = Color3.fromRGB(190, 110, 255)
            eventLbl.Font = Enum.Font.GothamBold
        elseif ev == "Heartbeat" then
            eventLbl.TextColor3 = Color3.fromRGB(130, 160, 200)
            eventLbl.Font = Enum.Font.Gotham
        elseif ev == "Stepped" then
            eventLbl.TextColor3 = Color3.fromRGB(100, 190, 210)
            eventLbl.Font = Enum.Font.Gotham
        elseif ev == "RenderStepped" then
            eventLbl.TextColor3 = Color3.fromRGB(240, 170, 80)
            eventLbl.Font = Enum.Font.Gotham
        else
            eventLbl.TextColor3 = Color3.fromRGB(140, 155, 180)
            eventLbl.Font = Enum.Font.Gotham
        end
    end
    if priBtn and not taskRowDragging[taskObj.id] then
        local sliderFill = priBtn:FindFirstChild("SliderFill")
        local sliderLbl = priBtn:FindFirstChild("SliderLbl")
        local maxHz = math.max(60, measuredFps or 60)
        local effHz = taskObj.effectiveHz or taskObj.targetHz or maxHz
        local fillRatio = math.clamp(effHz / maxHz, 0.08, 1.0)
        local barColor = getHzColor(effHz, maxHz)

        if sliderFill then
            sliderFill.Size = UDim2.new(fillRatio, 0, 1, 0)
            sliderFill.BackgroundColor3 = barColor
        end
        if sliderLbl then
            local text
            if effHz >= (maxHz - 0.5) then
                text = string.format("%dHz", maxHz)
            elseif effHz >= 1 then
                text = string.format("%dHz%s", math.round(effHz), taskObj.autoThrottled and "*" or "")
            else
                text = string.format("%.1fHz%s", effHz, taskObj.autoThrottled and "*" or "")
            end
            if taskObj.isAsync then
                text = ICONS.BOLT .. text
            end
            sliderLbl.Text = text
        end
    end
    if cpuLbl then
        local ms = taskObj.lastTimeMs or 0
        cpuLbl.Text = string.format("%.2fms", ms)
        if ms > 2.0 then cpuLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
        elseif ms > 0.8 then cpuLbl.TextColor3 = Color3.fromRGB(240, 180, 50)
        else cpuLbl.TextColor3 = Color3.fromRGB(100, 220, 140) end
    end

    row.Visible = true
    return row
end

-- Row 3: Startup Script Row & Drag-and-Drop Engine
local STAGE_COLORS = {
    Kernel = Color3.fromRGB(160, 70, 220),
    PreInit = Color3.fromRGB(240, 100, 60),
    GameLoaded = Color3.fromRGB(50, 130, 240),
    CharacterReady = Color3.fromRGB(40, 190, 210),
    Deferred = Color3.fromRGB(230, 160, 40),

    kernel = Color3.fromRGB(160, 70, 220),
    preinit = Color3.fromRGB(240, 100, 60),
    nodelay = Color3.fromRGB(240, 100, 60),
    gameloaded = Color3.fromRGB(50, 130, 240),
    characterready = Color3.fromRGB(40, 190, 210),
    characterloaded = Color3.fromRGB(40, 190, 210),
    deferred = Color3.fromRGB(230, 160, 40),
}

local startupBadgeHovered = {}
local currentStartupBoundaries = {}

local function getStageBoundaryInfo(allScripts)
    local stageGroups = {}
    for _, s in ipairs(allScripts) do
        local st = s.stage or "GameLoaded"
        if not stageGroups[st] then
            stageGroups[st] = {}
        end
        table.insert(stageGroups[st], s)
    end

    local boundaryInfo = {}

    for st, list in pairs(stageGroups) do
        local count = #list
        for i, s in ipairs(list) do
            local fileKey = s.file:lower()
            local isKernelManager = (st == "Kernel" and (fileKey:find("kerneltaskmanager") ~= nil or count == 1))
            local isFirst = (i == 1)
            local isLast = (i == count)

            local info = {
                isFirst = isFirst,
                isLast = isLast,
                stage = st,
                canToggle = false,
                toggleTarget = nil,
                targetPosition = nil,
            }

            if not isKernelManager then
                if st == "PreInit" then
                    if isFirst then
                        info.canToggle = true
                        info.toggleTarget = "Kernel"
                        info.targetPosition = "BOTTOM"
                    elseif isLast then
                        info.canToggle = true
                        info.toggleTarget = "GameLoaded"
                        info.targetPosition = "TOP"
                    end
                elseif st == "GameLoaded" then
                    if isFirst then
                        info.canToggle = true
                        info.toggleTarget = "PreInit"
                        info.targetPosition = "BOTTOM"
                    elseif isLast then
                        info.canToggle = true
                        info.toggleTarget = "PreInit"
                        info.targetPosition = "BOTTOM"
                    end
                elseif st == "Kernel" then
                    if isLast and not isKernelManager then
                        info.canToggle = true
                        info.toggleTarget = "PreInit"
                        info.targetPosition = "TOP"
                    end
                end
            end

            boundaryInfo[fileKey] = info
        end
    end

    return boundaryInfo
end

-- Startup Drag & Drop Visual Indicators
local StartupDropIndicator = Instance.new("Frame")
StartupDropIndicator.Name = "StartupDropIndicator"
StartupDropIndicator.Size = UDim2.new(1, -8, 0, 3)
StartupDropIndicator.BackgroundColor3 = Color3.fromRGB(60, 170, 255)
StartupDropIndicator.BorderSizePixel = 0
StartupDropIndicator.Visible = false
StartupDropIndicator.ZIndex = 120
StartupDropIndicator.Parent = ScrollListStartup

local indCorner = Instance.new("UICorner")
indCorner.CornerRadius = UDim.new(1, 0)
indCorner.Parent = StartupDropIndicator

local StartupDragGhost = Instance.new("Frame")
StartupDragGhost.Name = "StartupDragGhost"
StartupDragGhost.Size = UDim2.new(0, 350, 0, 32)
StartupDragGhost.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
StartupDragGhost.BackgroundTransparency = 0.2
StartupDragGhost.BorderSizePixel = 0
StartupDragGhost.Visible = false
StartupDragGhost.ZIndex = 250
StartupDragGhost.Parent = MainFrame

local ghostCorner = Instance.new("UICorner")
ghostCorner.CornerRadius = UDim.new(0, 4)
ghostCorner.Parent = StartupDragGhost

local ghostStroke = Instance.new("UIStroke")
ghostStroke.Thickness = 1.5
ghostStroke.Color = Color3.fromRGB(70, 160, 255)
ghostStroke.Transparency = 0.3
ghostStroke.Parent = StartupDragGhost

local ghostDot = Instance.new("Frame")
ghostDot.Name = "GhostDot"
ghostDot.Size = UDim2.new(0, 8, 0, 8)
ghostDot.Position = UDim2.new(0, 12, 0.5, -4)
ghostDot.BackgroundColor3 = Color3.fromRGB(50, 220, 120)
ghostDot.BorderSizePixel = 0
ghostDot.ZIndex = 251
ghostDot.Parent = StartupDragGhost
local gdCorner = Instance.new("UICorner")
gdCorner.CornerRadius = UDim.new(1, 0)
gdCorner.Parent = ghostDot

local ghostName = Instance.new("TextLabel")
ghostName.Name = "GhostName"
ghostName.Size = UDim2.new(0.48, 0, 1, 0)
ghostName.Position = UDim2.new(0, 28, 0, 0)
ghostName.BackgroundTransparency = 1
ghostName.Font = Enum.Font.GothamMedium
ghostName.TextSize = 11
ghostName.TextColor3 = Color3.fromRGB(240, 245, 255)
ghostName.TextXAlignment = Enum.TextXAlignment.Left
ghostName.TextTruncate = Enum.TextTruncate.AtEnd
ghostName.ZIndex = 251
ghostName.Parent = StartupDragGhost

local ghostBadge = Instance.new("TextLabel")
ghostBadge.Name = "GhostBadge"
ghostBadge.Size = UDim2.new(0, 75, 0, 18)
ghostBadge.Position = UDim2.new(1, -125, 0.5, -9)
ghostBadge.BackgroundColor3 = Color3.fromRGB(25, 35, 55)
ghostBadge.BorderSizePixel = 0
ghostBadge.Font = Enum.Font.GothamBold
ghostBadge.TextSize = 9
ghostBadge.TextColor3 = Color3.fromRGB(100, 180, 255)
ghostBadge.ZIndex = 251
ghostBadge.Parent = StartupDragGhost
local gbCorner = Instance.new("UICorner")
gbCorner.CornerRadius = UDim.new(0, 3)
gbCorner.Parent = ghostBadge

local ghostGrip = Instance.new("TextLabel")
ghostGrip.Name = "GhostGrip"
ghostGrip.Size = UDim2.new(0, 30, 1, 0)
ghostGrip.Position = UDim2.new(1, -38, 0, 0)
ghostGrip.BackgroundTransparency = 1
ghostGrip.Font = Enum.Font.GothamBold
ghostGrip.TextSize = 12
ghostGrip.TextColor3 = Color3.fromRGB(80, 170, 255)
ghostGrip.Text = "↕"
ghostGrip.ZIndex = 251
ghostGrip.Parent = StartupDragGhost

local pendingStartupDrag = nil
local isDraggingStartupRow = false
local activeStartupDrag = nil
local targetDropIndex = nil
local targetDropStage = nil

-- ==============================================================================
-- STARTUP ACCORDION CONTEXT MENU & IN-GAME CODE EDITOR
-- ==============================================================================

local openCodeEditor = nil
local TextService = game:GetService("TextService")


do
-- In-Game Code Editor Modal
local Ed = {}

local function edCorner(parent, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 4)
    c.Parent = parent
    return c
end

local function edStroke(parent, col, thick)
    local s = Instance.new("UIStroke")
    s.Color = col or Color3.fromRGB(55, 68, 95)
    s.Thickness = thick or 1
    s.Parent = parent
    return s
end

Ed.Modal = Instance.new("Frame")
Ed.Modal.Name = "CodeEditorModal"
Ed.Modal.Size = UDim2.new(1, -24, 1, -24)
Ed.Modal.Position = UDim2.new(0, 12, 0, 12)
Ed.Modal.BackgroundColor3 = Color3.fromRGB(15, 18, 26)
Ed.Modal.BorderSizePixel = 0
Ed.Modal.ZIndex = 500
Ed.Modal.Visible = false
Ed.Modal.Parent = MainFrame
edCorner(Ed.Modal, 8)
edStroke(Ed.Modal, Color3.fromRGB(55, 68, 95), 1.5)

-- Header bar (height 36)
Ed.Header = Instance.new("Frame")
Ed.Header.Name = "Header"
Ed.Header.Size = UDim2.new(1, 0, 0, 36)
Ed.Header.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
Ed.Header.BorderSizePixel = 0
Ed.Header.ZIndex = 501
Ed.Header.Parent = Ed.Modal
edCorner(Ed.Header, 8)

Ed.Title = Instance.new("TextLabel")
Ed.Title.Name = "Title"
Ed.Title.Size = UDim2.new(0.55, 0, 1, 0)
Ed.Title.Position = UDim2.new(0, 12, 0, 0)
Ed.Title.BackgroundTransparency = 1
Ed.Title.Font = Enum.Font.GothamBold
Ed.Title.TextSize = 11
Ed.Title.TextColor3 = Color3.fromRGB(240, 245, 255)
Ed.Title.TextXAlignment = Enum.TextXAlignment.Left
Ed.Title.TextTruncate = Enum.TextTruncate.AtEnd
Ed.Title.ZIndex = 502
Ed.Title.Parent = Ed.Header

Ed.SaveBtn = Instance.new("TextButton")
Ed.SaveBtn.Name = "SaveBtn"
Ed.SaveBtn.Size = UDim2.new(0, 85, 0, 24)
Ed.SaveBtn.Position = UDim2.new(1, -225, 0.5, -12)
Ed.SaveBtn.BackgroundColor3 = Color3.fromRGB(30, 85, 50)
Ed.SaveBtn.AutoButtonColor = false
Ed.SaveBtn.Font = Enum.Font.GothamBold
Ed.SaveBtn.TextSize = 10
Ed.SaveBtn.TextColor3 = Color3.fromRGB(120, 250, 160)
Ed.SaveBtn.Text = "💾 Save"
Ed.SaveBtn.ZIndex = 502
Ed.SaveBtn.Parent = Ed.Header
edCorner(Ed.SaveBtn, 4)

Ed.RunBtn = Instance.new("TextButton")
Ed.RunBtn.Name = "RunBtn"
Ed.RunBtn.Size = UDim2.new(0, 80, 0, 24)
Ed.RunBtn.Position = UDim2.new(1, -132, 0.5, -12)
Ed.RunBtn.BackgroundColor3 = Color3.fromRGB(35, 65, 115)
Ed.RunBtn.AutoButtonColor = false
Ed.RunBtn.Font = Enum.Font.GothamBold
Ed.RunBtn.TextSize = 10
Ed.RunBtn.TextColor3 = Color3.fromRGB(120, 200, 255)
Ed.RunBtn.Text = "▶ Run"
Ed.RunBtn.ZIndex = 502
Ed.RunBtn.Parent = Ed.Header
edCorner(Ed.RunBtn, 4)

Ed.CloseBtn = Instance.new("TextButton")
Ed.CloseBtn.Name = "CloseBtn"
Ed.CloseBtn.Size = UDim2.new(0, 36, 0, 24)
Ed.CloseBtn.Position = UDim2.new(1, -44, 0.5, -12)
Ed.CloseBtn.BackgroundColor3 = Color3.fromRGB(55, 25, 30)
Ed.CloseBtn.AutoButtonColor = false
Ed.CloseBtn.Font = Enum.Font.GothamBold
Ed.CloseBtn.TextSize = 13
Ed.CloseBtn.TextColor3 = Color3.fromRGB(255, 130, 130)
Ed.CloseBtn.Text = "X"
Ed.CloseBtn.Modal = true
Ed.CloseBtn.ZIndex = 502
Ed.CloseBtn.Parent = Ed.Header
edCorner(Ed.CloseBtn, 4)

Ed.CloseBtn.MouseEnter:Connect(function()
    Ed.CloseBtn.BackgroundColor3 = Color3.fromRGB(75, 30, 35)
    Ed.CloseBtn.TextColor3 = Color3.fromRGB(255, 170, 170)
end)
Ed.CloseBtn.MouseLeave:Connect(function()
    Ed.CloseBtn.BackgroundColor3 = Color3.fromRGB(55, 25, 30)
    Ed.CloseBtn.TextColor3 = Color3.fromRGB(255, 130, 130)
end)

-- Code Editing Container (ScrollingFrame + Viewport-Virtualized Syntax Highlighter + TextBox)
local LINE_HEIGHT = 11
local CHAR_WIDTH = 6
local PADDING_LEFT = 8
local PADDING_TOP = 6

Ed.Doc = {
    Lines = {},
    TotalLines = 0,
    MaxLineLen = 0,
    TotalChars = 0,
}
Ed.Script = nil
Ed.HlThread = nil
Ed.BlinkThread = nil
Ed.CaretSolid = true
Ed.EditStartLine = 1
Ed.EditEndLine = 1
Ed.IsLargeDoc = false
Ed.IsUpdatingText = false

Ed.Scroll = Instance.new("ScrollingFrame")
Ed.Scroll.Name = "CodeScroll"
Ed.Scroll.Size = UDim2.new(1, -20, 1, -72)
Ed.Scroll.Position = UDim2.new(0, 10, 0, 40)
Ed.Scroll.BackgroundColor3 = Color3.fromRGB(10, 12, 17)
Ed.Scroll.BorderSizePixel = 0
Ed.Scroll.ScrollBarThickness = 6
Ed.Scroll.ScrollBarImageColor3 = Color3.fromRGB(60, 75, 105)
Ed.Scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
Ed.Scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
Ed.Scroll.ZIndex = 501
Ed.Scroll.Parent = Ed.Modal
edCorner(Ed.Scroll, 6)

-- Syntax Highlight Background Layer (RichText Label with pixel-perfect font alignment)
Ed.HighlightLabel = Instance.new("TextLabel")
Ed.HighlightLabel.Name = "HighlightLabel"
Ed.HighlightLabel.Size = UDim2.new(1, -16, 0, 0)
Ed.HighlightLabel.Position = UDim2.new(0, PADDING_LEFT, 0, PADDING_TOP)
Ed.HighlightLabel.AutomaticSize = Enum.AutomaticSize.None
Ed.HighlightLabel.BackgroundTransparency = 1
Ed.HighlightLabel.RichText = true
Ed.HighlightLabel.Font = Enum.Font.Code
Ed.HighlightLabel.TextSize = 11
Ed.HighlightLabel.TextColor3 = Color3.fromRGB(171, 178, 191)
Ed.HighlightLabel.TextXAlignment = Enum.TextXAlignment.Left
Ed.HighlightLabel.TextYAlignment = Enum.TextYAlignment.Top
Ed.HighlightLabel.ZIndex = 502
Ed.HighlightLabel.Parent = Ed.Scroll

-- Interactive Code Editor Layer (TextTransparency = 1 allows syntax colors to show through)
Ed.TextBox = Instance.new("TextBox")
Ed.TextBox.Name = "CodeBox"
Ed.TextBox.Size = UDim2.new(1, -16, 0, 0)
Ed.TextBox.Position = UDim2.new(0, PADDING_LEFT, 0, PADDING_TOP)
Ed.TextBox.AutomaticSize = Enum.AutomaticSize.None
Ed.TextBox.BackgroundTransparency = 1
Ed.TextBox.ClearTextOnFocus = false
Ed.TextBox.MultiLine = true
Ed.TextBox.Font = Enum.Font.Code
Ed.TextBox.TextSize = 11
Ed.TextBox.TextColor3 = Color3.fromRGB(225, 235, 250)
Ed.TextBox.TextTransparency = 1
Ed.TextBox.TextXAlignment = Enum.TextXAlignment.Left
Ed.TextBox.TextYAlignment = Enum.TextYAlignment.Top
Ed.TextBox.ZIndex = 503
Ed.TextBox.Parent = Ed.Scroll

-- Custom High-Visibility Caret (blinking vertical bar tracking CursorPosition)
Ed.Caret = Instance.new("Frame")
Ed.Caret.Name = "CodeCaret"
Ed.Caret.Size = UDim2.new(0, 2, 0, 12)
Ed.Caret.Position = UDim2.new(0, PADDING_LEFT, 0, PADDING_TOP)
Ed.Caret.BackgroundColor3 = Color3.fromRGB(100, 215, 255)
Ed.Caret.BorderSizePixel = 0
Ed.Caret.ZIndex = 505
Ed.Caret.Visible = false
Ed.Caret.Parent = Ed.Scroll

-- Status Footer Bar (height 26)
Ed.Footer = Instance.new("Frame")
Ed.Footer.Name = "Footer"
Ed.Footer.Size = UDim2.new(1, 0, 0, 26)
Ed.Footer.Position = UDim2.new(0, 0, 1, -26)
Ed.Footer.BackgroundColor3 = Color3.fromRGB(18, 21, 30)
Ed.Footer.BorderSizePixel = 0
Ed.Footer.ZIndex = 501
Ed.Footer.Parent = Ed.Modal
edCorner(Ed.Footer, 8)

Ed.StatusLbl = Instance.new("TextLabel")
Ed.StatusLbl.Name = "StatusLbl"
Ed.StatusLbl.Size = UDim2.new(1, -20, 1, 0)
Ed.StatusLbl.Position = UDim2.new(0, 10, 0, 0)
Ed.StatusLbl.BackgroundTransparency = 1
Ed.StatusLbl.Font = Enum.Font.Gotham
Ed.StatusLbl.TextSize = 10
Ed.StatusLbl.TextColor3 = Color3.fromRGB(140, 160, 190)
Ed.StatusLbl.TextXAlignment = Enum.TextXAlignment.Left
Ed.StatusLbl.ZIndex = 502
Ed.StatusLbl.Parent = Ed.Footer

local function renderViewport()
    if not Ed.Modal.Visible or not Ed.Doc or Ed.Doc.TotalLines == 0 then return end

    local scrollY = Ed.Scroll.CanvasPosition.Y
    local viewHeight = math.max(100, Ed.Scroll.AbsoluteWindowSize.Y)

    -- Calculate visible line range with 5-line overscan buffer
    local firstLine = math.max(1, math.floor((scrollY - PADDING_TOP) / LINE_HEIGHT) - 5)
    local lastLine = math.min(Ed.Doc.TotalLines, math.ceil((scrollY + viewHeight - PADDING_TOP) / LINE_HEIGHT) + 5)
    local count = math.max(1, lastLine - firstLine + 1)

    local slice = {}
    for i = firstLine, lastLine do
        table.insert(slice, Ed.Doc.Lines[i] or "")
    end
    local sliceText = table.concat(slice, "\n")

    Ed.HighlightLabel.Position = UDim2.new(0, PADDING_LEFT, 0, (firstLine - 1) * LINE_HEIGHT + PADDING_TOP)
    Ed.HighlightLabel.Size = UDim2.new(1, -PADDING_LEFT * 2, 0, count * LINE_HEIGHT)
    Ed.HighlightLabel.Text = highlightLuau(sliceText)
end

local function updateCaretPos()
    if not Ed.TextBox:IsFocused() or not Ed.Modal.Visible then
        Ed.Caret.Visible = false
        return
    end

    local text = Ed.TextBox.Text
    local p = Ed.TextBox.CursorPosition
    if p < 1 then p = 1 end
    if p > #text + 1 then p = #text + 1 end

    local before = text:sub(1, p - 1)
    local _, lineCount = before:gsub("\n", "")
    local lastNl = before:match(".*()\n") or 0
    local linePrefix = before:sub(lastNl + 1)
    local xOffset = #linePrefix * CHAR_WIDTH
    local yOffset = lineCount * LINE_HEIGHT

    local boxTopY = Ed.TextBox.Position.Y.Offset
    Ed.Caret.Position = UDim2.new(0, PADDING_LEFT + xOffset, 0, boxTopY + yOffset)
    Ed.Caret.Visible = true
    Ed.Caret.BackgroundTransparency = 0
    Ed.CaretSolid = true

    -- Viewport scroll follow
    local targetY = boxTopY + yOffset
    local scrollY = Ed.Scroll.CanvasPosition.Y
    local viewHeight = math.max(100, Ed.Scroll.AbsoluteWindowSize.Y)
    if targetY < scrollY + 10 then
        Ed.Scroll.CanvasPosition = Vector2.new(Ed.Scroll.CanvasPosition.X, math.max(0, targetY - 20))
    elseif targetY + 16 > scrollY + viewHeight - 10 then
        Ed.Scroll.CanvasPosition = Vector2.new(Ed.Scroll.CanvasPosition.X, (targetY + 20) - viewHeight)
    end

    -- Update status bar with line and column
    local curLineInDoc = (Ed.EditStartLine - 1) + lineCount + 1
    local curColInDoc = #linePrefix + 1
    Ed.StatusLbl.Text = string.format("Ln %d, Col %d | Lines: %d | Characters: %d", curLineInDoc, curColInDoc, Ed.Doc.TotalLines, Ed.Doc.TotalChars or #text)
    Ed.StatusLbl.TextColor3 = Color3.fromRGB(140, 160, 190)
end

local function startCaretBlinking()
    if Ed.BlinkThread then
        task.cancel(Ed.BlinkThread)
        Ed.BlinkThread = nil
    end
    Ed.Caret.Visible = true
    Ed.Caret.BackgroundTransparency = 0
    Ed.CaretSolid = true
    Ed.BlinkThread = task.spawn(function()
        while Ed.TextBox:IsFocused() and Ed.Modal.Visible do
            task.wait(0.5)
            Ed.CaretSolid = not Ed.CaretSolid
            Ed.Caret.BackgroundTransparency = Ed.CaretSolid and 0 or 1
        end
        Ed.Caret.Visible = false
    end)
end

local function stopCaretBlinking()
    if Ed.BlinkThread then
        task.cancel(Ed.BlinkThread)
        Ed.BlinkThread = nil
    end
    Ed.Caret.Visible = false
end

local function activateEditWindow(targetLine, targetCol)
    if not Ed.Doc or Ed.Doc.TotalLines == 0 then return end
    targetLine = math.clamp(targetLine or 1, 1, Ed.Doc.TotalLines)
    targetCol = math.max(1, targetCol or 1)

    if Ed.Doc.TotalLines <= 300 then
        Ed.IsLargeDoc = false
        Ed.EditStartLine = 1
        Ed.EditEndLine = Ed.Doc.TotalLines
        Ed.IsUpdatingText = true
        Ed.TextBox.Position = UDim2.new(0, PADDING_LEFT, 0, PADDING_TOP)
        Ed.TextBox.Size = UDim2.new(1, -PADDING_LEFT * 2, 0, Ed.Doc.TotalLines * LINE_HEIGHT)
        Ed.TextBox.Text = table.concat(Ed.Doc.Lines, "\n")
        Ed.IsUpdatingText = false

        local charPos = 1
        for i = 1, targetLine - 1 do
            charPos = charPos + #(Ed.Doc.Lines[i] or "") + 1
        end
        local lineStr = Ed.Doc.Lines[targetLine] or ""
        charPos = charPos + math.min(targetCol - 1, #lineStr)

        Ed.TextBox:CaptureFocus()
        Ed.TextBox.CursorPosition = charPos
    else
        Ed.IsLargeDoc = true
        local startL = math.max(1, targetLine - 45)
        local endL = math.min(Ed.Doc.TotalLines, targetLine + 45)
        Ed.EditStartLine = startL
        Ed.EditEndLine = endL

        local slice = {}
        for i = startL, endL do
            table.insert(slice, Ed.Doc.Lines[i] or "")
        end
        Ed.IsUpdatingText = true
        Ed.TextBox.Position = UDim2.new(0, PADDING_LEFT, 0, (startL - 1) * LINE_HEIGHT + PADDING_TOP)
        Ed.TextBox.Size = UDim2.new(1, -PADDING_LEFT * 2, 0, (endL - startL + 1) * LINE_HEIGHT)
        Ed.TextBox.Text = table.concat(slice, "\n")
        Ed.IsUpdatingText = false

        local charPos = 1
        for i = 1, (targetLine - startL) do
            charPos = charPos + #(slice[i] or "") + 1
        end
        local lineStr = slice[targetLine - startL + 1] or ""
        charPos = charPos + math.min(targetCol - 1, #lineStr)

        Ed.TextBox:CaptureFocus()
        Ed.TextBox.CursorPosition = charPos
    end
    updateCaretPos()
    startCaretBlinking()
end

-- Scroll signals for virtualization
Ed.Scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
    renderViewport()
end)

Ed.Scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    renderViewport()
end)

-- MouseWheel Smooth Scrolling over code container
UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseWheel and Ed.Modal.Visible then
        local mousePos = UserInputService:GetMouseLocation()
        local absPos = Ed.Scroll.AbsolutePosition
        local absSize = Ed.Scroll.AbsoluteSize
        if mousePos.X >= absPos.X and mousePos.X <= absPos.X + absSize.X and
           mousePos.Y >= absPos.Y and mousePos.Y <= absPos.Y + absSize.Y then
            local delta = input.Position.Z * -33 -- 3 lines per notch
            local currentY = Ed.Scroll.CanvasPosition.Y
            local maxY = math.max(0, Ed.Scroll.AbsoluteCanvasSize.Y - Ed.Scroll.AbsoluteWindowSize.Y)
            Ed.Scroll.CanvasPosition = Vector2.new(Ed.Scroll.CanvasPosition.X, math.clamp(currentY + delta, 0, maxY))
        end
    end
end)

-- Click-to-Position Navigation
Ed.Scroll.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 and Ed.Modal.Visible and Ed.Doc and Ed.Doc.TotalLines > 0 then
        local mousePos = UserInputService:GetMouseLocation()
        local guiInset = GuiService:GetGuiInset()
        local my = mousePos.Y - guiInset.Y
        local mx = mousePos.X - guiInset.X

        local clickLocalY = my - Ed.Scroll.AbsolutePosition.Y + Ed.Scroll.CanvasPosition.Y - PADDING_TOP
        local clickedLine = math.clamp(math.floor(clickLocalY / LINE_HEIGHT) + 1, 1, Ed.Doc.TotalLines)
        local clickLocalX = mx - Ed.Scroll.AbsolutePosition.X - PADDING_LEFT + Ed.Scroll.CanvasPosition.X
        local clickedCol = math.max(1, math.floor(clickLocalX / CHAR_WIDTH) + 1)

        activateEditWindow(clickedLine, clickedCol)
    end
end)

-- Tab Key Support: 4 spaces insertion & focus retention
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if input.KeyCode == Enum.KeyCode.Tab and Ed.TextBox:IsFocused() and Ed.Modal.Visible then
        local p = Ed.TextBox.CursorPosition
        local t = Ed.TextBox.Text
        if p > 0 and p <= #t + 1 then
            local newText = t:sub(1, p - 1) .. "    " .. t:sub(p)
            Ed.TextBox.Text = newText
            Ed.TextBox.CursorPosition = p + 4
            task.defer(function()
                if Ed.TextBox and Ed.Modal.Visible then
                    Ed.TextBox:CaptureFocus()
                    Ed.TextBox.CursorPosition = p + 4
                    updateCaretPos()
                end
            end)
        end
    end
end)

Ed.TextBox.Focused:Connect(function()
    updateCaretPos()
    startCaretBlinking()
end)

Ed.TextBox.FocusLost:Connect(function()
    stopCaretBlinking()
end)

Ed.TextBox:GetPropertyChangedSignal("CursorPosition"):Connect(function()
    updateCaretPos()
end)

openCodeEditor = function(scriptObj)
    Ed.Script = scriptObj
    if Ed.HlThread then
        task.cancel(Ed.HlThread)
        Ed.HlThread = nil
    end

    local target = normStartupPath(scriptObj.file)
    if not isfile(target) and isfile("workspace/" .. target) then
        target = "workspace/" .. target
    end

    local code = ""
    if isfile(target) then
        local ok, content = pcall(readfile, target)
        if ok and content then
            code = content
        end
    end

    -- Normalize CRLF -> LF
    code = code:gsub("\r\n", "\n"):gsub("\r", "\n")

    Ed.Title.Text = "✏️ " .. (scriptObj.name or "Script") .. " (" .. scriptObj.file .. ")"
    local isTruncated = false
    if #code >= 2000000 then
        isTruncated = true
        code = code:sub(1, 200000) .. "\n\n-- [TRUNCATED: File exceeds 2,000,000 characters]"
        Ed.StatusLbl.Text = string.format("⚠️ File truncated (Original: %d chars, Max: 2,000,000 chars) | Read-Only", #code)
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(255, 170, 50)
    end
    Ed.Script.isTruncated = isTruncated

    local lines = string.split(code, "\n")
    if #lines == 0 then lines = {""} end
    Ed.Doc.Lines = lines
    Ed.Doc.TotalLines = #lines

    local maxLen = 0
    for _, l in ipairs(lines) do
        if #l > maxLen then maxLen = #l end
    end
    Ed.Doc.MaxLineLen = maxLen
    Ed.Doc.TotalChars = #code

    Ed.Scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
    Ed.Scroll.CanvasSize = UDim2.new(0, math.max(0, maxLen * CHAR_WIDTH + 60), 0, Ed.Doc.TotalLines * LINE_HEIGHT + 40)
    Ed.Scroll.CanvasPosition = Vector2.new(0, 0)

    if not isTruncated then
        Ed.StatusLbl.Text = string.format("Lines: %d | Characters: %d | Ready", Ed.Doc.TotalLines, #code)
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(140, 160, 190)
    end

    -- Ensure mouse cursor is completely unlocked and visible
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
    Ed.Modal.Visible = true

    renderViewport()
    activateEditWindow(1, 1)
end

getgenv().OpenScriptEditor = function(fileOrObj)
    if type(fileOrObj) == "string" then
        openCodeEditor({
            file = fileOrObj,
            name = fileOrObj:match("([^/\\.]+)%.lua$") or fileOrObj:match("([^/\\.]+)%.txt$") or fileOrObj,
            stage = "PreInit"
        })
    elseif type(fileOrObj) == "table" then
        openCodeEditor(fileOrObj)
    end
end

Ed.TextBox:GetPropertyChangedSignal("Text"):Connect(function()
    if not Ed.Modal.Visible or not Ed.Script or Ed.IsUpdatingText then return end
    if Ed.Script.isTruncated then return end

    local newText = Ed.TextBox.Text
    local newSlice = string.split(newText, "\n")

    if not Ed.IsLargeDoc then
        Ed.Doc.Lines = newSlice
        Ed.Doc.TotalLines = #newSlice
        Ed.EditStartLine = 1
        Ed.EditEndLine = #newSlice
    else
        local before = {}
        for i = 1, Ed.EditStartLine - 1 do table.insert(before, Ed.Doc.Lines[i] or "") end
        local after = {}
        for i = Ed.EditEndLine + 1, #Ed.Doc.Lines do table.insert(after, Ed.Doc.Lines[i] or "") end

        local merged = {}
        for _, l in ipairs(before) do table.insert(merged, l) end
        for _, l in ipairs(newSlice) do table.insert(merged, l) end
        for _, l in ipairs(after) do table.insert(merged, l) end

        Ed.Doc.Lines = merged
        Ed.Doc.TotalLines = #merged
        Ed.EditEndLine = Ed.EditStartLine + #newSlice - 1
    end

    local maxLen = 0
    local totalChars = 0
    for _, l in ipairs(Ed.Doc.Lines) do
        local len = #l
        if len > maxLen then maxLen = len end
        totalChars = totalChars + len + 1
    end
    Ed.Doc.MaxLineLen = maxLen
    Ed.Doc.TotalChars = totalChars

    Ed.Scroll.CanvasSize = UDim2.new(0, math.max(0, maxLen * CHAR_WIDTH + 60), 0, Ed.Doc.TotalLines * LINE_HEIGHT + 40)
    Ed.TextBox.Size = UDim2.new(1, -PADDING_LEFT * 2, 0, (Ed.EditEndLine - Ed.EditStartLine + 1) * LINE_HEIGHT)

    Ed.StatusLbl.Text = string.format("Lines: %d | Characters: %d | Unsaved changes", Ed.Doc.TotalLines, totalChars)
    Ed.StatusLbl.TextColor3 = Color3.fromRGB(180, 200, 230)

    renderViewport()
    updateCaretPos()
end)

Ed.CloseBtn.MouseButton1Click:Connect(function()
    stopCaretBlinking()
    if Ed.HlThread then
        task.cancel(Ed.HlThread)
        Ed.HlThread = nil
    end
    Ed.Modal.Visible = false
    Ed.Script = nil
end)

Ed.SaveBtn.MouseButton1Click:Connect(function()
    if not Ed.Script then return end
    if Ed.Script.isTruncated then
        Ed.StatusLbl.Text = "❌ Save blocked: File exceeds limit. Please edit externally."
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
        return
    end
    local target = normStartupPath(Ed.Script.file)
    if not isfile(target) and isfile("workspace/" .. target) then
        target = "workspace/" .. target
    end
    Ed.SaveBtn.Text = "⏳ Saving..."
    local fullCode = table.concat(Ed.Doc.Lines, "\n")
    local ok, err = pcall(writefile, target, fullCode)
    if ok then
        Ed.SaveBtn.Text = "✅ Saved!"
        Ed.StatusLbl.Text = string.format("✅ Saved successfully to %s at %s (%d chars)", Ed.Script.file, os.date("%H:%M:%S"), #fullCode)
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(100, 240, 150)
        task.delay(1.5, function()
            if Ed.SaveBtn then Ed.SaveBtn.Text = "💾 Save" end
        end)
        scanStartupScripts(true)
    else
        Ed.SaveBtn.Text = "ERR"
        Ed.StatusLbl.Text = "❌ Save failed: " .. tostring(err)
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
        task.delay(2, function()
            if Ed.SaveBtn then Ed.SaveBtn.Text = "💾 Save" end
        end)
    end
end)

Ed.RunBtn.MouseButton1Click:Connect(function()
    if not Ed.Script then return end
    local fullCode = table.concat(Ed.Doc.Lines, "\n")
    local fn, sErr = loadstring(fullCode, "@" .. (Ed.Script.name or "Script"))
    if not fn then
        Ed.StatusLbl.Text = "⚠️ Syntax Error: " .. tostring(sErr)
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(255, 120, 80)
        return
    end
    Ed.RunBtn.Text = "⏳ Running..."
    local ok, rErr = pcall(task.spawn, fn)
    if ok then
        Ed.RunBtn.Text = "🚀 Done!"
        Ed.StatusLbl.Text = "🚀 Script executed successfully in isolated thread!"
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(100, 240, 150)
    else
        Ed.RunBtn.Text = "ERR"
        Ed.StatusLbl.Text = "⚠️ Runtime Error: " .. tostring(rErr)
        Ed.StatusLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
    end
    task.delay(1.5, function()
        if Ed.RunBtn then Ed.RunBtn.Text = "▶ Run" end
    end)
end)
end -- end CodeEditorModal block scope

do
do
    -- ==============================================================================
    -- NEW STARTUP SCRIPT CREATION MODAL
    -- ==============================================================================
    local NM = {}

    local function nmCorner(parent, r)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, r or 4)
        c.Parent = parent
        return c
    end

    local function nmStroke(parent, col, thick)
        local s = Instance.new("UIStroke")
        s.Color = col or Color3.fromRGB(50, 68, 98)
        s.Thickness = thick or 1
        s.Parent = parent
        return s
    end

    NM.Modal = Instance.new("Frame")
    NM.Modal.Name = "NewScriptModal"
    NM.Modal.Size = UDim2.new(0, 430, 0, 290)
    NM.Modal.Position = UDim2.new(0.5, -215, 0.5, -145)
    NM.Modal.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
    NM.Modal.BorderSizePixel = 0
    NM.Modal.ZIndex = 510
    NM.Modal.Visible = false
    NM.Modal.Parent = MainFrame
    nmCorner(NM.Modal, 8)
    nmStroke(NM.Modal, Color3.fromRGB(50, 68, 98), 1.5)

    -- Header
    NM.Header = Instance.new("Frame")
    NM.Header.Name = "Header"
    NM.Header.Size = UDim2.new(1, 0, 0, 36)
    NM.Header.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
    NM.Header.BorderSizePixel = 0
    NM.Header.ZIndex = 511
    NM.Header.Parent = NM.Modal
    nmCorner(NM.Header, 8)

    NM.Title = Instance.new("TextLabel")
    NM.Title.Name = "Title"
    NM.Title.Size = UDim2.new(1, -50, 1, 0)
    NM.Title.Position = UDim2.new(0, 14, 0, 0)
    NM.Title.BackgroundTransparency = 1
    NM.Title.Font = Enum.Font.GothamBold
    NM.Title.TextSize = 11
    NM.Title.TextColor3 = Color3.fromRGB(240, 245, 255)
    NM.Title.Text = "➕ Create New Startup Script"
    NM.Title.TextXAlignment = Enum.TextXAlignment.Left
    NM.Title.ZIndex = 512
    NM.Title.Parent = NM.Header

    NM.CloseBtn = Instance.new("TextButton")
    NM.CloseBtn.Name = "CloseBtn"
    NM.CloseBtn.Size = UDim2.new(0, 32, 0, 24)
    NM.CloseBtn.Position = UDim2.new(1, -38, 0.5, -12)
    NM.CloseBtn.BackgroundColor3 = Color3.fromRGB(55, 25, 30)
    NM.CloseBtn.AutoButtonColor = false
    NM.CloseBtn.Font = Enum.Font.GothamBold
    NM.CloseBtn.TextSize = 12
    NM.CloseBtn.TextColor3 = Color3.fromRGB(255, 130, 130)
    NM.CloseBtn.Text = "X"
    NM.CloseBtn.Modal = true
    NM.CloseBtn.ZIndex = 512
    NM.CloseBtn.Parent = NM.Header
    nmCorner(NM.CloseBtn, 4)

    NM.CloseBtn.MouseButton1Click:Connect(function()
        NM.Modal.Visible = false
    end)

    -- Script Name Field
    NM.NameLbl = Instance.new("TextLabel")
    NM.NameLbl.Size = UDim2.new(1, -28, 0, 14)
    NM.NameLbl.Position = UDim2.new(0, 14, 0, 46)
    NM.NameLbl.BackgroundTransparency = 1
    NM.NameLbl.Font = Enum.Font.GothamBold
    NM.NameLbl.TextSize = 9
    NM.NameLbl.TextColor3 = Color3.fromRGB(120, 140, 175)
    NM.NameLbl.Text = "SCRIPT FILENAME"
    NM.NameLbl.TextXAlignment = Enum.TextXAlignment.Left
    NM.NameLbl.ZIndex = 511
    NM.NameLbl.Parent = NM.Modal

    NM.NameBox = Instance.new("TextBox")
    NM.NameBox.Name = "NameBox"
    NM.NameBox.Size = UDim2.new(1, -28, 0, 28)
    NM.NameBox.Position = UDim2.new(0, 14, 0, 64)
    NM.NameBox.BackgroundColor3 = Color3.fromRGB(11, 14, 20)
    NM.NameBox.BorderSizePixel = 0
    NM.NameBox.ClearTextOnFocus = false
    NM.NameBox.Font = Enum.Font.Code
    NM.NameBox.TextSize = 11
    NM.NameBox.TextColor3 = Color3.fromRGB(225, 235, 250)
    NM.NameBox.Text = "NewScript.lua"
    NM.NameBox.PlaceholderText = "e.g. MyScript.lua"
    NM.NameBox.PlaceholderColor3 = Color3.fromRGB(80, 95, 120)
    NM.NameBox.TextXAlignment = Enum.TextXAlignment.Left
    NM.NameBox.ZIndex = 511
    NM.NameBox.Parent = NM.Modal
    nmCorner(NM.NameBox, 4)
    nmStroke(NM.NameBox, Color3.fromRGB(40, 52, 75), 1)

    local nbPad = Instance.new("UIPadding")
    nbPad.PaddingLeft = UDim.new(0, 8)
    nbPad.PaddingRight = UDim.new(0, 8)
    nbPad.Parent = NM.NameBox

    -- Boot Stage Selector
    NM.StageLbl = Instance.new("TextLabel")
    NM.StageLbl.Size = UDim2.new(1, -28, 0, 14)
    NM.StageLbl.Position = UDim2.new(0, 14, 0, 102)
    NM.StageLbl.BackgroundTransparency = 1
    NM.StageLbl.Font = Enum.Font.GothamBold
    NM.StageLbl.TextSize = 9
    NM.StageLbl.TextColor3 = Color3.fromRGB(120, 140, 175)
    NM.StageLbl.Text = "BOOT STAGE (EXECUTION TIMING)"
    NM.StageLbl.TextXAlignment = Enum.TextXAlignment.Left
    NM.StageLbl.ZIndex = 511
    NM.StageLbl.Parent = NM.Modal

    NM.SelectedStage = "PreInit"
    NM.StageButtons = {}

    NM.StageContainer = Instance.new("Frame")
    NM.StageContainer.Size = UDim2.new(1, -28, 0, 24)
    NM.StageContainer.Position = UDim2.new(0, 14, 0, 118)
    NM.StageContainer.BackgroundTransparency = 1
    NM.StageContainer.ZIndex = 511
    NM.StageContainer.Parent = NM.Modal

    local stageLayout = Instance.new("UIListLayout")
    stageLayout.FillDirection = Enum.FillDirection.Horizontal
    stageLayout.Padding = UDim.new(0, 6)
    stageLayout.Parent = NM.StageContainer

    local function updatePills()
        for s, b in pairs(NM.StageButtons) do
            local isSel = (s == NM.SelectedStage)
            b.BackgroundColor3 = isSel and Color3.fromRGB(28, 55, 95) or Color3.fromRGB(14, 18, 25)
            b.TextColor3 = isSel and Color3.fromRGB(100, 210, 255) or Color3.fromRGB(120, 135, 160)
            local strk = b:FindFirstChildOfClass("UIStroke")
            if strk then strk.Color = isSel and Color3.fromRGB(50, 110, 180) or Color3.fromRGB(35, 45, 65) end
        end
    end

    for _, s in ipairs({ "PreInit", "GameLoaded", "CharacterReady", "Deferred" }) do
        local sb = Instance.new("TextButton")
        sb.Name = "Stage_" .. s
        sb.Size = UDim2.new(0.25, -5, 1, 0)
        sb.AutoButtonColor = false
        sb.Font = Enum.Font.GothamBold
        sb.TextSize = 9
        sb.Text = s
        sb.ZIndex = 512
        sb.Parent = NM.StageContainer
        nmCorner(sb, 4)
        nmStroke(sb, Color3.fromRGB(35, 45, 65), 1)
        NM.StageButtons[s] = sb
        sb.MouseButton1Click:Connect(function()
            NM.SelectedStage = s
            updatePills()
        end)
    end

    -- Scope Selector
    NM.ScopeLbl = Instance.new("TextLabel")
    NM.ScopeLbl.Size = UDim2.new(1, -28, 0, 14)
    NM.ScopeLbl.Position = UDim2.new(0, 14, 0, 152)
    NM.ScopeLbl.BackgroundTransparency = 1
    NM.ScopeLbl.Font = Enum.Font.GothamBold
    NM.ScopeLbl.TextSize = 9
    NM.ScopeLbl.TextColor3 = Color3.fromRGB(120, 140, 175)
    NM.ScopeLbl.Text = "SCRIPT SCOPE"
    NM.ScopeLbl.TextXAlignment = Enum.TextXAlignment.Left
    NM.ScopeLbl.ZIndex = 511
    NM.ScopeLbl.Parent = NM.Modal

    NM.SelectedScope = "Universal"
    NM.ScopeButtons = {}

    NM.ScopeContainer = Instance.new("Frame")
    NM.ScopeContainer.Size = UDim2.new(1, -28, 0, 24)
    NM.ScopeContainer.Position = UDim2.new(0, 14, 0, 168)
    NM.ScopeContainer.BackgroundTransparency = 1
    NM.ScopeContainer.ZIndex = 511
    NM.ScopeContainer.Parent = NM.Modal

    local scopeLayout = Instance.new("UIListLayout")
    scopeLayout.FillDirection = Enum.FillDirection.Horizontal
    scopeLayout.Padding = UDim.new(0, 6)
    scopeLayout.Parent = NM.ScopeContainer

    local function updateScopePills()
        for sc, b in pairs(NM.ScopeButtons) do
            local isSel = (sc == NM.SelectedScope)
            b.BackgroundColor3 = isSel and Color3.fromRGB(28, 55, 95) or Color3.fromRGB(14, 18, 25)
            b.TextColor3 = isSel and Color3.fromRGB(100, 210, 255) or Color3.fromRGB(120, 135, 160)
            local strk = b:FindFirstChildOfClass("UIStroke")
            if strk then strk.Color = isSel and Color3.fromRGB(50, 110, 180) or Color3.fromRGB(35, 45, 65) end
        end
    end

    for _, sc in ipairs({
        { id = "Universal", label = "🌐 Universal (All Games)" },
        { id = "GameSpecific", label = "🎯 Game-Specific (" .. tostring(game.PlaceId) .. ")" }
    }) do
        local scb = Instance.new("TextButton")
        scb.Name = "Scope_" .. sc.id
        scb.Size = UDim2.new(0.5, -3, 1, 0)
        scb.AutoButtonColor = false
        scb.Font = Enum.Font.GothamMedium
        scb.TextSize = 9
        scb.Text = sc.label
        scb.ZIndex = 512
        scb.Parent = NM.ScopeContainer
        nmCorner(scb, 4)
        nmStroke(scb, Color3.fromRGB(35, 45, 65), 1)
        NM.ScopeButtons[sc.id] = scb
        scb.MouseButton1Click:Connect(function()
            NM.SelectedScope = sc.id
            updateScopePills()
        end)
    end

    -- Status / Error label
    NM.StatusLbl = Instance.new("TextLabel")
    NM.StatusLbl.Size = UDim2.new(1, -28, 0, 16)
    NM.StatusLbl.Position = UDim2.new(0, 14, 0, 202)
    NM.StatusLbl.BackgroundTransparency = 1
    NM.StatusLbl.Font = Enum.Font.Gotham
    NM.StatusLbl.TextSize = 10
    NM.StatusLbl.TextColor3 = Color3.fromRGB(255, 90, 90)
    NM.StatusLbl.TextXAlignment = Enum.TextXAlignment.Left
    NM.StatusLbl.ZIndex = 511
    NM.StatusLbl.Text = ""
    NM.StatusLbl.Parent = NM.Modal

    -- Action Buttons (Bottom Bar)
    NM.CancelBtn = Instance.new("TextButton")
    NM.CancelBtn.Name = "CancelBtn"
    NM.CancelBtn.Size = UDim2.new(0, 85, 0, 26)
    NM.CancelBtn.Position = UDim2.new(1, -225, 1, -38)
    NM.CancelBtn.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
    NM.CancelBtn.AutoButtonColor = false
    NM.CancelBtn.Font = Enum.Font.GothamMedium
    NM.CancelBtn.TextSize = 10
    NM.CancelBtn.TextColor3 = Color3.fromRGB(150, 165, 185)
    NM.CancelBtn.Text = "Cancel"
    NM.CancelBtn.ZIndex = 512
    NM.CancelBtn.Parent = NM.Modal
    nmCorner(NM.CancelBtn, 4)

    NM.CancelBtn.MouseButton1Click:Connect(function()
        NM.Modal.Visible = false
    end)

    NM.CreateBtn = Instance.new("TextButton")
    NM.CreateBtn.Name = "CreateBtn"
    NM.CreateBtn.Size = UDim2.new(0, 120, 0, 26)
    NM.CreateBtn.Position = UDim2.new(1, -134, 1, -38)
    NM.CreateBtn.BackgroundColor3 = Color3.fromRGB(25, 75, 45)
    NM.CreateBtn.AutoButtonColor = false
    NM.CreateBtn.Font = Enum.Font.GothamBold
    NM.CreateBtn.TextSize = 10
    NM.CreateBtn.TextColor3 = Color3.fromRGB(120, 250, 160)
    NM.CreateBtn.Text = "🚀 Create & Edit"
    NM.CreateBtn.ZIndex = 512
    NM.CreateBtn.Parent = NM.Modal
    nmCorner(NM.CreateBtn, 4)

    NM.CreateBtn.MouseButton1Click:Connect(function()
        local rawName = NM.NameBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
        if rawName == "" then
            NM.StatusLbl.Text = "⚠️ Please enter a script filename."
            return
        end
        if not rawName:find("%.lua$") and not rawName:find("%.txt$") then
            rawName = rawName .. ".lua"
        end

        local placeIdStr = tostring(game.PlaceId)
        local placeName = "Place"
        pcall(function()
            local info = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
            if info and info.Name then placeName = info.Name end
        end)
        local safePlaceName = placeName:gsub("[^%w%s%-_]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local gameFolder = string.format("%s - %s", placeIdStr, safePlaceName)

        local targetRelPath
        if NM.SelectedScope == "Universal" then
            if NM.SelectedStage == "PreInit" then
                if not isfolder("autoexec/preinit") then makefolder("autoexec/preinit") end
                targetRelPath = "autoexec/preinit/" .. rawName
            else
                if not isfolder("autoexec") then makefolder("autoexec") end
                targetRelPath = "autoexec/" .. rawName
            end
        else
            local base = "autoexec/" .. gameFolder
            if not isfolder(base) then makefolder(base) end
            if NM.SelectedStage == "PreInit" then
                if not isfolder(base .. "/preinit") then makefolder(base .. "/preinit") end
                targetRelPath = base .. "/preinit/" .. rawName
            else
                targetRelPath = base .. "/" .. rawName
            end
        end

        local diskPath = targetRelPath
        if not isfile(diskPath) and isfile("workspace/" .. diskPath) then
            diskPath = "workspace/" .. diskPath
        end

        if isfile(diskPath) then
            NM.StatusLbl.Text = "❌ File already exists: " .. targetRelPath
            return
        end

        local cleanTitle = rawName:gsub("%.%w+$", "")
        local boilerplate = string.format([[--!stage %s
--!priority 100
--!name %s

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

print("[%s]: Initialized successfully.")
]], NM.SelectedStage, cleanTitle, cleanTitle)

        local ok, err = pcall(writefile, targetRelPath, boilerplate)
        if not ok then
            NM.StatusLbl.Text = "❌ Creation failed: " .. tostring(err)
            return
        end

        NM.Modal.Visible = false
        scanStartupScripts(true)
        if refreshStartupTab then
            refreshStartupTab(true)
        end

        if openCodeEditor then
            openCodeEditor({
                file = targetRelPath,
                name = cleanTitle,
                stage = NM.SelectedStage
            })
        end
    end)

    openNewScriptModal = function()
        NM.NameBox.Text = "NewScript.lua"
        NM.SelectedStage = "PreInit"
        NM.SelectedScope = "Universal"
        updatePills()
        updateScopePills()
        NM.StatusLbl.Text = ""
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
        NM.Modal.Visible = true
        task.defer(function()
            NM.NameBox:CaptureFocus()
        end)
    end
end
end

do
    -- ==============================================================================
    -- TABLE NOTICE BANNER (Option 2: Non-intrusive floating toast with quick-switch)
    -- ==============================================================================
    local NoticeBanner = Instance.new("Frame")
    NoticeBanner.Name = "TableNoticeBanner"
    NoticeBanner.Size = UDim2.new(0, 480, 0, 36)
    NoticeBanner.Position = UDim2.new(0.5, -240, 1, -80)
    NoticeBanner.BackgroundColor3 = Color3.fromRGB(22, 28, 40)
    NoticeBanner.BorderSizePixel = 0
    NoticeBanner.ZIndex = 500
    NoticeBanner.Visible = false
    NoticeBanner.Parent = MainFrame

    local nbCorner = Instance.new("UICorner")
    nbCorner.CornerRadius = UDim.new(0, 6)
    nbCorner.Parent = NoticeBanner

    local nbStroke = Instance.new("UIStroke")
    nbStroke.Color = Color3.fromRGB(60, 90, 140)
    nbStroke.Thickness = 1.5
    nbStroke.Parent = NoticeBanner

    local nbIcon = Instance.new("TextLabel")
    nbIcon.Name = "Icon"
    nbIcon.Size = UDim2.new(0, 24, 1, 0)
    nbIcon.Position = UDim2.new(0, 8, 0, 0)
    nbIcon.BackgroundTransparency = 1
    nbIcon.Font = Enum.Font.GothamBold
    nbIcon.TextSize = 13
    nbIcon.TextColor3 = Color3.fromRGB(240, 180, 50)
    nbIcon.Text = ICONS.LOCK_CLOSED
    nbIcon.Parent = NoticeBanner

    local nbMsg = Instance.new("TextLabel")
    nbMsg.Name = "Message"
    nbMsg.Size = UDim2.new(1, -190, 1, 0)
    nbMsg.Position = UDim2.new(0, 32, 0, 0)
    nbMsg.BackgroundTransparency = 1
    nbMsg.Font = Enum.Font.GothamMedium
    nbMsg.TextSize = 10
    nbMsg.TextColor3 = Color3.fromRGB(215, 230, 250)
    nbMsg.TextXAlignment = Enum.TextXAlignment.Left
    nbMsg.TextTruncate = Enum.TextTruncate.AtEnd
    nbMsg.Text = "Manual reordering is locked."
    nbMsg.Parent = NoticeBanner

    local nbSwitchBtn = Instance.new("TextButton")
    nbSwitchBtn.Name = "SwitchBtn"
    nbSwitchBtn.Size = UDim2.new(0, 120, 0, 24)
    nbSwitchBtn.Position = UDim2.new(1, -150, 0.5, -12)
    nbSwitchBtn.BackgroundColor3 = Color3.fromRGB(35, 75, 130)
    nbSwitchBtn.BorderSizePixel = 0
    nbSwitchBtn.AutoButtonColor = false
    nbSwitchBtn.Font = Enum.Font.GothamBold
    nbSwitchBtn.TextSize = 10
    nbSwitchBtn.TextColor3 = Color3.fromRGB(150, 215, 255)
    nbSwitchBtn.Text = "Switch to Priority"
    nbSwitchBtn.Parent = NoticeBanner
    local sbCorner = Instance.new("UICorner")
    sbCorner.CornerRadius = UDim.new(0, 4)
    sbCorner.Parent = nbSwitchBtn

    nbSwitchBtn.MouseEnter:Connect(function()
        nbSwitchBtn.BackgroundColor3 = Color3.fromRGB(48, 95, 160)
    end)
    nbSwitchBtn.MouseLeave:Connect(function()
        nbSwitchBtn.BackgroundColor3 = Color3.fromRGB(35, 75, 130)
    end)

    local nbCloseBtn = Instance.new("TextButton")
    nbCloseBtn.Name = "CloseBtn"
    nbCloseBtn.Size = UDim2.new(0, 20, 0, 20)
    nbCloseBtn.Position = UDim2.new(1, -24, 0.5, -10)
    nbCloseBtn.BackgroundTransparency = 1
    nbCloseBtn.Font = Enum.Font.GothamBold
    nbCloseBtn.TextSize = 12
    nbCloseBtn.TextColor3 = Color3.fromRGB(150, 165, 185)
    nbCloseBtn.Text = "✕"
    nbCloseBtn.Parent = NoticeBanner

    nbCloseBtn.MouseButton1Click:Connect(function()
        NoticeBanner.Visible = false
    end)

    local noticeTimerToken = 0
    local noticeTargetTab = "Tasks"

    nbSwitchBtn.MouseButton1Click:Connect(function()
        NoticeBanner.Visible = false
        local tabKey = noticeTargetTab or currentTab or "Tasks"
        local state = TableSortState[tabKey]
        if state then
            state.colId = "Priority"
            state.ascending = false
            updateHeaderSortIndicators(tabKey)
            local isPriSort = true
            if tabKey == "Tasks" then
                for _, r in pairs(cachedTaskRows) do
                    local grip = r:FindFirstChild("GripLbl")
                    if grip then grip.TextColor3 = Color3.fromRGB(120, 160, 215) end
                end
            elseif tabKey == "Loops" then
                for _, r in pairs(cachedLoopRows) do
                    local grip = r:FindFirstChild("GripLbl")
                    if grip then grip.TextColor3 = Color3.fromRGB(120, 160, 215) end
                end
            elseif tabKey == "Startup" then
                for _, r in pairs(cachedStartupRows) do
                    local grip = r:FindFirstChild("GripLbl")
                    if grip then grip.TextColor3 = Color3.fromRGB(120, 160, 215) end
                end
            end
            if tabKey == "Startup" and refreshStartupTab then
                refreshStartupTab(true)
            end
        end
    end)

    showTableNotice = function(message, showSwitch, targetTab)
        noticeTargetTab = targetTab or currentTab or "Tasks"
        nbMsg.Text = message or "Manual reordering is locked."
        nbSwitchBtn.Visible = (showSwitch ~= false)
        if nbSwitchBtn.Visible then
            nbMsg.Size = UDim2.new(1, -190, 1, 0)
        else
            nbMsg.Size = UDim2.new(1, -60, 1, 0)
        end
        NoticeBanner.Visible = true
        noticeTimerToken = noticeTimerToken + 1
        local myToken = noticeTimerToken
        task.delay(4, function()
            if noticeTimerToken == myToken and NoticeBanner.Visible then
                NoticeBanner.Visible = false
            end
        end)
    end

    -- ==============================================================================
    -- PRIORITY EDIT MODAL (Option 3: Stepper, Direct Number Input, Presets)
    -- ==============================================================================
    local PM = {}
    PM.Modal = Instance.new("Frame")
    PM.Modal.Name = "PriorityEditModal"
    PM.Modal.Size = UDim2.new(0, 360, 0, 220)
    PM.Modal.Position = UDim2.new(0.5, -180, 0.5, -110)
    PM.Modal.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
    PM.Modal.BorderSizePixel = 0
    PM.Modal.ZIndex = 520
    PM.Modal.Visible = false
    PM.Modal.Parent = MainFrame

    local pmCorner = Instance.new("UICorner")
    pmCorner.CornerRadius = UDim.new(0, 8)
    pmCorner.Parent = PM.Modal

    local pmStroke = Instance.new("UIStroke")
    pmStroke.Color = Color3.fromRGB(50, 68, 98)
    pmStroke.Thickness = 1.5
    pmStroke.Parent = PM.Modal

    -- Header
    PM.Header = Instance.new("Frame")
    PM.Header.Name = "Header"
    PM.Header.Size = UDim2.new(1, 0, 0, 36)
    PM.Header.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
    PM.Header.BorderSizePixel = 0
    PM.Header.ZIndex = 521
    PM.Header.Parent = PM.Modal
    local pmhCorner = Instance.new("UICorner")
    pmhCorner.CornerRadius = UDim.new(0, 8)
    pmhCorner.Parent = PM.Header

    PM.Title = Instance.new("TextLabel")
    PM.Title.Name = "Title"
    PM.Title.Size = UDim2.new(1, -50, 1, 0)
    PM.Title.Position = UDim2.new(0, 14, 0, 0)
    PM.Title.BackgroundTransparency = 1
    PM.Title.Font = Enum.Font.GothamBold
    PM.Title.TextSize = 11
    PM.Title.TextColor3 = Color3.fromRGB(240, 245, 255)
    PM.Title.Text = "🎯 Adjust Execution Priority"
    PM.Title.TextXAlignment = Enum.TextXAlignment.Left
    PM.Title.ZIndex = 522
    PM.Title.Parent = PM.Header

    PM.CloseBtn = Instance.new("TextButton")
    PM.CloseBtn.Name = "CloseBtn"
    PM.CloseBtn.Size = UDim2.new(0, 24, 0, 24)
    PM.CloseBtn.Position = UDim2.new(1, -30, 0, 6)
    PM.CloseBtn.BackgroundColor3 = Color3.fromRGB(30, 36, 48)
    PM.CloseBtn.BorderSizePixel = 0
    PM.CloseBtn.Font = Enum.Font.GothamBold
    PM.CloseBtn.TextSize = 12
    PM.CloseBtn.TextColor3 = Color3.fromRGB(180, 195, 220)
    PM.CloseBtn.Text = "✕"
    PM.CloseBtn.ZIndex = 522
    PM.CloseBtn.Parent = PM.Header
    local pmcCorner = Instance.new("UICorner")
    pmcCorner.CornerRadius = UDim.new(0, 4)
    pmcCorner.Parent = PM.CloseBtn

    PM.CloseBtn.MouseButton1Click:Connect(function()
        PM.Modal.Visible = false
    end)

    -- Target Info Row
    PM.TargetBadge = Instance.new("TextLabel")
    PM.TargetBadge.Name = "TargetBadge"
    PM.TargetBadge.Size = UDim2.new(0, 70, 0, 20)
    PM.TargetBadge.Position = UDim2.new(0, 16, 0, 46)
    PM.TargetBadge.BackgroundColor3 = Color3.fromRGB(25, 45, 75)
    PM.TargetBadge.BorderSizePixel = 0
    PM.TargetBadge.Font = Enum.Font.GothamBold
    PM.TargetBadge.TextSize = 9
    PM.TargetBadge.TextColor3 = Color3.fromRGB(100, 190, 255)
    PM.TargetBadge.Text = "TASK"
    PM.TargetBadge.ZIndex = 522
    PM.TargetBadge.Parent = PM.Modal
    local tbCorner = Instance.new("UICorner")
    tbCorner.CornerRadius = UDim.new(0, 4)
    tbCorner.Parent = PM.TargetBadge

    PM.TargetName = Instance.new("TextLabel")
    PM.TargetName.Name = "TargetName"
    PM.TargetName.Size = UDim2.new(1, -110, 0, 20)
    PM.TargetName.Position = UDim2.new(0, 92, 0, 46)
    PM.TargetName.BackgroundTransparency = 1
    PM.TargetName.Font = Enum.Font.GothamMedium
    PM.TargetName.TextSize = 11
    PM.TargetName.TextColor3 = Color3.fromRGB(225, 235, 250)
    PM.TargetName.TextXAlignment = Enum.TextXAlignment.Left
    PM.TargetName.TextTruncate = Enum.TextTruncate.AtEnd
    PM.TargetName.Text = "Task Name"
    PM.TargetName.ZIndex = 522
    PM.TargetName.Parent = PM.Modal

    -- Stepper Row Container
    PM.StepperContainer = Instance.new("Frame")
    PM.StepperContainer.Name = "StepperContainer"
    PM.StepperContainer.Size = UDim2.new(1, -32, 0, 36)
    PM.StepperContainer.Position = UDim2.new(0, 16, 0, 76)
    PM.StepperContainer.BackgroundTransparency = 1
    PM.StepperContainer.ZIndex = 522
    PM.StepperContainer.Parent = PM.Modal

    local function createStepBtn(name, text, posX, sizeX)
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Size = UDim2.new(0, sizeX, 1, 0)
        btn.Position = posX
        btn.BackgroundColor3 = Color3.fromRGB(25, 32, 45)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.TextColor3 = Color3.fromRGB(180, 205, 235)
        btn.Text = text
        btn.ZIndex = 523
        btn.Parent = PM.StepperContainer
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 4)
        c.Parent = btn
        local s = Instance.new("UIStroke")
        s.Thickness = 1
        s.Color = Color3.fromRGB(45, 60, 85)
        s.Parent = btn
        btn.MouseEnter:Connect(function()
            btn.BackgroundColor3 = Color3.fromRGB(35, 48, 70)
            s.Color = Color3.fromRGB(80, 130, 200)
        end)
        btn.MouseLeave:Connect(function()
            btn.BackgroundColor3 = Color3.fromRGB(25, 32, 45)
            s.Color = Color3.fromRGB(45, 60, 85)
        end)
        return btn
    end

    PM.BtnMinus10 = createStepBtn("Minus10", "-10", UDim2.new(0, 0, 0, 0), 44)
    PM.BtnMinus1 = createStepBtn("Minus1", "-1", UDim2.new(0, 48, 0, 0), 36)

    PM.PriBox = Instance.new("TextBox")
    PM.PriBox.Name = "PriBox"
    PM.PriBox.Size = UDim2.new(1, -176, 1, 0)
    PM.PriBox.Position = UDim2.new(0, 88, 0, 0)
    PM.PriBox.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
    PM.PriBox.BorderSizePixel = 0
    PM.PriBox.Font = Enum.Font.GothamBold
    PM.PriBox.TextSize = 14
    PM.PriBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    PM.PriBox.TextXAlignment = Enum.TextXAlignment.Center
    PM.PriBox.Text = "50"
    PM.PriBox.ClearTextOnFocus = false
    PM.PriBox.ZIndex = 523
    PM.PriBox.Parent = PM.StepperContainer
    local pibCorner = Instance.new("UICorner")
    pibCorner.CornerRadius = UDim.new(0, 4)
    pibCorner.Parent = PM.PriBox
    local pibStroke = Instance.new("UIStroke")
    pibStroke.Color = Color3.fromRGB(45, 65, 95)
    pibStroke.Thickness = 1
    pibStroke.Parent = PM.PriBox

    PM.BtnPlus1 = createStepBtn("Plus1", "+1", UDim2.new(1, -84, 0, 0), 36)
    PM.BtnPlus10 = createStepBtn("Plus10", "+10", UDim2.new(1, -44, 0, 0), 44)

    -- Presets Container
    PM.PresetsContainer = Instance.new("Frame")
    PM.PresetsContainer.Name = "PresetsContainer"
    PM.PresetsContainer.Size = UDim2.new(1, -32, 0, 26)
    PM.PresetsContainer.Position = UDim2.new(0, 16, 0, 122)
    PM.PresetsContainer.BackgroundTransparency = 1
    PM.PresetsContainer.ZIndex = 522
    PM.PresetsContainer.Parent = PM.Modal
    local presetsLayout = Instance.new("UIListLayout")
    presetsLayout.FillDirection = Enum.FillDirection.Horizontal
    presetsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    presetsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    presetsLayout.Padding = UDim.new(0, 6)
    presetsLayout.Parent = PM.PresetsContainer

    -- Action Buttons Container
    PM.ActionsContainer = Instance.new("Frame")
    PM.ActionsContainer.Name = "ActionsContainer"
    PM.ActionsContainer.Size = UDim2.new(1, -32, 0, 30)
    PM.ActionsContainer.Position = UDim2.new(0, 16, 1, -42)
    PM.ActionsContainer.BackgroundTransparency = 1
    PM.ActionsContainer.ZIndex = 522
    PM.ActionsContainer.Parent = PM.Modal

    PM.CancelBtn = Instance.new("TextButton")
    PM.CancelBtn.Name = "CancelBtn"
    PM.CancelBtn.Size = UDim2.new(0, 90, 1, 0)
    PM.CancelBtn.Position = UDim2.new(0, 0, 0, 0)
    PM.CancelBtn.BackgroundColor3 = Color3.fromRGB(28, 34, 46)
    PM.CancelBtn.BorderSizePixel = 0
    PM.CancelBtn.Font = Enum.Font.GothamMedium
    PM.CancelBtn.TextSize = 10
    PM.CancelBtn.TextColor3 = Color3.fromRGB(170, 185, 205)
    PM.CancelBtn.Text = "Cancel"
    PM.CancelBtn.ZIndex = 523
    PM.CancelBtn.Parent = PM.ActionsContainer
    local cbCorner = Instance.new("UICorner")
    cbCorner.CornerRadius = UDim.new(0, 4)
    cbCorner.Parent = PM.CancelBtn

    PM.SaveBtn = Instance.new("TextButton")
    PM.SaveBtn.Name = "SaveBtn"
    PM.SaveBtn.Size = UDim2.new(0, 140, 1, 0)
    PM.SaveBtn.Position = UDim2.new(1, -140, 0, 0)
    PM.SaveBtn.BackgroundColor3 = Color3.fromRGB(35, 95, 175)
    PM.SaveBtn.BorderSizePixel = 0
    PM.SaveBtn.Font = Enum.Font.GothamBold
    PM.SaveBtn.TextSize = 10
    PM.SaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    PM.SaveBtn.Text = "💾 Save Priority"
    PM.SaveBtn.ZIndex = 523
    PM.SaveBtn.Parent = PM.ActionsContainer
    local sbCorner2 = Instance.new("UICorner")
    sbCorner2.CornerRadius = UDim.new(0, 4)
    sbCorner2.Parent = PM.SaveBtn

    local currentTargetType = nil
    local currentItemObj = nil
    local currentPriorityVal = 50

    local function adjustBy(delta)
        local val = (tonumber(PM.PriBox.Text) or currentPriorityVal) + delta
        local maxLimit = (currentTargetType == "Startup") and 1000 or 100
        currentPriorityVal = math.clamp(math.round(val), 1, maxLimit)
        PM.PriBox.Text = tostring(currentPriorityVal)
    end

    PM.BtnMinus10.MouseButton1Click:Connect(function() adjustBy(-10) end)
    PM.BtnMinus1.MouseButton1Click:Connect(function() adjustBy(-1) end)
    PM.BtnPlus1.MouseButton1Click:Connect(function() adjustBy(1) end)
    PM.BtnPlus10.MouseButton1Click:Connect(function() adjustBy(10) end)
    PM.CancelBtn.MouseButton1Click:Connect(function() PM.Modal.Visible = false end)

    local function commitPrioritySave()
        if not currentTargetType or not currentItemObj then
            PM.Modal.Visible = false
            return
        end

        local rawVal = tonumber(PM.PriBox.Text) or currentPriorityVal or 50
        local maxLimit = (currentTargetType == "Startup") and 1000 or 100
        local finalVal = math.clamp(math.round(rawVal), 1, maxLimit)

        if currentTargetType == "Task" then
            currentItemObj.priority = finalVal
            currentItemObj.basePriority = finalVal
            if SetSchedulerTaskPriority then
                SetSchedulerTaskPriority(currentItemObj.id, finalVal)
            end
            saveSchedulerOverrides(true)
            emitProfile()
            local r = cachedTaskRows[currentItemObj.id]
            if r then
                local priLbl = r:FindFirstChild("PriLbl")
                if priLbl then priLbl.Text = tostring(finalVal) end
            end

        elseif currentTargetType == "Loop" then
            currentItemObj.priority = finalVal
            if SetLoopPriority then
                SetLoopPriority(currentItemObj.id, finalVal)
            end
            saveSchedulerOverrides(true)
            emitProfile()
            local r = cachedLoopRows[currentItemObj.id]
            if r then
                local priLbl = r:FindFirstChild("PriLbl")
                if priLbl then priLbl.Text = tostring(finalVal) end
            end

        elseif currentTargetType == "Startup" then
            currentItemObj.priority = finalVal
            updateScriptPragmas(currentItemObj.file, currentItemObj.stage, finalVal)
            scanStartupScripts(true)
            if refreshStartupTab then
                refreshStartupTab(true)
            end
        end

        PM.Modal.Visible = false
    end

    PM.SaveBtn.MouseButton1Click:Connect(commitPrioritySave)
    PM.PriBox.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            commitPrioritySave()
        else
            local val = tonumber(PM.PriBox.Text)
            if val then
                local maxLimit = (currentTargetType == "Startup") and 1000 or 100
                currentPriorityVal = math.clamp(math.round(val), 1, maxLimit)
                PM.PriBox.Text = tostring(currentPriorityVal)
            else
                PM.PriBox.Text = tostring(currentPriorityVal)
            end
        end
    end)

    openPriorityEditModal = function(targetType, itemObj, currentPri)
        currentTargetType = targetType
        currentItemObj = itemObj
        currentPriorityVal = tonumber(currentPri) or 50
        if targetType == "Startup" then
            currentPriorityVal = math.clamp(math.round(currentPriorityVal), 1, 1000)
        else
            currentPriorityVal = math.clamp(math.round(currentPriorityVal), 1, 100)
        end

        local titleName = "Item"
        local badgeCol = Color3.fromRGB(50, 130, 240)
        if targetType == "Task" then
            titleName = tostring(itemObj.name or itemObj.id or "Task")
            badgeCol = Color3.fromRGB(50, 130, 240)
        elseif targetType == "Loop" then
            titleName = tostring(itemObj.caller or itemObj.name or "Loop")
            badgeCol = Color3.fromRGB(40, 190, 210)
        elseif targetType == "Startup" then
            local fn = itemObj.file:match("[^/\\]+$") or itemObj.file
            titleName = fn:gsub("%.lua$", ""):gsub("%.txt$", "")
            badgeCol = STAGE_COLORS[itemObj.stage or "GameLoaded"] or Color3.fromRGB(160, 70, 220)
        end

        PM.TargetBadge.Text = targetType:upper()
        PM.TargetBadge.TextColor3 = badgeCol
        PM.TargetBadge.BackgroundColor3 = Color3.fromRGB(math.floor(badgeCol.R * 40), math.floor(badgeCol.G * 40), math.floor(badgeCol.B * 40))
        PM.TargetName.Text = titleName
        PM.PriBox.Text = tostring(currentPriorityVal)

        for _, ch in ipairs(PM.PresetsContainer:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end

        local presets = {}
        if targetType == "Startup" then
            presets = {
                { name = "1000 Max", val = 1000 },
                { name = "500 High", val = 500 },
                { name = "100 Med", val = 100 },
                { name = "50 Low", val = 50 },
                { name = "10 Min", val = 10 },
            }
        else
            presets = {
                { name = "100 Max", val = 100 },
                { name = "80 High", val = 80 },
                { name = "50 Med", val = 50 },
                { name = "25 Low", val = 25 },
                { name = "10 Min", val = 10 },
            }
        end

        for _, p in ipairs(presets) do
            local pBtn = Instance.new("TextButton")
            pBtn.Name = "Preset_" .. tostring(p.val)
            pBtn.Size = UDim2.new(0, 58, 0, 22)
            pBtn.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
            pBtn.BorderSizePixel = 0
            pBtn.Font = Enum.Font.GothamMedium
            pBtn.TextSize = 9
            pBtn.TextColor3 = Color3.fromRGB(160, 185, 215)
            pBtn.Text = p.name
            pBtn.ZIndex = 523
            pBtn.Parent = PM.PresetsContainer
            local pc = Instance.new("UICorner")
            pc.CornerRadius = UDim.new(0, 3)
            pc.Parent = pBtn

            local ps = Instance.new("UIStroke")
            ps.Thickness = 1
            ps.Color = Color3.fromRGB(45, 60, 85)
            ps.Parent = pBtn

            pBtn.MouseEnter:Connect(function()
                pBtn.BackgroundColor3 = Color3.fromRGB(35, 50, 75)
                ps.Color = Color3.fromRGB(80, 130, 200)
            end)
            pBtn.MouseLeave:Connect(function()
                pBtn.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
                ps.Color = Color3.fromRGB(45, 60, 85)
            end)

            pBtn.MouseButton1Click:Connect(function()
                currentPriorityVal = p.val
                PM.PriBox.Text = tostring(p.val)
            end)
        end

        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
        PM.Modal.Visible = true
        task.defer(function()
            PM.PriBox:CaptureFocus()
        end)
    end
end

local function isScriptGameSpecific(filePath)
    local lower = normStartupPath(filePath):lower()
    local placeIdStr = tostring(game.PlaceId)
    return (lower:find("/" .. placeIdStr) ~= nil or lower:find("^" .. placeIdStr) ~= nil or lower:find("autoexec/" .. placeIdStr) ~= nil)
end

local function toggleScriptScope(scriptObj)
    if scriptObj.stage == "Kernel" then
        return false, "Kernel scripts cannot change scope"
    end
    local oldPath = normStartupPath(scriptObj.file)
    local fullOld = oldPath
    if not isfile(fullOld) and isfile("workspace/" .. fullOld) then
        fullOld = "workspace/" .. fullOld
    end
    if not isfile(fullOld) then return false, "File not found: " .. oldPath end

    local placeIdStr = tostring(game.PlaceId)
    local isSpecific = isScriptGameSpecific(oldPath)
    local newPath

    if isSpecific then
        local afterPlace = oldPath:gsub("^autoexec/[^/]+/", "autoexec/")
        if afterPlace == oldPath then
            afterPlace = oldPath:gsub("^[^/]+/", "")
            if not afterPlace:match("^autoexec/") then
                afterPlace = "autoexec/" .. afterPlace
            end
        end
        newPath = afterPlace
    else
        local targetPlaceFolder = nil
        pcall(function()
            if listfiles and isfolder and isfolder("autoexec") then
                for _, f in ipairs(listfiles("autoexec")) do
                    local fn = f:match("[^/\\]+$") or f
                    if isfolder(f) and fn:find(placeIdStr) then
                        targetPlaceFolder = normStartupPath(f)
                        break
                    end
                end
            end
        end)
        if not targetPlaceFolder then
            local placeName = "Place"
            pcall(function()
                local mps = game:GetService("MarketplaceService")
                local info = mps:GetProductInfo(game.PlaceId)
                if info and info.Name then
                    placeName = info.Name:gsub("[^%w%s%-_]", ""):gsub("^%s+", ""):gsub("%s+$", "")
                end
            end)
            targetPlaceFolder = "autoexec/" .. placeIdStr .. " - " .. placeName
        end

        local rel = oldPath:gsub("^autoexec/", "")
        newPath = targetPlaceFolder .. "/" .. rel
    end

    local parentDir = newPath:match("^(.*)/[^/]+$")
    if parentDir and makefolder and not isfolder(parentDir) then
        pcall(makefolder, parentDir)
    end

    local ok, content = pcall(readfile, fullOld)
    if not ok or not content then return false, "Read failed" end

    local writeOk = pcall(writefile, newPath, content)
    if not writeOk then return false, "Write failed" end

    pcall(delfile, fullOld)
    scriptObj.file = newPath

    return true, newPath
end

local function toggleRowAccordion(targetRow, fileKey, forceState)
    if not targetRow or not targetRow.Parent then return end
    local panel = targetRow:FindFirstChild("AccordionPanel")
    if not panel then return end

    local isCurrentlyOpen = (targetRow.Size.Y.Offset > 32)
    local shouldOpen = if forceState ~= nil then forceState else not isCurrentlyOpen

    if shouldOpen and activeExpandedRowKey and activeExpandedRowKey ~= fileKey then
        local prevRow = cachedStartupRows[activeExpandedRowKey]
        if prevRow and prevRow.Parent then
            toggleRowAccordion(prevRow, activeExpandedRowKey, false)
        end
    end

    if shouldOpen then
        activeExpandedRowKey = fileKey
        panel.Visible = true
        local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local t = TweenService:Create(targetRow, tweenInfo, { Size = UDim2.new(1, 0, 0, 68) })
        t:Play()
    else
        if activeExpandedRowKey == fileKey then
            activeExpandedRowKey = nil
        end
        local tweenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local t = TweenService:Create(targetRow, tweenInfo, { Size = UDim2.new(1, 0, 0, 32) })
        t:Play()
        t.Completed:Connect(function()
            if targetRow and targetRow.Parent and targetRow.Size.Y.Offset <= 32 then
                panel.Visible = false
            end
        end)
    end
end

-- Register Drag Movement & Drop Handlers
table.insert(hudWindowConnections, UserInputService.InputChanged:Connect(function(input)
    if not ScreenGui.Enabled then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end

    if currentTab == "Startup" then
        if pendingStartupDrag and not isDraggingStartupRow then
            if (input.Position - pendingStartupDrag.startPos).Magnitude >= 6 then
                local sortCol = TableSortState.Startup and TableSortState.Startup.colId or "Priority"
                if sortCol ~= "Priority" then
                    pendingStartupDrag = nil
                    showTableNotice("Manual reordering is locked while sorted by " .. tostring(sortCol) .. ". Switch to PRIORITY to reorder.", true, "Startup")
                    return
                end
                isDraggingStartupRow = true
                activeStartupDrag = pendingStartupDrag
                pendingStartupDrag = nil
                if activeStartupDrag.row then
                    activeStartupDrag.row.BackgroundTransparency = 0.65
                    if activeExpandedRowKey then
                        local expRow = cachedStartupRows[activeExpandedRowKey]
                        if expRow then
                            toggleRowAccordion(expRow, activeExpandedRowKey, false)
                        end
                    end
                end

                StartupDragGhost.Visible = true
                ghostName.Text = activeStartupDrag.script.name or "Script"
                ghostDot.BackgroundColor3 = (activeStartupDrag.script.enabled ~= false) and Color3.fromRGB(50, 220, 120) or Color3.fromRGB(100, 110, 125)
                local st = activeStartupDrag.script.stage or "GameLoaded"
                ghostBadge.Text = st:upper()
                local sc = STAGE_COLORS[st] or Color3.fromRGB(50, 130, 240)
                ghostBadge.TextColor3 = sc
                ghostBadge.BackgroundColor3 = Color3.fromRGB(math.floor(sc.R * 40), math.floor(sc.G * 40), math.floor(sc.B * 40))

                StartupDropIndicator.Visible = true
            end
        end

        if isDraggingStartupRow and activeStartupDrag then
            local mfPos = MainFrame.AbsolutePosition
            StartupDragGhost.Position = UDim2.new(0, input.Position.X - mfPos.X - 175, 0, input.Position.Y - mfPos.Y - 16)

            local allScripts = scanStartupScripts()
            local filtered = {}
            local numKernel = 0
            for _, s in ipairs(allScripts) do
                if s.file:lower() ~= activeStartupDrag.script.file:lower() then
                    table.insert(filtered, s)
                    if s.stage == "Kernel" then
                        numKernel = numKernel + 1
                    end
                end
            end

            local totalFiltered = #filtered
            local minSlot = numKernel + 1
            local chosenSlot = minSlot
            local chosenStage = "PreInit"
            local mouseY = input.Position.Y

            if totalFiltered > 0 and totalFiltered >= minSlot then
                local foundSlot = false
                for i = minSlot, totalFiltered do
                    local s = filtered[i]
                    local r = cachedStartupRows[s.file]
                    if r and r.Visible then
                        local rCenter = r.AbsolutePosition.Y + (r.AbsoluteSize.Y / 2)
                        if mouseY < rCenter then
                            chosenSlot = i
                            foundSlot = true
                            break
                        end
                    end
                end
                if not foundSlot then
                    chosenSlot = totalFiltered + 1
                end
            else
                chosenSlot = minSlot
            end

            chosenSlot = math.clamp(chosenSlot, minSlot, totalFiltered + 1)
            targetDropIndex = chosenSlot

            -- Stage boundary detection & inference
            local pred = (chosenSlot > 1) and filtered[chosenSlot - 1] or nil
            local succ = (chosenSlot <= totalFiltered) and filtered[chosenSlot] or nil

            if pred and succ then
                if pred.stage == succ.stage then
                    chosenStage = (pred.stage == "Kernel") and "PreInit" or pred.stage
                else
                    -- Stage Boundary (e.g. pred is PreInit, succ is GameLoaded)
                    local rPred = cachedStartupRows[pred.file]
                    local rSucc = cachedStartupRows[succ.file]
                    local predBottom = (rPred and rPred.Visible) and (rPred.AbsolutePosition.Y + rPred.AbsoluteSize.Y) or mouseY
                    local succTop = (rSucc and rSucc.Visible) and rSucc.AbsolutePosition.Y or mouseY
                    local midY = (predBottom + succTop) / 2
                    if mouseY <= midY then
                        -- Top half of boundary: bottom of PreInit
                        chosenStage = (pred.stage == "Kernel") and "PreInit" or pred.stage
                    else
                        -- Bottom half of boundary: top of GameLoaded
                        chosenStage = succ.stage
                    end
                end
            elseif pred and not succ then
                chosenStage = (pred.stage == "Kernel") and "PreInit" or pred.stage
            elseif succ and not pred then
                chosenStage = (succ.stage == "Kernel") and "PreInit" or succ.stage
            else
                chosenStage = "PreInit"
            end

            targetDropStage = chosenStage

            -- Dynamic ghost badge live preview
            ghostBadge.Text = targetDropStage:upper()
            local c = STAGE_COLORS[targetDropStage] or Color3.fromRGB(50, 130, 240)
            ghostBadge.TextColor3 = c
            ghostBadge.BackgroundColor3 = Color3.fromRGB(math.floor(c.R * 40), math.floor(c.G * 40), math.floor(c.B * 40))

            -- Visual position of drop indicator via LayoutOrder
            StartupDropIndicator.LayoutOrder = chosenSlot * 10 - 5
        end

    elseif currentTab == "Tasks" then
        if TaskDrag.pending and not TaskDrag.isDragging then
            if (input.Position - TaskDrag.pending.startPos).Magnitude >= 6 then
                local sortCol = TableSortState.Tasks and TableSortState.Tasks.colId or "Priority"
                if sortCol ~= "Priority" then
                    TaskDrag.pending = nil
                    showTableNotice("Manual reordering is locked while sorted by " .. tostring(sortCol) .. ". Switch to PRIORITY to reorder.", true, "Tasks")
                    return
                end
                TaskDrag.isDragging = true
                TaskDrag.active = TaskDrag.pending
                TaskDrag.pending = nil
                if TaskDrag.active.row then
                    TaskDrag.active.row.BackgroundTransparency = 0.65
                end

                StartupDragGhost.Visible = true
                local tObj = TaskDrag.active.task
                ghostName.Text = tostring(tObj.name or tObj.id or "Task")
                ghostDot.BackgroundColor3 = tObj.paused and Color3.fromRGB(120, 130, 150) or Color3.fromRGB(50, 220, 120)
                local ev = tostring(tObj.event or "Heartbeat")
                ghostBadge.Text = ev:upper()
                ghostBadge.TextColor3 = Color3.fromRGB(100, 190, 255)
                ghostBadge.BackgroundColor3 = Color3.fromRGB(20, 40, 65)

                TaskDrag.indicator.Visible = true
            end
        end

        if TaskDrag.isDragging and TaskDrag.active then
            local mfPos = MainFrame.AbsolutePosition
            StartupDragGhost.Position = UDim2.new(0, input.Position.X - mfPos.X - 175, 0, input.Position.Y - mfPos.Y - 16)

            local profile = (getgenv().GetSchedulerProfile and getgenv().GetSchedulerProfile()) or {}
            local allTasks = profile.tasks or {}
            local filtered = {}
            for _, t in ipairs(allTasks) do
                if t.id ~= TaskDrag.active.task.id then
                    table.insert(filtered, t)
                end
            end

            local totalFiltered = #filtered
            local chosenSlot = 1
            local mouseY = input.Position.Y

            if totalFiltered > 0 then
                local foundSlot = false
                for i = 1, totalFiltered do
                    local t = filtered[i]
                    local r = cachedTaskRows[t.id]
                    if r and r.Visible then
                        local rCenter = r.AbsolutePosition.Y + (r.AbsoluteSize.Y / 2)
                        if mouseY < rCenter then
                            chosenSlot = i
                            foundSlot = true
                            break
                        end
                    end
                end
                if not foundSlot then
                    chosenSlot = totalFiltered + 1
                end
            end

            chosenSlot = math.clamp(chosenSlot, 1, totalFiltered + 1)
            TaskDrag.targetIndex = chosenSlot

            TaskDrag.indicator.LayoutOrder = chosenSlot * 10 - 5
        end

    elseif currentTab == "Loops" then
        if LoopDrag.pending and not LoopDrag.isDragging then
            if (input.Position - LoopDrag.pending.startPos).Magnitude >= 6 then
                local sortCol = TableSortState.Loops and TableSortState.Loops.colId or "Priority"
                if sortCol ~= "Priority" then
                    LoopDrag.pending = nil
                    showTableNotice("Manual reordering is locked while sorted by " .. tostring(sortCol) .. ". Switch to PRIORITY to reorder.", true, "Loops")
                    return
                end
                LoopDrag.isDragging = true
                LoopDrag.active = LoopDrag.pending
                LoopDrag.pending = nil
                if LoopDrag.active.row then
                    LoopDrag.active.row.BackgroundTransparency = 0.65
                end

                StartupDragGhost.Visible = true
                local lObj = LoopDrag.active.loop
                ghostName.Text = tostring(lObj.caller or lObj.name or "Loop")
                ghostDot.BackgroundColor3 = lObj.paused and Color3.fromRGB(255, 160, 40) or Color3.fromRGB(50, 220, 120)
                local srcBadge = (lObj.isExecutor ~= false) and "EXECUTOR" or "GAME"
                ghostBadge.Text = srcBadge
                ghostBadge.TextColor3 = (lObj.isExecutor ~= false) and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(100, 190, 255)
                ghostBadge.BackgroundColor3 = Color3.fromRGB(20, 40, 65)

                LoopDrag.indicator.Visible = true
            end
        end

        if LoopDrag.isDragging and LoopDrag.active then
            local mfPos = MainFrame.AbsolutePosition
            StartupDragGhost.Position = UDim2.new(0, input.Position.X - mfPos.X - 175, 0, input.Position.Y - mfPos.Y - 16)

            local profile = (getgenv().GetLoopProfile and getgenv().GetLoopProfile()) or {}
            local allLoops = profile.loops or {}
            local filtered = {}
            for _, l in ipairs(allLoops) do
                if l.id ~= LoopDrag.active.loop.id then
                    table.insert(filtered, l)
                end
            end

            local totalFiltered = #filtered
            local chosenSlot = 1
            local mouseY = input.Position.Y

            if totalFiltered > 0 then
                local foundSlot = false
                for i = 1, totalFiltered do
                    local l = filtered[i]
                    local r = cachedLoopRows[l.id]
                    if r and r.Visible then
                        local rCenter = r.AbsolutePosition.Y + (r.AbsoluteSize.Y / 2)
                        if mouseY < rCenter then
                            chosenSlot = i
                            foundSlot = true
                            break
                        end
                    end
                end
                if not foundSlot then
                    chosenSlot = totalFiltered + 1
                end
            end

            chosenSlot = math.clamp(chosenSlot, 1, totalFiltered + 1)
            LoopDrag.targetIndex = chosenSlot

            LoopDrag.indicator.LayoutOrder = chosenSlot * 10 - 5
        end
    end
end))

table.insert(hudWindowConnections, UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    pendingStartupDrag = nil
    TaskDrag.pending = nil
    LoopDrag.pending = nil

    if isDraggingStartupRow and activeStartupDrag then
        isDraggingStartupRow = false
        StartupDragGhost.Visible = false
        StartupDropIndicator.Visible = false
        if activeStartupDrag.row then
            activeStartupDrag.row.BackgroundTransparency = 0
        end

        local draggedScript = activeStartupDrag.script
        local newStage = targetDropStage or draggedScript.stage or "GameLoaded"
        draggedScript.stage = newStage

        local allScripts = scanStartupScripts(true)
        local remaining = {}
        for _, s in ipairs(allScripts) do
            if s.file:lower() ~= draggedScript.file:lower() then
                table.insert(remaining, s)
            end
        end

        local kernelList = {}
        local preinitList = {}
        local gameloadedList = {}
        local otherList = {}

        for _, s in ipairs(remaining) do
            if s.stage == "Kernel" then
                table.insert(kernelList, s)
            elseif s.stage == "PreInit" then
                table.insert(preinitList, s)
            elseif s.stage == "GameLoaded" then
                table.insert(gameloadedList, s)
            else
                table.insert(otherList, s)
            end
        end

        if newStage == "PreInit" then
            local slotInPre = (targetDropIndex or (#kernelList + 1)) - #kernelList
            slotInPre = math.clamp(slotInPre, 1, #preinitList + 1)
            table.insert(preinitList, slotInPre, draggedScript)
        elseif newStage == "GameLoaded" then
            local offset = #kernelList + #preinitList
            local slotInGame = (targetDropIndex or (offset + 1)) - offset
            slotInGame = math.clamp(slotInGame, 1, #gameloadedList + 1)
            table.insert(gameloadedList, slotInGame, draggedScript)
        else
            table.insert(otherList, draggedScript)
        end

        -- Recalculate descending priorities for PreInit (200-300 range)
        local basePre = math.max(250, 200 + #preinitList * 10)
        for i, s in ipairs(preinitList) do
            local assignedPri = basePre - (i - 1) * 10
            s.priority = assignedPri
            s.stage = "PreInit"
            updateScriptPragmas(s.file, "PreInit", assignedPri)
        end

        -- Recalculate descending priorities for GameLoaded (10-150 range)
        local baseGame = math.max(100, #gameloadedList * 10)
        for i, s in ipairs(gameloadedList) do
            local assignedPri = baseGame - (i - 1) * 10
            s.priority = assignedPri
            s.stage = "GameLoaded"
            updateScriptPragmas(s.file, "GameLoaded", assignedPri)
        end

        TableSortState.Startup.colId = "Priority"
        TableSortState.Startup.ascending = false
        updateHeaderSortIndicators("Startup")

        for k, r in pairs(cachedStartupRows) do
            r:Destroy()
            cachedStartupRows[k] = nil
        end
        if refreshStartupTab then
            refreshStartupTab(true)
        end

        activeStartupDrag = nil
        targetDropIndex = nil
        targetDropStage = nil
    end

    if TaskDrag.isDragging and TaskDrag.active then
        TaskDrag.isDragging = false
        StartupDragGhost.Visible = false
        TaskDrag.indicator.Visible = false
        if TaskDrag.active.row then
            TaskDrag.active.row.BackgroundTransparency = 0
        end

        local draggedTask = TaskDrag.active.task
        local targetSlot = TaskDrag.targetIndex
        TaskDrag.active = nil
        TaskDrag.targetIndex = nil

        pcall(function()
            local profile = (getgenv().GetSchedulerProfile and getgenv().GetSchedulerProfile()) or {}
            local allTasks = profile.tasks or {}
            local remaining = {}
            for _, t in ipairs(allTasks) do
                if t.id ~= draggedTask.id then
                    table.insert(remaining, t)
                end
            end

            local slot = math.clamp(targetSlot or (#remaining + 1), 1, #remaining + 1)
            table.insert(remaining, slot, draggedTask)

            local totalTasks = #remaining
            local basePri = 100
            local minPri = 10
            local step = (totalTasks > 1) and ((basePri - minPri) / (totalTasks - 1)) or 0

            for i, t in ipairs(remaining) do
                local assignedPri = math.clamp(math.round(basePri - (i - 1) * step), 5, 100)
                t.priority = assignedPri
                t.sortOrder = i
                local taskObj = findTask(t.id)
                if taskObj then
                    taskObj.sortOrder = i
                    taskObj.priority = assignedPri
                end
                local r = cachedTaskRows[t.id]
                if r then
                    r.LayoutOrder = i * 10
                end
                if getgenv().SetSchedulerTaskPriority then
                    getgenv().SetSchedulerTaskPriority(t.id, assignedPri, i)
                end
            end

            TableSortState.Tasks.colId = "Priority"
            TableSortState.Tasks.ascending = false
            updateHeaderSortIndicators("Tasks")

            saveSchedulerOverrides(true)
            emitProfile()
        end)
    end

    if LoopDrag.isDragging and LoopDrag.active then
        LoopDrag.isDragging = false
        StartupDragGhost.Visible = false
        LoopDrag.indicator.Visible = false
        if LoopDrag.active.row then
            LoopDrag.active.row.BackgroundTransparency = 0
        end

        local draggedLoop = LoopDrag.active.loop
        local targetSlot = LoopDrag.targetIndex
        LoopDrag.active = nil
        LoopDrag.targetIndex = nil

        pcall(function()
            local profile = (getgenv().GetLoopProfile and getgenv().GetLoopProfile()) or {}
            local allLoops = profile.loops or {}
            local remaining = {}
            for _, l in ipairs(allLoops) do
                if l.id ~= draggedLoop.id then
                    table.insert(remaining, l)
                end
            end

            local slot = math.clamp(targetSlot or (#remaining + 1), 1, #remaining + 1)
            table.insert(remaining, slot, draggedLoop)

            local totalLoops = #remaining
            local basePri = 100
            local minPri = 10
            local step = (totalLoops > 1) and ((basePri - minPri) / (totalLoops - 1)) or 0

            for i, l in ipairs(remaining) do
                local assignedPri = math.clamp(math.round(basePri - (i - 1) * step), 5, 100)
                l.priority = assignedPri
                l.sortOrder = i
                for _, loop in pairs(loopRegistry) do
                    if loop.id == l.id then
                        loop.sortOrder = i
                        loop.priority = assignedPri
                        break
                    end
                end
                local r = cachedLoopRows[l.id]
                if r then
                    r.LayoutOrder = i * 10
                end
                if getgenv().SetLoopPriority then
                    getgenv().SetLoopPriority(l.id, assignedPri, i)
                end
            end

            TableSortState.Loops.colId = "Priority"
            TableSortState.Loops.ascending = false
            updateHeaderSortIndicators("Loops")

            saveSchedulerOverrides(true)
            emitProfile()
        end)
    end
end))

local function renderStartupRow(scriptObj, idx)
    local key = scriptObj.file
    local row = cachedStartupRows[key]
    if not row then
        row = Instance.new("Frame")
        row.Name = key
        row.Size = (activeExpandedRowKey == key) and UDim2.new(1, 0, 0, 68) or UDim2.new(1, 0, 0, 32)
        row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)
        row.BorderSizePixel = 0
        row.LayoutOrder = idx * 10
        row.Active = true
        row.ClipsDescendants = true
        row.Parent = ScrollListStartup

        local rCorner = Instance.new("UICorner")
        rCorner.CornerRadius = UDim.new(0, 4)
        rCorner.Parent = row

        local isPriSort = TableSortState.Startup and TableSortState.Startup.colId == "Priority"
        local gripLbl = Instance.new("TextLabel")
        gripLbl.Name = "GripLbl"
        gripLbl.Size = UDim2.new(0, 12, 0, 16)
        gripLbl.Position = UDim2.new(0, 4, 0, 8)
        gripLbl.BackgroundTransparency = 1
        gripLbl.Font = Enum.Font.GothamBold
        gripLbl.TextSize = 12
        gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
        gripLbl.Text = ICONS.GRIP
        gripLbl.Parent = row

        local dot = Instance.new("Frame")
        dot.Name = "Dot"
        dot.Size = UDim2.new(0, 8, 0, 8)
        dot.Position = UDim2.new(0.02, 10, 0, 12)
        dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120)
        dot.BorderSizePixel = 0
        dot.Parent = row
        local dotCorner = Instance.new("UICorner")
        dotCorner.CornerRadius = UDim.new(1, 0)
        dotCorner.Parent = dot

        local priLbl = Instance.new("TextButton")
        priLbl.Name = "PriLbl"
        priLbl.Size = UDim2.new(0, 34, 0, 18)
        priLbl.Position = UDim2.new(0.02, 22, 0, 7)
        priLbl.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
        priLbl.BorderSizePixel = 0
        priLbl.AutoButtonColor = false
        priLbl.Font = Enum.Font.GothamBold
        priLbl.TextSize = 10
        priLbl.TextColor3 = Color3.fromRGB(210, 230, 255)
        priLbl.TextXAlignment = Enum.TextXAlignment.Center
        priLbl.Text = tostring(scriptObj.priority or 100)
        priLbl.Parent = row
        local priCorner = Instance.new("UICorner")
        priCorner.CornerRadius = UDim.new(0, 3)
        priCorner.Parent = priLbl
        local priStroke = Instance.new("UIStroke")
        priStroke.Thickness = 1
        priStroke.Color = Color3.fromRGB(45, 60, 85)
        priStroke.Parent = priLbl

        priLbl.MouseEnter:Connect(function()
            priLbl.BackgroundColor3 = Color3.fromRGB(38, 52, 75)
            priStroke.Color = Color3.fromRGB(80, 130, 200)
        end)
        priLbl.MouseLeave:Connect(function()
            priLbl.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
            priStroke.Color = Color3.fromRGB(45, 60, 85)
        end)
        priLbl.MouseButton1Click:Connect(function()
            if openPriorityEditModal then
                openPriorityEditModal("Startup", scriptObj, scriptObj.priority or 100)
            end
        end)

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Name = "NameLbl"
        nameLbl.Size = UDim2.new(0.40, 0, 0, 15)
        nameLbl.Position = UDim2.new(0.12, 0, 0, 2)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamMedium
        nameLbl.TextSize = 11
        nameLbl.TextColor3 = Color3.fromRGB(225, 235, 250)
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Active = false
        nameLbl.Parent = row

        local pathLbl = Instance.new("TextLabel")
        pathLbl.Name = "PathLbl"
        pathLbl.Size = UDim2.new(0.40, 0, 0, 12)
        pathLbl.Position = UDim2.new(0.12, 0, 0, 17)
        pathLbl.BackgroundTransparency = 1
        pathLbl.Font = Enum.Font.Gotham
        pathLbl.TextSize = 9
        pathLbl.TextColor3 = Color3.fromRGB(110, 125, 150)
        pathLbl.TextXAlignment = Enum.TextXAlignment.Left
        pathLbl.TextTruncate = Enum.TextTruncate.AtEnd
        pathLbl.Active = false
        pathLbl.Parent = row

        local stageBadge = Instance.new("TextButton")
        stageBadge.Name = "StageBadge"
        stageBadge.Size = UDim2.new(0, 80, 0, 18)
        stageBadge.Position = UDim2.new(0.53, 0, 0, 7)
        stageBadge.BackgroundColor3 = Color3.fromRGB(25, 35, 55)
        stageBadge.BorderSizePixel = 0
        stageBadge.AutoButtonColor = false
        stageBadge.Font = Enum.Font.GothamBold
        stageBadge.TextSize = 9
        stageBadge.TextColor3 = Color3.fromRGB(100, 180, 255)
        stageBadge.Parent = row
        local stageCorner = Instance.new("UICorner")
        stageCorner.CornerRadius = UDim.new(0, 3)
        stageCorner.Parent = stageBadge

        stageBadge.MouseEnter:Connect(function()
            local bInfo = currentStartupBoundaries[scriptObj.file:lower()]
            if not (bInfo and bInfo.canToggle) then return end
            startupBadgeHovered[scriptObj.file:lower()] = true
            local c = STAGE_COLORS[scriptObj.stage or "GameLoaded"] or Color3.fromRGB(50, 130, 240)
            stageBadge.BackgroundColor3 = Color3.fromRGB(math.min(255, math.floor(c.R * 70)), math.min(255, math.floor(c.G * 70)), math.min(255, math.floor(c.B * 70)))
        end)
        stageBadge.MouseLeave:Connect(function()
            startupBadgeHovered[scriptObj.file:lower()] = nil
            local c = STAGE_COLORS[scriptObj.stage or "GameLoaded"] or Color3.fromRGB(50, 130, 240)
            stageBadge.BackgroundColor3 = Color3.fromRGB(math.floor(c.R * 40), math.floor(c.G * 40), math.floor(c.B * 40))
        end)

        stageBadge.MouseButton1Click:Connect(function()
            local bInfo = currentStartupBoundaries[scriptObj.file:lower()]
            if not (bInfo and bInfo.canToggle) then
                return
            end

            local targetStage = bInfo.toggleTarget
            local targetPos = bInfo.targetPosition
            if not targetStage then return end

            local allScripts = scanStartupScripts(true)
            local remaining = {}
            for _, s in ipairs(allScripts) do
                if s.file:lower() ~= scriptObj.file:lower() then
                    table.insert(remaining, s)
                end
            end

            local kernelList = {}
            local preinitList = {}
            local gameloadedList = {}
            local otherList = {}

            for _, s in ipairs(remaining) do
                if s.stage == "Kernel" then
                    table.insert(kernelList, s)
                elseif s.stage == "PreInit" then
                    table.insert(preinitList, s)
                elseif s.stage == "GameLoaded" then
                    table.insert(gameloadedList, s)
                else
                    table.insert(otherList, s)
                end
            end

            scriptObj.stage = targetStage

            if targetStage == "Kernel" then
                if targetPos == "TOP" then
                    table.insert(kernelList, 1, scriptObj)
                else
                    table.insert(kernelList, scriptObj)
                end
            elseif targetStage == "PreInit" then
                if targetPos == "TOP" then
                    table.insert(preinitList, 1, scriptObj)
                else
                    table.insert(preinitList, scriptObj)
                end
            elseif targetStage == "GameLoaded" then
                if targetPos == "TOP" then
                    table.insert(gameloadedList, 1, scriptObj)
                else
                    table.insert(gameloadedList, scriptObj)
                end
            else
                table.insert(otherList, scriptObj)
            end

            -- Recalculate descending priorities for Kernel
            local kernelPri = 1000
            for i, s in ipairs(kernelList) do
                if s.file:lower():find("kerneltaskmanager") then
                    s.priority = 1000
                    s.stage = "Kernel"
                    updateScriptPragmas(s.file, "Kernel", 1000)
                else
                    kernelPri = kernelPri - 10
                    s.priority = kernelPri
                    s.stage = "Kernel"
                    updateScriptPragmas(s.file, "Kernel", kernelPri)
                end
            end

            -- Recalculate descending priorities for PreInit (200-300 range)
            local basePre = math.max(250, 200 + #preinitList * 10)
            for i, s in ipairs(preinitList) do
                local assignedPri = basePre - (i - 1) * 10
                s.priority = assignedPri
                s.stage = "PreInit"
                updateScriptPragmas(s.file, "PreInit", assignedPri)
            end

            -- Recalculate descending priorities for GameLoaded (10-150 range)
            local baseGame = math.max(100, #gameloadedList * 10)
            for i, s in ipairs(gameloadedList) do
                local assignedPri = baseGame - (i - 1) * 10
                s.priority = assignedPri
                s.stage = "GameLoaded"
                updateScriptPragmas(s.file, "GameLoaded", assignedPri)
            end

            startupBadgeHovered[scriptObj.file:lower()] = nil

            for k, r in pairs(cachedStartupRows) do
                r:Destroy()
                cachedStartupRows[k] = nil
            end
            if refreshStartupTab then
                refreshStartupTab(true)
            end
        end)

        local timeLbl = Instance.new("TextLabel")
        timeLbl.Name = "TimeLbl"
        timeLbl.Size = UDim2.new(0.14, 0, 0, 32)
        timeLbl.Position = UDim2.new(0.70, 0, 0, 0)
        timeLbl.BackgroundTransparency = 1
        timeLbl.Font = Enum.Font.Gotham
        timeLbl.TextSize = 10
        timeLbl.TextColor3 = Color3.fromRGB(180, 195, 220)
        timeLbl.TextXAlignment = Enum.TextXAlignment.Right
        timeLbl.Parent = row

        local toggleBtn = Instance.new("TextButton")
        toggleBtn.Name = "ToggleBtn"
        toggleBtn.Size = UDim2.new(0, 64, 0, 20)
        toggleBtn.Position = UDim2.new(0.86, 0, 0, 6)
        toggleBtn.BackgroundColor3 = Color3.fromRGB(25, 50, 35)
        toggleBtn.BorderSizePixel = 0
        toggleBtn.Font = Enum.Font.GothamBold
        toggleBtn.TextSize = 9
        toggleBtn.TextColor3 = Color3.fromRGB(100, 240, 150)
        toggleBtn.Text = ICONS.DOT_GREEN .. " ON"
        toggleBtn.Parent = row
        local toggleCorner = Instance.new("UICorner")
        toggleCorner.CornerRadius = UDim.new(0, 3)
        toggleCorner.Parent = toggleBtn

        toggleBtn.MouseButton1Click:Connect(function()
            toggleBtn.Text = ICONS.HOURGLASS .. "..."
            local ok, newDisabledState, newPath = toggleStartupScript(scriptObj.file)
            if ok then
                scriptObj.enabled = not newDisabledState
                if newPath then
                    scriptObj.file = newPath
                end
                toggleBtn.Text = scriptObj.enabled and (ICONS.DOT_GREEN .. " ON") or (ICONS.DOT_WHITE .. " OFF")
                toggleBtn.BackgroundColor3 = scriptObj.enabled and Color3.fromRGB(25, 50, 35) or Color3.fromRGB(45, 30, 30)
                toggleBtn.TextColor3 = scriptObj.enabled and Color3.fromRGB(100, 240, 150) or Color3.fromRGB(240, 120, 120)
                dot.BackgroundColor3 = scriptObj.enabled and Color3.fromRGB(50, 220, 120) or Color3.fromRGB(100, 110, 125)
                nameLbl.TextColor3 = scriptObj.enabled and Color3.fromRGB(225, 235, 250) or Color3.fromRGB(130, 140, 155)
                pathLbl.Text = scriptObj.file
                timeLbl.Text = scriptObj.enabled and "Ready" or "Disabled"
                timeLbl.TextColor3 = Color3.fromRGB(110, 125, 150)
                scanStartupScripts(true)
            else
                toggleBtn.Text = "ERR"
                task.delay(1.5, function()
                    if toggleBtn then
                        toggleBtn.Text = scriptObj.enabled and (ICONS.DOT_GREEN .. " ON") or (ICONS.DOT_WHITE .. " OFF")
                    end
                end)
            end
        end)

        -- Accordion Panel (revealed on right-click)
        local accordion = Instance.new("Frame")
        accordion.Name = "AccordionPanel"
        accordion.Size = UDim2.new(1, 0, 0, 36)
        accordion.Position = UDim2.new(0, 0, 0, 32)
        accordion.BackgroundColor3 = Color3.fromRGB(14, 17, 24)
        accordion.BackgroundTransparency = 0.35
        accordion.BorderSizePixel = 0
        accordion.ClipsDescendants = true
        accordion.Visible = (activeExpandedRowKey == key)
        accordion.Parent = row

        local accCorner = Instance.new("UICorner")
        accCorner.CornerRadius = UDim.new(0, 4)
        accCorner.Parent = accordion

        local div = Instance.new("Frame")
        div.Name = "Divider"
        div.Size = UDim2.new(1, -16, 0, 1)
        div.Position = UDim2.new(0, 8, 0, 0)
        div.BackgroundColor3 = Color3.fromRGB(208, 217, 251)
        div.BackgroundTransparency = 0.88
        div.BorderSizePixel = 0
        div.Parent = accordion

        local btnContainer = Instance.new("Frame")
        btnContainer.Name = "BtnContainer"
        btnContainer.Size = UDim2.new(1, -16, 1, -4)
        btnContainer.Position = UDim2.new(0, 8, 0, 3)
        btnContainer.BackgroundTransparency = 1
        btnContainer.BorderSizePixel = 0
        btnContainer.Parent = accordion

        local btnLayout = Instance.new("UIListLayout")
        btnLayout.FillDirection = Enum.FillDirection.Horizontal
        btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        btnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        btnLayout.Padding = UDim.new(0, 8)
        btnLayout.SortOrder = Enum.SortOrder.LayoutOrder
        btnLayout.Parent = btnContainer

        -- 1. Scope Pill Button
        local scopeBtn = Instance.new("TextButton")
        scopeBtn.Name = "ScopeBtn"
        scopeBtn.Size = UDim2.new(0, 180, 0, 24)
        scopeBtn.BackgroundColor3 = Color3.fromRGB(26, 34, 48)
        scopeBtn.AutoButtonColor = false
        scopeBtn.Font = Enum.Font.GothamMedium
        scopeBtn.TextSize = 10
        scopeBtn.TextColor3 = Color3.fromRGB(190, 220, 255)
        scopeBtn.LayoutOrder = 1
        scopeBtn.Parent = btnContainer

        local scopeCorner = Instance.new("UICorner")
        scopeCorner.CornerRadius = UDim.new(0, 5)
        scopeCorner.Parent = scopeBtn

        local scopeStroke = Instance.new("UIStroke")
        scopeStroke.Color = Color3.fromRGB(70, 120, 190)
        scopeStroke.Transparency = 0.75
        scopeStroke.Thickness = 1
        scopeStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        scopeStroke.Parent = scopeBtn

        scopeBtn.MouseEnter:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                scopeBtn.BackgroundColor3 = Color3.fromRGB(36, 48, 68)
                scopeStroke.Transparency = 0.5
            end
        end)
        scopeBtn.MouseLeave:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                scopeBtn.BackgroundColor3 = Color3.fromRGB(26, 34, 48)
                scopeStroke.Transparency = 0.75
            end
        end)
        scopeBtn.MouseButton1Down:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                scopeBtn.BackgroundColor3 = Color3.fromRGB(45, 60, 85)
            end
        end)
        scopeBtn.MouseButton1Up:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                scopeBtn.BackgroundColor3 = Color3.fromRGB(36, 48, 68)
            end
        end)

        scopeBtn.MouseButton1Click:Connect(function()
            if scriptObj.stage == "Kernel" then return end
            scopeBtn.Text = ICONS.HOURGLASS .. " Moving..."
            local ok, errOrPath = toggleScriptScope(scriptObj)
            if ok then
                local oldKey = key
                cachedStartupRows[oldKey] = nil
                row:Destroy()
                activeExpandedRowKey = errOrPath
                scanStartupScripts(true)
                if refreshStartupTab then
                    refreshStartupTab(true)
                end
            else
                scopeBtn.Text = ICONS.WARN .. " " .. tostring(errOrPath):sub(1, 15)
                task.delay(1.5, function()
                    if scopeBtn and scopeBtn.Parent then
                        local isSpec = isScriptGameSpecific(scriptObj.file)
                        scopeBtn.Text = isSpec and (ICONS.GAME .. " Scope: Game Specific") or (ICONS.GLOBE .. " Scope: Global")
                    end
                end)
            end
        end)

        -- 2. Edit Pill Button
        local editBtn = Instance.new("TextButton")
        editBtn.Name = "EditBtn"
        editBtn.Size = UDim2.new(0, 110, 0, 24)
        editBtn.BackgroundColor3 = Color3.fromRGB(24, 38, 32)
        editBtn.AutoButtonColor = false
        editBtn.Font = Enum.Font.GothamMedium
        editBtn.TextSize = 10
        editBtn.TextColor3 = Color3.fromRGB(160, 240, 190)
        editBtn.Text = ICONS.EDIT .. " Edit Script"
        editBtn.LayoutOrder = 2
        editBtn.Parent = btnContainer

        local editCorner = Instance.new("UICorner")
        editCorner.CornerRadius = UDim.new(0, 5)
        editCorner.Parent = editBtn

        local editStroke = Instance.new("UIStroke")
        editStroke.Color = Color3.fromRGB(60, 160, 110)
        editStroke.Transparency = 0.75
        editStroke.Thickness = 1
        editStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        editStroke.Parent = editBtn

        editBtn.MouseEnter:Connect(function()
            editBtn.BackgroundColor3 = Color3.fromRGB(34, 52, 44)
            editStroke.Transparency = 0.5
        end)
        editBtn.MouseLeave:Connect(function()
            editBtn.BackgroundColor3 = Color3.fromRGB(24, 38, 32)
            editStroke.Transparency = 0.75
        end)
        editBtn.MouseButton1Down:Connect(function()
            editBtn.BackgroundColor3 = Color3.fromRGB(42, 65, 55)
        end)
        editBtn.MouseButton1Up:Connect(function()
            editBtn.BackgroundColor3 = Color3.fromRGB(34, 52, 44)
        end)

        editBtn.MouseButton1Click:Connect(function()
            if openCodeEditor then
                openCodeEditor(scriptObj)
            end
        end)

        -- 3. Delete Pill Button
        local deleteBtn = Instance.new("TextButton")
        deleteBtn.Name = "DeleteBtn"
        deleteBtn.Size = UDim2.new(0, 110, 0, 24)
        deleteBtn.BackgroundColor3 = Color3.fromRGB(42, 22, 24)
        deleteBtn.AutoButtonColor = false
        deleteBtn.Font = Enum.Font.GothamMedium
        deleteBtn.TextSize = 10
        deleteBtn.TextColor3 = Color3.fromRGB(255, 140, 140)
        deleteBtn.Text = ICONS.DELETE .. " Delete"
        deleteBtn.LayoutOrder = 3
        deleteBtn.Parent = btnContainer

        local delCorner = Instance.new("UICorner")
        delCorner.CornerRadius = UDim.new(0, 5)
        delCorner.Parent = deleteBtn

        local delStroke = Instance.new("UIStroke")
        delStroke.Color = Color3.fromRGB(200, 70, 70)
        delStroke.Transparency = 0.75
        delStroke.Thickness = 1
        delStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        delStroke.Parent = deleteBtn

        local isConfirmingDelete = false

        deleteBtn.MouseEnter:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                deleteBtn.BackgroundColor3 = isConfirmingDelete and Color3.fromRGB(100, 30, 35) or Color3.fromRGB(58, 28, 32)
                delStroke.Transparency = 0.5
            end
        end)
        deleteBtn.MouseLeave:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                deleteBtn.BackgroundColor3 = isConfirmingDelete and Color3.fromRGB(80, 25, 25) or Color3.fromRGB(42, 22, 24)
                delStroke.Transparency = 0.75
            end
        end)
        deleteBtn.MouseButton1Down:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                deleteBtn.BackgroundColor3 = Color3.fromRGB(72, 32, 38)
            end
        end)
        deleteBtn.MouseButton1Up:Connect(function()
            if scriptObj.stage ~= "Kernel" then
                deleteBtn.BackgroundColor3 = isConfirmingDelete and Color3.fromRGB(100, 30, 35) or Color3.fromRGB(58, 28, 32)
            end
        end)

        deleteBtn.MouseButton1Click:Connect(function()
            if scriptObj.stage == "Kernel" or (scriptObj.file and scriptObj.file:lower():find("kerneltaskmanager")) then
                return
            end
            if not isConfirmingDelete then
                isConfirmingDelete = true
                deleteBtn:SetAttribute("Confirming", true)
                deleteBtn.Text = ICONS.WARN .. " Confirm?"
                deleteBtn.BackgroundColor3 = Color3.fromRGB(80, 25, 25)
                deleteBtn.TextColor3 = Color3.fromRGB(255, 220, 220)
                deleteBtn.Size = UDim2.new(0, 115, 0, 24)
                task.delay(3, function()
                    if isConfirmingDelete and deleteBtn and deleteBtn.Parent then
                        isConfirmingDelete = false
                        deleteBtn:SetAttribute("Confirming", nil)
                        deleteBtn.Text = ICONS.DELETE .. " Delete"
                        deleteBtn.BackgroundColor3 = Color3.fromRGB(42, 22, 24)
                        deleteBtn.TextColor3 = Color3.fromRGB(255, 140, 140)
                        deleteBtn.Size = UDim2.new(0, 110, 0, 24)
                    end
                end)
            else
                isConfirmingDelete = false
                deleteBtn:SetAttribute("Confirming", nil)
                deleteBtn.Text = ICONS.HOURGLASS .. " Deleting..."
                local target = normStartupPath(scriptObj.file)
                if not isfile(target) and isfile("workspace/" .. target) then
                    target = "workspace/" .. target
                end
                pcall(delfile, target)
                pcall(delfile, scriptObj.file)
                cachedStartupRows[key] = nil
                row:Destroy()
                if activeExpandedRowKey == key then
                    activeExpandedRowKey = nil
                end
                scanStartupScripts(true)
                if refreshStartupTab then
                    refreshStartupTab(true)
                end
            end
        end)

        row.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                if isInsideGui(toggleBtn, input.Position) or isInsideGui(priLbl, input.Position) then
                    return
                end
                local bInfo = currentStartupBoundaries[scriptObj.file:lower()]
                if bInfo and bInfo.canToggle and isInsideGui(stageBadge, input.Position) then
                    return
                end
                if accordion.Visible and isInsideGui(accordion, input.Position) then
                    return
                end
                if scriptObj.stage == "Kernel" then
                    return
                end
                pendingStartupDrag = {
                    script = scriptObj,
                    row = row,
                    startPos = input.Position,
                    startIdx = idx,
                }
            elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                if isInsideGui(toggleBtn, input.Position) or isInsideGui(stageBadge, input.Position) or isInsideGui(priLbl, input.Position) then
                    return
                end
                if accordion.Visible and isInsideGui(accordion, input.Position) then
                    return
                end
                toggleRowAccordion(row, scriptObj.file)
            end
        end)

        cachedStartupRows[key] = row
        applyRowColumnLayout(row, "Startup")
    end

    row.LayoutOrder = idx * 10
    row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)
    local dot = row:FindFirstChild("Dot")
    local gripLbl = row:FindFirstChild("GripLbl")
    if gripLbl then
        local isPriSort = TableSortState.Startup and TableSortState.Startup.colId == "Priority"
        gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
    end
    local priLbl = row:FindFirstChild("PriLbl")
    if priLbl then
        priLbl.Text = tostring(scriptObj.priority or 100)
    end
    local nameLbl = row:FindFirstChild("NameLbl")
    local pathLbl = row:FindFirstChild("PathLbl")
    local stageBadge = row:FindFirstChild("StageBadge")
    local timeLbl = row:FindFirstChild("TimeLbl")
    local toggleBtn = row:FindFirstChild("ToggleBtn")

    local isEnabled = (scriptObj.enabled ~= false)
    if dot then
        dot.BackgroundColor3 = isEnabled and Color3.fromRGB(50, 220, 120) or Color3.fromRGB(100, 110, 125)
    end
    if nameLbl then
        nameLbl.Text = scriptObj.name or "Script"
        nameLbl.TextColor3 = isEnabled and Color3.fromRGB(225, 235, 250) or Color3.fromRGB(130, 140, 155)
    end
    if pathLbl then
        pathLbl.Text = scriptObj.file or ""
    end
    if stageBadge then
        local bInfo = currentStartupBoundaries[scriptObj.file:lower()]
        local isInteractive = (bInfo and bInfo.canToggle == true)

        stageBadge.Active = isInteractive
        stageBadge.Selectable = isInteractive

        local stage = scriptObj.stage or "GameLoaded"
        stageBadge.Text = stage:upper()
        local c = STAGE_COLORS[stage] or Color3.fromRGB(50, 130, 240)
        stageBadge.TextColor3 = c

        local isHovered = isInteractive and startupBadgeHovered[scriptObj.file:lower()]
        if isHovered then
            stageBadge.BackgroundColor3 = Color3.fromRGB(math.min(255, math.floor(c.R * 70)), math.min(255, math.floor(c.G * 70)), math.min(255, math.floor(c.B * 70)))
        else
            stageBadge.BackgroundColor3 = Color3.fromRGB(math.floor(c.R * 40), math.floor(c.G * 40), math.floor(c.B * 40))
        end
    end
    if timeLbl then
        local totalMs = (scriptObj.compileMs or 0) + (scriptObj.execMs or 0)
        if not isEnabled then
            timeLbl.Text = "Disabled"
            timeLbl.TextColor3 = Color3.fromRGB(110, 125, 150)
        elseif totalMs > 0 then
            timeLbl.Text = string.format("%.1f ms", totalMs)
            timeLbl.TextColor3 = (totalMs > 10) and Color3.fromRGB(255, 180, 50) or Color3.fromRGB(180, 195, 220)
        else
            timeLbl.Text = "Ready"
            timeLbl.TextColor3 = Color3.fromRGB(110, 125, 150)
        end
    end
    if toggleBtn then
        toggleBtn.Text = isEnabled and (ICONS.DOT_GREEN .. " ON") or (ICONS.DOT_WHITE .. " OFF")
        toggleBtn.BackgroundColor3 = isEnabled and Color3.fromRGB(25, 50, 35) or Color3.fromRGB(45, 30, 30)
        toggleBtn.TextColor3 = isEnabled and Color3.fromRGB(100, 240, 150) or Color3.fromRGB(240, 120, 120)
    end

    -- Update Accordion & Action Buttons state
    local accordion = row:FindFirstChild("AccordionPanel")
    if accordion then
        local isExpanded = (activeExpandedRowKey == key)
        accordion.Visible = isExpanded
        row.Size = isExpanded and UDim2.new(1, 0, 0, 68) or UDim2.new(1, 0, 0, 32)

        local btnContainer = accordion:FindFirstChild("BtnContainer")
        if btnContainer then
            local scopeBtn = btnContainer:FindFirstChild("ScopeBtn")
            if scopeBtn then
                if scriptObj.stage == "Kernel" then
                    scopeBtn.Text = ICONS.BOLT .. " Scope: Kernel (Global)"
                    scopeBtn.TextColor3 = Color3.fromRGB(110, 125, 145)
                    scopeBtn.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
                else
                    local isSpec = isScriptGameSpecific(scriptObj.file)
                    scopeBtn.Text = isSpec and (ICONS.GAME .. " Scope: Game Specific") or (ICONS.GLOBE .. " Scope: Global")
                    scopeBtn.TextColor3 = Color3.fromRGB(190, 220, 255)
                    scopeBtn.BackgroundColor3 = Color3.fromRGB(26, 34, 48)
                end
            end

            local deleteBtn = btnContainer:FindFirstChild("DeleteBtn")
            if deleteBtn then
                if scriptObj.stage == "Kernel" or (scriptObj.file and scriptObj.file:lower():find("kerneltaskmanager")) then
                    deleteBtn.Text = ICONS.LOCK_CLOSED .. " Locked"
                    deleteBtn.TextColor3 = Color3.fromRGB(110, 125, 145)
                    deleteBtn.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
                elseif not deleteBtn:GetAttribute("Confirming") then
                    deleteBtn.Text = ICONS.DELETE .. " Delete"
                    deleteBtn.TextColor3 = Color3.fromRGB(255, 140, 140)
                    deleteBtn.BackgroundColor3 = Color3.fromRGB(42, 22, 24)
                    deleteBtn.Size = UDim2.new(0, 110, 0, 24)
                end
            end
        end
    end

    row.Visible = true
    return row
end


refreshStartupTab = function(force)
    if not ScreenGui.Enabled or currentTab ~= "Startup" then return end
    local filterText = SearchBox.Text:lower()
    local seenKeys = {}
    local visibleCount = 0
    local startupScripts = scanStartupScripts(force)
    if TableSortState.Startup and TableSortState.Startup.colId then
        sortStartupList(startupScripts, TableSortState.Startup.colId, TableSortState.Startup.ascending)
    end
    currentStartupBoundaries = getStageBoundaryInfo(startupScripts)
    allStartupScriptsRef = startupScripts
    for idx, scriptObj in ipairs(startupScripts) do
        seenKeys[scriptObj.file] = true
        local matches = (filterText == "")
            or (scriptObj.name and scriptObj.name:lower():find(filterText, 1, true))
            or (scriptObj.file and scriptObj.file:lower():find(filterText, 1, true))
            or (scriptObj.stage and scriptObj.stage:lower():find(filterText, 1, true))

        if not showDisabled and scriptObj.enabled == false then
            matches = false
            if activeExpandedRowKey == scriptObj.file then
                activeExpandedRowKey = nil
            end
        end

        if matches then
            visibleCount = visibleCount + 1
            renderStartupRow(scriptObj, visibleCount)
        else
            local r = cachedStartupRows[scriptObj.file]
            if r then r.Visible = false end
        end
    end
    for key, r in pairs(cachedStartupRows) do
        if not seenKeys[key] then
            r:Destroy()
            cachedStartupRows[key] = nil
        end
    end
    EmptyStartup.Visible = (visibleCount == 0)
    if visibleCount == 0 then
        EmptyStartup.Text = if filterText ~= "" then "No startup scripts match filter '" .. SearchBox.Text .. "'."
            else "No startup scripts found in autoexec/ directory."
    end
end

-- Row 4: Loop Row (Placed after getHzColor so all helper routines are defined)
local loopRowDragging = {}

local LOOP_HZ_CYCLE = {
    [0] = 60,
    [60] = 30,
    [30] = 15,
    [15] = 5,
    [5] = 1,
    [1] = 0,
}

local function renderLoopRow(loopObj, idx)
    local row = cachedLoopRows[loopObj.id]
    if not row then
        row = Instance.new("Frame")
        row.Name = loopObj.id
        row.Size = UDim2.new(1, 0, 0, 32)
        row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)
        row.BorderSizePixel = 0
        row.LayoutOrder = idx * 10
        row.Active = true
        row.Parent = ScrollListLoops

        local rCorner = Instance.new("UICorner")
        rCorner.CornerRadius = UDim.new(0, 4)
        rCorner.Parent = row

        local isPriSort = TableSortState.Loops and TableSortState.Loops.colId == "Priority"
        local gripLbl = Instance.new("TextLabel")
        gripLbl.Name = "GripLbl"
        gripLbl.Size = UDim2.new(0, 12, 0, 16)
        gripLbl.Position = UDim2.new(0, 4, 0.5, -8)
        gripLbl.BackgroundTransparency = 1
        gripLbl.Font = Enum.Font.GothamBold
        gripLbl.TextSize = 12
        gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
        gripLbl.Text = ICONS.GRIP
        gripLbl.Parent = row

        local dot = Instance.new("Frame")
        dot.Name = "Dot"
        dot.Size = UDim2.new(0, 8, 0, 8)
        dot.Position = UDim2.new(0, 20, 0.5, -4)
        dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120)
        dot.BorderSizePixel = 0
        dot.Parent = row
        local dotCorner = Instance.new("UICorner")
        dotCorner.CornerRadius = UDim.new(1, 0)
        dotCorner.Parent = dot

        local priLbl = Instance.new("TextButton")
        priLbl.Name = "PriLbl"
        priLbl.Size = UDim2.new(0, 28, 0, 18)
        priLbl.Position = UDim2.new(0, 32, 0.5, -9)
        priLbl.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
        priLbl.BorderSizePixel = 0
        priLbl.AutoButtonColor = false
        priLbl.Font = Enum.Font.GothamBold
        priLbl.TextSize = 10
        priLbl.TextColor3 = Color3.fromRGB(210, 230, 255)
        priLbl.TextXAlignment = Enum.TextXAlignment.Center
        priLbl.Text = tostring(loopObj.priority or 50)
        priLbl.Parent = row
        local priCorner = Instance.new("UICorner")
        priCorner.CornerRadius = UDim.new(0, 3)
        priCorner.Parent = priLbl
        local priStroke = Instance.new("UIStroke")
        priStroke.Thickness = 1
        priStroke.Color = Color3.fromRGB(45, 60, 85)
        priStroke.Parent = priLbl

        priLbl.MouseEnter:Connect(function()
            priLbl.BackgroundColor3 = Color3.fromRGB(38, 52, 75)
            priStroke.Color = Color3.fromRGB(80, 130, 200)
        end)
        priLbl.MouseLeave:Connect(function()
            priLbl.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
            priStroke.Color = Color3.fromRGB(45, 60, 85)
        end)
        priLbl.MouseButton1Click:Connect(function()
            if openPriorityEditModal then
                openPriorityEditModal("Loop", loopObj, loopObj.priority or 50)
            end
        end)

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Name = "NameLbl"
        nameLbl.Size = UDim2.new(0.33, 0, 1, 0)
        nameLbl.Position = UDim2.new(0, 34, 0, 0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamMedium
        nameLbl.TextSize = 11
        nameLbl.TextColor3 = Color3.fromRGB(225, 235, 250)
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Parent = row

        local itersLbl = Instance.new("TextLabel")
        itersLbl.Name = "ItersLbl"
        itersLbl.Size = UDim2.new(0.11, 0, 1, 0)
        itersLbl.Position = UDim2.new(0.44, 0, 0, 0)
        itersLbl.BackgroundTransparency = 1
        itersLbl.Font = Enum.Font.Gotham
        itersLbl.TextSize = 10
        itersLbl.TextColor3 = Color3.fromRGB(140, 155, 180)
        itersLbl.TextXAlignment = Enum.TextXAlignment.Left
        itersLbl.Parent = row

        local hzBtn = Instance.new("TextButton")
        hzBtn.Name = "HzBtn"
        hzBtn.Size = UDim2.new(0, 64, 0, 20)
        hzBtn.Position = UDim2.new(0.61, -32, 0.5, -10)
        hzBtn.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
        hzBtn.BorderSizePixel = 0
        hzBtn.Text = ""
        hzBtn.AutoButtonColor = false
        hzBtn.Parent = row
        local hzCorner = Instance.new("UICorner")
        hzCorner.CornerRadius = UDim.new(0, 4)
        hzCorner.Parent = hzBtn

        local sliderFill = Instance.new("Frame")
        sliderFill.Name = "SliderFill"
        sliderFill.Size = UDim2.new(1, 0, 1, 0)
        sliderFill.Position = UDim2.new(0, 0, 0, 0)
        sliderFill.BackgroundColor3 = Color3.fromRGB(50, 130, 240)
        sliderFill.BorderSizePixel = 0
        sliderFill.Parent = hzBtn
        local fillCorner = Instance.new("UICorner")
        fillCorner.CornerRadius = UDim.new(0, 4)
        fillCorner.Parent = sliderFill

        local sliderLbl = Instance.new("TextLabel")
        sliderLbl.Name = "SliderLbl"
        sliderLbl.Size = UDim2.new(1, 0, 1, 0)
        sliderLbl.BackgroundTransparency = 1
        sliderLbl.Font = Enum.Font.GothamBold
        sliderLbl.TextSize = 10
        sliderLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
        sliderLbl.Text = "60Hz"
        sliderLbl.ZIndex = 3
        sliderLbl.Parent = hzBtn

        local lockBtn = Instance.new("TextButton")
        lockBtn.Name = "LockBtn"
        lockBtn.Size = UDim2.new(0, 24, 0, 20)
        lockBtn.Position = UDim2.new(0.695, -12, 0.5, -10)
        lockBtn.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
        lockBtn.BorderSizePixel = 0
        lockBtn.Font = Enum.Font.GothamBold
        lockBtn.TextSize = 10
        lockBtn.TextColor3 = Color3.fromRGB(120, 135, 160)
        lockBtn.Text = ICONS.LOCK_OPEN
        lockBtn.Parent = row
        local lockCorner = Instance.new("UICorner")
        lockCorner.CornerRadius = UDim.new(0, 4)
        lockCorner.Parent = lockBtn

        local cpuLbl = Instance.new("TextLabel")
        cpuLbl.Name = "CpuLbl"
        cpuLbl.Size = UDim2.new(0.11, 0, 1, 0)
        cpuLbl.Position = UDim2.new(0.73, 0, 0, 0)
        cpuLbl.BackgroundTransparency = 1
        cpuLbl.Font = Enum.Font.GothamBold
        cpuLbl.TextSize = 11
        cpuLbl.TextColor3 = Color3.fromRGB(100, 220, 140)
        cpuLbl.TextXAlignment = Enum.TextXAlignment.Right
        cpuLbl.Parent = row

        local actions = Instance.new("Frame")
        actions.Name = "Actions"
        actions.Size = UDim2.new(0.12, 0, 1, 0)
        actions.Position = UDim2.new(0.86, 0, 0, 0)
        actions.BackgroundTransparency = 1
        actions.Parent = row
        local actionsLayout = Instance.new("UIListLayout")
        actionsLayout.FillDirection = Enum.FillDirection.Horizontal
        actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        actionsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        actionsLayout.Padding = UDim.new(0, 4)
        actionsLayout.Parent = actions

        local pauseBtn = Instance.new("TextButton")
        pauseBtn.Name = "PauseBtn"
        pauseBtn.Size = UDim2.new(0, 24, 0, 20)
        pauseBtn.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
        pauseBtn.BorderSizePixel = 0
        pauseBtn.Font = Enum.Font.GothamBold
        pauseBtn.TextSize = 10
        pauseBtn.TextColor3 = Color3.fromRGB(200, 215, 240)
        pauseBtn.Text = ICONS.PAUSE
        pauseBtn.Parent = actions
        local pauseCorner = Instance.new("UICorner")
        pauseCorner.CornerRadius = UDim.new(0, 4)
        pauseCorner.Parent = pauseBtn

        local killBtn = Instance.new("TextButton")
        killBtn.Name = "KillBtn"
        killBtn.Size = UDim2.new(0, 24, 0, 20)
        killBtn.BackgroundColor3 = Color3.fromRGB(60, 25, 30)
        killBtn.BorderSizePixel = 0
        killBtn.Font = Enum.Font.GothamBold
        killBtn.TextSize = 11
        killBtn.TextColor3 = Color3.fromRGB(255, 140, 140)
        killBtn.Text = ICONS.KILL
        killBtn.Parent = actions
        local killCorner = Instance.new("UICorner")
        killCorner.CornerRadius = UDim.new(0, 4)
        killCorner.Parent = killBtn

        -- Connect Actions
        local isDragging = false
        local function updateSlider(posX)
            local barX = hzBtn.AbsolutePosition.X
            local barW = math.max(1, hzBtn.AbsoluteSize.X)
            local rel = math.clamp((posX - barX) / barW, 0.01, 1.0)
            local maxHz = math.max(60, measuredFps or 60)
            local targetHz
            if rel >= 0.95 then
                targetHz = 0 -- 0 indicates Max / Uncapped
            else
                targetHz = math.clamp(math.round(rel * maxHz), 1, maxHz)
            end

            local sliderFill = hzBtn:FindFirstChild("SliderFill")
            local sliderLbl = hzBtn:FindFirstChild("SliderLbl")
            if sliderFill then
                sliderFill.Size = UDim2.new(rel, 0, 1, 0)
                sliderFill.BackgroundColor3 = if targetHz == 0 then Color3.fromRGB(50, 130, 240) else getHzColor(targetHz, maxHz)
            end
            if sliderLbl then
                local text = (targetHz == 0 or not targetHz or targetHz >= maxHz) and string.format("%dHz", maxHz) or string.format("%dHz", targetHz)
                sliderLbl.Text = text
            end

            if getgenv().SetLoopFrequency then
                getgenv().SetLoopFrequency(loopObj.id, targetHz)
            end
        end

        local loopDragMoveConn, loopDragEndConn
        local function stopLoopDrag()
            isDragging = false
            loopRowDragging[loopObj.id] = false
            if loopDragMoveConn then loopDragMoveConn:Disconnect(); loopDragMoveConn = nil end
            if loopDragEndConn then loopDragEndConn:Disconnect(); loopDragEndConn = nil end
        end

        row.Destroying:Connect(stopLoopDrag)

        hzBtn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isDragging = true
                loopRowDragging[loopObj.id] = true
                updateSlider(input.Position.X)

                if loopDragMoveConn then loopDragMoveConn:Disconnect() end
                if loopDragEndConn then loopDragEndConn:Disconnect() end

                loopDragMoveConn = UserInputService.InputChanged:Connect(function(moveInput)
                    if isDragging and (moveInput.UserInputType == Enum.UserInputType.MouseMovement or moveInput.UserInputType == Enum.UserInputType.Touch) then
                        updateSlider(moveInput.Position.X)
                    end
                end)
                loopDragEndConn = UserInputService.InputEnded:Connect(function(endInput)
                    if endInput.UserInputType == Enum.UserInputType.MouseButton1 or endInput.UserInputType == Enum.UserInputType.Touch then
                        stopLoopDrag()
                    end
                end)
            end
        end)

        lockBtn.MouseButton1Click:Connect(function()
            local willLock = not (lockBtn.Text == ICONS.LOCK_CLOSED)
            if getgenv().SetLoopLocked then
                getgenv().SetLoopLocked(loopObj.id, willLock)
            end
        end)

        pauseBtn.MouseButton1Click:Connect(function()
            local willPause = (pauseBtn.Text == ICONS.PAUSE)
            if getgenv().SetLoopPaused then
                getgenv().SetLoopPaused(loopObj.id, willPause)
            end
        end)

        killBtn.MouseButton1Click:Connect(function()
            if getgenv().KillLoop then
                getgenv().KillLoop(loopObj.id)
            end
        end)

        row.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                if isInsideGui(hzBtn, input.Position) or isInsideGui(lockBtn, input.Position) or isInsideGui(actions, input.Position) or isInsideGui(priLbl, input.Position) then
                    return
                end
                LoopDrag.pending = {
                    loop = loopObj,
                    row = row,
                    startPos = input.Position,
                    startIdx = idx,
                }
            end
        end)

        cachedLoopRows[loopObj.id] = row
        applyRowColumnLayout(row, "Loops")
    end

    row.LayoutOrder = idx * 10
    row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)

    -- Update row state
    local dot = row:FindFirstChild("Dot")
    local gripLbl = row:FindFirstChild("GripLbl")
    if gripLbl then
        local isPriSort = TableSortState.Loops and TableSortState.Loops.colId == "Priority"
        gripLbl.TextColor3 = isPriSort and Color3.fromRGB(120, 160, 215) or Color3.fromRGB(55, 68, 88)
    end
    local priLbl = row:FindFirstChild("PriLbl")
    local priVal = loopObj.priority or 50
    if priLbl then
        priLbl.Text = tostring(priVal)
    end
    if dot then
        if loopObj.paused then
            dot.BackgroundColor3 = Color3.fromRGB(255, 160, 40) -- Orange
        elseif loopObj.autoThrottled then
            dot.BackgroundColor3 = Color3.fromRGB(240, 210, 40) -- Yellow
        elseif (loopObj.avgTimeMs or 0) > 2.5 then
            dot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)  -- Red
        else
            dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120) -- Green
        end
    end

    local nameLbl = row:FindFirstChild("NameLbl")
    if nameLbl then
        local displayName = loopObj.caller or loopObj.name or "UnknownLoop"
        local badge = (loopObj.isExecutor ~= false) and (ICONS.BOLT .. " ") or (ICONS.GAME .. " ")
        nameLbl.Text = badge .. displayName
    end

    local itersLbl = row:FindFirstChild("ItersLbl")
    if itersLbl then
        itersLbl.Text = string.format("%d iters", loopObj.iterations or 0)
    end

    if not loopRowDragging[loopObj.id] then
        local hzBtn = row:FindFirstChild("HzBtn")
        if hzBtn then
            local sliderLbl = hzBtn:FindFirstChild("SliderLbl")
            local sliderFill = hzBtn:FindFirstChild("SliderFill")
            local targetHz = loopObj.targetHz
            local maxHz = math.max(60, measuredFps or 60)
            if sliderLbl then
                if targetHz and targetHz > 0 and targetHz < maxHz then
                    sliderLbl.Text = string.format("%dHz", targetHz)
                else
                    sliderLbl.Text = string.format("%dHz", maxHz)
                end
            end
            if sliderFill then
                local fillRatio
                if not targetHz or targetHz == 0 or targetHz >= maxHz then
                    fillRatio = 1.0
                    sliderFill.BackgroundColor3 = Color3.fromRGB(50, 130, 240)
                else
                    fillRatio = math.clamp(targetHz / maxHz, 0.08, 1.0)
                    sliderFill.BackgroundColor3 = getHzColor(targetHz, maxHz)
                end
                sliderFill.Size = UDim2.new(fillRatio, 0, 1, 0)
            end
        end
    end

    local lockBtn = row:FindFirstChild("LockBtn")
    if lockBtn then
        lockBtn.Text = if loopObj.locked then ICONS.LOCK_CLOSED else ICONS.LOCK_OPEN
        lockBtn.BackgroundColor3 = if loopObj.locked then Color3.fromRGB(45, 40, 20) else Color3.fromRGB(25, 30, 42)
        lockBtn.TextColor3 = if loopObj.locked then Color3.fromRGB(255, 200, 50) else Color3.fromRGB(120, 135, 160)
    end

    local cpuLbl = row:FindFirstChild("CpuLbl")
    if cpuLbl then
        local ms = loopObj.avgTimeMs or 0
        cpuLbl.Text = string.format("%.2fms", ms)
        if ms > 2.5 then cpuLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
        elseif ms > 1.0 then cpuLbl.TextColor3 = Color3.fromRGB(255, 180, 50)
        else cpuLbl.TextColor3 = Color3.fromRGB(100, 220, 140) end
    end

    local actions = row:FindFirstChild("Actions")
    if actions then
        local pauseBtn = actions:FindFirstChild("PauseBtn")
        if pauseBtn then
            pauseBtn.Text = if loopObj.paused then ICONS.PLAY else ICONS.PAUSE
            pauseBtn.BackgroundColor3 = if loopObj.paused then Color3.fromRGB(25, 55, 35) else Color3.fromRGB(28, 34, 48)
            pauseBtn.TextColor3 = if loopObj.paused then Color3.fromRGB(100, 240, 140) else Color3.fromRGB(200, 215, 240)
        end
    end

    row.Visible = true
    return row
end

-- Row 5: Game Task Row
local cachedGameRows = {}


local function renderGameTaskRow(entry, idx)
    local row = cachedGameRows[entry.id]
    if not row then
        row = Instance.new("Frame")
        row.Name = entry.id
        row.Size = UDim2.new(1, 0, 0, 32)
        row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)
        row.BorderSizePixel = 0
        row.LayoutOrder = idx
        row.Parent = ScrollListGame

        local rCorner = Instance.new("UICorner")
        rCorner.CornerRadius = UDim.new(0, 4)
        rCorner.Parent = row

        local dot = Instance.new("Frame")
        dot.Name = "Dot"
        dot.Size = UDim2.new(0, 8, 0, 8)
        dot.Position = UDim2.new(0.02, 10, 0.5, -4)
        dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120)
        dot.BorderSizePixel = 0
        dot.Parent = row
        local dotCorner = Instance.new("UICorner")
        dotCorner.CornerRadius = UDim.new(1, 0)
        dotCorner.Parent = dot

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Name = "NameLbl"
        nameLbl.Size = UDim2.new(0.44, 0, 1, 0)
        nameLbl.Position = UDim2.new(0.08, 0, 0, 0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamMedium
        nameLbl.TextSize = 11
        nameLbl.TextColor3 = Color3.fromRGB(225, 235, 250)
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        local labelText = if (entry.count and entry.count > 1)
            then string.format("%s (x%d)", entry.name, entry.count)
            else entry.name
        nameLbl.Text = labelText
        nameLbl.Parent = row

        local eventLbl = Instance.new("TextLabel")
        eventLbl.Name = "EventLbl"
        eventLbl.Size = UDim2.new(0.15, 0, 1, 0)
        eventLbl.Position = UDim2.new(0.54, 0, 0, 0)
        eventLbl.BackgroundTransparency = 1
        eventLbl.Font = Enum.Font.Gotham
        eventLbl.TextSize = 10
        eventLbl.TextColor3 = Color3.fromRGB(140, 155, 180)
        eventLbl.TextXAlignment = Enum.TextXAlignment.Left
        eventLbl.Text = entry.event
        eventLbl.Parent = row

        local statusBadge = Instance.new("Frame")
        statusBadge.Name = "StatusBadge"
        statusBadge.Size = UDim2.new(0, 84, 0, 20)
        statusBadge.Position = UDim2.new(0.775, -42, 0.5, -10)
        statusBadge.BackgroundColor3 = Color3.fromRGB(18, 38, 28)
        statusBadge.BorderSizePixel = 0
        statusBadge.Parent = row
        local badgeCorner = Instance.new("UICorner")
        badgeCorner.CornerRadius = UDim.new(0, 4)
        badgeCorner.Parent = statusBadge

        local statusLbl = Instance.new("TextLabel")
        statusLbl.Name = "StatusLbl"
        statusLbl.Size = UDim2.new(1, 0, 1, 0)
        statusLbl.BackgroundTransparency = 1
        statusLbl.Font = Enum.Font.GothamBold
        statusLbl.TextSize = 10
        statusLbl.TextColor3 = Color3.fromRGB(100, 230, 160)
        statusLbl.Text = "Native"
        statusLbl.Parent = statusBadge

        local actionBtn = Instance.new("TextButton")
        actionBtn.Name = "ActionBtn"
        actionBtn.Size = UDim2.new(0, 72, 0, 20)
        actionBtn.Position = UDim2.new(0.93, -36, 0.5, -10)
        actionBtn.BackgroundColor3 = Color3.fromRGB(28, 48, 40)
        actionBtn.BorderSizePixel = 0
        actionBtn.Font = Enum.Font.GothamBold
        actionBtn.TextSize = 10
        actionBtn.TextColor3 = Color3.fromRGB(100, 230, 160)
        actionBtn.Text = ICONS.INGEST .. " Ingest"
        actionBtn.AutoButtonColor = true
        actionBtn.Parent = row
        local actionCorner = Instance.new("UICorner")
        actionCorner.CornerRadius = UDim.new(0, 4)
        actionCorner.Parent = actionBtn

        actionBtn.MouseButton1Click:Connect(function()
            if entry.isIngested then
                EjectGameTask(entry.id)
            else
                IngestGameTask(entry.id)
            end
        end)

        cachedGameRows[entry.id] = row
        applyRowColumnLayout(row, "Game")
    end

    row.LayoutOrder = idx
    row.BackgroundColor3 = if idx % 2 == 0 then Color3.fromRGB(20, 24, 33) else Color3.fromRGB(17, 20, 28)

    local dot = row:FindFirstChild("Dot")
    local nameLbl = row:FindFirstChild("NameLbl")
    local eventLbl = row:FindFirstChild("EventLbl")
    local statusBadge = row:FindFirstChild("StatusBadge")
    local actionBtn = row:FindFirstChild("ActionBtn")

    local labelText = if (entry.count and entry.count > 1)
        then string.format("%s (x%d)", entry.name, entry.count)
        else entry.name
    if nameLbl then nameLbl.Text = labelText end
    if eventLbl then eventLbl.Text = entry.event end

    if entry.isIngested then
        if dot then dot.BackgroundColor3 = Color3.fromRGB(64, 196, 255) end
        if statusBadge then
            statusBadge.BackgroundColor3 = Color3.fromRGB(20, 35, 55)
            local lbl = statusBadge:FindFirstChild("StatusLbl")
            if lbl then
                lbl.TextColor3 = Color3.fromRGB(80, 200, 255)
                lbl.Text = "Ingested"
            end
        end
        if actionBtn then
            actionBtn.Text = ICONS.EJECT .. " Eject"
            actionBtn.BackgroundColor3 = Color3.fromRGB(60, 28, 32)
            actionBtn.TextColor3 = Color3.fromRGB(255, 140, 140)
        end
    else
        if dot then dot.BackgroundColor3 = Color3.fromRGB(50, 220, 120) end
        if statusBadge then
            statusBadge.BackgroundColor3 = Color3.fromRGB(18, 38, 28)
            local lbl = statusBadge:FindFirstChild("StatusLbl")
            if lbl then
                lbl.TextColor3 = Color3.fromRGB(100, 230, 160)
                lbl.Text = "Native"
            end
        end
        if actionBtn then
            actionBtn.Text = ICONS.INGEST .. " Ingest"
            actionBtn.BackgroundColor3 = Color3.fromRGB(28, 48, 40)
            actionBtn.TextColor3 = Color3.fromRGB(100, 230, 160)
        end
    end

    row.Visible = true
    return row
end

-- ==============================================================================
-- UPDATE TICK (10Hz)
-- ==============================================================================

local lastGameScanTime = 0
local running = true

task.spawn(function()
    while running do
        task.wait(0.1)

        if ScreenGui.Enabled then
            pcall(function()
                local profile
                if getgenv().GetSchedulerProfile then
                    profile = getgenv().GetSchedulerProfile()
                elseif getgenv().GetSchedulerLiveState then
                    profile = getgenv().GetSchedulerLiveState()
                end

            if profile then
                -- 1. Update Header Metrics
                local fps = profile.fps
                if not fps or fps == 60 then
                    if getgenv().GetAdaptiveBudget then
                        local _, mFps = getgenv().GetAdaptiveBudget()
                        if mFps and mFps > 0 then fps = mFps end
                    end
                end
                fps = fps or 60
                local budgetMs = profile.frameBudgetMs or 3.4
                LblFps.Text = string.format("%d FPS", fps)
                LblBudget.Text = string.format("Budget: %.2fms", budgetMs)

                local totalCpu = profile.totalCpuMs or 0
                local budgetPct = profile.budgetUsedPercent or 0
                LblCpu.Text = string.format("%.2fms", totalCpu)
                LblBudgetPct.Text = string.format("%.1f%% of Budget", budgetPct)
                if budgetPct > 80 then LblCpu.TextColor3 = Color3.fromRGB(255, 80, 80)
                elseif budgetPct > 50 then LblCpu.TextColor3 = Color3.fromRGB(255, 180, 50)
                else LblCpu.TextColor3 = Color3.fromRGB(100, 220, 140) end

                local heapMb = (profile.memory and profile.memory.heapMb) or (math.floor(((gcinfo() or 0) / 1024) * 10) / 10)
                LblMem.Text = string.format("%.1f MB", heapMb)
                LblGc.Text = "Luau Heap Memory"

                local activeTasks = profile.totalActiveTasks or 0
                local totalTasks = profile.totalTasks or 0
                local activeLoops = profile.totalActiveLoops or profile.totalLoops or 0
                local totalLoops = profile.totalLoops or 0
                local combinedActive = activeTasks + activeLoops
                local combinedTotal = totalTasks + totalLoops
                LblTasks.Text = string.format("%d Active / %d Total", combinedActive, combinedTotal)
                LblTaskSub.Text = string.format("%d Tasks • %d Loops", totalTasks, totalLoops)

                -- Periodic game tasks scan (every 2.5s) to keep native task count updated
                if tick() - lastGameScanTime >= 2.5 then
                    lastGameScanTime = tick()
                    pcall(ScanGameTasks)
                    if tasksSubMode == "active" and BtnAdvanced then
                        local c = #DiscoveredGameTaskOrder
                        BtnAdvanced.Text = (c > 0) and string.format("🌐 Native Tasks (%d)", c) or "🌐 Native Tasks"
                    end
                end

                -- Record performance sample every 0.5s for rolling sparkline graphs
                if tick() - perfHistory.lastSampleTime >= 0.5 then
                    perfHistory.lastSampleTime = tick()
                    local curPing = 30
                    pcall(function()
                        local statsService = game:GetService("Stats")
                        if statsService and statsService.Network and statsService.Network.ServerStatsItem then
                            curPing = math.round(statsService.Network.ServerStatsItem["Data Ping"]:GetValue())
                        end
                    end)
                    recordPerfSample(fps, totalCpu, heapMb, curPing)
                end

                -- 4. Reconcile Active Tab Rows
                local filterText = SearchBox.Text:lower()

                if currentTab == "Tasks" then
                    if tasksSubMode == "advanced" then
                        local seenIds = {}
                        local visibleCount = 0
                        local rawGameTasks = DiscoveredGameTaskOrder or {}
                        local gameTasks = {}
                        for _, gt in ipairs(rawGameTasks) do
                            table.insert(gameTasks, gt)
                        end
                        if TableSortState.Game and TableSortState.Game.colId then
                            sortGameTaskList(gameTasks, TableSortState.Game.colId, TableSortState.Game.ascending)
                        end
                        for idx, entry in ipairs(gameTasks) do
                            seenIds[entry.id] = true
                            local textMatches = (filterText == "")
                                or (entry.name and entry.name:lower():find(filterText, 1, true))
                                or (entry.id and entry.id:lower():find(filterText, 1, true))
                                or (entry.event and entry.event:lower():find(filterText, 1, true))

                            if textMatches then
                                visibleCount = visibleCount + 1
                                renderGameTaskRow(entry, visibleCount)
                            else
                                local r = cachedGameRows[entry.id]
                                if r then r.Visible = false end
                            end
                        end
                        for id, r in pairs(cachedGameRows) do
                            if not seenIds[id] then
                                r:Destroy()
                                cachedGameRows[id] = nil
                            end
                        end
                        EmptyGame.Visible = (visibleCount == 0)
                        if visibleCount == 0 then
                            if filterText ~= "" then
                                EmptyGame.Text = "No game tasks match filter '" .. SearchBox.Text .. "'."
                            else
                                EmptyGame.Text = "No game tasks discovered. Click 'Rescan' to query RunService."
                            end
                        end
                    else
                        if not TaskDrag.isDragging then
                            local seenIds = {}
                            local visibleCount = 0
                            local rawTasks = profile.tasks or {}
                            local tasks = {}
                            for _, t in ipairs(rawTasks) do
                                table.insert(tasks, t)
                            end
                            if TableSortState.Tasks and TableSortState.Tasks.colId then
                                sortTaskList(tasks, TableSortState.Tasks.colId, TableSortState.Tasks.ascending)
                            end
                            for idx, taskObj in ipairs(tasks) do
                                local textMatches = (filterText == "")
                                    or (taskObj.name and taskObj.name:lower():find(filterText, 1, true))
                                    or (taskObj.id and taskObj.id:lower():find(filterText, 1, true))
                                    or (taskObj.event and taskObj.event:lower():find(filterText, 1, true))

                                local isExec = (taskObj.isExecutor ~= false)
                                local sourceMatches = (currentSourceFilter == "all")
                                    or (currentSourceFilter == "executor" and isExec)
                                    or (currentSourceFilter == "game" and not isExec)

                                if textMatches and sourceMatches then
                                    seenIds[taskObj.id] = true
                                    visibleCount = visibleCount + 1
                                    renderTaskRow(taskObj, visibleCount)
                                else
                                    local r = cachedTaskRows[taskObj.id]
                                    if r then r.Visible = false end
                                end
                            end
                            for id, r in pairs(cachedTaskRows) do
                                if not seenIds[id] then
                                    r:Destroy()
                                    cachedTaskRows[id] = nil
                                end
                            end
                            EmptyTasks.Visible = (visibleCount == 0)
                            if visibleCount == 0 then
                                local nativeCount = #DiscoveredGameTaskOrder
                                if filterText ~= "" and currentSourceFilter ~= "all" then
                                    EmptyTasks.Text = string.format("No %s tasks match filter '%s'.", currentSourceFilter, SearchBox.Text)
                                elseif filterText ~= "" then
                                    EmptyTasks.Text = "No tasks match filter '" .. SearchBox.Text .. "'."
                                elseif currentSourceFilter ~= "all" then
                                    EmptyTasks.Text = string.format("No active %s tasks registered in Virtual Scheduler.", currentSourceFilter)
                                else
                                    if nativeCount > 0 then
                                        EmptyTasks.Text = string.format("No Virtual Scheduler tasks registered yet.\n\nClick '🌐 Native Tasks (%d)' below to inspect and throttle Roblox engine connections,\nor switch to the 'Loops' tab to monitor running while/repeat loops.", nativeCount)
                                    else
                                        EmptyTasks.Text = "No active tasks registered in Virtual Scheduler.\nSwitch to the 'Loops' tab to monitor running while/repeat loops."
                                    end
                                end
                            end
                        end
                    end

                elseif currentTab == "Loops" then
                    if not LoopDrag.isDragging then
                        local seenIds = {}
                        local visibleCount = 0
                        local rawLoops = (profile.loops) or (getgenv().GetLoopProfile and getgenv().GetLoopProfile().loops) or {}
                        local loops = {}
                        for _, l in ipairs(rawLoops) do
                            table.insert(loops, l)
                        end
                        if TableSortState.Loops and TableSortState.Loops.colId then
                            sortLoopList(loops, TableSortState.Loops.colId, TableSortState.Loops.ascending)
                        end
                        for idx, loopObj in ipairs(loops) do
                            local textMatches = (filterText == "")
                                or (loopObj.name and loopObj.name:lower():find(filterText, 1, true))
                                or (loopObj.id and loopObj.id:lower():find(filterText, 1, true))
                                or (loopObj.caller and loopObj.caller:lower():find(filterText, 1, true))

                            local isExec = (loopObj.isExecutor ~= false)
                            local sourceMatches = (currentSourceFilter == "all")
                                or (currentSourceFilter == "executor" and isExec)
                                or (currentSourceFilter == "game" and not isExec)

                            if textMatches and sourceMatches then
                                seenIds[loopObj.id] = true
                                visibleCount = visibleCount + 1
                                renderLoopRow(loopObj, visibleCount)
                            else
                                local r = cachedLoopRows[loopObj.id]
                                if r then r.Visible = false end
                            end
                        end
                        for id, r in pairs(cachedLoopRows) do
                            if not seenIds[id] then
                                r:Destroy()
                                cachedLoopRows[id] = nil
                                loopRowDragging[id] = nil
                            end
                        end
                        EmptyLoops.Visible = (visibleCount == 0)
                        if visibleCount == 0 then
                            if filterText ~= "" and currentSourceFilter ~= "all" then
                                EmptyLoops.Text = string.format("No %s loops match filter '%s'.", currentSourceFilter, SearchBox.Text)
                            elseif filterText ~= "" then
                                EmptyLoops.Text = "No loops match filter '" .. SearchBox.Text .. "'."
                            elseif currentSourceFilter ~= "all" then
                                EmptyLoops.Text = string.format("No active %s while/repeat loops detected.", currentSourceFilter)
                            else
                                EmptyLoops.Text = "No active while/repeat loops detected."
                            end
                        end
                    end

                elseif currentTab == "Performance" then
                    updatePerformanceUI(profile)

                elseif currentTab == "Startup" then
                    if refreshStartupTab then
                        refreshStartupTab()
                    end
                end
            end
            end) -- end pcall
        end
    end
end)

-- ==============================================================================
-- WIRING FOOTER BUTTONS
-- ==============================================================================

-- Tasks Footer Buttons

BtnPauseAll.MouseButton1Click:Connect(function()
    local profile = getgenv().GetSchedulerProfile and getgenv().GetSchedulerProfile()
    if profile and profile.tasks then
        local willPause = (BtnPauseAll.Text == "⏸ Pause All")
        for _, t in ipairs(profile.tasks) do
            if getgenv().SetSchedulerTaskPaused then
                getgenv().SetSchedulerTaskPaused(t.id, willPause)
            end
        end
        BtnPauseAll.Text = if willPause then "▶ Resume All" else "⏸ Pause All"
    end
end)

BtnKillAll.MouseButton1Click:Connect(function()
    if getgenv().UnloadAllTasks then
        getgenv().UnloadAllTasks()
    end
end)

-- Game Tasks Footer Buttons
BtnRescanGame.MouseButton1Click:Connect(function()
    ScanGameTasks()
    BtnRescanGame.Text = "✓ Scanned"
    task.delay(1.0, function()
        if BtnRescanGame then
            BtnRescanGame.Text = "🔄 Rescan"
        end
    end)
end)

BtnIngestAllGame.MouseButton1Click:Connect(function()
    local ingestedCount = 0
    for _, entry in ipairs(DiscoveredGameTaskOrder) do
        if not entry.isIngested then
            local ok = IngestGameTask(entry.id)
            if ok then ingestedCount = ingestedCount + 1 end
        end
    end
    BtnIngestAllGame.Text = string.format("✓ Ingested %d", ingestedCount)
    task.delay(1.5, function()
        if BtnIngestAllGame then
            BtnIngestAllGame.Text = "📥 Ingest All"
        end
    end)
end)

BtnEjectAllGame.MouseButton1Click:Connect(function()
    if table.clear then
        table.clear(persistedIngestedKeys)
    else
        for k in pairs(persistedIngestedKeys) do
            persistedIngestedKeys[k] = nil
        end
    end
    getgenv()._VirtualSchedulerPersistedIngestedKeys = persistedIngestedKeys
    local ejectedCount = 0
    for _, entry in ipairs(DiscoveredGameTaskOrder) do
        if entry.isIngested then
            local ok = EjectGameTask(entry.id)
            if ok then ejectedCount = ejectedCount + 1 end
        end
    end
    BtnEjectAllGame.Text = string.format("✓ Ejected %d", ejectedCount)
    task.delay(1.5, function()
        if BtnEjectAllGame then
            BtnEjectAllGame.Text = "📤 Eject All"
        end
    end)
end)

-- Loops Footer Buttons
BtnPauseAllLoops.MouseButton1Click:Connect(function()
    if getgenv().PauseAllLoops then
        local isPaused = getgenv().PauseAllLoops(not loopsPausedAll)
        BtnPauseAllLoops.Text = if isPaused then "▶ Resume All Loops" else "⏸ Pause All Loops"
        BtnPauseAllLoops.BackgroundColor3 = if isPaused then Color3.fromRGB(25, 55, 35) else Color3.fromRGB(28, 45, 70)
    end
end)

BtnKillAllLoops.MouseButton1Click:Connect(function()
    if getgenv().KillAllLoops then
        getgenv().KillAllLoops()
    end
end)

-- Performance Footer Buttons
BtnResetGraphs.MouseButton1Click:Connect(function()
    table.clear(perfHistory.fps)
    table.clear(perfHistory.cpu)
    table.clear(perfHistory.mem)
    table.clear(perfHistory.ping)
    for i = 1, 60 do
        table.insert(perfHistory.fps, measuredFps or 60)
        table.insert(perfHistory.cpu, 0.05)
        table.insert(perfHistory.mem, math.floor(((gcinfo() or 0) / 1024) * 10) / 10)
        table.insert(perfHistory.ping, 30)
    end
    BtnResetGraphs.Text = "✓ Reset"
    task.delay(1.0, function()
        if BtnResetGraphs then BtnResetGraphs.Text = "🔄 Reset History" end
    end)
end)

-- Startup Footer Buttons
BtnRescanStartup.MouseButton1Click:Connect(function()
    BtnRescanStartup.Text = "✓ Rescanned"
    for k, r in pairs(cachedStartupRows) do
        r:Destroy()
        cachedStartupRows[k] = nil
    end
    task.delay(1.0, function()
        if BtnRescanStartup then BtnRescanStartup.Text = "🔄 Rescan Autoexec" end
    end)
end)

CloseBtn.MouseButton1Click:Connect(function()
    ScreenGui.Enabled = false
end)

-- UpdateBadge wired to Bootloader's Root-of-Trust Update Gate
if UpdateBadge then
    UpdateBadge.MouseButton1Click:Connect(function()
        if type(getgenv().OpenOmniUpdateGate) == "function" then
            getgenv().OpenOmniUpdateGate()
        end
    end)
end

-- ==============================================================================
-- KEYBIND & TOGGLE HANDLER (Shift + F8)
-- ==============================================================================

toggleHUD = function(forcedState)
    if forcedState ~= nil then
        ScreenGui.Enabled = forcedState
    else
        ScreenGui.Enabled = not ScreenGui.Enabled
    end
    if ScreenGui.Enabled then
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
    end
end

local keybindConnection
keybindConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if input.KeyCode == Enum.KeyCode.F8 then
        local isShiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
        if isShiftHeld then
            toggleHUD()
        end
    end
end)

-- Final Mount
ScreenGui.Parent = guiParent

-- Clean up hook

cleanUpHUD = function()
    running = false
    if keybindConnection then
        pcall(function() keybindConnection:Disconnect() end)
        keybindConnection = nil
    end
    for _, conn in ipairs(hudWindowConnections) do
        pcall(function() conn:Disconnect() end)
    end
    hudWindowConnections = {}
    for _, r in pairs(cachedGameRows) do pcall(function() r:Destroy() end) end
    cachedGameRows = {}
    for _, r in pairs(cachedTaskRows) do pcall(function() r:Destroy() end) end
    cachedTaskRows = {}
    for _, r in pairs(cachedLoopRows) do pcall(function() r:Destroy() end) end
    cachedLoopRows = {}
    for _, r in pairs(cachedStartupRows) do pcall(function() r:Destroy() end) end
    cachedStartupRows = {}
    TableHeaders = {}
    activeDividerDrag = nil
    if ScreenGui then
        pcall(function() ScreenGui:Destroy() end)
        ScreenGui = nil
    end
    -- Clear HUD exports & global state
    getgenv()._KernelTaskManagerGui = nil
    getgenv()._KernelTaskManagerCleanUp = nil
    getgenv().ToggleTaskManagerHUD = nil
    getgenv()._OmniTaskManager_HandleDividerDrag = nil
    getgenv()._OmniTaskManager_AutoFitColumn = nil
    getgenv()._OmniTaskManager_SortTable = nil
    getgenv()._OmniTaskManager_GetSortState = nil
end

getgenv()._KernelTaskManagerGui = ScreenGui
end
initHUD()

-- ==============================================================================
-- UNIFIED EXPORTS & TEARDOWN
-- ==============================================================================

local function unifiedCleanUp(isTeardown)
    if type(cleanUpHUD) == "function" then
        pcall(cleanUpHUD)
    end
    if type(cleanUpScheduler) == "function" then
        pcall(cleanUpScheduler, isTeardown)
    end
    getgenv()._KernelTaskManagerUnifiedCleanUp = nil
    getgenv()._KernelTaskManagerCleanUp = nil
    getgenv()._VirtualSchedulerCleanUp = nil
    getgenv()._KernelTaskManagerGui = nil
    getgenv().ToggleTaskManagerHUD = nil
    getgenv()._KernelTaskManagerLoaded = nil
    getgenv()._VirtualSchedulerLoaded = nil
    getgenv()._OmniTaskManager_HandleDividerDrag = nil
    getgenv()._OmniTaskManager_AutoFitColumn = nil
    getgenv()._OmniTaskManager_SortTable = nil
    getgenv()._OmniTaskManager_GetSortState = nil
end

getgenv()._KernelTaskManagerCleanUp = cleanUpHUD
getgenv()._VirtualSchedulerCleanUp = cleanUpScheduler
getgenv()._KernelTaskManagerUnifiedCleanUp = unifiedCleanUp
getgenv()._KernelTaskManagerLoaded = true
getgenv()._VirtualSchedulerLoaded = true
getgenv().ToggleTaskManagerHUD = toggleHUD

print("[KernelTaskManager]: Unified Runtime Micro-Kernel & Task Manager HUD initialized. Press Shift + F8 to open.")