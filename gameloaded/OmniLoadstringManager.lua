--!stage: GameLoaded
--!priority: 80
--!name: OmniLoadstringManager
-- ==============================================================================
-- OMNI LOADSTRING & TRUST MANAGER (Shift + F6)
-- Interactive management console for authorized remote script URLs & return hashes.
-- Allows users to:
--   - Inspect all authorized URLs from Omni_TrustedUrls.json
--   - Toggle per-script unattended Auto-Update (Silent Auto-Update vs Diff Review)
--   - View cached local script files in omni_trusted_scripts/
--   - Check upstream URLs for pending author updates
--   - Revoke trust records (deleting authorized URLs or return hashes)
--   - Clean orphan hashes and manage approved content signatures
-- ==============================================================================

local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local TRUSTED_URLS_LEDGER_PATH = "Omni_TrustedUrls.json"
local TRUSTED_SCRIPTS_DIR = "omni_trusted_scripts"

-- GUI Parent Discovery
local function getGuiParent()
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local okCG, CoreGui = pcall(function() return game:GetService("CoreGui") end)
    if okCG and CoreGui then
        local okP = pcall(function()
            local test = Instance.new("Folder")
            test.Parent = CoreGui
            test:Destroy()
        end)
        if okP then return CoreGui end
    end
    if Players.LocalPlayer then
        local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
        if pg then return pg end
    end
    return nil
end

-- Cryptographic Hash Utility (SHA-256)
local function computeSha256(str)
    if not str or type(str) ~= "string" then return nil end
    local cryptHash = (type(crypt) == "table" and type(crypt.hash) == "function" and crypt.hash)
                   or (type(syn) == "table" and type(syn.crypt) == "table" and type(syn.crypt.hash) == "function" and syn.crypt.hash)
    if cryptHash then
        local ok, h = pcall(cryptHash, str, "sha256")
        if ok and type(h) == "string" and #h == 64 then return h:lower() end
    end
    local cryptSha = (type(crypt) == "table" and type(crypt.sha256) == "function" and crypt.sha256)
    if cryptSha then
        local ok, h = pcall(cryptSha, str)
        if ok and type(h) == "string" and #h == 64 then return h:lower() end
    end
    local sha256Fn = (type(sha256) == "function" and sha256) or (type(sha256_hex) == "function" and sha256_hex)
    if sha256Fn then
        local ok, h = pcall(sha256Fn, str)
        if ok and type(h) == "string" and #h == 64 then return h:lower() end
    end
    return nil
end

-- Ledger Helpers
local function loadLedger()
    if isfile and isfile(TRUSTED_URLS_LEDGER_PATH) then
        local ok, raw = pcall(readfile, TRUSTED_URLS_LEDGER_PATH)
        if ok and raw and #raw > 0 then
            local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
            if decOk and type(data) == "table" then
                local sanitizedUrls = {}
                if type(data.urls) == "table" then
                    for u, entry in pairs(data.urls) do
                        if type(u) == "string" and u:match("^https?://") and type(entry) == "table" then
                            local safeHash = entry.hash
                            if type(safeHash) == "string" and #safeHash == 64 and safeHash:match("^%x+$") then
                                local safeSubs = {}
                                if type(entry.submodules) == "table" then
                                    for _, sH in ipairs(entry.submodules) do
                                        if type(sH) == "string" and #sH == 64 and sH:match("^%x+$") then
                                            table.insert(safeSubs, sH:lower())
                                        end
                                    end
                                end
                                sanitizedUrls[u] = {
                                    url = u,
                                    name = (type(entry.name) == "string" and #entry.name > 0) and entry.name or nil,
                                    hash = safeHash:lower(),
                                    local_file = entry.local_file,
                                    first_trusted = tonumber(entry.first_trusted) or os.time(),
                                    last_updated = tonumber(entry.last_updated) or os.time(),
                                    auto_update = (entry.auto_update == true),
                                    submodules = safeSubs
                                }
                            end
                        end
                    end
                end
                local sanitizedHashes = {}
                if type(data.hashes) == "table" then
                    for h, val in pairs(data.hashes) do
                        if type(h) == "string" and #h == 64 and h:match("^%x+$") and (val == true or type(val) == "string") then
                            sanitizedHashes[h:lower()] = true
                        end
                    end
                end
                for _, uEntry in pairs(sanitizedUrls) do
                    if uEntry.hash then sanitizedHashes[uEntry.hash:lower()] = true end
                    if type(uEntry.submodules) == "table" then
                        for _, sH in ipairs(uEntry.submodules) do
                            sanitizedHashes[sH:lower()] = true
                        end
                    end
                end
                return {
                    version = tonumber(data.version) or 1,
                    urls = sanitizedUrls,
                    hashes = sanitizedHashes
                }
            end
        end
    end
    return { version = 1, urls = {}, hashes = {} }
end

local function saveLedger(ledger)
    if not ledger or type(ledger) ~= "table" then return false end
    if isfolder and not isfolder(TRUSTED_SCRIPTS_DIR) then
        pcall(makefolder, TRUSTED_SCRIPTS_DIR)
    end
    local okEnc, json = pcall(function() return HttpService:JSONEncode(ledger) end)
    if okEnc and json and writefile then
        local okW = pcall(writefile, TRUSTED_URLS_LEDGER_PATH, json)
        return okW
    end
    return false
end

-- Windows Safe Filename Sanitizer
local function sanitizeUrlToFilename(url)
    if not url or type(url) ~= "string" then return "script.lua" end
    local clean = url:gsub("^https?://", ""):gsub("%?.*$", ""):gsub("[^%w%.%-_]", "_"):gsub("_+", "_")
    if #clean > 50 then clean = clean:sub(1, 50) end
    local h = computeSha256(url)
    local short = (h and h:sub(1, 10)) or "hash"
    return clean .. "_" .. short .. ".lua"
end

-- Format Timestamp
local function formatTimestamp(ts)
    if not ts or ts == 0 then return "N/A" end
    local dt = os.date("!*t", ts)
    return string.format("%04d-%02d-%02d %02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.min)
end

-- Extract Domain & Distinct Script Identity
local function getUrlDisplayName(url, customName)
    if customName and type(customName) == "string" and #customName > 0 then
        local domain = (url and url:match("^https?://([^/]+)")) or "custom"
        return domain, customName
    end
    if not url then return "Unknown Script", "Direct Content" end
    local withoutProto = url:gsub("^https?://", "")
    local domain, path = withoutProto:match("^([^/]+)/(.*)$")
    domain = domain or withoutProto
    path = path or ""

    local lowerDomain = domain:lower()
    if lowerDomain:find("luaauth.com") or lowerDomain:find("luaarmor") then
        local token = path:match("([^/]+)$") or path
        local shortToken = #token > 12 and (token:sub(1, 10) .. "...") or token
        return domain, "LuaArmor (" .. shortToken .. ")"
    end

    if lowerDomain:find("githubusercontent.com") then
        local owner, repo, filename = path:match("^([^/]+)/([^/]+)/.-/([^/]+)$")
        if repo and filename then
            return domain, repo .. ": " .. filename
        end
    end

    if lowerDomain:find("pastebin.com") then
        local pid = path:match("([^/]+)$") or path
        return domain, "Pastebin (" .. pid .. ")"
    end

    local filename = path:match("([^/]+)$") or path
    if #filename > 28 then
        filename = filename:sub(1, 25) .. "..."
    end
    return domain, filename
end

-- ==============================================================================
-- CLEANUP PREVIOUS INSTANCE (HOT-RELOAD SAFETY)
-- ==============================================================================
if type(getgenv()._OmniLoadstringManagerCleanUp) == "function" then
    pcall(getgenv()._OmniLoadstringManagerCleanUp)
end

local guiParent = getGuiParent()
if not guiParent then
    warn("[OmniLoadstringManager]: Unable to locate GUI parent. Retrying on PlayerGui...")
    local lp = Players.LocalPlayer or Players.PlayerAdded:Wait()
    guiParent = lp:WaitForChild("PlayerGui", 10)
end

if not guiParent then
    warn("[OmniLoadstringManager]: Failed to mount GUI. Aborting.")
    return
end

-- Remove any old GUI
local existingGui = guiParent:FindFirstChild("Omni_LoadstringManagerGui")
if existingGui then
    existingGui:Destroy()
end

-- ==============================================================================
-- DESIGN SYSTEM TOKENS (Omni Unified UI Standard)
-- ==============================================================================
local Theme = {
    Background    = Color3.fromRGB(15, 17, 23),   -- #0F1117: Main window background
    TitleBar      = Color3.fromRGB(20, 24, 33),   -- #141821: Window header bar
    Card          = Color3.fromRGB(24, 30, 42),   -- #181E2A: Content cards & panels
    CardSelected  = Color3.fromRGB(30, 38, 52),   -- #1E2634: Active tabs & focused rows
    Stroke        = Color3.fromRGB(45, 52, 68),   -- #2D3444: Main window outer border (1px)
    CardStroke    = Color3.fromRGB(40, 50, 68),   -- #283244: Card & section border (1px)
    Accent        = Color3.fromRGB(64, 196, 255), -- #40C4FF: Electric cyan primary accent
    AccentHover   = Color3.fromRGB(20, 180, 255), -- #14B4FF: Active hover highlight
    PrimaryBtn    = Color3.fromRGB(30, 80, 140),  -- #1E508C: Affirmative button background
    DangerBtn     = Color3.fromRGB(60, 25, 32),   -- #3C1920: Destructive button background
    CloseBtnBg    = Color3.fromRGB(28, 32, 42),   -- #1C202A: Window close button background
    KeybindBg     = Color3.fromRGB(30, 36, 50),   -- #1E2432: Keybind pill background
    
    TextPrimary   = Color3.fromRGB(240, 244, 255),-- #F0F4FF: High-contrast title & tab text
    TextSecondary = Color3.fromRGB(140, 155, 180),-- #8C9BB4: Subtitles & inactive tab labels
    TextMuted     = Color3.fromRGB(85, 100, 125), -- #55647D: Placeholders & timestamps
    KeybindText   = Color3.fromRGB(160, 175, 200),-- #A0AFCC: Keybind pill text
    CloseBtnText  = Color3.fromRGB(200, 210, 225),-- #C8D2E1: Close button text ("X")
    
    StatusSuccess = Color3.fromRGB(50, 220, 120), -- #32DC78: Green status / additions
    StatusWarning = Color3.fromRGB(255, 175, 50), -- #FFAF32: Yellow advisory / warnings
    StatusDanger  = Color3.fromRGB(255, 75, 75),  -- #FF4B4B: Red errors / removals
}

-- ==============================================================================
-- BUILD USER INTERFACE
-- ==============================================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "Omni_LoadstringManagerGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 9998
ScreenGui.Parent = guiParent

-- Backdrop Dimmer
local Backdrop = Instance.new("Frame")
Backdrop.Name = "Backdrop"
Backdrop.Size = UDim2.new(1, 0, 1, 0)
Backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
Backdrop.BackgroundTransparency = 0.55
Backdrop.BorderSizePixel = 0
Backdrop.Visible = false
Backdrop.Parent = ScreenGui

-- Main Container Window
local Window = Instance.new("Frame")
Window.Name = "Window"
Window.Size = UDim2.new(0, 720, 0, 560)
Window.Position = UDim2.new(0.5, -360, 0.5, -280)
Window.BackgroundColor3 = Theme.Background
Window.BorderSizePixel = 0
Window.ClipsDescendants = true
Window.Parent = Backdrop

local WindowCorner = Instance.new("UICorner")
WindowCorner.CornerRadius = UDim.new(0, 8)
WindowCorner.Parent = Window

local WindowStroke = Instance.new("UIStroke")
WindowStroke.Thickness = 1
WindowStroke.Color = Theme.Stroke
WindowStroke.Parent = Window

-- Standardized Draggable Header (38px standard)
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 38)
Header.BackgroundColor3 = Theme.TitleBar
Header.BorderSizePixel = 0
Header.Active = true
Header.Parent = Window

local HeaderCorner = Instance.new("UICorner")
HeaderCorner.CornerRadius = UDim.new(0, 8)
HeaderCorner.Parent = Header

local HeaderCover = Instance.new("Frame")
HeaderCover.Name = "HeaderCover"
HeaderCover.Size = UDim2.new(1, 0, 0, 8)
HeaderCover.Position = UDim2.new(0, 0, 1, -8)
HeaderCover.BackgroundColor3 = Theme.TitleBar
HeaderCover.BorderSizePixel = 0
HeaderCover.Parent = Header

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Name = "TitleLabel"
TitleLabel.Size = UDim2.new(0, 310, 1, 0)
TitleLabel.Position = UDim2.new(0, 12, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Active = false
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 13
TitleLabel.TextColor3 = Theme.Accent
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.TextYAlignment = Enum.TextYAlignment.Center
TitleLabel.Text = "⚡ OMNI LOADSTRING & TRUST MANAGER"
TitleLabel.Parent = Header

-- Standard Keybind Badge in Header
local KeybindBadge = Instance.new("TextLabel")
KeybindBadge.Name = "KeybindBadge"
KeybindBadge.Size = UDim2.new(0, 74, 0, 20)
KeybindBadge.Position = UDim2.new(0, 326, 0.5, -10)
KeybindBadge.BackgroundColor3 = Theme.KeybindBg
KeybindBadge.Active = false
KeybindBadge.Font = Enum.Font.GothamBold
KeybindBadge.TextSize = 10
KeybindBadge.TextColor3 = Theme.KeybindText
KeybindBadge.Text = "Shift + F6"
KeybindBadge.Parent = Header

local KeybindBadgeCorner = Instance.new("UICorner")
KeybindBadgeCorner.CornerRadius = UDim.new(0, 4)
KeybindBadgeCorner.Parent = KeybindBadge

-- Refresh Button (Positioned next to Close Button)
local RefreshBtn = Instance.new("TextButton")
RefreshBtn.Name = "RefreshBtn"
RefreshBtn.Size = UDim2.new(0, 28, 0, 28)
RefreshBtn.Position = UDim2.new(1, -66, 0.5, -14)
RefreshBtn.BackgroundColor3 = Theme.CloseBtnBg
RefreshBtn.BorderSizePixel = 0
RefreshBtn.Font = Enum.Font.GothamBold
RefreshBtn.TextSize = 13
RefreshBtn.TextColor3 = Theme.CloseBtnText
RefreshBtn.Text = "🔄"
RefreshBtn.Parent = Header

local RefreshBtnCorner = Instance.new("UICorner")
RefreshBtnCorner.CornerRadius = UDim.new(0, 4)
RefreshBtnCorner.Parent = RefreshBtn

RefreshBtn.MouseEnter:Connect(function()
    RefreshBtn.BackgroundColor3 = Theme.CardSelected
    RefreshBtn.TextColor3 = Theme.TextPrimary
end)
RefreshBtn.MouseLeave:Connect(function()
    RefreshBtn.BackgroundColor3 = Theme.CloseBtnBg
    RefreshBtn.TextColor3 = Theme.CloseBtnText
end)

-- Standardized [X] Close Button (28x28px, 4px corner)
local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.Size = UDim2.new(0, 28, 0, 28)
CloseBtn.Position = UDim2.new(1, -34, 0.5, -14)
CloseBtn.BackgroundColor3 = Theme.CloseBtnBg
CloseBtn.BorderSizePixel = 0
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 13
CloseBtn.TextColor3 = Theme.CloseBtnText
CloseBtn.Text = "X"
CloseBtn.Modal = true
CloseBtn.Parent = Header

local CloseBtnCorner = Instance.new("UICorner")
CloseBtnCorner.CornerRadius = UDim.new(0, 4)
CloseBtnCorner.Parent = CloseBtn

CloseBtn.MouseEnter:Connect(function()
    CloseBtn.BackgroundColor3 = Theme.DangerBtn
    CloseBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
end)

CloseBtn.MouseLeave:Connect(function()
    CloseBtn.BackgroundColor3 = Theme.CloseBtnBg
    CloseBtn.TextColor3 = Theme.CloseBtnText
end)

-- Dragging Functionality for Header
local dragging = false
local dragInput, dragStart, startPos
local restingPos = UDim2.new(0.5, -360, 0.5, -280)

Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = Window.Position
        restingPos = Window.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                restingPos = Window.Position
            end
        end)
    end
end)

Header.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        Window.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
        restingPos = Window.Position
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if dragging then
            restingPos = Window.Position
        end
        dragging = false
    end
end)

-- ==============================================================================
-- RESIZABLE WINDOW ENGINE (Bottom-Right Resize Grip)
-- ==============================================================================
local MIN_WIDTH = 600
local MIN_HEIGHT = 400
local MAX_WIDTH = 1400
local MAX_HEIGHT = 900

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
ResizeGrip.Parent = Window

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
        startSize = Vector2.new(Window.AbsoluteSize.X, Window.AbsoluteSize.Y)
        ResizeGrip.TextColor3 = Color3.fromRGB(64, 196, 255)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - resizeStart
        local newW = math.clamp(startSize.X + delta.X, MIN_WIDTH, MAX_WIDTH)
        local newH = math.clamp(startSize.Y + delta.Y, MIN_HEIGHT, MAX_HEIGHT)
        Window.Size = UDim2.new(0, newW, 0, newH)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if resizing then
            resizing = false
            ResizeGrip.TextColor3 = Color3.fromRGB(80, 95, 120)
        end
    end
end)

-- Navigation Tabs Bar
local NavFrame = Instance.new("Frame")
NavFrame.Name = "NavFrame"
NavFrame.Size = UDim2.new(1, -24, 0, 28)
NavFrame.Position = UDim2.new(0, 12, 0, 44)
NavFrame.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
NavFrame.BorderSizePixel = 0
NavFrame.Parent = Window

local NavCorner = Instance.new("UICorner")
NavCorner.CornerRadius = UDim.new(0, 6)
NavCorner.Parent = NavFrame

local NavStroke = Instance.new("UIStroke")
NavStroke.Thickness = 1
NavStroke.Color = Color3.fromRGB(35, 41, 55)
NavStroke.Parent = NavFrame

local currentTab = "urls" -- "urls" or "hashes"

local UrlsTabBtn = Instance.new("TextButton")
UrlsTabBtn.Name = "UrlsTabBtn"
UrlsTabBtn.Size = UDim2.new(0.5, -2, 1, 0)
UrlsTabBtn.Position = UDim2.new(0, 0, 0, 0)
UrlsTabBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
UrlsTabBtn.BackgroundTransparency = 0
UrlsTabBtn.BorderSizePixel = 0
UrlsTabBtn.Font = Enum.Font.GothamBold
UrlsTabBtn.TextSize = 11
UrlsTabBtn.TextColor3 = Color3.fromRGB(80, 200, 255)
UrlsTabBtn.Text = "🔗 Authorized URLs (0)"
UrlsTabBtn.Parent = NavFrame

local UrlsTabCorner = Instance.new("UICorner")
UrlsTabCorner.CornerRadius = UDim.new(0, 6)
UrlsTabCorner.Parent = UrlsTabBtn

local UrlsTabIndicator = Instance.new("Frame")
UrlsTabIndicator.Name = "Indicator"
UrlsTabIndicator.Size = UDim2.new(0, 0, 0, 0)
UrlsTabIndicator.Visible = false
UrlsTabIndicator.Parent = UrlsTabBtn

local HashesTabBtn = Instance.new("TextButton")
HashesTabBtn.Name = "HashesTabBtn"
HashesTabBtn.Size = UDim2.new(0.5, -2, 1, 0)
HashesTabBtn.Position = UDim2.new(0.5, 2, 0, 0)
HashesTabBtn.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
HashesTabBtn.BackgroundTransparency = 0
HashesTabBtn.BorderSizePixel = 0
HashesTabBtn.Font = Enum.Font.GothamBold
HashesTabBtn.TextSize = 11
HashesTabBtn.TextColor3 = Color3.fromRGB(130, 145, 170)
HashesTabBtn.Text = "🛡️ Return Hashes (0)"
HashesTabBtn.Parent = NavFrame

local HashesTabCorner = Instance.new("UICorner")
HashesTabCorner.CornerRadius = UDim.new(0, 6)
HashesTabCorner.Parent = HashesTabBtn

local HashesTabIndicator = Instance.new("Frame")
HashesTabIndicator.Name = "Indicator"
HashesTabIndicator.Size = UDim2.new(0, 0, 0, 0)
HashesTabIndicator.Visible = false
HashesTabIndicator.Parent = HashesTabBtn

UrlsTabBtn.MouseEnter:Connect(function()
    if currentTab ~= "urls" then
        UrlsTabBtn.TextColor3 = Color3.fromRGB(200, 215, 240)
    end
end)
UrlsTabBtn.MouseLeave:Connect(function()
    if currentTab ~= "urls" then
        UrlsTabBtn.TextColor3 = Color3.fromRGB(130, 145, 170)
    end
end)
HashesTabBtn.MouseEnter:Connect(function()
    if currentTab ~= "hashes" then
        HashesTabBtn.TextColor3 = Color3.fromRGB(200, 215, 240)
    end
end)
HashesTabBtn.MouseLeave:Connect(function()
    if currentTab ~= "hashes" then
        HashesTabBtn.TextColor3 = Color3.fromRGB(130, 145, 170)
    end
end)

-- Search & Filter Bar
local SearchFrame = Instance.new("Frame")
SearchFrame.Name = "SearchFrame"
SearchFrame.Size = UDim2.new(1, -24, 0, 28)
SearchFrame.Position = UDim2.new(0, 12, 0, 78)
SearchFrame.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
SearchFrame.BorderSizePixel = 0
SearchFrame.Parent = Window

local SearchCorner = Instance.new("UICorner")
SearchCorner.CornerRadius = UDim.new(0, 4)
SearchCorner.Parent = SearchFrame

local SearchStroke = Instance.new("UIStroke")
SearchStroke.Thickness = 1
SearchStroke.Color = Color3.fromRGB(35, 41, 55)
SearchStroke.Parent = SearchFrame

local SearchIcon = Instance.new("TextLabel")
SearchIcon.Size = UDim2.new(0, 30, 1, 0)
SearchIcon.BackgroundTransparency = 1
SearchIcon.Font = Enum.Font.Gotham
SearchIcon.TextSize = 13
SearchIcon.TextColor3 = Theme.TextSecondary
SearchIcon.Text = "🔍"
SearchIcon.Parent = SearchFrame

local SearchBox = Instance.new("TextBox")
SearchBox.Name = "SearchBox"
SearchBox.Size = UDim2.new(1, -64, 1, 0)
SearchBox.Position = UDim2.new(0, 32, 0, 0)
SearchBox.BackgroundTransparency = 1
SearchBox.Font = Enum.Font.GothamMedium
SearchBox.TextSize = 12
SearchBox.TextColor3 = Theme.TextPrimary
SearchBox.Text = ""
SearchBox.PlaceholderColor3 = Theme.TextMuted
SearchBox.PlaceholderText = "Search authorized URLs, domains, or return hashes..."
SearchBox.ClearTextOnFocus = false
SearchBox.TextXAlignment = Enum.TextXAlignment.Left
SearchBox.Parent = SearchFrame

local SearchClearBtn = Instance.new("TextButton")
SearchClearBtn.Name = "SearchClearBtn"
SearchClearBtn.Size = UDim2.new(0, 24, 0, 24)
SearchClearBtn.AnchorPoint = Vector2.new(1, 0.5)
SearchClearBtn.Position = UDim2.new(1, -6, 0.5, 0)
SearchClearBtn.BackgroundColor3 = Theme.Card
SearchClearBtn.BackgroundTransparency = 1
SearchClearBtn.BorderSizePixel = 0
SearchClearBtn.Text = ""
SearchClearBtn.Visible = false
SearchClearBtn.Parent = SearchFrame

local SearchClearCorner = Instance.new("UICorner")
SearchClearCorner.CornerRadius = UDim.new(0, 5)
SearchClearCorner.Parent = SearchClearBtn

local ClearIcon = Instance.new("ImageLabel")
ClearIcon.Name = "ClearIcon"
ClearIcon.Size = UDim2.new(0, 12, 0, 12)
ClearIcon.AnchorPoint = Vector2.new(0.5, 0.5)
ClearIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
ClearIcon.BackgroundTransparency = 1
ClearIcon.Image = "rbxasset://textures/StudioSharedUI/close.png"
ClearIcon.ImageColor3 = Theme.TextSecondary
ClearIcon.Parent = SearchClearBtn

SearchClearBtn.MouseEnter:Connect(function()
    SearchClearBtn.BackgroundTransparency = 0.5
    ClearIcon.ImageColor3 = Theme.TextPrimary
end)

SearchClearBtn.MouseLeave:Connect(function()
    SearchClearBtn.BackgroundTransparency = 1
    ClearIcon.ImageColor3 = Theme.TextSecondary
end)

SearchClearBtn.MouseButton1Click:Connect(function()
    SearchBox.Text = ""
end)

-- Toast Notification Container
local Toast = Instance.new("Frame")
Toast.Name = "Toast"
Toast.Size = UDim2.new(1, -48, 0, 28)
Toast.Position = UDim2.new(0, 24, 1, -40)
Toast.BackgroundColor3 = Theme.TitleBar
Toast.BorderSizePixel = 0
Toast.ZIndex = 10
Toast.Visible = false
Toast.Parent = Window

local ToastCorner = Instance.new("UICorner")
ToastCorner.CornerRadius = UDim.new(0, 6)
ToastCorner.Parent = Toast

local ToastStroke = Instance.new("UIStroke")
ToastStroke.Thickness = 1
ToastStroke.Color = Theme.Stroke
ToastStroke.Parent = Toast

local ToastText = Instance.new("TextLabel")
ToastText.Size = UDim2.new(1, -20, 1, 0)
ToastText.Position = UDim2.new(0, 10, 0, 0)
ToastText.BackgroundTransparency = 1
ToastText.Font = Enum.Font.GothamMedium
ToastText.TextSize = 11
ToastText.TextColor3 = Theme.TextPrimary
ToastText.Text = ""
ToastText.TextXAlignment = Enum.TextXAlignment.Left
ToastText.ZIndex = 11
ToastText.Parent = Toast

local toastThread = nil
local function showToast(message, isError)
    if toastThread then task.cancel(toastThread) end
    ToastText.Text = message
    if isError then
        Toast.BackgroundColor3 = Theme.DangerBtn
        ToastStroke.Color = Theme.StatusDanger
    else
        Toast.BackgroundColor3 = Color3.fromRGB(18, 36, 28)
        ToastStroke.Color = Theme.StatusSuccess
    end
    Toast.Visible = true
    toastThread = task.delay(3.5, function()
        Toast.Visible = false
    end)
end

-- ==============================================================================
-- CONTENT CONTAINERS
-- ==============================================================================

-- 1. URL Content Frame
local UrlsContainer = Instance.new("Frame")
UrlsContainer.Name = "UrlsContainer"
UrlsContainer.Size = UDim2.new(1, -24, 1, -122)
UrlsContainer.Position = UDim2.new(0, 12, 0, 114)
UrlsContainer.BackgroundTransparency = 1
UrlsContainer.Parent = Window

local UrlsScroll = Instance.new("ScrollingFrame")
UrlsScroll.Name = "UrlsScroll"
UrlsScroll.Size = UDim2.new(1, 0, 1, 0)
UrlsScroll.BackgroundTransparency = 1
UrlsScroll.BorderSizePixel = 0
UrlsScroll.ScrollBarThickness = 5
UrlsScroll.ScrollBarImageColor3 = Theme.Accent
UrlsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
UrlsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
UrlsScroll.Parent = UrlsContainer

local UrlsListLayout = Instance.new("UIListLayout")
UrlsListLayout.SortOrder = Enum.SortOrder.LayoutOrder
UrlsListLayout.Padding = UDim.new(0, 8)
UrlsListLayout.Parent = UrlsScroll

-- 2. Hashes Content Frame
local HashesContainer = Instance.new("Frame")
HashesContainer.Name = "HashesContainer"
HashesContainer.Size = UDim2.new(1, -24, 1, -122)
HashesContainer.Position = UDim2.new(0, 12, 0, 114)
HashesContainer.BackgroundTransparency = 1
HashesContainer.Visible = false
HashesContainer.Parent = Window

local HashesScroll = Instance.new("ScrollingFrame")
HashesScroll.Name = "HashesScroll"
HashesScroll.Size = UDim2.new(1, 0, 1, 0)
HashesScroll.BackgroundTransparency = 1
HashesScroll.BorderSizePixel = 0
HashesScroll.ScrollBarThickness = 5
HashesScroll.ScrollBarImageColor3 = Theme.Accent
HashesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
HashesScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
HashesScroll.Parent = HashesContainer

local HashesListLayout = Instance.new("UIListLayout")
HashesListLayout.SortOrder = Enum.SortOrder.LayoutOrder
HashesListLayout.Padding = UDim.new(0, 6)
HashesListLayout.Parent = HashesScroll

-- Active View Controller
currentTab = "urls" -- "urls" or "hashes"
local currentLedger = { version = 1, urls = {}, hashes = {} }

local renderUrlsView = nil
local renderHashesView = nil
local expandedScriptGroups = {}

local function switchTab(tab)
    currentTab = tab
    if tab == "urls" then
        UrlsTabBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
        UrlsTabBtn.BackgroundTransparency = 0
        UrlsTabBtn.TextColor3 = Color3.fromRGB(80, 200, 255)

        HashesTabBtn.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
        HashesTabBtn.BackgroundTransparency = 0
        HashesTabBtn.TextColor3 = Color3.fromRGB(130, 145, 170)

        UrlsContainer.Visible = true
        HashesContainer.Visible = false
        if renderUrlsView then renderUrlsView() end
    else
        HashesTabBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
        HashesTabBtn.BackgroundTransparency = 0
        HashesTabBtn.TextColor3 = Color3.fromRGB(80, 200, 255)

        UrlsTabBtn.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
        UrlsTabBtn.BackgroundTransparency = 0
        UrlsTabBtn.TextColor3 = Color3.fromRGB(130, 145, 170)

        UrlsContainer.Visible = false
        HashesContainer.Visible = true
        if renderHashesView then renderHashesView() end
    end
end

UrlsTabBtn.MouseButton1Click:Connect(function() switchTab("urls") end)
HashesTabBtn.MouseButton1Click:Connect(function() switchTab("hashes") end)

-- ==============================================================================
-- VIEW RENDERERS
-- ==============================================================================

renderUrlsView = function()
    -- Clear current children
    for _, child in ipairs(UrlsScroll:GetChildren()) do
        if child:IsA("GuiObject") and child ~= UrlsListLayout then
            child:Destroy()
        end
    end

    local query = SearchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local urlList = {}
    for u, entry in pairs(currentLedger.urls) do
        table.insert(urlList, entry)
    end
    table.sort(urlList, function(a, b)
        return (a.last_updated or 0) > (b.last_updated or 0)
    end)

    UrlsTabBtn.Text = string.format("🔗 Authorized URLs (%d)", #urlList)

    local totalHashes = 0
    if currentLedger.hashes then
        for _ in pairs(currentLedger.hashes) do
            totalHashes = totalHashes + 1
        end
    end
    HashesTabBtn.Text = string.format("🛡️ Return Hashes (%d)", totalHashes)

    local matches = 0
    for idx, entry in ipairs(urlList) do
        local u = entry.url
        local h = entry.hash or ""
        local localFile = entry.local_file or ""
        local domain, shortFile = getUrlDisplayName(u, entry.name)
        local scriptName = entry.name or shortFile or domain

        if query == "" or u:lower():find(query, 1, true) or h:lower():find(query, 1, true) or domain:lower():find(query, 1, true) or shortFile:lower():find(query, 1, true) or (entry.name and entry.name:lower():find(query, 1, true)) then
            matches = matches + 1

            local Card = Instance.new("Frame")
            Card.Name = "UrlCard_" .. idx
            Card.Size = UDim2.new(1, 0, 0, 114)
            Card.BackgroundColor3 = Theme.Card
            Card.BorderSizePixel = 0
            Card.ClipsDescendants = true
            Card.Parent = UrlsScroll

            local CardCorner = Instance.new("UICorner")
            CardCorner.CornerRadius = UDim.new(0, 6)
            CardCorner.Parent = Card

            local CardStroke = Instance.new("UIStroke")
            CardStroke.Thickness = 1
            CardStroke.Color = Theme.CardStroke
            CardStroke.Parent = Card

            -- Row 1: Left Container (Domain Pill + Script Title)
            local TopLeft = Instance.new("Frame")
            TopLeft.Name = "TopLeft"
            TopLeft.Size = UDim2.new(1, -265, 0, 22)
            TopLeft.Position = UDim2.new(0, 10, 0, 8)
            TopLeft.BackgroundTransparency = 1
            TopLeft.ClipsDescendants = true
            TopLeft.Parent = Card

            local TopLeftLayout = Instance.new("UIListLayout")
            TopLeftLayout.FillDirection = Enum.FillDirection.Horizontal
            TopLeftLayout.VerticalAlignment = Enum.VerticalAlignment.Center
            TopLeftLayout.SortOrder = Enum.SortOrder.LayoutOrder
            TopLeftLayout.Padding = UDim.new(0, 8)
            TopLeftLayout.Parent = TopLeft

            local DomainPill = Instance.new("Frame")
            DomainPill.Name = "DomainPill"
            DomainPill.LayoutOrder = 1
            DomainPill.Size = UDim2.new(0, 0, 0, 20)
            DomainPill.AutomaticSize = Enum.AutomaticSize.X
            DomainPill.BackgroundColor3 = Theme.KeybindBg
            DomainPill.BorderSizePixel = 0
            DomainPill.Parent = TopLeft

            local DomainCorner = Instance.new("UICorner")
            DomainCorner.CornerRadius = UDim.new(0, 4)
            DomainCorner.Parent = DomainPill

            local DomainPadding = Instance.new("UIPadding")
            DomainPadding.PaddingLeft = UDim.new(0, 8)
            DomainPadding.PaddingRight = UDim.new(0, 8)
            DomainPadding.Parent = DomainPill

            local DomainLabel = Instance.new("TextLabel")
            DomainLabel.Size = UDim2.new(0, 0, 1, 0)
            DomainLabel.AutomaticSize = Enum.AutomaticSize.X
            DomainLabel.BackgroundTransparency = 1
            DomainLabel.Font = Enum.Font.GothamBold
            DomainLabel.TextSize = 10
            DomainLabel.TextColor3 = Theme.Accent
            DomainLabel.Text = domain
            DomainLabel.Parent = DomainPill

            local TitleLabel = Instance.new("TextLabel")
            TitleLabel.Name = "TitleLabel"
            TitleLabel.LayoutOrder = 2
            TitleLabel.Size = UDim2.new(0, 0, 1, 0)
            TitleLabel.AutomaticSize = Enum.AutomaticSize.X
            TitleLabel.BackgroundTransparency = 1
            TitleLabel.Font = Enum.Font.GothamBold
            TitleLabel.TextSize = 12
            TitleLabel.TextColor3 = Theme.TextPrimary
            TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
            TitleLabel.Text = entry.name or shortFile or domain
            TitleLabel.Parent = TopLeft

            -- Row 2: Dedicated URL Label (Clean, bounded to left column, zero button collision)
            local UrlLabel = Instance.new("TextLabel")
            UrlLabel.Name = "UrlLabel"
            UrlLabel.Size = UDim2.new(1, -265, 0, 16)
            UrlLabel.Position = UDim2.new(0, 10, 0, 34)
            UrlLabel.BackgroundTransparency = 1
            UrlLabel.Font = Enum.Font.RobotoMono
            UrlLabel.TextSize = 10
            UrlLabel.TextColor3 = Theme.TextSecondary
            UrlLabel.TextXAlignment = Enum.TextXAlignment.Left
            UrlLabel.TextTruncate = Enum.TextTruncate.AtEnd
            UrlLabel.Text = u
            UrlLabel.Parent = Card

            -- Auto-Update Status Badge & Toggle Button (Task Manager High-Contrast Utility Style)
            local isAuto = (entry.auto_update == true)
            local AutoToggleBtn = Instance.new("TextButton")
            AutoToggleBtn.Name = "AutoToggleBtn"
            AutoToggleBtn.Size = UDim2.new(0, 150, 0, 24)
            AutoToggleBtn.Position = UDim2.new(1, -245, 0, 8)
            AutoToggleBtn.BackgroundColor3 = isAuto and Color3.fromRGB(22, 48, 34) or Color3.fromRGB(28, 32, 42)
            AutoToggleBtn.BorderSizePixel = 0
            AutoToggleBtn.Font = Enum.Font.GothamBold
            AutoToggleBtn.TextSize = 10
            AutoToggleBtn.TextColor3 = isAuto and Color3.fromRGB(100, 240, 150) or Color3.fromRGB(160, 175, 200)
            AutoToggleBtn.Text = isAuto and "⚡ Auto-Update: ON" or "⏸️ Auto-Update: OFF"
            AutoToggleBtn.Parent = Card

            local AutoToggleCorner = Instance.new("UICorner")
            AutoToggleCorner.CornerRadius = UDim.new(0, 4)
            AutoToggleCorner.Parent = AutoToggleBtn

            local AutoToggleStroke = Instance.new("UIStroke")
            AutoToggleStroke.Thickness = 1
            AutoToggleStroke.Color = isAuto and Color3.fromRGB(36, 75, 52) or Color3.fromRGB(38, 48, 64)
            AutoToggleStroke.Parent = AutoToggleBtn

            AutoToggleBtn.MouseEnter:Connect(function()
                if entry.auto_update == true then
                    AutoToggleBtn.BackgroundColor3 = Color3.fromRGB(28, 60, 42)
                    AutoToggleBtn.TextColor3 = Color3.fromRGB(130, 255, 175)
                else
                    AutoToggleBtn.BackgroundColor3 = Color3.fromRGB(36, 42, 54)
                    AutoToggleBtn.TextColor3 = Color3.fromRGB(200, 215, 240)
                end
            end)
            AutoToggleBtn.MouseLeave:Connect(function()
                local curAuto = (entry.auto_update == true)
                AutoToggleBtn.BackgroundColor3 = curAuto and Color3.fromRGB(22, 48, 34) or Color3.fromRGB(28, 32, 42)
                AutoToggleBtn.TextColor3 = curAuto and Color3.fromRGB(100, 240, 150) or Color3.fromRGB(160, 175, 200)
            end)

            AutoToggleBtn.MouseButton1Click:Connect(function()
                entry.auto_update = not (entry.auto_update == true)
                currentLedger.urls[u] = entry
                local saved = saveLedger(currentLedger)
                if saved then
                    local stateStr = entry.auto_update and "ENABLED" or "DISABLED"
                    showToast(string.format("Auto-Update %s for %s", stateStr, scriptName), false)
                    renderUrlsView()
                else
                    showToast("Failed to save ledger to disk!", true)
                end
            end)

            -- Revoke Button (Two-Step Confirmation)
            local RevokeBtn = Instance.new("TextButton")
            RevokeBtn.Name = "RevokeBtn"
            RevokeBtn.Size = UDim2.new(0, 80, 0, 24)
            RevokeBtn.Position = UDim2.new(1, -90, 0, 8)
            RevokeBtn.BackgroundColor3 = Theme.DangerBtn
            RevokeBtn.BorderSizePixel = 0
            RevokeBtn.Font = Enum.Font.GothamBold
            RevokeBtn.TextSize = 11
            RevokeBtn.TextColor3 = Theme.StatusDanger
            RevokeBtn.Text = "🗑️ Revoke"
            RevokeBtn.Parent = Card

            local RevokeCorner = Instance.new("UICorner")
            RevokeCorner.CornerRadius = UDim.new(0, 4)
            RevokeCorner.Parent = RevokeBtn

            local revokeConfirm = false
            local revokeReset = nil
            RevokeBtn.MouseButton1Click:Connect(function()
                if not revokeConfirm then
                    revokeConfirm = true
                    RevokeBtn.Text = "Confirm?"
                    RevokeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 55)
                    RevokeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
                    revokeReset = task.delay(4.0, function()
                        revokeConfirm = false
                        RevokeBtn.Text = "🗑️ Revoke"
                        RevokeBtn.BackgroundColor3 = Theme.DangerBtn
                        RevokeBtn.TextColor3 = Theme.StatusDanger
                    end)
                else
                    if revokeReset then task.cancel(revokeReset) end
                    currentLedger.urls[u] = nil
                    if entry.hash and currentLedger.hashes then
                        currentLedger.hashes[entry.hash] = nil
                    end
                    if type(entry.submodules) == "table" and currentLedger.hashes then
                        for _, sH in ipairs(entry.submodules) do
                            currentLedger.hashes[sH] = nil
                        end
                    end
                    saveLedger(currentLedger)
                    showToast(string.format("Revoked trust for %s and linked submodules.", scriptName), false)
                    renderUrlsView()
                end
            end)

            -- Submodules & Signatures Attribution Chip (Clickable, switches to filtered Hashes view)
            local primaryHash = entry.hash and entry.hash:lower() or nil
            local submodules = (type(entry.submodules) == "table" and entry.submodules) or {}
            local subCount = #submodules
            local totalSigs = (primaryHash and 1 or 0) + subCount

            local SigChip = Instance.new("TextButton")
            SigChip.Name = "SigChip"
            SigChip.Size = UDim2.new(0, 235, 0, 24)
            SigChip.Position = UDim2.new(1, -245, 0, 44)
            SigChip.BackgroundColor3 = Theme.KeybindBg
            SigChip.BorderSizePixel = 0
            SigChip.Font = Enum.Font.GothamMedium
            SigChip.TextSize = 10
            SigChip.TextColor3 = Theme.KeybindText
            if subCount > 0 then
                SigChip.Text = string.format("🔒 %d Signatures (%d Subs)", totalSigs, subCount)
            else
                SigChip.Text = "🔒 1 Signature (Primary Only)"
            end
            SigChip.Parent = Card

            local SigChipCorner = Instance.new("UICorner")
            SigChipCorner.CornerRadius = UDim.new(0, 4)
            SigChipCorner.Parent = SigChip

            local SigChipStroke = Instance.new("UIStroke")
            SigChipStroke.Thickness = 1
            SigChipStroke.Color = Theme.CardStroke
            SigChipStroke.Parent = SigChip

            SigChip.MouseButton1Click:Connect(function()
                local filterToken = entry.name or u:match("([^/]+)$") or u
                SearchBox.Text = filterToken
                switchTab("hashes")
            end)

            -- Hash Label & Copy
            local HashLabel = Instance.new("TextLabel")
            HashLabel.Size = UDim2.new(1, -265, 0, 16)
            HashLabel.Position = UDim2.new(0, 10, 0, 52)
            HashLabel.BackgroundTransparency = 1
            HashLabel.Font = Enum.Font.RobotoMono
            HashLabel.TextSize = 10
            HashLabel.TextColor3 = Theme.TextSecondary
            HashLabel.TextXAlignment = Enum.TextXAlignment.Left
            HashLabel.TextTruncate = Enum.TextTruncate.AtEnd
            local shortH = (h and #h >= 16) and (h:sub(1, 14) .. "..." .. h:sub(-8)) or (h or "N/A")
            HashLabel.Text = "SHA-256: " .. shortH
            HashLabel.Parent = Card

            -- Cache File Info & Timestamps
            local CacheLabel = Instance.new("TextLabel")
            CacheLabel.Size = UDim2.new(1, -265, 0, 16)
            CacheLabel.Position = UDim2.new(0, 10, 0, 70)
            CacheLabel.BackgroundTransparency = 1
            CacheLabel.Font = Enum.Font.Gotham
            CacheLabel.TextSize = 10
            CacheLabel.TextColor3 = Theme.TextMuted
            CacheLabel.TextXAlignment = Enum.TextXAlignment.Left
            CacheLabel.TextTruncate = Enum.TextTruncate.AtEnd
            local fileExists = localFile ~= "" and isfile and isfile(localFile)
            local fileStat = fileExists and "✓ Cached on disk" or "⚠️ Cache missing"
            CacheLabel.Text = string.format("Cache: %s (%s)", localFile ~= "" and localFile or "None", fileStat)
            CacheLabel.Parent = Card

            local TimeLabel = Instance.new("TextLabel")
            TimeLabel.Size = UDim2.new(1, -265, 0, 16)
            TimeLabel.Position = UDim2.new(0, 10, 0, 88)
            TimeLabel.BackgroundTransparency = 1
            TimeLabel.Font = Enum.Font.Gotham
            TimeLabel.TextSize = 10
            TimeLabel.TextColor3 = Theme.TextMuted
            TimeLabel.TextXAlignment = Enum.TextXAlignment.Left
            TimeLabel.TextTruncate = Enum.TextTruncate.AtEnd
            TimeLabel.Text = string.format("First Trusted: %s | Last Updated: %s", formatTimestamp(entry.first_trusted), formatTimestamp(entry.last_updated))
            TimeLabel.Parent = Card

            -- Check Upstream Button
            local CheckBtn = Instance.new("TextButton")
            CheckBtn.Name = "CheckBtn"
            CheckBtn.Size = UDim2.new(0, 150, 0, 24)
            CheckBtn.Position = UDim2.new(1, -245, 0, 80)
            CheckBtn.BackgroundColor3 = Theme.PrimaryBtn
            CheckBtn.BorderSizePixel = 0
            CheckBtn.Font = Enum.Font.GothamBold
            CheckBtn.TextSize = 10
            CheckBtn.TextColor3 = Theme.TextPrimary
            CheckBtn.Text = "🌐 Check Upstream"
            CheckBtn.Parent = Card

            local CheckCorner = Instance.new("UICorner")
            CheckCorner.CornerRadius = UDim.new(0, 4)
            CheckCorner.Parent = CheckBtn

            CheckBtn.MouseEnter:Connect(function()
                CheckBtn.BackgroundColor3 = Color3.fromRGB(38, 95, 165)
            end)
            CheckBtn.MouseLeave:Connect(function()
                CheckBtn.BackgroundColor3 = Theme.PrimaryBtn
            end)

            CheckBtn.MouseButton1Click:Connect(function()
                CheckBtn.Text = "Checking..."
                task.spawn(function()
                    local ok, remoteBody = pcall(function()
                        if _rawHttpGet then
                            return _rawHttpGet(game, u)
                        else
                            return game:HttpGet(u)
                        end
                    end)

                    if ok and type(remoteBody) == "string" and #remoteBody > 0 then
                        local remHash = computeSha256(remoteBody)
                        local normRemHash = computeSha256(remoteBody:gsub("\r\n", "\n"))
                        local isIdentical = (remHash == entry.hash) or (normRemHash == entry.hash)

                        if isIdentical then
                            CheckBtn.Text = "✓ Up to Date"
                            CheckBtn.TextColor3 = Theme.StatusSuccess
                            showToast(string.format("Upstream for %s is verified and identical.", scriptName), false)
                        else
                            if entry.auto_update == true then
                                CheckBtn.Text = "⚡ Auto-Updating..."
                                if localFile ~= "" and writefile then
                                    pcall(writefile, localFile, remoteBody)
                                end
                                entry.hash = remHash
                                entry.last_updated = os.time()
                                currentLedger.urls[u] = entry
                                if not currentLedger.hashes then currentLedger.hashes = {} end
                                currentLedger.hashes[remHash] = true
                                if normRemHash then currentLedger.hashes[normRemHash] = true end
                                saveLedger(currentLedger)
                                CheckBtn.Text = "⚡ Updated!"
                                CheckBtn.TextColor3 = Theme.StatusSuccess
                                showToast(string.format("Auto-applied upstream update for %s!", scriptName), false)
                                renderUrlsView()
                            else
                                CheckBtn.Text = "⚠️ Update Pending"
                                CheckBtn.TextColor3 = Theme.StatusWarning
                                showToast(string.format("Author updated %s! Approval required on next execution.", scriptName), false)
                            end
                        end
                    else
                        CheckBtn.Text = "Error Checking"
                        CheckBtn.TextColor3 = Theme.StatusDanger
                        showToast(string.format("Failed to fetch upstream URL for %s: %s", scriptName, tostring(remoteBody)), true)
                    end
                end)
            end)

            -- Copy URL Button
            local CopyBtn = Instance.new("TextButton")
            CopyBtn.Name = "CopyBtn"
            CopyBtn.Size = UDim2.new(0, 80, 0, 24)
            CopyBtn.Position = UDim2.new(1, -90, 0, 80)
            CopyBtn.BackgroundColor3 = Theme.CardSelected
            CopyBtn.BorderSizePixel = 0
            CopyBtn.Font = Enum.Font.GothamMedium
            CopyBtn.TextSize = 10
            CopyBtn.TextColor3 = Theme.TextSecondary
            CopyBtn.Text = "📋 Copy URL"
            CopyBtn.Parent = Card

            local CopyCorner = Instance.new("UICorner")
            CopyCorner.CornerRadius = UDim.new(0, 4)
            CopyCorner.Parent = CopyBtn

            CopyBtn.MouseEnter:Connect(function()
                CopyBtn.TextColor3 = Theme.TextPrimary
            end)
            CopyBtn.MouseLeave:Connect(function()
                CopyBtn.TextColor3 = Theme.TextSecondary
            end)

            CopyBtn.MouseButton1Click:Connect(function()
                if setclipboard then
                    setclipboard(u)
                    CopyBtn.Text = "Copied!"
                    task.delay(1.5, function() CopyBtn.Text = "📋 Copy URL" end)
                else
                    showToast("setclipboard not supported on executor", true)
                end
            end)
        end
    end

    if matches == 0 then
        local EmptyNotice = Instance.new("Frame")
        EmptyNotice.Size = UDim2.new(1, 0, 0, 80)
        EmptyNotice.BackgroundColor3 = Theme.TitleBar
        EmptyNotice.BorderSizePixel = 0
        EmptyNotice.Parent = UrlsScroll

        local EmptyCorner = Instance.new("UICorner")
        EmptyCorner.CornerRadius = UDim.new(0, 6)
        EmptyCorner.Parent = EmptyNotice

        local EmptyLabel = Instance.new("TextLabel")
        EmptyLabel.Size = UDim2.new(1, 0, 1, 0)
        EmptyLabel.BackgroundTransparency = 1
        EmptyLabel.Font = Enum.Font.GothamMedium
        EmptyLabel.TextSize = 12
        EmptyLabel.TextColor3 = Theme.TextSecondary
        if #urlList == 0 then
            EmptyLabel.Text = "No authorized URLs recorded yet.\nRun a script via loadstring() to authorize it at the Permission Gate."
        elseif query ~= "" then
            EmptyLabel.Text = "No authorized URLs match your search query."
        else
            EmptyLabel.Text = "No authorized URLs found."
        end
        EmptyLabel.Parent = EmptyNotice
    end
end

renderHashesView = function()
    for _, child in ipairs(HashesScroll:GetChildren()) do
        if child:IsA("GuiObject") and child ~= HashesListLayout then
            child:Destroy()
        end
    end

    local query = SearchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local hashList = {}
    for h, val in pairs(currentLedger.hashes or {}) do
        if val ~= nil and val ~= false then
            table.insert(hashList, h:lower())
        end
    end
    table.sort(hashList)

    HashesTabBtn.Text = string.format("🛡️ Return Hashes (%d)", #hashList)

    local totalUrls = 0
    if currentLedger.urls then
        for _ in pairs(currentLedger.urls) do
            totalUrls = totalUrls + 1
        end
    end
    UrlsTabBtn.Text = string.format("🔗 Authorized URLs (%d)", totalUrls)

    -- 1. Organize into Structured Script Groups
    local scriptGroups = {}
    local scriptGroupOrder = {}
    local knownScriptHashes = {}

    for u, entry in pairs(currentLedger.urls or {}) do
        local customName = entry.name
        local domain, scriptId = getUrlDisplayName(u, customName)
        local scriptTarget = customName or scriptId

        local primaryHash = entry.hash and entry.hash:lower() or nil
        local subs = {}
        if type(entry.submodules) == "table" then
            for _, sH in ipairs(entry.submodules) do
                local sHLower = sH:lower()
                table.insert(subs, sHLower)
                knownScriptHashes[sHLower] = u
            end
        end
        if primaryHash then
            knownScriptHashes[primaryHash] = u
        end

        local group = {
            url = u,
            name = scriptTarget,
            domain = domain,
            primaryHash = primaryHash,
            submodules = subs,
            autoUpdate = (entry.auto_update == true),
            lastUpdated = entry.last_updated or 0
        }
        scriptGroups[u] = group
        table.insert(scriptGroupOrder, u)
    end

    table.sort(scriptGroupOrder, function(a, b)
        return (scriptGroups[a].lastUpdated or 0) > (scriptGroups[b].lastUpdated or 0)
    end)

    -- 2. Identify Standalone / Dynamic Hashes
    local standaloneHashes = {}
    for _, h in ipairs(hashList) do
        if not knownScriptHashes[h] then
            table.insert(standaloneHashes, h)
        end
    end

    local totalRenderedCards = 0

    -- 3. Render Grouped Script Containers
    for grpIdx, u in ipairs(scriptGroupOrder) do
        local grp = scriptGroups[u]
        local subCount = #grp.submodules
        local totalSigs = (grp.primaryHash and 1 or 0) + subCount

        local matchesPrimary = (grp.primaryHash and grp.primaryHash:find(query, 1, true))
        local matchesMeta = (query == "")
            or grp.name:lower():find(query, 1, true)
            or grp.domain:lower():find(query, 1, true)
            or u:lower():find(query, 1, true)
            or matchesPrimary

        local matchedSubmodules = {}
        for sIdx, sH in ipairs(grp.submodules) do
            if query == "" or matchesMeta or sH:find(query, 1, true) then
                table.insert(matchedSubmodules, { index = sIdx, hash = sH })
            end
        end

        if matchesMeta or #matchedSubmodules > 0 then
            totalRenderedCards = totalRenderedCards + 1

            local isExpanded = (query ~= "") or (expandedScriptGroups[u] == true)

            local GroupCard = Instance.new("Frame")
            GroupCard.Name = "ScriptGroupCard_" .. grpIdx
            GroupCard.Size = UDim2.new(1, 0, 0, 0)
            GroupCard.AutomaticSize = Enum.AutomaticSize.Y
            GroupCard.BackgroundColor3 = Theme.Card
            GroupCard.BorderSizePixel = 0
            GroupCard.Parent = HashesScroll

            local GroupCorner = Instance.new("UICorner")
            GroupCorner.CornerRadius = UDim.new(0, 6)
            GroupCorner.Parent = GroupCard

            local GroupStroke = Instance.new("UIStroke")
            GroupStroke.Thickness = 1
            GroupStroke.Color = Theme.CardStroke
            GroupStroke.Parent = GroupCard

            local GroupLayout = Instance.new("UIListLayout")
            GroupLayout.SortOrder = Enum.SortOrder.LayoutOrder
            GroupLayout.Padding = UDim.new(0, 0)
            GroupLayout.Parent = GroupCard

            -- ==================================================================
            -- SECTION A: CARD HEADER BAR
            -- ==================================================================
            local HeaderBar = Instance.new("Frame")
            HeaderBar.Name = "HeaderBar"
            HeaderBar.LayoutOrder = 1
            HeaderBar.Size = UDim2.new(1, 0, 0, 44)
            HeaderBar.BackgroundColor3 = Theme.TitleBar
            HeaderBar.BorderSizePixel = 0
            HeaderBar.Parent = GroupCard

            local HeaderCorner = Instance.new("UICorner")
            HeaderCorner.CornerRadius = UDim.new(0, 6)
            HeaderCorner.Parent = HeaderBar

            -- Left Cluster: Domain Pill, Script Title, Signatures Badge (Automatic horizontal flow)
            local HeaderLeft = Instance.new("Frame")
            HeaderLeft.Name = "HeaderLeft"
            HeaderLeft.Size = UDim2.new(1, -260, 1, 0)
            HeaderLeft.Position = UDim2.new(0, 10, 0, 0)
            HeaderLeft.BackgroundTransparency = 1
            HeaderLeft.Parent = HeaderBar

            local LeftLayout = Instance.new("UIListLayout")
            LeftLayout.FillDirection = Enum.FillDirection.Horizontal
            LeftLayout.VerticalAlignment = Enum.VerticalAlignment.Center
            LeftLayout.SortOrder = Enum.SortOrder.LayoutOrder
            LeftLayout.Padding = UDim.new(0, 8)
            LeftLayout.Parent = HeaderLeft

            -- 1. Domain Pill
            local DomainPill = Instance.new("Frame")
            DomainPill.Name = "DomainPill"
            DomainPill.LayoutOrder = 1
            DomainPill.Size = UDim2.new(0, 0, 0, 20)
            DomainPill.AutomaticSize = Enum.AutomaticSize.X
            DomainPill.BackgroundColor3 = Theme.KeybindBg
            DomainPill.BorderSizePixel = 0
            DomainPill.Parent = HeaderLeft

            local DomainCorner = Instance.new("UICorner")
            DomainCorner.CornerRadius = UDim.new(0, 4)
            DomainCorner.Parent = DomainPill

            local DomainPadding = Instance.new("UIPadding")
            DomainPadding.PaddingLeft = UDim.new(0, 8)
            DomainPadding.PaddingRight = UDim.new(0, 8)
            DomainPadding.Parent = DomainPill

            local DomainLabel = Instance.new("TextLabel")
            DomainLabel.Size = UDim2.new(0, 0, 1, 0)
            DomainLabel.AutomaticSize = Enum.AutomaticSize.X
            DomainLabel.BackgroundTransparency = 1
            DomainLabel.Font = Enum.Font.GothamBold
            DomainLabel.TextSize = 10
            DomainLabel.TextColor3 = Theme.Accent
            DomainLabel.Text = grp.domain
            DomainLabel.Parent = DomainPill

            -- 2. Script Title
            local TitleLabel = Instance.new("TextLabel")
            TitleLabel.Name = "TitleLabel"
            TitleLabel.LayoutOrder = 2
            TitleLabel.Size = UDim2.new(0, 0, 1, 0)
            TitleLabel.AutomaticSize = Enum.AutomaticSize.X
            TitleLabel.BackgroundTransparency = 1
            TitleLabel.Font = Enum.Font.GothamBold
            TitleLabel.TextSize = 12
            TitleLabel.TextColor3 = Theme.TextPrimary
            TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
            TitleLabel.Text = grp.name
            TitleLabel.Parent = HeaderLeft

            -- 3. Signatures Total Badge
            local sigPillText = subCount > 0
                and string.format("🔒 %d Signatures (%d Subs)", totalSigs, subCount)
                or "🔒 1 Signature (Primary Only)"

            local SigPill = Instance.new("Frame")
            SigPill.Name = "SigPill"
            SigPill.LayoutOrder = 3
            SigPill.Size = UDim2.new(0, 0, 0, 20)
            SigPill.AutomaticSize = Enum.AutomaticSize.X
            SigPill.BackgroundColor3 = Theme.KeybindBg
            SigPill.BorderSizePixel = 0
            SigPill.Parent = HeaderLeft

            local SigCorner = Instance.new("UICorner")
            SigCorner.CornerRadius = UDim.new(0, 4)
            SigCorner.Parent = SigPill

            local SigPadding = Instance.new("UIPadding")
            SigPadding.PaddingLeft = UDim.new(0, 8)
            SigPadding.PaddingRight = UDim.new(0, 8)
            SigPadding.Parent = SigPill

            local SigLabel = Instance.new("TextLabel")
            SigLabel.Size = UDim2.new(0, 0, 1, 0)
            SigLabel.AutomaticSize = Enum.AutomaticSize.X
            SigLabel.BackgroundTransparency = 1
            SigLabel.Font = Enum.Font.GothamMedium
            SigLabel.TextSize = 10
            SigLabel.TextColor3 = Theme.KeybindText
            SigLabel.Text = sigPillText
            SigLabel.Parent = SigPill

            -- Right Cluster: Copy All Hashes + Expand/Collapse Button (Right-aligned horizontal flow)
            local HeaderRight = Instance.new("Frame")
            HeaderRight.Name = "HeaderRight"
            HeaderRight.Size = UDim2.new(0, 250, 1, 0)
            HeaderRight.Position = UDim2.new(1, -10, 0, 0)
            HeaderRight.AnchorPoint = Vector2.new(1, 0)
            HeaderRight.BackgroundTransparency = 1
            HeaderRight.Parent = HeaderBar

            local RightLayout = Instance.new("UIListLayout")
            RightLayout.FillDirection = Enum.FillDirection.Horizontal
            RightLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
            RightLayout.VerticalAlignment = Enum.VerticalAlignment.Center
            RightLayout.SortOrder = Enum.SortOrder.LayoutOrder
            RightLayout.Padding = UDim.new(0, 8)
            RightLayout.Parent = HeaderRight

            local CopyAllBtn = Instance.new("TextButton")
            CopyAllBtn.Name = "CopyAllBtn"
            CopyAllBtn.LayoutOrder = 1
            CopyAllBtn.Size = UDim2.new(0, 0, 0, 26)
            CopyAllBtn.AutomaticSize = Enum.AutomaticSize.X
            CopyAllBtn.BackgroundColor3 = Theme.CardSelected
            CopyAllBtn.BorderSizePixel = 0
            CopyAllBtn.Font = Enum.Font.GothamMedium
            CopyAllBtn.TextSize = 10
            CopyAllBtn.TextColor3 = Theme.TextPrimary
            CopyAllBtn.Text = "📋 Copy All"
            CopyAllBtn.Parent = HeaderRight

            local CopyAllCorner = Instance.new("UICorner")
            CopyAllCorner.CornerRadius = UDim.new(0, 4)
            CopyAllCorner.Parent = CopyAllBtn

            local CopyAllPadding = Instance.new("UIPadding")
            CopyAllPadding.PaddingLeft = UDim.new(0, 10)
            CopyAllPadding.PaddingRight = UDim.new(0, 10)
            CopyAllPadding.Parent = CopyAllBtn

            CopyAllBtn.MouseButton1Click:Connect(function()
                if setclipboard then
                    local allLines = {}
                    if grp.primaryHash then table.insert(allLines, grp.primaryHash) end
                    for _, sH in ipairs(grp.submodules) do table.insert(allLines, sH) end
                    setclipboard(table.concat(allLines, "\n"))
                    CopyAllBtn.Text = "✓ Copied All!"
                    task.delay(1.5, function() CopyAllBtn.Text = "📋 Copy All" end)
                end
            end)

            if subCount > 0 then
                local ToggleBtn = Instance.new("TextButton")
                ToggleBtn.Name = "ToggleBtn"
                ToggleBtn.LayoutOrder = 2
                ToggleBtn.Size = UDim2.new(0, 0, 0, 26)
                ToggleBtn.AutomaticSize = Enum.AutomaticSize.X
                ToggleBtn.BackgroundColor3 = isExpanded and Theme.CardSelected or Theme.TitleBar
                ToggleBtn.BorderSizePixel = 0
                ToggleBtn.Font = Enum.Font.GothamBold
                ToggleBtn.TextSize = 10
                ToggleBtn.TextColor3 = isExpanded and Theme.Accent or Theme.TextSecondary
                ToggleBtn.Text = isExpanded and "▲ Hide Submodules" or string.format("▼ View %d Submodules", subCount)
                ToggleBtn.Parent = HeaderRight

                local ToggleCorner = Instance.new("UICorner")
                ToggleCorner.CornerRadius = UDim.new(0, 4)
                ToggleCorner.Parent = ToggleBtn

                local TogglePadding = Instance.new("UIPadding")
                TogglePadding.PaddingLeft = UDim.new(0, 10)
                TogglePadding.PaddingRight = UDim.new(0, 10)
                TogglePadding.Parent = ToggleBtn

                ToggleBtn.MouseButton1Click:Connect(function()
                    expandedScriptGroups[u] = not (expandedScriptGroups[u] == true)
                    renderHashesView()
                end)
            end

            -- ==================================================================
            -- SECTION B: PRIMARY ENTRYPOINT ROW
            -- ==================================================================
            if grp.primaryHash then
                local PrimRow = Instance.new("Frame")
                PrimRow.Name = "PrimaryRow"
                PrimRow.LayoutOrder = 2
                PrimRow.Size = UDim2.new(1, 0, 0, 36)
                PrimRow.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
                PrimRow.BorderSizePixel = 0
                PrimRow.Parent = GroupCard

                local PrimBadge = Instance.new("TextLabel")
                PrimBadge.Size = UDim2.new(0, 140, 1, 0)
                PrimBadge.Position = UDim2.new(0, 12, 0, 0)
                PrimBadge.BackgroundTransparency = 1
                PrimBadge.Font = Enum.Font.GothamBold
                PrimBadge.TextSize = 10
                PrimBadge.TextColor3 = Theme.StatusSuccess
                PrimBadge.TextXAlignment = Enum.TextXAlignment.Left
                PrimBadge.Text = "★ Primary Entrypoint"
                PrimBadge.Parent = PrimRow

                local PrimHash = Instance.new("TextLabel")
                PrimHash.Size = UDim2.new(1, -230, 1, 0)
                PrimHash.Position = UDim2.new(0, 155, 0, 0)
                PrimHash.BackgroundTransparency = 1
                PrimHash.Font = Enum.Font.RobotoMono
                PrimHash.TextSize = 11
                PrimHash.TextColor3 = Theme.TextPrimary
                PrimHash.TextXAlignment = Enum.TextXAlignment.Left
                PrimHash.TextTruncate = Enum.TextTruncate.AtEnd
                PrimHash.Text = grp.primaryHash
                PrimHash.Parent = PrimRow

                local PrimCopyBtn = Instance.new("TextButton")
                PrimCopyBtn.Size = UDim2.new(0, 60, 0, 22)
                PrimCopyBtn.Position = UDim2.new(1, -72, 0, 7)
                PrimCopyBtn.BackgroundColor3 = Theme.CardSelected
                PrimCopyBtn.BorderSizePixel = 0
                PrimCopyBtn.Font = Enum.Font.GothamMedium
                PrimCopyBtn.TextSize = 10
                PrimCopyBtn.TextColor3 = Theme.TextSecondary
                PrimCopyBtn.Text = "Copy"
                PrimCopyBtn.Parent = PrimRow

                local PrimCopyCorner = Instance.new("UICorner")
                PrimCopyCorner.CornerRadius = UDim.new(0, 4)
                PrimCopyCorner.Parent = PrimCopyBtn

                PrimCopyBtn.MouseEnter:Connect(function()
                    PrimCopyBtn.TextColor3 = Theme.TextPrimary
                end)
                PrimCopyBtn.MouseLeave:Connect(function()
                    PrimCopyBtn.TextColor3 = Theme.TextSecondary
                end)

                PrimCopyBtn.MouseButton1Click:Connect(function()
                    if setclipboard then
                        setclipboard(grp.primaryHash)
                        PrimCopyBtn.Text = "Copied!"
                        task.delay(1.5, function() PrimCopyBtn.Text = "Copy" end)
                    end
                end)
            end

            -- ==================================================================
            -- SECTION C: SUBMODULES ACCORDION DRAWER
            -- ==================================================================
            if subCount > 0 and isExpanded then
                local Drawer = Instance.new("Frame")
                Drawer.Name = "SubmodulesDrawer"
                Drawer.LayoutOrder = 3
                Drawer.Size = UDim2.new(1, 0, 0, 0)
                Drawer.AutomaticSize = Enum.AutomaticSize.Y
                Drawer.BackgroundColor3 = Color3.fromRGB(14, 18, 24)
                Drawer.BorderSizePixel = 0
                Drawer.Parent = GroupCard

                local DrawerLayout = Instance.new("UIListLayout")
                DrawerLayout.SortOrder = Enum.SortOrder.LayoutOrder
                DrawerLayout.Padding = UDim.new(0, 2)
                DrawerLayout.Parent = Drawer

                local DrawerPadding = Instance.new("UIPadding")
                DrawerPadding.PaddingTop = UDim.new(0, 6)
                DrawerPadding.PaddingBottom = UDim.new(0, 8)
                DrawerPadding.PaddingLeft = UDim.new(0, 10)
                DrawerPadding.PaddingRight = UDim.new(0, 10)
                DrawerPadding.Parent = Drawer

                local DrawerHeader = Instance.new("Frame")
                DrawerHeader.LayoutOrder = 1
                DrawerHeader.Size = UDim2.new(1, 0, 0, 22)
                DrawerHeader.BackgroundTransparency = 1
                DrawerHeader.Parent = Drawer

                local DrawerTitle = Instance.new("TextLabel")
                DrawerTitle.Size = UDim2.new(1, 0, 1, 0)
                DrawerTitle.BackgroundTransparency = 1
                DrawerTitle.Font = Enum.Font.GothamBold
                DrawerTitle.TextSize = 10
                DrawerTitle.TextColor3 = Theme.TextSecondary
                DrawerTitle.TextXAlignment = Enum.TextXAlignment.Left
                DrawerTitle.Text = string.format("🧩 OBFUSCATED CHILD CHUNKS (%d VERIFIED AT RUNTIME)", #matchedSubmodules)
                DrawerTitle.Parent = DrawerHeader

                for subIdx, item in ipairs(matchedSubmodules) do
                    local sH = item.hash
                    local sNum = item.index

                    local SubRow = Instance.new("Frame")
                    SubRow.Name = "SubRow_" .. sNum
                    SubRow.LayoutOrder = subIdx + 1
                    SubRow.Size = UDim2.new(1, 0, 0, 24)
                    SubRow.BackgroundColor3 = (subIdx % 2 == 0) and Color3.fromRGB(20, 24, 34) or Color3.fromRGB(16, 20, 28)
                    SubRow.BorderSizePixel = 0
                    SubRow.Parent = Drawer

                    local SubRowCorner = Instance.new("UICorner")
                    SubRowCorner.CornerRadius = UDim.new(0, 4)
                    SubRowCorner.Parent = SubRow

                    local IndexLabel = Instance.new("TextLabel")
                    IndexLabel.Size = UDim2.new(0, 32, 1, 0)
                    IndexLabel.Position = UDim2.new(0, 6, 0, 0)
                    IndexLabel.BackgroundTransparency = 1
                    IndexLabel.Font = Enum.Font.GothamMedium
                    IndexLabel.TextSize = 10
                    IndexLabel.TextColor3 = Theme.TextMuted
                    IndexLabel.TextXAlignment = Enum.TextXAlignment.Left
                    IndexLabel.Text = string.format("#%02d", sNum)
                    IndexLabel.Parent = SubRow

                    local HashLabel = Instance.new("TextLabel")
                    HashLabel.Size = UDim2.new(1, -110, 1, 0)
                    HashLabel.Position = UDim2.new(0, 42, 0, 0)
                    HashLabel.BackgroundTransparency = 1
                    HashLabel.Font = Enum.Font.RobotoMono
                    HashLabel.TextSize = 10
                    HashLabel.TextColor3 = Theme.TextPrimary
                    HashLabel.TextXAlignment = Enum.TextXAlignment.Left
                    HashLabel.TextTruncate = Enum.TextTruncate.AtEnd
                    HashLabel.Text = sH
                    HashLabel.Parent = SubRow

                    local SubCopyBtn = Instance.new("TextButton")
                    SubCopyBtn.Size = UDim2.new(0, 48, 0, 18)
                    SubCopyBtn.Position = UDim2.new(1, -54, 0, 3)
                    SubCopyBtn.BackgroundColor3 = Theme.CardSelected
                    SubCopyBtn.BorderSizePixel = 0
                    SubCopyBtn.Font = Enum.Font.GothamMedium
                    SubCopyBtn.TextSize = 9
                    SubCopyBtn.TextColor3 = Theme.TextSecondary
                    SubCopyBtn.Text = "Copy"
                    SubCopyBtn.Parent = SubRow

                    local SubCopyCorner = Instance.new("UICorner")
                    SubCopyCorner.CornerRadius = UDim.new(0, 3)
                    SubCopyCorner.Parent = SubCopyBtn

                    SubCopyBtn.MouseEnter:Connect(function()
                        SubCopyBtn.TextColor3 = Theme.TextPrimary
                    end)
                    SubCopyBtn.MouseLeave:Connect(function()
                        SubCopyBtn.TextColor3 = Theme.TextSecondary
                    end)

                    SubCopyBtn.MouseButton1Click:Connect(function()
                        if setclipboard then
                            setclipboard(sH)
                            SubCopyBtn.Text = "✓"
                            task.delay(1.2, function() SubCopyBtn.Text = "Copy" end)
                        end
                    end)
                end
            end
        end
    end

    -- 4. Render Standalone / Dynamic Hashes Section (if any exist)
    if #standaloneHashes > 0 then
        local matchedStandalone = {}
        for _, sH in ipairs(standaloneHashes) do
            if query == "" or sH:find(query, 1, true) then
                table.insert(matchedStandalone, sH)
            end
        end

        if #matchedStandalone > 0 then
            totalRenderedCards = totalRenderedCards + 1

            local StandaloneCard = Instance.new("Frame")
            StandaloneCard.Name = "StandaloneHashesCard"
            StandaloneCard.Size = UDim2.new(1, 0, 0, 0)
            StandaloneCard.AutomaticSize = Enum.AutomaticSize.Y
            StandaloneCard.BackgroundColor3 = Theme.Card
            StandaloneCard.BorderSizePixel = 0
            StandaloneCard.Parent = HashesScroll

            local StandaloneCorner = Instance.new("UICorner")
            StandaloneCorner.CornerRadius = UDim.new(0, 6)
            StandaloneCorner.Parent = StandaloneCard

            local StandaloneStroke = Instance.new("UIStroke")
            StandaloneStroke.Thickness = 1
            StandaloneStroke.Color = Theme.CardStroke
            StandaloneStroke.Parent = StandaloneCard

            local StandaloneLayout = Instance.new("UIListLayout")
            StandaloneLayout.SortOrder = Enum.SortOrder.LayoutOrder
            StandaloneLayout.Padding = UDim.new(0, 4)
            StandaloneLayout.Parent = StandaloneCard

            local StandalonePadding = Instance.new("UIPadding")
            StandalonePadding.PaddingTop = UDim.new(0, 8)
            StandalonePadding.PaddingBottom = UDim.new(0, 10)
            StandalonePadding.PaddingLeft = UDim.new(0, 10)
            StandalonePadding.PaddingRight = UDim.new(0, 10)
            StandalonePadding.Parent = StandaloneCard

            local StandaloneHeader = Instance.new("Frame")
            StandaloneHeader.LayoutOrder = 1
            StandaloneHeader.Size = UDim2.new(1, 0, 0, 26)
            StandaloneHeader.BackgroundTransparency = 1
            StandaloneHeader.Parent = StandaloneCard

            local SHeaderLabel = Instance.new("TextLabel")
            SHeaderLabel.Size = UDim2.new(1, 0, 1, 0)
            SHeaderLabel.BackgroundTransparency = 1
            SHeaderLabel.Font = Enum.Font.GothamBold
            SHeaderLabel.TextSize = 11
            SHeaderLabel.TextColor3 = Theme.StatusWarning
            SHeaderLabel.TextXAlignment = Enum.TextXAlignment.Left
            SHeaderLabel.Text = string.format("⚡ Standalone & Dynamic Hashes (%d)", #matchedStandalone)
            SHeaderLabel.Parent = StandaloneHeader

            for sIdx, sH in ipairs(matchedStandalone) do
                local sRow = Instance.new("Frame")
                sRow.Name = "StandaloneRow_" .. sIdx
                sRow.LayoutOrder = sIdx + 1
                sRow.Size = UDim2.new(1, 0, 0, 28)
                sRow.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
                sRow.BorderSizePixel = 0
                sRow.Parent = StandaloneCard

                local sRowCorner = Instance.new("UICorner")
                sRowCorner.CornerRadius = UDim.new(0, 4)
                sRowCorner.Parent = sRow

                local sHashText = Instance.new("TextLabel")
                sHashText.Size = UDim2.new(1, -140, 1, 0)
                sHashText.Position = UDim2.new(0, 8, 0, 0)
                sHashText.BackgroundTransparency = 1
                sHashText.Font = Enum.Font.RobotoMono
                sHashText.TextSize = 10
                sHashText.TextColor3 = Theme.TextPrimary
                sHashText.TextXAlignment = Enum.TextXAlignment.Left
                sHashText.TextTruncate = Enum.TextTruncate.AtEnd
                sHashText.Text = sH
                sHashText.Parent = sRow

                local sCopyBtn = Instance.new("TextButton")
                sCopyBtn.Size = UDim2.new(0, 55, 0, 20)
                sCopyBtn.Position = UDim2.new(1, -125, 0, 4)
                sCopyBtn.BackgroundColor3 = Theme.CardSelected
                sCopyBtn.BorderSizePixel = 0
                sCopyBtn.Font = Enum.Font.GothamMedium
                sCopyBtn.TextSize = 9
                sCopyBtn.TextColor3 = Theme.TextSecondary
                sCopyBtn.Text = "Copy"
                sCopyBtn.Parent = sRow

                local sCopyCorner = Instance.new("UICorner")
                sCopyCorner.CornerRadius = UDim.new(0, 3)
                sCopyCorner.Parent = sCopyBtn

                sCopyBtn.MouseEnter:Connect(function()
                    sCopyBtn.TextColor3 = Theme.TextPrimary
                end)
                sCopyBtn.MouseLeave:Connect(function()
                    sCopyBtn.TextColor3 = Theme.TextSecondary
                end)

                sCopyBtn.MouseButton1Click:Connect(function()
                    if setclipboard then
                        setclipboard(sH)
                        sCopyBtn.Text = "✓"
                        task.delay(1.2, function() sCopyBtn.Text = "Copy" end)
                    end
                end)

                local sRevokeBtn = Instance.new("TextButton")
                sRevokeBtn.Size = UDim2.new(0, 60, 0, 20)
                sRevokeBtn.Position = UDim2.new(1, -65, 0, 4)
                sRevokeBtn.BackgroundColor3 = Theme.DangerBtn
                sRevokeBtn.BorderSizePixel = 0
                sRevokeBtn.Font = Enum.Font.GothamBold
                sRevokeBtn.TextSize = 9
                sRevokeBtn.TextColor3 = Theme.StatusDanger
                sRevokeBtn.Text = "Revoke"
                sRevokeBtn.Parent = sRow

                local sRevokeCorner = Instance.new("UICorner")
                sRevokeCorner.CornerRadius = UDim.new(0, 3)
                sRevokeCorner.Parent = sRevokeBtn

                sRevokeBtn.MouseButton1Click:Connect(function()
                    currentLedger.hashes[sH] = nil
                    saveLedger(currentLedger)
                    showToast("Revoked standalone hash " .. sH:sub(1, 10) .. "...", false)
                    renderHashesView()
                end)
            end
        end
    end

    -- 5. Empty View Fallback
    if totalRenderedCards == 0 then
        local EmptyNotice = Instance.new("Frame")
        EmptyNotice.Size = UDim2.new(1, 0, 0, 60)
        EmptyNotice.BackgroundColor3 = Theme.TitleBar
        EmptyNotice.BorderSizePixel = 0
        EmptyNotice.Parent = HashesScroll

        local EmptyCorner = Instance.new("UICorner")
        EmptyCorner.CornerRadius = UDim.new(0, 6)
        EmptyCorner.Parent = EmptyNotice

        local EmptyLabel = Instance.new("TextLabel")
        EmptyLabel.Size = UDim2.new(1, 0, 1, 0)
        EmptyLabel.BackgroundTransparency = 1
        EmptyLabel.Font = Enum.Font.GothamMedium
        EmptyLabel.TextSize = 12
        EmptyLabel.TextColor3 = Theme.TextSecondary
        if #hashList == 0 then
            EmptyLabel.Text = "No return hashes recorded yet."
        elseif query ~= "" then
            EmptyLabel.Text = "No return hashes match your search filter."
        else
            EmptyLabel.Text = "No return hashes found."
        end
        EmptyLabel.Parent = EmptyNotice
    end
end

-- Search Box Change Listener
SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
    SearchClearBtn.Visible = (#SearchBox.Text > 0)
    if currentTab == "urls" then
        if renderUrlsView then renderUrlsView() end
    else
        if renderHashesView then renderHashesView() end
    end
end)

-- Refresh Button Click
local function refreshData()
    currentLedger = loadLedger()
    if currentTab == "urls" then
        renderUrlsView()
    else
        renderHashesView()
    end
    showToast("Trust ledger refreshed from disk.", false)
end
RefreshBtn.MouseButton1Click:Connect(refreshData)

-- Open & Close Window
local isOpen = false
local isAnimating = false
local lastToggleTime = 0
local DEBOUNCE_DELAY = 0.35 -- 350ms debounce threshold to prevent double-firing

local function openManager()
    if isOpen or isAnimating then return end
    local now = os.clock()
    if now - lastToggleTime < DEBOUNCE_DELAY then return end
    lastToggleTime = now
    isAnimating = true
    isOpen = true

    currentLedger = loadLedger()
    Backdrop.Visible = true
    local base = restingPos or Window.Position
    Window.Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale - 0.05, base.Y.Offset)
    Window.BackgroundTransparency = 0.2
    local tween = TweenService:Create(Window, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position = base,
        BackgroundTransparency = 0
    })
    tween:Play()
    tween.Completed:Connect(function()
        isAnimating = false
    end)
    SearchBox.Text = ""
    SearchClearBtn.Visible = false
    if currentTab == "urls" then
        renderUrlsView()
    else
        renderHashesView()
    end
end

local function closeManager()
    if not isOpen or isAnimating then return end
    local now = os.clock()
    if now - lastToggleTime < DEBOUNCE_DELAY then return end
    lastToggleTime = now
    isAnimating = true
    isOpen = false

    local base = restingPos or Window.Position
    local tween = TweenService:Create(Window, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
        Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale + 0.05, base.Y.Offset),
        BackgroundTransparency = 1
    })
    tween:Play()
    tween.Completed:Connect(function()
        isAnimating = false
        if not isOpen then
            Backdrop.Visible = false
            Window.Position = base
            Window.BackgroundTransparency = 0
        end
    end)
end

local function toggleManager()
    local now = os.clock()
    if isAnimating or (now - lastToggleTime < DEBOUNCE_DELAY) then return end
    if isOpen then
        closeManager()
    else
        openManager()
    end
end

CloseBtn.MouseButton1Click:Connect(closeManager)

-- Keyboard Shortcut Listener (F6 / Shift + F6 / Escape)
local inputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if UserInputService:GetFocusedTextBox() then return end

    if input.KeyCode == Enum.KeyCode.F6 then
        toggleManager()
    elseif input.KeyCode == Enum.KeyCode.Escape and isOpen then
        closeManager()
    end
end)

-- Export Public API
getgenv().OpenOmniLoadstringManager = openManager
getgenv().CloseOmniLoadstringManager = closeManager
getgenv().ToggleOmniLoadstringManager = toggleManager
getgenv().GetOmniTrustedUrls = function() return loadLedger() end
getgenv().SetOmniUrlAutoUpdate = function(targetUrl, enabled)
    local l = loadLedger()
    if l.urls and l.urls[targetUrl] then
        l.urls[targetUrl].auto_update = (enabled == true)
        saveLedger(l)
        currentLedger = l
        if isOpen then renderUrlsView() end
        return true
    end
    return false
end
getgenv().RevokeOmniUrlTrust = function(targetUrl)
    local l = loadLedger()
    if l.urls and l.urls[targetUrl] then
        local entry = l.urls[targetUrl]
        local h = entry.hash
        l.urls[targetUrl] = nil
        if h and l.hashes then l.hashes[h] = nil end
        if type(entry.submodules) == "table" and l.hashes then
            for _, sH in ipairs(entry.submodules) do
                l.hashes[sH] = nil
            end
        end
        saveLedger(l)
        currentLedger = l
        if isOpen then renderUrlsView() end
        return true
    end
    return false
end

-- Teardown Hook for Hot-Reloading
getgenv()._OmniLoadstringManagerCleanUp = function()
    if inputConn then pcall(function() inputConn:Disconnect() end) end
    if ScreenGui then pcall(function() ScreenGui:Destroy() end) end
end

print("[OmniLoadstringManager]: Initialized successfully. Press F6 (or Shift + F6) to manage authorized loadstrings.")
