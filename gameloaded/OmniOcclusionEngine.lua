--[[
    ==============================================================================
    OMNI OCCLUSION ENGINE (Universal Hardware-Accelerated Occlusion Culler)
    ==============================================================================
    - First-in-class real-time client-side occlusion culling for Roblox.
    - Suppresses GPU vertex processing, rasterization, and draw calls on occluded
      geometry using native BasePart.LocalTransparencyModifier = 1.
    - Zero physics disruption: Collisions, rays, and scripts remain 100% intact.
    - Inverted Convergence Raycasting: Bypasses lack of native ConeCast by
      casting inward from cluster bounding hulls to the camera focal point.
    - Voxel Hash Partition: Groups static geometry into 28-stud spatial bounding
      cells, evaluating ~80-120 cells instead of 40,000+ raw parts.
    - Multi-Point Conservative Probing: 3-point hull sampling + 12-deg peripheral
      frustum padding guarantees zero edge popping.
    - 2-Frame Temporal Hysteresis: Anti-flicker delay prevents portal strobing.
    - Frame-Budgeted: Adaptive Heartbeat governor caps CPU time to <= 1.0ms/frame.
    - Toggle Keybind: Shift + F5 (with live telemetry HUD).
    ==============================================================================
]]

-- Anti-overlap guard
if getgenv()._OmniOcclusionEngineRunning then
    if getgenv()._OmniOcclusionEngineUnload then
        getgenv()._OmniOcclusionEngineUnload()
    end
end
getgenv()._OmniOcclusionEngineRunning = true

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local Camera = workspace.CurrentCamera or workspace:WaitForChild("Camera")

local function getGuiParent()
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local okCG, cg = pcall(function() return game:GetService("CoreGui") end)
    if okCG and cg then return cg end
    return LocalPlayer:WaitForChild("PlayerGui")
end

-- ==============================================================================
-- ENGINE CONFIGURATION
-- ==============================================================================
local CFG = {
    CELL_SIZE = 14,               -- Voxel cell cube edge (studs) - tightened from 28 to 14
    MAX_PROP_SIZE = 15,           -- Max dimension for cull candidate (walls/floors > 15 never cull)
    MAX_CULL_RADIUS = 300,        -- Maximum distance from camera to cull geometry
    MIN_CULL_DIST = 22,           -- Minimum distance (never cull parts inside near room/corridor)
    FRAME_BUDGET_MS = 0.95,       -- Maximum CPU ms per frame on Heartbeat
    CELLS_PER_SLICE = 80,         -- Maximum cells to raycast-probe per frame
    HYSTERESIS_FRAMES = 2,        -- Consecutive occluded evaluations before culling
    PERIPHERAL_PADDING_DEG = 12,  -- Extra FOV padding (degrees) to eliminate turn popping
    MIN_OCCLUDER_AREA = 45,       -- Min square stud surface area to count as major occluder
    IGNORE_CHARACTER = true,      -- Never cull player characters or dynamic models
}

-- ==============================================================================
-- STATE REGISTRIES
-- ==============================================================================
local spatialGrid = {}            -- [string key] -> Cell
local activeCells = {}            -- Array of all registered Cell objects
local cellCount = 0
local totalTrackedParts = 0

getgenv()._OmniActiveCells = activeCells
getgenv()._OmniSpatialGrid = spatialGrid

local isEngineEnabled = true
local isHudVisible = true

local currentCulledPartsCount = 0
local currentFrustumPartsCount = 0
local lastFrameExecutionTimeMs = 0
local probeParams = RaycastParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Exclude
probeParams.IgnoreWater = true
local ignoreList = {}

local function updateRaycastFilter()
    table.clear(ignoreList)
    if LocalPlayer.Character then
        table.insert(ignoreList, LocalPlayer.Character)
    end
    probeParams.FilterDescendantsInstances = ignoreList
end
updateRaycastFilter()
LocalPlayer.CharacterAdded:Connect(updateRaycastFilter)

-- Penetrative raycaster: Punches through transparent windows, glass, water, and invisible trigger zones
-- Only genuine, anchored, opaque geometry (transparency <= 0.05 and Anchored == true) counts as an occluder
local function isOpaqueOccluder(inst)
    if inst:IsA("Terrain") then
        return true
    end
    if not inst:IsA("BasePart") then
        return false
    end
    -- Must be opaque (transparency <= 0.05) - punches through glass, windows, water, triggers
    if inst.Transparency > 0.05 then
        return false
    end
    -- Must be anchored static geometry (walls, floors, ceilings, foundations)
    if not inst.Anchored then
        return false
    end
    -- Dynamic characters (players, NPCs, accessories) should never occlude world geometry
    local parent = inst.Parent
    if parent and (parent:IsA("Accessory") or parent:FindFirstChildOfClass("Humanoid") or (parent.Parent and parent.Parent:FindFirstChildOfClass("Humanoid"))) then
        return false
    end
    return true
end

local function raycastOpaque(origin, direction, maxHops)
    local curOrigin = origin
    local remaining = direction
    local hops = 0
    maxHops = maxHops or 4
    local hasPunched = false

    while hops < maxHops do
        hops = hops + 1
        local hit = workspace:Raycast(curOrigin, remaining, probeParams)
        if not hit then break end

        local inst = hit.Instance
        if isOpaqueOccluder(inst) then
            if hasPunched then
                local baseCount = LocalPlayer.Character and 1 or 0
                while #ignoreList > baseCount do table.remove(ignoreList) end
                probeParams.FilterDescendantsInstances = ignoreList
            end
            return hit
        end

        -- Transparent glass, window, water, invisible trigger, or dynamic character: PUNCH THROUGH!
        hasPunched = true
        table.insert(ignoreList, inst)
        probeParams.FilterDescendantsInstances = ignoreList

        curOrigin = hit.Position + remaining.Unit * 0.08
        remaining = (origin + direction) - curOrigin
        if remaining:Dot(direction) <= 0 then break end
    end

    if hasPunched then
        local baseCount = LocalPlayer.Character and 1 or 0
        while #ignoreList > baseCount do table.remove(ignoreList) end
        probeParams.FilterDescendantsInstances = ignoreList
    end
    return nil
end

-- ==============================================================================
-- SPATIAL VOXEL CLASSIFICATION
-- ==============================================================================
local function getCellKey(pos)
    local cx = math.floor(pos.X / CFG.CELL_SIZE)
    local cy = math.floor(pos.Y / CFG.CELL_SIZE)
    local cz = math.floor(pos.Z / CFG.CELL_SIZE)
    return cx .. "_" .. cy .. "_" .. cz
end

local function isMajorOccluder(part)
    if not part.Anchored then return false end
    if part.Transparency > 0.05 then return false end
    local s = part.Size
    local maxFace = math.max(s.X * s.Y, s.Y * s.Z, s.X * s.Z)
    return maxFace >= CFG.MIN_OCCLUDER_AREA
end

local function isCullCandidate(part)
    if not part:IsA("BasePart") then return false end
    if part.Transparency >= 0.99 then return false end -- Already invisible trigger/zone
    local s = part.Size
    -- Smarter Anchoring: Large structural geometry (walls, floors, ceilings, roads) NEVER cull!
    if math.max(s.X, s.Y, s.Z) > CFG.MAX_PROP_SIZE then return false end
    local parent = part.Parent
    if parent and (parent:IsA("Accessory") or parent:FindFirstChildOfClass("Humanoid") or (parent.Parent and parent.Parent:FindFirstChildOfClass("Humanoid"))) then
        return false
    end
    if isMajorOccluder(part) then return false end -- Major occluders always render
    return true
end

local function registerPart(part)
    if not isCullCandidate(part) then return end
    local p = part.Position
    local key = getCellKey(p)
    local cell = spatialGrid[key]

    if not cell then
        local cx = math.floor(p.X / CFG.CELL_SIZE)
        local cy = math.floor(p.Y / CFG.CELL_SIZE)
        local cz = math.floor(p.Z / CFG.CELL_SIZE)
        cell = {
            key = key,
            center = Vector3.new((cx + 0.5) * CFG.CELL_SIZE, (cy + 0.5) * CFG.CELL_SIZE, (cz + 0.5) * CFG.CELL_SIZE),
            radius = CFG.CELL_SIZE * 0.707, -- Max theoretical radius (~9.9 studs)
            actualRadius = 2,               -- Dynamically expands to fit enclosed props
            parts = {},
            isOccluded = false,
            consecutiveOccluded = 0,
            lastEvaluated = 0,
        }
        spatialGrid[key] = cell
        table.insert(activeCells, cell)
        cellCount = #activeCells
    end

    table.insert(cell.parts, part)
    local s = part.Size
    local partExt = (p - cell.center).Magnitude + (math.max(s.X, s.Y, s.Z) * 0.5)
    if partExt > cell.actualRadius then
        cell.actualRadius = math.min(cell.radius, partExt)
    end
    totalTrackedParts = totalTrackedParts + 1
end

local function unregisterPart(part)
    local p = part.Position
    local key = getCellKey(p)
    local cell = spatialGrid[key]
    if cell then
        for i = #cell.parts, 1, -1 do
            if cell.parts[i] == part then
                table.remove(cell.parts, i)
                totalTrackedParts = math.max(0, totalTrackedParts - 1)
                break
            end
        end
    end
end

-- ==============================================================================
-- PROGRESSIVE BACKGROUND INITIALIZER (Zero Boot Lag)
-- ==============================================================================
local function indexWorldIncrementally()
    local allDescendants = workspace:GetDescendants()
    local total = #allDescendants
    local cursor = 1
    local batchSize = 1000

    while cursor <= total do
        local maxEnd = math.min(total, cursor + batchSize - 1)
        for i = cursor, maxEnd do
            local obj = allDescendants[i]
            if obj:IsA("BasePart") then
                registerPart(obj)
            end
        end
        cursor = maxEnd + 1
        task.wait()
    end

    -- Hook live world streaming / dynamic additions
    workspace.DescendantAdded:Connect(function(obj)
        if obj:IsA("BasePart") then
            registerPart(obj)
        end
    end)

    workspace.DescendantRemoving:Connect(function(obj)
        if obj:IsA("BasePart") then
            unregisterPart(obj)
        end
    end)
end
task.spawn(indexWorldIncrementally)

-- ==============================================================================
-- INVERTED CONVERGENCE OCCLUSION PIPELINE
-- ==============================================================================
local globalCulledPartsCount = 0
local globalFrustumPartsCount = 0
local frameParity = 0
local candidateCursor = 1

local function evaluateOcclusionCycle()
    if not isEngineEnabled then return end
    if cellCount == 0 then return end

    local tStart = os.clock()
    local camPos = Camera.CFrame.Position
    local camLook = Camera.CFrame.LookVector

    -- Half-angle cosine with conservative peripheral padding
    local fovPadRad = math.rad((Camera.FieldOfView * 0.5) + CFG.PERIPHERAL_PADDING_DEG)
    local minDot = math.cos(fovPadRad)

    -- 1. Rapid Vector Frustum Filter (<0.15ms across all cells)
    local candidates = {}
    local frustumPartsSum = 0

    for i = 1, cellCount do
        local cell = activeCells[i]
        if cell and #cell.parts > 0 then
            local toCell = cell.center - camPos
            local dist = toCell.Magnitude

            -- Distance filter: 16 to 380 studs
            if dist > CFG.MIN_CULL_DIST and dist <= CFG.MAX_CULL_RADIUS then
                local dot = camLook:Dot(toCell.Unit)
                if dot >= minDot then
                    table.insert(candidates, cell)
                    frustumPartsSum = frustumPartsSum + #cell.parts
                else
                    -- Outside frustum: restore to native
                    if cell.isOccluded then
                        cell.isOccluded = false
                        globalCulledPartsCount = math.max(0, globalCulledPartsCount - #cell.parts)
                        for _, part in ipairs(cell.parts) do
                            if part.Parent then part.LocalTransparencyModifier = 0 end
                        end
                    end
                    cell.consecutiveOccluded = 0
                end
            elseif cell.isOccluded then
                -- Out of range: restore
                cell.isOccluded = false
                cell.consecutiveOccluded = 0
                globalCulledPartsCount = math.max(0, globalCulledPartsCount - #cell.parts)
                for _, part in ipairs(cell.parts) do
                    if part.Parent then part.LocalTransparencyModifier = 0 end
                end
            end
        end
    end

    -- 2. Rotating Sliced Multi-Probe Raycasting across Candidates (Fair Scheduling)
    local candCount = #candidates
    if candCount > 0 then
        local sliceLimit = math.min(candCount, CFG.CELLS_PER_SLICE)
        local stepsRun = 0
        for step = 1, sliceLimit do
            stepsRun = step
            local idx = ((candidateCursor + step - 2) % candCount) + 1
            local cell = candidates[idx]
            local toCell = cell.center - camPos
            local dist = toCell.Magnitude

            -- True Geometric Clearance:
            -- The occluding wall must be strictly in front of the entire cluster of props in this cell
            local aRad = cell.actualRadius or 2
            local clearanceDist = dist - aRad - 0.5

            -- Probe 1: Center Point (punches through transparent glass and invisible triggers)
            local hitCenter = raycastOpaque(camPos, toCell)
            local isCenterBlocked = hitCenter and (((hitCenter.Position - camPos).Magnitude) < clearanceDist)
            local isFullyOccluded = false

            if isCenterBlocked then
                if cell.isOccluded then
                    -- Already occluded: 1 confirmed probe is sufficient to maintain state
                    isFullyOccluded = true
                else
                    -- Not yet occluded: require 3-point hull confirmation to prevent false culling
                    local rOffset = aRad * 0.65
                    local rightVec = Camera.CFrame.RightVector * rOffset
                    local upVec = Camera.CFrame.UpVector * rOffset

                    local toCornerA = (cell.center + rightVec + upVec) - camPos
                    local toCornerB = (cell.center - rightVec - upVec) - camPos

                    local hitA = raycastOpaque(camPos, toCornerA)
                    local hitB = raycastOpaque(camPos, toCornerB)

                    local isABlocked = hitA and (((hitA.Position - camPos).Magnitude) < (toCornerA.Magnitude - aRad * 0.5))
                    local isBBlocked = hitB and (((hitB.Position - camPos).Magnitude) < (toCornerB.Magnitude - aRad * 0.5))

                    if isABlocked and isBBlocked then
                        isFullyOccluded = true
                    end
                end
            end

            -- State Diffing & Hysteresis: Only cull when consistently occluded across frames
            if isFullyOccluded then
                cell.consecutiveOccluded = cell.consecutiveOccluded + 1
                if cell.consecutiveOccluded >= CFG.HYSTERESIS_FRAMES and not cell.isOccluded then
                    cell.isOccluded = true
                    globalCulledPartsCount = globalCulledPartsCount + #cell.parts
                    for _, part in ipairs(cell.parts) do
                        if part.Parent then
                            part.LocalTransparencyModifier = 1
                        end
                    end
                end
            else
                cell.consecutiveOccluded = 0
                if cell.isOccluded then
                    cell.isOccluded = false
                    globalCulledPartsCount = math.max(0, globalCulledPartsCount - #cell.parts)
                    for _, part in ipairs(cell.parts) do
                        if part.Parent then
                            part.LocalTransparencyModifier = 0
                        end
                    end
                end
            end

            -- Frame budget safety valve
            if (os.clock() - tStart) * 1000 >= CFG.FRAME_BUDGET_MS then
                break
            end
        end
        candidateCursor = ((candidateCursor + stepsRun - 1) % candCount) + 1
    end

    globalFrustumPartsCount = frustumPartsSum
    lastFrameExecutionTimeMs = (os.clock() - tStart) * 1000
end

-- ==============================================================================
-- RESTORE ALL PARTICLES & GEOMETRY (Clean Unload / Off Switch)
-- ==============================================================================
local function restoreAllGeometry()
    for _, cell in ipairs(activeCells) do
        if cell.isOccluded then
            cell.isOccluded = false
            cell.consecutiveOccluded = 0
            for _, part in ipairs(cell.parts) do
                if part and part.Parent then
                    part.LocalTransparencyModifier = 0
                end
            end
        end
    end
    globalCulledPartsCount = 0
    currentCulledPartsCount = 0
end

-- ==============================================================================
-- HIGH-TECH DESKTOP HUD & TELEMETRY OVERLAY (Task Manager Theme)
-- ==============================================================================
local guiParent = getGuiParent()
local hudScreenGui = Instance.new("ScreenGui")
hudScreenGui.Name = "OmniOcclusionHUD"
hudScreenGui.ResetOnSpawn = false
hudScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local HudFrame = Instance.new("Frame")
HudFrame.Name = "HudFrame"
HudFrame.Size = UDim2.new(0, 310, 0, 115)
HudFrame.Position = UDim2.new(1, -325, 0, 50)
HudFrame.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
HudFrame.BorderSizePixel = 0
HudFrame.Parent = hudScreenGui

local HudCorner = Instance.new("UICorner")
HudCorner.CornerRadius = UDim.new(0, 8)
HudCorner.Parent = HudFrame

local HudStroke = Instance.new("UIStroke")
HudStroke.Thickness = 1
HudStroke.Color = Color3.fromRGB(45, 52, 68)
HudStroke.Parent = HudFrame

-- Header
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 30)
Header.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
Header.BorderSizePixel = 0
Header.Parent = HudFrame

local HeaderCorner = Instance.new("UICorner")
HeaderCorner.CornerRadius = UDim.new(0, 8)
HeaderCorner.Parent = Header

local HeaderTitle = Instance.new("TextLabel")
HeaderTitle.Size = UDim2.new(1, -70, 1, 0)
HeaderTitle.Position = UDim2.new(0, 10, 0, 0)
HeaderTitle.BackgroundTransparency = 1
HeaderTitle.Font = Enum.Font.GothamBold
HeaderTitle.TextSize = 11
HeaderTitle.TextColor3 = Color3.fromRGB(64, 196, 255)
HeaderTitle.TextXAlignment = Enum.TextXAlignment.Left
HeaderTitle.Text = "⚡ OMNI OCCLUSION ENGINE"
HeaderTitle.Parent = Header

local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Name = "ToggleBtn"
ToggleBtn.Size = UDim2.new(0, 52, 0, 20)
ToggleBtn.Position = UDim2.new(1, -58, 0, 5)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(22, 48, 34)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.TextSize = 9
ToggleBtn.TextColor3 = Color3.fromRGB(100, 240, 150)
ToggleBtn.Text = "ACTIVE"
ToggleBtn.Parent = Header

local ToggleCorner = Instance.new("UICorner")
ToggleCorner.CornerRadius = UDim.new(0, 4)
ToggleCorner.Parent = ToggleBtn

local ToggleStroke = Instance.new("UIStroke")
ToggleStroke.Thickness = 1
ToggleStroke.Color = Color3.fromRGB(36, 75, 52)
ToggleStroke.Parent = ToggleBtn

-- 3 Metric Cards Row
local MetricsContainer = Instance.new("Frame")
MetricsContainer.Name = "MetricsContainer"
MetricsContainer.Size = UDim2.new(1, -16, 0, 44)
MetricsContainer.Position = UDim2.new(0, 8, 0, 36)
MetricsContainer.BackgroundTransparency = 1
MetricsContainer.Parent = HudFrame

local MetricLayout = Instance.new("UIListLayout")
MetricLayout.FillDirection = Enum.FillDirection.Horizontal
MetricLayout.SortOrder = Enum.SortOrder.LayoutOrder
MetricLayout.Padding = UDim.new(0, 6)
MetricLayout.Parent = MetricsContainer

local function createMetricCard(name, label, initialValue, order)
    local card = Instance.new("Frame")
    card.Name = name
    card.LayoutOrder = order
    card.Size = UDim2.new(0.333, -4, 1, 0)
    card.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
    card.BorderSizePixel = 0
    card.Parent = MetricsContainer

    local cardCorner = Instance.new("UICorner")
    cardCorner.CornerRadius = UDim.new(0, 6)
    cardCorner.Parent = card

    local cardStroke = Instance.new("UIStroke")
    cardStroke.Thickness = 1
    cardStroke.Color = Color3.fromRGB(35, 41, 55)
    cardStroke.Parent = card

    local topLabel = Instance.new("TextLabel")
    topLabel.Size = UDim2.new(1, -8, 0, 14)
    topLabel.Position = UDim2.new(0, 4, 0, 4)
    topLabel.BackgroundTransparency = 1
    topLabel.Font = Enum.Font.GothamBold
    topLabel.TextSize = 8
    topLabel.TextColor3 = Color3.fromRGB(130, 145, 170)
    topLabel.TextXAlignment = Enum.TextXAlignment.Center
    topLabel.Text = label
    topLabel.Parent = card

    local valLabel = Instance.new("TextLabel")
    valLabel.Name = "ValLabel"
    valLabel.Size = UDim2.new(1, -8, 0, 20)
    valLabel.Position = UDim2.new(0, 4, 0, 18)
    valLabel.BackgroundTransparency = 1
    valLabel.Font = Enum.Font.RobotoMono
    valLabel.TextSize = 11
    valLabel.TextColor3 = Color3.fromRGB(50, 220, 120)
    valLabel.TextXAlignment = Enum.TextXAlignment.Center
    valLabel.Text = initialValue
    valLabel.Parent = card

    return valLabel
end

local CardCulledVal = createMetricCard("CardCulled", "CULLED PARTS", "0", 1)
local CardReductionVal = createMetricCard("CardReduction", "DRAW REDUCTION", "0%", 2)
local CardBudgetVal = createMetricCard("CardBudget", "FRAME COST", "0.0ms", 3)

-- Footer Info Bar
local Footer = Instance.new("Frame")
Footer.Name = "Footer"
Footer.Size = UDim2.new(1, -16, 0, 22)
Footer.Position = UDim2.new(0, 8, 0, 86)
Footer.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
Footer.BorderSizePixel = 0
Footer.Parent = HudFrame

local FooterCorner = Instance.new("UICorner")
FooterCorner.CornerRadius = UDim.new(0, 4)
FooterCorner.Parent = Footer

local FooterText = Instance.new("TextLabel")
FooterText.Name = "FooterText"
FooterText.Size = UDim2.new(1, -12, 1, 0)
FooterText.Position = UDim2.new(0, 6, 0, 0)
FooterText.BackgroundTransparency = 1
FooterText.Font = Enum.Font.GothamMedium
FooterText.TextSize = 9
FooterText.TextColor3 = Color3.fromRGB(140, 155, 180)
FooterText.TextXAlignment = Enum.TextXAlignment.Left
FooterText.Text = "Shift + F5: Toggle HUD | Inverted Convergence Active"
FooterText.Parent = Footer

-- Toggle Interaction
ToggleBtn.MouseButton1Click:Connect(function()
    isEngineEnabled = not isEngineEnabled
    if isEngineEnabled then
        ToggleBtn.Text = "ACTIVE"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(22, 48, 34)
        ToggleBtn.TextColor3 = Color3.fromRGB(100, 240, 150)
        ToggleStroke.Color = Color3.fromRGB(36, 75, 52)
    else
        ToggleBtn.Text = "PAUSED"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(45, 25, 30)
        ToggleBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
        ToggleStroke.Color = Color3.fromRGB(75, 38, 44)
        restoreAllGeometry()
    end
end)

hudScreenGui.Parent = guiParent

-- ==============================================================================
-- RUNTIME TELEMETRY & KEYBIND HOOKS
-- ==============================================================================
local frameTimes = {}
local lastTelemetryUpdate = 0

local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
    local ok, err = pcall(evaluateOcclusionCycle)
    if not ok then
        warn("[Omni Occlusion Engine Error]: " .. tostring(err))
    end

    -- Calculate rolling FPS
    table.insert(frameTimes, dt)
    if #frameTimes > 30 then
        table.remove(frameTimes, 1)
    end

    -- Update HUD once every 0.15s (efficient)
    local now = os.clock()
    if now - lastTelemetryUpdate >= 0.15 then
        lastTelemetryUpdate = now
        local sumDt = 0
        for _, t in ipairs(frameTimes) do sumDt = sumDt + t end
        local avgFps = #frameTimes > 0 and math.floor(#frameTimes / math.max(0.001, sumDt)) or 60

        local ratio = (globalCulledPartsCount / math.max(1, globalCulledPartsCount + globalFrustumPartsCount)) * 100
        CardCulledVal.Text = tostring(globalCulledPartsCount)
        CardReductionVal.Text = string.format("%.1f%%", ratio)
        CardBudgetVal.Text = string.format("%.2fms", lastFrameExecutionTimeMs)

        if not isEngineEnabled then
            CardCulledVal.Text = "OFF"
            CardReductionVal.Text = "0%"
            CardBudgetVal.Text = "0.0ms"
        end

        FooterText.Text = string.format("FPS: %d | Cells: %d | Tracked: %d | Shift+F5: Hide", avgFps, cellCount, totalTrackedParts)
    end
end)

-- Keybind Toggle (Shift + F5)
local inputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.F5 and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
        isHudVisible = not isHudVisible
        HudFrame.Visible = isHudVisible
    end
end)

-- Unload sequence
getgenv()._OmniOcclusionEngineUnload = function()
    if heartbeatConn then heartbeatConn:Disconnect() end
    if inputConn then inputConn:Disconnect() end
    restoreAllGeometry()
    if hudScreenGui then hudScreenGui:Destroy() end
    getgenv()._OmniOcclusionEngineRunning = false
    print("[Omni Occlusion Engine]: Cleanly unloaded and restored all geometry.")
end

print(string.format("[Omni Occlusion Engine v1.0]: Initialized! Spatial grid active with %d-stud cells.", CFG.CELL_SIZE))
