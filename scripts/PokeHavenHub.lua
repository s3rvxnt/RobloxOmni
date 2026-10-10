--[[
    Poke Haven Luxury Hub v1.0
    Game: [🎃] Poke Haven 🔊 18+ (PlaceId: 16331682055)
    Features:
      • 📍 Waypoints & Player Teleporter (Docks, Bar, Bull, Pool, Boxing, Campfire, Cave, Piano)
      • 🎣 Auto-Fisher & Instant Auto-Sell (Automated casting, perfect minigame auto-catch, instant doubloons)
      • 🐂 Mechanical Bull Autoplay & Campfire Marshmallow Auto-Roaster (100% perfect golden roast)
      • 🍸 Anti-Drunk Sobriety Guard (Blocks inverted controls, slippery ice feet, camera wobble)
      • ⚡ Player Utilities (WalkSpeed, JumpPower, Noclip, Infinite Jump, Ragdoll, Emote Player)
--]]

-- Clean up any existing hub
if getgenv()._PokeHavenHubCleanUp then
    pcall(getgenv()._PokeHavenHubCleanUp)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local lp = Players.LocalPlayer
local mouse = lp:GetMouse()
local camera = workspace.CurrentCamera

-- Parent detection
local guiParent = nil
if type(gethui) == "function" then
    guiParent = gethui()
else
    local ok, res = pcall(function() return CoreGui end)
    guiParent = (ok and res) or lp:WaitForChild("PlayerGui")
end

-- State variables
local hubConnections = {}
local autoFishRunning = false
local autoSellRunning = false
local antiDrunkEnabled = true
local bullAutoplayEnabled = false
local noclipEnabled = false
local infJumpEnabled = false
local currentSpectatingPlayer = nil

local defaultWalkSpeed = 16
local defaultJumpPower = 50
local currentWalkSpeed = 16
local currentJumpPower = 50

-- Coordinates Map
local WAYPOINTS = {
    { name = "🎣 Fishing Docks", pos = Vector3.new(284.7, 6.0, 223.6) },
    { name = "🍸 The Bar Counter", pos = Vector3.new(-151.0, 17.6, 145.9) },
    { name = "🎱 8-Ball Pool Hall", pos = Vector3.new(-214.2, 11.0, 334.3) },
    { name = "🐂 Mechanical Bull", pos = Vector3.new(-212.9, 8.3, 254.0) },
    { name = "🥊 Boxing Ring", pos = Vector3.new(-162.3, 14.2, 217.8) },
    { name = "🏕️ Campfire & Marshmallows", pos = Vector3.new(-228.3, 134.7, -22.5) },
    { name = "🎹 Grand Piano Lounge", pos = Vector3.new(-274.9, 5.9, 105.8) },
    { name = "💎 Secret Cave", pos = Vector3.new(299.1, 92.9, -46.9) },
    { name = "🏄 Ocean Shore", pos = Vector3.new(150.0, 3.0, 260.0) },
}

-- Notification Toast Function
local function sendToast(title, msg, duration)
    pcall(function()
        local StarterGui = game:GetService("StarterGui")
        StarterGui:SetCore("SendNotification", {
            Title = title or "Poke Haven Hub",
            Text = msg or "",
            Duration = duration or 3
        })
    end)
end

-- Teleport helper
local function safeTeleport(pos)
    local char = lp.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        char.HumanoidRootPart.CFrame = CFrame.new(pos + Vector3.new(0, 3.5, 0))
    end
end

-- ==============================================================================
-- GUI CONSTRUCTION
-- ==============================================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "PokeHaven_Luxury_Hub"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = guiParent

-- Floating Toggle Pill Button (For mobile/mouse reopening)
local TogglePill = Instance.new("TextButton")
TogglePill.Name = "TogglePill"
TogglePill.Size = UDim2.new(0, 120, 0, 32)
TogglePill.Position = UDim2.new(0, 20, 0.45, 0)
TogglePill.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
TogglePill.TextColor3 = Color3.fromRGB(0, 230, 255)
TogglePill.Text = "⚡ POKE HUB"
TogglePill.Font = Enum.Font.GothamBold
TogglePill.TextSize = 12
TogglePill.BorderSizePixel = 0
TogglePill.AutoButtonColor = false
TogglePill.Parent = ScreenGui

local PillCorner = Instance.new("UICorner")
PillCorner.CornerRadius = UDim.new(0, 16)
PillCorner.Parent = TogglePill

local PillStroke = Instance.new("UIStroke")
PillStroke.Color = Color3.fromRGB(0, 210, 255)
PillStroke.Thickness = 1.5
PillStroke.Parent = TogglePill

-- Main Window Frame
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 580, 0, 390)
MainFrame.Position = UDim2.new(0.5, -290, 0.5, -195)
MainFrame.BackgroundColor3 = Color3.fromRGB(16, 18, 27)
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 12)
MainCorner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = Color3.fromRGB(45, 55, 82)
MainStroke.Thickness = 1.5
MainStroke.Parent = MainFrame

-- Topbar
local Topbar = Instance.new("Frame")
Topbar.Name = "Topbar"
Topbar.Size = UDim2.new(1, 0, 0, 42)
Topbar.BackgroundColor3 = Color3.fromRGB(22, 26, 40)
Topbar.BorderSizePixel = 0
Topbar.Parent = MainFrame

local TopbarCorner = Instance.new("UICorner")
TopbarCorner.CornerRadius = UDim.new(0, 12)
TopbarCorner.Parent = Topbar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Name = "TitleLabel"
TitleLabel.Text = "⚡ POKE HAVEN LUXURY HUB"
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 14
TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TitleLabel.Size = UDim2.new(0, 250, 1, 0)
TitleLabel.Position = UDim2.new(0, 16, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Topbar

local SubtitleLabel = Instance.new("TextLabel")
SubtitleLabel.Name = "SubtitleLabel"
SubtitleLabel.Text = "v1.0 • All-in-One [RightShift]"
SubtitleLabel.Font = Enum.Font.Gotham
SubtitleLabel.TextSize = 11
SubtitleLabel.TextColor3 = Color3.fromRGB(0, 215, 255)
SubtitleLabel.Size = UDim2.new(0, 180, 1, 0)
SubtitleLabel.Position = UDim2.new(0, 235, 0, 0)
SubtitleLabel.BackgroundTransparency = 1
SubtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
SubtitleLabel.Parent = Topbar

-- Close & Minimize Buttons
local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.Text = "✕"
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 14
CloseBtn.TextColor3 = Color3.fromRGB(255, 110, 110)
CloseBtn.Size = UDim2.new(0, 32, 0, 32)
CloseBtn.Position = UDim2.new(1, -38, 0, 5)
CloseBtn.BackgroundColor3 = Color3.fromRGB(35, 25, 35)
CloseBtn.BorderSizePixel = 0
CloseBtn.Parent = Topbar
local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 6)
CloseCorner.Parent = CloseBtn

local MinBtn = Instance.new("TextButton")
MinBtn.Name = "MinBtn"
MinBtn.Text = "—"
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 12
MinBtn.TextColor3 = Color3.fromRGB(200, 210, 240)
MinBtn.Size = UDim2.new(0, 32, 0, 32)
MinBtn.Position = UDim2.new(1, -74, 0, 5)
MinBtn.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
MinBtn.BorderSizePixel = 0
MinBtn.Parent = Topbar
local MinCorner = Instance.new("UICorner")
MinCorner.CornerRadius = UDim.new(0, 6)
MinCorner.Parent = MinBtn

-- Smooth Dragging System
local dragging, dragInput, dragStart, startPos
Topbar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

Topbar.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end)

-- Sidebar Navigation
local Sidebar = Instance.new("Frame")
Sidebar.Name = "Sidebar"
Sidebar.Size = UDim2.new(0, 140, 1, -42)
Sidebar.Position = UDim2.new(0, 0, 0, 42)
Sidebar.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
Sidebar.BorderSizePixel = 0
Sidebar.Parent = MainFrame

local SidebarLayout = Instance.new("UIListLayout")
SidebarLayout.SortOrder = Enum.SortOrder.LayoutOrder
SidebarLayout.Padding = UDim.new(0, 4)
SidebarLayout.Parent = Sidebar

local SidebarPad = Instance.new("UIPadding")
SidebarPad.PaddingTop = UDim.new(0, 8)
SidebarPad.PaddingLeft = UDim.new(0, 8)
SidebarPad.PaddingRight = UDim.new(0, 8)
SidebarPad.Parent = Sidebar

-- Content Container
local ContentContainer = Instance.new("Frame")
ContentContainer.Name = "ContentContainer"
ContentContainer.Size = UDim2.new(1, -140, 1, -42)
ContentContainer.Position = UDim2.new(0, 140, 0, 42)
ContentContainer.BackgroundColor3 = Color3.fromRGB(16, 18, 27)
ContentContainer.BorderSizePixel = 0
ContentContainer.Parent = MainFrame

-- Tab Frames Table
local tabButtons = {}
local tabPages = {}

local function createTabPage(name)
    local page = Instance.new("ScrollingFrame")
    page.Name = name .. "Page"
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 4
    page.ScrollBarImageColor3 = Color3.fromRGB(60, 75, 110)
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.Visible = false
    page.Parent = ContentContainer

    local pageLayout = Instance.new("UIListLayout")
    pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
    pageLayout.Padding = UDim.new(0, 10)
    pageLayout.Parent = page

    local pagePad = Instance.new("UIPadding")
    pagePad.PaddingTop = UDim.new(0, 12)
    pagePad.PaddingBottom = UDim.new(0, 12)
    pagePad.PaddingLeft = UDim.new(0, 12)
    pagePad.PaddingRight = UDim.new(0, 12)
    pagePad.Parent = page

    return page
end

local function addTabButton(name, icon, order)
    local btn = Instance.new("TextButton")
    btn.Name = name .. "TabBtn"
    btn.Size = UDim2.new(1, 0, 0, 36)
    btn.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
    btn.TextColor3 = Color3.fromRGB(160, 175, 205)
    btn.Text = icon .. " " .. name
    btn.Font = Enum.Font.GothamMedium
    btn.TextSize = 12
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.LayoutOrder = order
    btn.Parent = Sidebar

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 6)
    btnCorner.Parent = btn

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 10)
    pad.Parent = btn

    tabButtons[name] = btn
    local page = createTabPage(name)
    tabPages[name] = page

    btn.MouseButton1Click:Connect(function()
        for tName, tBtn in pairs(tabButtons) do
            local isCurrent = (tName == name)
            tBtn.BackgroundColor3 = isCurrent and Color3.fromRGB(35, 45, 75) or Color3.fromRGB(24, 28, 42)
            tBtn.TextColor3 = isCurrent and Color3.fromRGB(0, 230, 255) or Color3.fromRGB(160, 175, 205)
            tabPages[tName].Visible = isCurrent
        end
    end)

    return page
end

-- Reusable UI Component Builders
local function createSectionHeader(page, title, order)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 20)
    lbl.BackgroundTransparency = 1
    lbl.Text = title:upper()
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 11
    lbl.TextColor3 = Color3.fromRGB(120, 140, 180)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.LayoutOrder = order
    lbl.Parent = page
    return lbl
end

local function createButton(page, text, callback, order, customColor)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 34)
    btn.BackgroundColor3 = customColor or Color3.fromRGB(30, 36, 56)
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Text = text
    btn.Font = Enum.Font.GothamMedium
    btn.TextSize = 12
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = true
    btn.LayoutOrder = order
    btn.Parent = page

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn

    btn.MouseButton1Click:Connect(function()
        pcall(callback)
    end)
    return btn
end

local function createToggle(page, labelText, defaultState, callback, order)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, 0, 0, 36)
    container.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
    container.BorderSizePixel = 0
    container.LayoutOrder = order
    container.Parent = page

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = container

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -60, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(220, 230, 250)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = container

    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.new(0, 46, 0, 24)
    toggleBtn.Position = UDim2.new(1, -54, 0.5, -12)
    toggleBtn.BackgroundColor3 = defaultState and Color3.fromRGB(0, 180, 220) or Color3.fromRGB(50, 56, 75)
    toggleBtn.Text = defaultState and "ON" or "OFF"
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 11
    toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Parent = container

    local tCorner = Instance.new("UICorner")
    tCorner.CornerRadius = UDim.new(0, 12)
    tCorner.Parent = toggleBtn

    local state = defaultState
    toggleBtn.MouseButton1Click:Connect(function()
        state = not state
        toggleBtn.BackgroundColor3 = state and Color3.fromRGB(0, 180, 220) or Color3.fromRGB(50, 56, 75)
        toggleBtn.Text = state and "ON" or "OFF"
        pcall(callback, state)
    end)

    return container
end

-- ==============================================================================
-- TAB 1: 📍 WAYPOINTS
-- ==============================================================================
local waypointsPage = addTabButton("Waypoints", "📍", 1)

createSectionHeader(waypointsPage, "Map Fast Travel", 1)

local wpGrid = Instance.new("Frame")
wpGrid.Size = UDim2.new(1, 0, 0, 0)
wpGrid.AutomaticSize = Enum.AutomaticSize.Y
wpGrid.BackgroundTransparency = 1
wpGrid.LayoutOrder = 2
wpGrid.Parent = waypointsPage

local gridLayout = Instance.new("UIGridLayout")
gridLayout.CellSize = UDim2.new(0.485, 0, 0, 34)
gridLayout.CellPadding = UDim2.new(0.03, 0, 0, 6)
gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
gridLayout.Parent = wpGrid

for idx, wp in ipairs(WAYPOINTS) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 1, 0)
    btn.BackgroundColor3 = Color3.fromRGB(26, 32, 50)
    btn.TextColor3 = Color3.fromRGB(210, 225, 255)
    btn.Text = wp.name
    btn.Font = Enum.Font.GothamMedium
    btn.TextSize = 11
    btn.BorderSizePixel = 0
    btn.LayoutOrder = idx
    btn.Parent = wpGrid

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn

    btn.MouseButton1Click:Connect(function()
        safeTeleport(wp.pos)
        sendToast("Waypoints", "Teleported to " .. wp.name, 2)
    end)
end

createSectionHeader(waypointsPage, "Player Teleport & Spectate", 3)

local playerSelectContainer = Instance.new("Frame")
playerSelectContainer.Size = UDim2.new(1, 0, 0, 36)
playerSelectContainer.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
playerSelectContainer.BorderSizePixel = 0
playerSelectContainer.LayoutOrder = 4
playerSelectContainer.Parent = waypointsPage
local pCorner = Instance.new("UICorner")
pCorner.CornerRadius = UDim.new(0, 6)
pCorner.Parent = playerSelectContainer

local selectedPlayerName = nil

local pInput = Instance.new("TextBox")
pInput.Size = UDim2.new(1, -20, 1, 0)
pInput.Position = UDim2.new(0, 10, 0, 0)
pInput.BackgroundTransparency = 1
pInput.PlaceholderText = "Type player name or display name..."
pInput.PlaceholderColor3 = Color3.fromRGB(120, 135, 165)
pInput.Text = ""
pInput.TextColor3 = Color3.fromRGB(255, 255, 255)
pInput.Font = Enum.Font.Gotham
pInput.TextSize = 12
pInput.TextXAlignment = Enum.TextXAlignment.Left
pInput.Parent = playerSelectContainer

local function findTargetPlayer(query)
    if not query or query == "" then return nil end
    local q = query:lower()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            if p.Name:lower():find(q) or p.DisplayName:lower():find(q) then
                return p
            end
        end
    end
    return nil
end

local pActionsFrame = Instance.new("Frame")
pActionsFrame.Size = UDim2.new(1, 0, 0, 34)
pActionsFrame.BackgroundTransparency = 1
pActionsFrame.LayoutOrder = 5
pActionsFrame.Parent = waypointsPage

local tpBtn = Instance.new("TextButton")
tpBtn.Size = UDim2.new(0.485, 0, 1, 0)
tpBtn.Position = UDim2.new(0, 0, 0, 0)
tpBtn.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
tpBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
tpBtn.Text = "🚀 Teleport to Player"
tpBtn.Font = Enum.Font.GothamMedium
tpBtn.TextSize = 11
tpBtn.BorderSizePixel = 0
tpBtn.Parent = pActionsFrame
local tpCorner = Instance.new("UICorner")
tpCorner.CornerRadius = UDim.new(0, 6)
tpCorner.Parent = tpBtn

tpBtn.MouseButton1Click:Connect(function()
    local target = findTargetPlayer(pInput.Text)
    if target and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
        safeTeleport(target.Character.HumanoidRootPart.Position)
        sendToast("Player TP", "Teleported to " .. target.DisplayName, 2)
    else
        sendToast("Player TP", "Player not found or character not loaded", 2)
    end
end)

local spectateBtn = Instance.new("TextButton")
spectateBtn.Size = UDim2.new(0.485, 0, 1, 0)
spectateBtn.Position = UDim2.new(0.515, 0, 0, 0)
spectateBtn.BackgroundColor3 = Color3.fromRGB(45, 40, 70)
spectateBtn.TextColor3 = Color3.fromRGB(220, 200, 255)
spectateBtn.Text = "👁️ Spectate / Reset"
spectateBtn.Font = Enum.Font.GothamMedium
spectateBtn.TextSize = 11
spectateBtn.BorderSizePixel = 0
spectateBtn.Parent = pActionsFrame
local specCorner = Instance.new("UICorner")
specCorner.CornerRadius = UDim.new(0, 6)
specCorner.Parent = spectateBtn

spectateBtn.MouseButton1Click:Connect(function()
    if currentSpectatingPlayer then
        currentSpectatingPlayer = nil
        if lp.Character and lp.Character:FindFirstChild("Humanoid") then
            camera.CameraSubject = lp.Character.Humanoid
        end
        spectateBtn.Text = "👁️ Spectate / Reset"
        sendToast("Spectate", "Camera returned to you", 2)
    else
        local target = findTargetPlayer(pInput.Text)
        if target and target.Character and target.Character:FindFirstChild("Humanoid") then
            currentSpectatingPlayer = target
            camera.CameraSubject = target.Character.Humanoid
            spectateBtn.Text = "👁️ Reset View"
            sendToast("Spectate", "Now spectating " .. target.DisplayName, 2)
        else
            sendToast("Spectate", "Player not found", 2)
        end
    end
end)

-- ==============================================================================
-- TAB 2: 🎣 AUTO-FISHER
-- ==============================================================================
local fishPage = addTabButton("Auto-Fish", "🎣", 2)

createSectionHeader(fishPage, "Automated Fishing & Catching", 1)

createToggle(fishPage, "🎣 Auto-Fish (Auto-Cast & Instant Reel)", false, function(enabled)
    autoFishRunning = enabled
    if enabled then
        sendToast("Auto-Fish", "Active! Equipping rod and casting...", 2)
        task.spawn(function()
            local toolAction = ReplicatedStorage:FindFirstChild("Remotes") and ReplicatedStorage.Remotes:FindFirstChild("ToolAction")
            while autoFishRunning do
                local char = lp.Character
                local backpack = lp:FindFirstChild("Backpack")
                
                -- Ensure rod is equipped
                local rod = char and char:FindFirstChildOfClass("Tool")
                if not (rod and rod.Name:lower():find("rod")) and backpack then
                    for _, t in ipairs(backpack:GetChildren()) do
                        if t.Name:lower():find("rod") and char:FindFirstChild("Humanoid") then
                            char.Humanoid:EquipTool(t)
                            task.wait(0.3)
                            break
                        end
                    end
                end

                -- Cast line towards docks water
                if toolAction then
                    local castPos = Vector3.new(280 + math.random(-5, 5), 0, 220 + math.random(-5, 5))
                    pcall(function()
                        toolAction:FireServer("CastLine", castPos, 1)
                    end)
                    task.wait(1.5)

                    -- Trigger instant win catch
                    pcall(function()
                        toolAction:FireServer("CastFish", { Success = true }, 1)
                    end)
                end

                task.wait(3.5)
            end
        end)
    else
        sendToast("Auto-Fish", "Stopped", 2)
    end
end, 2)

createToggle(fishPage, "💰 Auto-Sell Fish (Instant Poke Doubloons)", false, function(enabled)
    autoSellRunning = enabled
    if enabled then
        sendToast("Auto-Sell", "Active! Fish will sell immediately upon catch", 2)
    end
end, 3)

-- Connect to AutoSellPrompt for instant selling
pcall(function()
    local autoSellPrompt = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AutoSellPrompt")
    local sellFish = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ShopRemotes"):WaitForChild("SellFish")
    local conn = autoSellPrompt.OnClientEvent:Connect(function(fishData)
        if autoSellRunning and fishData then
            pcall(function()
                sellFish:InvokeServer("Fish", {
                    Name = fishData.Name,
                    Modifier = fishData.Modifier,
                    Id = fishData.Id
                }, 1)
            end)
        end
    end)
    table.insert(hubConnections, conn)
end)

createButton(fishPage, "📍 Teleport to Fishing Docks", function()
    safeTeleport(Vector3.new(284.7, 6.0, 223.6))
    sendToast("Fishing", "Arrived at Fishing Docks", 2)
end, 4, Color3.fromRGB(25, 50, 75))

-- ==============================================================================
-- TAB 3: 🐂 MINIGAMES
-- ==============================================================================
local minigamesPage = addTabButton("Minigames", "🐂", 3)

createSectionHeader(minigamesPage, "Mechanical Bull Rhythm Autoplay", 1)

createToggle(minigamesPage, "🐂 Auto-Hit Bull Rhythm Notes (Infinite Score)", false, function(enabled)
    bullAutoplayEnabled = enabled
    if enabled then
        sendToast("Bull Game", "Autoplay Active! Notes will be hit automatically", 2)
        task.spawn(function()
            local bullScoreSignal = ReplicatedStorage:FindFirstChild("Assets")
                and ReplicatedStorage.Assets:FindFirstChild("BullGame")
                and ReplicatedStorage.Assets.BullGame:FindFirstChild("Remotes")
                and ReplicatedStorage.Assets.BullGame.Remotes:FindFirstChild("ScoreSignal")

            while bullAutoplayEnabled do
                -- Inspect PlayerGui for active BullGame
                local pgui = lp:FindFirstChild("PlayerGui")
                local bg = pgui and (pgui:FindFirstChild("BullGame") or pgui:FindFirstChild("BullChoiceLocal"))
                if bg and bg.Enabled then
                    -- Trigger lanes 1..4
                    local holder = bg:FindFirstChild("Holder", true)
                    if holder and holder:FindFirstChild("Lanes") then
                        for laneIdx = 1, 4 do
                            local lane = holder.Lanes:FindFirstChild(tostring(laneIdx))
                            local trigger = lane and lane:FindFirstChild("Trigger")
                            if trigger then
                                pcall(function() firesignal(trigger.MouseButton1Click) end)
                            end
                        end
                    end
                    -- Send reliable ScoreSignal updates
                    if bullScoreSignal then
                        pcall(function()
                            bullScoreSignal:FireServer("Combo", true)
                        end)
                    end
                end
                task.wait(0.12)
            end
        end)
    end
end, 2)

createButton(minigamesPage, "🐂 Teleport to Mechanical Bull", function()
    safeTeleport(Vector3.new(-212.9, 8.3, 254.0))
    sendToast("Bull", "Arrived at Mechanical Bull Arena", 2)
end, 3, Color3.fromRGB(45, 30, 45))

createSectionHeader(minigamesPage, "Campfire Marshmallows", 4)

createButton(minigamesPage, "🔥 Instant 100% Golden Roast Marshmallow", function()
    safeTeleport(Vector3.new(-228.3, 134.7, -22.5))
    task.wait(0.3)
    pcall(function()
        local updateMarsh = ReplicatedStorage:FindFirstChild("UpdateMarshmallow")
        if updateMarsh then
            updateMarsh:FireServer(100, 0)
            sendToast("Marshmallow", "Roasted to 100% perfection! ✨", 2)
        end
    end)
end, 5, Color3.fromRGB(60, 40, 20))

createButton(minigamesPage, "🏕️ Teleport to Campfire", function()
    safeTeleport(Vector3.new(-228.3, 134.7, -22.5))
    sendToast("Campfire", "Arrived at Campfire", 2)
end, 6, Color3.fromRGB(35, 40, 30))

-- ==============================================================================
-- TAB 4: 🍸 BAR & ANTI-DRUNK
-- ==============================================================================
local barPage = addTabButton("Bar & Sobriety", "🍸", 4)

createSectionHeader(barPage, "Sobriety Guard (Anti-Drunk)", 1)

createToggle(barPage, "🛡️ Anti-Drunk (Normal WASD, No Slips, Crisp Screen)", true, function(enabled)
    antiDrunkEnabled = enabled
    if enabled then
        sendToast("Anti-Drunk", "Sobriety Active! No inverted controls or icy slips", 2)
    end
end, 2)

-- Neutralize InvertControls and SlipperyFeet from Remotes
local function applyAntiDrunkPatches()
    pcall(function()
        local remotes = ReplicatedStorage:FindFirstChild("Remotes")
        if remotes then
            local invert = remotes:FindFirstChild("InvertControls")
            if invert and getconnections then
                for _, conn in ipairs(getconnections(invert.OnClientEvent)) do
                    if antiDrunkEnabled then
                        pcall(function() conn:Disable() end)
                    else
                        pcall(function() conn:Enable() end)
                    end
                end
            end
            local slippery = remotes:FindFirstChild("SlipperyFeet")
            if slippery and getconnections then
                for _, conn in ipairs(getconnections(slippery.OnClientEvent)) do
                    if antiDrunkEnabled then
                        pcall(function() conn:Disable() end)
                    else
                        pcall(function() conn:Enable() end)
                    end
                end
            end
        end
    end)
end
task.spawn(function()
    while true do
        if antiDrunkEnabled then
            applyAntiDrunkPatches()
        end
        task.wait(2.0)
    end
end)

createSectionHeader(barPage, "The Bar Counter", 3)

createButton(barPage, "🍸 Teleport to The Bar Counter", function()
    safeTeleport(Vector3.new(-151.0, 17.6, 145.9))
    sendToast("Bar", "Arrived at The Bar Counter", 2)
end, 4, Color3.fromRGB(50, 30, 50))

-- ==============================================================================
-- TAB 5: ⚡ PLAYER & FUN
-- ==============================================================================
local playerPage = addTabButton("Player & Fun", "⚡", 5)

createSectionHeader(page, "Movement Enhancements", 1)

createToggle(playerPage, "👻 Noclip (Walk through walls & doors)", false, function(enabled)
    noclipEnabled = enabled
    if enabled then
        sendToast("Noclip", "Enabled! Walk through obstacles", 2)
    else
        sendToast("Noclip", "Disabled", 2)
    end
end, 2)

local noclipConn = RunService.Stepped:Connect(function()
    if noclipEnabled and lp.Character then
        for _, part in ipairs(lp.Character:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    end
end)
table.insert(hubConnections, noclipConn)

createToggle(playerPage, "🦘 Infinite Jump (Fly / Jump in mid-air)", false, function(enabled)
    infJumpEnabled = enabled
    if enabled then
        sendToast("Infinite Jump", "Enabled! Press Space to jump in air", 2)
    end
end, 3)

local infJumpConn = UserInputService.JumpRequest:Connect(function()
    if infJumpEnabled and lp.Character and lp.Character:FindFirstChildOfClass("Humanoid") then
        lp.Character:FindFirstChildOfClass("Humanoid"):ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)
table.insert(hubConnections, infJumpConn)

createSectionHeader(playerPage, "Speed & Jump Multipliers", 4)

local speedRow = Instance.new("Frame")
speedRow.Size = UDim2.new(1, 0, 0, 34)
speedRow.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
speedRow.BorderSizePixel = 0
speedRow.LayoutOrder = 5
speedRow.Parent = playerPage
local sCorner = Instance.new("UICorner")
sCorner.CornerRadius = UDim.new(0, 6)
sCorner.Parent = speedRow

local sLbl = Instance.new("TextLabel")
sLbl.Size = UDim2.new(0.5, 0, 1, 0)
sLbl.Position = UDim2.new(0, 10, 0, 0)
sLbl.BackgroundTransparency = 1
sLbl.Text = "WalkSpeed (16 / 32 / 64)"
sLbl.Font = Enum.Font.GothamMedium
sLbl.TextSize = 12
sLbl.TextColor3 = Color3.fromRGB(220, 230, 250)
sLbl.TextXAlignment = Enum.TextXAlignment.Left
sLbl.Parent = speedRow

local speeds = { 16, 32, 64 }
for i, spd in ipairs(speeds) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 36, 0, 24)
    btn.Position = UDim2.new(1, -125 + (i * 38), 0.5, -12)
    btn.BackgroundColor3 = Color3.fromRGB(38, 46, 70)
    btn.TextColor3 = Color3.fromRGB(0, 220, 255)
    btn.Text = tostring(spd)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.BorderSizePixel = 0
    btn.Parent = speedRow
    local bCorner = Instance.new("UICorner")
    bCorner.CornerRadius = UDim.new(0, 4)
    bCorner.Parent = btn

    btn.MouseButton1Click:Connect(function()
        if lp.Character and lp.Character:FindFirstChildOfClass("Humanoid") then
            lp.Character:FindFirstChildOfClass("Humanoid").WalkSpeed = spd
            sendToast("Speed", "WalkSpeed set to " .. spd, 2)
        end
    end)
end

createSectionHeader(playerPage, "Social & Animations", 6)

createButton(playerPage, "🤸 Instant Ragdoll On/Off", function()
    local toggleRag = ReplicatedStorage:FindFirstChild("Remotes") and ReplicatedStorage.Remotes:FindFirstChild("ToggleRagdoll")
    if toggleRag then
        toggleRag:FireServer()
    end
end, 7, Color3.fromRGB(60, 35, 45))

-- Emote Buttons Row
local emoteRow = Instance.new("Frame")
emoteRow.Size = UDim2.new(1, 0, 0, 34)
emoteRow.BackgroundTransparency = 1
emoteRow.LayoutOrder = 8
emoteRow.Parent = playerPage

local sampleEmotes = { "Shuffle", "Twirl", "Sleep", "Monkey" }
for idx, emote in ipairs(sampleEmotes) do
    local eBtn = Instance.new("TextButton")
    eBtn.Size = UDim2.new(0.23, 0, 1, 0)
    eBtn.Position = UDim2.new((idx - 1) * 0.256, 0, 0, 0)
    eBtn.BackgroundColor3 = Color3.fromRGB(30, 36, 56)
    eBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
    eBtn.Text = emote
    eBtn.Font = Enum.Font.GothamMedium
    eBtn.TextSize = 11
    eBtn.BorderSizePixel = 0
    eBtn.Parent = emoteRow
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = eBtn

    eBtn.MouseButton1Click:Connect(function()
        local playEmote = ReplicatedStorage:FindFirstChild("Remotes") and ReplicatedStorage.Remotes:FindFirstChild("PlayEmote")
        if playEmote then
            playEmote:FireServer(emote)
            sendToast("Emote", "Playing " .. emote, 2)
        end
    end)
end

-- ==============================================================================
-- WINDOW TOGGLING & KEYBIND
-- ==============================================================================
local isVisible = true

local function toggleHub()
    isVisible = not isVisible
    MainFrame.Visible = isVisible
end

CloseBtn.MouseButton1Click:Connect(toggleHub)
MinBtn.MouseButton1Click:Connect(toggleHub)
TogglePill.MouseButton1Click:Connect(toggleHub)

local keybindConn = UserInputService.InputBegan:Connect(function(input, gpe)
    if not gpe and input.KeyCode == Enum.KeyCode.RightShift then
        toggleHub()
    end
end)
table.insert(hubConnections, keybindConn)

-- Default to first tab
tabButtons["Waypoints"].BackgroundColor3 = Color3.fromRGB(35, 45, 75)
tabButtons["Waypoints"].TextColor3 = Color3.fromRGB(0, 230, 255)
tabPages["Waypoints"].Visible = true

-- Teardown Function
getgenv()._PokeHavenHubCleanUp = function()
    for _, c in ipairs(hubConnections) do
        pcall(function() c:Disconnect() end)
    end
    hubConnections = {}
    autoFishRunning = false
    autoSellRunning = false
    bullAutoplayEnabled = false
    noclipEnabled = false
    infJumpEnabled = false
    if ScreenGui then
        pcall(function() ScreenGui:Destroy() end)
    end
    getgenv()._PokeHavenHubCleanUp = nil
    print("[PokeHavenHub]: Cleanly unloaded.")
end

sendToast("Poke Haven Luxury Hub", "Loaded! Press RightShift to toggle.", 4)
print("[PokeHavenHub]: Loaded successfully.")
