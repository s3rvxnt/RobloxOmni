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

-- ==============================================================================
-- STEP 2: ANTI-HOOKING EXECUTOR PRIMITIVE CLONING (Unhookable C-Closures)
-- ==============================================================================
-- Must execute before ANY other logic, hooks, or third-party libraries.
-- Captures unhookable references to executor primitives via clonefunction.
local _rawClone = (type(clonefunction) == "function" and clonefunction) or nil
local _clonefunctionPoisoned = false
local _primitivesPoisoned = false

local _checkIsCClosure = (type(iscclosure) == "function" and iscclosure) or nil
local _checkIsLClosure = (type(islclosure) == "function" and islclosure) or nil
local _checkDebugInfo = (debug and type(debug.info) == "function" and debug.info) or nil

-- Authenticate a function primitive as an authentic C-closure
local function _isAuthenticCClosure(fn)
    if type(fn) ~= "function" then return false end
    if _checkIsLClosure then
        local okL, isL = pcall(_checkIsLClosure, fn)
        if okL and isL == true then return false end
    end
    if _checkIsCClosure then
        local okC, isC = pcall(_checkIsCClosure, fn)
        if not okC or isC ~= true then return false end
    end
    if _checkDebugInfo then
        local okS, src = pcall(_checkDebugInfo, fn, "s")
        if not okS or (src ~= "[C]" and src ~= "=[C]") then return false end
        local okL, line = pcall(_checkDebugInfo, fn, "l")
        if not okL or line ~= -1 then return false end
    end
    return true
end

if _rawClone then
    -- 0. Check islclosure(clonefunction)
    if _checkIsLClosure then
        local okL, isL = pcall(_checkIsLClosure, _rawClone)
        if okL and isL == true then
            _clonefunctionPoisoned = true
        end
    end

    -- 1. Check iscclosure itself if debug.info is present
    if not _clonefunctionPoisoned and _checkIsCClosure and _checkDebugInfo then
        local okC, srcC = pcall(_checkDebugInfo, _checkIsCClosure, "s")
        if not okC or (srcC ~= "[C]" and srcC ~= "=[C]") then
            _checkIsCClosure = nil
            _clonefunctionPoisoned = true
        end
    end

    -- 2. Inspect iscclosure(clonefunction)
    if not _clonefunctionPoisoned and _checkIsCClosure then
        local ok, isC = pcall(_checkIsCClosure, _rawClone)
        if not ok or isC ~= true then
            _clonefunctionPoisoned = true
        end
    end

    -- 3. Inspect debug.info(clonefunction, "s") == "[C]"
    if not _clonefunctionPoisoned and _checkDebugInfo then
        local ok, src = pcall(_checkDebugInfo, _rawClone, "s")
        if not ok or (src ~= "[C]" and src ~= "=[C]") then
            _clonefunctionPoisoned = true
        end
        local okL, line = pcall(_checkDebugInfo, _rawClone, "l")
        if not okL or line ~= -1 then
            _clonefunctionPoisoned = true
        end
    end

    -- 4. Functional clone canary test: authentic clonefunction returns a distinct closure pointer
    if not _clonefunctionPoisoned then
        local function _canary() return true end
        local okTest, clonedCanary = pcall(_rawClone, _canary)
        if not okTest or type(clonedCanary) ~= "function" or clonedCanary == _canary then
            _clonefunctionPoisoned = true
        end
    end

    if _clonefunctionPoisoned then
        _rawClone = nil
        warn("[Bootloader | ROOT-OF-TRUST BREACH]: Malicious clonefunction hook or alphabetical pre-emption detected! Discarding poisoned clone primitive.")
    end
end

local function _safeClone(fn)
    if _rawClone and type(fn) == "function" then
        local ok, cloned = pcall(_rawClone, fn)
        if ok and type(cloned) == "function" then
            return cloned
        end
    end
    return fn
end

-- Validate and capture pristine closures for all critical primitives
local function _capturePrimitive(rawFn, name)
    if not rawFn then return nil end
    if _checkIsLClosure then
        local okL, isL = pcall(_checkIsLClosure, rawFn)
        if okL and isL == true then
            _primitivesPoisoned = true
            warn("[Bootloader | ROOT-OF-TRUST BREACH]: Hooked Lua-closure detected for primitive: " .. tostring(name))
            return nil
        end
    end
    return _safeClone(rawFn)
end

-- Capture pristine unhookable C-closures for all critical primitives
local _writefile   = _capturePrimitive(writefile, "writefile")
local _readfile    = _capturePrimitive(readfile, "readfile")
local _isfile      = _capturePrimitive(isfile, "isfile")
local _isfolder    = _capturePrimitive(isfolder, "isfolder")
local _makefolder  = _capturePrimitive(makefolder, "makefolder")
local _delfile     = _capturePrimitive(delfile, "delfile")
local _listfiles   = _capturePrimitive(listfiles, "listfiles")
local _loadstring  = _capturePrimitive(loadstring, "loadstring")
local _clonedLoadstring = _loadstring
local _loadfile    = _capturePrimitive(loadfile, "loadfile")
local _dofile      = _capturePrimitive(dofile, "dofile")
local _request     = _capturePrimitive(request or http_request or (syn and syn.request) or (http and http.request), "request")
local _hookfunction = _capturePrimitive(hookfunction, "hookfunction")
local _isGameHttpGet = (game and type(game.HttpGet) == "function")
local _rawHttpGet  = (_isGameHttpGet and game.HttpGet) or (type(httpget) == "function" and httpget)
local _clonedHttpGet = _capturePrimitive(_rawHttpGet, "HttpGet")

-- Authenticate and capture native crypto primitives at Frame 0
local _capturedCryptHash = (type(crypt) == "table" and type(crypt.hash) == "function" and _isAuthenticCClosure(crypt.hash) and _safeClone(crypt.hash)) or nil
local _capturedCryptSha256 = (type(crypt) == "table" and type(crypt.sha256) == "function" and _isAuthenticCClosure(crypt.sha256) and _safeClone(crypt.sha256)) or nil
local _capturedSha256 = (type(sha256) == "function" and _isAuthenticCClosure(sha256) and _safeClone(sha256)) or nil
local _capturedSynCryptHash = (type(syn) == "table" and type(syn.crypt) == "table" and type(syn.crypt.hash) == "function" and _isAuthenticCClosure(syn.crypt.hash) and _safeClone(syn.crypt.hash)) or nil

-- Provide file-scoped shadow locals so internal operations strictly bind to cloned closures
local writefile  = _writefile
local readfile   = _readfile
local isfile     = _isfile
local isfolder   = _isfolder
local makefolder = _makefolder
local delfile    = _delfile
local listfiles  = _listfiles
local loadstring = _loadstring
local request    = _request

local function safeHttpGet(url)
    if _clonedHttpGet then
        local ok, res
        if _isGameHttpGet then
            ok, res = pcall(_clonedHttpGet, game, url)
        else
            ok, res = pcall(_clonedHttpGet, url)
        end
        if ok and res and type(res) == "string" then
            return res
        end
    end
    if _request then
        local ok, res = pcall(_request, { Url = url, Method = "GET" })
        if ok and res and (not res.StatusCode or res.StatusCode == 200) and res.Body then
            return res.Body
        end
    end
    return nil
end

-- ==============================================================================
-- STEP 3: CRYPTOGRAPHIC INTEGRITY & TOCTOU DEFENSE ENGINE (SHA-256)
-- ==============================================================================
local _K_SHA256 = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function pureLuauSha256(msg)
    local band = bit32.band
    local bnot = bit32.bnot
    local bxor = bit32.bxor
    local rrotate = bit32.rrotate
    local rshift = bit32.rshift

    local h0 = 0x6a09e667
    local h1 = 0xbb67ae85
    local h2 = 0x3c6ef372
    local h3 = 0xa54ff53a
    local h4 = 0x510e527f
    local h5 = 0x9b05688c
    local h6 = 0x1f83d9ab
    local h7 = 0x5be0cd19

    local len = #msg
    local bitLen = len * 8
    local padLen = (55 - (len % 64)) % 64
    local pad = string.char(0x80) .. string.rep(string.char(0), padLen)
    local highBits = math.floor(bitLen / 0x100000000)
    local lowBits = bitLen % 0x100000000
    local lenBytes = string.char(
        rshift(highBits, 24) % 256, rshift(highBits, 16) % 256, rshift(highBits, 8) % 256, highBits % 256,
        rshift(lowBits, 24) % 256, rshift(lowBits, 16) % 256, rshift(lowBits, 8) % 256, lowBits % 256
    )
    local full = msg .. pad .. lenBytes
    local totalBlocks = #full / 64

    local w = table.create(64, 0)

    for b = 0, totalBlocks - 1 do
        local offset = b * 64
        for i = 1, 16 do
            local idx = offset + (i - 1) * 4 + 1
            local b1, b2, b3, b4 = string.byte(full, idx, idx + 3)
            w[i] = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        end
        for i = 17, 64 do
            local v1 = w[i - 15]
            local s0 = bxor(rrotate(v1, 7), rrotate(v1, 18), rshift(v1, 3))
            local v2 = w[i - 2]
            local s1 = bxor(rrotate(v2, 17), rrotate(v2, 19), rshift(v2, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 0x100000000
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7

        for i = 1, 64 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (h + S1 + ch + _K_SHA256[i] + w[i]) % 0x100000000
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local temp2 = (S0 + maj) % 0x100000000

            h = g
            g = f
            f = e
            e = (d + temp1) % 0x100000000
            d = c
            c = b
            b = a
            a = (temp1 + temp2) % 0x100000000
        end

        h0 = (h0 + a) % 0x100000000
        h1 = (h1 + b) % 0x100000000
        h2 = (h2 + c) % 0x100000000
        h3 = (h3 + d) % 0x100000000
        h4 = (h4 + e) % 0x100000000
        h5 = (h5 + f) % 0x100000000
        h6 = (h6 + g) % 0x100000000
        h7 = (h7 + h) % 0x100000000
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

local function computeSha256(str)
    if type(str) ~= "string" then return nil end
    -- Check executor crypto library primitives captured and authenticated at Frame 0
    if _capturedCryptHash then
        local ok, h = pcall(_capturedCryptHash, str, "sha256")
        if ok and type(h) == "string" and #h == 64 then return h:lower() end
    end
    if _capturedCryptSha256 then
        local ok, h = pcall(_capturedCryptSha256, str)
        if ok and type(h) == "string" and #h == 64 then return h:lower() end
    end
    if _capturedSha256 then
        local ok, h = pcall(_capturedSha256, str)
        if ok and type(h) == "string" and #h == 64 then return h:lower() end
    end
    if _capturedSynCryptHash then
        local ok, h = pcall(_capturedSynCryptHash, str, "sha256")
        if ok and type(h) == "string" and #h == 64 then return h:lower() end
    end
    return pureLuauSha256(str)
end

local function verifyContentHash(content, expectedHash)
    if not expectedHash or expectedHash == "" then return true end
    if not content or type(content) ~= "string" then return false end
    local exp = expectedHash:lower():match("^%s*(%x+)%s*$")
    if not exp then return false end

    local h1 = computeSha256(content)
    if h1 and h1:lower() == exp then
        return true
    end
    local h2 = computeSha256(content:gsub("\r\n", "\n"))
    if h2 and h2:lower() == exp then
        return true
    end
    local h3 = computeSha256(content:gsub("\r\n", "\n"):gsub("\n", "\r\n"))
    if h3 and h3:lower() == exp then
        return true
    end
    return false
end

local bootStart = os.clock()

local rawGame = (workspace and workspace.Parent) or game
if not getgenv()._KernelOrigGame then
    getgenv()._KernelOrigGame = rawGame
end

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

if type(isfolder) ~= "function" or type(listfiles) ~= "function" or type(isfile) ~= "function" then
    print("[Bootloader]: Incompatible exploit environment.")
    getgenv()._OmniBootloaderRunning = false
    return
end

-- Universal Scheduler Exemption Registry
if not getgenv()._KernelExemptScripts then
    getgenv()._KernelExemptScripts = {}
end

local function isObfuscatedCode(src, chunkname)
    if chunkname and type(chunkname) == "string" and chunkname ~= "" then
        local cLower = chunkname:lower()
        if cLower:find("luraph", 1, true)
            or cLower:find("lph_", 1, true)
            or cLower:find("luaauth", 1, true)
            or cLower:find("luarmor", 1, true)
            or cLower:find("luaarmor", 1, true)
            or cLower:find("moonsec", 1, true)
            or cLower:find("ironbrew", 1, true)
            or cLower:find("plasmii", 1, true)
            or cLower:find("_obf", 1, true)
            or cLower:find(".obf", 1, true)
            or cLower:find("obfuscated", 1, true) then
            return true
        end
        local exempt = getgenv()._KernelExemptScripts
        if exempt and (exempt[cLower] or exempt[cLower:gsub("^[@%[]", "")]) then
            return true
        end
    end

    if type(src) ~= "string" or #src < 10 then return false end
    if src:sub(1, 4) == "\27Lua" then return true end

    local sample = #src > 10000 and src:sub(1, 10000) or src

    -- Structured source code inspection (30+ lines, reasonable avg line length, 5+ functions)
    local lineCount = 0
    for _ in sample:gmatch("[^\r\n]+") do
        lineCount = lineCount + 1
    end
    local avgLen = #sample / math.max(1, lineCount)
    local funcCount = 0
    for _ in sample:gmatch("%f[%w_]function%s*[%w_:%.]*%s*%(") do
        funcCount = funcCount + 1
    end

    -- Human-readable structured source code is not obfuscated unless it contains a dense VM line
    if lineCount >= 30 and avgLen <= 250 and funcCount >= 5 then
        for line in sample:gmatch("[^\r\n]+") do
            if #line > 2500 and not line:match("^%s*%-%-") then
                if line:find("string%.char") or line:find("bit32") or line:find("getfenv") or line:find("unpack") or line:find("table%.concat") then
                    return true
                end
            end
        end
        return false
    end

    local head = sample:sub(1, 4000):lower()
    if head:find("luraph", 1, true) ~= nil
        or head:find("lph_", 1, true) ~= nil
        or head:find("lh={", 1, true) ~= nil
        or head:find("lh = {", 1, true) ~= nil
        or head:find(",lh={},", 1, true) ~= nil
        or head:find("luaauth", 1, true) ~= nil
        or head:find("luarmor", 1, true) ~= nil
        or head:find("luaarmor", 1, true) ~= nil
        or head:find("la_script_id", 1, true) ~= nil
        or head:find("api.luaauth.com", 1, true) ~= nil
        or head:find("api.luarmor.net", 1, true) ~= nil
        or head:find("moonsec", 1, true) ~= nil
        or head:find("ironbrew", 1, true) ~= nil
        or head:find("prometheus", 1, true) ~= nil
        or head:find("psu obfuscator", 1, true) ~= nil
        or head:find("aztup", 1, true) ~= nil
        or head:find("synapse xen", 1, true) ~= nil
        or head:find("boron", 1, true) ~= nil
        or head:find("obfuscated with", 1, true) ~= nil
        or head:find("this file was obfuscated", 1, true) ~= nil
        or head:find("protected by", 1, true) ~= nil then
        return true
    end

    -- Barcode variable names
    local barcodeCount = 0
    for _ in sample:gmatch("[Il1][Il1][Il1][Il1][Il1][Il1][Il1][Il1]+") do
        barcodeCount = barcodeCount + 1
        if barcodeCount >= 5 then return true end
    end

    -- Hex variable identifiers
    local hexVarCount = 0
    for _ in sample:gmatch("_0x%x%x%x%x+") do
        hexVarCount = hexVarCount + 1
        if hexVarCount >= 8 then return true end
    end

    -- Packed decimal escapes
    local escapedByteCount = 0
    for _ in sample:gmatch("\\[0-9][0-9][0-9]") do
        escapedByteCount = escapedByteCount + 1
        if escapedByteCount > 80 then return true end
    end

    -- Packed hex escapes
    local hexEscapeCount = 0
    for _ in sample:gmatch("\\x%x%x") do
        hexEscapeCount = hexEscapeCount + 1
        if hexEscapeCount > 80 then return true end
    end

    -- Dense single line VM wrapper
    for line in sample:gmatch("[^\r\n]+") do
        if #line > 2500 and not line:match("^%s*%-%-") then
            if line:find("string%.char") or line:find("bit32") or line:find("getfenv") or line:find("unpack") or line:find("table%.concat") then
                return true
            end
        end
    end

    -- Excessive dynamic string.char
    local strCharCount = 0
    for _ in sample:gmatch("string%.char%s*%(") do
        strCharCount = strCharCount + 1
        if strCharCount >= 15 then return true end
    end

    return false
end

-- ==============================================================================
-- ROOT OF TRUST: REMOTE SCRIPT URL LEDGER & ZERO-TRUST LOADSTRING GATEWAY
-- ==============================================================================
local TRUSTED_URLS_LEDGER_PATH = "Omni_TrustedUrls.json"
local TRUSTED_SCRIPTS_DIR = "omni_trusted_scripts"

if not isfolder(TRUSTED_SCRIPTS_DIR) then
    pcall(makefolder, TRUSTED_SCRIPTS_DIR)
end

-- GUI Root Finder
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
    local Players = game:GetService("Players")
    if Players and Players.LocalPlayer then
        local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
        if pg then return pg end
    end
    return nil
end

-- Forward declarations for dynamic security gate controller
local promptRemoteScriptSecurity = nil
local ensureUpdateGateController = nil
local updateGateController = nil
local initUpdateGate = nil
local isScriptReviewActive = false
local isScriptReviewPending = false
local scriptReviewCallback = nil

-- Network Monitor & URL Capture Cache
local _fetchedUrlByContentHash = {}
local _recentFetchesByUrl = {}
local _sessionApprovedHashes = {}

local function recordFetch(url, body)
    if type(url) ~= "string" or type(body) ~= "string" then return end
    local h = computeSha256(body)
    if h then
        _fetchedUrlByContentHash[h] = url
        local normH = computeSha256(body:gsub("\r\n", "\n"))
        if normH then
            _fetchedUrlByContentHash[normH] = url
        end
        _recentFetchesByUrl[url] = { hash = h, body = body, time = os.clock() }
    end
end

-- Network Interception: Record remote script downloads without hooking low-level C primitives
-- We preserve authentic C-closures on request and game.__namecall to prevent triggering
-- anti-HttpSpy anti-tamper freeze routines in commercial obfuscators (Luraph, LuaArmor).
local interceptedHttpGet = function(self, url, ...)
    local targetSelf = self
    local targetUrl = url
    if type(targetSelf) == "string" and targetUrl == nil then
        targetUrl = targetSelf
        targetSelf = game
    end
    local body = nil
    if _clonedHttpGet then
        if _isGameHttpGet then
            body = _clonedHttpGet(targetSelf or game, targetUrl, ...)
        else
            body = _clonedHttpGet(targetUrl, ...)
        end
    end
    if type(body) == "string" and type(targetUrl) == "string" then
        recordFetch(targetUrl, body)
    end
    return body
end

local interceptedRequest = function(options, ...)
    if not _request then return nil end
    local res = _request(options, ...)
    if type(options) == "table" and type(options.Url) == "string" and type(res) == "table" and type(res.Body) == "string" then
        local method = options.Method and string.upper(tostring(options.Method)) or "GET"
        if method == "GET" then
            recordFetch(options.Url, res.Body)
        end
    end
    return res
end

-- Safely expose non-invasive global helper without overriding authentic C-closures
-- (Note: method == "HttpGet" is handled natively without hooking __namecall)
if type(getgenv().HttpGet) == "function" and getgenv().HttpGet ~= _rawHttpGet then
    getgenv().HttpGet = (newcclosure and newcclosure(interceptedHttpGet)) or interceptedHttpGet
end

-- Windows-Safe Filename Sanitizer for Cached Trusted Scripts
local function sanitizeUrlToFilename(url)
    if not url or type(url) ~= "string" then return "unknown_script.lua" end
    local clean = url:gsub("^https?://", "")
    clean = clean:gsub("%?.*$", "")
    clean = clean:gsub("[^%w%.%-_]", "_")
    clean = clean:gsub("_+", "_")
    if #clean > 60 then
        clean = clean:sub(1, 60)
    end
    local urlHash = computeSha256(url)
    local shortHash = (urlHash and urlHash:sub(1, 10)) or "hash"
    return clean .. "_" .. shortHash .. ".lua"
end

-- Persistent Ledger Management
local function loadTrustedUrlLedger()
    if isfile(TRUSTED_URLS_LEDGER_PATH) then
        local ok, raw = pcall(readfile, TRUSTED_URLS_LEDGER_PATH)
        if ok and raw and #raw > 0 then
            local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
            if decOk and type(data) == "table" then
                data.urls = data.urls or {}
                data.hashes = data.hashes or {}
                return data
            end
        end
    end
    return { version = 1, urls = {}, hashes = {} }
end

local function saveTrustedUrlLedger(ledger)
    if not ledger or type(ledger) ~= "table" then return false end
    local okEnc, json = pcall(function() return HttpService:JSONEncode(ledger) end)
    if okEnc and json then
        local okW = pcall(writefile, TRUSTED_URLS_LEDGER_PATH, json)
        return okW
    end
    return false
end

-- Security Heuristics Audit
local function auditScriptContent(code)
    local badges = {}
    if not code or #code == 0 then return badges end

    local sample = #code > 10000 and code:sub(1, 10000) or code

    -- Obfuscation Detection
    local isObfuscated = false

    -- 1. Precompiled Bytecode Signature (Raw binary header)
    if code:sub(1, 4) == "\27Lua" then
        isObfuscated = true
    end

    -- 2. Barcode variable names (e.g. IlIIlllIIllI)
    if not isObfuscated then
        local barcodeCount = 0
        for _ in sample:gmatch("[Il1][Il1][Il1][Il1][Il1][Il1][Il1][Il1]+") do
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
        for _ in sample:gmatch("_0x%x%x%x%x+") do
            hexVarCount = hexVarCount + 1
            if hexVarCount >= 8 then
                isObfuscated = true
                break
            end
        end
    end

    -- 4. Packed Decimal Byte Streams (\123\145\167...)
    if not isObfuscated then
        local escapedByteCount = 0
        for _ in sample:gmatch("\\[0-9][0-9][0-9]") do
            escapedByteCount = escapedByteCount + 1
            if escapedByteCount > 80 then
                isObfuscated = true
                break
            end
        end
    end

    -- 5. Packed Hex Byte Streams (\x41\x42\x43...)
    if not isObfuscated then
        local hexEscapeCount = 0
        for _ in sample:gmatch("\\x%x%x") do
            hexEscapeCount = hexEscapeCount + 1
            if hexEscapeCount > 80 then
                isObfuscated = true
                break
            end
        end
    end

    -- 6. Giant dense single-line VM wrapper (> 2500 chars with string decoding)
    if not isObfuscated then
        for line in sample:gmatch("[^\r\n]+") do
            if #line > 2500 and not line:match("^%s*%-%-") then
                if line:find("string%.char") or line:find("bit32") or line:find("getfenv") or line:find("unpack") or line:find("table%.concat") then
                    isObfuscated = true
                    break
                end
            end
        end
    end

    -- 7. Excessive dynamic string.char calls
    if not isObfuscated then
        local strCharCount = 0
        for _ in sample:gmatch("string%.char%s*%(") do
            strCharCount = strCharCount + 1
            if strCharCount >= 15 then
                isObfuscated = true
                break
            end
        end
    end

    -- 8. Known Obfuscator Signatures
    if not isObfuscated then
        local head = code:sub(1, 4000):lower()
        if isObfuscatedCode(head, "") then
            isObfuscated = true
        else
            local lower = code:lower()
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
        end
    end

    -- 9. Zero-Width Unicode Smuggling & Trojan Source BiDi Overrides (CVE-2021-42574)
    local hasZeroWidth = false
    local hasBidiTrojan = false
    local hasHomoglyphs = false

    -- Check Zero-Width / Invisible Space sequences
    if code:find("\226\128\139") or code:find("\226\128\140") or code:find("\226\128\141")
        or code:find("\239\187\191") or code:find("\226\128\142") or code:find("\226\128\143")
        or code:find("\226\128[\128-\138]") or code:find("\226\129\160") or code:find("\194\173") then
        hasZeroWidth = true
    end

    -- Check Trojan Source BiDi Overrides / Isolates (U+202A-U+202E and U+2066-U+2069)
    if code:find("\226\128[\170-\174]") or code:find("\226\129[\166-\169]") then
        hasBidiTrojan = true
    end

    -- Check Cyrillic/Greek Homoglyphs disguised in identifiers (strip comments & string literals first)
    for line in code:gmatch("[^\r\n]+") do
        if not line:match("^%s*%-%-") then -- Skip pure comments
            local strippedLine = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
            if strippedLine:find("[\208-\209][\128-\191]") or strippedLine:find("[\206-\207][\128-\191]") then
                hasHomoglyphs = true
                break
            end
        end
    end

    if hasBidiTrojan then
        isObfuscated = true
        table.insert(badges, { label = "🛑 Trojan Source (BiDi)", color = Color3.fromRGB(255, 35, 35) })
    elseif hasZeroWidth or hasHomoglyphs then
        isObfuscated = true
        table.insert(badges, { label = "🚨 Unicode Smuggling", color = Color3.fromRGB(255, 45, 45) })
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

-- Anti-Trojan Source & Homoglyph Diff Sanitizer (CVE-2021-42574)
local function sanitizeDiffText(text)
    if not text or type(text) ~= "string" then return "" end
    local s = text
    -- Hard safety clamp: Never process or assign strings > 1200 chars to a TextLabel
    if #s > 1200 then
        s = s:sub(1, 1200) .. " ... [line truncated: " .. tostring(#text) .. " chars]"
    end
    -- Reveal Zero-Width characters and invisible controls
    s = s:gsub("\239\187\191", "[BOM]")
    s = s:gsub("\226\128\139", "[ZWSP]")
    s = s:gsub("\226\128\140", "[ZWNJ]")
    s = s:gsub("\226\128\141", "[ZWJ]")
    s = s:gsub("\226\128\142", "[LRM]")
    s = s:gsub("\226\128\143", "[RLM]")
    s = s:gsub("\226\128[\128-\138]", "[INV-SP]")
    s = s:gsub("\226\129\160", "[WJ]")
    s = s:gsub("\194\173", "[SHY]")
    -- Reveal BiDi overrides / isolates
    s = s:gsub("\226\128\170", "[LRE]")
    s = s:gsub("\226\128\171", "[RLE]")
    s = s:gsub("\226\128\172", "[PDF]")
    s = s:gsub("\226\128\173", "[LRO]")
    s = s:gsub("\226\128\174", "[RLO]")
    s = s:gsub("\226\129\166", "[LRI]")
    s = s:gsub("\226\129\167", "[RLI]")
    s = s:gsub("\226\129\168", "[FSI]")
    s = s:gsub("\226\129\169", "[PDI]")
    -- Reveal non-printable ASCII control characters (keep tabs and newlines)
    s = s:gsub("[\1-\8\11-\12\14-\31\127]", function(c)
        return string.format("\\x%02X", string.byte(c))
    end)
    if #s > 1500 then
        s = s:sub(1, 1500)
    end
    return s
end

-- Ultra-Fast Linear Diff Engine
local function computeLineDiff(oldCode, newCode)
    local CHUNK_SIZE = 800
    local oldLines = {}
    if oldCode and #oldCode > 0 then
        for line in (oldCode .. "\n"):gmatch("(.-)\r?\n") do
            if #line > CHUNK_SIZE then
                for i = 1, math.min(#line, CHUNK_SIZE * 5), CHUNK_SIZE do
                    table.insert(oldLines, line:sub(i, i + CHUNK_SIZE - 1))
                end
            else
                table.insert(oldLines, line)
            end
            if #oldLines >= 500 then break end
        end
    end

    local newLines = {}
    if newCode and #newCode > 0 then
        for line in (newCode .. "\n"):gmatch("(.-)\r?\n") do
            if #line > CHUNK_SIZE then
                for i = 1, math.min(#line, CHUNK_SIZE * 5), CHUNK_SIZE do
                    table.insert(newLines, line:sub(i, i + CHUNK_SIZE - 1))
                end
            else
                table.insert(newLines, line)
            end
            if #newLines >= 500 then break end
        end
    end

    if #oldLines == 0 then
        local diff = {}
        for idx, line in ipairs(newLines) do
            table.insert(diff, { type = "add", lineNum = idx, text = sanitizeDiffText(line) })
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
    for idx, entry in ipairs(rawEntries) do
        if keep[idx] then
            if skipped > 0 then
                table.insert(diff, { type = "info", lineNum = 0, text = string.format("... [%d unchanged lines] ...", skipped) })
                skipped = 0
            end
            table.insert(diff, {
                type = entry.type,
                lineNum = entry.lineNum,
                text = sanitizeDiffText(entry.text)
            })
        else
            skipped = skipped + 1
        end
    end

    return diff, #newLines, adds, removes
end

ensureUpdateGateController = function()
    if updateGateController then return updateGateController end
    local gp = getGuiParent()
    if not gp then
        local Players = pcall(function() return game:GetService("Players") end) and game:GetService("Players")
        if Players and Players.LocalPlayer then
            gp = Players.LocalPlayer:FindFirstChild("PlayerGui") or (Players.LocalPlayer:WaitForChild("PlayerGui", 2))
        end
    end
    if gp and type(initUpdateGate) == "function" then
        local ok, gate = pcall(initUpdateGate, gp)
        if ok and type(gate) == "table" then
            updateGateController = gate
            return gate
        else
            warn("[Omni Security Gate]: initUpdateGate failed: " .. tostring(gate))
        end
    else
        if not gp then
            warn("[Omni Security Gate]: Unable to locate GUI parent (CoreGui/PlayerGui)")
        elseif type(initUpdateGate) ~= "function" then
            warn("[Omni Security Gate]: initUpdateGate not ready yet (" .. type(initUpdateGate) .. ")")
        end
    end
    return nil
end

-- Universal Scheduler Exemption Registry
if not getgenv()._KernelExemptScripts then
    getgenv()._KernelExemptScripts = {}
end

if not getgenv()._AdaptiveExecutionGatewayInstalled then
    local origLoadstring = _clonedLoadstring or getgenv().loadstring or loadstring
    getgenv()._KernelOrigLoadstring = nil
    if type(origLoadstring) == "function" then
        local _exemptObfuscatedClosures = setmetatable({}, { __mode = "k" })
        local _exemptObfuscatedCallers = {}
        local _exemptObfuscatedThreads = setmetatable({}, { __mode = "k" })
        local _lastApprovedObfuscatedExecTime = 0

        for _, k in ipairs({ "luraph", "luaauth", "luarmor", "luaarmor", "moonsec", "ironbrew", "plasmii", "prometheus", "psu obfuscator", "synapse xen", "boron", "aztup" }) do
            _exemptObfuscatedCallers[k] = true
        end

        local function sanitizeCallerChunk(name)
            if not name or type(name) ~= "string" then return "" end
            local s = name:gsub("^%[string%s+\"", ""):gsub("\"%]$", ""):gsub("^[@%[%]=]", ""):gsub("%]$", "")
            return s:lower()
        end

        local function compileExecutableChunk(code, chunk, isObf)
            local compiledFn, compileErr = origLoadstring(code, chunk)
            if not compiledFn then
                return nil, compileErr
            end

            if isObf then
                _lastApprovedObfuscatedExecTime = os.clock()
                if chunk and type(chunk) == "string" and chunk ~= "" then
                    local cleanChunk = sanitizeCallerChunk(chunk)
                    if cleanChunk ~= "" then
                        _exemptObfuscatedCallers[cleanChunk] = true
                    end
                end

                if type(compiledFn) == "function" then
                    _exemptObfuscatedClosures[compiledFn] = true
                    local rawCompiled = compiledFn
                    local wrappedFn = function(...)
                        local curThread = coroutine.running()
                        _exemptObfuscatedThreads[curThread] = os.clock() + 60.0
                        _lastApprovedObfuscatedExecTime = os.clock()
                        return rawCompiled(...)
                    end
                    _exemptObfuscatedClosures[wrappedFn] = true
                    return wrappedFn
                end
            end

            return compiledFn
        end

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

            if type(src) ~= "string" or #src == 0 then
                return origLoadstring(src, chunkname)
            end

            -- 1. Thread-Level Exemption Check (Instantaneous 0ms lookup)
            local curThread = coroutine.running()
            if _exemptObfuscatedThreads[curThread] and (os.clock() < _exemptObfuscatedThreads[curThread]) then
                return origLoadstring(src, chunkname)
            end

            -- 2. Stack origin inspection: check if caller itself is internal or an exempt/obfuscated script
            local isCallerExempt = false
            local isCallerObfuscatedExempt = false
            if debug and debug.info then
                local immSrc = debug.info(2, "s")
                if immSrc and type(immSrc) == "string" and immSrc ~= "" and immSrc ~= "[C]" then
                    local cleanImm = sanitizeCallerChunk(immSrc)
                    if cleanImm:find("remoteexecute") or cleanImm:find("bootloader") then
                        isCallerExempt = true
                    end
                end
                if not isCallerExempt then
                    for lvl = 2, 20 do
                        local okF, cFunc = pcall(debug.info, lvl, "f")
                        if okF and cFunc and _exemptObfuscatedClosures[cFunc] then
                            isCallerExempt = true
                            isCallerObfuscatedExempt = true
                            break
                        end

                        local okS, cSrc = pcall(debug.info, lvl, "s")
                        if okS and cSrc and type(cSrc) == "string" and cSrc ~= "" and cSrc ~= "[C]" then
                            local clean = sanitizeCallerChunk(cSrc)
                            if _exemptObfuscatedCallers[clean]
                                or clean:find("luraph", 1, true)
                                or clean:find("luaauth", 1, true)
                                or clean:find("luarmor", 1, true)
                                or clean:find("luaarmor", 1, true)
                                or clean:find("moonsec", 1, true)
                                or clean:find("ironbrew", 1, true)
                                or clean:find("plasmii", 1, true)
                                or clean:find("omni_trusted_scripts", 1, true) then
                                isCallerExempt = true
                                isCallerObfuscatedExempt = true
                                break
                            end
                            if clean:find("bootloader", 1, true) or clean:find("taskmanager", 1, true)
                                or clean:find("enhancementsuite", 1, true) or clean:find("taskscheduler", 1, true)
                                or clean:find("remoteexecute", 1, true)
                                or (getgenv()._KernelExemptScripts and getgenv()._KernelExemptScripts[clean]) then
                                isCallerExempt = true
                                break
                            end
                        end
                    end
                end
            end

            -- 3. Temporal Unpack Lease (Dynamic loadstrings within 15 seconds of approved obfuscated script run)
            if not isCallerExempt and (os.clock() - _lastApprovedObfuscatedExecTime < 15.0) then
                local chunkLow = (chunkname and type(chunkname) == "string") and chunkname:lower() or ""
                if chunkLow:find("luraph", 1, true)
                    or chunkLow:find("luaauth", 1, true)
                    or chunkLow:find("luarmor", 1, true)
                    or chunkLow:find("luaarmor", 1, true)
                    or chunkLow:find("moonsec", 1, true)
                    or chunkLow:find("ironbrew", 1, true)
                    or _exemptObfuscatedCallers[sanitizeCallerChunk(chunkname)]
                    or isObfuscatedCode(src, chunkname) then
                    isCallerExempt = true
                    isCallerObfuscatedExempt = true
                end
            end

            -- If internal Omni caller or approved obfuscated script, bypass security gate directly with authentic loadstring
            if isCallerExempt then
                if isCallerObfuscatedExempt then
                    _exemptObfuscatedThreads[curThread] = os.clock() + 60.0
                end
                return origLoadstring(src, chunkname)
            end

            local srcHash = computeSha256(src)
            local normSrcHash = computeSha256(src:gsub("\r\n", "\n"))

            -- 1. Identify URL
            local targetUrl = _fetchedUrlByContentHash[srcHash] or _fetchedUrlByContentHash[normSrcHash]
            if not targetUrl and chunkname and type(chunkname) == "string" then
                targetUrl = chunkname:match("^@?(https?://[%w-_%.%?%.:/%+=&]+)")
            end
            if not targetUrl then
                local head = src:sub(1, 300)
                targetUrl = head:match("%-%-%!url:%s*(https?://[%w-_%.%?%.:/%+=&]+)")
                         or head:match("%-%-%s*(https?://raw%.githubusercontent%.com/[%w-_%.%?%.:/%+=&]+)")
                         or head:match("%-%-%s*(https?://pastebin%.com/raw/[%w-_%.%?%.:/%+=&]+)")
            end

            local ledger = loadTrustedUrlLedger()

            -- If targetUrl not identified yet, check if this exact script content hash was already trusted in ledger
            if not targetUrl and ledger.urls then
                for u, entry in pairs(ledger.urls) do
                    if entry.hash == srcHash or entry.hash == normSrcHash then
                        targetUrl = u
                        break
                    end
                end
            end

            if targetUrl then
                local trustedEntry = ledger.urls[targetUrl]
                if trustedEntry then
                    -- Known URL! Check if content hash matches local copy
                    local hashMatches = (trustedEntry.hash == srcHash) or (trustedEntry.hash == normSrcHash)
                    if not hashMatches and trustedEntry.local_file and isfile(trustedEntry.local_file) then
                        local localCopy = readfile(trustedEntry.local_file)
                        if localCopy then
                            local locHash = computeSha256(localCopy)
                            local locNorm = computeSha256(localCopy:gsub("\r\n", "\n"))
                            if locHash == srcHash or locNorm == normSrcHash or locHash == normSrcHash then
                                hashMatches = true
                            end
                        end
                    end

                    if hashMatches then
                        -- Content is identical to approved local copy: instant pass-through!
                        local effectiveChunk = chunkname or ("@" .. targetUrl)
                        local isObf = isObfuscatedCode(src, effectiveChunk)
                        if isObf then
                            _exemptObfuscatedCallers[sanitizeCallerChunk(targetUrl)] = true
                            if trustedEntry.local_file then
                                _exemptObfuscatedCallers[sanitizeCallerChunk(trustedEntry.local_file)] = true
                            end
                        end
                        return compileExecutableChunk(src, effectiveChunk, isObf)
                    else
                        -- Content was updated by the author!
                        local localCopy = (trustedEntry.local_file and isfile(trustedEntry.local_file) and readfile(trustedEntry.local_file)) or ""

                        if not promptRemoteScriptSecurity and ensureUpdateGateController then
                            ensureUpdateGateController()
                        end

                        local decision = "block"
                        if promptRemoteScriptSecurity then
                            decision = promptRemoteScriptSecurity({
                                mode = "script_update",
                                url = targetUrl,
                                oldCode = localCopy,
                                newCode = src,
                                chunkname = chunkname,
                                badges = auditScriptContent(src)
                            })
                        else
                            warn("[Omni Security Gate]: GUI unavailable to review update for " .. tostring(targetUrl) .. "; blocking execution for safety.")
                        end

                        if decision == "approve" then
                            if trustedEntry.local_file then
                                pcall(writefile, trustedEntry.local_file, src)
                            end
                            trustedEntry.hash = srcHash
                            trustedEntry.last_updated = os.time()
                            saveTrustedUrlLedger(ledger)
                            local effectiveChunk = chunkname or ("@" .. targetUrl)
                            local isObf = isObfuscatedCode(src, effectiveChunk)
                            if isObf then
                                _exemptObfuscatedCallers[sanitizeCallerChunk(targetUrl)] = true
                                if trustedEntry.local_file then
                                    _exemptObfuscatedCallers[sanitizeCallerChunk(trustedEntry.local_file)] = true
                                end
                            end
                            return compileExecutableChunk(src, effectiveChunk, isObf)
                        elseif decision == "run_previous" then
                            if localCopy and localCopy ~= "" then
                                local effectiveChunk = chunkname or ("@" .. targetUrl)
                                local isObf = isObfuscatedCode(localCopy, effectiveChunk)
                                if isObf then
                                    _exemptObfuscatedCallers[sanitizeCallerChunk(targetUrl)] = true
                                    if trustedEntry.local_file then
                                        _exemptObfuscatedCallers[sanitizeCallerChunk(trustedEntry.local_file)] = true
                                    end
                                end
                                return compileExecutableChunk(localCopy, effectiveChunk, isObf)
                            else
                                return nil, "Omni Security Gate: No previous safe version found on disk"
                            end
                        elseif decision == "block" or not decision then
                            return nil, "Omni Security Gate: Execution blocked by user"
                        else
                            return nil, "Omni Security Gate: Execution blocked by user"
                        end
                    end
                else
                    -- Brand New Remote Script URL!
                    if not promptRemoteScriptSecurity and ensureUpdateGateController then
                        ensureUpdateGateController()
                    end

                    local decision = "block"
                    if promptRemoteScriptSecurity then
                        decision = promptRemoteScriptSecurity({
                            mode = "script_new",
                            url = targetUrl,
                            oldCode = "",
                            newCode = src,
                            chunkname = chunkname,
                            badges = auditScriptContent(src)
                        })
                    else
                        warn("[Omni Security Gate]: GUI unavailable to approve new script for " .. tostring(targetUrl) .. "; blocking execution for safety.")
                    end

                    if decision == "approve" then
                        local filename = TRUSTED_SCRIPTS_DIR .. "/" .. sanitizeUrlToFilename(targetUrl)
                        pcall(writefile, filename, src)
                        ledger.urls[targetUrl] = {
                            url = targetUrl,
                            hash = srcHash,
                            local_file = filename,
                            first_trusted = os.time(),
                            last_updated = os.time()
                        }
                        saveTrustedUrlLedger(ledger)
                        local effectiveChunk = chunkname or ("@" .. targetUrl)
                        local isObf = isObfuscatedCode(src, effectiveChunk)
                        if isObf then
                            _exemptObfuscatedCallers[sanitizeCallerChunk(targetUrl)] = true
                            _exemptObfuscatedCallers[sanitizeCallerChunk(filename)] = true
                        end
                        return compileExecutableChunk(src, effectiveChunk, isObf)
                    else
                        return nil, "Omni Security Gate: Execution blocked by user"
                    end
                end
            else
                -- Dynamic / Inline loadstring (no URL)
                if _sessionApprovedHashes[srcHash] or (ledger.hashes and ledger.hashes[srcHash]) then
                    local isObf = isObfuscatedCode(src, chunkname)
                    return compileExecutableChunk(src, chunkname, isObf)
                end

                local badges = auditScriptContent(src)
                local hasDanger = false
                for _, b in ipairs(badges) do
                    if b.label:find("🛑") or b.label:find("🚨") or b.label:find("⚠️") then
                        hasDanger = true
                        break
                    end
                end

                if hasDanger or #src > 1000 then
                    if not promptRemoteScriptSecurity and ensureUpdateGateController then
                        ensureUpdateGateController()
                    end

                    local decision = "block"
                    if promptRemoteScriptSecurity then
                        decision = promptRemoteScriptSecurity({
                            mode = "script_inline",
                            url = nil,
                            chunkname = chunkname or "Dynamic Script",
                            oldCode = "",
                            newCode = src,
                            badges = badges
                        })
                    else
                        warn("[Omni Security Gate]: Dynamic code blocked (GUI unavailable)")
                    end

                    if decision == "approve" then
                        _sessionApprovedHashes[srcHash] = true
                        ledger.hashes[srcHash] = true
                        saveTrustedUrlLedger(ledger)
                        local isObf = isObfuscatedCode(src, chunkname)
                        return compileExecutableChunk(src, chunkname, isObf)
                    else
                        return nil, "Omni Security Gate: Execution blocked by user"
                    end
                else
                    _sessionApprovedHashes[srcHash] = true
                    local isObf = isObfuscatedCode(src, chunkname)
                    return compileExecutableChunk(src, chunkname, isObf)
                end
            end
        end

        local wrappedLoadstring = (newcclosure and newcclosure(loadstringShim)) or loadstringShim
        getgenv().loadstring = wrappedLoadstring
        getgenv()._KernelOrigLoadstring = nil
        getgenv()._AdaptiveExecutionGatewayInstalled = true
        getgenv()._KernelLoadstringShimInstalled = true

        -- Intercept loadfile and dofile so disk payloads route through the Zero-Trust gate
        local origLoadfile = _loadfile or getgenv().loadfile
        if type(origLoadfile) == "function" then
            local function loadfileShim(path, chunkname)
                if not path or type(path) ~= "string" then
                    return nil, "invalid argument #1 to 'loadfile' (string expected, got " .. typeof(path) .. ")"
                end
                if not isfile(path) then
                    return nil, "cannot open " .. tostring(path) .. ": No such file or directory"
                end
                local ok, content = pcall(readfile, path)
                if not ok or type(content) ~= "string" then
                    return nil, "cannot open " .. tostring(path) .. ": Failed to read file"
                end
                return loadstringShim(content, chunkname or ("@" .. tostring(path)))
            end
            getgenv().loadfile = (newcclosure and newcclosure(loadfileShim)) or loadfileShim
        end

        local origDofile = _dofile or getgenv().dofile
        if type(origDofile) == "function" then
            local function dofileShim(path, ...)
                local fn, err = getgenv().loadfile(path)
                if not fn then
                    error(err or ("cannot open " .. tostring(path)), 2)
                end
                return fn(...)
            end
            getgenv().dofile = (newcclosure and newcclosure(dofileShim)) or dofileShim
        end

        -- Passive Integrity: Watchdog ensures loadstring / loadfile remain bound without hooking metatables or C closures
        -- (Preserves native getgenv() metatable and authentic hookfunction C-closure for Luraph / LuaArmor anti-tamper)

        -- Background Watchdog: Re-assert loadstring integrity if tampered with via rawset
        task.spawn(function()
            while true do
                task.wait(2.0)
                if getgenv().loadstring ~= wrappedLoadstring then
                    getgenv().loadstring = wrappedLoadstring
                end
                if getgenv()._KernelOrigLoadstring ~= nil then
                    getgenv()._KernelOrigLoadstring = nil
                end
            end
        end)
    end
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

-- Check 4: Alphabetical pre-emption or clonefunction hook poisoning detected at Step 2
if _clonefunctionPoisoned then
    SafeMode = true
    SafeModeReason = "ClonefunctionPoisoning"
    warn("[Bootloader]: ⚠️ ALPHABETICAL PRE-EMPTION / HOOK POISONING DETECTED — Activating Safe Mode!")
elseif _primitivesPoisoned then
    SafeMode = true
    SafeModeReason = "PrimitivePoisoning"
    warn("[Bootloader]: ⚠️ PRIMITIVE HOOK POISONING DETECTED — Activating Safe Mode!")
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
                -- Verify SHA-256 integrity of Bootloader_Updated if known in manifest or ledger
                local handoffStage = lookupManifestStage and (lookupManifestStage("Bootloader_Updated", updatedPath) or lookupManifestStage("Bootloader", updatedPath))
                local expectedHandoffSha = handoffStage and handoffStage.sha256
                if not expectedHandoffSha and type(loadLedger) == "function" then
                    local ledger = loadLedger()
                    local comp = (ledger and ledger.components and (ledger.components["Bootloader_Updated"] or ledger.components["Bootloader"]))
                    if comp then expectedHandoffSha = comp.sha256 end
                end
                if expectedHandoffSha and not verifyContentHash(updatedCode, expectedHandoffSha) then
                    warn(string.format("[Bootloader | INTEGRITY BREACH]: Bootloader_Updated SHA-256 hash mismatch! Expected: %s. Aborting untrusted handoff.", tostring(expectedHandoffSha)))
                    pcall(delfile, updatedPath)
                    isEligible = false
                end
            end

            if isEligible then
                local updatedFn, compileErr = _clonedLoadstring(updatedCode, "@Bootloader_Updated")
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
    while true do
        local ok, res = pcall(predicate)
        if ok and res then
            return true
        end
        if (os.clock() - start) >= timeoutSec then
            return false
        end
        task.wait(pollInterval)
    end
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


local function fetchGithubScript(url)
    local content = safeHttpGet(url)
    if content and type(content) == "string" then
        local trimmed = content:match("^%s*(.-)%s*$")
        if trimmed == "404: Not Found" or trimmed:find("404: Not Found", 1, true) or trimmed:find("400: Invalid Request", 1, true) then
            return nil
        end
        return content
    end
    return nil
end

-- ==============================================================================
-- LEDGER MANAGEMENT & INITIAL CORE BOOTSTRAP GATE
-- ==============================================================================
local LEDGER_PATH = "Omni_Ledger.json"
local KERNEL_INIT_MARKER = "Omni_KernelInitialized.marker"

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

-- ==============================================================================
-- SANDBOX PATH TRAVERSAL SANITIZATION & BOUNDARY VALIDATION
-- ==============================================================================
local function validateSafeLocalPath(path)
    if type(path) ~= "string" or #path == 0 or #path > 260 then
        return nil
    end
    -- Reject null bytes and non-printable control characters
    if path:find("[\0-\31\127]") then
        return nil
    end
    -- Reject illegal Windows filename characters (< > : " | ? *)
    if path:find('[<>:"|%?%*]') then
        return nil
    end
    -- Reject URL-encoded traversal (%2e, %2f, %5c, %25)
    local lowerPath = path:lower()
    if lowerPath:find("%%2e") or lowerPath:find("%%2f") or lowerPath:find("%%5c") or lowerPath:find("%%25") then
        return nil
    end
    -- Reject absolute paths (leading slashes / or \)
    if path:match("^[/\\]") then
        return nil
    end
    -- Normalize backslashes to forward slashes for validation
    local normalized = path:gsub("\\", "/")
    -- Reject directory traversal (../ or /.. or ^../ or /..$)
    if normalized:find("%.%./") or normalized:find("/%.%.") or normalized == ".." or normalized:match("^%.%.$") then
        return nil
    end
    -- Reject consecutive slashes
    if normalized:find("//") then
        return nil
    end
    -- Reject trailing dots or whitespace (Windows canonicalization vulnerability)
    if normalized:match("[%s%.]$") then
        return nil
    end
    -- Enforce sandbox boundary: must be inside autoexec/ or workspace/ or be a local filename
    if not (normalized:match("^autoexec/") or normalized:match("^workspace/") or not normalized:find("/")) then
        return nil
    end
    -- Reject Windows DOS reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
    local fileName = normalized:match("[^/]+$") or normalized
    local baseName = fileName:match("^([^%.]+)") or fileName
    local upperBase = baseName:upper()
    if upperBase == "CON" or upperBase == "PRN" or upperBase == "AUX" or upperBase == "NUL"
        or upperBase:match("^COM[1-9]$") or upperBase:match("^LPT[1-9]$") then
        return nil
    end
    -- Reject targeting bootloader core files and runtime lock/sentinel files
    local lowerNorm = normalized:lower()
    if lowerNorm == "bootloader.lua" or lowerNorm == "autoexec/bootloader.lua"
        or lowerNorm:find("bootloader_running%.lock")
        or lowerNorm:find("bootloader_handoff%.lock")
        or lowerNorm:find("safe_mode%.lock") then
        return nil
    end
    -- Enforce strict file extension whitelist (only Luau scripts, json configs, and markers)
    local ext = normalized:match("%.([^%./\\]+)$")
    if ext then
        local lowerExt = ext:lower()
        if lowerExt ~= "lua" and lowerExt ~= "luau" and lowerExt ~= "json" and lowerExt ~= "txt" and lowerExt ~= "marker" then
            return nil
        end
    end
    return normalized
end

-- Initial Core Components Bootstrap (Ensures all official stages are initialized on fresh install)
-- Strictly respects user sovereignty: if already initialized, deleted or .off components are NEVER silently re-downloaded
local BOOTSTRAP_STAGES = {
    {
        repoPath = "kernel/KernelTaskManager.lua",
        localPath = "autoexec/kernel/KernelTaskManager.lua",
        name = "KernelTaskManager",
        sha256 = "67f2ea77f805c22f66dd61006feb9aae805646e51988030cce966297dda0d8b5"
    },
    {
        repoPath = "gameloaded/OmniEnhancementSuite.lua",
        localPath = "autoexec/gameloaded/OmniEnhancementSuite.lua",
        name = "OmniEnhancementSuite",
        sha256 = "8a4d8eeb657b8d72bea417f3d943c8787f193604a1003442d95845d6d2ca2a83"
    }
}

local manifestStagesByName = {}

local function registerManifestStage(st)
    if type(st) ~= "table" then return end
    if table.freeze then pcall(table.freeze, st) end
    local name = st.name
    if name and type(name) == "string" then
        manifestStagesByName[name] = st
        manifestStagesByName[name:lower()] = st
        local cleanName = name:gsub("%.luau?$", "")
        manifestStagesByName[cleanName] = st
        manifestStagesByName[cleanName:lower()] = st
        manifestStagesByName[cleanName .. ".lua"] = st
        manifestStagesByName[cleanName .. ".luau"] = st
    end
    local lp = st.localPath or st.path
    if lp and type(lp) == "string" then
        manifestStagesByName[lp] = st
        manifestStagesByName[lp:lower()] = st
        local normFwd = lp:gsub("\\", "/")
        local normBack = lp:gsub("/", "\\")
        manifestStagesByName[normFwd] = st
        manifestStagesByName[normBack] = st
        manifestStagesByName[normFwd:lower()] = st
        manifestStagesByName[normBack:lower()] = st
        local noAuto = normFwd:gsub("^autoexec/", "")
        manifestStagesByName[noAuto] = st
        manifestStagesByName[noAuto:lower()] = st
        local base = normFwd:match("[^/]+$")
        if base then
            manifestStagesByName[base] = st
            manifestStagesByName[base:lower()] = st
            local baseNoExt = base:gsub("%.luau?$", "")
            manifestStagesByName[baseNoExt] = st
            manifestStagesByName[baseNoExt:lower()] = st
            manifestStagesByName[baseNoExt .. ".lua"] = st
            manifestStagesByName[baseNoExt .. ".luau"] = st
        end
    end
end

local function lookupManifestStage(name, filePath)
    if not manifestStagesByName then return nil end
    local candidates = {}
    if name and type(name) == "string" then
        table.insert(candidates, name)
        table.insert(candidates, name:lower())
        local clean = name:gsub("%.luau?$", "")
        table.insert(candidates, clean)
        table.insert(candidates, clean:lower())
        table.insert(candidates, clean .. ".lua")
        table.insert(candidates, clean .. ".luau")
    end
    if filePath and type(filePath) == "string" then
        table.insert(candidates, filePath)
        table.insert(candidates, filePath:lower())
        local normFwd = filePath:gsub("\\", "/")
        local normBack = filePath:gsub("/", "\\")
        table.insert(candidates, normFwd)
        table.insert(candidates, normBack)
        table.insert(candidates, (normFwd:gsub("^autoexec/", "")))
        table.insert(candidates, (normFwd:gsub("^autoexec/", "")):lower())
        local base = normFwd:match("[^/]+$")
        if base then
            table.insert(candidates, base)
            table.insert(candidates, base:lower())
            local baseNoExt = base:gsub("%.luau?$", "")
            table.insert(candidates, baseNoExt)
            table.insert(candidates, baseNoExt:lower())
            table.insert(candidates, baseNoExt .. ".lua")
            table.insert(candidates, baseNoExt .. ".luau")
        end
    end
    for _, c in ipairs(candidates) do
        local st = manifestStagesByName[c]
        if st then return st end
    end
    return nil
end

for _, bStage in ipairs(BOOTSTRAP_STAGES) do
    registerManifestStage(bStage)
end

local function isStageDisabled(localPath)
    if not isfile then return false end
    -- Check disabled extensions: .off, .bak, .disabled
    if isfile(localPath .. ".off") or isfile(localPath .. ".bak") or isfile(localPath .. ".disabled") then
        return true
    end
    -- Check disabled/ignored subfolders: Off/, Disabled/, .ignore/, _disabled/, _backup/, _ignored/
    local dir, fname = localPath:match("^(.-)[/\\]([^/\\]+)$")
    if dir and fname then
        local checkDirs = { "Off", "Disabled", ".ignore", "_disabled", "_backup", "_ignored" }
        for _, sub in ipairs(checkDirs) do
            if isfile(dir .. "/" .. sub .. "/" .. fname)
                or isfile(dir .. "/" .. sub .. "/" .. fname .. ".off")
                or isfile(dir .. "/" .. sub .. "/" .. fname .. ".bak")
                or isfile(dir .. "/" .. sub .. "/" .. fname .. ".disabled") then
                return true
            end
        end
    end
    return false
end

local isInitialized = (isfile and (isfile(KERNEL_INIT_MARKER) or isfile(LEDGER_PATH))) or false
local ledger = loadLedger()

if not SafeMode and not isInitialized then
    local bootstrappedAny = false
    for _, bStage in ipairs(BOOTSTRAP_STAGES) do
        local isOff = isStageDisabled(bStage.localPath)
        if isfile and not isfile(bStage.localPath) and not isOff then
            local url = GITHUB_REPO_RAW .. bStage.repoPath .. "?v=" .. tostring(os.time())
            local content = fetchGithubScript(url)
            if content and #content > 100 then
                -- Strict SHA-256 integrity verification (TOCTOU defense)
                if bStage.sha256 then
                    local isValid = verifyContentHash(content, bStage.sha256)
                    if not isValid then
                        warn(string.format("[Bootloader | INTEGRITY BREACH]: Bootstrap hash mismatch for %s! Aborting bootstrap.", bStage.name))
                        continue
                    end
                end
                local parentDir = bStage.localPath:match("^(.*)[/\\][^/\\]+$")
                if parentDir and isfolder and not isfolder(parentDir) then pcall(makefolder, parentDir) end
                local ok, err = pcall(writefile, bStage.localPath, content)
                if ok then
                    bootstrappedAny = true
                    ledger.components[bStage.name] = {
                        installed = true,
                        lastSeenVersion = CURRENT_OMNI_VERSION,
                        path = bStage.localPath,
                        updatedAt = os.time(),
                        sha256 = bStage.sha256
                    }
                    print(string.format("[Bootloader]: Initialized core %s -> %s", bStage.name, bStage.localPath))
                else
                    warn(string.format("[Bootloader]: Failed to bootstrap %s: %s", bStage.name, tostring(err)))
                end
            end
        end
    end
    if isfile and not isfile(KERNEL_INIT_MARKER) and writefile then
        pcall(writefile, KERNEL_INIT_MARKER, tostring(os.time()))
    end
    if isfile and not isfile("Omni_Installed.marker") and writefile then
        pcall(writefile, "Omni_Installed.marker", tostring(os.time()))
    end
    if bootstrappedAny then
        saveLedger(ledger)
    end
elseif isfile and not isfile(KERNEL_INIT_MARKER) and isfile(LEDGER_PATH) and writefile then
    -- Backfill marker if ledger already exists from installer
    pcall(writefile, KERNEL_INIT_MARKER, tostring(os.time()))
    if not isfile("Omni_Installed.marker") then
        pcall(writefile, "Omni_Installed.marker", tostring(os.time()))
    end
end

-- ==============================================================================
-- ROOT OF TRUST: OMNI SECURITY & TRANSPARENCY GATE
-- ==============================================================================

initUpdateGate = function(guiParent, UpdateBadge)
    local function getLatestCommitSha()
        local ok, res = pcall(function()
            if type(request) == "function" then
                local resp = request({
                    Url = "https://api.github.com/repos/s3rvxnt/RobloxOmni/commits/main",
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
        return "main"
    end

    -- Security Heuristics Audit
    local function auditScriptContent(code)
        local badges = {}
        if not code or #code == 0 then return badges end

        -- Obfuscation Detection
        local isObfuscated = false

        -- 1. Precompiled Bytecode Signature (Raw binary header)
        if code:sub(1, 4) == "\27Lua" then
            isObfuscated = true
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

        -- 4. Packed Decimal Byte Streams (\123\145\167...)
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

        -- 5. Packed Hex Byte Streams (\x41\x42\x43...)
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

        -- 6. Giant dense single-line VM wrapper (> 2500 chars with string decoding)
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

        -- 7. Excessive dynamic string.char calls
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

        -- 8. Known Obfuscator Signatures & Watermarks
        if not isObfuscated then
            local lineCount = 0
            for _ in code:gmatch("[^\r\n]+") do
                lineCount = lineCount + 1
            end
            local avgLen = #code / math.max(1, lineCount)
            local funcCount = 0
            for _ in code:gmatch("%f[%w_]function%s*[%w_:%.]*%s*%(") do
                funcCount = funcCount + 1
            end
            local isStructured = (lineCount >= 30 and avgLen <= 250 and funcCount >= 5)

            if isStructured then
                -- For structured source code, only flag if top 20 lines contain an unambiguous obfuscator declaration banner
                local topLines = {}
                local n = 0
                for line in code:gmatch("[^\r\n]+") do
                    n = n + 1
                    table.insert(topLines, line:lower())
                    if n >= 20 then break end
                end
                local headerText = table.concat(topLines, "\n")
                local explicitBanners = {
                    "obfuscated with", "this file was obfuscated", "protected by luarmor",
                    "protected by luraph", "moonsec v", "lph--"
                }
                for _, banner in ipairs(explicitBanners) do
                    if headerText:find(banner, 1, true) then
                        isObfuscated = true
                        break
                    end
                end
            else
                -- For non-structured / minified / short files, check standard obfuscator keywords
                local lower = code:lower()
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
            end
        end

        -- 9. Zero-Width Unicode Smuggling & Trojan Source BiDi Overrides (CVE-2021-42574)
        local hasZeroWidth = false
        local hasBidiTrojan = false
        local hasHomoglyphs = false

        -- Check Zero-Width / Invisible Space sequences
        if code:find("\226\128\139") or code:find("\226\128\140") or code:find("\226\128\141")
            or code:find("\239\187\191") or code:find("\226\128\142") or code:find("\226\128\143")
            or code:find("\226\128[\128-\138]") or code:find("\226\129\160") or code:find("\194\173") then
            hasZeroWidth = true
        end

        -- Check Trojan Source BiDi Overrides / Isolates (U+202A-U+202E and U+2066-U+2069)
        if code:find("\226\128[\170-\174]") or code:find("\226\129[\166-\169]") then
            hasBidiTrojan = true
        end

        -- Check Cyrillic/Greek Homoglyphs disguised in identifiers (strip comments & string literals first)
        for line in code:gmatch("[^\r\n]+") do
            if not line:match("^%s*%-%-") then -- Skip pure comments
                local strippedLine = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
                if strippedLine:find("[\208-\209][\128-\191]") or strippedLine:find("[\206-\207][\128-\191]") then
                    hasHomoglyphs = true
                    break
                end
            end
        end

        if hasBidiTrojan then
            isObfuscated = true
            table.insert(badges, { label = "🛑 Trojan Source (BiDi)", color = Color3.fromRGB(255, 35, 35) })
        elseif hasZeroWidth or hasHomoglyphs then
            isObfuscated = true
            table.insert(badges, { label = "🚨 Unicode Smuggling", color = Color3.fromRGB(255, 45, 45) })
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

    -- Anti-Trojan Source & Homoglyph Diff Sanitizer (CVE-2021-42574)
    local function sanitizeDiffText(text)
        if not text or type(text) ~= "string" then return "" end
        local s = text
        -- Reveal Zero-Width characters and invisible controls
        s = s:gsub("\239\187\191", "[BOM]")
        s = s:gsub("\226\128\139", "[ZWSP]")
        s = s:gsub("\226\128\140", "[ZWNJ]")
        s = s:gsub("\226\128\141", "[ZWJ]")
        s = s:gsub("\226\128\142", "[LRM]")
        s = s:gsub("\226\128\143", "[RLM]")
        s = s:gsub("\226\128[\128-\138]", "[INV-SP]")
        s = s:gsub("\226\129\160", "[WJ]")
        s = s:gsub("\194\173", "[SHY]")
        -- Reveal BiDi overrides / isolates
        s = s:gsub("\226\128\170", "[LRE]")
        s = s:gsub("\226\128\171", "[RLE]")
        s = s:gsub("\226\128\172", "[PDF]")
        s = s:gsub("\226\128\173", "[LRO]")
        s = s:gsub("\226\128\174", "[RLO]")
        s = s:gsub("\226\129\166", "[LRI]")
        s = s:gsub("\226\129\167", "[RLI]")
        s = s:gsub("\226\129\168", "[FSI]")
        s = s:gsub("\226\129\169", "[PDI]")
        -- Reveal non-printable ASCII control characters (keep tabs and newlines)
        s = s:gsub("[\1-\8\11-\12\14-\31\127]", function(c)
            return string.format("\\x%02X", string.byte(c))
        end)
        return s
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
                table.insert(diff, { type = "add", lineNum = idx, text = sanitizeDiffText(line) })
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
        for idx, entry in ipairs(rawEntries) do
            if keep[idx] then
                if skipped > 0 then
                    table.insert(diff, { type = "info", lineNum = 0, text = string.format("... [%d unchanged lines] ...", skipped) })
                    skipped = 0
                end
                table.insert(diff, {
                    type = entry.type,
                    lineNum = entry.lineNum,
                    text = sanitizeDiffText(entry.text)
                })
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
    pcall(function()
        if type(protectgui) == "function" then
            protectgui(UpdateScreenGui)
        elseif type(protect_gui) == "function" then
            protect_gui(UpdateScreenGui)
        elseif type(syn) == "table" and type(syn.protect_gui) == "function" then
            syn.protect_gui(UpdateScreenGui)
        end
    end)
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

    local SecondaryBtn = Instance.new("TextButton")
    SecondaryBtn.Name = "SecondaryBtn"
    SecondaryBtn.Size = UDim2.new(0, 200, 1, 0)
    SecondaryBtn.Position = UDim2.new(0, 116, 0, 0)
    SecondaryBtn.BackgroundColor3 = Color3.fromRGB(24, 45, 75)
    SecondaryBtn.Font = Enum.Font.GothamBold
    SecondaryBtn.TextSize = 11
    SecondaryBtn.TextColor3 = Color3.fromRGB(120, 195, 255)
    SecondaryBtn.Text = "🛡️ Run Previous Safe Version"
    SecondaryBtn.Visible = false
    SecondaryBtn.Parent = FooterFrame

    local SecondaryCorner = Instance.new("UICorner")
    SecondaryCorner.CornerRadius = UDim.new(0, 6)
    SecondaryCorner.Parent = SecondaryBtn

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
                        local safeLocalPath = validateSafeLocalPath(p)
                        if safeLocalPath then
                            local newStage = {
                                repoPath = stage.repoPath or stage.url,
                                localPath = safeLocalPath,
                                path = safeLocalPath,
                                stage = stage.stage,
                                name = stage.name or safeLocalPath:match("[^/\\]+$") or "Component",
                                desc = stage.desc,
                                sha256 = stage.sha256 or stage.hash or nil,
                                code = stage.code,
                                content = stage.content
                            }
                            if table.freeze then pcall(table.freeze, newStage) end
                            table.insert(valid, newStage)
                        else
                            warn("[Bootloader | SANDBOX SECURITY]: Discarded stage with unsafe path: " .. tostring(p))
                        end
                    end
                end
            end
        end
        if table.freeze then pcall(table.freeze, valid) end
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
        CodeScroll.CanvasPosition = Vector2.new(0, 0)

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
                local BATCH_SIZE = 100
                local totalDiff = #diff

                local function renderBatch(startIdx, endIdx)
                    for idx = startIdx, endIdx do
                        local item = diff[idx]
                        if not item then break end

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
                        txtLbl.Text = prefix .. tostring(item.text or ""):sub(1, 1500)
                        txtLbl.Parent = lineRow
                    end
                end

                -- Immediately render initial batch
                local firstEnd = math.min(totalDiff, BATCH_SIZE)
                renderBatch(1, firstEnd)

                -- Progressively stream remaining lines across frames
                if firstEnd < totalDiff then
                    task.spawn(function()
                        local nextStart = firstEnd + 1
                        while nextStart <= totalDiff do
                            task.wait()
                            if selectedStageIdx ~= stageIdx then break end
                            local nextEnd = math.min(totalDiff, nextStart + BATCH_SIZE - 1)
                            renderBatch(nextStart, nextEnd)
                            nextStart = nextEnd + 1
                        end
                    end)
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

    local isDefcon1Lockdown = false
    local userConsentCallback = nil
    local closeUpdateModal = nil
    local openUpdateModal = nil

    local function applyVerifiedUpdateSequence()
        if not currentUpdateData then return false end
        local stages = currentUpdateData.stages
        if not stages or #stages == 0 then
            stages = {
                {
                    repoPath = "kernel/KernelTaskManager.lua",
                    localPath = "autoexec/kernel/KernelTaskManager.lua",
                    name = "KernelTaskManager",
                    sha256 = "67f2ea77f805c22f66dd61006feb9aae805646e51988030cce966297dda0d8b5"
                }
            }
        end

        ApplyUpdateBtn.Active = false
        ApplyUpdateBtn.Text = "⏳ Verifying SHA-256 and applying..."

        local anySuccess = false
        local lastCode = nil
        local shaToUse = currentUpdateData.sha or getLatestCommitSha()
        local ledger = loadLedger()

        for idx, stage in ipairs(stages) do
            local repoPath = stage.repoPath or stage.url
            local localPath = stage.localPath or stage.path
            if not localPath or type(localPath) ~= "string" then
                continue
            end
            local safeLocalPath = validateSafeLocalPath(localPath)
            if not safeLocalPath then
                warn("[OmniUpdater | SANDBOX SECURITY]: Skipped unsafe path traversal stage: " .. tostring(localPath))
                continue
            end
            localPath = safeLocalPath
            local name = stage.name or localPath:match("[^/\\]+$") or "Component"

            local remoteContent = stage.code or stage.content or fetchedStageCodes[idx]
            if not remoteContent and repoPath then
                local url = repoPath
                if not url:find("^https?://") then
                    url = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/" .. shaToUse .. "/" .. url
                elseif not url:find("^https://raw%.githubusercontent%.com/s3rvxnt/RobloxOmni/") then
                    warn("[OmniUpdater | SANDBOX SECURITY]: Disallowed external download URL: " .. tostring(url))
                    continue
                end
                remoteContent = fetchGithubScript(url)
            end

            if remoteContent and #remoteContent > 100 then
                -- STEP 3: STRICT SHA-256 HASH VERIFICATION (TOCTOU Defense)
                local expectedSha = stage.sha256 or stage.hash
                if expectedSha then
                    local isValid = verifyContentHash(remoteContent, expectedSha)
                    if not isValid then
                        warn(string.format("[OmniUpdater | INTEGRITY BREACH]: SHA-256 mismatch for %s! Expected: %s. Aborting component installation.", name, expectedSha))
                        continue
                    end
                end

                -- Write to disk as offline cache
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
                        updatedAt = os.time(),
                        sha256 = expectedSha
                    }
                    -- STEP 3: MEMORY-ONLY EXECUTION - execute directly from the verified in-memory remoteContent buffer!
                    if localPath:find("KernelTaskManager") then
                        lastCode = remoteContent
                    elseif localPath:find("OmniEnhancementSuite") then
                        task.spawn(function()
                            local fn, errComp = _clonedLoadstring(remoteContent, "@OmniEnhancementSuite")
                            if fn then pcall(fn) else warn("[OmniUpdater]: Compilation error: " .. tostring(errComp)) end
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
            if isDefcon1Lockdown then
                ApplyUpdateBtn.Text = "✓ Security Patch Applied! Please restart Roblox."
                ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
                ApplyUpdateBtn.Active = false
                DismissBtn.Text = "Close"
                return true
            end
            ApplyUpdateBtn.Text = "✓ Applied! Reloading Omni..."
            task.wait(0.7)
            closeUpdateModal()
            PillToast.Visible = false
            if UpdateBadge then UpdateBadge.Visible = false end

            if lastCode then
                if type(getgenv()._KernelTaskManagerUnifiedCleanUp) == "function" then
                    pcall(getgenv()._KernelTaskManagerUnifiedCleanUp)
                end
                local fn, syntaxErr = _clonedLoadstring(lastCode, "@KernelTaskManager")
                if fn then
                    task.spawn(function()
                        local okRun, runErr = xpcall(fn, debug.traceback)
                        if not okRun then
                            warn("[OmniUpdater]: Reload runtime error: " .. tostring(runErr))
                        end
                    end)
                else
                    warn("[OmniUpdater]: Reload compilation error: " .. tostring(syntaxErr))
                end
            end
            return true
        else
            ApplyUpdateBtn.Text = "❌ Verification / Download Failed"
            task.wait(2.5)
            ApplyUpdateBtn.Active = true
            refreshApplyButtonUI()
            return false
        end
    end

    local isDefcon1Lockdown = false
    local defcon1UnlockTime = 0
    local defcon1CountdownThread = nil

    openUpdateModal = function(lockdownFlag, lockdownMsg)
        if defcon1CountdownThread then
            task.cancel(defcon1CountdownThread)
            defcon1CountdownThread = nil
        end
        if forceInstallResetThread then
            task.cancel(forceInstallResetThread)
            forceInstallResetThread = nil
        end
        forceInstallConfirmActive = false
        isObfuscatedUpdateDetected = false

        -- Defcon 1 is sticky: once engaged or if flagged or global lockdown is active, it cannot be downgraded
        if lockdownFlag == true or getgenv()._OmniLockdownActive == true then
            isDefcon1Lockdown = true
            if defcon1UnlockTime == 0 or os.clock() >= defcon1UnlockTime then
                defcon1UnlockTime = os.clock() + 5.0
            end
        else
            if not isDefcon1Lockdown then
                isDefcon1Lockdown = false
            end
        end

        if not currentUpdateData then
            currentUpdateData = {
                version = CURRENT_OMNI_VERSION,
                releaseDate = "2026-10-06",
                title = "Omni v1.0 - Runtime Micro-Kernel & Enhancement Suite",
                changelog = {
                    "Adaptive 6.0ms frame-budgeted bootloader with automated crash recovery and Safe Mode",
                    "Kernel Task Manager HUD and adaptive loop governor with per-task CPU telemetry (Shift + F8)",
                    "Zero-trust update transparency gate with line-by-line diff inspection and security scanner (Shift + F7)",
                    "Real-time game connection ingestion, priority bands, and instant hot-reloading",
                    "Omni Enhancement Suite: Streamer mode, Personal Space Bubble, Player ESP, Anti-AFK, and native ESC settings"
                },
                stages = sanitizeStages(BOOTSTRAP_STAGES)
            }
        end

        -- Configure visual presentation based on Defcon 1 Lockdown status
        if isDefcon1Lockdown then
            ModalTitle.Text = "🚨 DEFCON 1 SECURITY LOCKDOWN"
            ModalTitle.TextColor3 = Color3.fromRGB(255, 65, 65)
            ModalSubtitle.Text = "AIR-GAP ACTIVE: Client disconnected from server to prevent anti-cheat detection telemetry"
            ModalSubtitle.TextColor3 = Color3.fromRGB(255, 140, 140)
            ApplyUpdateBtn.Text = "🛡️ Inspecting Security Diff (5s)..."
            ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(130, 40, 40)
            DiffCard.BackgroundColor3 = Color3.fromRGB(38, 18, 22)
            DiffStroke.Color = Color3.fromRGB(180, 45, 45)
        else
            ModalTitle.Text = "⚡ OMNI UPDATE & SECURITY GATE"
            ModalTitle.TextColor3 = Color3.fromRGB(64, 196, 255)
            ModalSubtitle.Text = "Verified code changes • Complete transparency before updating local files"
            ModalSubtitle.TextColor3 = Color3.fromRGB(150, 165, 185)
            ApplyUpdateBtn.Text = "⬇️ Update & Apply Now"
            ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
            DiffCard.BackgroundColor3 = Color3.fromRGB(22, 27, 38)
            DiffStroke.Color = Color3.fromRGB(38, 50, 72)
        end

        -- Pre-scan stage contents for obfuscation
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

        if isDefcon1Lockdown then
            local remaining = defcon1UnlockTime - os.clock()
            if remaining > 0 then
                ApplyUpdateBtn.Active = false
                ApplyUpdateBtn.Text = string.format("🛡️ Inspecting Security Diff (%ds)...", math.max(1, math.ceil(remaining)))
                ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(130, 40, 40)
                defcon1CountdownThread = task.spawn(function()
                    while os.clock() < defcon1UnlockTime do
                        task.wait(0.2)
                        if not isDefcon1Lockdown or not ModalBackdrop.Visible then break end
                        local rem = defcon1UnlockTime - os.clock()
                        if rem > 0 then
                            ApplyUpdateBtn.Text = string.format("🛡️ Inspecting Security Diff (%ds)...", math.max(1, math.ceil(rem)))
                        end
                    end
                    if isDefcon1Lockdown and ModalBackdrop.Visible and os.clock() >= defcon1UnlockTime then
                        ApplyUpdateBtn.Active = true
                        ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(210, 35, 35)
                        ApplyUpdateBtn.Text = "🛡️ Apply Critical Security Patch"
                    end
                    defcon1CountdownThread = nil
                end)
            else
                ApplyUpdateBtn.Active = true
                ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(210, 35, 35)
                ApplyUpdateBtn.Text = "🛡️ Apply Critical Security Patch"
            end
        else
            ApplyUpdateBtn.Active = true
            refreshApplyButtonUI()
        end

        local ledger = loadLedger()
        local installedVersion = (ledger and ledger.version) or CURRENT_OMNI_VERSION
        DiffCurrent.Text = "Installed: v" .. tostring(installedVersion)
        DiffAvailable.Text = "Available: v" .. tostring(currentUpdateData.version)
        DiffDate.Text = tostring(currentUpdateData.releaseDate or "Latest")

        local changelogItems = {}
        if isDefcon1Lockdown then
            table.insert(changelogItems, "🚨 [DEFCON 1 LOCKDOWN ACTIVE]: " .. tostring(lockdownMsg or "Core exploit detection alert"))
            table.insert(changelogItems, "🛡️ Client has been air-gapped from game server to prevent telemetry detection.")
            table.insert(changelogItems, "⚠️ All core rings and autoexec scripts are completely halted.")
            table.insert(changelogItems, "🔍 Inspect the verified code diff below before applying the security patch.")
        end
        if currentUpdateData.changelog then
            for _, note in ipairs(currentUpdateData.changelog) do
                table.insert(changelogItems, note)
            end
        end
        populateChangelog(changelogItems)
        setupStageBar()
        renderStageDiff(1)
        if isDefcon1Lockdown then
            switchTab("Code")
        else
            switchTab("Changelog")
        end

        ModalBackdrop.Visible = true
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
    end

    local isApprovalPending = false
    local function yieldForUserApproval(lockdownFlag, lockdownMsg)
        if isApprovalPending then
            while isApprovalPending do
                task.wait(0.1)
            end
        end
        isApprovalPending = true
        local approved = nil
        userConsentCallback = function(val)
            approved = val
            userConsentCallback = nil
            isApprovalPending = false
        end

        openUpdateModal(lockdownFlag, lockdownMsg)

        -- Pure Zero-Trust Synchronous Yield: caller blocks until user explicitly clicks button in UI
        while approved == nil do
            task.wait(0.1)
        end

        return approved
    end

    -- Parameterless globals to eliminate any capability scraping or arbitrary code injection
    getgenv().OpenOmniUpdateGate = function() openUpdateModal(false) end
    getgenv().TestOmniUpdateGate = function() openUpdateModal(false) end

    closeUpdateModal = function()
        if isScriptReviewActive and scriptReviewCallback then
            scriptReviewCallback("block")
            return
        end
        if userConsentCallback then
            userConsentCallback(false)
        end
        if defcon1CountdownThread then
            task.cancel(defcon1CountdownThread)
            defcon1CountdownThread = nil
        end
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
        if isScriptReviewActive and scriptReviewCallback then
            scriptReviewCallback("block")
            return
        end
        if userConsentCallback then
            userConsentCallback(false)
        end
        closeUpdateModal()
        if not getgenv()._OmniUpdateDismissed and currentUpdateData and not isDefcon1Lockdown then
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
        openUpdateModal(false)
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
        if isScriptReviewActive and scriptReviewCallback then
            scriptReviewCallback("block")
            return
        end
        if userConsentCallback then
            userConsentCallback(false)
        end
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

    SecondaryBtn.MouseButton1Click:Connect(function()
        if isScriptReviewActive and scriptReviewCallback then
            scriptReviewCallback("run_previous")
            return
        end
    end)

    if UpdateBadge then
        UpdateBadge.MouseButton1Click:Connect(function() openUpdateModal(false) end)
    end

    -- Keybind: Shift + F7 to toggle Update Gate (Shift + F8 toggles Task Manager HUD)
    local inputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode == Enum.KeyCode.F7 then
            local isShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
            if isShift then
                if ModalBackdrop.Visible then
                    closeUpdateModal()
                else
                    openUpdateModal(false)
                end
            end
        end
    end)

    ApplyUpdateBtn.MouseButton1Click:Connect(function()
        if isScriptReviewActive and scriptReviewCallback then
            scriptReviewCallback("approve")
            return
        end
        if not currentUpdateData then return end

        -- Defcon 1 Panic Click Guard: Strictly reject clicks while mandatory inspection countdown is running
        if isDefcon1Lockdown and defcon1CountdownThread ~= nil then
            warn("[Bootloader | UPDATE GATE]: Inspection countdown active. Please review the security diff before applying.")
            return
        end
        if isDefcon1Lockdown and os.clock() < defcon1UnlockTime then
            warn("[Bootloader | UPDATE GATE]: Inspection countdown active. Please review the security diff before applying.")
            return
        end

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

        if userConsentCallback then
            userConsentCallback(true)
        else
            task.spawn(applyVerifiedUpdateSequence)
        end
    end)

    -- Background Update & Missing Component Checker
    task.spawn(function()
        task.wait(1.5)
        if getgenv()._OmniLockdownActive then return end
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
                local isOff = isStageDisabled(localPath)
                if isfile and not isfile(localPath) and not isOff then
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

    promptRemoteScriptSecurity = function(opts)
        while isApprovalPending or isScriptReviewPending do
            task.wait(0.1)
        end
        isScriptReviewPending = true
        isScriptReviewActive = true

        local decision = nil
        scriptReviewCallback = function(val)
            decision = val
            isScriptReviewActive = false
            scriptReviewCallback = nil
            isScriptReviewPending = false
        end

        local mode = opts.mode -- "script_update" | "script_new" | "script_inline"
        local url = opts.url
        local oldCode = opts.oldCode or ""
        local newCode = opts.newCode or ""
        local badges = opts.badges or auditScriptContent(newCode)

        -- Adjust StageBar and CodeReview sub-bars for script review
        StageBar.Visible = false
        AuditBar.Position = UDim2.new(0, 0, 0, 0)
        CodeScroll.Position = UDim2.new(0, 0, 0, 26)
        CodeScroll.Size = UDim2.new(1, 0, 1, -26)
        TabBtnChangelog.Visible = false
        TabBtnCode.Size = UDim2.new(1, 0, 1, 0)
        TabBtnCode.Position = UDim2.new(0, 0, 0, 0)

        if mode == "script_update" then
            ModalTitle.Text = "⚠️ OMNI SECURITY GATE: SCRIPT UPDATED"
            ModalTitle.TextColor3 = Color3.fromRGB(255, 175, 45)
            ModalSubtitle.Text = "Remote author updated code • Review diff before execution"
            ModalSubtitle.TextColor3 = Color3.fromRGB(220, 225, 235)

            DiffCurrent.Text = "Target:"
            DiffAvailable.Text = (url and (#url > 40 and (url:sub(1, 40) .. "...") or url)) or "Remote Script"
            DiffDate.Text = "UPDATED"
            DiffDate.TextColor3 = Color3.fromRGB(255, 175, 45)

            DismissBtn.Size = UDim2.new(0, 110, 1, 0)
            DismissBtn.Text = "🛑 Block"
            DismissBtn.BackgroundColor3 = Color3.fromRGB(48, 22, 26)
            DismissBtn.TextColor3 = Color3.fromRGB(255, 120, 120)

            SecondaryBtn.Visible = true
            SecondaryBtn.Position = UDim2.new(0, 116, 0, 0)
            SecondaryBtn.Size = UDim2.new(0, 200, 1, 0)
            SecondaryBtn.Text = "🛡️ Run Previous Safe Version"
            SecondaryBtn.BackgroundColor3 = Color3.fromRGB(24, 45, 75)
            SecondaryBtn.TextColor3 = Color3.fromRGB(120, 195, 255)

            ApplyUpdateBtn.Position = UDim2.new(0, 322, 0, 0)
            ApplyUpdateBtn.Size = UDim2.new(1, -322, 1, 0)
            ApplyUpdateBtn.Text = "✅ Approve Changes & Run"
            ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(30, 140, 65)

            local diffEntries = computeLineDiff(oldCode, newCode)
            for _, c in ipairs(AuditBar:GetChildren()) do
                if not c:IsA("UIListLayout") then c:Destroy() end
            end
            for idx, b in ipairs(badges) do
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
                chipStroke.Color = b.color or Color3.fromRGB(60, 80, 110)
                chipStroke.Parent = chip

                local chipPad = Instance.new("UIPadding")
                chipPad.PaddingLeft = UDim.new(0, 6)
                chipPad.PaddingRight = UDim.new(0, 6)
                chipPad.Parent = chip

                local chipLbl = Instance.new("TextLabel")
                chipLbl.Size = UDim2.new(0, 0, 1, 0)
                chipLbl.AutomaticSize = Enum.AutomaticSize.X
                chipLbl.BackgroundTransparency = 1
                chipLbl.Font = Enum.Font.GothamBold
                chipLbl.TextSize = 10
                chipLbl.TextColor3 = b.color or Color3.fromRGB(255, 255, 255)
                chipLbl.Text = b.label
                chipLbl.Parent = chip
            end

            for _, c in ipairs(CodeScroll:GetChildren()) do
                if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
            end

            local BATCH_SIZE = 60
            local totalDiff = #diffEntries
            local function renderBatch(startIdx, endIdx)
                for i = startIdx, endIdx do
                    local item = diffEntries[i]
                    if not item then break end
                    local lineRow = Instance.new("Frame")
                    lineRow.Name = "Line_" .. i
                    lineRow.Size = UDim2.new(1, 0, 0, 16)
                    lineRow.BorderSizePixel = 0

                    local bgCol = Color3.fromRGB(10, 12, 16)
                    local textCol = Color3.fromRGB(180, 195, 215)
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
                    numLbl.Text = (item.type == "info") and "..." or tostring(item.lineNum or i)
                    numLbl.Parent = lineRow

                    local txtLbl = Instance.new("TextLabel")
                    txtLbl.Size = UDim2.new(1, -48, 1, 0)
                    txtLbl.Position = UDim2.new(0, 46, 0, 0)
                    txtLbl.BackgroundTransparency = 1
                    txtLbl.Font = Enum.Font.RobotoMono
                    txtLbl.TextSize = 10
                    txtLbl.TextColor3 = textCol
                    txtLbl.TextXAlignment = Enum.TextXAlignment.Left
                    txtLbl.Text = prefix .. tostring(item.text or ""):sub(1, 1500)
                    txtLbl.Parent = lineRow
                end
            end
            local firstEnd = math.min(totalDiff, BATCH_SIZE)
            renderBatch(1, firstEnd)
            if firstEnd < totalDiff then
                task.spawn(function()
                    local nextStart = firstEnd + 1
                    while nextStart <= totalDiff do
                        task.wait()
                        if not isScriptReviewActive then break end
                        local nextEnd = math.min(totalDiff, nextStart + BATCH_SIZE - 1)
                        renderBatch(nextStart, nextEnd)
                        nextStart = nextEnd + 1
                    end
                end)
            end
        else
            -- "script_new" or "script_inline"
            ModalTitle.Text = (mode == "script_new") and "🛡️ OMNI SECURITY GATE: NEW REMOTE SCRIPT" or "🛡️ OMNI SECURITY GATE: DYNAMIC CODE"
            ModalTitle.TextColor3 = Color3.fromRGB(64, 196, 255)
            ModalSubtitle.Text = (mode == "script_new") and "First-time remote execution • Review code before trusting" or "Dynamic execution attempt • Review code before executing"
            ModalSubtitle.TextColor3 = Color3.fromRGB(180, 195, 215)

            DiffCurrent.Text = "Target:"
            DiffAvailable.Text = (url and (#url > 40 and (url:sub(1, 40) .. "...") or url)) or (opts.chunkname or "Inline Script")
            DiffDate.Text = "NEW"
            DiffDate.TextColor3 = Color3.fromRGB(64, 196, 255)

            DismissBtn.Size = UDim2.new(0, 140, 1, 0)
            DismissBtn.Text = "🛑 Block Execution"
            DismissBtn.BackgroundColor3 = Color3.fromRGB(48, 22, 26)
            DismissBtn.TextColor3 = Color3.fromRGB(255, 120, 120)

            SecondaryBtn.Visible = false

            ApplyUpdateBtn.Position = UDim2.new(0, 148, 0, 0)
            ApplyUpdateBtn.Size = UDim2.new(1, -148, 1, 0)
            ApplyUpdateBtn.Text = "🛡️ Trust & Execute"
            ApplyUpdateBtn.BackgroundColor3 = Color3.fromRGB(0, 122, 204)

            for _, c in ipairs(AuditBar:GetChildren()) do
                if not c:IsA("UIListLayout") then c:Destroy() end
            end
            for idx, b in ipairs(badges) do
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
                chipStroke.Color = b.color or Color3.fromRGB(60, 80, 110)
                chipStroke.Parent = chip

                local chipPad = Instance.new("UIPadding")
                chipPad.PaddingLeft = UDim.new(0, 6)
                chipPad.PaddingRight = UDim.new(0, 6)
                chipPad.Parent = chip

                local chipLbl = Instance.new("TextLabel")
                chipLbl.Size = UDim2.new(0, 0, 1, 0)
                chipLbl.AutomaticSize = Enum.AutomaticSize.X
                chipLbl.BackgroundTransparency = 1
                chipLbl.Font = Enum.Font.GothamBold
                chipLbl.TextSize = 10
                chipLbl.TextColor3 = b.color or Color3.fromRGB(255, 255, 255)
                chipLbl.Text = b.label
                chipLbl.Parent = chip
            end

            for _, c in ipairs(CodeScroll:GetChildren()) do
                if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
            end

            local rawLines = {}
            local MAX_PREVIEW_LINES = 400
            local CHUNK_SIZE = 800
            for line in (newCode .. "\n"):gmatch("(.-)\r?\n") do
                if #rawLines >= MAX_PREVIEW_LINES then
                    table.insert(rawLines, string.format("... [Preview capped at %d lines]", MAX_PREVIEW_LINES))
                    break
                end
                if #line > CHUNK_SIZE then
                    for i = 1, math.min(#line, CHUNK_SIZE * 5), CHUNK_SIZE do
                        table.insert(rawLines, line:sub(i, i + CHUNK_SIZE - 1))
                        if #rawLines >= MAX_PREVIEW_LINES then break end
                    end
                    if #line > CHUNK_SIZE * 5 then
                        table.insert(rawLines, string.format("... [minified line truncated: %d chars total]", #line))
                    end
                else
                    table.insert(rawLines, line)
                end
            end
            if #rawLines == 0 then
                table.insert(rawLines, "-- (Empty Script)")
            end

            local BATCH_SIZE = 60
            local totalLines = #rawLines
            local function renderRawBatch(startIdx, endIdx)
                for i = startIdx, endIdx do
                    local line = rawLines[i]
                    if not line then break end
                    local lineRow = Instance.new("Frame")
                    lineRow.Name = "Line_" .. i
                    lineRow.Size = UDim2.new(1, 0, 0, 16)
                    lineRow.BorderSizePixel = 0
                    lineRow.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
                    lineRow.Parent = CodeScroll

                    local numLbl = Instance.new("TextLabel")
                    numLbl.Size = UDim2.new(0, 36, 1, 0)
                    numLbl.Position = UDim2.new(0, 4, 0, 0)
                    numLbl.BackgroundTransparency = 1
                    numLbl.Font = Enum.Font.RobotoMono
                    numLbl.TextSize = 10
                    numLbl.TextColor3 = Color3.fromRGB(90, 105, 125)
                    numLbl.TextXAlignment = Enum.TextXAlignment.Right
                    numLbl.Text = tostring(i)
                    numLbl.Parent = lineRow

                    local txtLbl = Instance.new("TextLabel")
                    txtLbl.Size = UDim2.new(1, -48, 1, 0)
                    txtLbl.Position = UDim2.new(0, 46, 0, 0)
                    txtLbl.BackgroundTransparency = 1
                    txtLbl.Font = Enum.Font.RobotoMono
                    txtLbl.TextSize = 10
                    txtLbl.TextColor3 = Color3.fromRGB(180, 195, 215)
                    txtLbl.TextXAlignment = Enum.TextXAlignment.Left
                    txtLbl.Text = "  " .. sanitizeDiffText(line):sub(1, 1500)
                    txtLbl.Parent = lineRow
                end
            end
            local firstEnd = math.min(totalLines, BATCH_SIZE)
            renderRawBatch(1, firstEnd)
            if firstEnd < totalLines then
                task.spawn(function()
                    local nextStart = firstEnd + 1
                    while nextStart <= totalLines do
                        task.wait()
                        if not isScriptReviewActive then break end
                        local nextEnd = math.min(totalLines, nextStart + BATCH_SIZE - 1)
                        renderRawBatch(nextStart, nextEnd)
                        nextStart = nextEnd + 1
                    end
                end)
            end
        end

        switchTab("Code")
        ModalBackdrop.Visible = true
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true

        while decision == nil do
            task.wait(0.05)
        end

        ModalBackdrop.Visible = false

        -- Restore standard layout
        StageBar.Visible = true
        AuditBar.Position = UDim2.new(0, 0, 0, 30)
        CodeScroll.Position = UDim2.new(0, 0, 0, 56)
        CodeScroll.Size = UDim2.new(1, 0, 1, -56)
        TabBtnChangelog.Visible = true
        TabBtnCode.Size = UDim2.new(0, 160, 1, 0)
        TabBtnCode.Position = UDim2.new(0, 168, 0, 0)
        SecondaryBtn.Visible = false
        DismissBtn.Size = UDim2.new(0, 140, 1, 0)
        DismissBtn.Text = "Dismiss (Skip)"
        DismissBtn.BackgroundColor3 = Color3.fromRGB(28, 34, 46)
        DismissBtn.TextColor3 = Color3.fromRGB(180, 195, 215)
        ApplyUpdateBtn.Position = UDim2.new(0, 148, 0, 0)
        ApplyUpdateBtn.Size = UDim2.new(1, -148, 1, 0)
        refreshApplyButtonUI()

        return decision
    end

    local controller = {
        open = function(lockdownFlag, msg) openUpdateModal(lockdownFlag, msg) end,
        close = closeUpdateModal,
        yieldApproval = yieldForUserApproval,
        promptSecurity = promptRemoteScriptSecurity,
        applyVerified = applyVerifiedUpdateSequence,
        setManifestData = function(data)
            if type(data) == "table" then
                local st = sanitizeStages(data.stages or {})
                local cl = {}
                if type(data.changelog) == "table" then
                    for _, note in ipairs(data.changelog) do
                        table.insert(cl, tostring(note))
                    end
                else
                    table.insert(cl, "Security update and performance improvements")
                end
                if table.freeze then pcall(table.freeze, cl) end
                currentUpdateData = {
                    version = data.version or CURRENT_OMNI_VERSION,
                    releaseDate = data.releaseDate or "Latest",
                    title = data.title or ("Omni v" .. tostring(data.version or "1.0")),
                    changelog = cl,
                    stages = st,
                    sha = data.sha or "main",
                    lockdown = data.lockdown or false,
                    lockdown_message = data.lockdown_message or nil
                }
                if table.freeze then pcall(table.freeze, currentUpdateData) end
            end
        end,
        cleanup = function()
            if inputConn then pcall(function() inputConn:Disconnect() end); inputConn = nil end
            if UpdateScreenGui then pcall(function() UpdateScreenGui:Destroy() end); UpdateScreenGui = nil end
            getgenv().OpenOmniUpdateGate = nil
            getgenv().TestOmniUpdateGate = nil
        end
    }
    if table.freeze then pcall(table.freeze, controller) end
    return controller
end

-- ==============================================================================
-- ROOT OF TRUST: UPDATE GATE INSTANTIATION & DEFCON 1 KILL SWITCH
-- ==============================================================================
if not updateGateController and ensureUpdateGateController then
    updateGateController = ensureUpdateGateController()
end

-- ==============================================================================
-- STEP 1: DEFCON 1 SECURITY LOCKDOWN & AIR-GAP KILL SWITCH
-- ==============================================================================
local function checkDefcon1Lockdown()
    -- Check manifest.json (GitHub raw or local check) for lockdown (bool) & lockdown_message (string)
    local rawManifest = fetchGithubScript(MANIFEST_URL .. "?v=" .. tostring(os.time()))
    if not rawManifest and isfile then
        if isfile("manifest.json") then
            local ok, raw = pcall(readfile, "manifest.json")
            if ok and raw then rawManifest = raw end
        elseif isfile("autoexec/manifest.json") then
            local ok, raw = pcall(readfile, "autoexec/manifest.json")
            if ok and raw then rawManifest = raw end
        elseif isfile("workspace/manifest.json") then
            local ok, raw = pcall(readfile, "workspace/manifest.json")
            if ok and raw then rawManifest = raw end
        end
    end

    if not rawManifest then
        return false -- Proceed with local offline boot
    end

    local ok, parsed = pcall(function() return HttpService:JSONDecode(rawManifest) end)
    if not ok or type(parsed) ~= "table" then
        return false
    end

    -- Update manifest stage hash lookup table
    if parsed.stages and type(parsed.stages) == "table" then
        for _, st in ipairs(parsed.stages) do
            registerManifestStage(st)
        end
    end

    if updateGateController and updateGateController.setManifestData then
        updateGateController.setManifestData(parsed)
    end

    if parsed.lockdown == true then
        local lockdownMsg = parsed.lockdown_message or "Omni Defcon 1 Security Lockdown: Core exploit detection alert. Client air-gapped from server to prevent anti-cheat telemetry. Please review and apply the security patch."

        warn("=====================================================================")
        warn("[Bootloader | DEFCON 1 SECURITY LOCKDOWN ENGAGED]")
        warn(lockdownMsg)
        warn("=====================================================================")

        -- Air-gap client from game server: call LocalPlayer:Kick with appropriate safety checks/waits
        local function airGapClient(msg)
            local Players = nil
            pcall(function() Players = game:GetService("Players") end)
            if not Players then
                pcall(function() Players = game:FindService("Players") end)
            end
            local lp = Players and Players.LocalPlayer
            if lp then
                pcall(function() lp:Kick(msg) end)
                return
            end
            task.spawn(function()
                local kicked = false
                if Players then
                    pcall(function()
                        local conn
                        conn = Players:GetPropertyChangedSignal("LocalPlayer"):Connect(function()
                            if Players.LocalPlayer and not kicked then
                                kicked = true
                                pcall(function() Players.LocalPlayer:Kick(msg) end)
                                if conn then conn:Disconnect() end
                            end
                        end)
                    end)
                end
                local start = os.clock()
                while not kicked and (os.clock() - start) < 30.0 do
                    if not Players then
                        pcall(function() Players = game:GetService("Players") end)
                    end
                    if Players and Players.LocalPlayer then
                        kicked = true
                        pcall(function() Players.LocalPlayer:Kick(msg) end)
                        break
                    end
                    task.wait(0.05)
                end
            end)
        end
        airGapClient(lockdownMsg)

        pcall(delfile, RUNNING_LOCK)
        getgenv()._OmniBootloaderRunning = false
        getgenv()._OmniLockdownActive = true

        -- STEP 4: Render Diff Viewer in CoreGui and yield synchronously for user approval
        if updateGateController and updateGateController.yieldApproval then
            local approved = updateGateController.yieldApproval(true, lockdownMsg)
            if approved then
                updateGateController.applyVerified()
                warn("[Bootloader | DEFCON 1]: Security patch applied successfully from memory. Please restart client.")
            else
                warn("[Bootloader | DEFCON 1]: Security patch dismissed by user.")
            end
        else
            warn("[Bootloader | DEFCON 1]: CoreGui unavailable. Client air-gapped from server.")
        end

        -- HALT BOOTLOADER: Core rings and user autoexec scripts NEVER RUN
        return true
    end

    return false
end

local isLockdownActive = checkDefcon1Lockdown()
if isLockdownActive then
    print("[Bootloader]: Bootloader halted under Defcon 1 Security Lockdown.")
    return
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
    local existing = registeredBasenames[dedupKey]
    if existing then
        -- Prefer .lua / .luau over .txt if both exist in the same directory
        local isNewLua = meta.file:lower():match("%.lua[u]?$")
        local isOldTxt = existing.file:lower():match("%.txt$")
        if isNewLua and isOldTxt then
            -- Remove old .txt entry from its registered queue (even if in a different stage)
            local oldQueue = Queues[existing.stage]
            if oldQueue then
                for idx, item in ipairs(oldQueue) do
                    if item == existing then
                        table.remove(oldQueue, idx)
                        Telemetry.stages[existing.stage] = math.max(0, (Telemetry.stages[existing.stage] or 1) - 1)
                        break
                    end
                end
            end
            -- Insert the superior .lua/.luau file into its designated queue
            table.insert(Queues[meta.stage], meta)
            Telemetry.stages[meta.stage] = (Telemetry.stages[meta.stage] or 0) + 1
            registeredBasenames[dedupKey] = meta
        end
        return
    end
    registeredBasenames[dedupKey] = meta

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
    local content = ""
    local status = "PENDING"
    local errorMsg = nil
    local execMs = 0
    
    local scriptEntry = {
        name = scriptName,
        file = file,
        stage = meta.stage,
        priority = meta.priority,
        status = "PENDING",
        compileMs = 0,
        execMs = 0,
        error = nil
    }
    
    if type(readfile) == "function" and isfile(file) then
        local ok, fileData = pcall(readfile, file)
        if ok and fileData then
            content = fileData
            -- STEP 3: Cryptographic Integrity Verification (TOCTOU Defense)
            local expectedSha = meta.sha256
            if not expectedSha then
                local stageObj = lookupManifestStage(scriptName, file)
                if stageObj then expectedSha = stageObj.sha256 end
            end
            if expectedSha then
                local isValid = verifyContentHash(content, expectedSha)
                if not isValid then
                    warn(string.format("[Bootloader | INTEGRITY BREACH]: SHA-256 hash mismatch for %s! Expected: %s. Aborting execution!", scriptName, expectedSha))
                    status = "SECURITY_HASH_MISMATCH"
                    scriptEntry.status = status
                    scriptEntry.error = "SHA-256 integrity check failed: file may be tampered on disk"
                    Telemetry.errors = Telemetry.errors + 1
                    Telemetry.executed = Telemetry.executed + 1
                    table.insert(Telemetry.scripts, scriptEntry)
                    emitTelemetry()
                    return
                end
            end
            -- Memory-only compilation from verified buffer via unhookable cloned loadstring
            compiledFn, syntaxErr = _clonedLoadstring(content, "@" .. scriptName)
        else
            syntaxErr = "Failed to read file from disk."
        end
    else
        syntaxErr = "File inaccessible via readfile."
    end
    
    local compileMs = (os.clock() - compileStart) * 1000
    scriptEntry.compileMs = math.floor(compileMs * 100) / 100

    if compiledFn then
        -- Attach scoped environment to un-obfuscated scripts so game:GetService("RunService") routes to Active Tasks
        local exempt = getgenv()._KernelExemptScripts or {}
        local isExempt = (meta.name and exempt[meta.name:lower()]) or (meta.file and exempt[meta.file:lower()]) or isObfuscatedCode(content or "", meta.name or meta.file)
        if not isExempt then
            local gameProxy = getgenv()._OmniGameProxy or (getgenv()._OmniCreateGameProxy and getgenv()._OmniCreateGameProxy())
            if gameProxy then
                local fnEnv = getfenv(compiledFn)
                if fnEnv and fnEnv.game ~= gameProxy then
                    local origCloneref = getgenv().cloneref or cloneref
                    local function safeCloneref(obj, ...)
                        if not obj
                            or rawequal(obj, gameProxy)
                            or (getgenv()._VirtualSchedulerProxiedRunService and rawequal(obj, getgenv()._VirtualSchedulerProxiedRunService))
                            or (getgenv().RunService and rawequal(obj, getgenv().RunService))
                            or typeof(obj) ~= "Instance" then
                            return obj
                        end
                        return origCloneref(obj, ...)
                    end
                    local scriptEnv = setmetatable({
                        game = gameProxy,
                        RunService = getgenv()._VirtualSchedulerProxiedRunService or getgenv().RunService,
                        cloneref = (type(origCloneref) == "function" and safeCloneref) or nil,
                    }, { __index = fnEnv })
                    pcall(setfenv, compiledFn, scriptEnv)
                end
            end
        end

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
local syncOk, syncErr = pcall(function()
    bootStart = os.clock()
    getgenv()._OmniRingsStarted = true

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

        -- Critical init phase complete: disarm crash sentinel so disconnects/rejoins don't trigger Safe Mode!
        pcall(delfile, RUNNING_LOCK)
    else
        print("[Bootloader]: Safe Mode Active — Bypassing Ring 1 (PreInit).")
    end
    emitTelemetry()
end)

if not syncOk then
    warn("[Bootloader]: ⚠️ Critical init phase error (Ring 0/1): " .. tostring(syncErr))
    pcall(delfile, RUNNING_LOCK)
    getgenv()._OmniBootloaderRunning = false
    return
end

-- ==============================================================================
-- RINGS 2 & 3: NETWORK CLIENT & USERSPACE LIFECYCLE (Async)
-- ==============================================================================

task.spawn(function()
    local asyncOk, asyncErr = pcall(function()
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

        print(string.format("[Bootloader]: Boot completed in %.1fms | Discovered: %d | Executed: %d | Success: %d | Errors: %d",
            totalBootMs, Telemetry.discovered, Telemetry.executed, Telemetry.success, Telemetry.errors))

        -- Keep Omni alive across teleports only if not already installed in autoexec
        local hasLocal = (type(isfile) == "function") and (
            isfile("Omni_Autoexec.marker")
            or isfile("autoexec/Bootloader.lua")
            or isfile("autoexec/CustomAutoExec.lua")
            or isfile("autoexe/Bootloader.lua")
            or isfile("autoexe/CustomAutoExec.lua")
        )
        if not hasLocal then
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
                                local isLocal = (type(isfile) == "function") and (
                                    isfile("Omni_Autoexec.marker")
                                    or isfile("autoexec/Bootloader.lua")
                                    or isfile("autoexec/CustomAutoExec.lua")
                                    or isfile("autoexe/Bootloader.lua")
                                    or isfile("autoexe/CustomAutoExec.lua")
                                )
                                if not isLocal then
                                    pcall(function()
                                        loadstring(game:HttpGet("https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/Bootloader.lua"))()
                                    end)
                                end
                            end
                        end)
                    ]])
                end)
            end
        end
    end)

    -- In all outcomes, ensure lock is gone and running flag is cleared
    pcall(delfile, RUNNING_LOCK)
    getgenv()._OmniBootloaderRunning = false
    getgenv()._OmniBootloaderLoaded = true

    if not asyncOk then
        warn("[Bootloader]: ⚠️ Error in async lifecycle: " .. tostring(asyncErr))
    end
end)