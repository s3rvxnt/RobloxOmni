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

local CURRENT_OMNI_VERSION = "1.0.0"
local TARGET_BUDGET_MS = 6.0 -- Max Lua ms per frame before yielding to host engine

-- Session duplicate run guard (prevents overlapping concurrent boots)
if (getgenv()._OmniBootloaderRunning or getgenv()._OmniBootloaderLoaded) and not getgenv()._OmniBootloaderHandoffActive then
    print("[Bootloader]: Omni Bootloader is already running/loaded in this session.")
    return
end
getgenv()._OmniBootloaderRunning = true

if type(isfolder) ~= "function" or type(listfiles) ~= "function" then
    print("[Bootloader]: Incompatible exploit environment.")
    getgenv()._OmniBootloaderRunning = false
    return
end

-- String Prefix Helper
local function startsWith(str, prefix)
    if not str or not prefix then return false end
    return str:sub(1, #prefix) == prefix
end

-- Version Comparison Helpers
local function parseVersion(vStr)
    local parts = {}
    for num in tostring(vStr):gmatch("%d+") do
        table.insert(parts, tonumber(num))
    end
    while #parts < 3 do table.insert(parts, 0) end
    return parts
end

local function isNewerVersion(remote, current)
    local r = parseVersion(remote)
    local c = parseVersion(current)
    for i = 1, math.max(#r, #c) do
        local rVal = r[i] or 0
        local cVal = c[i] or 0
        if rVal > cVal then return true end
        if rVal < cVal then return false end
    end
    return false
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
end

-- ==============================================================================
-- DYNAMIC BOOTLOADER HANDOFF (Future-Proof Self-Update Bridge)
-- ==============================================================================
-- If an updated verified bootloader was installed via the Update Gate to workspace,
-- hand off execution seamlessly to the newer version BEFORE writing any locks!
local HANDOFF_LOCK = "Bootloader_Handoff.lock"
local FAILED_VERSION_FILE = "Bootloader_FailedVersion.txt"

-- Check for crashed previous handoff (client froze or crashed during updated bootloader init).
-- Only the outermost bootloader may do this: inside a handoff, the lock on disk is the one
-- our parent just wrote for us, not evidence of a previous crash.
if not getgenv()._OmniBootloaderHandoffActive and isfile and isfile(HANDOFF_LOCK) then
    local crashedVer = nil
    pcall(function() crashedVer = readfile(HANDOFF_LOCK) end)
    pcall(delfile, HANDOFF_LOCK)
    if crashedVer and crashedVer ~= "" then
        pcall(writefile, FAILED_VERSION_FILE, crashedVer)
        warn("[Bootloader]: ⚠️ Updated bootloader v" .. tostring(crashedVer) .. " crashed previous session — blacklisting version.")
    end
end

local blacklistedVersion = nil
if isfile and isfile(FAILED_VERSION_FILE) then
    pcall(function() blacklistedVersion = readfile(FAILED_VERSION_FILE) end)
end

if not getgenv()._OmniBootloaderHandoffActive and not SafeMode then
    local updatedPath = "autoexec/Bootloader_Updated.lua"
    if isfile and isfile(updatedPath) then
        local ok, updatedCode = pcall(readfile, updatedPath)
        if ok and updatedCode and #updatedCode > 500 then
            local updatedVersion = updatedCode:match('CURRENT_OMNI_VERSION%s*=%s*"([^"]+)"')
            -- Skip if not newer than base, OR if this exact version previously failed and hasn't been superseded
            local isEligible = updatedVersion and isNewerVersion(updatedVersion, CURRENT_OMNI_VERSION)
            if isEligible and blacklistedVersion and not isNewerVersion(updatedVersion, blacklistedVersion) then
                isEligible = false
            end

            if isEligible then
                local updatedFn, compileErr = loadstring(updatedCode, "@Bootloader_Updated")
                if updatedFn then
                    -- Set sentinel lock before calling update to catch early client freezes/crashes
                    pcall(writefile, HANDOFF_LOCK, updatedVersion)
                    getgenv()._OmniBootloaderHandoffActive = true
                    getgenv()._OmniRingsStarted = nil

                    local runOk, runErr = pcall(updatedFn)
                    getgenv()._OmniBootloaderHandoffActive = nil
                    pcall(delfile, HANDOFF_LOCK)

                    if runOk and getgenv()._OmniRingsStarted then
                        -- Successfully booted updated version! Clear any older blacklist
                        if blacklistedVersion and isNewerVersion(updatedVersion, blacklistedVersion) then
                            pcall(delfile, FAILED_VERSION_FILE)
                        end
                        return -- Clean handoff complete!
                    elseif runOk and not getgenv()._OmniRingsStarted then
                        -- Update returned early without booting anything!
                        pcall(writefile, FAILED_VERSION_FILE, updatedVersion)
                        warn("[Bootloader]: Updated bootloader v" .. updatedVersion .. " returned early without starting scripts — blacklisting and falling back to base.")
                    elseif not runOk then
                        if getgenv()._OmniRingsStarted then
                            -- Error occurred after scripts were already running — do NOT re-run scripts in base!
                            warn("[Bootloader]: Updated bootloader v" .. updatedVersion .. " encountered runtime error after starting scripts: " .. tostring(runErr))
                            return
                        else
                            -- Early error before any scripts ran — blacklist version and safely fall back to base
                            pcall(writefile, FAILED_VERSION_FILE, updatedVersion)
                            warn("[Bootloader]: Updated bootloader v" .. updatedVersion .. " early runtime error: " .. tostring(runErr) .. " — falling back to base.")
                        end
                    end
                else
                    pcall(writefile, FAILED_VERSION_FILE, updatedVersion)
                    warn("[Bootloader]: Updated bootloader compilation error: " .. tostring(compileErr))
                end
            end
        end
    end
end

if not SafeMode then
    -- Write running lockfile for crash detection during critical init phase
    pcall(writefile, RUNNING_LOCK, tostring(os.time()))
    task.spawn(function()
        local Players = game:GetService("Players")
        local lp = Players.LocalPlayer
        if not lp then
            pcall(function()
                Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
            end)
            lp = Players.LocalPlayer
        end
        if lp then
            pcall(function()
                lp.OnTeleport:Connect(function(state)
                    if state == Enum.TeleportState.Started then
                        pcall(delfile, RUNNING_LOCK)
                    end
                end)
            end)
        end
    end)
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
local GITHUB_REPO_RAW = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/release/"
local MANIFEST_URL = GITHUB_REPO_RAW .. "manifest.json"


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
    if ok and content and type(content) == "string" and #content > 50 then
        if #content < 150 and (content:find("404: Not Found") or content:find("400: Invalid Request")) then
            return nil
        end
        return content
    end
    return nil
end

-- Initial Core Kernel Bootstrap (Only triggers if core kernel is completely missing and wasn't intentionally deleted)
local coreKernelLocal = "autoexec/kernel/KernelTaskManager.lua"
local KERNEL_INIT_MARKER = "Omni_KernelInitialized.marker"
if not isfile(coreKernelLocal) and not isfile(KERNEL_INIT_MARKER) then
    local coreUrl = GITHUB_REPO_RAW .. "kernel/KernelTaskManager.lua?v=" .. tostring(os.time())
    local coreContent = fetchGithubScript(coreUrl)
    if coreContent and #coreContent > 100 then
        local parentDir = coreKernelLocal:match("^(.*)[/\\][^/\\]+$")
        if parentDir and not isfolder(parentDir) then pcall(makefolder, parentDir) end
        local ok, err = pcall(writefile, coreKernelLocal, coreContent)
        if ok then
            pcall(writefile, KERNEL_INIT_MARKER, tostring(os.time()))
            print("[Bootloader]: Initialized core KernelTaskManager -> " .. coreKernelLocal)
        else
            warn("[Bootloader]: Failed to bootstrap core kernel: " .. tostring(err))
        end
    end
elseif isfile(coreKernelLocal) and not isfile(KERNEL_INIT_MARKER) then
    pcall(writefile, KERNEL_INIT_MARKER, tostring(os.time()))
end

-- ==============================================================================
-- ROOT OF TRUST: OMNI SECURITY & TRANSPARENCY GATE
-- ==============================================================================
local function getGuiParent()
    local okCG, CoreGui = pcall(function() return game:GetService("CoreGui") end)
    if okCG and CoreGui then
        local okP = pcall(function()
            local test = Instance.new("Folder")
            test.Parent = CoreGui
            test:Destroy()
        end)
        if okP then return CoreGui end
    end
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local Players = game:GetService("Players")
    local start = os.clock()
    while not Players.LocalPlayer and (os.clock() - start) < 15 do
        task.wait(0.1)
    end
    if Players.LocalPlayer then
        return Players.LocalPlayer:WaitForChild("PlayerGui", 10)
    end
    return nil
end

local function initUpdateGate(guiParent, UpdateBadge)
    local GITHUB_REPO_RAW = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/release/"
    local MANIFEST_URL = GITHUB_REPO_RAW .. "manifest.json"
    local LEDGER_PATH = "Omni_Ledger.json"

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
        if ok and content and type(content) == "string" and #content > 50 then
            -- Only check for 404/400 error message if content is suspiciously short (< 150 chars)
            if #content < 150 and (content:find("404: Not Found") or content:find("400: Invalid Request")) then
                return nil
            end
            return content
        end
        return nil
    end

    local function getLatestCommitSha()
        local ok, res = pcall(function()
            if type(request) == "function" then
                local resp = request({
                    Url = "https://api.github.com/repos/s3rvxnt/RobloxOmni/commits/release",
                    Method = "GET",
                    Headers = { ["User-Agent"] = "OmniUpdater" }
                })
                if resp and resp.StatusCode == 200 and resp.Body then
                    local data = HttpService:JSONDecode(resp.Body)
                    return data and data.sha
                end
            end
        end)
        if ok and res and type(res) == "string" and #res > 10 then
            return res
        end
        return "release"
    end

    -- Ledger Management
    local function loadLedger()
        if type(isfile) == "function" and isfile(LEDGER_PATH) then
            local ok, raw = pcall(readfile, LEDGER_PATH)
            if ok and raw and #raw > 2 then
                local okDec, data = pcall(function() return HttpService:JSONDecode(raw) end)
                if okDec and type(data) == "table" then
                    data.components = data.components or {}
                    return data
                end
            end
        end
        return { version = CURRENT_OMNI_VERSION, components = {} }
    end

    local function saveLedger(ledger)
        if type(writefile) == "function" and HttpService then
            pcall(function()
                writefile(LEDGER_PATH, HttpService:JSONEncode(ledger))
            end)
        end
    end

    -- Security Heuristics Audit
    local function auditScriptContent(code)
        local badges = {}
        if not code or #code == 0 then return badges end

        -- Obfuscation Detection
        local isObfuscated = false
        local lower = code:lower()

        -- 1. Known Obfuscator Signatures & Watermarks
        local obfKeywords = {
            "luarmor", "luraph", "ironbrew", "moonsec", "prometheus", "psu obfuscator",
            "aztup", "boron", "wearedevs obfuscator", "synapse xen",
            "obfuscated with", "this file was obfuscated", "protected by",
            "lph-", "lph_", "lph_obfuscated", "lph_jit", "lph_enc"
        }
        for _, sig in ipairs(obfKeywords) do
            if lower:find(sig, 1, true) then
                isObfuscated = true
                break
            end
        end

        -- 2. Barcode variable names (e.g. IlIIlllIIllI)
        if not isObfuscated then
            local barcodeCount = 0
            for _ in code:gmatch("[Il1][Il1][Il1][Il1][Il1][Il1][Il1][Il1]+") do
                barcodeCount = barcodeCount + 1
                if barcodeCount >= 5 then
                    isObfuscated = true
                    break
                end
            end
        end

        -- 3. Hex variable identifiers (e.g. _0x4f1a2b)
        if not isObfuscated then
            local hexVarCount = 0
            for _ in code:gmatch("_0x%x%x%x%x+") do
                hexVarCount = hexVarCount + 1
                if hexVarCount >= 8 then
                    isObfuscated = true
                    break
                end
            end
        end

        -- 4. Precompiled Bytecode Signature
        if not isObfuscated then
            if code:sub(1, 4) == "\27Lua" or code:find("\\27Lua", 1, true) or code:find("\\x1bLua", 1, true) then
                isObfuscated = true
            end
        end

        -- 5. Packed Decimal Byte Streams (\123\145\167...)
        if not isObfuscated then
            local escapedByteCount = 0
            for _ in code:gmatch("\\[0-9][0-9][0-9]") do
                escapedByteCount = escapedByteCount + 1
                if escapedByteCount > 80 then
                    isObfuscated = true
                    break
                end
            end
        end

        -- 6. Packed Hex Byte Streams (\x41\x42\x43...)
        if not isObfuscated then
            local hexEscapeCount = 0
            for _ in code:gmatch("\\x%x%x") do
                hexEscapeCount = hexEscapeCount + 1
                if hexEscapeCount > 80 then
                    isObfuscated = true
                    break
                end
            end
        end

        -- 7. Giant dense single-line VM wrapper (> 2500 chars with string decoding)
        if not isObfuscated then
            for line in code:gmatch("[^\r\n]+") do
                if #line > 2500 and not line:match("^%s*%-%-") then
                    if line:find("string%.char") or line:find("bit32") or line:find("getfenv") or line:find("unpack") or line:find("table%.concat") then
                        isObfuscated = true
                        break
                    end
                end
            end
        end

        -- 8. Excessive dynamic string.char calls
        if not isObfuscated then
            local strCharCount = 0
            for _ in code:gmatch("string%.char%s*%(") do
                strCharCount = strCharCount + 1
                if strCharCount >= 15 then
                    isObfuscated = true
                    break
                end
            end
        end

        if isObfuscated then
            table.insert(badges, { label = "🛑 Obfuscated", color = Color3.fromRGB(255, 65, 65) })
        end

        if code:find("discord%.com/api/webhooks") or code:find("discordapp%.com/api/webhooks") then
            table.insert(badges, { label = "🚨 Webhook", color = Color3.fromRGB(240, 70, 70) })
        end
        if code:find("loadstring%s*%(") then
            table.insert(badges, { label = "⚠️ loadstring()", color = Color3.fromRGB(250, 160, 40) })
        end
        if code:find("HttpGet%s*%(") or code:find("request%s*%(") or code:find("http_request%s*%(") then
            table.insert(badges, { label = "🌐 Web Traffic", color = Color3.fromRGB(60, 180, 250) })
        end
        if code:find("writefile%s*%(") or code:find("delfile%s*%(") then
            table.insert(badges, { label = "💾 File IO", color = Color3.fromRGB(170, 130, 240) })
        end
        if #badges == 0 then
            table.insert(badges, { label = "🛡️ Clean Audit", color = Color3.fromRGB(70, 210, 130) })
        end
        return badges
    end

    -- Ultra-Fast Linear Diff Engine
    local function computeLineDiff(oldCode, newCode)
        local oldLines = {}
        if oldCode and #oldCode > 0 then
            for line in (oldCode .. "\n"):gmatch("(.-)\r?\n") do
                table.insert(oldLines, line)
            end
        end

        local newLines = {}
        if newCode and #newCode > 0 then
            for line in (newCode .. "\n"):gmatch("(.-)\r?\n") do
                table.insert(newLines, line)
            end
        end

        if #oldLines == 0 then
            local diff = {}
            for idx, line in ipairs(newLines) do
                table.insert(diff, { type = "add", lineNum = idx, text = line })
                if idx >= 500 then
                    local rem = #newLines - idx
                    if rem > 0 then
                        table.insert(diff, { type = "info", lineNum = 0, text = string.format("... [preview truncated, %d lines remaining] ...", rem) })
                    end
                    break
                end
            end
            return diff, #newLines, #newLines, 0
        end

        local adds = 0
        local removes = 0
        local oldIdx = 1
        local newIdx = 1
        local oldLen = #oldLines
        local newLen = #newLines

        local rawEntries = {}

        while oldIdx <= oldLen or newIdx <= newLen do
            if oldIdx <= oldLen and newIdx <= newLen and oldLines[oldIdx] == newLines[newIdx] then
                table.insert(rawEntries, { type = "same", lineNum = newIdx, text = newLines[newIdx] })
                oldIdx = oldIdx + 1
                newIdx = newIdx + 1
            else
                local matchOld, matchNew = nil, nil
                local searchWindow = 40
                for d = 1, searchWindow do
                    if not matchNew and (newIdx + d) <= newLen and oldIdx <= oldLen and oldLines[oldIdx] == newLines[newIdx + d] then
                        matchNew = d
                        break
                    end
                    if not matchOld and (oldIdx + d) <= oldLen and newIdx <= newLen and oldLines[oldIdx + d] == newLines[newIdx] then
                        matchOld = d
                        break
                    end
                end

                if matchNew then
                    for i = 0, matchNew - 1 do
                        adds = adds + 1
                        table.insert(rawEntries, { type = "add", lineNum = newIdx + i, text = newLines[newIdx + i] })
                    end
                    newIdx = newIdx + matchNew
                elseif matchOld then
                    for i = 0, matchOld - 1 do
                        removes = removes + 1
                        table.insert(rawEntries, { type = "remove", lineNum = oldIdx + i, text = oldLines[oldIdx + i] })
                    end
                    oldIdx = oldIdx + matchOld
                else
                    if oldIdx <= oldLen then
                        removes = removes + 1
                        table.insert(rawEntries, { type = "remove", lineNum = oldIdx, text = oldLines[oldIdx] })
                        oldIdx = oldIdx + 1
                    end
                    if newIdx <= newLen then
                        adds = adds + 1
                        table.insert(rawEntries, { type = "add", lineNum = newIdx, text = newLines[newIdx] })
                        newIdx = newIdx + 1
                    end
                end
            end
        end

        local keep = {}
        for idx, entry in ipairs(rawEntries) do
            if entry.type == "add" or entry.type == "remove" then
                for k = math.max(1, idx - 3), math.min(#rawEntries, idx + 3) do
                    keep[k] = true
                end
            end
        end

        local diff = {}
        local skipped = 0
        local maxDiffLines = 300
        for idx, entry in ipairs(rawEntries) do
            if keep[idx] then
                if skipped > 0 then
                    table.insert(diff, { type = "info", lineNum = 0, text = string.format("... [%d unchanged lines] ...", skipped) })
                    skipped = 0
                end
                table.insert(diff, entry)
                if #diff >= maxDiffLines then
                    local remaining = #rawEntries - idx
                    if remaining > 0 then
                        table.insert(diff, { type = "info", lineNum = 0, text = string.format("... [diff preview truncated, %d lines remaining] ...", remaining) })
                    end
                    break
                end
            else
                skipped = skipped + 1
            end
        end

        return diff, #newLines, adds, removes
    end

    local existingUpdateGui = guiParent:FindFirstChild("OmniUpdateGate_Protected")
    if existingUpdateGui then
        pcall(function() existingUpdateGui:Destroy() end)
    end

    -- Update Gate GUI Container
    local UpdateScreenGui = Instance.new("ScreenGui")
    UpdateScreenGui.Name = "OmniUpdateGate_Protected"
    UpdateScreenGui.ResetOnSpawn = false
    UpdateScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    UpdateScreenGui.DisplayOrder = 1000000
    UpdateScreenGui.Enabled = true
    UpdateScreenGui.Parent = guiParent

    -- 1. Floating Pill Toast (Top-Right)
    local PillToast = Instance.new("Frame")
    PillToast.Name = "PillToast"
    PillToast.Size = UDim2.new(0, 320, 0, 52)
    PillToast.Position = UDim2.new(1, -336, 0, 16)
    PillToast.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
    PillToast.BorderSizePixel = 0
    PillToast.Visible = false
    PillToast.Parent = UpdateScreenGui

    local PillCorner = Instance.new("UICorner")
    PillCorner.CornerRadius = UDim.new(0, 8)
    PillCorner.Parent = PillToast

    local PillStroke = Instance.new("UIStroke")
    PillStroke.Thickness = 1
    PillStroke.Color = Color3.fromRGB(45, 75, 120)
    PillStroke.Parent = PillToast

    local PillIcon = Instance.new("TextLabel")
    PillIcon.Size = UDim2.new(0, 24, 0, 24)
    PillIcon.Position = UDim2.new(0, 10, 0.5, -12)
    PillIcon.BackgroundTransparency = 1
    PillIcon.Font = Enum.Font.GothamBold
    PillIcon.TextSize = 16
    PillIcon.TextColor3 = Color3.fromRGB(64, 196, 255)
    PillIcon.Text = "⚡"
    PillIcon.Parent = PillToast

    local PillTitle = Instance.new("TextLabel")
    PillTitle.Size = UDim2.new(0, 160, 0, 16)
    PillTitle.Position = UDim2.new(0, 38, 0, 10)
    PillTitle.BackgroundTransparency = 1
    PillTitle.Font = Enum.Font.GothamBold
    PillTitle.TextSize = 12
    PillTitle.TextColor3 = Color3.fromRGB(240, 245, 255)
    PillTitle.TextXAlignment = Enum.TextXAlignment.Left
    PillTitle.Text = "Omni Update Available"
    PillTitle.Parent = PillToast

    local PillSubtitle = Instance.new("TextLabel")
    PillSubtitle.Name = "PillSubtitle"
    PillSubtitle.Size = UDim2.new(0, 160, 0, 14)
    PillSubtitle.Position = UDim2.new(0, 38, 0, 27)
    PillSubtitle.BackgroundTransparency = 1
    PillSubtitle.Font = Enum.Font.Gotham
    PillSubtitle.TextSize = 10
    PillSubtitle.TextColor3 = Color3.fromRGB(120, 170, 210)
    PillSubtitle.TextXAlignment = Enum.TextXAlignment.Left
    PillSubtitle.Text = "v1.0 Available"
    PillSubtitle.Parent = PillToast

    local PillReviewBtn = Instance.new("TextButton")
    PillReviewBtn.Name = "PillReviewBtn"
    PillReviewBtn.Size = UDim2.new(0, 76, 0, 26)
    PillReviewBtn.Position = UDim2.new(1, -104, 0.5, -13)
    PillReviewBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
    PillReviewBtn.Font = Enum.Font.GothamBold
    PillReviewBtn.TextSize = 10
    PillReviewBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    PillReviewBtn.Text = "Review"
    PillReviewBtn.Parent = PillToast

    local PillReviewCorner = Instance.new("UICorner")
    PillReviewCorner.CornerRadius = UDim.new(0, 5)
    PillReviewCorner.Parent = PillReviewBtn

    local PillDismissBtn = Instance.new("TextButton")
    PillDismissBtn.Name = "PillDismissBtn"
    PillDismissBtn.Size = UDim2.new(0, 20, 0, 20)
    PillDismissBtn.Position = UDim2.new(1, -24, 0.5, -10)
    PillDismissBtn.BackgroundTransparency = 1
    PillDismissBtn.Font = Enum.Font.GothamBold
    PillDismissBtn.TextSize = 11
    PillDismissBtn.TextColor3 = Color3.fromRGB(140, 155, 175)
    PillDismissBtn.Text = "X"
    PillDismissBtn.Parent = PillToast

    -- 2. Modal Backdrop & Centered Modal Frame (580x480)
    local ModalBackdrop = Instance.new("Frame")
    ModalBackdrop.Name = "ModalBackdrop"
    ModalBackdrop.Size = UDim2.new(1, 0, 1, 0)
    ModalBackdrop.Position = UDim2.new(0, 0, 0, 0)
    ModalBackdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    ModalBackdrop.BackgroundTransparency = 0.6
    ModalBackdrop.BorderSizePixel = 0
    ModalBackdrop.Visible = false
    ModalBackdrop.Parent = UpdateScreenGui

    local ModalFrame = Instance.new("Frame")
    ModalFrame.Name = "ModalFrame"
    ModalFrame.Size = UDim2.new(0, 580, 0, 480)
    ModalFrame.Position = UDim2.new(0.5, -290, 0.5, -240)
    ModalFrame.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
    ModalFrame.BorderSizePixel = 0
    ModalFrame.ClipsDescendants = true
    ModalFrame.Active = true
    ModalFrame.Parent = ModalBackdrop

    local ModalCorner = Instance.new("UICorner")
    ModalCorner.CornerRadius = UDim.new(0, 10)
    ModalCorner.Parent = ModalFrame

    local ModalStroke = Instance.new("UIStroke")
    ModalStroke.Thickness = 1.5
    ModalStroke.Color = Color3.fromRGB(35, 110, 180)
    ModalStroke.Parent = ModalFrame

    -- Modal Header
    local ModalHeader = Instance.new("Frame")
    ModalHeader.Name = "ModalHeader"
    ModalHeader.Size = UDim2.new(1, 0, 0, 50)
    ModalHeader.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
    ModalHeader.BorderSizePixel = 0
    ModalHeader.Parent = ModalFrame

    local ModalHeaderCorner = Instance.new("UICorner")
    ModalHeaderCorner.CornerRadius = UDim.new(0, 10)
    ModalHeaderCorner.Parent = ModalHeader

    local ModalTitle = Instance.new("TextLabel")
    ModalTitle.Size = UDim2.new(1, -60, 0, 22)
    ModalTitle.Position = UDim2.new(0, 16, 0, 7)
    ModalTitle.BackgroundTransparency = 1
    ModalTitle.Font = Enum.Font.GothamBold
    ModalTitle.TextSize = 13
    ModalTitle.TextColor3 = Color3.fromRGB(64, 196, 255)
    ModalTitle.TextXAlignment = Enum.TextXAlignment.Left
    ModalTitle.Text = "⚡ OMNI UPDATE & SECURITY GATE"
    ModalTitle.Parent = ModalHeader

    local ModalSubtitle = Instance.new("TextLabel")
    ModalSubtitle.Size = UDim2.new(1, -60, 0, 14)
    ModalSubtitle.Position = UDim2.new(0, 16, 0, 28)
    ModalSubtitle.BackgroundTransparency = 1
    ModalSubtitle.Font = Enum.Font.Gotham
    ModalSubtitle.TextSize = 10
    ModalSubtitle.TextColor3 = Color3.fromRGB(150, 165, 185)
    ModalSubtitle.TextXAlignment = Enum.TextXAlignment.Left
    ModalSubtitle.Text = "Verified code changes • Complete transparency before updating local files"
    ModalSubtitle.Parent = ModalHeader

    local ModalCloseBtn = Instance.new("TextButton")
    ModalCloseBtn.Size = UDim2.new(0, 28, 0, 28)
    ModalCloseBtn.Position = UDim2.new(1, -38, 0.5, -14)
    ModalCloseBtn.BackgroundColor3 = Color3.fromRGB(28, 34, 46)
    ModalCloseBtn.Font = Enum.Font.GothamBold
    ModalCloseBtn.TextSize = 13
    ModalCloseBtn.TextColor3 = Color3.fromRGB(200, 210, 225)
    ModalCloseBtn.Text = "X"
    ModalCloseBtn.Parent = ModalHeader

    local ModalCloseCorner = Instance.new("UICorner")
    ModalCloseCorner.CornerRadius = UDim.new(0, 6)
    ModalCloseCorner.Parent = ModalCloseBtn

    -- Version Diff Card
    local DiffCard = Instance.new("Frame")
    DiffCard.Name = "DiffCard"
    DiffCard.Size = UDim2.new(1, -32, 0, 38)
    DiffCard.Position = UDim2.new(0, 16, 0, 56)
    DiffCard.BackgroundColor3 = Color3.fromRGB(22, 27, 38)
    DiffCard.BorderSizePixel = 0
    DiffCard.Parent = ModalFrame

    local DiffCorner = Instance.new("UICorner")
    DiffCorner.CornerRadius = UDim.new(0, 6)
    DiffCorner.Parent = DiffCard

    local DiffStroke = Instance.new("UIStroke")
    DiffStroke.Thickness = 1
    DiffStroke.Color = Color3.fromRGB(38, 50, 72)
    DiffStroke.Parent = DiffCard

    local DiffCurrent = Instance.new("TextLabel")
    DiffCurrent.Name = "DiffCurrent"
    DiffCurrent.Size = UDim2.new(0, 150, 1, 0)
    DiffCurrent.Position = UDim2.new(0, 12, 0, 0)
    DiffCurrent.BackgroundTransparency = 1
    DiffCurrent.Font = Enum.Font.GothamMedium
    DiffCurrent.TextSize = 11
    DiffCurrent.TextColor3 = Color3.fromRGB(140, 175, 155)
    DiffCurrent.TextXAlignment = Enum.TextXAlignment.Left
    DiffCurrent.Text = "Installed: v" .. CURRENT_OMNI_VERSION
    DiffCurrent.Parent = DiffCard

    local DiffArrow = Instance.new("TextLabel")
    DiffArrow.Size = UDim2.new(0, 30, 1, 0)
    DiffArrow.Position = UDim2.new(0, 165, 0, 0)
    DiffArrow.BackgroundTransparency = 1
    DiffArrow.Font = Enum.Font.GothamBold
    DiffArrow.TextSize = 14
    DiffArrow.TextColor3 = Color3.fromRGB(64, 196, 255)
    DiffArrow.Text = "➔"
    DiffArrow.Parent = DiffCard

    local DiffAvailable = Instance.new("TextLabel")
    DiffAvailable.Name = "DiffAvailable"
    DiffAvailable.Size = UDim2.new(0, 160, 1, 0)
    DiffAvailable.Position = UDim2.new(0, 200, 0, 0)
    DiffAvailable.BackgroundTransparency = 1
    DiffAvailable.Font = Enum.Font.GothamBold
    DiffAvailable.TextSize = 12
    DiffAvailable.TextColor3 = Color3.fromRGB(64, 196, 255)
    DiffAvailable.TextXAlignment = Enum.TextXAlignment.Left
    DiffAvailable.Text = "Available: v1.0"
    DiffAvailable.Parent = DiffCard

    local DiffDate = Instance.new("TextLabel")
    DiffDate.Name = "DiffDate"
    DiffDate.Size = UDim2.new(0, 120, 1, 0)
    DiffDate.Position = UDim2.new(1, -132, 0, 0)
    DiffDate.BackgroundTransparency = 1
    DiffDate.Font = Enum.Font.Gotham
    DiffDate.TextSize = 10
    DiffDate.TextColor3 = Color3.fromRGB(130, 145, 165)
    DiffDate.TextXAlignment = Enum.TextXAlignment.Right
    DiffDate.Text = "2026-10-02"
    DiffDate.Parent = DiffCard

    -- Tab Switcher Bar
    local TabBar = Instance.new("Frame")
    TabBar.Name = "TabBar"
    TabBar.Size = UDim2.new(1, -32, 0, 28)
    TabBar.Position = UDim2.new(0, 16, 0, 100)
    TabBar.BackgroundTransparency = 1
    TabBar.Parent = ModalFrame

    local TabBtnChangelog = Instance.new("TextButton")
    TabBtnChangelog.Name = "TabBtnChangelog"
    TabBtnChangelog.Size = UDim2.new(0, 160, 1, 0)
    TabBtnChangelog.Position = UDim2.new(0, 0, 0, 0)
    TabBtnChangelog.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
    TabBtnChangelog.Font = Enum.Font.GothamBold
    TabBtnChangelog.TextSize = 11
    TabBtnChangelog.TextColor3 = Color3.fromRGB(255, 255, 255)
    TabBtnChangelog.Text = "📋 Changelog & Notes"
    TabBtnChangelog.Parent = TabBar

    local TabChangelogCorner = Instance.new("UICorner")
    TabChangelogCorner.CornerRadius = UDim.new(0, 5)
    TabChangelogCorner.Parent = TabBtnChangelog

    local TabBtnCode = Instance.new("TextButton")
    TabBtnCode.Name = "TabBtnCode"
    TabBtnCode.Size = UDim2.new(0, 160, 1, 0)
    TabBtnCode.Position = UDim2.new(0, 168, 0, 0)
    TabBtnCode.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
    TabBtnCode.Font = Enum.Font.GothamBold
    TabBtnCode.TextSize = 11
    TabBtnCode.TextColor3 = Color3.fromRGB(160, 175, 195)
    TabBtnCode.Text = "🔍 Review Code & Diff"
    TabBtnCode.Parent = TabBar

    local TabCodeCorner = Instance.new("UICorner")
    TabCodeCorner.CornerRadius = UDim.new(0, 5)
    TabCodeCorner.Parent = TabBtnCode

    -- Content Frame
    local ContentFrame = Instance.new("Frame")
    ContentFrame.Name = "ContentFrame"
    ContentFrame.Size = UDim2.new(1, -32, 0, 292)
    ContentFrame.Position = UDim2.new(0, 16, 0, 134)
    ContentFrame.BackgroundTransparency = 1
    ContentFrame.Parent = ModalFrame

    -- View A: Changelog Scroll
    local ChangelogScroll = Instance.new("ScrollingFrame")
    ChangelogScroll.Name = "ChangelogScroll"
    ChangelogScroll.Size = UDim2.new(1, 0, 1, 0)
    ChangelogScroll.BackgroundColor3 = Color3.fromRGB(11, 13, 19)
    ChangelogScroll.BorderSizePixel = 0
    ChangelogScroll.ScrollBarThickness = 4
    ChangelogScroll.ScrollBarImageColor3 = Color3.fromRGB(64, 196, 255)
    ChangelogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    ChangelogScroll.Visible = true
    ChangelogScroll.Parent = ContentFrame

    local ChangelogCorner = Instance.new("UICorner")
    ChangelogCorner.CornerRadius = UDim.new(0, 6)
    ChangelogCorner.Parent = ChangelogScroll

    local ChangelogStroke = Instance.new("UIStroke")
    ChangelogStroke.Thickness = 1
    ChangelogStroke.Color = Color3.fromRGB(30, 38, 52)
    ChangelogStroke.Parent = ChangelogScroll

    local ChangelogLayout = Instance.new("UIListLayout")
    ChangelogLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ChangelogLayout.Padding = UDim.new(0, 6)
    ChangelogLayout.Parent = ChangelogScroll

    local ChangelogPadding = Instance.new("UIPadding")
    ChangelogPadding.PaddingTop = UDim.new(0, 8)
    ChangelogPadding.PaddingBottom = UDim.new(0, 8)
    ChangelogPadding.PaddingLeft = UDim.new(0, 8)
    ChangelogPadding.PaddingRight = UDim.new(0, 12)
    ChangelogPadding.Parent = ChangelogScroll

    -- View B: Code Review & Diff Viewer Frame
    local CodeReviewFrame = Instance.new("Frame")
    CodeReviewFrame.Name = "CodeReviewFrame"
    CodeReviewFrame.Size = UDim2.new(1, 0, 1, 0)
    CodeReviewFrame.BackgroundTransparency = 1
    CodeReviewFrame.Visible = false
    CodeReviewFrame.Parent = ContentFrame

    -- Stage selector sub-bar
    local StageBar = Instance.new("Frame")
    StageBar.Name = "StageBar"
    StageBar.Size = UDim2.new(1, 0, 0, 26)
    StageBar.BackgroundTransparency = 1
    StageBar.Parent = CodeReviewFrame

    local StageBarLayout = Instance.new("UIListLayout")
    StageBarLayout.FillDirection = Enum.FillDirection.Horizontal
    StageBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
    StageBarLayout.Padding = UDim.new(0, 6)
    StageBarLayout.Parent = StageBar

    -- Audit badges & stats sub-bar
    local AuditBar = Instance.new("Frame")
    AuditBar.Name = "AuditBar"
    AuditBar.Size = UDim2.new(1, 0, 0, 22)
    AuditBar.Position = UDim2.new(0, 0, 0, 30)
    AuditBar.BackgroundTransparency = 1
    AuditBar.Parent = CodeReviewFrame

    local AuditBarLayout = Instance.new("UIListLayout")
    AuditBarLayout.FillDirection = Enum.FillDirection.Horizontal
    AuditBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
    AuditBarLayout.Padding = UDim.new(0, 6)
    AuditBarLayout.Parent = AuditBar

    -- Monospaced Code & Diff Scroll
    local CodeScroll = Instance.new("ScrollingFrame")
    CodeScroll.Name = "CodeScroll"
    CodeScroll.Size = UDim2.new(1, 0, 1, -56)
    CodeScroll.Position = UDim2.new(0, 0, 0, 56)
    CodeScroll.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
    CodeScroll.BorderSizePixel = 0
    CodeScroll.ScrollBarThickness = 5
    CodeScroll.ScrollBarImageColor3 = Color3.fromRGB(64, 196, 255)
    CodeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    CodeScroll.Parent = CodeReviewFrame

    local CodeScrollCorner = Instance.new("UICorner")
    CodeScrollCorner.CornerRadius = UDim.new(0, 6)
    CodeScrollCorner.Parent = CodeScroll

    local CodeScrollStroke = Instance.new("UIStroke")
    CodeScrollStroke.Thickness = 1
    CodeScrollStroke.Color = Color3.fromRGB(30, 38, 52)
    CodeScrollStroke.Parent = CodeScroll

    local CodeScrollLayout = Instance.new("UIListLayout")
    CodeScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
    CodeScrollLayout.Padding = UDim.new(0, 2)
    CodeScrollLayout.Parent = CodeScroll

    local CodeScrollPadding = Instance.new("UIPadding")
    CodeScrollPadding.PaddingTop = UDim.new(0, 4)
    CodeScrollPadding.PaddingBottom = UDim.new(0, 6)
    CodeScrollPadding.PaddingLeft = UDim.new(0, 6)
    CodeScrollPadding.PaddingRight = UDim.new(0, 8)
    CodeScrollPadding.Parent = CodeScroll

    -- Footer Action Buttons
    local FooterFrame = Instance.new("Frame")
    FooterFrame.Name = "FooterFrame"
    FooterFrame.Size = UDim2.new(1, -32, 0, 36)
    FooterFrame.Position = UDim2.new(0, 16, 1, -44)
    FooterFrame.BackgroundTransparency = 1
    FooterFrame.Parent = ModalFrame

    local DismissBtn = Instance.new("TextButton")
    DismissBtn.Name = "DismissBtn"
    DismissBtn.Size = UDim2.new(0, 140, 1, 0)
    DismissBtn.Position = UDim2.new(0, 0, 0, 0)
    DismissBtn.BackgroundColor3 = Color3.fromRGB(28, 34, 46)
    DismissBtn.Font = Enum.Font.GothamBold
    DismissBtn.TextSize = 11
    DismissBtn.TextColor3 = Color3.fromRGB(180, 195, 215)
    DismissBtn.Text = "Dismiss (Skip)"
    DismissBtn.Parent = FooterFrame

    local DismissCorner = Instance.new("UICorner")
    DismissCorner.CornerRadius = UDim.new(0, 6)
    DismissCorner.Parent = DismissBtn

    local ApplyUpdateBtn = Instance.new("TextButton")
    ApplyUpdateBtn.Name = "ApplyUpdateBtn"
    ApplyUpdateBtn.Size = UDim2.new(1, -148, 1, 0)
    ApplyUpdateBtn.Position = UDim2.new(0, 148, 0, 0)
    ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
    ApplyUpdateBtn.Font = Enum.Font.GothamBold
    ApplyUpdateBtn.TextSize = 12
    ApplyUpdateBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    ApplyUpdateBtn.Text = "⬇️ Update & Apply Now"
    ApplyUpdateBtn.Parent = FooterFrame

    local ApplyCorner = Instance.new("UICorner")
    ApplyCorner.CornerRadius = UDim.new(0, 6)
    ApplyCorner.Parent = ApplyUpdateBtn

    -- Option B: Obfuscation Protection State & UI Controller
    local isObfuscatedUpdateDetected = false
    local forceInstallConfirmActive = false
    local forceInstallResetThread = nil

    local function refreshApplyButtonUI()
        if isObfuscatedUpdateDetected then
            if forceInstallConfirmActive then
                ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(220, 20, 20)
                ApplyUpdateBtn.Text = "🛑 Are you sure? Click again to Force Install"
            else
                ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
                ApplyUpdateBtn.Text = "⚠️ Force Install Obfuscated Code (Unsafe)"
            end
        else
            ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
            ApplyUpdateBtn.Text = "⬇️ Update & Apply Now"
        end
    end

    -- Tab Switching Logic
    local function switchTab(tabName)
        if tabName == "Changelog" then
            ChangelogScroll.Visible = true
            CodeReviewFrame.Visible = false
            TabBtnChangelog.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
            TabBtnChangelog.TextColor3 = Color3.fromRGB(255, 255, 255)
            TabBtnCode.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
            TabBtnCode.TextColor3 = Color3.fromRGB(160, 175, 195)
        else
            ChangelogScroll.Visible = false
            CodeReviewFrame.Visible = true
            TabBtnCode.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
            TabBtnCode.TextColor3 = Color3.fromRGB(255, 255, 255)
            TabBtnChangelog.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
            TabBtnChangelog.TextColor3 = Color3.fromRGB(160, 175, 195)
        end
    end

    TabBtnChangelog.MouseButton1Click:Connect(function() switchTab("Changelog") end)
    TabBtnCode.MouseButton1Click:Connect(function() switchTab("Code") end)

    -- Populate Changelog
    local function populateChangelog(items)
        for _, child in ipairs(ChangelogScroll:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end
        for idx, item in ipairs(items) do
            local row = Instance.new("Frame")
            row.Name = "ChangeRow_" .. idx
            row.Size = UDim2.new(1, 0, 0, 0)
            row.AutomaticSize = Enum.AutomaticSize.Y
            row.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
            row.BorderSizePixel = 0
            row.LayoutOrder = idx
            row.Parent = ChangelogScroll

            local rowCorner = Instance.new("UICorner")
            rowCorner.CornerRadius = UDim.new(0, 4)
            rowCorner.Parent = row

            local rowStroke = Instance.new("UIStroke")
            rowStroke.Thickness = 1
            rowStroke.Color = Color3.fromRGB(28, 36, 50)
            rowStroke.Parent = row

            local rowPadding = Instance.new("UIPadding")
            rowPadding.PaddingTop = UDim.new(0, 6)
            rowPadding.PaddingBottom = UDim.new(0, 6)
            rowPadding.PaddingLeft = UDim.new(0, 8)
            rowPadding.PaddingRight = UDim.new(0, 8)
            rowPadding.Parent = row

            local icon = Instance.new("TextLabel")
            icon.Size = UDim2.new(0, 16, 0, 16)
            icon.Position = UDim2.new(0, 0, 0, 0)
            icon.BackgroundTransparency = 1
            icon.Font = Enum.Font.GothamBold
            icon.TextSize = 10
            icon.TextColor3 = Color3.fromRGB(64, 196, 255)
            icon.Text = "🔹"
            icon.Parent = row

            local desc = Instance.new("TextLabel")
            desc.Size = UDim2.new(1, -22, 0, 0)
            desc.Position = UDim2.new(0, 22, 0, 0)
            desc.AutomaticSize = Enum.AutomaticSize.Y
            desc.BackgroundTransparency = 1
            desc.Font = Enum.Font.Gotham
            desc.TextSize = 11
            desc.TextColor3 = Color3.fromRGB(225, 235, 245)
            desc.TextXAlignment = Enum.TextXAlignment.Left
            desc.TextWrapped = true
            desc.Text = tostring(item)
            desc.Parent = row
        end
    end

    local currentUpdateData = nil
    local fetchedStageCodes = {}
    local selectedStageIdx = 1

    local function sanitizeStages(rawStages)
        local valid = {}
        if type(rawStages) == "table" then
            for _, stage in ipairs(rawStages) do
                if type(stage) == "table" then
                    local p = stage.localPath or stage.path
                    if p and type(p) == "string" and p ~= "" then
                        stage.localPath = p
                        stage.name = stage.name or p:match("[^/\\]+$") or "Component"
                        table.insert(valid, stage)
                    end
                end
            end
        end
        return valid
    end

    local function renderStageDiff(stageIdx)
        selectedStageIdx = stageIdx
        local stages = (currentUpdateData and currentUpdateData.stages) or {}
        local stage = stages[stageIdx]
        if not stage then return end

        local localPath = stage.localPath or stage.path
        local repoPath = stage.repoPath or stage.url
        local name = stage.name or (localPath and localPath:match("[^/\\]+$")) or "Component"

        -- Update stage selector buttons active state
        for _, btn in ipairs(StageBar:GetChildren()) do
            if btn:IsA("TextButton") then
                local isThis = (btn.Name == "StageBtn_" .. stageIdx)
                btn.BackgroundColor3 = isThis and Color3.fromRGB(0, 122, 204) or Color3.fromRGB(24, 30, 42)
                btn.TextColor3 = isThis and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 175, 195)
            end
        end

        -- Clear AuditBar
        for _, c in ipairs(AuditBar:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        -- Clear CodeScroll & show loading banner
        for _, c in ipairs(CodeScroll:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        local loadingLbl = Instance.new("TextLabel")
        loadingLbl.Size = UDim2.new(1, 0, 0, 40)
        loadingLbl.BackgroundTransparency = 1
        loadingLbl.Font = Enum.Font.GothamMedium
        loadingLbl.TextSize = 11
        loadingLbl.TextColor3 = Color3.fromRGB(64, 196, 255)
        loadingLbl.Text = "⏳ Loading & diffing component from GitHub..."
        loadingLbl.Parent = CodeScroll

        task.spawn(function()
            -- Fetch remote content if needed
            local remoteContent = stage.code or stage.content or fetchedStageCodes[stageIdx]
            if not remoteContent then
                local shaToUse = (currentUpdateData and currentUpdateData.sha) or getLatestCommitSha()
                local url = repoPath
                if not url:find("^https?://") then
                    url = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/" .. shaToUse .. "/" .. url
                end
                remoteContent = fetchGithubScript(url)
                fetchedStageCodes[stageIdx] = remoteContent
            end

            -- If user switched away while loading, skip render
            if selectedStageIdx ~= stageIdx then return end

            -- Read existing local content
            local localContent = ""
            local isInstalled = isfile and isfile(localPath)
            if isInstalled then
                local ok, raw = pcall(readfile, localPath)
                if ok and raw then localContent = raw end
            end

            -- Clear loading banner
            for _, c in ipairs(CodeScroll:GetChildren()) do
                if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
            end

            -- Clear AuditBar
            for _, c in ipairs(AuditBar:GetChildren()) do
                if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
            end

            if not remoteContent then
                local notice = Instance.new("TextLabel")
                notice.Size = UDim2.new(1, 0, 0, 40)
                notice.BackgroundTransparency = 1
                notice.Font = Enum.Font.GothamMedium
                notice.TextSize = 11
                notice.TextColor3 = Color3.fromRGB(250, 160, 40)
                notice.Text = "⚠️ Unable to load remote code from GitHub. Check network connection."
                notice.Parent = CodeScroll
                return
            end

            -- Render Audit Chips
            local badges = auditScriptContent(remoteContent or localContent)
            for _, b in ipairs(badges) do
                local chip = Instance.new("Frame")
                chip.Size = UDim2.new(0, 0, 1, 0)
                chip.AutomaticSize = Enum.AutomaticSize.X
                chip.BackgroundColor3 = Color3.fromRGB(20, 26, 36)
                chip.BorderSizePixel = 0
                chip.Parent = AuditBar

                local chipCorner = Instance.new("UICorner")
                chipCorner.CornerRadius = UDim.new(0, 4)
                chipCorner.Parent = chip

                local chipStroke = Instance.new("UIStroke")
                chipStroke.Thickness = 1
                chipStroke.Color = b.color
                chipStroke.Parent = chip

                local chipPadding = Instance.new("UIPadding")
                chipPadding.PaddingLeft = UDim.new(0, 6)
                chipPadding.PaddingRight = UDim.new(0, 6)
                chipPadding.Parent = chip

                local chipLbl = Instance.new("TextLabel")
                chipLbl.Size = UDim2.new(0, 0, 1, 0)
                chipLbl.AutomaticSize = Enum.AutomaticSize.X
                chipLbl.BackgroundTransparency = 1
                chipLbl.Font = Enum.Font.GothamBold
                chipLbl.TextSize = 10
                chipLbl.TextColor3 = b.color
                chipLbl.Text = b.label
                chipLbl.Parent = chip
            end

            -- Status tag
            local statusLbl = Instance.new("TextLabel")
            statusLbl.Size = UDim2.new(0, 0, 1, 0)
            statusLbl.AutomaticSize = Enum.AutomaticSize.X
            statusLbl.BackgroundTransparency = 1
            statusLbl.Font = Enum.Font.Gotham
            statusLbl.TextSize = 10
            statusLbl.TextColor3 = isInstalled and Color3.fromRGB(140, 185, 210) or Color3.fromRGB(240, 180, 70)
            statusLbl.Text = isInstalled and " • Local file present" or " • Component Not Installed"
            statusLbl.Parent = AuditBar

            -- Compute Line Diff
            local diff, totalLines, adds, removes = computeLineDiff(localContent, remoteContent)

            -- Diff Stats Badge in AuditBar
            local diffStat = Instance.new("Frame")
            diffStat.Size = UDim2.new(0, 0, 1, 0)
            diffStat.AutomaticSize = Enum.AutomaticSize.X
            diffStat.BackgroundColor3 = Color3.fromRGB(20, 26, 36)
            diffStat.BorderSizePixel = 0
            diffStat.Parent = AuditBar

            local diffStatCorner = Instance.new("UICorner")
            diffStatCorner.CornerRadius = UDim.new(0, 4)
            diffStatCorner.Parent = diffStat

            local diffStatStroke = Instance.new("UIStroke")
            diffStatStroke.Thickness = 1
            diffStatStroke.Color = Color3.fromRGB(45, 65, 95)
            diffStatStroke.Parent = diffStat

            local diffStatPadding = Instance.new("UIPadding")
            diffStatPadding.PaddingLeft = UDim.new(0, 6)
            diffStatPadding.PaddingRight = UDim.new(0, 6)
            diffStatPadding.Parent = diffStat

            local diffStatLbl = Instance.new("TextLabel")
            diffStatLbl.Size = UDim2.new(0, 0, 1, 0)
            diffStatLbl.AutomaticSize = Enum.AutomaticSize.X
            diffStatLbl.BackgroundTransparency = 1
            diffStatLbl.Font = Enum.Font.RobotoMono
            diffStatLbl.TextSize = 10
            diffStatLbl.TextColor3 = (adds == 0 and removes == 0) and Color3.fromRGB(120, 210, 150) or Color3.fromRGB(160, 200, 240)
            diffStatLbl.Text = (adds == 0 and removes == 0) and ("✓ " .. totalLines .. " lines (Synced)") or ("+" .. tostring(adds) .. " / -" .. tostring(removes) .. " lines")
            diffStatLbl.Parent = diffStat

            local obfBadge = nil
            for _, b in ipairs(badges) do
                if b.label == "🛑 Obfuscated" then
                    obfBadge = b
                    break
                end
            end

            if obfBadge then
                isObfuscatedUpdateDetected = true
                refreshApplyButtonUI()

                local obfBanner = Instance.new("Frame")
                obfBanner.Name = "ObfuscationBanner"
                obfBanner.Size = UDim2.new(1, 0, 0, 36)
                obfBanner.BackgroundColor3 = Color3.fromRGB(45, 16, 20)
                obfBanner.BorderSizePixel = 0
                obfBanner.LayoutOrder = 0
                obfBanner.Parent = CodeScroll

                local obfCorner = Instance.new("UICorner")
                obfCorner.CornerRadius = UDim.new(0, 4)
                obfCorner.Parent = obfBanner

                local obfStroke = Instance.new("UIStroke")
                obfStroke.Thickness = 1
                obfStroke.Color = Color3.fromRGB(240, 70, 70)
                obfStroke.Parent = obfBanner

                local obfLbl = Instance.new("TextLabel")
                obfLbl.Size = UDim2.new(1, -20, 1, 0)
                obfLbl.Position = UDim2.new(0, 12, 0, 0)
                obfLbl.BackgroundTransparency = 1
                obfLbl.Font = Enum.Font.GothamBold
                obfLbl.TextSize = 11
                obfLbl.TextColor3 = Color3.fromRGB(255, 100, 100)
                obfLbl.TextXAlignment = Enum.TextXAlignment.Left
                obfLbl.Text = "🛑 OBFUSCATED CODE DETECTED — Logic is hidden from inspection!"
                obfLbl.Parent = obfBanner
            end

            if #diff == 0 or (adds == 0 and removes == 0 and #localContent > 0) then
                local emptyRow = Instance.new("Frame")
                emptyRow.Name = "IdenticalNotice"
                emptyRow.Size = UDim2.new(1, 0, 0, 36)
                emptyRow.BackgroundColor3 = Color3.fromRGB(16, 28, 22)
                emptyRow.BorderSizePixel = 0
                emptyRow.Parent = CodeScroll

                local emptyCorner = Instance.new("UICorner")
                emptyCorner.CornerRadius = UDim.new(0, 4)
                emptyCorner.Parent = emptyRow

                local emptyStroke = Instance.new("UIStroke")
                emptyStroke.Thickness = 1
                emptyStroke.Color = Color3.fromRGB(35, 90, 55)
                emptyStroke.Parent = emptyRow

                local emptyLbl = Instance.new("TextLabel")
                emptyLbl.Size = UDim2.new(1, -20, 1, 0)
                emptyLbl.Position = UDim2.new(0, 12, 0, 0)
                emptyLbl.BackgroundTransparency = 1
                emptyLbl.Font = Enum.Font.GothamMedium
                emptyLbl.TextSize = 11
                emptyLbl.TextColor3 = Color3.fromRGB(100, 230, 130)
                emptyLbl.TextXAlignment = Enum.TextXAlignment.Left
                emptyLbl.Text = "✓ Local file matches repository version (" .. tostring(totalLines) .. " lines verified identical - no changes needed)"
                emptyLbl.Parent = emptyRow
            else
                for idx, item in ipairs(diff) do
                    local lineRow = Instance.new("Frame")
                    lineRow.Name = "Line_" .. idx
                    lineRow.Size = UDim2.new(1, 0, 0, 16)
                    lineRow.BorderSizePixel = 0
                    lineRow.LayoutOrder = idx

                    local bgCol = Color3.fromRGB(10, 12, 16)
                    local textCol = Color3.fromRGB(190, 200, 215)
                    local prefix = "  "

                    if item.type == "add" then
                        bgCol = Color3.fromRGB(16, 38, 24)
                        textCol = Color3.fromRGB(100, 230, 130)
                        prefix = "+ "
                    elseif item.type == "remove" then
                        bgCol = Color3.fromRGB(42, 18, 20)
                        textCol = Color3.fromRGB(250, 110, 110)
                        prefix = "- "
                    elseif item.type == "info" then
                        bgCol = Color3.fromRGB(24, 30, 42)
                        textCol = Color3.fromRGB(140, 165, 195)
                        prefix = "  "
                    end
                    lineRow.BackgroundColor3 = bgCol
                    lineRow.Parent = CodeScroll

                    local numLbl = Instance.new("TextLabel")
                    numLbl.Size = UDim2.new(0, 36, 1, 0)
                    numLbl.Position = UDim2.new(0, 4, 0, 0)
                    numLbl.BackgroundTransparency = 1
                    numLbl.Font = Enum.Font.RobotoMono
                    numLbl.TextSize = 10
                    numLbl.TextColor3 = Color3.fromRGB(90, 105, 125)
                    numLbl.TextXAlignment = Enum.TextXAlignment.Right
                    numLbl.Text = (item.type == "info") and "..." or tostring(item.lineNum or idx)
                    numLbl.Parent = lineRow

                    local txtLbl = Instance.new("TextLabel")
                    txtLbl.Size = UDim2.new(1, -48, 1, 0)
                    txtLbl.Position = UDim2.new(0, 46, 0, 0)
                    txtLbl.BackgroundTransparency = 1
                    txtLbl.Font = Enum.Font.RobotoMono
                    txtLbl.TextSize = 10
                    txtLbl.TextColor3 = textCol
                    txtLbl.TextXAlignment = Enum.TextXAlignment.Left
                    txtLbl.Text = prefix .. item.text
                    txtLbl.Parent = lineRow
                end
            end
        end)
    end

    local function setupStageBar()
        for _, c in ipairs(StageBar:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end

        local stages = (currentUpdateData and currentUpdateData.stages) or {}
        for idx, stage in ipairs(stages) do
            local btn = Instance.new("TextButton")
            btn.Name = "StageBtn_" .. idx
            btn.Size = UDim2.new(0, 0, 1, 0)
            btn.AutomaticSize = Enum.AutomaticSize.X
            btn.BackgroundColor3 = (idx == selectedStageIdx) and Color3.fromRGB(0, 122, 204) or Color3.fromRGB(24, 30, 42)
            btn.BorderSizePixel = 0
            btn.Font = Enum.Font.GothamBold
            btn.TextSize = 10
            btn.TextColor3 = (idx == selectedStageIdx) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 175, 195)
            btn.Text = " " .. (stage.name or "Component") .. " "
            btn.LayoutOrder = idx
            btn.Parent = StageBar

            local btnCorner = Instance.new("UICorner")
            btnCorner.CornerRadius = UDim.new(0, 4)
            btnCorner.Parent = btn

            local btnPadding = Instance.new("UIPadding")
            btnPadding.PaddingLeft = UDim.new(0, 6)
            btnPadding.PaddingRight = UDim.new(0, 6)
            btnPadding.Parent = btn

            btn.MouseButton1Click:Connect(function()
                renderStageDiff(idx)
            end)
        end
    end

    local function openUpdateModal(customData)
        if forceInstallResetThread then
            task.cancel(forceInstallResetThread)
            forceInstallResetThread = nil
        end
        forceInstallConfirmActive = false
        isObfuscatedUpdateDetected = false

        if customData and type(customData) == "table" then
            currentUpdateData = customData
            currentUpdateData.stages = sanitizeStages(currentUpdateData.stages)
            fetchedStageCodes = {}
        elseif not currentUpdateData then
            currentUpdateData = {
                version = CURRENT_OMNI_VERSION,
                releaseDate = "2026-10-03",
                title = "Omni v1.0 - Runtime Micro-Kernel & Enhancement Suite",
                changelog = {
                    "Adaptive 6.0ms frame-budgeted bootloader with automated crash recovery and Safe Mode",
                    "Kernel Task Manager HUD and adaptive loop governor with per-task CPU telemetry (Shift + F8)",
                    "Zero-trust update transparency gate with line-by-line diff inspection and security scanner (Shift + F7)",
                    "Real-time game connection ingestion, priority bands, and instant hot-reloading",
                    "Omni Enhancement Suite: Streamer mode, Personal Space Bubble, Player ESP, Anti-AFK, and native ESC settings"
                },
                stages = sanitizeStages({
                    {
                        repoPath = "kernel/KernelTaskManager.lua",
                        localPath = "autoexec/kernel/KernelTaskManager.lua",
                        name = "KernelTaskManager"
                    },
                    {
                        repoPath = "gameloaded/OmniEnhancementSuite.lua",
                        localPath = "autoexec/gameloaded/OmniEnhancementSuite.lua",
                        name = "OmniEnhancementSuite"
                    }
                })
            }
        end

        -- Pre-scan any immediately available stage contents for obfuscation
        if currentUpdateData and currentUpdateData.stages then
            for idx, st in ipairs(currentUpdateData.stages) do
                local c = st.code or st.content or fetchedStageCodes[idx]
                if c then
                    local bg = auditScriptContent(c)
                    for _, b in ipairs(bg) do
                        if b.label == "🛑 Obfuscated" then
                            isObfuscatedUpdateDetected = true
                            break
                        end
                    end
                end
            end
        end

        ApplyUpdateBtn.Active = true
        refreshApplyButtonUI()

        local ledger = loadLedger()
        local installedVersion = (ledger and ledger.version) or CURRENT_OMNI_VERSION
        DiffCurrent.Text = "Installed: v" .. tostring(installedVersion)
        DiffAvailable.Text = "Available: v" .. tostring(currentUpdateData.version)
        DiffDate.Text = tostring(currentUpdateData.releaseDate or "Latest")
        populateChangelog(currentUpdateData.changelog or { "Performance improvements and bug fixes" })
        setupStageBar()
        renderStageDiff(1)
        switchTab("Changelog")

        ModalBackdrop.Visible = true
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
    end

    getgenv().OpenOmniUpdateGate = openUpdateModal
    getgenv().TestOmniUpdateGate = openUpdateModal

    local function closeUpdateModal()
        if forceInstallResetThread then
            task.cancel(forceInstallResetThread)
            forceInstallResetThread = nil
        end
        forceInstallConfirmActive = false
        refreshApplyButtonUI()
        ModalBackdrop.Visible = false
    end

    -- Event Wiring
    ModalCloseBtn.MouseButton1Click:Connect(function()
        closeUpdateModal()
        if not getgenv()._OmniUpdateDismissed and currentUpdateData then
            PillToast.Visible = true
        end
    end)

    -- Smooth Modal Header Dragging
    local isDraggingModal, dragStartPos, frameStartPos
    ModalHeader.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDraggingModal = true
            dragStartPos = input.Position
            frameStartPos = ModalFrame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    isDraggingModal = false
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if isDraggingModal and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStartPos
            ModalFrame.Position = UDim2.new(frameStartPos.X.Scale, frameStartPos.X.Offset + delta.X, frameStartPos.Y.Scale, frameStartPos.Y.Offset + delta.Y)
        end
    end)

    PillReviewBtn.MouseButton1Click:Connect(function()
        PillToast.Visible = false
        openUpdateModal()
    end)

    PillDismissBtn.MouseButton1Click:Connect(function()
        PillToast.Visible = false
        getgenv()._OmniUpdateDismissed = true
                getgenv()._OmniUpdateAvailable = false
        -- Update ledger dismissed state
        local ledger = loadLedger()
        if currentUpdateData and currentUpdateData.stages then
            for _, stage in ipairs(currentUpdateData.stages) do
                local name = stage.name or stage.localPath
                ledger.components[name] = ledger.components[name] or {}
                ledger.components[name].lastSeenVersion = currentUpdateData.version
            end
            saveLedger(ledger)
        end
    end)

    DismissBtn.MouseButton1Click:Connect(function()
        closeUpdateModal()
        PillToast.Visible = false
        getgenv()._OmniUpdateDismissed = true
                getgenv()._OmniUpdateAvailable = false
        local ledger = loadLedger()
        if currentUpdateData and currentUpdateData.stages then
            for _, stage in ipairs(currentUpdateData.stages) do
                local name = stage.name or stage.localPath
                ledger.components[name] = ledger.components[name] or {}
                ledger.components[name].lastSeenVersion = currentUpdateData.version
            end
            saveLedger(ledger)
        end
    end)

    if UpdateBadge then
        UpdateBadge.MouseButton1Click:Connect(openUpdateModal)
    end

    -- Keybind: Shift + F7 to toggle Update Gate (Shift + F8 toggles Task Manager HUD)
    local inputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.F7 then
            local isShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
            if isShift then
                if ModalBackdrop.Visible then
                    closeUpdateModal()
                else
                    openUpdateModal()
                end
            end
        end
    end)

    ApplyUpdateBtn.MouseButton1Click:Connect(function()
        if not currentUpdateData then return end

        -- Option B: Two-click confirmation for obfuscated updates
        if isObfuscatedUpdateDetected and not forceInstallConfirmActive then
            forceInstallConfirmActive = true
            refreshApplyButtonUI()
            if forceInstallResetThread then
                task.cancel(forceInstallResetThread)
            end
            forceInstallResetThread = task.delay(4.5, function()
                forceInstallConfirmActive = false
                refreshApplyButtonUI()
            end)
            return
        end

        if forceInstallResetThread then
            task.cancel(forceInstallResetThread)
            forceInstallResetThread = nil
        end
        forceInstallConfirmActive = false

        ApplyUpdateBtn.Active = false
        ApplyUpdateBtn.Text = "⏳ Fetching from GitHub..."

        task.spawn(function()
            local stages = currentUpdateData.stages
            if not stages or #stages == 0 then
                stages = {
                    {
                        repoPath = "kernel/KernelTaskManager.lua",
                        localPath = "autoexec/kernel/KernelTaskManager.lua",
                        name = "KernelTaskManager"
                    }
                }
            end

            local anySuccess = false
            local lastCode = nil
            local shaToUse = (currentUpdateData and currentUpdateData.sha) or getLatestCommitSha()
            local ledger = loadLedger()

            for idx, stage in ipairs(stages) do
                local repoPath = stage.repoPath or stage.url
                local localPath = stage.localPath or stage.path
                if not localPath or type(localPath) ~= "string" then
                    continue
                end
                local name = stage.name or localPath:match("[^/\\]+$") or "Component"

                local remoteContent = stage.code or stage.content or fetchedStageCodes[idx]
                if not remoteContent and repoPath then
                    local url = repoPath
                    if not url:find("^https?://") then
                        url = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/" .. shaToUse .. "/" .. url
                    end
                    remoteContent = fetchGithubScript(url)
                end

                if remoteContent and #remoteContent > 100 then
                    -- Ensure parent directory exists
                    local parentDir = localPath:match("^(.*)[/\\][^/\\]+$")
                    if parentDir and isfolder and not isfolder(parentDir) then
                        pcall(makefolder, parentDir)
                    end

                    local ok, err = pcall(writefile, localPath, remoteContent)
                    if ok then
                        anySuccess = true
                        ledger.components[name] = {
                            installed = true,
                            lastSeenVersion = currentUpdateData.version,
                            path = localPath,
                            updatedAt = os.time()
                        }
                        if localPath:find("KernelTaskManager") then
                            lastCode = remoteContent
                        elseif localPath:find("OmniEnhancementSuite") then
                            -- Live reload enhancement suite
                            task.spawn(function()
                                local fn = loadstring(remoteContent, "@OmniEnhancementSuite")
                                if fn then pcall(fn) end
                            end)
                        end
                    else
                        warn("[OmniUpdater]: Failed writing " .. localPath .. ": " .. tostring(err))
                    end
                end
            end

            ledger.version = currentUpdateData.version
            saveLedger(ledger)

            if anySuccess then
                getgenv()._OmniUpdateDismissed = true
                getgenv()._OmniUpdateAvailable = false
                ApplyUpdateBtn.Text = "✓ Applied! Reloading Omni..."
                task.wait(0.7)
                closeUpdateModal()
                PillToast.Visible = false
                if UpdateBadge then UpdateBadge.Visible = false end

                -- Teardown old instance and execute updated code if kernel was updated
                if lastCode then
                    if type(getgenv()._KernelTaskManagerUnifiedCleanUp) == "function" then
                        pcall(getgenv()._KernelTaskManagerUnifiedCleanUp)
                    end
                    local fn, syntaxErr = loadstring(lastCode, "@KernelTaskManager")
                    if fn then
                        task.spawn(fn)
                    else
                        warn("[OmniUpdater]: Reload compilation error: " .. tostring(syntaxErr))
                    end
                end
            else
                ApplyUpdateBtn.Text = "❌ Download Failed (Check Connection)"
                task.wait(2.5)
                ApplyUpdateBtn.Active = true
                refreshApplyButtonUI()
            end
        end)
    end)

    -- Background Update & Missing Component Checker
    task.spawn(function()
        task.wait(1.5)
        local sha = getLatestCommitSha()
        local manifestUrl = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/" .. sha .. "/manifest.json"
        local rawManifest = fetchGithubScript(manifestUrl)
        if not rawManifest then
            rawManifest = fetchGithubScript(MANIFEST_URL .. "?v=" .. tostring(os.time()))
        end
        if not rawManifest then return end

        local ok, parsed = pcall(function() return HttpService:JSONDecode(rawManifest) end)
        if not ok or not parsed or not parsed.version then return end

        local ledger = loadLedger()
        local hasUpdate = false
        local missingAvailable = {}
        local installedVersion = (ledger and ledger.version) or CURRENT_OMNI_VERSION

        if isNewerVersion(parsed.version, installedVersion) then
            hasUpdate = true
        end

        if parsed.stages and type(parsed.stages) == "table" then
            for _, stage in ipairs(parsed.stages) do
                local localPath = stage.localPath or stage.path
                if not localPath or type(localPath) ~= "string" then
                    continue
                end
                local name = stage.name or localPath
                if isfile and not isfile(localPath) then
                    local compData = ledger.components[name]
                    local lastSeen = compData and compData.lastSeenVersion
                    if not lastSeen or isNewerVersion(parsed.version, lastSeen) then
                        table.insert(missingAvailable, name)
                    end
                end
            end
        end

        if hasUpdate or #missingAvailable > 0 then
            currentUpdateData = {
                version = parsed.version,
                releaseDate = parsed.releaseDate or "Latest",
                title = parsed.title or ("Omni v" .. parsed.version),
                changelog = parsed.changelog or { "Performance improvements and bug fixes" },
                stages = sanitizeStages(parsed.stages or {}),
                sha = sha
            }

            -- Show TitleBar badge
            getgenv()._OmniUpdateAvailable = true
            getgenv()._OmniUpdateBadgeText = "⚡ v" .. tostring(parsed.version) .. " Available"

            if UpdateBadge then
                UpdateBadge.Text = getgenv()._OmniUpdateBadgeText
                UpdateBadge.Visible = true
            end

            -- Show floating Pill Toast if not dismissed
            if not getgenv()._OmniUpdateDismissed then
                if hasUpdate then
                    PillSubtitle.Text = "v" .. tostring(installedVersion) .. " ➔ v" .. tostring(parsed.version)
                else
                    PillSubtitle.Text = #missingAvailable .. " new component(s) available"
                end
                PillToast.Visible = true
            end
        end
    end)

    return function()
        if inputConn then
            pcall(function() inputConn:Disconnect() end)
            inputConn = nil
        end
        if UpdateScreenGui then
            pcall(function() UpdateScreenGui:Destroy() end)
            UpdateScreenGui = nil
        end
        getgenv().OpenOmniUpdateGate = nil
        getgenv().TestOmniUpdateGate = nil
    end
end

-- Launch Root-of-Trust Security & Update Gate
task.spawn(function()
    local ok, err = pcall(function()
        local guiParent = getGuiParent()
        if guiParent then
            initUpdateGate(guiParent)
        end
    end)
    if not ok then
        warn("[Bootloader]: Update Gate initialization error: " .. tostring(err))
    end
end)

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
    if name == "bootloader.lua" or name == "customautoexec.lua" or name == "bootloader_updated.lua" then return false end
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

    -- Deduplicate scripts in same directory by canonical basename (e.g. KernelTaskManager.lua vs KernelTaskManager.txt)
    local parentDir = filePath:match("^(.*)[/\\][^/\\]+$") or ""
    local rawName = meta.name:gsub("%.%w+$", ""):lower()
    local dedupKey = parentDir:lower() .. "/" .. rawName
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
bootStart = os.clock()
getgenv()._OmniRingsStarted = true
pcall(function()
    if isfile and isfile("Bootloader_Handoff.lock") then
        pcall(delfile, "Bootloader_Handoff.lock")
    end
end)

if not SafeMode and not getgenv()._KernelTaskManagerLoaded then
    if isfolder("autoexec/kernel") then
        scanDirectory("autoexec/kernel", "Kernel")
    end
    if isfolder("autoexec/root") then
        scanDirectory("autoexec/root", "Kernel")
    end

    sortQueue(Queues.Kernel)

    for _, meta in ipairs(Queues.Kernel) do
        executeScript(meta)
    end
elseif SafeMode then
    print("[Bootloader]: Safe Mode Active — Bypassing Ring 0 (Kernel).")
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
                elseif lowerFolder == "gameloaded" or lowerFolder == "game_loaded" then
                    -- Stage: GameLoaded folder
                    scanDirectory(item, "GameLoaded")
                elseif lowerFolder == "characterready" or lowerFolder == "characterloaded" or lowerFolder == "character_ready" or lowerFolder == "character_loaded" then
                    -- Stage: CharacterReady folder
                    scanDirectory(item, "CharacterReady")
                elseif lowerFolder == "deferred" or lowerFolder == "deffered" then
                    -- Stage: Deferred folder
                    scanDirectory(item, "Deferred")
                elseif folderName == PlaceIdStr 
                    or startsWith(folderName, PlaceIdStr .. " - ")
                    or startsWith(folderName, PlaceIdStr .. "_")
                    or lowerFolder == "place_" .. PlaceIdStr 
                    or startsWith(lowerFolder, "place_" .. PlaceIdStr .. " - ")
                    or startsWith(lowerFolder, "place_" .. PlaceIdStr .. "_")
                    or lowerFolder == "place" .. PlaceIdStr then
                    -- Place-specific folder (scans nodelay/ as PreInit, others as GameLoaded)
                    scanDirectory(item, "GameLoaded")
                elseif (GameIdStr ~= "0" and (folderName == GameIdStr 
                    or startsWith(folderName, GameIdStr .. " - ")
                    or startsWith(folderName, GameIdStr .. "_")
                    or lowerFolder == "universe_" .. GameIdStr 
                    or startsWith(lowerFolder, "universe_" .. GameIdStr .. " - ")
                    or lowerFolder == "game_" .. GameIdStr
                    or startsWith(lowerFolder, "game_" .. GameIdStr .. " - "))) then
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
                        or startsWith(lowerFolder, "account_" .. AccountName:lower() .. " - ")
                        or startsWith(lowerFolder, "account_" .. AccountName:lower() .. "_")
                        or startsWith(lowerFolder, "user_" .. AccountName:lower() .. " - ")
                        or startsWith(lowerFolder, "user_" .. AccountName:lower() .. "_") then
                        
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

    -- Full boot pipeline successfully completed: clear running crash sentinel lockfile
    pcall(delfile, RUNNING_LOCK)

    getgenv()._OmniBootloaderRunning = false
    getgenv()._OmniBootloaderLoaded = true

    print(string.format("[Bootloader]: Boot completed in %.1fms | Discovered: %d | Executed: %d | Success: %d | Errors: %d",
        totalBootMs, Telemetry.discovered, Telemetry.executed, Telemetry.success, Telemetry.errors))

    -- Keep Omni alive across teleports if not installed in autoexec
    local queueOnTeleport = (syn and syn.queue_on_teleport) or queue_on_teleport or queueonteleport or (fluxus and fluxus.queue_on_teleport)
    if type(queueOnTeleport) == "function" then
        pcall(function()
            queueOnTeleport([[
                task.spawn(function()
                    local waited = 0
                    while waited < 5.0 and not getgenv()._OmniBootloaderLoaded and not getgenv()._OmniBootloaderRunning do
                        task.wait(0.2)
                        waited = waited + 0.2
                    end
                    if not getgenv()._OmniBootloaderLoaded and not getgenv()._OmniBootloaderRunning then
                        local hasLocal = (type(isfile) == "function") and (isfile("autoexec/Bootloader.lua") or isfile("workspace/autoexec/Bootloader.lua") or isfile("autoexec/CustomAutoExec.lua") or isfile("Omni_Installed.marker"))
                        if not hasLocal then
                            pcall(function()
                                loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/release/Bootloader.lua"))()
                            end)
                        end
                    end
                end)
            ]])
        end)
    end
end)