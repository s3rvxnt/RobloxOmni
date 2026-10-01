--[[
    Adaptive Frame-Budgeted Autoexec Bootloader (4-Tier Ring Architecture)
    ----------------------------------------------------------------------
    - Ring 0: Bootloader & Kernel (autoexec/kernel/) -> Frame 0, NO yields, purely environment & hooks
    - Ring 1: DataModel Level (game ~= nil) -> PreInit / Universal / PlaceId / UniverseId (nodelay)
    - Ring 2: Network Client Level (game.Players ~= nil) -> GameLoaded (IsLoaded, 6ms budget)
    - Ring 3: UserSpace Level (game.Players.LocalPlayer ~= nil) -> Account-scoped, CharacterReady, Deferred
    - Adaptive Frame Budgeting: yields to Heartbeat if a frame exceeds TARGET_BUDGET_MS (6ms)
    - Deterministic load order: Priority descending, then Alphabetical ascending
    - Multi-scope routing: Universal, UniverseId, PlaceId, Account-scoped
    - Ignores: Off/, Disabled/, .ignore/, and non-script extensions (.json, .png, .bak, .off)
    - Fault-tolerant: xpcall error boundaries per script with full stack traces
    - Non-blocking: Coroutine-isolated execution prevents top-level loops from freezing bootloader
    - Telemetry: Emits Bootloader_Status.json with per-script timing and status
]]

local bootStart = os.clock()

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local TARGET_BUDGET_MS = 6.0 -- Max Lua ms per frame before yielding to host engine

if type(isfolder) ~= "function" or type(listfiles) ~= "function" then
    print("[Bootloader]: Incompatible exploit environment.")
    return
end

-- ==============================================================================
-- SAFE MODE & CRASH SENTINEL (Zero-Delay Fault Recovery)
-- ==============================================================================
local SAFE_MODE_LOCK = "SAFE_MODE.lock"
local RUNNING_LOCK = "Bootloader_Running.lock"

local SafeMode = false
local SafeModeReason = nil

-- Check 1: Manual safe mode lockfile (from RejoinSafeMode() or install.bat)
if isfile and isfile(SAFE_MODE_LOCK) then
    SafeMode = true
    SafeModeReason = "ManualLock"
    pcall(delfile, SAFE_MODE_LOCK)
-- Check 2: Crash sentinel (previous launch terminated before boot completed)
elseif isfile and isfile(RUNNING_LOCK) then
    SafeMode = true
    SafeModeReason = "CrashSentinel"
    pcall(delfile, RUNNING_LOCK)
    warn("[Bootloader]: ⚠️ PREVIOUS LAUNCH CRASH DETECTED — Activating Safe Mode!")
-- Check 3: Shift key pre-held at Frame 0 (zero millisecond delay added)
else
    pcall(function()
        if UserInputService and UserInputService.IsKeyDown then
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
                SafeMode = true
                SafeModeReason = "ShiftKey"
            end
        end
    end)
end

if SafeMode then
    print(string.format("[Bootloader]: ⚠️ SAFE MODE ENGAGED (Reason: %s) — Bypassing user autoexec scripts.", tostring(SafeModeReason)))
else
    -- Write running lockfile for crash detection
    pcall(writefile, RUNNING_LOCK, tostring(os.time()))
end

-- Global Rejoin in Safe Mode helper
getgenv().RejoinSafeMode = function()
    pcall(writefile, SAFE_MODE_LOCK, "true")
    local TeleportService = game:GetService("TeleportService")
    local Players = game:GetService("Players")
    local lp = Players and Players.LocalPlayer
    if TeleportService and game.PlaceId then
        print("[Bootloader]: Rejoining into Safe Mode...")
        if lp and game.JobId and game.JobId ~= "" then
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp)
        else
            TeleportService:Teleport(game.PlaceId, lp)
        end
    end
end

-- Timeout helper for resilient engine waits
local function waitFor(predicate, timeoutSec, pollInterval)
    local start = os.clock()
    pollInterval = pollInterval or 0.1
    while not predicate() do
        if (os.clock() - start) >= timeoutSec then
            return false
        end
        task.wait(pollInterval)
    end
    return true
end

-- Ensure baseline stage directories exist
local BASE_STAGE_DIRS = {
    "autoexec",
    "autoexec/kernel",
    "autoexec/preinit",
    "autoexec/gameloaded",
    "autoexec/characterloaded",
    "autoexec/deferred"
}
for _, dir in ipairs(BASE_STAGE_DIRS) do
    if not isfolder(dir) then pcall(makefolder, dir) end
end

-- ==============================================================================
-- GITHUB STAGE AUTO-MIRRORING & DYNAMIC SYNC
-- ==============================================================================
local GITHUB_REPO_RAW = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/"
local MANIFEST_URL = GITHUB_REPO_RAW .. "manifest.json"

local DEFAULT_STAGE_MIRRORS = {
    {
        repoPath = "kernel/KernelTaskManager.lua",
        localPath = "autoexec/kernel/KernelTaskManager.lua",
        name = "KernelTaskManager",
        desc = "Kernel Task Manager & Runtime Micro-Kernel (Shift + F8)"
    }
}

local function fetchGithubScript(url)
    local ok, content = pcall(function()
        if type(game.HttpGet) == "function" then
            return game:HttpGet(url)
        elseif type(httpget) == "function" then
            return httpget(url)
        elseif type(request) == "function" then
            local res = request({ Url = url, Method = "GET" })
            return res and res.Body
        end
    end)
    if ok and content and type(content) == "string" and #content > 100 and not content:find("404: Not Found") and not content:find("400: Invalid Request") then
        return content
    end
    return nil
end

-- Try fetching dynamic manifest from GitHub
local activeMirrors = DEFAULT_STAGE_MIRRORS
local manifestRaw = fetchGithubScript(MANIFEST_URL .. "?v=" .. tostring(os.time()))
if manifestRaw and HttpService then
    local ok, parsed = pcall(function() return HttpService:JSONDecode(manifestRaw) end)
    if ok and parsed and type(parsed.stages) == "table" and #parsed.stages > 0 then
        activeMirrors = parsed.stages
    end
end

for _, mirror in ipairs(activeMirrors) do
    local localPath = mirror.localPath or mirror.path
    local repoPath = mirror.repoPath or mirror.url
    local mirrorName = mirror.name or localPath:match("[^/\\]+$") or "Component"

    -- Ensure parent folder exists
    local parentFolder = localPath:match("^(.*)[/\\][^/\\]+$")
    if parentFolder and not isfolder(parentFolder) then
        pcall(makefolder, parentFolder)
    end

    local fileExists = isfile(localPath)
    local existingContent = nil
    if fileExists then
        local ok, data = pcall(readfile, localPath)
        if ok and data and #data > 100 then
            existingContent = data
        end
    end

    -- Construct remote URL (handles relative repoPath or full URL)
    local remoteUrl = repoPath
    if not remoteUrl:find("^https?://") then
        remoteUrl = GITHUB_REPO_RAW .. remoteUrl
    end

    -- Check GitHub for updates with cache-busting timestamp
    local latestContent = fetchGithubScript(remoteUrl .. "?v=" .. tostring(os.time()))
    if latestContent then
        if not existingContent then
            local writeOk, writeErr = pcall(writefile, localPath, latestContent)
            if writeOk then
                print(string.format("[Bootloader]: Successfully installed %s -> %s", mirrorName, localPath))
            else
                warn(string.format("[Bootloader]: Failed to write %s: %s", localPath, tostring(writeErr)))
            end
        elseif existingContent ~= latestContent then
            local writeOk, writeErr = pcall(writefile, localPath, latestContent)
            if writeOk then
                print(string.format("[Bootloader]: Auto-updated %s to latest version from GitHub!", mirrorName))
            else
                warn(string.format("[Bootloader]: Failed to update %s: %s", localPath, tostring(writeErr)))
            end
        else
            print(string.format("[Bootloader]: %s is up-to-date.", mirrorName))
        end
    else
        if fileExists then
            print(string.format("[Bootloader]: GitHub unreachable. Using cached %s.", mirrorName))
        else
            warn(string.format("[Bootloader]: Could not fetch %s from GitHub and no local cache exists.", mirrorName))
        end
    end
end

local PlaceIdStr = tostring(game.PlaceId)
local GameIdStr = tostring(game.GameId or 0)

-- Stage normalization lookup table
local STAGES = {
    kernel = "Kernel",
    preinit = "PreInit",
    nodelay = "PreInit",
    gameloaded = "GameLoaded",
    gameload = "GameLoaded",
    characterready = "CharacterReady",
    characterloaded = "CharacterReady",
    deferred = "Deferred",
    deffered = "Deferred"
}

-- Queue buckets
local Queues = {
    Kernel = {},
    PreInit = {},
    GameLoaded = {},
    CharacterReady = {},
    Deferred = {}
}

local Telemetry = {
    timestamp = os.time(),
    placeId = game.PlaceId,
    gameId = game.GameId,
    account = "Pending Replicating",
    safeMode = SafeMode,
    safeModeReason = SafeModeReason,
    discovered = 0,
    executed = 0,
    success = 0,
    errors = 0,
    stages = {
        Kernel = 0,
        PreInit = 0,
        GameLoaded = 0,
        CharacterReady = 0,
        Deferred = 0
    },
    scripts = {}
}

-- Emit structured telemetry to workspace
local function emitTelemetry()
    pcall(function()
        if writefile and HttpService then
            writefile("Bootloader_Status.json", HttpService:JSONEncode(Telemetry))
        end
    end)
end

-- Helpers
local function isIgnoredFolder(folderName)
    if not folderName then return true end
    local lower = folderName:lower()
    return lower == "off" or lower == "disabled" or lower == ".ignore" 
        or folderName:sub(1, 1) == "_" or folderName:sub(1, 1) == "."
end

local function isScriptFile(path)
    if not path or isfolder(path) then return false end
    local lower = path:lower()
    local name = lower:match("[^/\\]+$")
    if name == "bootloader.lua" or name == "customautoexec.lua" then return false end
    if lower:match("%.off$") or lower:match("%.disabled$") or lower:match("%.bak$") or lower:match("%.tmp$") then
        return false
    end
    return lower:match("%.luau$") ~= nil or lower:match("%.lua$") ~= nil or lower:match("%.txt$") ~= nil
end

local function parsePragmas(filePath)
    local meta = {
        file = filePath,
        name = filePath:match("[^/\\]+$") or filePath,
        stage = nil,
        priority = 0
    }
    
    pcall(function()
        if isfile(filePath) then
            local header = readfile(filePath)
            -- Read up to first 4000 characters for pragmas
            local snippet = header:sub(1, 4000)
            for line in snippet:gmatch("[^\r\n]+") do
                local trimmed = line:match("^%s*(.-)%s*$")
                if trimmed and trimmed:sub(1, 3) == "--!" then
                    local pragma, sep, val = trimmed:match("^%-%-!([%w_]+)([:%s=]+)(.-)%s*$")
                    if pragma and val then
                        val = val:match("^%s*(.-)%s*$")
                        local lowerPragma = pragma:lower()
                        if lowerPragma == "stage" then
                            local stageKey = val:lower():gsub("[%s_]+", "")
                            if STAGES[stageKey] then
                                meta.stage = STAGES[stageKey]
                            end
                        elseif lowerPragma == "priority" and tonumber(val) then
                            meta.priority = tonumber(val)
                        elseif lowerPragma == "name" and val ~= "" then
                            meta.name = val
                        end
                    end
                elseif trimmed and trimmed:sub(1, 2) ~= "--" and trimmed ~= "" then
                    -- Reached non-comment code
                    break
                end
            end
        end
    end)
    return meta
end

local registeredBasenames = {}
local executedFiles = {}

local function registerScript(filePath, defaultStage)
    if not isScriptFile(filePath) then return end
    local meta = parsePragmas(filePath)
    meta.stage = meta.stage or defaultStage or "GameLoaded"

    -- Deduplicate scripts by stage + canonical basename (e.g. KernelTaskManager.lua vs KernelTaskManager.txt)
    local rawName = meta.name:gsub("%.%w+$", ""):lower()
    local dedupKey = meta.stage .. ":" .. rawName
    if registeredBasenames[dedupKey] then
        -- Prefer .lua over .txt if both exist
        if meta.file:lower():match("%.lua$") or meta.file:lower():match("%.luau$") then
            for idx, existing in ipairs(Queues[meta.stage]) do
                local existingRaw = existing.name:gsub("%.%w+$", ""):lower()
                if existingRaw == rawName then
                    Queues[meta.stage][idx] = meta
                    break
                end
            end
        end
        return
    end
    registeredBasenames[dedupKey] = true

    table.insert(Queues[meta.stage], meta)
    Telemetry.discovered = Telemetry.discovered + 1
    Telemetry.stages[meta.stage] = (Telemetry.stages[meta.stage] or 0) + 1
end

local function scanDirectory(dirPath, defaultStage)
    if not isfolder(dirPath) then return end
    for _, item in ipairs(listfiles(dirPath)) do
        if isfolder(item) then
            local folderName = item:match("[^/\\]+$")
            if not isIgnoredFolder(folderName) then
                local lowerFolder = folderName:lower()
                if lowerFolder == "kernel" or lowerFolder == "root" then
                    scanDirectory(item, "Kernel")
                elseif lowerFolder == "preinit" or lowerFolder == "nodelay" then
                    scanDirectory(item, "PreInit")
                elseif lowerFolder == "gameloaded" or lowerFolder == "game_loaded" then
                    scanDirectory(item, "GameLoaded")
                elseif lowerFolder == "characterready" or lowerFolder == "characterloaded" or lowerFolder == "character_loaded" or lowerFolder == "character_ready" then
                    scanDirectory(item, "CharacterReady")
                elseif lowerFolder == "deferred" or lowerFolder == "deffered" then
                    scanDirectory(item, "Deferred")
                else
                    scanDirectory(item, defaultStage)
                end
            end
        else
            registerScript(item, defaultStage)
        end
    end
end

-- ==========================================
-- SCRIPT EXECUTION ENGINE
-- ==========================================

local function executeScript(meta)
    local file = meta.file
    if executedFiles[file] then return end
    executedFiles[file] = true

    local scriptName = meta.name
    local compileStart = os.clock()
    local compiledFn, syntaxErr = nil, nil
    
    if type(readfile) == "function" and isfile(file) then
        local ok, content = pcall(readfile, file)
        if ok and content then
            compiledFn, syntaxErr = loadstring(content, "@" .. scriptName)
        else
            syntaxErr = "Failed to read file from disk."
        end
    elseif type(loadfile) == "function" then
        compiledFn, syntaxErr = loadfile(file)
    end
    
    local compileMs = (os.clock() - compileStart) * 1000
    local execMs = 0
    local status = "SUCCESS"
    local errorMsg = nil
    
    local scriptEntry = {
        name = scriptName,
        file = file,
        stage = meta.stage,
        priority = meta.priority,
        status = "PENDING",
        compileMs = math.floor(compileMs * 100) / 100,
        execMs = 0,
        error = nil
    }

    if compiledFn then
        local execStart = os.clock()
        -- Coroutine-isolated execution: prevents top-level yields or loops from freezing the bootloader
        local thread = coroutine.create(function()
            local success, runtimeErr = xpcall(compiledFn, debug.traceback)
            if not success then
                errorMsg = tostring(runtimeErr)
                warn(string.format("[Bootloader | RUNTIME ERROR]: %s\n%s", scriptName, errorMsg))
                if scriptEntry.status ~= "RUNTIME_ERROR" then
                    if scriptEntry.status == "SUCCESS" then
                        Telemetry.success = math.max(0, Telemetry.success - 1)
                    end
                    scriptEntry.status = "RUNTIME_ERROR"
                    scriptEntry.error = errorMsg
                    Telemetry.errors = Telemetry.errors + 1
                    emitTelemetry()
                end
            end
        end)
        
        local ok, resumeErr = coroutine.resume(thread)
        execMs = (os.clock() - execStart) * 1000
        scriptEntry.execMs = math.floor(execMs * 100) / 100
        
        if not ok or errorMsg then
            status = "RUNTIME_ERROR"
            errorMsg = errorMsg or tostring(resumeErr)
            if scriptEntry.status ~= "RUNTIME_ERROR" then
                Telemetry.errors = Telemetry.errors + 1
            end
            scriptEntry.status = status
            scriptEntry.error = errorMsg
        else
            status = "SUCCESS"
            scriptEntry.status = status
            Telemetry.success = Telemetry.success + 1
        end
    else
        status = "SYNTAX_ERROR"
        errorMsg = tostring(syntaxErr or "Unknown compilation error")
        scriptEntry.status = status
        scriptEntry.error = errorMsg
        Telemetry.errors = Telemetry.errors + 1
        warn(string.format("[Bootloader | SYNTAX ERROR]: %s\n%s", scriptName, errorMsg))
    end
    
    Telemetry.executed = Telemetry.executed + 1
    table.insert(Telemetry.scripts, scriptEntry)
end

local function sortQueue(queue)
    table.sort(queue, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.name:lower() < b.name:lower()
    end)
end

local function runStageWithBudget(stageName, queue)
    if #queue == 0 then return end
    local frameStart = os.clock()
    
    for _, meta in ipairs(queue) do
        if not executedFiles[meta.file] then
            -- Frame budget check: if frame exceeded TARGET_BUDGET_MS (6ms), yield to next engine heartbeat
            if (os.clock() - frameStart) * 1000 >= TARGET_BUDGET_MS then
                RunService.Heartbeat:Wait()
                frameStart = os.clock()
            end
            executeScript(meta)
        end
    end
end

-- ==============================================================================
-- RING 0: KERNEL (Tier 1 - System Hooks, Scheduler & Loop Governor)
-- ==============================================================================
-- Frame 0, NO yields, NO task.wait(), purely environment & hooks.
local bootStart = os.clock()

if isfolder("autoexec/kernel") and not getgenv()._KernelTaskManagerLoaded then
    scanDirectory("autoexec/kernel", "Kernel")
end

sortQueue(Queues.Kernel)

for _, meta in ipairs(Queues.Kernel) do
    executeScript(meta)
end
emitTelemetry()

-- ==============================================================================
-- RING 1: DATAMODEL LEVEL (game ~= nil) - PreInit & Non-Account Discovery
-- ==============================================================================
-- Frame 0, DataModel is valid. game.PlaceId and game.GameId are accessible.

if not SafeMode then
    for _, item in ipairs(listfiles("autoexec")) do
        if isfolder(item) then
            local folderName = item:match("[^/\\]+$")
            if not isIgnoredFolder(folderName) then
                local lowerFolder = folderName:lower()
                if lowerFolder == "kernel" or lowerFolder == "root" then
                    -- Handled in Ring 0
                elseif lowerFolder == "preinit" or lowerFolder == "nodelay" then
                    -- Universal Frame-0 PreInit (RemoteExecute, utilities, etc.)
                    scanDirectory(item, "PreInit")
                elseif lowerFolder == "universal" or lowerFolder == "common" or lowerFolder == "shared" then
                    -- Universal folder
                    scanDirectory(item, "GameLoaded")
                elseif folderName == PlaceIdStr 
                    or folderName:sub(1, #PlaceIdStr + 3) == PlaceIdStr .. " - " 
                    or folderName:sub(1, #PlaceIdStr + 1) == PlaceIdStr .. "_"
                    or lowerFolder == "place_" .. PlaceIdStr 
                    or lowerFolder:sub(1, #PlaceIdStr + 7) == "place_" .. PlaceIdStr .. " - "
                    or lowerFolder:sub(1, #PlaceIdStr + 7) == "place_" .. PlaceIdStr .. "_"
                    or lowerFolder == "place" .. PlaceIdStr then
                    -- Place-specific folder (scans nodelay/ as PreInit, others as GameLoaded)
                    scanDirectory(item, "GameLoaded")
                elseif (GameIdStr ~= "0" and (folderName == GameIdStr 
                    or folderName:sub(1, #GameIdStr + 3) == GameIdStr .. " - " 
                    or folderName:sub(1, #GameIdStr + 1) == GameIdStr .. "_"
                    or lowerFolder == "universe_" .. GameIdStr 
                    or lowerFolder:sub(1, #GameIdStr + 10) == "universe_" .. GameIdStr .. " - "
                    or lowerFolder == "game_" .. GameIdStr
                    or lowerFolder:sub(1, #GameIdStr + 6) == "game_" .. GameIdStr .. " - ")) then
                    -- Universe-specific folder
                    scanDirectory(item, "GameLoaded")
                end
            end
        else
            registerScript(item, "GameLoaded")
        end
    end

    sortQueue(Queues.PreInit)
    sortQueue(Queues.GameLoaded)
    sortQueue(Queues.CharacterReady)
    sortQueue(Queues.Deferred)

    -- Execute PreInit concurrently at Frame 0 (nodelay, e.g. RemoteExecute)
    for _, meta in ipairs(Queues.PreInit) do
        task.spawn(executeScript, meta)
    end
else
    print("[Bootloader]: Safe Mode Active — Bypassing Ring 1 (PreInit).")
end
emitTelemetry()

-- ==============================================================================
-- RINGS 2 & 3: NETWORK CLIENT & USERSPACE LIFECYCLE (Async)
-- ==============================================================================

task.spawn(function()
    if SafeMode then
        print("[Bootloader]: Safe Mode Active — Bypassing Ring 2 (GameLoaded), Ring 3 (CharacterReady), and Ring 4 (Deferred).")
        local totalBootMs = (os.clock() - bootStart) * 1000
        Telemetry.totalDurationMs = math.floor(totalBootMs * 100) / 100
        emitTelemetry()
        return
    end

    -- RING 2: NETWORK CLIENT LEVEL (game:GetService("Players") ~= nil & game:IsLoaded())
    if not game:IsLoaded() then
        local loadedOk = waitFor(function() return game:IsLoaded() end, 8.0)
        if not loadedOk then
            warn("[Bootloader]: game:IsLoaded() timed out after 8s — proceeding with GameLoaded stage.")
        end
    end
    
    local Players = game:GetService("Players")
    if not Players then
        waitFor(function() Players = game:GetService("Players"); return Players ~= nil end, 5.0)
    end

    -- Settle render frames after join
    RunService.RenderStepped:Wait()

    -- Execute initial GameLoaded queue with 6ms adaptive budget
    runStageWithBudget("GameLoaded", Queues.GameLoaded)
    emitTelemetry()

    -- RING 3: USERSPACE LEVEL (game.Players.LocalPlayer ~= nil)
    local playerOk = waitFor(function() return Players and Players.LocalPlayer ~= nil end, 10.0)
    if not playerOk then
        warn("[Bootloader]: Players.LocalPlayer timed out after 10s — skipping userspace account stage.")
    else
        local LocalPlayer = Players.LocalPlayer
        local AccountName = LocalPlayer.Name
        Telemetry.account = AccountName

        -- Discover and register Account-scoped directory
        local initialDiscovered = Telemetry.discovered
        for _, item in ipairs(listfiles("autoexec")) do
            if isfolder(item) then
                local folderName = item:match("[^/\\]+$")
                if not isIgnoredFolder(folderName) then
                    local lowerFolder = folderName:lower()
                    if lowerFolder == "account_" .. AccountName:lower() 
                        or lowerFolder == AccountName:lower() 
                        or lowerFolder == "user_" .. AccountName:lower()
                        or lowerFolder:sub(1, #AccountName + 9) == "account_" .. AccountName:lower() .. " - "
                        or lowerFolder:sub(1, #AccountName + 6) == "user_" .. AccountName:lower() .. " - " then
                        
                        scanDirectory(item, "GameLoaded")
                    end
                end
            end
        end

        if Telemetry.discovered > initialDiscovered then
            sortQueue(Queues.GameLoaded)
            sortQueue(Queues.CharacterReady)
            sortQueue(Queues.Deferred)
            -- Run any newly added GameLoaded scripts from the account folder
            runStageWithBudget("GameLoaded", Queues.GameLoaded)
            emitTelemetry()
        end

        -- STAGE 3: CharacterReady (Waits for character spawn with 12s timeout)
        if #Queues.CharacterReady > 0 then
            if not LocalPlayer.Character or not LocalPlayer.Character.Parent then
                local charOk = waitFor(function() return LocalPlayer.Character and LocalPlayer.Character.Parent ~= nil end, 12.0)
                if not charOk then
                    warn("[Bootloader]: Character spawn timed out after 12s — executing CharacterReady queue with timeout guard.")
                end
            end
            RunService.Heartbeat:Wait()
            runStageWithBudget("CharacterReady", Queues.CharacterReady)
        end
        emitTelemetry()
    end

    -- STAGE 4: Deferred (Background / Telemetry)
    if #Queues.Deferred > 0 then
        task.wait(0.5)
        for _, meta in ipairs(Queues.Deferred) do
            if not executedFiles[meta.file] then
                executeScript(meta)
                RunService.Heartbeat:Wait()
            end
        end
    end

    local totalBootMs = (os.clock() - bootStart) * 1000
    Telemetry.totalDurationMs = math.floor(totalBootMs * 100) / 100
    emitTelemetry()

    -- Normal boot completed successfully without crashes: delete running lockfile
    pcall(delfile, RUNNING_LOCK)

    print(string.format("[Bootloader]: Boot completed in %.1fms | Discovered: %d | Executed: %d | Success: %d | Errors: %d",
        totalBootMs, Telemetry.discovered, Telemetry.executed, Telemetry.success, Telemetry.errors))
end)