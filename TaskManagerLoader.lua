--[[
    ==============================================================================
    OMNI KERNEL TASK MANAGER & RUNTIME MICRO-KERNEL - UNIVERSAL LOADER
    ==============================================================================
    Repository: https://github.com/s3rvxnt/RobloxOmni
    Author: s3rvxnt & DeepMind Antigravity Pair-Programming Suite
    License: MIT
    
    Usage:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/TaskManagerLoader.lua"))()
    ==============================================================================
]]

local GITHUB_REPO_RAW = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main"
local SCRIPT_NAME = "KernelTaskManager.lua"
local LOCAL_FALLBACK_PATHS = {
    "autoexec/kernel/KernelTaskManager.lua",
    "workspace/autoexec/kernel/KernelTaskManager.lua",
    "KernelTaskManager.lua",
}

local function notifyUser(title, message, duration)
    pcall(function()
        local StarterGui = game:GetService("StarterGui")
        StarterGui:SetCore("SendNotification", {
            Title = title or "Omni Kernel",
            Text = message or "Initialized",
            Duration = duration or 4.5,
        })
    end)
end

local function fetchSource()
    -- 1. Try local workspace files first if available (for offline/developer testing)
    if isfile and readfile then
        for _, path in ipairs(LOCAL_FALLBACK_PATHS) do
            local ok, exists = pcall(isfile, path)
            if ok and exists then
                local readOk, content = pcall(readfile, path)
                if readOk and content and #content > 500 then
                    print("[OmniLoader]: Loaded KernelTaskManager from local file: " .. path)
                    return content
                end
            end
        end
    end

    -- 2. Fetch from GitHub Raw
    local url = GITHUB_REPO_RAW .. "/" .. SCRIPT_NAME
    local getOk, rawContent = pcall(function()
        return game:HttpGet(url .. "?v=" .. tostring(os.time()))
    end)

    if getOk and rawContent and #rawContent > 500 then
        print("[OmniLoader]: Downloaded KernelTaskManager from GitHub: " .. url)
        return rawContent
    end

    return nil, rawContent
end

local function main()
    print("==================================================================")
    print(" [OmniLoader]: Initializing Omni Kernel Task Manager...")
    print("==================================================================")

    local sourceCode, err = fetchSource()
    if not sourceCode then
        warn("[OmniLoader ERROR]: Failed to retrieve KernelTaskManager source: " .. tostring(err))
        notifyUser("Omni Kernel Error", "Failed to fetch KernelTaskManager source code.", 6)
        return
    end

    local loadOk, compiledFn = pcall(loadstring, sourceCode)
    if not loadOk or not compiledFn then
        warn("[OmniLoader ERROR]: Luau compilation failed: " .. tostring(compiledFn))
        notifyUser("Omni Kernel Error", "Failed to compile KernelTaskManager.", 6)
        return
    end

    local execOk, execErr = pcall(compiledFn)
    if not execOk then
        warn("[OmniLoader ERROR]: Runtime execution failed: " .. tostring(execErr))
        notifyUser("Omni Kernel Error", "Runtime initialization error: " .. tostring(execErr), 6)
        return
    end

    notifyUser("Omni Kernel Active", "Task Manager ready. Press Shift + F8 to open HUD.", 5.0)
    print("[OmniLoader]: Successfully mounted Omni Kernel & Task Manager HUD.")
end

main()
