--[[
    ==============================================================================
    OMNI BOOTLOADER - ONE-CLICK INSTALLER
    ==============================================================================
    Repository: https://github.com/s3rvxnt/RobloxOmni
    Usage:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.lua"))()
    ==============================================================================
]]

local GITHUB_URL = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/OmniBootloader.lua"
local TARGET_PATH = "autoexec/OmniBootloader.lua"

local function notifyUser(title, text)
    pcall(function()
        local StarterGui = game:GetService("StarterGui")
        StarterGui:SetCore("SendNotification", {
            Title = title or "Omni Bootloader",
            Text = text or "Action complete",
            Duration = 5.0
        })
    end)
end

local function install()
    print("==================================================================")
    print(" [OmniInstaller]: Downloading OmniBootloader...")
    print("==================================================================")

    if not writefile then
        warn("[OmniInstaller ERROR]: writefile() is unavailable in this environment.")
        notifyUser("Install Failed", "writefile() function unavailable.")
        return
    end

    local fetchOk, content = pcall(function()
        return game:HttpGet(GITHUB_URL .. "?v=" .. tostring(os.time()))
    end)

    if not fetchOk or not content or #content < 1000 then
        warn("[OmniInstaller ERROR]: Failed to download OmniBootloader from GitHub: " .. tostring(content))
        notifyUser("Install Failed", "Could not download OmniBootloader from GitHub.")
        return
    end

    -- Ensure autoexec directory exists
    if isfolder and not isfolder("autoexec") then
        pcall(makefolder, "autoexec")
    end

    local writeOk, writeErr = pcall(writefile, TARGET_PATH, content)
    if not writeOk then
        warn("[OmniInstaller ERROR]: Failed to write to " .. TARGET_PATH .. ": " .. tostring(writeErr))
        notifyUser("Install Failed", "Failed to write file to autoexec/.")
        return
    end

    print("[OmniInstaller]: Successfully installed OmniBootloader to " .. TARGET_PATH)
    notifyUser("Omni Installed!", "OmniBootloader written to autoexec/. Booting now...")

    -- Immediately boot for the current session
    local compileOk, compiledFn = pcall(loadstring, content)
    if compileOk and compiledFn then
        pcall(compiledFn)
        print("[OmniInstaller]: OmniBootloader initialized for current session. Press Shift + F8 for Task Manager.")
    end
end

install()
