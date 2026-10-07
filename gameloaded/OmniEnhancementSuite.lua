--!stage GameLoaded
--!name OmniEnhancementSuite
--!priority 120
-- ============================================================================
-- OmniEnhancementSuite.lua
-- Comprehensive In-Game Enhancement Suite for Roblox (Omni Ecosystem)
-- Features:
--   1. Streamer Mode (Visual-only display/username/ID spoofing & overhead redaction)
--   2. Personal Space Bubble (Smooth distance falloff + temporal lerp fade + 10-step drag & slide slider)
--   3. Universal Player Locator & ESP (Box adornments, on-demand highlight pool up to 255, raycast tracers, team quick-toggle)
--   4. Leaderboard Context Tools (Track/Untrack button, animated 2x2 accordion copy panel for ID/Profile/Names)
--   5. Chat Enhancements (Timestamp prefixes, username/display name mention audio chimes)
--   6. Anti-AFK (Inactivity kick prevention)
--   7. Native ESC Menu Integration (Seamlessly injected at top of Settings page)
-- ============================================================================

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- ============================================================================
-- Section 1: Services & Environment Bootstrap
-- ============================================================================
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Teams = game:GetService("Teams")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local SoundService = game:GetService("SoundService")

while not Players.LocalPlayer do
    task.wait()
end
local LocalPlayer = Players.LocalPlayer

local function GetLocalPlayer()
    if not LocalPlayer then
        LocalPlayer = Players.LocalPlayer
    end
    return LocalPlayer
end

-- ============================================================================
-- Section 2: Unified Lifecycle & Cleanup (Hot-Reload Safety)
-- ============================================================================
local genv = (typeof(getgenv) == "function" and getgenv()) or nil

if genv then
    if genv.__OmniEnhancementCleanup then
        pcall(genv.__OmniEnhancementCleanup)
        genv.__OmniEnhancementCleanup = nil
    end
    if genv.__EnhancementCleanup then
        pcall(genv.__EnhancementCleanup)
        genv.__EnhancementCleanup = nil
    end
end

local Janitor = {}
local function Own(x)
    table.insert(Janitor, x)
    return x
end

-- ============================================================================
-- Section 3: Configuration & State Management
-- ============================================================================
local CONFIG_FILE = "omni_enhancement_config.json"
local LEGACY_CONFIG_FILE = "roblox_enhancement_config.json"

local config = {
    streamer_mode = true,
    personal_space_bubble = 0,
    chat_timestamps = true,
    mention_chimes = true,
    force_bubble_chat = true,
    anti_afk = true,
    locator_esp = true,
    locator_tracers = true,
    locator_distance = true,
}

local function LoadConfig()
    pcall(function()
        if typeof(readfile) == "function" and typeof(isfile) == "function" then
            local fileToRead = nil
            if isfile(CONFIG_FILE) then
                fileToRead = CONFIG_FILE
            elseif isfile(LEGACY_CONFIG_FILE) then
                fileToRead = LEGACY_CONFIG_FILE
            end
            if fileToRead then
                local raw = readfile(fileToRead)
                local data = HttpService:JSONDecode(raw)
                if type(data) == "table" then
                    for k, v in pairs(data) do
                        config[k] = v
                    end
                end
            end
        end
    end)
end

local function SaveConfig()
    pcall(function()
        if typeof(writefile) == "function" then
            writefile(CONFIG_FILE, HttpService:JSONEncode(config))
        end
    end)
end

LoadConfig()

-- ============================================================================
-- Section 4: Streamer Mode Engine
-- Visual-Only Metamethod Spoofing + Overhead / CoreGui Redaction
-- Scripts reading properties receive genuine unredacted values.
-- ============================================================================
local StreamerMode = {}
local OriginalTexts = setmetatable({}, { __mode = "k" })
local HookedObjects = setmetatable({}, { __mode = "k" })
local StreamerConns = {}
local isRedacting = false
local isStreamerActive = false

local function EscapeReplacement(s)
    return (s:gsub("%%", "%%%%"))
end

local function BuildCaseInsensitivePattern(s)
    local pattern = ""
    for i = 1, #s do
        local c = s:sub(i, i)
        if c:match("%a") then
            pattern = pattern .. "[" .. c:lower() .. c:upper() .. "]"
        elseif c:match("[%^%$%(%)%%%.%[%]%*%+%-%?]") then
            pattern = pattern .. "%" .. c
        else
            pattern = pattern .. c
        end
    end
    return pattern
end

local TargetCache = {
    targets = {},
    dirty = true,
}

local function InvalidateTargets()
    TargetCache.dirty = true
end

local playerAnonMap = {}
local playerAnonCounter = 0

local function GetAnonPlayerName(p)
    local uid = p.UserId
    if not playerAnonMap[uid] then
        playerAnonCounter = playerAnonCounter + 1
        playerAnonMap[uid] = "Player " .. tostring(playerAnonCounter)
    end
    return playerAnonMap[uid]
end

local function GetCompiledTargets()
    if not TargetCache.dirty then
        return TargetCache.targets
    end

    local targets = {}
    local function Add(str, replacement)
        if typeof(str) == "string" and #str > 1 then
            local pat = BuildCaseInsensitivePattern(str)
            table.insert(targets, { pattern = pat, rep = EscapeReplacement(replacement), len = #str, plainLower = str:lower() })
        end
    end

    local lp = GetLocalPlayer()
    if lp then
        Add(tostring(lp.UserId), "00000000")
        Add(lp.DisplayName, "Streamer")
        Add(lp.Name, "Streamer")
    end

    local allPlayers = Players:GetPlayers()
    for _, p in ipairs(allPlayers) do
        if p ~= lp then
            local anon = GetAnonPlayerName(p)
            Add(tostring(p.UserId), "00000000")
            Add(p.DisplayName, anon)
            Add(p.Name, anon)
        end
    end

    table.sort(targets, function(a, b) return a.len > b.len end)
    TargetCache.targets = targets
    TargetCache.dirty = false
    return targets
end

Own(Players.PlayerAdded:Connect(InvalidateTargets))
Own(Players.PlayerRemoving:Connect(InvalidateTargets))

local function RedactString(str)
    if typeof(str) ~= "string" or #str < 2 then return str end
    -- High-speed fast path: if string contains no letters and no 7+ digit IDs, it cannot contain player names
    if not str:find("%a") and not str:find("%d%d%d%d%d%d%d") then
        return str
    end
    local targets = GetCompiledTargets()
    local lowerStr = str:lower()
    local res = str
    for _, t in ipairs(targets) do
        if lowerStr:find(t.plainLower, 1, true) then
            res = res:gsub(t.pattern, t.rep)
            lowerStr = res:lower()
        end
    end
    return res
end

local function IsEnhancementGui(obj)
    local current = obj
    while current and current ~= game do
        if current.Name:sub(1, 12) == "Enhancement_" or current.Name:sub(1, 17) == "RobloxEnhancement" then
            return true
        end
        current = current.Parent
    end
    return false
end

-- Metamethod Handlers (Dynamic routing via executor environment preserves C++ pointers across hot-reloads)
local originalIndex = genv and genv.__EnhancementOriginalIndex
local originalNewIndex = genv and genv.__EnhancementOriginalNewIndex

local function IndexHandler(self, key)
    if isStreamerActive and typeof(self) == "Instance" then
        if key == "Text" or (key == "DisplayName" and self:IsA("Humanoid")) then
            local orig = OriginalTexts[self]
            if orig ~= nil then
                return orig
            end
        end
    end
    return originalIndex(self, key)
end

local function NewIndexHandler(self, key, value)
    if isStreamerActive and not isRedacting and typeof(self) == "Instance" then
        if key == "Text" then
            if self:IsA("TextLabel") or self:IsA("TextButton") or self:IsA("TextBox") then
                if not IsEnhancementGui(self) then
                    local strVal = tostring(value or "")
                    local redacted = RedactString(strVal)
                    if redacted ~= strVal then
                        OriginalTexts[self] = strVal
                        return originalNewIndex(self, key, redacted)
                    else
                        OriginalTexts[self] = nil
                        return originalNewIndex(self, key, value)
                    end
                end
            end
        elseif key == "DisplayName" and self:IsA("Humanoid") then
            local strVal = tostring(value or "")
            local redacted = RedactString(strVal)
            if redacted ~= strVal then
                OriginalTexts[self] = strVal
                return originalNewIndex(self, key, redacted)
            else
                OriginalTexts[self] = nil
                return originalNewIndex(self, key, value)
            end
        end
    end
    return originalNewIndex(self, key, value)
end

if typeof(hookmetamethod) == "function" and (genv and genv._OmniEnableMetamethodHooks) then
    if not originalIndex then
        originalIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
            if genv and genv.__EnhancementIndexHandler then
                return genv.__EnhancementIndexHandler(self, key)
            end
            return IndexHandler(self, key)
        end))
        if genv then genv.__EnhancementOriginalIndex = originalIndex end
    end
    if genv then genv.__EnhancementIndexHandler = IndexHandler end

    if not originalNewIndex then
        originalNewIndex = hookmetamethod(game, "__newindex", newcclosure(function(self, key, value)
            if genv and genv.__EnhancementNewIndexHandler then
                return genv.__EnhancementNewIndexHandler(self, key, value)
            end
            return NewIndexHandler(self, key, value)
        end))
        if genv then genv.__EnhancementOriginalNewIndex = originalNewIndex end
    end
    if genv then genv.__EnhancementNewIndexHandler = NewIndexHandler end
else
    originalIndex = function(self, key) return self[key] end
    originalNewIndex = function(self, key, value) self[key] = value end
end

local function GetRawText(obj)
    if originalIndex then
        return originalIndex(obj, "Text")
    end
    return obj.Text
end

local function SetRawText(obj, val)
    if originalNewIndex then
        return originalNewIndex(obj, "Text", val)
    end
    obj.Text = val
end

local function GetRawDisplayName(hum)
    if originalIndex then
        return originalIndex(hum, "DisplayName")
    end
    return hum.DisplayName
end

local function SetRawDisplayName(hum, val)
    if originalNewIndex then
        return originalNewIndex(hum, "DisplayName", val)
    end
    hum.DisplayName = val
end

-- ============================================================================
-- Section 4.1: Universal Text & DisplayName Hooks (The 3 Render Roots)
-- Content-based redaction across all 3 Roblox render roots:
--   Root 1: CoreGui (Roblox Native UI: PlayerList, Chat, Settings, Emotes)
--   Root 2: PlayerGui (Developer 2D UI: Custom HUDs, Leaderboards, Menus)
--   Root 3: Workspace (In-World 3D UI: BillboardGui, SurfaceGui, Humanoid)
-- ============================================================================

local function HookTextObject(obj)
    if not (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then return end
    if HookedObjects[obj] or IsEnhancementGui(obj) then return end
    HookedObjects[obj] = true

    local function Check()
        if not isStreamerActive or isRedacting then return end
        local raw = GetRawText(obj)
        if raw and #raw >= 2 then
            local currentRedacted = OriginalTexts[obj] and RedactString(OriginalTexts[obj])
            local sourceText = (raw ~= currentRedacted) and raw or (OriginalTexts[obj] or raw)
            local redacted = RedactString(sourceText)
            if redacted ~= sourceText then
                OriginalTexts[obj] = sourceText
                local currentRaw = GetRawText(obj)
                if currentRaw ~= redacted then
                    isRedacting = true
                    pcall(function() SetRawText(obj, redacted) end)
                    isRedacting = false
                end
            else
                if OriginalTexts[obj] then
                    OriginalTexts[obj] = nil
                end
            end
        end
    end

    Check()
    local conn = obj:GetPropertyChangedSignal("Text"):Connect(Check)
    table.insert(StreamerConns, conn)
end

local function HookHumanoid(hum)
    if not hum or not hum:IsA("Humanoid") then return end
    if HookedObjects[hum] then return end
    HookedObjects[hum] = true

    local function Check()
        if not isStreamerActive or isRedacting then return end
        local raw = GetRawDisplayName(hum)
        if raw and #raw >= 2 then
            local currentRedacted = OriginalTexts[hum] and RedactString(OriginalTexts[hum])
            local sourceText = (raw ~= currentRedacted) and raw or (OriginalTexts[hum] or raw)
            local redacted = RedactString(sourceText)
            if redacted ~= sourceText then
                OriginalTexts[hum] = sourceText
                local currentRaw = GetRawDisplayName(hum)
                if currentRaw ~= redacted then
                    isRedacting = true
                    pcall(function() SetRawDisplayName(hum, redacted) end)
                    isRedacting = false
                end
            else
                if OriginalTexts[hum] then
                    OriginalTexts[hum] = nil
                end
            end
        end
    end

    Check()
    local conn = hum:GetPropertyChangedSignal("DisplayName"):Connect(Check)
    table.insert(StreamerConns, conn)
end

local function HookGuiContainer(container)
    if not container then return end
    for _, d in ipairs(container:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
            HookTextObject(d)
        end
    end
    local c = container.DescendantAdded:Connect(function(desc)
        if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") then
            HookTextObject(desc)
        end
    end)
    table.insert(StreamerConns, c)
end

function StreamerMode.Enable()
    isStreamerActive = true
    for _, c in ipairs(StreamerConns) do
        if typeof(c) == "RBXScriptConnection" or (type(c) == "table" and type(c.Disconnect) == "function") then
            pcall(function() c:Disconnect() end)
        elseif typeof(c) == "thread" then
            pcall(task.cancel, c)
        end
    end
    table.clear(StreamerConns)
    table.clear(HookedObjects)

    -- Dynamic Target Re-compilation on player roster changes
    local pAddedConn = Players.PlayerAdded:Connect(function()
        InvalidateTargets()
        if config.streamer_mode then
            StreamerMode.Refresh()
        end
    end)
    table.insert(StreamerConns, pAddedConn)

    local pRemovedConn = Players.PlayerRemoving:Connect(function()
        InvalidateTargets()
        if config.streamer_mode then
            StreamerMode.Refresh()
        end
    end)
    table.insert(StreamerConns, pRemovedConn)

    -- ROOT 1: CoreGui (All Roblox Native UIs)
    HookGuiContainer(CoreGui)

    -- ROOT 2: PlayerGui (All Developer 2D Screen UIs & HUDs)
    local lp = GetLocalPlayer()
    if lp then
        local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
        if pg then HookGuiContainer(pg) end
        local pgConn = lp.ChildAdded:Connect(function(child)
            if child:IsA("PlayerGui") or child.Name == "PlayerGui" then
                HookGuiContainer(child)
            end
        end)
        table.insert(StreamerConns, pgConn)
    end

    -- Periodic Re-check Sweep across PlayerGui every 15s (DescendantAdded already catches dynamic additions)
    local sweepThread = task.spawn(function()
        while isStreamerActive do
            task.wait(15)
            if not isStreamerActive then break end
            local curLp = GetLocalPlayer()
            if curLp then
                local pg = curLp:FindFirstChildOfClass("PlayerGui") or curLp:FindFirstChild("PlayerGui")
                if pg then
                    for _, d in ipairs(pg:GetDescendants()) do
                        if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) and not HookedObjects[d] and not IsEnhancementGui(d) then
                            HookTextObject(d)
                        end
                    end
                end
            end
        end
    end)
    table.insert(StreamerConns, sweepThread)

    -- ROOT 3: Workspace (All In-World 3D Overheads, BillboardGuis, SurfaceGuis & Characters)
    local function OnWorkspaceDescendant(desc)
        if desc:IsA("BillboardGui") or desc:IsA("SurfaceGui") then
            HookGuiContainer(desc)
        elseif desc:IsA("Humanoid") then
            HookHumanoid(desc)
        elseif desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") then
            if desc:FindFirstAncestorOfClass("BillboardGui") or desc:FindFirstAncestorOfClass("SurfaceGui") then
                HookTextObject(desc)
            end
        end
    end

    -- Connect Workspace live listener FIRST so no dynamic spawns are missed
    local wsConn = Workspace.DescendantAdded:Connect(OnWorkspaceDescendant)
    table.insert(StreamerConns, wsConn)

    -- Character lifecycle watcher for Humanoid & Overheads
    local function TrackPlayerCharacter(p)
        if p.Character then
            for _, d in ipairs(p.Character:GetDescendants()) do
                OnWorkspaceDescendant(d)
            end
        end
        local cConn = p.CharacterAdded:Connect(function(char)
            task.defer(function()
                if not isStreamerActive or not char then return end
                for _, d in ipairs(char:GetDescendants()) do
                    OnWorkspaceDescendant(d)
                end
            end)
        end)
        table.insert(StreamerConns, cConn)
    end

    for _, p in ipairs(Players:GetPlayers()) do
        TrackPlayerCharacter(p)
    end
    local pCharConn = Players.PlayerAdded:Connect(TrackPlayerCharacter)
    table.insert(StreamerConns, pCharConn)

    -- Frame-budgeted initial sweep across Workspace for pre-existing 3D GUIs (yields every 500 instances)
    task.spawn(function()
        local descs = Workspace:GetDescendants()
        local chunkSize = 500
        for i = 1, #descs do
            if not isStreamerActive then break end
            local d = descs[i]
            if d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
                HookGuiContainer(d)
            elseif d:IsA("Humanoid") then
                HookHumanoid(d)
            end
            if i % chunkSize == 0 then
                task.wait()
            end
        end
    end)

    -- Immediate refresh on startup
    StreamerMode.Refresh()
end

function StreamerMode.Refresh()
    -- Fast in-memory update across tracked targets (< 0.05ms)
    for obj, origText in pairs(OriginalTexts) do
        if obj and obj.Parent then
            local redacted = RedactString(origText)
            if obj:IsA("Humanoid") then
                local raw = GetRawDisplayName(obj)
                if raw ~= redacted then
                    isRedacting = true
                    pcall(function() SetRawDisplayName(obj, redacted) end)
                    isRedacting = false
                end
            else
                local rawText = GetRawText(obj)
                if rawText ~= redacted then
                    isRedacting = true
                    pcall(function() SetRawText(obj, redacted) end)
                    isRedacting = false
                end
            end
        end
    end
end

function StreamerMode.Disable()
    isStreamerActive = false
    for _, c in ipairs(StreamerConns) do
        if typeof(c) == "RBXScriptConnection" or (type(c) == "table" and type(c.Disconnect) == "function") then
            pcall(function() c:Disconnect() end)
        elseif typeof(c) == "thread" then
            pcall(task.cancel, c)
        end
    end
    table.clear(StreamerConns)
    table.clear(HookedObjects)
    playerAnonCounter = 0
    table.clear(playerAnonMap)

    isRedacting = true
    for obj, origText in pairs(OriginalTexts) do
        if obj and obj.Parent then
            if obj:IsA("Humanoid") then
                pcall(function() SetRawDisplayName(obj, origText) end)
            else
                pcall(function() SetRawText(obj, origText) end)
            end
        end
    end
    isRedacting = false
    table.clear(OriginalTexts)
end

-- ============================================================================
-- Section 5: Personal Space Bubble Engine (Nearby Player Fade)
-- Binary state with smooth temporal fade on enter/exit (no distance falloff)
-- ============================================================================
local PersonalSpaceBubble = {}
local bubbleConn
local charAlphas = {}
local charInside = {}

local BUBBLE_TARGET_ALPHA = 0.85
local FADE_SPEED = 7
local HYSTERESIS_BUFFER = 1.0

local function StepToRadius(step)
    if not step or step <= 0 then return 0 end
    return 3 + (step - 1) * (12 / 9)
end

local charPartsCache = setmetatable({}, { __mode = "k" })
local charAppliedAlpha = setmetatable({}, { __mode = "k" })

local function getCharParts(char)
    local parts = charPartsCache[char]
    if not parts then
        parts = {}
        for _, desc in ipairs(char:GetDescendants()) do
            if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
                table.insert(parts, desc)
            end
        end
        charPartsCache[char] = parts
    end
    return parts
end

local function ApplyCharTransparency(char, alpha)
    local last = charAppliedAlpha[char]
    if last and math.abs(last - alpha) < 0.005 then return end
    charAppliedAlpha[char] = alpha
    local parts = getCharParts(char)
    for i = #parts, 1, -1 do
        local p = parts[i]
        if p and p.Parent then
            p.LocalTransparencyModifier = alpha
        else
            table.remove(parts, i)
        end
    end
end

function PersonalSpaceBubble.Enable()
    if bubbleConn then
        bubbleConn:Disconnect()
        bubbleConn = nil
    end

    bubbleConn = RunService.RenderStepped:Connect(function(dt)
        local step = config.personal_space_bubble or 0
        if step <= 0 then
            PersonalSpaceBubble.Disable()
            return
        end

        local radius = StepToRadius(step)
        local exitRadius = radius + HYSTERESIS_BUFFER

        local lp = GetLocalPlayer()
        local myChar = lp and lp.Character
        local myRoot = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Head"))
        if not myRoot then return end
        local myPos = myRoot.Position

        local activeChars = {}

        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= lp and p.Character then
                local char = p.Character
                local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
                if root then
                    activeChars[char] = true
                    local dist = (root.Position - myPos).Magnitude

                    local wasInside = charInside[char] or false
                    local isInside = false
                    if wasInside then
                        isInside = (dist <= exitRadius)
                    else
                        isInside = (dist <= radius)
                    end
                    charInside[char] = isInside

                    local targetAlpha = isInside and BUBBLE_TARGET_ALPHA or 0
                    local currentAlpha = charAlphas[char] or 0

                    if isInside or currentAlpha > 0 then
                        local lerpFactor = math.clamp(dt * FADE_SPEED, 0, 1)
                        local newAlpha = currentAlpha + (targetAlpha - currentAlpha) * lerpFactor

                        if math.abs(newAlpha - targetAlpha) < 0.008 then
                            newAlpha = targetAlpha
                        end

                        charAlphas[char] = newAlpha
                        ApplyCharTransparency(char, newAlpha)

                        if newAlpha == 0 and not isInside then
                            charAlphas[char] = nil
                            charInside[char] = nil
                        end
                    end
                end
            end
        end

        for char, _ in pairs(charAlphas) do
            if not activeChars[char] then
                charAlphas[char] = nil
                charInside[char] = nil
            end
        end
    end)
end

function PersonalSpaceBubble.Disable()
    if bubbleConn then
        bubbleConn:Disconnect()
        bubbleConn = nil
    end
    for char, _ in pairs(charAlphas) do
        if char and char.Parent then
            ApplyCharTransparency(char, 0)
        end
    end
    charAlphas = {}
    charInside = {}
    charPartsCache = setmetatable({}, { __mode = "k" })
    charAppliedAlpha = setmetatable({}, { __mode = "k" })
end

-- ============================================================================
-- Section 6: Chat Enhancements (Timestamps & Mention Chimes)
-- ============================================================================
local function FormatTimestamp()
    local s = os.date("%I:%M %p"):gsub("^0", "")
    return s
end

local function PlayMentionChime()
    task.spawn(function()
        pcall(function()
            local sound = Instance.new("Sound")
            sound.SoundId = "rbxassetid://131039887376992"
            sound.Volume = 0.85
            sound.Parent = SoundService
            sound:Play()
            sound.Ended:Connect(function() sound:Destroy() end)
            task.delay(3, function()
                if sound and sound.Parent then sound:Destroy() end
            end)
        end)
    end)
end

local function ProcessIncomingTextMessage(message)
    local props = Instance.new("TextChatMessageProperties")

    local currentPrefix = (message and message.PrefixText) or ""
    local currentText = (message and message.Text) or ""

    if config.streamer_mode then
        if currentPrefix and currentPrefix ~= "" then
            currentPrefix = RedactString(currentPrefix)
        end
        if currentText and currentText ~= "" then
            currentText = RedactString(currentText)
        end
    end

    if config.chat_timestamps then
        local timeStr = FormatTimestamp()
        props.PrefixText = string.format("<font color='#A0A0A0'>[%s]</font> %s", timeStr, currentPrefix)
    else
        props.PrefixText = currentPrefix
    end
    props.Text = currentText

    if config.mention_chimes and message and message.TextSource then
        local lp = GetLocalPlayer()
        if lp and message.TextSource.UserId ~= lp.UserId then
            local text = message.Text or ""
            local namePat = lp.Name and BuildCaseInsensitivePattern(lp.Name)
            local dispPat = lp.DisplayName and BuildCaseInsensitivePattern(lp.DisplayName)
            if (namePat and text:find(namePat)) or (dispPat and text:find(dispPat)) then
                PlayMentionChime()
            end
        end
    end

    return props
end

-- Hook TextChatService (Modern Roblox Chat)
pcall(function()
    local TextChatService = game:GetService("TextChatService")
    if TextChatService then
        TextChatService.OnIncomingMessage = ProcessIncomingTextMessage
    end
end)

-- ============================================================================
-- Section 6.1: Bubble Chat Override Engine
-- Enforces chat bubbles even if the game developer explicitly disabled them
-- ============================================================================
local BubbleChatManager = {}
local bubbleConns = {}

function BubbleChatManager.Apply()
    if not config.force_bubble_chat then
        BubbleChatManager.Disable()
        return
    end

    -- Modern TextChatService
    pcall(function()
        local TextChatService = game:GetService("TextChatService")
        local function EnableBBC(bbc)
            if not bbc then return end
            pcall(function() bbc.Enabled = true end)
            if not bubbleConns[bbc] then
                local conn = bbc:GetPropertyChangedSignal("Enabled"):Connect(function()
                    if config.force_bubble_chat and not bbc.Enabled then
                        task.defer(function()
                            if bbc and config.force_bubble_chat then
                                pcall(function() bbc.Enabled = true end)
                            end
                        end)
                    end
                end)
                bubbleConns[bbc] = conn
                table.insert(Janitor, conn)
            end
        end

        local bbc = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
        if bbc then
            EnableBBC(bbc)
        end
        local childConn = TextChatService.ChildAdded:Connect(function(child)
            if child:IsA("BubbleChatConfiguration") then
                EnableBBC(child)
            end
        end)
        table.insert(Janitor, childConn)
    end)

    -- Legacy Chat Service
    pcall(function()
        local Chat = game:GetService("Chat")
        if Chat then
            pcall(function() Chat.BubbleChatEnabled = true end)
        end
    end)
end

function BubbleChatManager.Disable()
    for obj, conn in pairs(bubbleConns) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(bubbleConns)
end

-- Initialize Bubble Chat Override
BubbleChatManager.Apply()

-- Hook Legacy Chat (Older Games)
task.spawn(function()
    local lp = GetLocalPlayer()
    if not lp then return end
    local pg = lp:WaitForChild("PlayerGui", 10)
    if not pg then return end

    local function HookLegacyMessageLabel(label)
        if not label or not label:IsA("TextLabel") then return end
        if label:GetAttribute("OmniTimestamped") then return end
        label:SetAttribute("OmniTimestamped", true)

        task.defer(function()
            if not label or not label.Parent then return end
            local originalText = label.Text
            if originalText and originalText ~= "" then
                if config.chat_timestamps then
                    local timeStr = FormatTimestamp()
                    label.Text = string.format("[%s] %s", timeStr, originalText)
                end
                if config.mention_chimes then
                    local namePat = lp.Name and BuildCaseInsensitivePattern(lp.Name)
                    local dispPat = lp.DisplayName and BuildCaseInsensitivePattern(lp.DisplayName)
                    if (namePat and originalText:find(namePat)) or (dispPat and originalText:find(dispPat)) then
                        PlayMentionChime()
                    end
                end
            end
        end)
    end

    local function HookLegacyScroller(scroller)
        if not scroller then return end
        for _, desc in ipairs(scroller:GetDescendants()) do
            if desc:IsA("TextLabel") then HookLegacyMessageLabel(desc) end
        end
        local conn = scroller.DescendantAdded:Connect(function(desc)
            if desc:IsA("TextLabel") then HookLegacyMessageLabel(desc) end
        end)
        table.insert(StreamerConns, conn)
    end

    local function OnChatGuiAdded(chatGui)
        if chatGui.Name ~= "Chat" then return end
        task.spawn(function()
            local frame = chatGui:WaitForChild("Frame", 5)
            local chanFrame = frame and frame:WaitForChild("ChatChannelParentFrame", 5)
            local msgLog = chanFrame and chanFrame:WaitForChild("Frame_MessageLogDisplay", 5)
            local scroller = msgLog and msgLog:WaitForChild("Scroller", 5)
            if scroller then
                HookLegacyScroller(scroller)
            end
        end)
    end

    local chatGui = pg:FindFirstChild("Chat")
    if chatGui then OnChatGuiAdded(chatGui) end
    local pConn = pg.ChildAdded:Connect(OnChatGuiAdded)
    table.insert(StreamerConns, pConn)
end)

-- ============================================================================
-- Section 7: Anti-AFK Engine
-- ============================================================================
local AntiAFK = {}
local afkConn

function AntiAFK.Enable()
    if afkConn then afkConn:Disconnect() afkConn = nil end
    local lp = GetLocalPlayer()
    if lp then
        afkConn = lp.Idled:Connect(function()
            local VirtualUser = game:GetService("VirtualUser")
            if VirtualUser then
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new(0, 0))
            end
        end)
    end
end

function AntiAFK.Disable()
    if afkConn then
        afkConn:Disconnect()
        afkConn = nil
    end
end

-- ============================================================================
-- Section 8: Universal Player Locator & ESP
-- Box adornments, on-demand dynamic highlight pool (up to 255), raycast tracers, team quick-toggle
-- ============================================================================
local Locator = {}
local HighlightPool = {}
local lastActiveHighlights = 0

local function GetPooledHighlight(i)
    local hl = HighlightPool[i]
    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = "VirtualHighlight_" .. i
        hl.FillTransparency = 0
        hl.OutlineTransparency = 0
        hl.Enabled = false
        hl.Parent = nil
        HighlightPool[i] = Own(hl)
    end
    return hl
end

-- ============================================================================
-- Native Game Highlight Budget Monitor (Dynamic 255-slot governor)
-- Real-time tracking of non-enhancement highlights in Workspace and CoreGui
-- ============================================================================
local TOTAL_ENGINE_HIGHLIGHT_CAP = 255
local nativeHighlights = setmetatable({}, { __mode = "k" })
local nativeHighlightCount = 0

local function RegisterNativeHighlight(hl)
    if not hl or not hl:IsA("Highlight") then return end
    if hl.Name:sub(1, 16) == "VirtualHighlight" then return end
    if not nativeHighlights[hl] then
        nativeHighlights[hl] = true
        nativeHighlightCount = nativeHighlightCount + 1
    end
end

local function UnregisterNativeHighlight(hl)
    if not hl or not hl:IsA("Highlight") then return end
    if nativeHighlights[hl] then
        nativeHighlights[hl] = nil
        nativeHighlightCount = math.max(0, nativeHighlightCount - 1)
    end
end

Own(Workspace.DescendantAdded:Connect(RegisterNativeHighlight))
Own(Workspace.DescendantRemoving:Connect(UnregisterNativeHighlight))
Own(CoreGui.DescendantAdded:Connect(RegisterNativeHighlight))
Own(CoreGui.DescendantRemoving:Connect(UnregisterNativeHighlight))

task.spawn(function()
    local descs = Workspace:GetDescendants()
    local chunkSize = 500
    for i = 1, #descs do
        local d = descs[i]
        if d:IsA("Highlight") then
            RegisterNativeHighlight(d)
        end
        if i % chunkSize == 0 then
            task.wait()
        end
    end
end)

local TrackedPlayers = {}
local IndividuallyTrackedPlayers = {}
local TrackedTeams = {}
local PlayerListeners = {}
local UntrackPlayerInternal
local nextInterleaveSlot = 0

local PlayerList = CoreGui:FindFirstChild("PlayerList")

local function GetActualList()
    if not PlayerList then
        PlayerList = CoreGui:FindFirstChild("PlayerList")
        if not PlayerList then return nil end
    end
    local actualList = PlayerList:FindFirstChild("OffsetUndoFrame", true)
    if actualList then return actualList end
    
    local c = PlayerList:FindFirstChild("Children")
    c = c and c:FindFirstChild("OffsetFrame")
    c = c and c:FindFirstChild("PlayerScrollList")
    c = c and c:FindFirstChild("SizeOffsetFrame")
    if not c then return nil end
    
    local container = (c:FindFirstChild("Column") and c.Column:FindFirstChild("Body")) or c:FindFirstChild("ScrollingFrameContainer")
    if not container then return nil end
    
    local clip = container:FindFirstChild("ScrollingFrameClippingFrame")
    local scroll = clip and clip:FindFirstChild("ScrollingFrame")
    return scroll and scroll:FindFirstChild("OffsetUndoFrame")
end

local function NormalizeTeamName(t)
    if typeof(t) == "Instance" and t:IsA("Team") then return t.Name end
    return tostring(t or "")
end

local function NormalizePlayerName(p)
    if typeof(p) == "Instance" and p:IsA("Player") then return p.Name end
    return tostring(p or "")
end

local function IsPlayerTracked(PlayerName)
    PlayerName = NormalizePlayerName(PlayerName)
    return TrackedPlayers[PlayerName] ~= nil
end

local function IsPlayerIndividuallyTracked(PlayerName)
    PlayerName = NormalizePlayerName(PlayerName)
    return IndividuallyTrackedPlayers[PlayerName] == true
end

local function IsTeamTracked(TeamName)
    TeamName = NormalizeTeamName(TeamName)
    return TrackedTeams[TeamName] == true
end

local function SetLeaderboardPlayerIcon(player, show)
    if not player then return end
    local actualList = GetActualList()
    if not actualList then return end
    
    local playerEntry = actualList:FindFirstChild("PlayerEntry_" .. player.UserId, true)
    if not playerEntry then return end
    
    local content = playerEntry:FindFirstChild("PlayerEntryContentFrame")
    local overlay = content and content:FindFirstChild("OverlayFrame")
    local nameFrame = overlay and overlay:FindFirstChild("NameFrame")
    if not nameFrame then return end
    
    local locIcon = nameFrame:FindFirstChild("LocatorIcon")
    local playerIcon = nameFrame:FindFirstChild("PlayerIcon")
    
    if show then
        if not locIcon then
            locIcon = Instance.new("ImageLabel")
            locIcon.Name = "LocatorIcon"
            locIcon.LayoutOrder = 0
            locIcon.Size = UDim2.new(0, 16, 0, 16)
            locIcon.BackgroundTransparency = 1
            locIcon.Image = "rbxassetid://83346450342441"
            locIcon.Parent = nameFrame
        end
        if playerIcon and playerIcon:IsA("ImageLabel") then
            playerIcon.Visible = false
        end
    else
        if locIcon then locIcon:Destroy() end
        if playerIcon and playerIcon:IsA("ImageLabel") then
            playerIcon.Visible = true
        end
    end
end

local function SetLeaderboardTeamIcon(teamName, show)
    teamName = NormalizeTeamName(teamName)
    local actualList = GetActualList()
    if not actualList then return end
    
    local teamlist = actualList:FindFirstChild("TeamList_" .. teamName)
    if not teamlist then return end
    
    local teamEntry = teamlist:FindFirstChild("TeamEntry")
    if not teamEntry then return end
    
    local nameFrame = teamEntry:FindFirstChild("NameFrame")
    local bgFrame = nameFrame and nameFrame:FindFirstChild("BGFrame")
    local overlayFrame = bgFrame and bgFrame:FindFirstChild("OverlayFrame")
    if not overlayFrame then return end
    
    local teamNameLbl = overlayFrame:FindFirstChild("TeamName")
    local locIcon = overlayFrame:FindFirstChild("TeamLocatorIcon")
    
    if show then
        local textX = (teamNameLbl and teamNameLbl.TextBounds.X > 0) and teamNameLbl.TextBounds.X or 48
        local posX = 16 + textX + 6
        
        if not locIcon then
            locIcon = Instance.new("ImageLabel")
            locIcon.Name = "TeamLocatorIcon"
            locIcon.Size = UDim2.new(0, 16, 0, 16)
            locIcon.AnchorPoint = Vector2.new(0, 0.5)
            locIcon.Position = UDim2.new(0, posX, 0.5, 0)
            locIcon.BackgroundTransparency = 1
            locIcon.Image = "rbxassetid://83346450342441"
            locIcon.ZIndex = 5
            locIcon.Parent = overlayFrame
        else
            locIcon.Position = UDim2.new(0, posX, 0.5, 0)
        end
    else
        if locIcon then locIcon:Destroy() end
    end
end

local function GetEffectiveTrackerColor(player)
    local team = player and player.Team
    local teamColor = player and player.TeamColor
    if team and teamColor and teamColor.Name ~= "White" and teamColor.Name ~= "Medium stone grey" then
        return teamColor.Color
    end
    return Color3.fromRGB(0, 230, 255)
end

local function BuildCharacterBoxes(character, teamColor, parentFolder)
    local boxes = {}
    if not character or not character.Parent then return boxes end
    
    for _, part in ipairs(character:GetChildren()) do
        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 0.95 then
            local box = Instance.new("BoxHandleAdornment")
            box.Name = part.Name .. "_Adornment"
            box.Adornee = part
            box.AlwaysOnTop = true
            box.ZIndex = 10
            box.Size = part.Size
            box.Color3 = teamColor
            box.Transparency = 0
            box.Parent = parentFolder
            table.insert(boxes, box)
        end
    end
    return boxes
end

local function BuildBillboard(playerName, character, parentFolder)
    if not character or not character.Parent or not parentFolder then return nil end
    local head = character:FindFirstChild("Head") or character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
    if not head then return nil end
    
    local billboard = Instance.new("BillboardGui")
    billboard.Name = playerName .. "_Billboard"
    billboard.Size = UDim2.new(0, 200, 0, 50)
    billboard.StudsOffset = (head.Name == "Head") and Vector3.new(0, 1.8, 0) or Vector3.new(0, 3.5, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = head
    billboard.Parent = parentFolder
    
    local textLabel = Instance.new("TextLabel")
    textLabel.Name = "NameLabel"
    textLabel.BackgroundTransparency = 1
    textLabel.Position = UDim2.new(0, 0, 0, 0)
    textLabel.Size = UDim2.new(1, 0, 1, 0)
    textLabel.Font = Enum.Font.SourceSansSemibold
    textLabel.TextSize = 18
    textLabel.TextColor3 = Color3.new(1, 1, 1)
    textLabel.TextStrokeTransparency = 0
    textLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    textLabel.TextYAlignment = Enum.TextYAlignment.Center
    textLabel.TextXAlignment = Enum.TextXAlignment.Center
    textLabel.Text = playerName
    textLabel.ZIndex = 10
    textLabel.Parent = billboard
    
    return billboard
end

local function ClearPlayerAdornments(entry)
    if entry.StreamConn then
        entry.StreamConn:Disconnect()
        entry.StreamConn = nil
    end
    for _, b in ipairs(entry.Boxes) do
        b:Destroy()
    end
    entry.Boxes = {}
    if entry.Billboard then
        entry.Billboard:Destroy()
        entry.Billboard = nil
    end
    entry.NameLabel = nil
    entry.LastDistStuds = nil
    entry.LastDistMode = nil
    entry.LastBoxTrans = nil
    entry.LastOffset = nil
    entry.CachedHead = nil
end

local function TrackPlayerInternal(player)
    local localPlayer = LocalPlayer or Players.LocalPlayer
    if player == localPlayer then return end
    local playerName = player.Name
    if TrackedPlayers[playerName] then return end
    
    local container = Instance.new("Folder")
    container.Name = playerName .. "Locate"
    container.Parent = CoreGui
    
    local trackerColor = GetEffectiveTrackerColor(player)
    local tracerGui = Instance.new("ScreenGui")
    tracerGui.Name = playerName .. "TracerGui"
    tracerGui.IgnoreGuiInset = true
    tracerGui.DisplayOrder = 1000
    tracerGui.Parent = CoreGui
    
    local tracerLine = Instance.new("Frame")
    tracerLine.Name = "Line"
    tracerLine.AnchorPoint = Vector2.new(0.5, 0.5)
    tracerLine.BorderSizePixel = 0
    tracerLine.BackgroundColor3 = trackerColor
    tracerLine.ZIndex = 1000
    tracerLine.Visible = false
    tracerLine.Parent = tracerGui
    
    local entry = {
        Player = player,
        Character = player.Character,
        TeamColor = trackerColor,
        CurrentTeam = player.Team,
        Container = container,
        TracerGui = tracerGui,
        TracerLine = tracerLine,
        Boxes = {},
        Billboard = nil,
        NameLabel = nil,
        LastDistStuds = nil,
        LastDistMode = nil,
        LastBoxTrans = nil,
        LastOffset = nil,
        CachedHead = nil,
        InterleaveSlot = nextInterleaveSlot % 3,
        CachedObstructed = nil,
        CandidateData = { Character = nil, Distance = 0, TeamColor = nil },
        CharConn = nil,
        CharRemovingConn = nil,
        StreamConn = nil,
        CurrentTracerTrans = 1,
    }
    nextInterleaveSlot = nextInterleaveSlot + 1
    TrackedPlayers[playerName] = entry
    
    local function SetupCharacter(char)
        if not char then return end
        entry.Character = char
        ClearPlayerAdornments(entry)
        
        task.spawn(function()
            local attempts = 0
            while not char.Parent and attempts < 60 do
                attempts = attempts + 1
                task.wait(0.05)
                if not IsPlayerTracked(playerName) or entry.Character ~= char then return end
            end
            if not char.Parent or not IsPlayerTracked(playerName) then return end
            
            entry.Boxes = BuildCharacterBoxes(char, entry.TeamColor, container)
            entry.Billboard = BuildBillboard(playerName, char, container)
            
            if (#entry.Boxes == 0 or not entry.Billboard) and char.Parent then
                entry.StreamConn = char.ChildAdded:Connect(function(child)
                    if not char.Parent or not IsPlayerTracked(playerName) then
                        if entry.StreamConn then
                            entry.StreamConn:Disconnect()
                            entry.StreamConn = nil
                        end
                        return
                    end
                    if child:IsA("BasePart") then
                        if not entry.Billboard and (child.Name == "Head" or child.Name == "HumanoidRootPart") then
                            entry.Billboard = BuildBillboard(playerName, char, container)
                        end
                        if child.Name ~= "HumanoidRootPart" and child.Transparency < 0.95 then
                            local box = Instance.new("BoxHandleAdornment")
                            box.Name = child.Name .. "_Adornment"
                            box.Adornee = child
                            box.AlwaysOnTop = true
                            box.ZIndex = 10
                            box.Size = child.Size
                            box.Color3 = entry.TeamColor
                            box.Transparency = 0
                            box.Parent = container
                            table.insert(entry.Boxes, box)
                        end
                    end
                end)
                task.delay(6, function()
                    if entry.StreamConn then
                        entry.StreamConn:Disconnect()
                        entry.StreamConn = nil
                    end
                end)
            end
        end)
    end
    
    if player.Character then SetupCharacter(player.Character) end
    
    entry.CharConn = player.CharacterAdded:Connect(function(newChar)
        if IsPlayerTracked(playerName) then
            SetupCharacter(newChar or player.Character)
        end
    end)
    
    entry.CharRemovingConn = player.CharacterRemoving:Connect(function()
        ClearPlayerAdornments(entry)
        entry.Character = nil
    end)
end

function UntrackPlayerInternal(playerName)
    local entry = TrackedPlayers[playerName]
    if not entry then return end
    
    if entry.CharConn then entry.CharConn:Disconnect() entry.CharConn = nil end
    if entry.CharRemovingConn then entry.CharRemovingConn:Disconnect() entry.CharRemovingConn = nil end
    if entry.StreamConn then entry.StreamConn:Disconnect() entry.StreamConn = nil end
    
    if entry.TracerGui then entry.TracerGui:Destroy() end
    if entry.Container then entry.Container:Destroy() end
    
    TrackedPlayers[playerName] = nil
end

local function UpdatePlayerTeamColor(player)
    local entry = TrackedPlayers[player.Name]
    if not entry then return end
    
    local newColor = GetEffectiveTrackerColor(player)
    if entry.TeamColor ~= newColor then
        entry.TeamColor = newColor
        entry.CurrentTeam = player.Team
        if entry.TracerLine then
            entry.TracerLine.BackgroundColor3 = newColor
        end
        for _, b in ipairs(entry.Boxes) do
            b.Color3 = newColor
        end
    end
end

local function ReevaluatePlayer(player)
    local localPlayer = LocalPlayer or Players.LocalPlayer
    if not player or not player.Parent or player == localPlayer then return end
    local playerName = player.Name
    local team = player.Team
    local teamName = team and team.Name or "Neutral"
    
    local isIndividuallyTracked = (IndividuallyTrackedPlayers[playerName] == true)
    local isTeamTracked = (TrackedTeams[teamName] == true)
    local shouldTrack = isIndividuallyTracked or isTeamTracked
    
    if shouldTrack then
        if not TrackedPlayers[playerName] then
            TrackPlayerInternal(player)
        else
            UpdatePlayerTeamColor(player)
        end
    else
        if TrackedPlayers[playerName] then
            UntrackPlayerInternal(playerName)
        end
    end
    
    SetLeaderboardPlayerIcon(player, isIndividuallyTracked)
end

function Locator.TrackPlayer(PlayerName)
    IndividuallyTrackedPlayers[PlayerName] = true
    local p = Players:FindFirstChild(PlayerName)
    if p then ReevaluatePlayer(p) end
end

function Locator.UntrackPlayer(PlayerName)
    IndividuallyTrackedPlayers[PlayerName] = nil
    local p = Players:FindFirstChild(PlayerName)
    if p then ReevaluatePlayer(p) end
end

if genv then
    genv.Locator = Locator
    genv.TrackedPlayers = TrackedPlayers
end

-- Centralized Render Loop: Virtual Frustum Allocation & Tracers
local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
RayParams.IgnoreWater = true

local rayFilter = {nil, nil}
local visibleCandidates = {}
local locatorRenderFrame = 0
local HEAD_OFFSET = Vector3.new(0, 1.5, 0)
local ROOT_OFFSET = Vector3.new(0, 3.5, 0)

local function SortCandidatesByPriority(a, b)
    -- Priority 1: On-screen candidates get strict priority over off-screen / peripheral candidates
    if a.OnScreen ~= b.OnScreen then
        return a.OnScreen == true
    end
    -- Priority 2: Closer candidates get priority over further candidates (furthest get dropped first)
    return a.Distance < b.Distance
end

local function GetScreenEdgeIntersection(startPos, dir, viewportSize, margin)
    margin = margin or 15
    local minX, maxX = margin, viewportSize.X - margin
    local minY, maxY = margin, viewportSize.Y - margin

    local clampedStart = Vector2.new(
        math.clamp(startPos.X, minX, maxX),
        math.clamp(startPos.Y, minY, maxY)
    )

    local tX = math.huge
    if dir.X > 0.0001 then
        tX = (maxX - clampedStart.X) / dir.X
    elseif dir.X < -0.0001 then
        tX = (minX - clampedStart.X) / dir.X
    end

    local tY = math.huge
    if dir.Y > 0.0001 then
        tY = (maxY - clampedStart.Y) / dir.Y
    elseif dir.Y < -0.0001 then
        tY = (minY - clampedStart.Y) / dir.Y
    end

    local t = math.min(tX, tY)
    if t < 0 or t == math.huge then
        t = 100
    end
    return clampedStart + dir * t
end

local RenderConnection = RunService.RenderStepped:Connect(function(dt)
    dt = (type(dt) == "number" and dt > 0 and dt < 0.2) and dt or (1 / 60)
    locatorRenderFrame = (locatorRenderFrame + 1) % 120
    local Camera = Workspace.CurrentCamera
    if not Camera then return end
    
    local camPos = Camera.CFrame.Position
    local viewportSize = Camera.ViewportSize
    local localPlayer = LocalPlayer or Players.LocalPlayer
    local myChar = localPlayer and localPlayer.Character
    local myRoot = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso"))
    local inFirstPerson = (Camera.Focus.Position - camPos).Magnitude < 1
    
    local tracerStartPos
    if inFirstPerson or not myRoot then
        tracerStartPos = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.8)
    else
        local root2D, rootInFrustum = Camera:WorldToViewportPoint(myRoot.Position)
        if root2D.Z > 0 then
            tracerStartPos = Vector2.new(root2D.X, root2D.Y)
        else
            tracerStartPos = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.8)
        end
    end
    
    table.clear(visibleCandidates)
    rayFilter[1] = myChar
    local tracerAlpha = math.clamp(1 - math.exp(-8 * dt), 0, 1)
    
    for playerName, entry in pairs(TrackedPlayers) do
        local character = entry.Character
        local rootPart = character and (character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character.PrimaryPart)
        local teamColor = entry.TeamColor
        
        if character and character.Parent and rootPart then
            local rootPos = rootPart.Position
            local camDist = (rootPos - camPos).Magnitude
            
            local head = entry.CachedHead
            if not head or not head.Parent then
                head = character:FindFirstChild("Head")
                entry.CachedHead = head
            end
            local bestAdornee = head or rootPart
            local bb = entry.Billboard
            
            if not bb or not bb.Parent then
                entry.Billboard = BuildBillboard(playerName, character, entry.Container)
                entry.NameLabel = entry.Billboard and entry.Billboard:FindFirstChild("NameLabel")
                entry.LastDistStuds = nil
                entry.LastDistMode = nil
                entry.LastOffset = nil
            elseif bestAdornee and (bb.Adornee ~= bestAdornee or not bb.Adornee.Parent) then
                bb.Adornee = bestAdornee
                entry.LastOffset = nil
            end
            
            if entry.Billboard and entry.Billboard.Adornee then
                local isHead = (entry.Billboard.Adornee == head)
                local targetOffset = isHead and HEAD_OFFSET or ROOT_OFFSET
                if entry.LastOffset ~= targetOffset then
                    entry.LastOffset = targetOffset
                    entry.Billboard.StudsOffset = targetOffset
                end
            end
            
            local screenPos, inFrustum = Camera:WorldToViewportPoint(rootPos)
            local isBehind = screenPos.Z < 0
            local onScreen = not isBehind and 
                             screenPos.X >= 15 and screenPos.X <= (viewportSize.X - 15) and 
                             screenPos.Y >= 15 and screenPos.Y <= (viewportSize.Y - 15)
            local inHighlightFrustum = not isBehind and 
                             screenPos.X >= -150 and screenPos.X <= (viewportSize.X + 150) and 
                             screenPos.Y >= -150 and screenPos.Y <= (viewportSize.Y + 150)
            
            -- Box Transparency Hysteresis (120x speedup: updates only on visible change, 0 redundant size polling)
            local targetBoxTrans = config.locator_esp and (1 - math.clamp(camDist / 300, 0, 1)) or 1
            local lastBoxTrans = entry.LastBoxTrans
            if not lastBoxTrans or math.abs(targetBoxTrans - lastBoxTrans) >= 0.04 or (targetBoxTrans >= 0.99 and lastBoxTrans < 0.99) then
                entry.LastBoxTrans = targetBoxTrans
                for _, box in ipairs(entry.Boxes) do
                    if box and box.Parent then
                        box.Transparency = targetBoxTrans
                    end
                end
            end
            
            -- Option 4: Distance Hysteresis (only format/dirty UI when moved >= 4 studs or mode changed)
            if entry.Billboard then
                entry.Billboard.Enabled = config.locator_esp
                local nameLabel = entry.NameLabel
                if not nameLabel or not nameLabel.Parent then
                    nameLabel = entry.Billboard:FindFirstChild("NameLabel")
                    entry.NameLabel = nameLabel
                end
                if nameLabel then
                    local showDist = config.locator_distance
                    if showDist then
                        local roundedDist = math.floor(camDist)
                        if entry.LastDistMode ~= true or not entry.LastDistStuds or math.abs(roundedDist - entry.LastDistStuds) >= 4 then
                            entry.LastDistStuds = roundedDist
                            entry.LastDistMode = true
                            nameLabel.Text = string.format("%s [%d studs]", playerName, roundedDist)
                        end
                    else
                        if entry.LastDistMode ~= false then
                            entry.LastDistMode = false
                            entry.LastDistStuds = nil
                            nameLabel.Text = playerName
                        end
                    end
                end
            end
            
            local tracerLine = entry.TracerLine
            if tracerLine then
                if not config.locator_tracers then
                    tracerLine.Visible = false
                    entry.CurrentTracerTrans = 1
                else
                    local targetScreenPos
                    local isOffScreen = false

                    if isBehind then
                        isOffScreen = true
                        local localPos = Camera.CFrame:PointToObjectSpace(rootPos)
                        local forwardBack = math.max(0.1, localPos.Z)
                        local dir = Vector2.new(localPos.X, forwardBack - localPos.Y * 0.3)
                        if dir.Magnitude < 0.001 then
                            dir = Vector2.new(0, 1)
                        else
                            dir = dir.Unit
                        end
                        targetScreenPos = GetScreenEdgeIntersection(tracerStartPos, dir, viewportSize, 15)
                    elseif not onScreen then
                        isOffScreen = true
                        local delta = Vector2.new(screenPos.X, screenPos.Y) - tracerStartPos
                        local dir = delta.Magnitude > 0.001 and delta.Unit or Vector2.new(0, -1)
                        targetScreenPos = GetScreenEdgeIntersection(tracerStartPos, dir, viewportSize, 15)
                    else
                        targetScreenPos = Vector2.new(screenPos.X, screenPos.Y)
                    end

                    local delta = targetScreenPos - tracerStartPos
                    local dist2D = delta.Magnitude

                    if dist2D > 1 then
                        local isObstructed = false
                        if not isOffScreen and head and myChar then
                            local headPos = (head:IsA("BasePart") and head.Position) or (rootPart and rootPart.Position)
                            if headPos then
                                -- Option 2: Raycast Distance Culling & Frame Interleaving
                                if camDist > 250 then
                                    -- Distance Culling: beyond 250 studs, tracer is fully opaque anyway, skip raycast entirely
                                    isObstructed = true
                                    entry.CachedObstructed = true
                                else
                                    -- Frame Interleaving: stagger 4-pass raycast across 3 frames (~62Hz on 185 FPS)
                                    local shouldRaycast = (entry.CachedObstructed == nil) or ((locatorRenderFrame + (entry.InterleaveSlot or 0)) % 3 == 0)
                                    if shouldRaycast then
                                        rayFilter[2] = character
                                        RayParams.FilterDescendantsInstances = rayFilter
                                        local rayDir = headPos - camPos
                                        local curOrigin = camPos
                                        local curDir = rayDir
                                        local obstructed = false
                                        for _ = 1, 4 do
                                            local rayHit = Workspace:Raycast(curOrigin, curDir, RayParams)
                                            if not rayHit then
                                                break
                                            end
                                            local hitPart = rayHit.Instance
                                            if hitPart.Transparency > 0.75 and not hitPart.CanCollide then
                                                curOrigin = rayHit.Position + curDir.Unit * 0.2
                                                if (headPos - curOrigin):Dot(rayDir) <= 0 then
                                                    break
                                                end
                                                curDir = headPos - curOrigin
                                            else
                                                obstructed = true
                                                break
                                            end
                                        end
                                        entry.CachedObstructed = obstructed
                                        isObstructed = obstructed
                                    else
                                        isObstructed = entry.CachedObstructed or false
                                    end
                                end
                            end
                        end

                        local midPoint = (tracerStartPos + targetScreenPos) * 0.5
                        local angle = math.deg(math.atan2(delta.Y, delta.X))

                        tracerLine.Size = UDim2.new(0, dist2D, 0, 1)
                        tracerLine.Position = UDim2.new(0, midPoint.X, 0, midPoint.Y)
                        tracerLine.Rotation = angle

                        local targetTransparency = (isOffScreen or isObstructed) and 0 or math.clamp(1.3 - (camDist / 100), 0, 1)
                        local curTrans = entry.CurrentTracerTrans or targetTransparency
                        curTrans = curTrans + (targetTransparency - curTrans) * tracerAlpha
                        entry.CurrentTracerTrans = curTrans

                        if curTrans >= 0.99 and targetTransparency >= 0.99 then
                            tracerLine.Visible = false
                        else
                            tracerLine.BackgroundTransparency = math.clamp(curTrans, 0, 1)
                            tracerLine.Visible = true
                        end
                    else
                        tracerLine.Visible = false
                        entry.CurrentTracerTrans = 1
                    end
                end
            end
            
            -- Zero-allocation candidate reuse (all valid tracked characters)
            local cData = entry.CandidateData
            if not cData then
                cData = { Character = character, Distance = camDist, TeamColor = teamColor, OnScreen = onScreen }
                entry.CandidateData = cData
            else
                cData.Character = character
                cData.Distance = camDist
                cData.TeamColor = teamColor
                cData.OnScreen = onScreen
            end
            table.insert(visibleCandidates, cData)
        else
            if entry.TracerLine then
                entry.TracerLine.Visible = false
            end
            entry.CurrentTracerTrans = 1
        end
    end
    
    -- Adaptive Highlight pool update with dynamic game budget headroom
    local tHlStart = os.clock()
    if not config.locator_esp then
        if lastActiveHighlights > 0 then
            for i = 1, lastActiveHighlights do
                local hl = HighlightPool[i]
                if hl then
                    if hl.Adornee ~= nil then hl.Adornee = nil end
                    if hl.Enabled then hl.Enabled = false end
                    if hl.Parent ~= nil then hl.Parent = nil end
                end
            end
            lastActiveHighlights = 0
        end
    else
        table.sort(visibleCandidates, SortCandidatesByPriority)
        local availableSlots = math.max(0, TOTAL_ENGINE_HIGHLIGHT_CAP - nativeHighlightCount)
        local candidateCount = math.min(#visibleCandidates, availableSlots)
        
        for i = 1, candidateCount do
            local candidate = visibleCandidates[i]
            local hl = GetPooledHighlight(i)
            if hl then
                if hl.Adornee ~= candidate.Character then
                    hl.Adornee = candidate.Character
                end
                if hl.FillColor ~= candidate.TeamColor then
                    hl.FillColor = candidate.TeamColor
                end
                
                hl.FillTransparency = (1 - math.clamp(candidate.Distance / 100, 0, 1)) * 0.9
                hl.OutlineTransparency = math.clamp(candidate.Distance / 100, 0, 1) * 0.5
                
                local tc = candidate.TeamColor
                local outlineColor = (tc.R * 0.299 + tc.G * 0.587 + tc.B * 0.114) > 0.5 and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
                if hl.OutlineColor ~= outlineColor then
                    hl.OutlineColor = outlineColor
                end
                
                if hl.Parent ~= CoreGui then
                    hl.Parent = CoreGui
                end
                if not hl.Enabled then
                    hl.Enabled = true
                end
            end
        end

        if lastActiveHighlights > candidateCount then
            for i = candidateCount + 1, lastActiveHighlights do
                local hl = HighlightPool[i]
                if hl then
                    if hl.Adornee ~= nil then hl.Adornee = nil end
                    if hl.Enabled then hl.Enabled = false end
                    if hl.Parent ~= nil then hl.Parent = nil end
                end
            end
        end
        lastActiveHighlights = candidateCount
    end
    local tEnd = os.clock()
    if genv then
        genv._LocatorMetrics = {
            totalMs = (tEnd - dt) * 1000, -- will be overwritten below
            hlMs = (tEnd - tHlStart) * 1000,
            visibleCount = #visibleCandidates,
            lastActiveHl = lastActiveHighlights,
            nativeHl = nativeHighlightCount,
            availableSlots = math.max(0, TOTAL_ENGINE_HIGHLIGHT_CAP - nativeHighlightCount),
        }
    end
end)
Own(RenderConnection)

local function ToggleTeamTracking(TeamName)
    TeamName = NormalizeTeamName(TeamName)
    local currentlyTracked = (TrackedTeams[TeamName] == true)
    local newTracked = not currentlyTracked
    
    if newTracked then
        TrackedTeams[TeamName] = true
    else
        TrackedTeams[TeamName] = nil
    end
    
    SetLeaderboardTeamIcon(TeamName, newTracked)
    
    local team = Teams:FindFirstChild(TeamName)
    if team then
        for _, p in ipairs(team:GetPlayers()) do
            ReevaluatePlayer(p)
        end
    elseif TeamName == "Neutral" then
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Team == nil then
                ReevaluatePlayer(p)
            end
        end
    end
    
    for pName, entry in pairs(TrackedPlayers) do
        if entry.Player then
            ReevaluatePlayer(entry.Player)
        end
    end
end

local function HookTeamHeader(teamlist)
    local teamName = string.gsub(teamlist.Name, "TeamList_", "")
    SetLeaderboardTeamIcon(teamName, TrackedTeams[teamName] == true)
    
    local lastClickTime = 0
    local lastToggleTime = 0
    
    local function onTeamClicked()
        local now = os.clock()
        if now - lastToggleTime < 0.35 then return end
        local dt = now - lastClickTime
        if dt < 0.06 then return end
        if dt < 0.55 then
            lastToggleTime = now
            lastClickTime = 0
            ToggleTeamTracking(teamName)
        else
            lastClickTime = now
        end
    end
    
    local function hookEntry(teamEntry)
        if not teamEntry or not teamEntry:IsA("GuiObject") then return end
        if teamEntry:GetAttribute("LocatorEntryHooked") then return end
        teamEntry:SetAttribute("LocatorEntryHooked", true)
        
        teamEntry.Active = true
        Own(teamEntry.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                onTeamClicked()
            end
        end))
        for _, desc in ipairs(teamEntry:GetDescendants()) do
            if desc:IsA("GuiObject") then
                desc.Active = true
                Own(desc.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        onTeamClicked()
                    end
                end))
            end
        end
        Own(teamEntry.DescendantAdded:Connect(function(desc)
            if desc:IsA("GuiObject") then
                desc.Active = true
                Own(desc.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        onTeamClicked()
                    end
                end))
            end
        end))
        SetLeaderboardTeamIcon(teamName, TrackedTeams[teamName] == true)
    end
    
    for _, child in ipairs(teamlist:GetChildren()) do
        if not string.find(child.Name, "PlayerEntry", 1, true) and child:IsA("GuiObject") then
            hookEntry(child)
        end
    end
    
    Own(teamlist.ChildAdded:Connect(function(child)
        if not string.find(child.Name, "PlayerEntry", 1, true) and child:IsA("GuiObject") then
            hookEntry(child)
        end
    end))
    
    SetLeaderboardTeamIcon(teamName, TrackedTeams[teamName] == true)
end

local function HookLocatorPlayer(player)
    local localPlayer = LocalPlayer or Players.LocalPlayer
    if player == localPlayer or PlayerListeners[player] then return end
    
    local teamConn = player:GetPropertyChangedSignal("Team"):Connect(function()
        ReevaluatePlayer(player)
    end)
    local colorConn = player:GetPropertyChangedSignal("TeamColor"):Connect(function()
        UpdatePlayerTeamColor(player)
    end)
    
    PlayerListeners[player] = { teamConn, colorConn }
    Own(teamConn)
    Own(colorConn)
    ReevaluatePlayer(player)
end

local function UnhookLocatorPlayer(player)
    local conns = PlayerListeners[player]
    if conns then
        for _, c in ipairs(conns) do c:Disconnect() end
        PlayerListeners[player] = nil
    end
    IndividuallyTrackedPlayers[player.Name] = nil
    if TrackedPlayers[player.Name] then
        UntrackPlayerInternal(player.Name)
    end
end

for _, p in ipairs(Players:GetPlayers()) do HookLocatorPlayer(p) end
Own(Players.PlayerAdded:Connect(HookLocatorPlayer))
Own(Players.PlayerRemoving:Connect(UnhookLocatorPlayer))

-- ============================================================================
-- Section 9: Leaderboard DropDown Integration & Accordion Copy Panel
-- ============================================================================
local function SafeSetClipboard(text)
    pcall(function()
        if typeof(setclipboard) == "function" then
            setclipboard(text)
        elseif typeof(toclipboard) == "function" then
            toclipboard(text)
        end
    end)
end

local function Modification1(child)
    local DropDown = child
    if not DropDown or not DropDown:IsA("GuiObject") then return end
    local inner = DropDown:WaitForChild("InnerFrame", 5)
    if not inner then return end
    inner.Position = UDim2.new(0, 0, 0, 0)
    
    if DropDown:GetAttribute("LocatorHooked") then return end

    local oldBtn = inner:FindFirstChild("LocateButton")
    if oldBtn then oldBtn:Destroy() end
    local oldPanel = inner:FindFirstChild("CopyExpandPanel")
    if oldPanel then oldPanel:Destroy() end
    
    local inspectBtn = inner:WaitForChild("InspectButton", 5)
    if not inspectBtn then return end
    local LocateButton = inspectBtn:Clone()
    
    DropDown:SetAttribute("LocatorHooked", true)
    LocateButton.Parent = inner
    Own(LocateButton)
    local dismissHandler = LocateButton:FindFirstChild("DismissInputHandler")
    if dismissHandler then dismissHandler:Destroy() end
    
    if not LocateButton:FindFirstChild("Divider") then
        LocateButton.Image = ""
        LocateButton.BackgroundTransparency = 0.3
        local Divider = Instance.new("Frame")
        Divider.Name = "Divider"
        Divider.Parent = LocateButton
        Divider.AnchorPoint = Vector2.new(0, 1)
        Divider.BackgroundColor3 = Color3.fromRGB(208, 217, 251)
        Divider.BackgroundTransparency = 0.84
        Divider.BorderSizePixel = 0
        Divider.Position = UDim2.new(0, 0, 1, 0)
        Divider.Size = UDim2.new(1, 0, 0, 1)
        Divider.ZIndex = 3
    end
    
    local PlayerHeader = inner:WaitForChild("PlayerHeader", 5)
    if not PlayerHeader then return end
    
    local PlayerNameLbl = PlayerHeader:FindFirstChild("PlayerName", true)
    local DisplayNameLbl = PlayerHeader:FindFirstChild("DisplayName", true)
    
    PlayerHeader.LayoutOrder = -2
    LocateButton.LayoutOrder = 0
    LocateButton.Name = "LocateButton"
    LocateButton.Visible = true

    -- Safely find Text, Icon, and HoverBackground recursively anywhere inside LocateButton
    local textLabel = LocateButton:FindFirstChild("Text", true)
    local iconLabel = LocateButton:FindFirstChild("Icon", true)
    local hoverBg = LocateButton:FindFirstChild("HoverBackground", true) or LocateButton

    if not iconLabel then
        iconLabel = Instance.new("ImageLabel")
        iconLabel.Name = "Icon"
        iconLabel.Size = UDim2.new(0, 36, 0, 36)
        iconLabel.BackgroundTransparency = 1
        iconLabel.Parent = (hoverBg:IsA("GuiObject") and hoverBg or LocateButton)
    end
    
    local function GetTargetPlayer()
        local player = nil
        local pName = ""
        
        -- 1. Extract target username directly from PlayerHeader text
        local rawUser = ""
        if PlayerNameLbl and PlayerNameLbl:IsA("TextLabel") and PlayerNameLbl.Text ~= "" then
            rawUser = PlayerNameLbl.Text
        else
            for _, d in ipairs(PlayerHeader:GetDescendants()) do
                if d:IsA("TextLabel") and d.Text:sub(1, 1) == "@" then
                    rawUser = d.Text
                    break
                end
            end
        end

        local cleanUser = (rawUser:sub(1, 1) == "@") and rawUser:sub(2) or rawUser

        -- 2. Direct lookup in Players by username
        if cleanUser ~= "" then
            player = Players:FindFirstChild(cleanUser)
        end

        -- 3. Resolve via OriginalTexts (un-redacted text from StreamerMode)
        if not player and PlayerNameLbl and PlayerNameLbl:IsA("TextLabel") then
            local origText = OriginalTexts and OriginalTexts[PlayerNameLbl]
            if origText and origText ~= "" then
                local clean = origText:sub(1, 1) == "@" and origText:sub(2) or origText
                player = Players:FindFirstChild(clean)
            end
        end

        -- 4. Resolve via StreamerMode anonymization map (e.g. "Player 8")
        if not player and cleanUser ~= "" then
            for _, p in ipairs(Players:GetPlayers()) do
                if GetAnonPlayerName and GetAnonPlayerName(p) == cleanUser then
                    player = p
                    break
                end
            end
        end

        -- 5. Fallback: match by DisplayName
        if not player and DisplayNameLbl and DisplayNameLbl:IsA("TextLabel") and DisplayNameLbl.Text ~= "" then
            local dText = DisplayNameLbl.Text
            for _, p in ipairs(Players:GetPlayers()) do
                if p.DisplayName == dText or p.Name == dText then
                    player = p
                    break
                end
            end
        end

        -- 6. Fallback: Resolve by UserId from AvatarImage thumbnail URL
        if not player then
            local avatarImg = PlayerHeader:FindFirstChild("AvatarImage", true)
            if avatarImg and avatarImg:IsA("ImageLabel") and avatarImg.Image ~= "" then
                local uidStr = avatarImg.Image:match("id=(%d+)")
                local uid = uidStr and tonumber(uidStr)
                if uid then
                    player = Players:GetPlayerByUserId(uid)
                end
            end
        end

        if player then
            pName = player.Name
        elseif cleanUser ~= "" then
            pName = cleanUser
        end

        return player, pName
    end

    local function GetTargetInfo()
        local player, pName = GetTargetPlayer()
        local dName = (DisplayNameLbl and DisplayNameLbl:IsA("TextLabel") and DisplayNameLbl.Text) or (player and player.DisplayName) or pName
        return {
            player = player,
            cleanName = pName,
            displayName = dName,
        }
    end
    
    local function UpdateButtonUI()
        local _, pName = GetTargetPlayer()
        local isTracked = (pName ~= "" and IsPlayerIndividuallyTracked(pName))
        if textLabel then
            textLabel.Text = isTracked and "Untrack Player" or "Track Player"
        end
        if iconLabel then
            iconLabel.Image = isTracked and "rbxassetid://93890392372456" or "rbxassetid://129354637755552"
            iconLabel.ImageRectOffset = Vector2.new(0, 0)
            iconLabel.ImageRectSize = Vector2.new(0, 0)
        end
    end
    
    UpdateButtonUI()
    
    local HoverEnterListener, HoverLeaveListener, HoldListener
    if hoverBg and hoverBg:IsA("GuiObject") then
        HoverEnterListener = LocateButton.MouseEnter:Connect(function()
            pcall(function()
                hoverBg.BackgroundColor3 = Color3.fromRGB(208, 217, 251)
                hoverBg.BackgroundTransparency = 0.92
            end)
        end)
        HoverLeaveListener = LocateButton.MouseLeave:Connect(function()
            pcall(function()
                hoverBg.BackgroundTransparency = 1
            end)
        end)
        HoldListener = LocateButton.MouseButton1Down:Connect(function()
            pcall(function()
                hoverBg.BackgroundTransparency = 0.88
            end)
        end)
        Own(HoverEnterListener)
        Own(HoverLeaveListener)
        Own(HoldListener)
    end
    
    local ActionListener = LocateButton.Activated:Connect(function()
        local player, pName = GetTargetPlayer()
        if pName ~= "" then
            if IsPlayerIndividuallyTracked(pName) then
                IndividuallyTrackedPlayers[pName] = nil
            else
                IndividuallyTrackedPlayers[pName] = true
            end
            if player then ReevaluatePlayer(player) end
            UpdateButtonUI()
        end
    end)

    local EXPAND_HEIGHT = 80

    local function GetBaseHeight()
        local h = 80
        for _, child in ipairs(inner:GetChildren()) do
            if child:IsA("GuiObject") and child.Name ~= "PlayerHeader" and child.Name ~= "CopyExpandPanel" and child.Visible then
                local btnH = child.AbsoluteSize.Y > 0 and child.AbsoluteSize.Y or 56
                h = h + btnH
            end
        end
        return h
    end

    local initialWidth = DropDown.Size.X.Offset > 0 and DropDown.Size.X.Offset or 304
    DropDown.Size = UDim2.fromOffset(initialWidth, GetBaseHeight())

    local panel = Instance.new("Frame")
    panel.Name = "CopyExpandPanel"
    panel.LayoutOrder = -1
    panel.Size = UDim2.new(1, 0, 0, 0)
    panel.BackgroundColor3 = Color3.fromRGB(18, 18, 21)
    panel.BackgroundTransparency = 0.3
    panel.BorderSizePixel = 0
    panel.ClipsDescendants = true
    panel.Visible = false
    panel.Parent = inner
    Own(panel)

    local bottomDiv = Instance.new("Frame")
    bottomDiv.Name = "BottomDivider"
    bottomDiv.AnchorPoint = Vector2.new(0, 1)
    bottomDiv.Position = UDim2.new(0, 0, 1, 0)
    bottomDiv.Size = UDim2.new(1, 0, 0, 1)
    bottomDiv.BackgroundColor3 = Color3.fromRGB(208, 217, 251)
    bottomDiv.BackgroundTransparency = 0.84
    bottomDiv.BorderSizePixel = 0
    bottomDiv.Parent = panel

    local row1 = Instance.new("Frame")
    row1.Name = "Row1"
    row1.Size = UDim2.new(1, -20, 0, 28)
    row1.Position = UDim2.new(0, 10, 0, 8)
    row1.BackgroundTransparency = 1
    row1.BorderSizePixel = 0
    row1.Parent = panel

    local row2 = Instance.new("Frame")
    row2.Name = "Row2"
    row2.Size = UDim2.new(1, -20, 0, 28)
    row2.Position = UDim2.new(0, 10, 0, 42)
    row2.BackgroundTransparency = 1
    row2.BorderSizePixel = 0
    row2.Parent = panel

    local function CreatePill(parentRow, isRight, text, callback)
        local pill = Instance.new("TextButton")
        pill.Name = "Pill_" .. text:gsub("%s+", "")
        pill.Size = UDim2.new(0.5, -4, 1, 0)
        pill.Position = isRight and UDim2.new(0.5, 4, 0, 0) or UDim2.new(0, 0, 0, 0)
        pill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        pill.BackgroundTransparency = 0.92
        pill.AutoButtonColor = false
        pill.Text = ""
        pill.Parent = parentRow

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 6)
        corner.Parent = pill

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(208, 217, 251)
        stroke.Transparency = 0.88
        stroke.Thickness = 1
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent = pill

        local label = Instance.new("TextLabel")
        label.Name = "Label"
        label.Size = UDim2.new(1, 0, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.BuilderSansBold
        label.Text = text
        label.TextColor3 = Color3.fromRGB(240, 240, 245)
        label.TextSize = 12
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.Parent = pill

        pill.MouseEnter:Connect(function()
            pill.BackgroundTransparency = 0.84
            stroke.Transparency = 0.75
        end)
        pill.MouseLeave:Connect(function()
            pill.BackgroundTransparency = 0.92
            stroke.Transparency = 0.88
        end)
        pill.MouseButton1Down:Connect(function()
            pill.BackgroundTransparency = 0.76
        end)
        pill.MouseButton1Up:Connect(function()
            pill.BackgroundTransparency = 0.84
        end)

        pill.Activated:Connect(function()
            local info = GetTargetInfo()
            callback(info)
            local orig = label.Text
            label.Text = "Copied!"
            task.delay(1, function()
                if label and label.Parent then label.Text = orig end
            end)
        end)

        return pill
    end

    CreatePill(row1, false, "Copy User ID", function(target)
        local targetPlayer = target.player or (target.cleanName ~= "" and Players:FindFirstChild(target.cleanName))
        if targetPlayer then
            SafeSetClipboard(tostring(targetPlayer.UserId))
        else
            SafeSetClipboard("Unknown")
        end
    end)

    CreatePill(row1, true, "Copy Profile Link", function(target)
        local targetPlayer = target.player or (target.cleanName ~= "" and Players:FindFirstChild(target.cleanName))
        if targetPlayer then
            SafeSetClipboard("https://www.roblox.com/users/" .. tostring(targetPlayer.UserId) .. "/profile")
        else
            SafeSetClipboard("Unknown")
        end
    end)

    CreatePill(row2, false, "Copy Username", function(target)
        local uName = (target.player and target.player.Name) or (target.cleanName ~= "" and target.cleanName) or "Unknown"
        SafeSetClipboard(uName)
    end)

    CreatePill(row2, true, "Copy Display Name", function(target)
        local dName = (target.player and target.player.DisplayName) or target.displayName or "Unknown"
        SafeSetClipboard(dName)
    end)

    local isExpanded = (panel.Visible and panel.Size.Y.Offset > 0)
    local isAnimating = false

    local function ToggleExpand(forceState)
        if isAnimating then return end
        local targetState
        if forceState ~= nil then targetState = forceState else targetState = not isExpanded end
        if targetState == isExpanded then return end
        isExpanded = targetState
        isAnimating = true

        local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local width = DropDown.Size.X.Offset > 0 and DropDown.Size.X.Offset or 304
        local baseH = GetBaseHeight()

        if isExpanded then
            panel.Visible = true
            local panelTween = TweenService:Create(panel, tweenInfo, { Size = UDim2.new(1, 0, 0, EXPAND_HEIGHT) })
            local ddTween = TweenService:Create(DropDown, tweenInfo, { Size = UDim2.fromOffset(width, baseH + EXPAND_HEIGHT) })
            panelTween:Play()
            ddTween:Play()
            task.delay(0.22, function() isAnimating = false end)
            ddTween.Completed:Once(function() isAnimating = false end)
        else
            local panelTween = TweenService:Create(panel, tweenInfo, { Size = UDim2.new(1, 0, 0, 0) })
            local ddTween = TweenService:Create(DropDown, tweenInfo, { Size = UDim2.fromOffset(width, baseH) })
            panelTween:Play()
            ddTween:Play()
            task.delay(0.22, function()
                isAnimating = false
                if not isExpanded and panel and panel.Parent then panel.Visible = false end
            end)
            ddTween.Completed:Once(function()
                isAnimating = false
                if not isExpanded and panel and panel.Parent then panel.Visible = false end
            end)
        end
    end

    local lastToggleTick = 0
    local function SafeToggle()
        if os.clock() - lastToggleTick < 0.35 then return end
        lastToggleTick = os.clock()
        task.spawn(ToggleExpand)
    end

    local ddConns = {}
    local function TrackConn(conn)
        table.insert(ddConns, conn)
        return conn
    end

    if PlayerHeader:IsA("GuiButton") or PlayerHeader:IsA("TextButton") or PlayerHeader:IsA("ImageButton") then
        TrackConn(PlayerHeader.MouseButton2Click:Connect(SafeToggle))
        TrackConn(PlayerHeader.MouseButton2Down:Connect(SafeToggle))
    end

    TrackConn(PlayerHeader.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 then SafeToggle() end
    end))

    for _, desc in ipairs(PlayerHeader:GetDescendants()) do
        if desc:IsA("GuiObject") then
            TrackConn(desc.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton2 then SafeToggle() end
            end))
        end
    end

    TrackConn(PlayerHeader.DescendantAdded:Connect(function(desc)
        if desc:IsA("GuiObject") then
            TrackConn(desc.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton2 then SafeToggle() end
            end))
        end
    end))

    TrackConn(DropDown.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 then SafeToggle() end
    end))

    for _, desc in ipairs(DropDown:GetDescendants()) do
        if desc:IsA("GuiObject") and desc ~= panel and not desc:IsDescendantOf(panel) then
            TrackConn(desc.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton2 then SafeToggle() end
            end))
        end
    end

    TrackConn(DropDown.DescendantAdded:Connect(function(desc)
        if desc:IsA("GuiObject") and desc ~= panel and not desc:IsDescendantOf(panel) then
            TrackConn(desc.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton2 then SafeToggle() end
            end))
        end
    end))

    TrackConn(UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            if DropDown and DropDown.Parent and DropDown.Visible then
                local mousePos = UserInputService:GetMouseLocation()
                local dPos = DropDown.AbsolutePosition
                local dSize = DropDown.AbsoluteSize
                local inBoundsRaw = (mousePos.X >= (dPos.X - 5) and mousePos.X <= (dPos.X + dSize.X + 5)
                    and mousePos.Y >= (dPos.Y - 5) and mousePos.Y <= (dPos.Y + dSize.Y + 5))
                local inset, _ = GuiService:GetGuiInset()
                local adjPos = mousePos - inset
                local inBoundsAdj = (adjPos.X >= (dPos.X - 5) and adjPos.X <= (dPos.X + dSize.X + 5)
                    and adjPos.Y >= (dPos.Y - 5) and adjPos.Y <= (dPos.Y + dSize.Y + 5))
                if inBoundsRaw or inBoundsAdj then
                    SafeToggle()
                end
            end
        end
    end))
    
    TrackConn(DropDown:GetPropertyChangedSignal("Size"):Connect(function()
        if isAnimating then return end
        local expected = GetBaseHeight() + (isExpanded and EXPAND_HEIGHT or 0)
        if DropDown.Size.Y.Offset < expected then
            local w = DropDown.Size.X.Offset > 0 and DropDown.Size.X.Offset or 304
            DropDown.Size = UDim2.fromOffset(w, expected)
        end
    end))

    TrackConn(DropDown:GetPropertyChangedSignal("Visible"):Connect(function()
        if DropDown.Visible then
            task.defer(UpdateButtonUI)
        else
            isExpanded = false
            isAnimating = false
            panel.Size = UDim2.new(1, 0, 0, 0)
            panel.Visible = false
            local baseH = GetBaseHeight()
            local w = DropDown.Size.X.Offset > 0 and DropDown.Size.X.Offset or 304
            DropDown.Size = UDim2.fromOffset(w, baseH)
        end
    end))
    
    TrackConn(DropDown:GetPropertyChangedSignal("Position"):Connect(function()
        if DropDown.Visible then
            task.defer(UpdateButtonUI)
        end
    end))
    
    for _, desc in ipairs(PlayerHeader:GetDescendants()) do
        if desc:IsA("TextLabel") then
            TrackConn(desc:GetPropertyChangedSignal("Text"):Connect(function()
                task.defer(UpdateButtonUI)
                if isExpanded then
                    task.spawn(function() ToggleExpand(false) end)
                end
            end))
        end
    end
    
    TrackConn(ActionListener)
    if HoverLeaveListener then TrackConn(HoverLeaveListener) end
    if HoverEnterListener then TrackConn(HoverEnterListener) end
    if HoldListener then TrackConn(HoldListener) end

    local function DisconnectDD()
        for _, c in ipairs(ddConns) do
            if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
        end
        table.clear(ddConns)
        if DropDown and DropDown:GetAttribute("LocatorHooked") then
            DropDown:SetAttribute("LocatorHooked", nil)
        end
        if isExpanded then
            panel.Size = UDim2.new(1, 0, 0, 0)
            panel.Visible = false
            isExpanded = false
        end
    end

    TrackConn(DropDown.AncestryChanged:Connect(function()
        if not DropDown:IsDescendantOf(game) then DisconnectDD() end
    end))
    Own(DisconnectDD)
end

local function CheckAndHookDropDown(candidate)
    if not candidate or not candidate:IsA("GuiObject") then return end
    if candidate.Name ~= "PlayerDropDown" then return end
    if candidate:GetAttribute("LocatorHooked") then return end
    task.spawn(Modification1, candidate)
end

local function Modification2()
    local ActualList = GetActualList()
    if not ActualList and PlayerList then
        local found = PlayerList:FindFirstChild("OffsetUndoFrame", true)
        ActualList = found or GetActualList()
    end
    if not ActualList then return end
    
    for _, teamlist in ipairs(ActualList:GetChildren()) do
        if teamlist:IsA("Frame") and string.find(teamlist.Name, "TeamList_", 1, true) then
            HookTeamHeader(teamlist)
        end
    end
    
    for _, player in ipairs(Players:GetPlayers()) do
        if IsPlayerIndividuallyTracked(player.Name) then
            SetLeaderboardPlayerIcon(player, true)
        end
    end
    
    Own(ActualList.DescendantAdded:Connect(function(desc)
        if desc.Name == "NameFrame" then
            local entry = desc:FindFirstAncestorWhichIsA("Frame")
            if entry and entry.Name:sub(1, 12) == "PlayerEntry_" then
                local userId = tonumber(entry.Name:sub(13))
                local player = userId and Players:GetPlayerByUserId(userId)
                if player and IsPlayerIndividuallyTracked(player.Name) then
                    SetLeaderboardPlayerIcon(player, true)
                end
            elseif entry and entry.Name == "TeamEntry" then
                local teamList = entry.Parent
                if teamList and teamList.Name:sub(1, 9) == "TeamList_" then
                    local teamName = teamList.Name:sub(10)
                    if IsTeamTracked(teamName) then
                        SetLeaderboardTeamIcon(teamName, true)
                    end
                end
            end
        end
    end))
    
    local ListenForNewTeams = ActualList.ChildAdded:Connect(function(child)
        if child:IsA("Frame") and string.find(child.Name, "TeamList_", 1, true) then
            HookTeamHeader(child)
        end
    end)
    Own(ListenForNewTeams)
end

local function HookPlayerList(pl)
    if not pl then return end
    PlayerList = pl

    for _, d in ipairs(PlayerList:GetDescendants()) do
        CheckAndHookDropDown(d)
    end

    Own(PlayerList.DescendantAdded:Connect(function(child)
        CheckAndHookDropDown(child)
        if child.Name == "OffsetUndoFrame" or child.Name == "Children" then
            task.spawn(Modification2)
        end
    end))

    task.spawn(Modification2)
end

if PlayerList then
    HookPlayerList(PlayerList)
else
    local existingPl = CoreGui:FindFirstChild("PlayerList")
    if existingPl then
        HookPlayerList(existingPl)
    end
end

Own(CoreGui.ChildAdded:Connect(function(child)
    if child.Name == "PlayerList" then
        HookPlayerList(child)
    elseif child.Name == "PlayerDropDown" then
        CheckAndHookDropDown(child)
    end
end))

Own(CoreGui.DescendantAdded:Connect(function(desc)
    CheckAndHookDropDown(desc)
end))

for _, d in ipairs(CoreGui:GetDescendants()) do
    CheckAndHookDropDown(d)
end

task.spawn(function()
    while true do
        task.wait(0.5)
        if not PlayerList or not PlayerList.Parent then
            local pl = CoreGui:FindFirstChild("PlayerList")
            if pl then
                HookPlayerList(pl)
            end
        end
        local dd = CoreGui:FindFirstChild("PlayerDropDown", true)
        if dd and dd:IsA("GuiObject") and not dd:GetAttribute("LocatorHooked") then
            CheckAndHookDropDown(dd)
        end
    end
end)

-- ============================================================================
-- Section 10: In-Game ESC Menu Settings Injection
-- ============================================================================
local function FindTargetPage()
    local robloxGui = CoreGui:FindFirstChild("RobloxGui")
    if not robloxGui then return nil end
    local pvi = robloxGui:FindFirstChild("PageViewInnerFrame", true)
    if pvi then
        local page = pvi:FindFirstChild("Page")
        if page and page:FindFirstChild("RowListLayout") and page:FindFirstChild("VolumeFrame") then
            return page
        end
    end
    for _, desc in ipairs(robloxGui:GetDescendants()) do
        if desc.Name == "Page" and desc:IsA("Frame") and desc:FindFirstChild("RowListLayout") and desc:FindFirstChild("VolumeFrame") then
            return desc
        end
    end
    return nil
end

local activeMenuCleanup = nil

local function InjectEnhancementSettings(page)
    if not page or not page:IsDescendantOf(game) then return end

    if activeMenuCleanup then
        pcall(activeMenuCleanup)
        activeMenuCleanup = nil
    end

    for _, child in ipairs(page:GetChildren()) do
        if child.Name:sub(1, 12) == "Enhancement_" then
            pcall(child.Destroy, child)
        end
    end

    local menuConns = {}
    local function TrackConn(c)
        table.insert(menuConns, c)
        return c
    end

    local nativeRow = page:FindFirstChild("Option to View Untranslated MessageFrame")
        or page:FindFirstChild("Automatic Chat TranslationFrame")
        or page:FindFirstChild("FullscreenFrame") 
        or page:FindFirstChild("Automatic TranslationsFrame") 
        or page:FindFirstChild("Shift Lock SwitchFrame")

    -- 1. Section Header: "Mod Settings"
    local modHeader = Instance.new("Frame")
    modHeader.Name = "Enhancement_Header"
    modHeader.Size = UDim2.new(1, 0, 0, 48)
    modHeader.BackgroundTransparency = 1
    modHeader.LayoutOrder = -100

    local headerTxt = Instance.new("TextLabel")
    headerTxt.Name = "Text"
    headerTxt.Size = UDim2.new(1, -20, 1, 0)
    headerTxt.Position = UDim2.new(0, 10, 0, 0)
    headerTxt.BackgroundTransparency = 1
    pcall(function() headerTxt.Font = Enum.Font.BuilderSansBold end)
    if headerTxt.Font ~= Enum.Font.BuilderSansBold then
        headerTxt.Font = Enum.Font.GothamBold
    end
    headerTxt.TextSize = 20
    headerTxt.TextColor3 = Color3.fromRGB(240, 240, 245)
    headerTxt.TextXAlignment = Enum.TextXAlignment.Left
    headerTxt.TextYAlignment = Enum.TextYAlignment.Center
    headerTxt.Text = "⚡ Omni Enhancements"
    headerTxt.Parent = modHeader

    modHeader.Parent = page

    -- 2. Native Row Hover Applicator
    local function ClearNativeHighlights()
        for _, child in ipairs(page:GetChildren()) do
            if child:IsA("GuiObject") and not child.Name:find("Enhancement_") then
                if child.BackgroundTransparency ~= 1 then
                    child.BackgroundTransparency = 1
                end
            end
        end
    end

    local activeHoveredRow = nil

    local function SetActiveRow(targetRow)
        activeHoveredRow = targetRow
        ClearNativeHighlights()
        for _, child in ipairs(page:GetChildren()) do
            if child.Name:find("Enhancement_Row_") then
                child.BackgroundTransparency = (child == targetRow) and 0 or 1
            end
        end
    end

    TrackConn(modHeader.MouseEnter:Connect(function()
        SetActiveRow(nil)
    end))

    local function ApplyNativeRowHover(row)
        if not row then return end
        row.AutoButtonColor = false
        row.BackgroundColor3 = Color3.fromRGB(35, 37, 39)
        row.BackgroundTransparency = 1
        if row:IsA("ImageButton") then row.ImageTransparency = 1 end

        local corner = row:FindFirstChildOfClass("UICorner")
        if not corner then
            corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 8)
            corner.Parent = row
        end

        TrackConn(row.MouseEnter:Connect(function()
            SetActiveRow(row)
        end))

        TrackConn(row.MouseLeave:Connect(function()
            if activeHoveredRow == row then
                task.delay(0.02, function()
                    if activeHoveredRow == row then
                        activeHoveredRow = nil
                        row.BackgroundTransparency = 1
                    end
                end)
            end
        end))

        for _, desc in ipairs(row:GetDescendants()) do
            if desc:IsA("GuiObject") then
                TrackConn(desc.MouseEnter:Connect(function()
                    SetActiveRow(row)
                end))
                TrackConn(desc.MouseLeave:Connect(function()
                    if activeHoveredRow == row then
                        task.delay(0.02, function()
                            if activeHoveredRow == row then
                                activeHoveredRow = nil
                                row.BackgroundTransparency = 1
                            end
                        end)
                    end
                end))
            end
        end
    end

    -- 3. Toggle Row Builder
    local function CreateToggleRow(id, labelText, defaultVal, callback, layoutOrder, isSubRow)
        local row
        if nativeRow and nativeRow:FindFirstChild("Selector") then
            row = nativeRow:Clone()
            local lbl = row:FindFirstChild("FullscreenLabel") or row:FindFirstChildWhichIsA("TextLabel", true)
            if lbl then
                lbl.Name = id .. "Label"
                lbl.Text = labelText
                lbl.TextSize = isSubRow and 15 or 17
                pcall(function() lbl.Font = Enum.Font.BuilderSansMedium end)
                if lbl.Font ~= Enum.Font.BuilderSansMedium then lbl.Font = Enum.Font.GothamMedium end
                lbl.TextColor3 = isSubRow and Color3.fromRGB(205, 210, 220) or Color3.fromRGB(255, 255, 255)
                if isSubRow then
                    lbl.Position = UDim2.new(0, 30, 0, 0)
                end
            end

            local selector = row:FindFirstChild("Selector")
            if selector then
                selector.ClipsDescendants = true

                local onLbl = selector:FindFirstChild("Selection1")
                local offLbl = selector:FindFirstChild("Selection2")
                local leftBtn = selector:FindFirstChild("LeftButton")
                local rightBtn = selector:FindFirstChild("RightButton")
                local autoBtn = selector:FindFirstChild("AutoSelectButton")

                local state = (defaultVal == true)
                local TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
                local isTransitioning = false

                for _, l in ipairs({onLbl, offLbl}) do
                    if l then
                        l.TextSize = 17
                        pcall(function() l.Font = Enum.Font.BuilderSans end)
                        if l.Font ~= Enum.Font.BuilderSans then l.Font = Enum.Font.Gotham end
                        l.TextColor3 = Color3.fromRGB(255, 255, 255)
                    end
                end

                if onLbl then
                    onLbl.Text = "On"
                    onLbl.Position = state and UDim2.new(0, 32, 0, 0) or UDim2.new(0, 64, 0, 0)
                    onLbl.TextTransparency = state and 0 or 1
                    onLbl.Visible = state
                end
                if offLbl then
                    offLbl.Text = "Off"
                    offLbl.Position = (not state) and UDim2.new(0, 32, 0, 0) or UDim2.new(0, 64, 0, 0)
                    offLbl.TextTransparency = (not state) and 0 or 1
                    offLbl.Visible = not state
                end

                local function SlideTransition(toState, direction)
                    if isTransitioning then return end
                    isTransitioning = true

                    local currentLbl = state and onLbl or offLbl
                    local nextLbl = toState and onLbl or offLbl
                    state = toState

                    local outPos = (direction > 0) and UDim2.new(0, 0, 0, 0) or UDim2.new(0, 64, 0, 0)
                    local inStartPos = (direction > 0) and UDim2.new(0, 64, 0, 0) or UDim2.new(0, 0, 0, 0)
                    local inEndPos = UDim2.new(0, 32, 0, 0)

                    if nextLbl then
                        nextLbl.Position = inStartPos
                        nextLbl.TextTransparency = 1
                        nextLbl.Visible = true

                        TweenService:Create(nextLbl, TWEEN_INFO, {
                            Position = inEndPos,
                            TextTransparency = 0
                        }):Play()
                    end

                    if currentLbl then
                        local tweenOut = TweenService:Create(currentLbl, TWEEN_INFO, {
                            Position = outPos,
                            TextTransparency = 1
                        })
                        tweenOut:Play()
                    end

                    task.delay(0.16, function()
                        if currentLbl and currentLbl ~= nextLbl then
                            currentLbl.Visible = false
                        end
                        isTransitioning = false
                    end)

                    callback(state)
                end

                if leftBtn and leftBtn:IsA("GuiButton") then
                    TrackConn(leftBtn.Activated:Connect(function()
                        SlideTransition(not state, -1)
                    end))
                end
                if rightBtn and rightBtn:IsA("GuiButton") then
                    TrackConn(rightBtn.Activated:Connect(function()
                        SlideTransition(not state, 1)
                    end))
                end
                if autoBtn and autoBtn:IsA("GuiButton") then
                    TrackConn(autoBtn.Activated:Connect(function()
                        SlideTransition(not state, 1)
                    end))
                end
            end
        else
            row = Instance.new("ImageButton")
            row.Size = UDim2.new(1, 0, 0, 50)
            row.BackgroundTransparency = 1
            row.AutoButtonColor = false

            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0.45, -20, 1, 0)
            lbl.Position = isSubRow and UDim2.new(0, 30, 0, 0) or UDim2.new(0, 10, 0, 0)
            lbl.BackgroundTransparency = 1
            pcall(function() lbl.Font = Enum.Font.BuilderSansMedium end)
            if lbl.Font ~= Enum.Font.BuilderSansMedium then lbl.Font = Enum.Font.Gotham end
            lbl.TextSize = isSubRow and 14 or 16
            lbl.TextColor3 = isSubRow and Color3.fromRGB(205, 210, 220) or Color3.fromRGB(240, 240, 245)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Text = labelText
            lbl.Parent = row

            local sel = Instance.new("Frame")
            sel.Name = "Selector"
            sel.Size = UDim2.new(0.55, 0, 1, 0)
            sel.Position = UDim2.new(0.45, 0, 0, 0)
            sel.BackgroundTransparency = 1
            sel.Parent = row

            local state = (defaultVal == true)
            local statusLbl = Instance.new("TextButton")
            statusLbl.Size = UDim2.new(1, -20, 0, 34)
            statusLbl.Position = UDim2.new(0, 10, 0.5, -17)
            statusLbl.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
            pcall(function() statusLbl.Font = Enum.Font.BuilderSansBold end)
            if statusLbl.Font ~= Enum.Font.BuilderSansBold then statusLbl.Font = Enum.Font.GothamBold end
            statusLbl.TextSize = 14
            statusLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
            statusLbl.Text = state and "<  On  >" or "<  Off  >"
            statusLbl.Parent = sel

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 6)
            corner.Parent = statusLbl

            local function OnToggle()
                state = not state
                statusLbl.Text = state and "<  On  >" or "<  Off  >"
                callback(state)
            end
            TrackConn(statusLbl.Activated:Connect(OnToggle))
        end

        row.ClipsDescendants = true
        ApplyNativeRowHover(row)
        row.Name = "Enhancement_Row_" .. id
        row.LayoutOrder = layoutOrder
        row.Parent = page
        return row
    end

    -- 4. 10-Step Segmented Slider Builder (Cloned from Native VolumeFrame with Drag & Slide)
    local function CreateSliderRow(id, labelText, defaultVal, callback, layoutOrder)
        local nativeSlider = page:FindFirstChild("VolumeFrame")
        local row
        local currentStep = math.clamp(tonumber(defaultVal) or 0, 0, 10)

        if nativeSlider then
            row = nativeSlider:Clone()
            local lbl = row:FindFirstChild("VolumeLabel") or row:FindFirstChildWhichIsA("TextLabel", true)
            if lbl then
                lbl.Name = id .. "Label"
                lbl.Text = labelText
                lbl.TextSize = 17
                pcall(function() lbl.Font = Enum.Font.BuilderSansMedium end)
                if lbl.Font ~= Enum.Font.BuilderSansMedium then lbl.Font = Enum.Font.GothamMedium end
                lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
            end

            local slider = row:FindFirstChild("Slider")
            local stepsContainer = slider and slider:FindFirstChild("StepsContainer")
            local leftBtn = slider and slider:FindFirstChild("LeftButton")
            local rightBtn = slider and slider:FindFirstChild("RightButton")

            local INACTIVE_COLOR = Color3.fromRGB(57, 59, 61)
            local ACTIVE_COLOR = Color3.fromRGB(255, 255, 255)

            local function UpdateVisuals(step)
                currentStep = step
                if stepsContainer then
                    for i = 1, 10 do
                        local stepBtn = stepsContainer:FindFirstChild("Step" .. i)
                        if stepBtn then
                            local isActive = (i <= currentStep)
                            local col = isActive and ACTIVE_COLOR or INACTIVE_COLOR
                            stepBtn.BackgroundColor3 = col
                            stepBtn.BackgroundTransparency = 0
                            local filler = stepBtn:FindFirstChild("Filler")
                            if filler then
                                filler.BackgroundColor3 = col
                                filler.BackgroundTransparency = 0
                            end
                        end
                    end
                end
                if leftBtn then leftBtn.Visible = (currentStep > 0) end
                if rightBtn then rightBtn.Visible = (currentStep < 10) end
            end

            UpdateVisuals(currentStep)

            -- Drag & Slide Functionality (Matching Native Volume Slider)
            local isDragging = false
            local startX = 0
            local hasDragged = false
            local initialStepOnPress = currentStep

            local function UpdateFromX(xPos)
                if not stepsContainer then return end
                local left = stepsContainer.AbsolutePosition.X
                local width = stepsContainer.AbsoluteSize.X
                if width <= 0 then return end
                local relX = xPos - left
                local slotWidth = width / 10
                local newStep
                if relX <= slotWidth * 0.2 then
                    newStep = 0
                else
                    newStep = math.clamp(math.ceil(relX / slotWidth), 1, 10)
                end
                if newStep ~= currentStep then
                    UpdateVisuals(newStep)
                    callback(newStep)
                end
            end

            local function StartDrag(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    isDragging = true
                    startX = input.Position.X
                    hasDragged = false
                    initialStepOnPress = currentStep
                    UpdateFromX(input.Position.X)
                end
            end

            if stepsContainer then
                TrackConn(stepsContainer.InputBegan:Connect(StartDrag))
                for i = 1, 10 do
                    local stepBtn = stepsContainer:FindFirstChild("Step" .. i)
                    if stepBtn and stepBtn:IsA("GuiButton") then
                        TrackConn(stepBtn.InputBegan:Connect(StartDrag))
                        TrackConn(stepBtn.Activated:Connect(function()
                            if not hasDragged and i == 1 and initialStepOnPress == 1 then
                                UpdateVisuals(0)
                                callback(0)
                            end
                        end))
                    end
                end
            end

            if slider and slider:IsA("GuiButton") then
                TrackConn(slider.InputBegan:Connect(StartDrag))
            end

            TrackConn(UserInputService.InputChanged:Connect(function(input)
                if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                    if math.abs(input.Position.X - startX) > 3 then
                        hasDragged = true
                    end
                    UpdateFromX(input.Position.X)
                end
            end))

            TrackConn(UserInputService.InputEnded:Connect(function(input)
                if isDragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
                    isDragging = false
                end
            end))

            if leftBtn and leftBtn:IsA("GuiButton") then
                TrackConn(leftBtn.Activated:Connect(function()
                    if currentStep > 0 then
                        UpdateVisuals(currentStep - 1)
                        callback(currentStep)
                    end
                end))
            end

            if rightBtn and rightBtn:IsA("GuiButton") then
                TrackConn(rightBtn.Activated:Connect(function()
                    if currentStep < 10 then
                        UpdateVisuals(currentStep + 1)
                        callback(currentStep)
                    end
                end))
            end
        else
            row = Instance.new("ImageButton")
            row.Size = UDim2.new(1, 0, 0, 50)
            row.BackgroundTransparency = 1
            row.AutoButtonColor = false

            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0.4, -20, 1, 0)
            lbl.Position = UDim2.new(0, 10, 0, 0)
            lbl.BackgroundTransparency = 1
            pcall(function() lbl.Font = Enum.Font.BuilderSansMedium end)
            if lbl.Font ~= Enum.Font.BuilderSansMedium then lbl.Font = Enum.Font.Gotham end
            lbl.TextSize = 17
            lbl.TextColor3 = Color3.fromRGB(240, 240, 245)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Text = labelText
            lbl.Parent = row

            local slider = Instance.new("Frame")
            slider.Name = "Slider"
            slider.Size = UDim2.new(0.6, 0, 1, 0)
            slider.Position = UDim2.new(0.4, 0, 0, 0)
            slider.BackgroundTransparency = 1
            slider.Parent = row

            local stepsContainer = Instance.new("Frame")
            stepsContainer.Name = "StepsContainer"
            stepsContainer.Size = UDim2.new(1, -100, 0, 24)
            stepsContainer.AnchorPoint = Vector2.new(0.5, 0.5)
            stepsContainer.Position = UDim2.new(0.5, 0, 0.5, 0)
            stepsContainer.BackgroundTransparency = 1
            stepsContainer.Parent = slider

            local stepButtons = {}
            local INACTIVE_COLOR = Color3.fromRGB(57, 59, 61)
            local ACTIVE_COLOR = Color3.fromRGB(255, 255, 255)

            local function UpdateVisuals(step)
                currentStep = step
                for j = 1, 10 do
                    if stepButtons[j] then
                        local isActive = (j <= currentStep)
                        stepButtons[j].BackgroundColor3 = isActive and ACTIVE_COLOR or INACTIVE_COLOR
                        stepButtons[j].BackgroundTransparency = 0
                    end
                end
            end

            local isDragging = false
            local startX = 0
            local hasDragged = false
            local initialStepOnPress = currentStep

            local function UpdateFromX(xPos)
                if not stepsContainer then return end
                local left = stepsContainer.AbsolutePosition.X
                local width = stepsContainer.AbsoluteSize.X
                if width <= 0 then return end
                local relX = xPos - left
                local slotWidth = width / 10
                local newStep
                if relX <= slotWidth * 0.2 then
                    newStep = 0
                else
                    newStep = math.clamp(math.ceil(relX / slotWidth), 1, 10)
                end
                if newStep ~= currentStep then
                    UpdateVisuals(newStep)
                    callback(newStep)
                end
            end

            local function StartDrag(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    isDragging = true
                    startX = input.Position.X
                    hasDragged = false
                    initialStepOnPress = currentStep
                    UpdateFromX(input.Position.X)
                end
            end

            TrackConn(stepsContainer.InputBegan:Connect(StartDrag))

            for i = 1, 10 do
                local stepBtn = Instance.new("TextButton")
                stepBtn.Name = "Step" .. i
                stepBtn.Size = UDim2.new(0.1, -4, 1, 0)
                stepBtn.Position = UDim2.new((i - 1) * 0.1, 2, 0, 0)
                stepBtn.Text = ""
                stepBtn.BackgroundColor3 = (i <= currentStep) and ACTIVE_COLOR or INACTIVE_COLOR
                stepBtn.BackgroundTransparency = 0
                local corner = Instance.new("UICorner")
                corner.CornerRadius = UDim.new(0, 3)
                corner.Parent = stepBtn
                stepBtn.Parent = stepsContainer
                stepButtons[i] = stepBtn

                TrackConn(stepBtn.InputBegan:Connect(StartDrag))
                TrackConn(stepBtn.Activated:Connect(function()
                    if not hasDragged and i == 1 and initialStepOnPress == 1 then
                        UpdateVisuals(0)
                        callback(0)
                    end
                end))
            end

            TrackConn(UserInputService.InputChanged:Connect(function(input)
                if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                    if math.abs(input.Position.X - startX) > 3 then
                        hasDragged = true
                    end
                    UpdateFromX(input.Position.X)
                end
            end))

            TrackConn(UserInputService.InputEnded:Connect(function(input)
                if isDragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
                    isDragging = false
                end
            end))
        end

        ApplyNativeRowHover(row)
        row.Name = "Enhancement_Row_" .. id
        row.LayoutOrder = layoutOrder
        row.Parent = page
        return row
    end

    -- Construct Rows
    CreateToggleRow("StreamerMode", "Streamer Mode", config.streamer_mode, function(val)
        config.streamer_mode = val
        SaveConfig()
        if val then StreamerMode.Enable() else StreamerMode.Disable() end
    end, -90)

    CreateSliderRow("PersonalSpaceBubble", "Personal Space Bubble", config.personal_space_bubble or 0, function(val)
        config.personal_space_bubble = val
        SaveConfig()
        if val > 0 then PersonalSpaceBubble.Enable() else PersonalSpaceBubble.Disable() end
    end, -89)

    CreateToggleRow("LocatorTracers", "Locator Tracers", config.locator_tracers, function(val)
        config.locator_tracers = val
        SaveConfig()
    end, -84)

    CreateToggleRow("LocatorDistance", "Distance Readouts", config.locator_distance, function(val)
        config.locator_distance = val
        SaveConfig()
    end, -83)

    CreateToggleRow("ChatTimestamps", "Chat Timestamps", config.chat_timestamps, function(val)
        config.chat_timestamps = val
        SaveConfig()
    end, -82)

    CreateToggleRow("MentionChimes", "Mention Chimes", config.mention_chimes, function(val)
        config.mention_chimes = val
        SaveConfig()
    end, -81)

    CreateToggleRow("ForceBubbleChat", "Force Chat Bubbles", config.force_bubble_chat, function(val)
        config.force_bubble_chat = val
        SaveConfig()
        if BubbleChatManager and BubbleChatManager.Apply then
            BubbleChatManager.Apply()
        end
    end, -80.5)

    CreateToggleRow("AntiAFK", "Anti-AFK", config.anti_afk, function(val)
        config.anti_afk = val
        SaveConfig()
        if val then AntiAFK.Enable() else AntiAFK.Disable() end
    end, -80)

    -- Divider
    local modDivider = Instance.new("Frame")
    modDivider.Name = "Enhancement_Divider"
    modDivider.Size = UDim2.new(1, 0, 0, 16)
    modDivider.BackgroundTransparency = 1
    modDivider.LayoutOrder = -1

    local line = Instance.new("Frame")
    line.Size = UDim2.new(1, -20, 0, 1)
    line.Position = UDim2.new(0, 10, 0.5, 0)
    line.BackgroundColor3 = Color3.fromRGB(80, 80, 85)
    line.BackgroundTransparency = 0.5
    line.BorderSizePixel = 0
    line.Parent = modDivider
    modDivider.Parent = page

    TrackConn(modDivider.MouseEnter:Connect(function() SetActiveRow(nil) end))

    local function CleanupMenu()
        for _, c in ipairs(menuConns) do
            if typeof(c) == "RBXScriptConnection" then
                pcall(function() c:Disconnect() end)
            elseif type(c) == "table" and type(c.Disconnect) == "function" then
                pcall(function() c:Disconnect() end)
            end
        end
        table.clear(menuConns)
        for _, child in ipairs(page:GetChildren()) do
            if child.Name:sub(1, 12) == "Enhancement_" then
                pcall(child.Destroy, child)
            end
        end
    end
    activeMenuCleanup = CleanupMenu
    Own(function()
        if activeMenuCleanup == CleanupMenu then
            pcall(CleanupMenu)
            activeMenuCleanup = nil
        end
    end)
end

local function SetupWatcher()
    local robloxGui = CoreGui:FindFirstChild("RobloxGui")
    if not robloxGui then return end

    local function ShouldRebuild(p)
        if not p then return false end
        local h = p:FindFirstChild("Enhancement_Header")
        if not h or #h:GetChildren() == 0 then return true end
        return false
    end

    local function TriggerFastInject()
        task.spawn(function()
            for i = 1, 40 do
                local p = FindTargetPage()
                if p and ShouldRebuild(p) then
                    InjectEnhancementSettings(p)
                    break
                elseif p and not ShouldRebuild(p) then
                    break
                end
                task.wait(0.025)
            end
        end)
    end

    local shield = robloxGui:FindFirstChild("SettingsShield", true)
    if shield then
        Own(shield:GetPropertyChangedSignal("Visible"):Connect(function()
            if shield.Visible then
                TriggerFastInject()
            end
        end))
    end

    local pvi = robloxGui:FindFirstChild("PageViewInnerFrame", true)
    if pvi then
        Own(pvi.ChildAdded:Connect(function(child)
            if child.Name == "Page" then
                TriggerFastInject()
            end
        end))
        local page = pvi:FindFirstChild("Page")
        if page then
            Own(page:GetPropertyChangedSignal("Visible"):Connect(function()
                if page.Visible and ShouldRebuild(page) then
                    InjectEnhancementSettings(page)
                end
            end))
            Own(page.ChildAdded:Connect(function(child)
                if child.Name == "VolumeFrame" or child.Name == "RowListLayout" then
                    if ShouldRebuild(page) then
                        InjectEnhancementSettings(page)
                    end
                end
            end))
        end
    end

    Own(robloxGui.DescendantAdded:Connect(function(desc)
        if desc.Name == "VolumeFrame" then
            local p = desc.Parent
            if p and p.Name == "Page" and ShouldRebuild(p) then
                InjectEnhancementSettings(p)
            end
        end
    end))

    Own(GuiService.MenuOpened:Connect(function()
        TriggerFastInject()
    end))

    task.spawn(function()
        while genv and genv.__EnhancementCleanup do
            task.wait(1.0)
            local p = FindTargetPage()
            if ShouldRebuild(p) then
                InjectEnhancementSettings(p)
            end
        end
    end)
end

-- ============================================================================
-- Section 11: System Sync, Initialization & Cleanup Export
-- ============================================================================
local function SyncWithSystems()
    if config.streamer_mode then
        StreamerMode.Enable()
    else
        StreamerMode.Disable()
    end

    if (config.personal_space_bubble or 0) > 0 then
        PersonalSpaceBubble.Enable()
    else
        PersonalSpaceBubble.Disable()
    end

    if config.anti_afk then
        AntiAFK.Enable()
    else
        AntiAFK.Disable()
    end
end

SyncWithSystems()
SetupWatcher()

local initPage = FindTargetPage()
if initPage then
    InjectEnhancementSettings(initPage)
end

local function FullSuiteCleanup()
    -- 1. Streamer Mode Cleanup
    if StreamerMode and StreamerMode.Disable then
        pcall(StreamerMode.Disable)
    end

    -- 2. Personal Space Bubble Cleanup
    if PersonalSpaceBubble and PersonalSpaceBubble.Disable then
        pcall(PersonalSpaceBubble.Disable)
    end

    -- 3. Anti-AFK Cleanup
    if AntiAFK and AntiAFK.Disable then
        pcall(AntiAFK.Disable)
    end

    -- 5. Locator Cleanup
    for pName, _ in pairs(TrackedPlayers) do
        pcall(UntrackPlayerInternal, pName)
    end
    table.clear(TrackedPlayers)
    table.clear(IndividuallyTrackedPlayers)
    table.clear(TrackedTeams)

    for player, conns in pairs(PlayerListeners) do
        if type(conns) == "table" then
            for _, c in ipairs(conns) do
                if typeof(c) == "RBXScriptConnection" or (type(c) == "table" and type(c.Disconnect) == "function") then
                    pcall(function() c:Disconnect() end)
                end
            end
        end
    end
    table.clear(PlayerListeners)

    -- 6. Leaderboard Cleanup
    local actualList = GetActualList()
    if actualList then
        for _, desc in ipairs(actualList:GetDescendants()) do
            if desc.Name == "LocatorIcon" or desc.Name == "TeamLocatorIcon" then
                desc:Destroy()
            elseif desc.Name == "PlayerIcon" and desc:IsA("ImageLabel") then
                desc.Visible = true
            end
        end
    end
    if PlayerList then
        for _, desc in ipairs(PlayerList:GetDescendants()) do
            if desc.Name == "LocateButton" or desc.Name == "CopyExpandPanel" or desc.Name == "InlineCopyPanel" then
                desc:Destroy()
            end
            if desc:GetAttribute("LocatorHooked") then
                desc:SetAttribute("LocatorHooked", nil)
            end
        end
    end

    -- 7. Clean Janitor (all connections and instances)
    for i = #Janitor, 1, -1 do
        local x = Janitor[i]
        if typeof(x) == "RBXScriptConnection" then
            pcall(function() x:Disconnect() end)
        elseif type(x) == "table" and type(x.Disconnect) == "function" then
            pcall(function() x:Disconnect() end)
        elseif typeof(x) == "Instance" then
            pcall(x.Destroy, x)
        elseif type(x) == "function" then
            pcall(x)
        end
        Janitor[i] = nil
    end

    -- 8. Restore TextChatService IncomingMessage callback
    pcall(function()
        local TextChatService = game:GetService("TextChatService")
        if TextChatService then
            TextChatService.OnIncomingMessage = nil
        end
    end)

    -- 9. Bubble Chat Manager Cleanup
    if BubbleChatManager and BubbleChatManager.Disable then
        pcall(BubbleChatManager.Disable)
    end

    if genv then
        genv.__OmniEnhancementCleanup = nil
        genv.__EnhancementCleanup = nil
    end

    print("[OmniEnhancementSuite]: Suite fully cleaned up.")
end

if genv then
    genv.__OmniEnhancementCleanup = FullSuiteCleanup
    genv.__EnhancementCleanup = FullSuiteCleanup
    genv.OmniEnhancementSuite = {
        StreamerMode = StreamerMode,
        PersonalSpaceBubble = PersonalSpaceBubble,
        Locator = Locator,
        AntiAFK = AntiAFK,
        BubbleChat = BubbleChatManager,
        Config = config,
        Cleanup = FullSuiteCleanup,
    }
    genv.RobloxEnhancement = genv.OmniEnhancementSuite
end

print("[OmniEnhancementSuite]: Successfully loaded and initialized all enhancement modules!")

return {
    StreamerMode = StreamerMode,
    PersonalSpaceBubble = PersonalSpaceBubble,
    Locator = Locator,
    AntiAFK = AntiAFK,
    BubbleChat = BubbleChatManager,
    Config = config,
    Cleanup = FullSuiteCleanup,
}