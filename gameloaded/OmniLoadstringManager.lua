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
                                sanitizedUrls[u] = {
                                    url = u,
                                    hash = safeHash:lower(),
                                    local_file = entry.local_file,
                                    first_trusted = tonumber(entry.first_trusted) or os.time(),
                                    last_updated = tonumber(entry.last_updated) or os.time(),
                                    auto_update = (entry.auto_update == true)
                                }
                            end
                        end
                    end
                end
                local sanitizedHashes = {}
                if type(data.hashes) == "table" then
                    for h, val in pairs(data.hashes) do
                        if type(h) == "string" and #h == 64 and h:match("^%x+$") and (val == true or type(val) == "string") then
                            sanitizedHashes[h:lower()] = val
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

-- Extract Domain & Short Path
local function getUrlDisplayName(url)
    if not url then return "Unknown Script" end
    local withoutProto = url:gsub("^https?://", "")
    local domain, path = withoutProto:match("^([^/]+)/(.*)$")
    domain = domain or withoutProto
    path = path or ""
    local filename = path:match("([^/]+)$") or path
    if #filename > 35 then
        filename = "..." .. filename:sub(-32)
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
Window.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
Window.BorderSizePixel = 0
Window.ClipsDescendants = true
Window.Parent = Backdrop

local WindowCorner = Instance.new("UICorner")
WindowCorner.CornerRadius = UDim.new(0, 10)
WindowCorner.Parent = Window

local WindowStroke = Instance.new("UIStroke")
WindowStroke.Thickness = 1.5
WindowStroke.Color = Color3.fromRGB(42, 54, 76)
WindowStroke.Parent = Window

-- Draggable Header
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 48)
Header.BackgroundColor3 = Color3.fromRGB(22, 28, 40)
Header.BorderSizePixel = 0
Header.Parent = Window

local HeaderBottomBorder = Instance.new("Frame")
HeaderBottomBorder.Size = UDim2.new(1, 0, 0, 1)
HeaderBottomBorder.Position = UDim2.new(0, 0, 1, -1)
HeaderBottomBorder.BackgroundColor3 = Color3.fromRGB(36, 46, 64)
HeaderBottomBorder.BorderSizePixel = 0
HeaderBottomBorder.Parent = Header

local TitleIcon = Instance.new("TextLabel")
TitleIcon.Size = UDim2.new(0, 36, 1, 0)
TitleIcon.Position = UDim2.new(0, 12, 0, 0)
TitleIcon.BackgroundTransparency = 1
TitleIcon.Font = Enum.Font.GothamBold
TitleIcon.TextSize = 20
TitleIcon.Text = "🛡️"
TitleIcon.TextColor3 = Color3.fromRGB(64, 196, 255)
TitleIcon.Parent = Header

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(0, 350, 0, 24)
TitleLabel.Position = UDim2.new(0, 48, 0, 6)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 14
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.TextColor3 = Color3.fromRGB(64, 196, 255)
TitleLabel.Text = "OMNI LOADSTRING & TRUST MANAGER"
TitleLabel.Parent = Header

local SubtitleLabel = Instance.new("TextLabel")
SubtitleLabel.Size = UDim2.new(0, 420, 0, 16)
SubtitleLabel.Position = UDim2.new(0, 48, 0, 26)
SubtitleLabel.BackgroundTransparency = 1
SubtitleLabel.Font = Enum.Font.Gotham
SubtitleLabel.TextSize = 11
SubtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
SubtitleLabel.TextColor3 = Color3.fromRGB(140, 155, 175)
SubtitleLabel.Text = "Authorized script URLs, cryptographic signatures & per-script auto-updates"
SubtitleLabel.Parent = Header

-- Keybind Pill in Header
local KeybindPill = Instance.new("Frame")
KeybindPill.Size = UDim2.new(0, 80, 0, 24)
KeybindPill.Position = UDim2.new(1, -145, 0, 12)
KeybindPill.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
KeybindPill.BorderSizePixel = 0
KeybindPill.Parent = Header

local KeybindPillCorner = Instance.new("UICorner")
KeybindPillCorner.CornerRadius = UDim.new(0, 6)
KeybindPillCorner.Parent = KeybindPill

local KeybindPillStroke = Instance.new("UIStroke")
KeybindPillStroke.Thickness = 1
KeybindPillStroke.Color = Color3.fromRGB(48, 64, 92)
KeybindPillStroke.Parent = KeybindPill

local KeybindPillText = Instance.new("TextLabel")
KeybindPillText.Size = UDim2.new(1, 0, 1, 0)
KeybindPillText.BackgroundTransparency = 1
KeybindPillText.Font = Enum.Font.Code
KeybindPillText.TextSize = 11
KeybindPillText.TextColor3 = Color3.fromRGB(180, 200, 230)
KeybindPillText.Text = "Shift + F6"
KeybindPillText.Parent = KeybindPill

-- Refresh Button
local RefreshBtn = Instance.new("TextButton")
RefreshBtn.Name = "RefreshBtn"
RefreshBtn.Size = UDim2.new(0, 28, 0, 28)
RefreshBtn.Position = UDim2.new(1, -60, 0, 10)
RefreshBtn.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
RefreshBtn.BorderSizePixel = 0
RefreshBtn.Font = Enum.Font.GothamBold
RefreshBtn.TextSize = 14
RefreshBtn.TextColor3 = Color3.fromRGB(180, 200, 230)
RefreshBtn.Text = "🔄"
RefreshBtn.Parent = Header

local RefreshBtnCorner = Instance.new("UICorner")
RefreshBtnCorner.CornerRadius = UDim.new(0, 6)
RefreshBtnCorner.Parent = RefreshBtn

-- Close Button
local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.Size = UDim2.new(0, 28, 0, 28)
CloseBtn.Position = UDim2.new(1, -30, 0, 10)
CloseBtn.BackgroundColor3 = Color3.fromRGB(36, 24, 28)
CloseBtn.BorderSizePixel = 0
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 14
CloseBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
CloseBtn.Text = "✕"
CloseBtn.Parent = Header

local CloseBtnCorner = Instance.new("UICorner")
CloseBtnCorner.CornerRadius = UDim.new(0, 6)
CloseBtnCorner.Parent = CloseBtn

-- Dragging Functionality for Header
local dragging = false
local dragInput, dragStart, startPos

Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = Window.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
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
    end
end)

-- Navigation Tabs Bar
local NavFrame = Instance.new("Frame")
NavFrame.Name = "NavFrame"
NavFrame.Size = UDim2.new(1, -24, 0, 34)
NavFrame.Position = UDim2.new(0, 12, 0, 56)
NavFrame.BackgroundColor3 = Color3.fromRGB(12, 15, 22)
NavFrame.BorderSizePixel = 0
NavFrame.Parent = Window

local NavCorner = Instance.new("UICorner")
NavCorner.CornerRadius = UDim.new(0, 8)
NavCorner.Parent = NavFrame

local NavStroke = Instance.new("UIStroke")
NavStroke.Thickness = 1
NavStroke.Color = Color3.fromRGB(28, 36, 50)
NavStroke.Parent = NavFrame

local UrlsTabBtn = Instance.new("TextButton")
UrlsTabBtn.Name = "UrlsTabBtn"
UrlsTabBtn.Size = UDim2.new(0.5, -4, 1, -4)
UrlsTabBtn.Position = UDim2.new(0, 2, 0, 2)
UrlsTabBtn.BackgroundColor3 = Color3.fromRGB(28, 38, 56)
UrlsTabBtn.BorderSizePixel = 0
UrlsTabBtn.Font = Enum.Font.GothamBold
UrlsTabBtn.TextSize = 12
UrlsTabBtn.TextColor3 = Color3.fromRGB(64, 196, 255)
UrlsTabBtn.Text = "🔗 Authorized URLs (0)"
UrlsTabBtn.Parent = NavFrame

local UrlsTabCorner = Instance.new("UICorner")
UrlsTabCorner.CornerRadius = UDim.new(0, 6)
UrlsTabCorner.Parent = UrlsTabBtn

local HashesTabBtn = Instance.new("TextButton")
HashesTabBtn.Name = "HashesTabBtn"
HashesTabBtn.Size = UDim2.new(0.5, -4, 1, -4)
HashesTabBtn.Position = UDim2.new(0.5, 2, 0, 2)
HashesTabBtn.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
HashesTabBtn.BorderSizePixel = 0
HashesTabBtn.Font = Enum.Font.GothamMedium
HashesTabBtn.TextSize = 12
HashesTabBtn.TextColor3 = Color3.fromRGB(150, 165, 185)
HashesTabBtn.Text = "🛡️ Return Hashes (0)"
HashesTabBtn.Parent = NavFrame

local HashesTabCorner = Instance.new("UICorner")
HashesTabCorner.CornerRadius = UDim.new(0, 6)
HashesTabCorner.Parent = HashesTabBtn

-- Search & Filter Bar
local SearchFrame = Instance.new("Frame")
SearchFrame.Name = "SearchFrame"
SearchFrame.Size = UDim2.new(1, -24, 0, 32)
SearchFrame.Position = UDim2.new(0, 12, 0, 96)
SearchFrame.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
SearchFrame.BorderSizePixel = 0
SearchFrame.Parent = Window

local SearchCorner = Instance.new("UICorner")
SearchCorner.CornerRadius = UDim.new(0, 6)
SearchCorner.Parent = SearchFrame

local SearchStroke = Instance.new("UIStroke")
SearchStroke.Thickness = 1
SearchStroke.Color = Color3.fromRGB(36, 46, 64)
SearchStroke.Parent = SearchFrame

local SearchIcon = Instance.new("TextLabel")
SearchIcon.Size = UDim2.new(0, 30, 1, 0)
SearchIcon.BackgroundTransparency = 1
SearchIcon.Font = Enum.Font.Gotham
SearchIcon.TextSize = 13
SearchIcon.TextColor3 = Color3.fromRGB(120, 135, 155)
SearchIcon.Text = "🔍"
SearchIcon.Parent = SearchFrame

local SearchBox = Instance.new("TextBox")
SearchBox.Name = "SearchBox"
SearchBox.Size = UDim2.new(1, -40, 1, 0)
SearchBox.Position = UDim2.new(0, 32, 0, 0)
SearchBox.BackgroundTransparency = 1
SearchBox.Font = Enum.Font.Gotham
SearchBox.TextSize = 12
SearchBox.TextColor3 = Color3.fromRGB(220, 230, 245)
SearchBox.Text = ""
SearchBox.PlaceholderColor3 = Color3.fromRGB(100, 115, 135)
SearchBox.PlaceholderText = "Search authorized URLs, domains, or return hashes..."
SearchBox.ClearTextOnFocus = false
SearchBox.TextXAlignment = Enum.TextXAlignment.Left
SearchBox.Parent = SearchFrame

-- Toast Notification Container
local Toast = Instance.new("Frame")
Toast.Name = "Toast"
Toast.Size = UDim2.new(1, -48, 0, 28)
Toast.Position = UDim2.new(0, 24, 1, -40)
Toast.BackgroundColor3 = Color3.fromRGB(24, 32, 46)
Toast.BorderSizePixel = 0
Toast.ZIndex = 10
Toast.Visible = false
Toast.Parent = Window

local ToastCorner = Instance.new("UICorner")
ToastCorner.CornerRadius = UDim.new(0, 6)
ToastCorner.Parent = Toast

local ToastStroke = Instance.new("UIStroke")
ToastStroke.Thickness = 1
ToastStroke.Color = Color3.fromRGB(64, 196, 255)
ToastStroke.Parent = Toast

local ToastText = Instance.new("TextLabel")
ToastText.Size = UDim2.new(1, -20, 1, 0)
ToastText.Position = UDim2.new(0, 10, 0, 0)
ToastText.BackgroundTransparency = 1
ToastText.Font = Enum.Font.GothamMedium
ToastText.TextSize = 11
ToastText.TextColor3 = Color3.fromRGB(220, 240, 255)
ToastText.Text = ""
ToastText.TextXAlignment = Enum.TextXAlignment.Left
ToastText.ZIndex = 11
ToastText.Parent = Toast

local toastThread = nil
local function showToast(message, isError)
    if toastThread then task.cancel(toastThread) end
    ToastText.Text = message
    if isError then
        Toast.BackgroundColor3 = Color3.fromRGB(48, 20, 24)
        ToastStroke.Color = Color3.fromRGB(255, 75, 75)
    else
        Toast.BackgroundColor3 = Color3.fromRGB(18, 36, 28)
        ToastStroke.Color = Color3.fromRGB(70, 210, 130)
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
UrlsContainer.Size = UDim2.new(1, -24, 1, -145)
UrlsContainer.Position = UDim2.new(0, 12, 0, 136)
UrlsContainer.BackgroundTransparency = 1
UrlsContainer.Parent = Window

local UrlsScroll = Instance.new("ScrollingFrame")
UrlsScroll.Name = "UrlsScroll"
UrlsScroll.Size = UDim2.new(1, 0, 1, 0)
UrlsScroll.BackgroundTransparency = 1
UrlsScroll.BorderSizePixel = 0
UrlsScroll.ScrollBarThickness = 5
UrlsScroll.ScrollBarImageColor3 = Color3.fromRGB(64, 196, 255)
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
HashesContainer.Size = UDim2.new(1, -24, 1, -145)
HashesContainer.Position = UDim2.new(0, 12, 0, 136)
HashesContainer.BackgroundTransparency = 1
HashesContainer.Visible = false
HashesContainer.Parent = Window

local HashesScroll = Instance.new("ScrollingFrame")
HashesScroll.Name = "HashesScroll"
HashesScroll.Size = UDim2.new(1, 0, 1, -36)
HashesScroll.BackgroundTransparency = 1
HashesScroll.BorderSizePixel = 0
HashesScroll.ScrollBarThickness = 5
HashesScroll.ScrollBarImageColor3 = Color3.fromRGB(64, 196, 255)
HashesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
HashesScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
HashesScroll.Parent = HashesContainer

local HashesListLayout = Instance.new("UIListLayout")
HashesListLayout.SortOrder = Enum.SortOrder.LayoutOrder
HashesListLayout.Padding = UDim.new(0, 6)
HashesListLayout.Parent = HashesScroll

local HashesFooter = Instance.new("Frame")
HashesFooter.Size = UDim2.new(1, 0, 0, 30)
HashesFooter.Position = UDim2.new(0, 0, 1, -30)
HashesFooter.BackgroundTransparency = 1
HashesFooter.Parent = HashesContainer

local PurgeOrphansBtn = Instance.new("TextButton")
PurgeOrphansBtn.Size = UDim2.new(0, 180, 1, 0)
PurgeOrphansBtn.Position = UDim2.new(1, -180, 0, 0)
PurgeOrphansBtn.BackgroundColor3 = Color3.fromRGB(42, 28, 36)
PurgeOrphansBtn.BorderSizePixel = 0
PurgeOrphansBtn.Font = Enum.Font.GothamBold
PurgeOrphansBtn.TextSize = 11
PurgeOrphansBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
PurgeOrphansBtn.Text = "🧹 Purge Orphan Hashes"
PurgeOrphansBtn.Parent = HashesFooter

local PurgeOrphansCorner = Instance.new("UICorner")
PurgeOrphansCorner.CornerRadius = UDim.new(0, 6)
PurgeOrphansCorner.Parent = PurgeOrphansBtn

-- Active View Controller
local currentTab = "urls" -- "urls" or "hashes"
local currentLedger = { version = 1, urls = {}, hashes = {} }

local renderUrlsView = nil
local renderHashesView = nil

local function switchTab(tab)
    currentTab = tab
    if tab == "urls" then
        UrlsTabBtn.BackgroundColor3 = Color3.fromRGB(28, 38, 56)
        UrlsTabBtn.TextColor3 = Color3.fromRGB(64, 196, 255)
        HashesTabBtn.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
        HashesTabBtn.TextColor3 = Color3.fromRGB(150, 165, 185)
        UrlsContainer.Visible = true
        HashesContainer.Visible = false
        if renderUrlsView then renderUrlsView() end
    else
        HashesTabBtn.BackgroundColor3 = Color3.fromRGB(28, 38, 56)
        HashesTabBtn.TextColor3 = Color3.fromRGB(64, 196, 255)
        UrlsTabBtn.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
        UrlsTabBtn.TextColor3 = Color3.fromRGB(150, 165, 185)
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

    local matches = 0
    for idx, entry in ipairs(urlList) do
        local u = entry.url
        local h = entry.hash or ""
        local localFile = entry.local_file or ""
        local domain, shortFile = getUrlDisplayName(u)

        if query == "" or u:lower():find(query, 1, true) or h:lower():find(query, 1, true) or domain:lower():find(query, 1, true) then
            matches = matches + 1

            local Card = Instance.new("Frame")
            Card.Name = "UrlCard_" .. idx
            Card.Size = UDim2.new(1, 0, 0, 102)
            Card.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
            Card.BorderSizePixel = 0
            Card.Parent = UrlsScroll

            local CardCorner = Instance.new("UICorner")
            CardCorner.CornerRadius = UDim.new(0, 8)
            CardCorner.Parent = Card

            local CardStroke = Instance.new("UIStroke")
            CardStroke.Thickness = 1
            CardStroke.Color = Color3.fromRGB(36, 46, 66)
            CardStroke.Parent = Card

            -- Domain Pill
            local DomainPill = Instance.new("Frame")
            DomainPill.Size = UDim2.new(0, math.min(#domain * 7 + 16, 180), 0, 20)
            DomainPill.Position = UDim2.new(0, 10, 0, 10)
            DomainPill.BackgroundColor3 = Color3.fromRGB(28, 38, 56)
            DomainPill.BorderSizePixel = 0
            DomainPill.Parent = Card

            local DomainCorner = Instance.new("UICorner")
            DomainCorner.CornerRadius = UDim.new(0, 4)
            DomainCorner.Parent = DomainPill

            local DomainLabel = Instance.new("TextLabel")
            DomainLabel.Size = UDim2.new(1, 0, 1, 0)
            DomainLabel.BackgroundTransparency = 1
            DomainLabel.Font = Enum.Font.GothamBold
            DomainLabel.TextSize = 10
            DomainLabel.TextColor3 = Color3.fromRGB(64, 196, 255)
            DomainLabel.Text = domain
            DomainLabel.Parent = DomainPill

            -- URL Display Label
            local UrlLabel = Instance.new("TextLabel")
            UrlLabel.Size = UDim2.new(1, -260, 0, 20)
            UrlLabel.Position = UDim2.new(0, DomainPill.Size.X.Offset + 18, 0, 10)
            UrlLabel.BackgroundTransparency = 1
            UrlLabel.Font = Enum.Font.GothamMedium
            UrlLabel.TextSize = 11
            UrlLabel.TextColor3 = Color3.fromRGB(230, 235, 245)
            UrlLabel.TextXAlignment = Enum.TextXAlignment.Left
            UrlLabel.TextTruncate = Enum.TextTruncate.AtEnd
            UrlLabel.Text = shortFile ~= "" and (shortFile .. " (" .. u .. ")") or u
            UrlLabel.Parent = Card

            -- Auto-Update Status Badge & Toggle Button
            local isAuto = (entry.auto_update == true)
            local AutoToggleBtn = Instance.new("TextButton")
            AutoToggleBtn.Name = "AutoToggleBtn"
            AutoToggleBtn.Size = UDim2.new(0, 150, 0, 24)
            AutoToggleBtn.Position = UDim2.new(1, -245, 0, 8)
            AutoToggleBtn.BackgroundColor3 = isAuto and Color3.fromRGB(25, 80, 45) or Color3.fromRGB(34, 40, 52)
            AutoToggleBtn.BorderSizePixel = 0
            AutoToggleBtn.Font = Enum.Font.GothamBold
            AutoToggleBtn.TextSize = 11
            AutoToggleBtn.TextColor3 = isAuto and Color3.fromRGB(110, 240, 150) or Color3.fromRGB(160, 175, 195)
            AutoToggleBtn.Text = isAuto and "⚡ Auto-Update: ON" or "⏸️ Auto-Update: OFF"
            AutoToggleBtn.Parent = Card

            local AutoToggleCorner = Instance.new("UICorner")
            AutoToggleCorner.CornerRadius = UDim.new(0, 6)
            AutoToggleCorner.Parent = AutoToggleBtn

            local AutoToggleStroke = Instance.new("UIStroke")
            AutoToggleStroke.Thickness = 1
            AutoToggleStroke.Color = isAuto and Color3.fromRGB(50, 150, 85) or Color3.fromRGB(50, 62, 82)
            AutoToggleStroke.Parent = AutoToggleBtn

            AutoToggleBtn.MouseButton1Click:Connect(function()
                entry.auto_update = not (entry.auto_update == true)
                currentLedger.urls[u] = entry
                local saved = saveLedger(currentLedger)
                if saved then
                    local stateStr = entry.auto_update and "ENABLED" or "DISABLED"
                    showToast(string.format("Auto-Update %s for %s", stateStr, domain), false)
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
            RevokeBtn.BackgroundColor3 = Color3.fromRGB(42, 28, 36)
            RevokeBtn.BorderSizePixel = 0
            RevokeBtn.Font = Enum.Font.GothamBold
            RevokeBtn.TextSize = 11
            RevokeBtn.TextColor3 = Color3.fromRGB(255, 110, 110)
            RevokeBtn.Text = "🗑️ Revoke"
            RevokeBtn.Parent = Card

            local RevokeCorner = Instance.new("UICorner")
            RevokeCorner.CornerRadius = UDim.new(0, 6)
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
                        RevokeBtn.BackgroundColor3 = Color3.fromRGB(42, 28, 36)
                        RevokeBtn.TextColor3 = Color3.fromRGB(255, 110, 110)
                    end)
                else
                    if revokeReset then task.cancel(revokeReset) end
                    currentLedger.urls[u] = nil
                    if entry.hash and currentLedger.hashes then
                        currentLedger.hashes[entry.hash] = nil
                    end
                    if currentLedger.hashes then
                        for hK, val in pairs(currentLedger.hashes) do
                            if val == u or val == entry.hash then
                                currentLedger.hashes[hK] = nil
                            end
                        end
                    end
                    saveLedger(currentLedger)
                    showToast(string.format("Revoked trust for %s and linked submodules.", domain), false)
                    renderUrlsView()
                end
            end)

            -- Submodules & Signatures Attribution Chip (Clickable, switches to filtered Hashes view)
            local primaryHash = entry.hash and entry.hash:lower() or nil
            local subCount = 0
            for hK, val in pairs(currentLedger.hashes or {}) do
                local hKLower = hK:lower()
                if val == u or (primaryHash and val == primaryHash) then
                    if hKLower ~= primaryHash then
                        subCount = subCount + 1
                    end
                end
            end
            local totalSigs = (primaryHash and 1 or 0) + subCount

            local SigChip = Instance.new("TextButton")
            SigChip.Name = "SigChip"
            SigChip.Size = UDim2.new(0, 235, 0, 24)
            SigChip.Position = UDim2.new(1, -245, 0, 38)
            SigChip.BackgroundColor3 = Color3.fromRGB(26, 34, 48)
            SigChip.BorderSizePixel = 0
            SigChip.Font = Enum.Font.GothamMedium
            SigChip.TextSize = 10
            SigChip.TextColor3 = Color3.fromRGB(130, 195, 255)
            if subCount > 0 then
                SigChip.Text = string.format("🧩 %d Signatures (1 Primary + %d Subs) 🔍", totalSigs, subCount)
            else
                SigChip.Text = string.format("🧩 %d Signature (Primary Only) 🔍", totalSigs)
            end
            SigChip.Parent = Card

            local SigChipCorner = Instance.new("UICorner")
            SigChipCorner.CornerRadius = UDim.new(0, 6)
            SigChipCorner.Parent = SigChip

            local SigChipStroke = Instance.new("UIStroke")
            SigChipStroke.Thickness = 1
            SigChipStroke.Color = Color3.fromRGB(44, 58, 82)
            SigChipStroke.Parent = SigChip

            SigChip.MouseButton1Click:Connect(function()
                SearchBox.Text = domain
                switchTab("hashes")
            end)

            -- Hash Label & Copy
            local HashLabel = Instance.new("TextLabel")
            HashLabel.Size = UDim2.new(0, 360, 0, 16)
            HashLabel.Position = UDim2.new(0, 12, 0, 38)
            HashLabel.BackgroundTransparency = 1
            HashLabel.Font = Enum.Font.Code
            HashLabel.TextSize = 10
            HashLabel.TextColor3 = Color3.fromRGB(140, 160, 190)
            HashLabel.TextXAlignment = Enum.TextXAlignment.Left
            local shortH = (h and #h >= 16) and (h:sub(1, 14) .. "..." .. h:sub(-8)) or (h or "N/A")
            HashLabel.Text = "SHA-256: " .. shortH
            HashLabel.Parent = Card

            -- Cache File Info & Timestamps
            local CacheLabel = Instance.new("TextLabel")
            CacheLabel.Size = UDim2.new(0, 360, 0, 16)
            CacheLabel.Position = UDim2.new(0, 12, 0, 56)
            CacheLabel.BackgroundTransparency = 1
            CacheLabel.Font = Enum.Font.Gotham
            CacheLabel.TextSize = 10
            CacheLabel.TextColor3 = Color3.fromRGB(110, 125, 145)
            CacheLabel.TextXAlignment = Enum.TextXAlignment.Left
            local fileExists = localFile ~= "" and isfile and isfile(localFile)
            local fileStat = fileExists and "✓ Cached on disk" or "⚠️ Cache missing"
            CacheLabel.Text = string.format("Cache: %s (%s)", localFile ~= "" and localFile or "None", fileStat)
            CacheLabel.Parent = Card

            local TimeLabel = Instance.new("TextLabel")
            TimeLabel.Size = UDim2.new(0, 360, 0, 16)
            TimeLabel.Position = UDim2.new(0, 12, 0, 74)
            TimeLabel.BackgroundTransparency = 1
            TimeLabel.Font = Enum.Font.Gotham
            TimeLabel.TextSize = 10
            TimeLabel.TextColor3 = Color3.fromRGB(100, 115, 135)
            TimeLabel.TextXAlignment = Enum.TextXAlignment.Left
            TimeLabel.Text = string.format("First Trusted: %s | Last Updated: %s", formatTimestamp(entry.first_trusted), formatTimestamp(entry.last_updated))
            TimeLabel.Parent = Card

            -- Check Upstream Button
            local CheckBtn = Instance.new("TextButton")
            CheckBtn.Name = "CheckBtn"
            CheckBtn.Size = UDim2.new(0, 130, 0, 22)
            CheckBtn.Position = UDim2.new(1, -225, 0, 70)
            CheckBtn.BackgroundColor3 = Color3.fromRGB(30, 38, 54)
            CheckBtn.BorderSizePixel = 0
            CheckBtn.Font = Enum.Font.GothamBold
            CheckBtn.TextSize = 10
            CheckBtn.TextColor3 = Color3.fromRGB(180, 210, 245)
            CheckBtn.Text = "🌐 Check Upstream"
            CheckBtn.Parent = Card

            local CheckCorner = Instance.new("UICorner")
            CheckCorner.CornerRadius = UDim.new(0, 5)
            CheckCorner.Parent = CheckBtn

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
                            CheckBtn.TextColor3 = Color3.fromRGB(100, 230, 130)
                            showToast(string.format("Upstream for %s is verified and identical.", domain), false)
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
                                CheckBtn.TextColor3 = Color3.fromRGB(100, 230, 130)
                                showToast(string.format("Auto-applied upstream update for %s!", domain), false)
                                renderUrlsView()
                            else
                                CheckBtn.Text = "⚠️ Update Pending"
                                CheckBtn.TextColor3 = Color3.fromRGB(255, 170, 60)
                                showToast(string.format("Author updated %s! Approval required on next execution.", domain), false)
                            end
                        end
                    else
                        CheckBtn.Text = "Error Checking"
                        CheckBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
                        showToast(string.format("Failed to fetch upstream URL: %s", tostring(remoteBody)), true)
                    end
                end)
            end)

            -- Copy URL Button
            local CopyBtn = Instance.new("TextButton")
            CopyBtn.Name = "CopyBtn"
            CopyBtn.Size = UDim2.new(0, 80, 0, 22)
            CopyBtn.Position = UDim2.new(1, -90, 0, 70)
            CopyBtn.BackgroundColor3 = Color3.fromRGB(26, 32, 44)
            CopyBtn.BorderSizePixel = 0
            CopyBtn.Font = Enum.Font.GothamMedium
            CopyBtn.TextSize = 10
            CopyBtn.TextColor3 = Color3.fromRGB(160, 180, 205)
            CopyBtn.Text = "📋 Copy URL"
            CopyBtn.Parent = Card

            local CopyCorner = Instance.new("UICorner")
            CopyCorner.CornerRadius = UDim.new(0, 5)
            CopyCorner.Parent = CopyBtn

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
        EmptyNotice.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
        EmptyNotice.BorderSizePixel = 0
        EmptyNotice.Parent = UrlsScroll

        local EmptyCorner = Instance.new("UICorner")
        EmptyCorner.CornerRadius = UDim.new(0, 8)
        EmptyCorner.Parent = EmptyNotice

        local EmptyLabel = Instance.new("TextLabel")
        EmptyLabel.Size = UDim2.new(1, 0, 1, 0)
        EmptyLabel.BackgroundTransparency = 1
        EmptyLabel.Font = Enum.Font.GothamMedium
        EmptyLabel.TextSize = 12
        EmptyLabel.TextColor3 = Color3.fromRGB(140, 155, 175)
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
            table.insert(hashList, h)
        end
    end
    table.sort(hashList)

    HashesTabBtn.Text = string.format("🛡️ Return Hashes (%d)", #hashList)

    -- Map hashes to URLs and roles
    local hashToUrl = {}
    local hashRole = {} -- "primary", "submodule", "standalone"

    -- 1. Register all primary entry hashes from URLs
    for u, entry in pairs(currentLedger.urls or {}) do
        if entry.hash then
            local pHash = entry.hash:lower()
            hashToUrl[pHash] = u
            hashRole[pHash] = "primary"
        end
    end

    -- 2. Register submodule hashes (where val is a URL string)
    for h, val in pairs(currentLedger.hashes or {}) do
        local hLower = h:lower()
        if type(val) == "string" and #val > 0 then
            hashToUrl[hLower] = val
            if not hashRole[hLower] then
                hashRole[hLower] = "submodule"
            end
        elseif not hashRole[hLower] then
            hashRole[hLower] = "standalone"
        end
    end

    local matches = 0
    for idx, h in ipairs(hashList) do
        local hLower = h:lower()
        local linkedUrl = hashToUrl[hLower]
        local domain = linkedUrl and (getUrlDisplayName(linkedUrl)) or nil
        local matchesQuery = (query == "")
            or hLower:find(query, 1, true)
            or (linkedUrl and linkedUrl:lower():find(query, 1, true))
            or (domain and domain:lower():find(query, 1, true))

        if matchesQuery then
            matches = matches + 1

            local Row = Instance.new("Frame")
            Row.Name = "HashRow_" .. idx
            Row.Size = UDim2.new(1, 0, 0, 50)
            Row.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
            Row.BorderSizePixel = 0
            Row.Parent = HashesScroll

            local RowCorner = Instance.new("UICorner")
            RowCorner.CornerRadius = UDim.new(0, 6)
            RowCorner.Parent = Row

            local RowStroke = Instance.new("UIStroke")
            RowStroke.Thickness = 1
            RowStroke.Color = Color3.fromRGB(34, 44, 62)
            RowStroke.Parent = Row

            local role = hashRole[hLower] or "standalone"
            local domText = domain or "Direct Content"

            -- Line 1: Domain Pill
            local Pill = Instance.new("Frame")
            local pillWidth = math.min(#domText * 7 + 14, 160)
            Pill.Size = UDim2.new(0, pillWidth, 0, 18)
            Pill.Position = UDim2.new(0, 10, 0, 6)
            Pill.BackgroundColor3 = linkedUrl and Color3.fromRGB(28, 38, 56) or Color3.fromRGB(42, 36, 26)
            Pill.BorderSizePixel = 0
            Pill.Parent = Row

            local PillCorner = Instance.new("UICorner")
            PillCorner.CornerRadius = UDim.new(0, 4)
            PillCorner.Parent = Pill

            local PillLabel = Instance.new("TextLabel")
            PillLabel.Size = UDim2.new(1, 0, 1, 0)
            PillLabel.BackgroundTransparency = 1
            PillLabel.Font = Enum.Font.GothamBold
            PillLabel.TextSize = 10
            PillLabel.TextColor3 = linkedUrl and Color3.fromRGB(64, 196, 255) or Color3.fromRGB(255, 190, 80)
            PillLabel.Text = domText
            PillLabel.Parent = Pill

            -- Line 1: Relationship Badge
            local RelLabel = Instance.new("TextLabel")
            RelLabel.Size = UDim2.new(1, -pillWidth - 170, 0, 18)
            RelLabel.Position = UDim2.new(0, pillWidth + 18, 0, 6)
            RelLabel.BackgroundTransparency = 1
            RelLabel.Font = Enum.Font.GothamMedium
            RelLabel.TextSize = 10
            RelLabel.TextXAlignment = Enum.TextXAlignment.Left
            RelLabel.TextTruncate = Enum.TextTruncate.AtEnd

            if role == "primary" then
                RelLabel.TextColor3 = Color3.fromRGB(100, 230, 130)
                RelLabel.Text = "★ Primary Entrypoint"
            elseif role == "submodule" then
                RelLabel.TextColor3 = Color3.fromRGB(180, 195, 255)
                RelLabel.Text = "🧩 Submodule of " .. domText
            else
                RelLabel.TextColor3 = Color3.fromRGB(150, 165, 185)
                RelLabel.Text = "⚡ Standalone / Dynamic Hash"
            end
            RelLabel.Parent = Row

            -- Line 2: Monospace SHA-256 Hash
            local HashText = Instance.new("TextLabel")
            HashText.Size = UDim2.new(1, -165, 0, 18)
            HashText.Position = UDim2.new(0, 10, 0, 27)
            HashText.BackgroundTransparency = 1
            HashText.Font = Enum.Font.Code
            HashText.TextSize = 11
            HashText.TextColor3 = Color3.fromRGB(200, 215, 240)
            HashText.TextXAlignment = Enum.TextXAlignment.Left
            HashText.TextTruncate = Enum.TextTruncate.AtEnd
            HashText.Text = hLower
            HashText.Parent = Row

            -- Buttons on Right
            local CopyHashBtn = Instance.new("TextButton")
            CopyHashBtn.Size = UDim2.new(0, 65, 0, 26)
            CopyHashBtn.Position = UDim2.new(1, -145, 0, 12)
            CopyHashBtn.BackgroundColor3 = Color3.fromRGB(28, 36, 50)
            CopyHashBtn.BorderSizePixel = 0
            CopyHashBtn.Font = Enum.Font.GothamMedium
            CopyHashBtn.TextSize = 10
            CopyHashBtn.TextColor3 = Color3.fromRGB(160, 185, 215)
            CopyHashBtn.Text = "📋 Copy"
            CopyHashBtn.Parent = Row

            local CopyCorner = Instance.new("UICorner")
            CopyCorner.CornerRadius = UDim.new(0, 5)
            CopyCorner.Parent = CopyHashBtn

            CopyHashBtn.MouseButton1Click:Connect(function()
                if setclipboard then
                    setclipboard(hLower)
                    CopyHashBtn.Text = "Copied!"
                    task.delay(1.5, function() CopyHashBtn.Text = "📋 Copy" end)
                end
            end)

            local RevokeHashBtn = Instance.new("TextButton")
            RevokeHashBtn.Size = UDim2.new(0, 65, 0, 26)
            RevokeHashBtn.Position = UDim2.new(1, -75, 0, 12)
            RevokeHashBtn.BackgroundColor3 = Color3.fromRGB(42, 28, 34)
            RevokeHashBtn.BorderSizePixel = 0
            RevokeHashBtn.Font = Enum.Font.GothamBold
            RevokeHashBtn.TextSize = 10
            RevokeHashBtn.TextColor3 = Color3.fromRGB(255, 110, 110)
            RevokeHashBtn.Text = "Revoke"
            RevokeHashBtn.Parent = Row

            local RevokeCorner = Instance.new("UICorner")
            RevokeCorner.CornerRadius = UDim.new(0, 5)
            RevokeCorner.Parent = RevokeHashBtn

            RevokeHashBtn.MouseButton1Click:Connect(function()
                currentLedger.hashes[h] = nil
                currentLedger.hashes[hLower] = nil
                saveLedger(currentLedger)
                showToast("Revoked signature hash " .. hLower:sub(1, 10) .. "...", false)
                renderHashesView()
            end)
        end
    end

    if matches == 0 then
        local EmptyNotice = Instance.new("Frame")
        EmptyNotice.Size = UDim2.new(1, 0, 0, 60)
        EmptyNotice.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
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
        EmptyLabel.TextColor3 = Color3.fromRGB(140, 155, 175)
        if #hashList == 0 then
            EmptyLabel.Text = "No return hashes recorded yet."
        elseif query ~= "" then
            EmptyLabel.Text = "No approved hashes match your filter."
        else
            EmptyLabel.Text = "No return hashes found."
        end
        EmptyLabel.Parent = EmptyNotice
    end
end

-- Purge Orphan Hashes
PurgeOrphansBtn.MouseButton1Click:Connect(function()
    local activeUrls = currentLedger.urls or {}
    local activePrimaryHashes = {}
    for u, entry in pairs(activeUrls) do
        if entry.hash then
            activePrimaryHashes[entry.hash:lower()] = true
        end
    end

    local purgedCount = 0
    for h, val in pairs(currentLedger.hashes or {}) do
        local isOrphan = false
        if type(val) == "string" and #val > 0 then
            -- Submodule: orphan if its parent URL is no longer registered in activeUrls
            if not activeUrls[val] then
                isOrphan = true
            end
        else
            -- Standalone / legacy: orphan if not matching any active URL's primary hash
            if not activePrimaryHashes[h:lower()] then
                isOrphan = true
            end
        end

        if isOrphan then
            currentLedger.hashes[h] = nil
            purgedCount = purgedCount + 1
        end
    end

    if purgedCount > 0 then
        saveLedger(currentLedger)
        showToast(string.format("Purged %d orphan signature hash(es).", purgedCount), false)
        renderHashesView()
    else
        showToast("No orphan hashes found; all signatures belong to active URLs.", false)
    end
end)

-- Search Box Change Listener
SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
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
    Window.Position = UDim2.new(0.5, -360, 0.45, -280)
    Window.BackgroundTransparency = 0.2
    local tween = TweenService:Create(Window, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position = UDim2.new(0.5, -360, 0.5, -280),
        BackgroundTransparency = 0
    })
    tween:Play()
    tween.Completed:Connect(function()
        isAnimating = false
    end)
    SearchBox.Text = ""
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

    local tween = TweenService:Create(Window, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
        Position = UDim2.new(0.5, -360, 0.55, -280),
        BackgroundTransparency = 1
    })
    tween:Play()
    tween.Completed:Connect(function()
        isAnimating = false
        if not isOpen then
            Backdrop.Visible = false
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
        local h = l.urls[targetUrl].hash
        l.urls[targetUrl] = nil
        if h and l.hashes then l.hashes[h] = nil end
        if l.hashes then
            for hashKey, val in pairs(l.hashes) do
                if val == targetUrl or val == h then
                    l.hashes[hashKey] = nil
                end
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
