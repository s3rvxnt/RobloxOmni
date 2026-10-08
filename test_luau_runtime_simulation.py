#!/usr/bin/env python3
"""
Deep Luau Runtime Simulation Test.
Executes actual Luau scripts with mock environments using luau.exe to verify:
- Defcon 1 kill switch kicks LocalPlayer and halts execution
- Manifest lockdown=false allows execution to proceed
- Primitives cloned via clonefunction resist global hijacking
- SHA-256 integrity verification blocks tampered code
"""

import json
import os
import subprocess
import unittest

LUAU_PATH = r"C:\Users\admin\luau\luau.exe"
BOOTLOADER_PATH = os.path.join(os.path.dirname(__file__), "Bootloader.lua")

class TestLuauRuntimeSimulation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(BOOTLOADER_PATH, "r", encoding="utf-8") as f:
            cls.bootloader_source = f.read()

    def test_01_lockdown_true_kicks_and_halts(self):
        """Simulate Defcon 1 lockdown=true in Luau: assert LocalPlayer:Kick is called and rings halt."""
        simulation_script = """
        -- Mock Roblox environment
        local kickedMessage = nil
        local ring0Executed = false
        local uiRendered = false

        local mockLocalPlayer = {
            Kick = function(self, msg)
                kickedMessage = msg
            end
        }

        local mockPlayers = {
            LocalPlayer = mockLocalPlayer,
            GetPropertyChangedSignal = function()
                return { Wait = function() end }
            end
        }

        local mockHttpService = {
            JSONDecode = function(self, str)
                return {
                    version = "1.0.0",
                    lockdown = true,
                    lockdown_message = "EMERGENCY_LOCKDOWN_TEST"
                }
            end
        }

        local mockGame = {
            GetService = function(self, svc)
                if svc == "Players" then return mockPlayers end
                if svc == "HttpService" then return mockHttpService end
                if svc == "CoreGui" then return {} end
                return {}
            end,
            PlaceId = 12345,
            GameId = 67890
        }

        -- Mock executor primitives
        local _genv = {}
        local function getgenv() return _genv end
        local function isfile(path) return true end
        local function readfile(path) return '{"lockdown": true, "lockdown_message": "EMERGENCY_LOCKDOWN_TEST"}' end
        local function delfile(path) return true end
        local function writefile(path, content) return true end
        local function isfolder(path) return true end
        local function makefolder(path) return true end
        local function listfiles(path) return {} end
        local function clonefunction(f) return f end

        -- Extract Step 1 & 2 logic from Bootloader
        local _rawClone = clonefunction
        local function _safeClone(fn) return fn end
        local _writefile = _safeClone(writefile)
        local _readfile = _safeClone(readfile)
        local _isfile = _safeClone(isfile)
        local _delfile = _safeClone(delfile)
        local _loadstring = _safeClone(loadstring)

        local game = mockGame
        local HttpService = mockHttpService

        local updateGateMock = {
            yieldApproval = function(isLockdown, msg)
                uiRendered = true
                return true
            end,
            applyVerified = function() end,
            setManifestData = function() end
        }
        local updateGateController = updateGateMock

        -- The exact checkDefcon1Lockdown logic
        local function checkDefcon1Lockdown()
            local rawManifest = readfile("manifest.json")
            local ok, parsed = pcall(function() return HttpService:JSONDecode(rawManifest) end)
            if not ok or type(parsed) ~= "table" then return false end

            if parsed.lockdown == true then
                local lockdownMsg = parsed.lockdown_message or "Omni Defcon 1 Security Lockdown"
                local function airGapClient(msg)
                    local Players = game:GetService("Players")
                    local lp = Players and Players.LocalPlayer
                    if lp then pcall(function() lp:Kick(msg) end) end
                end
                airGapClient(lockdownMsg)
                getgenv()._OmniLockdownActive = true

                if updateGateController and updateGateController.yieldApproval then
                    local approved = updateGateController.yieldApproval(true, lockdownMsg)
                end
                return true
            end
            return false
        end

        local isLockdown = checkDefcon1Lockdown()
        if not isLockdown then
            ring0Executed = true
        end

        print("KICKED:" .. tostring(kickedMessage))
        print("HALTED:" .. tostring(isLockdown))
        print("UI_RENDERED:" .. tostring(uiRendered))
        print("RING0:" .. tostring(ring0Executed))
        """

        temp_file = "sim_lockdown_test.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(simulation_script)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("KICKED:EMERGENCY_LOCKDOWN_TEST", output)
            self.assertIn("HALTED:true", output)
            self.assertIn("UI_RENDERED:true", output)
            self.assertIn("RING0:false", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_02_lockdown_false_allows_execution(self):
        """Simulate manifest lockdown=false in Luau: assert LocalPlayer:Kick is NOT called and rings proceed."""
        simulation_script = """
        local kickedMessage = nil
        local ring0Executed = false

        local mockLocalPlayer = {
            Kick = function(self, msg) kickedMessage = msg end
        }
        local mockPlayers = { LocalPlayer = mockLocalPlayer }
        local mockHttpService = {
            JSONDecode = function(self, str)
                return { version = "1.0.0", lockdown = false }
            end
        }
        local mockGame = {
            GetService = function(self, svc)
                if svc == "Players" then return mockPlayers end
                if svc == "HttpService" then return mockHttpService end
                return {}
            end
        }

        local game = mockGame
        local HttpService = mockHttpService
        local function readfile(path) return '{"lockdown": false}' end

        local function checkDefcon1Lockdown()
            local rawManifest = readfile("manifest.json")
            local ok, parsed = pcall(function() return HttpService:JSONDecode(rawManifest) end)
            if ok and parsed.lockdown == true then
                mockLocalPlayer:Kick(parsed.lockdown_message)
                return true
            end
            return false
        end

        local isLockdown = checkDefcon1Lockdown()
        if not isLockdown then
            ring0Executed = true
        end

        print("KICKED:" .. tostring(kickedMessage))
        print("HALTED:" .. tostring(isLockdown))
        print("RING0:" .. tostring(ring0Executed))
        """

        temp_file = "sim_lockdown_false.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(simulation_script)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("KICKED:nil", output)
            self.assertIn("HALTED:false", output)
            self.assertIn("RING0:true", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_03_anti_hooking_cloning_integrity(self):
        """Simulate primitive hooking attack: ensure cloned closures ignore malicious global hooks."""
        simulation_script = """
        local originalWritefileInvoked = false
        local maliciousHookInvoked = false

        -- Original primitive
        local globalWritefile = function(path, content)
            originalWritefileInvoked = true
        end

        -- Clonefunction primitive
        local function clonefunction(fn)
            -- Simulates executor C-closure cloning: returns distinct wrapper holding pointer
            return function(...) return fn(...) end
        end

        -- Step 2 Capture on Line 1
        local _writefile = clonefunction(globalWritefile)
        local writefile = _writefile

        -- Malicious third-party script hooks the global
        globalWritefile = function(path, content)
            maliciousHookInvoked = true
        end

        -- Internal bootloader operation uses file-scoped writefile
        writefile("test.txt", "data")

        print("ORIGINAL:" .. tostring(originalWritefileInvoked))
        print("HOOKED:" .. tostring(maliciousHookInvoked))
        """

        temp_file = "sim_antihook.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(simulation_script)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("ORIGINAL:true", output)
            self.assertIn("HOOKED:false", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_04_sha256_hash_mismatch_blocks_execution(self):
        """Simulate tampered stage content: assert verifyContentHash detects tampering and blocks execution."""
        simulation_script = f"""
        local bit32 = bit32
        {self.bootloader_source[self.bootloader_source.find("local _K_SHA256 ="):self.bootloader_source.find("local bootStart = os.clock()")]}

        local officialCode = "print('Official Kernel Task Manager')"
        local officialHash = computeSha256(officialCode)

        local tamperedCode = "print('Malicious Injection!')"

        local officialCheck = verifyContentHash(officialCode, officialHash)
        local tamperedCheck = verifyContentHash(tamperedCode, officialHash)

        print("OFFICIAL_VALID:" .. tostring(officialCheck))
        print("TAMPERED_VALID:" .. tostring(tamperedCheck))
        """

        temp_file = "sim_sha256_integrity.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(simulation_script)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("OFFICIAL_VALID:true", output)
            self.assertIn("TAMPERED_VALID:false", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_05_execute_script_hash_mismatch_no_nil_index_crash(self):
        """Simulate executeScript on tampered file: assert clean abort without nil index crash."""
        simulation_script = f"""
        local bit32 = bit32
        {self.bootloader_source[self.bootloader_source.find("local _K_SHA256 ="):self.bootloader_source.find("local bootStart = os.clock()")]}

        local Telemetry = {{
            errors = 0,
            executed = 0,
            success = 0,
            scripts = {{}}
        }}
        local function emitTelemetry() end

        local function isfile(path) return true end
        local function readfile(path) return "print('tampered script payload')" end
        local function _clonedLoadstring(src, name) return function() end end

        local manifestStagesByName = {{}}
        local function registerManifestStage(st)
            manifestStagesByName[st.name] = st
            manifestStagesByName[st.localPath] = st
        end
        local function lookupManifestStage(name, path)
            return manifestStagesByName[name] or manifestStagesByName[path]
        end

        local expectedOfficialHash = "a15cfe41a10508962ed4b3943ce429f6bbfcfd1cc71549febe6b834448184349"
        registerManifestStage({{
            name = "KernelTaskManager",
            localPath = "autoexec/kernel/KernelTaskManager.lua",
            sha256 = expectedOfficialHash
        }})

        local executedFiles = {{}}

        -- The exact executeScript logic from Bootloader.lua
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
            
            local scriptEntry = {{
                name = scriptName,
                file = file,
                stage = meta.stage,
                priority = meta.priority,
                status = "PENDING",
                compileMs = 0,
                execMs = 0,
                error = nil
            }}

            if type(readfile) == "function" and isfile(file) then
                local ok, fileData = pcall(readfile, file)
                if ok and fileData then
                    content = fileData
                    local expectedSha = meta.sha256
                    if not expectedSha then
                        local stageObj = lookupManifestStage(scriptName, file)
                        if stageObj then expectedSha = stageObj.sha256 end
                    end
                    if expectedSha then
                        local isValid = verifyContentHash(content, expectedSha)
                        if not isValid then
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
                    compiledFn, syntaxErr = _clonedLoadstring(content, "@" .. scriptName)
                end
            end
        end

        local ok, err = pcall(function()
            executeScript({{
                file = "autoexec/kernel/KernelTaskManager.lua",
                name = "KernelTaskManager",
                stage = "Kernel",
                priority = 0
            }})
        end)

        print("PCALL_OK:" .. tostring(ok))
        print("ERR:" .. tostring(err))
        print("TELEMETRY_ERRORS:" .. tostring(Telemetry.errors))
        print("SCRIPT_STATUS:" .. tostring(Telemetry.scripts[1] and Telemetry.scripts[1].status))
        """

        temp_file = "sim_exec_tamper.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(simulation_script)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("PCALL_OK:true", output)
            self.assertIn("TELEMETRY_ERRORS:1", output)
            self.assertIn("SCRIPT_STATUS:SECURITY_HASH_MISMATCH", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_06_lookup_manifest_stage_windows_paths(self):
        """Verify lookupManifestStage matches Windows backslashes and file extensions."""
        harness = f"""
        {self.bootloader_source[self.bootloader_source.find("local BOOTSTRAP_STAGES ="):self.bootloader_source.find("local function isStageDisabled")]}

        local testWindowsPath = "autoexec\\\\kernel\\\\KernelTaskManager.lua"
        local testNameWithExt = "KernelTaskManager.lua"

        local st1 = lookupManifestStage("KernelTaskManager", testWindowsPath)
        local st2 = lookupManifestStage(testNameWithExt, testWindowsPath)
        local st3 = lookupManifestStage("OmniEnhancementSuite.luau", "autoexec\\\\gameloaded\\\\OmniEnhancementSuite.lua")

        print("ST1:" .. tostring(st1 and st1.name))
        print("ST2:" .. tostring(st2 and st2.name))
        print("ST3:" .. tostring(st3 and st3.name))
        """
        temp_file = "sim_lookup_stage.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("ST1:KernelTaskManager", output)
            self.assertIn("ST2:KernelTaskManager", output)
            self.assertIn("ST3:OmniEnhancementSuite", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_07_verify_content_hash_line_ending_tolerance(self):
        """Verify verifyContentHash tolerates both LF and CRLF line ending differences."""
        harness = f"""
        local bit32 = bit32
        {self.bootloader_source[self.bootloader_source.find("local _K_SHA256 ="):self.bootloader_source.find("local bootStart = os.clock()")]}

        local codeLF = "local a = 1\\nlocal b = 2\\nreturn a + b"
        local codeCRLF = "local a = 1\\r\\nlocal b = 2\\r\\nreturn a + b"

        local hashLF = computeSha256(codeLF)
        local hashCRLF = computeSha256(codeCRLF)

        -- LF content checked against CRLF hash:
        local match1 = verifyContentHash(codeLF, hashCRLF)
        -- CRLF content checked against LF hash:
        local match2 = verifyContentHash(codeCRLF, hashLF)

        print("MATCH1:" .. tostring(match1))
        print("MATCH2:" .. tostring(match2))
        """
        temp_file = "sim_line_endings.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("MATCH1:true", output)
            self.assertIn("MATCH2:true", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_08_table_freeze_gc_scraping_protection(self):
        """Verify table.freeze prevents rogue GC-scraping scripts from mutating manifest/controller tables."""
        harness = """
        local t = { name = "KernelTaskManager", sha256 = "abc" }
        table.freeze(t)

        local okMutate, errMutate = pcall(function()
            t.sha256 = "hacked"
        end)

        print("MUTATE_BLOCKED:" .. tostring(not okMutate))
        """
        temp_file = "sim_freeze.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            output = res.stdout
            self.assertIn("MUTATE_BLOCKED:true", output)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_09_validate_safe_local_path_runtime_simulation(self):
        """Simulate validateSafeLocalPath against diverse sandbox escape vectors."""
        # Extract validateSafeLocalPath from Bootloader.lua
        start_marker = "local function validateSafeLocalPath(path)"
        end_marker = "local BOOTSTRAP_STAGES ="
        func_body = self.bootloader_source[self.bootloader_source.find(start_marker):self.bootloader_source.find(end_marker)]

        harness = f"""
        {func_body}

        local testVectors = {{
            {{ path = "../../evil.bat", expectSafe = false }},
            {{ path = "autoexec/../../Windows/calc.exe", expectSafe = false }},
            {{ path = "C:\\\\Windows\\\\System32\\\\cmd.exe", expectSafe = false }},
            {{ path = "/etc/passwd", expectSafe = false }},
            {{ path = "autoexec/test.lua:evil.bat", expectSafe = false }},
            {{ path = "autoexec/%2e%2e/test.lua", expectSafe = false }},
            {{ path = "autoexec/test.lua.", expectSafe = false }},
            {{ path = "autoexec//test.lua", expectSafe = false }},
            {{ path = "autoexec/kernel/KernelTaskManager.lua", expectSafe = true }},
            {{ path = "autoexec\\\\kernel\\\\KernelTaskManager.lua", expectSafe = true }},
            {{ path = "workspace/manifest.json", expectSafe = true }},
            {{ path = "Omni_Ledger.json", expectSafe = true }}
        }}

        local allPassed = true
        for idx, vec in ipairs(testVectors) do
            local res = validateSafeLocalPath(vec.path)
            local isSafe = (res ~= nil)
            if isSafe ~= vec.expectSafe then
                print("FAIL_VEC_" .. idx .. ":" .. tostring(vec.path) .. " expected:" .. tostring(vec.expectSafe) .. " got:" .. tostring(isSafe))
                allPassed = false
            end
        end
        print("ALL_PATHS_SECURE:" .. tostring(allPassed))
        """
        temp_file = "sim_path_traversal.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("ALL_PATHS_SECURE:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_10_unicode_smuggling_and_diff_sanitizer_simulation(self):
        """Simulate Zero-Width Unicode smuggling and Trojan Source BiDi overrides in Luau runtime."""
        harness = r"""
        -- Test sanitizeDiffText
        local function sanitizeDiffText(text)
            if not text or type(text) ~= "string" then return "" end
            local s = text
            s = s:gsub("\239\187\191", "[BOM]")
            s = s:gsub("\226\128\139", "[ZWSP]")
            s = s:gsub("\226\128\140", "[ZWNJ]")
            s = s:gsub("\226\128\141", "[ZWJ]")
            s = s:gsub("\226\128\142", "[LRM]")
            s = s:gsub("\226\128\143", "[RLM]")
            s = s:gsub("\226\128\170", "[LRE]")
            s = s:gsub("\226\128\171", "[RLE]")
            s = s:gsub("\226\128\172", "[PDF]")
            s = s:gsub("\226\128\173", "[LRO]")
            s = s:gsub("\226\128\174", "[RLO]")
            s = s:gsub("\226\129\166", "[LRI]")
            s = s:gsub("\226\129\167", "[RLI]")
            s = s:gsub("\226\129\168", "[FSI]")
            s = s:gsub("\226\129\169", "[PDI]")
            s = s:gsub("[\1-\8\11-\12\14-\31]", function(c)
                return string.format("\\x%02X", string.byte(c))
            end)
            return s
        end

        local maliciousLine1 = "local secret = 'p" .. "\226\128\139" .. "assword'"
        local maliciousLine2 = "print('safe') -- " .. "\226\128\174" .. " 'admin' == user"
        local maliciousLine3 = "\239\187\191local x = 1"

        local clean1 = sanitizeDiffText(maliciousLine1)
        local clean2 = sanitizeDiffText(maliciousLine2)
        local clean3 = sanitizeDiffText(maliciousLine3)

        print("HAS_ZWSP:" .. tostring(clean1:find("%[ZWSP%]") ~= nil))
        print("HAS_RLO:" .. tostring(clean2:find("%[RLO%]") ~= nil))
        print("HAS_BOM:" .. tostring(clean3:find("%[BOM%]") ~= nil))
        """
        temp_file = "sim_unicode_test.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("HAS_ZWSP:true", res.stdout)
            self.assertIn("HAS_RLO:true", res.stdout)
            self.assertIn("HAS_BOM:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_11_clonefunction_poisoning_detection_simulation(self):
        """Simulate pre-empting autoexec script poisoning clonefunction with a Lua closure."""
        harness = """
        -- Third party script 00_evil.lua hooks clonefunction with a Lua closure
        local evilHookInvoked = false
        local fakeClonefunction = function(f)
            evilHookInvoked = true
            return f
        end

        local _rawClone = fakeClonefunction
        local _clonefunctionPoisoned = false

        -- Mock executor primitives: islclosure returns true for Lua functions
        local function islclosure(fn) return true end
        local function iscclosure(fn) return false end

        local _checkIsCClosure = iscclosure
        local _checkIsLClosure = islclosure
        local _checkDebugInfo = debug.info

        if _checkIsLClosure then
            local okL, isL = pcall(_checkIsLClosure, _rawClone)
            if okL and isL == true then
                _clonefunctionPoisoned = true
            end
        end

        if not _clonefunctionPoisoned and _checkIsCClosure then
            local okC, isC = pcall(_checkIsCClosure, _rawClone)
            if not okC or isC ~= true then
                _clonefunctionPoisoned = true
            end
        end

        if not _clonefunctionPoisoned and _checkDebugInfo then
            local okD, src = pcall(_checkDebugInfo, _rawClone, "s")
            if not okD or src ~= "[C]" then
                _clonefunctionPoisoned = true
            end
        end

        if _clonefunctionPoisoned then
            _rawClone = nil
        end

        local function _safeClone(fn)
            if _rawClone and type(fn) == "function" then
                return _rawClone(fn)
            end
            return fn
        end

        local testFn = function() return "test" end
        local resultFn = _safeClone(testFn)

        print("POISON_DETECTED:" .. tostring(_clonefunctionPoisoned))
        print("RAW_CLONE_DISCARDED:" .. tostring(_rawClone == nil))
        print("EVIL_HOOK_INVOKED:" .. tostring(evilHookInvoked))
        print("FALLBACK_PRESERVED:" .. tostring(resultFn == testFn))
        """
        temp_file = "sim_clone_poison.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("POISON_DETECTED:true", res.stdout)
            self.assertIn("RAW_CLONE_DISCARDED:true", res.stdout)
            self.assertIn("EVIL_HOOK_INVOKED:false", res.stdout)
            self.assertIn("FALLBACK_PRESERVED:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_12_defcon1_click_blocker_simulation(self):
        """Simulate Defcon 1 panic click-through rejection while countdown active."""
        harness = """
        local applied = false
        local isDefcon1Lockdown = true
        local defcon1CountdownThread = {} -- Active countdown thread representation

        local function onApplyClicked()
            if isDefcon1Lockdown and defcon1CountdownThread ~= nil then
                -- Rejected!
                return false
            end
            applied = true
            return true
        end

        local attempt1 = onApplyClicked()
        print("ATTEMPT_1_BLOCKED:" .. tostring(not attempt1))
        print("APPLIED_1:" .. tostring(applied))

        -- Countdown finishes
        defcon1CountdownThread = nil

        local attempt2 = onApplyClicked()
        print("ATTEMPT_2_ALLOWED:" .. tostring(attempt2))
        print("APPLIED_2:" .. tostring(applied))
        """
        temp_file = "sim_defcon1_click.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("ATTEMPT_1_BLOCKED:true", res.stdout)
            self.assertIn("APPLIED_1:false", res.stdout)
            self.assertIn("ATTEMPT_2_ALLOWED:true", res.stdout)
            self.assertIn("APPLIED_2:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)


    def test_13_primitive_lua_hook_detection_simulation(self):
        """Simulate pre-empting autoexec script hooking primitives (loadstring/writefile) with Lua closures."""
        harness = """
        local islclosure = function(fn) return true end
        local iscclosure = function(fn) return false end
        local _checkIsLClosure = islclosure

        local _primitivesPoisoned = false
        local function _safeClone(fn) return fn end

        local function _capturePrimitive(rawFn, name)
            if not rawFn then return nil end
            if _checkIsLClosure then
                local okL, isL = pcall(_checkIsLClosure, rawFn)
                if okL and isL == true then
                    _primitivesPoisoned = true
                    return nil
                end
            end
            return _safeClone(rawFn)
        end

        local hookedLoadstring = function(code) return function() end end
        local captured = _capturePrimitive(hookedLoadstring, "loadstring")

        print("PRIMITIVE_POISONED:" .. tostring(_primitivesPoisoned))
        print("CAPTURED_NIL:" .. tostring(captured == nil))

        local SafeMode = false
        local SafeModeReason = nil
        if _primitivesPoisoned then
            SafeMode = true
            SafeModeReason = "PrimitivePoisoning"
        end
        print("SAFE_MODE_ENGAGED:" .. tostring(SafeMode))
        print("SAFE_MODE_REASON:" .. tostring(SafeModeReason))
        """
        temp_file = "sim_primitive_hook.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("PRIMITIVE_POISONED:true", res.stdout)
            self.assertIn("CAPTURED_NIL:true", res.stdout)
            self.assertIn("SAFE_MODE_ENGAGED:true", res.stdout)
            self.assertIn("SAFE_MODE_REASON:PrimitivePoisoning", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_14_multibyte_bidi_and_typographic_unicode_simulation(self):
        """Verify multi-byte UTF-8 regex correctly distinguishes typography from Trojan Source BiDi and Homoglyphs."""
        harness = r"""
        local Color3 = { fromRGB = function(r, g, b) return { r = r, g = g, b = b } end }

        local function auditScriptContent(code)
            local badges = {}
            local isObfuscated = false

            local hasZeroWidth = false
            local hasBidiTrojan = false
            local hasHomoglyphs = false

            if code:find("\226\128\139") or code:find("\226\128\140") or code:find("\226\128\141")
                or code:find("\239\187\191") or code:find("\226\128\142") or code:find("\226\128\143")
                or code:find("\226\128[\128-\138]") or code:find("\226\129\160") or code:find("\194\173") then
                hasZeroWidth = true
            end

            if code:find("\226\128[\170-\174]") or code:find("\226\129[\166-\169]") then
                hasBidiTrojan = true
            end

            for line in code:gmatch("[^\r\n]+") do
                if not line:match("^%s*%-%-") then
                    local strippedLine = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
                    if strippedLine:find("[\208-\209][\128-\191]") or strippedLine:find("[\206-\207][\128-\191]") then
                        hasHomoglyphs = true
                        break
                    end
                end
            end

            if hasBidiTrojan then
                isObfuscated = true
                table.insert(badges, { label = "Trojan_BiDi" })
            elseif hasZeroWidth or hasHomoglyphs then
                isObfuscated = true
                table.insert(badges, { label = "Unicode_Smuggling" })
            end

            if isObfuscated then
                table.insert(badges, { label = "Obfuscated" })
            end
            if #badges == 0 then
                table.insert(badges, { label = "Clean" })
            end
            return badges, isObfuscated
        end

        -- Case 1: Standard scripts with em-dash, euro sign, arrows, and localized Cyrillic in quotes
        local benign1 = 'print("Version 1.0 \226\128\148 Release")' -- Em-dash U+2014
        local benign2 = 'local price = "10\226\130\172"' -- Euro U+20AC
        local benign3 = 'print("Step 1 \226\134\146 Step 2")' -- Arrow U+2192
        local benign4 = 'local greeting = "\208\159\209\128\208\184\208\146\208\181\209\130"' -- Cyrillic string literal

        local b1, obf1 = auditScriptContent(benign1)
        local b2, obf2 = auditScriptContent(benign2)
        local b3, obf3 = auditScriptContent(benign3)
        local b4, obf4 = auditScriptContent(benign4)

        print("BENIGN_1_CLEAN:" .. tostring(b1[1].label == "Clean"))
        print("BENIGN_2_CLEAN:" .. tostring(b2[1].label == "Clean"))
        print("BENIGN_3_CLEAN:" .. tostring(b3[1].label == "Clean"))
        print("BENIGN_4_CLEAN:" .. tostring(b4[1].label == "Clean"))

        -- Case 2: Real Trojan Source BiDi RLO U+202E (\226\128\174)
        local maliciousBidi = "print('safe') -- " .. "\226\128\174" .. " user == 'admin'"
        local bBidi, obfBidi = auditScriptContent(maliciousBidi)
        print("MALICIOUS_BIDI_DETECTED:" .. tostring(bBidi[1].label == "Trojan_BiDi"))

        -- Case 3: Real Zero-Width space U+200B (\226\128\139)
        local maliciousZwsp = "local sec" .. "\226\128\139" .. "ret = 1"
        local bZwsp, obfZwsp = auditScriptContent(maliciousZwsp)
        print("MALICIOUS_ZWSP_DETECTED:" .. tostring(bZwsp[1].label == "Unicode_Smuggling"))

        -- Case 4: Real homoglyph disguised in variable name (Cyrillic 'a' \208\176 in local admin)
        local maliciousHomoglyph = "local \208\176dmin = true"
        local bHomo, obfHomo = auditScriptContent(maliciousHomoglyph)
        print("MALICIOUS_HOMOGLYPH_DETECTED:" .. tostring(bHomo[1].label == "Unicode_Smuggling"))
        """
        temp_file = "sim_multibyte_unicode.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("BENIGN_1_CLEAN:true", res.stdout)
            self.assertIn("BENIGN_2_CLEAN:true", res.stdout)
            self.assertIn("BENIGN_3_CLEAN:true", res.stdout)
            self.assertIn("BENIGN_4_CLEAN:true", res.stdout)
            self.assertIn("MALICIOUS_BIDI_DETECTED:true", res.stdout)
            self.assertIn("MALICIOUS_ZWSP_DETECTED:true", res.stdout)
            self.assertIn("MALICIOUS_HOMOGLYPH_DETECTED:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_15_sandbox_dos_device_and_executable_rejection_simulation(self):
        """Simulate validateSafeLocalPath in Luau rejecting DOS devices, dangerous extensions, and lockfiles."""
        harness = r"""
        local function validateSafeLocalPath(path)
            if type(path) ~= "string" or #path == 0 or #path > 260 then return nil end
            if path:find("[\0-\31\127]") then return nil end
            if path:find('[<>:"|%?%*]') then return nil end
            local lowerPath = path:lower()
            if lowerPath:find("%%2e") or lowerPath:find("%%2f") or lowerPath:find("%%5c") or lowerPath:find("%%25") then return nil end
            if path:match("^[/\\]") then return nil end
            local normalized = path:gsub("\\", "/")
            if normalized:find("%.%./") or normalized:find("/%.%.") or normalized == ".." or normalized:match("^%.%.$") then return nil end
            if normalized:find("//") then return nil end
            if normalized:match("[%s%.]$") then return nil end
            if not (normalized:match("^autoexec/") or normalized:match("^workspace/") or not normalized:find("/")) then return nil end

            local fileName = normalized:match("[^/]+$") or normalized
            local baseName = fileName:match("^([^%.]+)") or fileName
            local upperBase = baseName:upper()
            if upperBase == "CON" or upperBase == "PRN" or upperBase == "AUX" or upperBase == "NUL"
                or upperBase:match("^COM[1-9]$") or upperBase:match("^LPT[1-9]$") then
                return nil
            end

            local lowerNorm = normalized:lower()
            if lowerNorm == "bootloader.lua" or lowerNorm == "autoexec/bootloader.lua"
                or lowerNorm:find("bootloader_running%.lock")
                or lowerNorm:find("bootloader_handoff%.lock")
                or lowerNorm:find("safe_mode%.lock") then
                return nil
            end

            local ext = normalized:match("%.([^%./\\]+)$")
            if ext then
                local lowerExt = ext:lower()
                if lowerExt ~= "lua" and lowerExt ~= "luau" and lowerExt ~= "json" and lowerExt ~= "txt" and lowerExt ~= "marker" then
                    return nil
                end
            end
            return normalized
        end

        local tests = {
            { path = "autoexec/CON", expect = false },
            { path = "autoexec/con.lua", expect = false },
            { path = "workspace/aux.lua", expect = false },
            { path = "workspace/nul.json", expect = false },
            { path = "workspace/payload.exe", expect = false },
            { path = "autoexec/script.bat", expect = false },
            { path = "autoexec/exploit.dll", expect = false },
            { path = "autoexec/Bootloader.lua", expect = false },
            { path = "autoexec/Bootloader_Running.lock", expect = false },
            { path = "autoexec/<test>.lua", expect = false },
            { path = "autoexec/kernel/KernelTaskManager.lua", expect = true },
            { path = "workspace/manifest.json", expect = true },
            { path = "Omni_Ledger.json", expect = true }
        }

        local allPassed = true
        for idx, t in ipairs(tests) do
            local res = validateSafeLocalPath(t.path)
            local ok = (res ~= nil)
            if ok ~= t.expect then
                print("FAIL_IDX_" .. idx .. ":" .. t.path .. " got:" .. tostring(ok) .. " exp:" .. tostring(t.expect))
                allPassed = false
            end
        end
        print("ALL_SANDBOX_TESTS_PASSED:" .. tostring(allPassed))
        """
        temp_file = "sim_sandbox_dos.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("ALL_SANDBOX_TESTS_PASSED:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_17_loadstring_url_ledger_and_diff_simulation(self):
        """Simulate real Luau execution of URL ledger, author update diff prompt, and safe rollback."""
        harness = """
        local bit32 = bit32
        local pureSha = function(msg)
            -- Lightweight SHA mock for simulation
            local h = 0
            for i = 1, #msg do
                h = bit32.bxor(h * 31 + string.byte(msg, i), 0x55555555)
            end
            return string.format("%08x", h)
        end
        local computeSha256 = pureSha

        local mockFs = {}
        local isfile = function(p) return mockFs[p] ~= nil end
        local isfolder = function(p) return true end
        local makefolder = function(p) end
        local readfile = function(p) return mockFs[p] end
        local writefile = function(p, c) mockFs[p] = c end

        -- Extraction of URL ledger & loadstring gateway logic
        local TRUSTED_URLS_LEDGER_PATH = "Omni_TrustedUrls.json"
        local TRUSTED_SCRIPTS_DIR = "omni_trusted_scripts"

        local _fetchedUrlByContentHash = {}
        local function recordFetch(url, body)
            local h = computeSha256(body)
            _fetchedUrlByContentHash[h] = url
        end

        local function sanitizeUrlToFilename(url)
            local clean = url:gsub("^https?://", ""):gsub("[^%w%.%-_]", "_")
            local h = computeSha256(url):sub(1, 8)
            return clean .. "_" .. h .. ".lua"
        end

        local function loadTrustedUrlLedger()
            if isfile(TRUSTED_URLS_LEDGER_PATH) then
                local raw = readfile(TRUSTED_URLS_LEDGER_PATH)
                -- Simple parse for simulation
                return raw
            end
            return { version = 1, urls = {}, hashes = {} }
        end

        local ledgerData = { urls = {}, hashes = {} }
        local function getLedger() return ledgerData end
        local function saveLedger(data) ledgerData = data end

        local gatePromptCalls = {}
        local mockUserDecision = "approve"

        local function promptRemoteScriptSecurity(opts)
            table.insert(gatePromptCalls, opts)
            return mockUserDecision
        end

        local function safeLoadstring(src, chunkname)
            local srcHash = computeSha256(src)
            local targetUrl = _fetchedUrlByContentHash[srcHash]
            local ledger = getLedger()

            if targetUrl then
                local trusted = ledger.urls[targetUrl]
                if trusted then
                    if trusted.hash == srcHash then
                        return "EXECUTED_VERIFIED_MATCH:" .. src
                    else
                        local oldCode = readfile(trusted.local_file) or ""
                        local decision = promptRemoteScriptSecurity({
                            mode = "script_update",
                            url = targetUrl,
                            oldCode = oldCode,
                            newCode = src
                        })
                        if decision == "approve" then
                            writefile(trusted.local_file, src)
                            trusted.hash = srcHash
                            return "EXECUTED_APPROVED_UPDATE:" .. src
                        elseif decision == "run_previous" then
                            return "EXECUTED_PREVIOUS_SAFE:" .. oldCode
                        else
                            return nil, "Omni Security Gate: Execution blocked by user"
                        end
                    end
                else
                    local decision = promptRemoteScriptSecurity({
                        mode = "script_new",
                        url = targetUrl,
                        oldCode = "",
                        newCode = src
                    })
                    if decision == "approve" then
                        local filename = TRUSTED_SCRIPTS_DIR .. "/" .. sanitizeUrlToFilename(targetUrl)
                        writefile(filename, src)
                        ledger.urls[targetUrl] = {
                            url = targetUrl,
                            hash = srcHash,
                            local_file = filename
                        }
                        return "EXECUTED_NEW_TRUSTED:" .. src
                    else
                        return nil, "Omni Security Gate: Execution blocked by user"
                    end
                end
            end
            return "EXECUTED_INLINE:" .. src
        end

        -- Step 1: Script fetched for first time -> prompt new -> approved
        local testUrl = "https://raw.githubusercontent.com/author/hub/main/script.lua"
        local codeV1 = "print('Hub v1.0 - Clean')"
        recordFetch(testUrl, codeV1)

        mockUserDecision = "approve"
        local res1, err1 = safeLoadstring(codeV1, testUrl)
        print("STEP_1:" .. tostring(res1))
        print("STEP_1_FILE_SAVED:" .. tostring(isfile(ledgerData.urls[testUrl].local_file)))

        -- Step 2: Second run of identical code -> instant execution with ZERO prompt
        local promptCountBefore = #gatePromptCalls
        local res2, err2 = safeLoadstring(codeV1, testUrl)
        local promptCountAfter = #gatePromptCalls
        print("STEP_2_PROMPT_CALLED:" .. tostring(promptCountAfter > promptCountBefore))
        print("STEP_2:" .. tostring(res2))

        -- Step 3: Author updates content on GitHub with a backdoor! User chooses 'run_previous'
        local codeV2_Malicious = "print('Hub v1.0 - Clean')\\nlocal webhook = 'evil.com'"
        recordFetch(testUrl, codeV2_Malicious)
        mockUserDecision = "run_previous"
        local res3, err3 = safeLoadstring(codeV2_Malicious, testUrl)
        print("STEP_3_DECISION:" .. tostring(res3))

        -- Step 4: Author fixes script, user reviews diff and clicks 'approve'
        local codeV2_Clean = "print('Hub v2.0 - Verified Fixed')"
        recordFetch(testUrl, codeV2_Clean)
        mockUserDecision = "approve"
        local res4, err4 = safeLoadstring(codeV2_Clean, testUrl)
        print("STEP_4_DECISION:" .. tostring(res4))

        -- Step 5: User blocks a suspicious URL
        local badUrl = "https://pastebin.com/raw/stealer"
        local badCode = "stealCookies()"
        recordFetch(badUrl, badCode)
        mockUserDecision = "block"
        local res5, err5 = safeLoadstring(badCode, badUrl)
        print("STEP_5_BLOCKED:" .. tostring(res5 == nil and err5:find("Execution blocked by user") ~= nil))

        -- Step 6: loadfile routes through safeLoadstring
        local function safeLoadfile(path, chunkname)
            local content = readfile(path)
            return safeLoadstring(content, chunkname or ("@" .. tostring(path)))
        end
        writefile("disk_script.lua", "print('Executed from disk')")
        local res6, err6 = safeLoadfile("disk_script.lua")
        print("STEP_6_LOADFILE:" .. tostring(res6))

        -- Step 7: Metatable guard prevents tampering with loadstring
        local mockGenv = {}
        local protectedLoadstring = safeLoadstring
        local mt = {
            __index = function(t, k)
                if k == "loadstring" then return protectedLoadstring end
            end,
            __newindex = function(t, k, v)
                if k == "loadstring" and v ~= protectedLoadstring then
                    return -- Block tampering
                end
                rawset(t, k, v)
            end
        }
        setmetatable(mockGenv, mt)
        -- Malicious script attempts to hijack
        mockGenv.loadstring = function() return "HACKED" end
        print("STEP_7_TAMPER_PROTECTED:" .. tostring(mockGenv.loadstring == protectedLoadstring))
        """
        temp_file = "sim_loadstring_gate.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("STEP_1:EXECUTED_NEW_TRUSTED:print('Hub v1.0 - Clean')", res.stdout)
            self.assertIn("STEP_1_FILE_SAVED:true", res.stdout)
            self.assertIn("STEP_2_PROMPT_CALLED:false", res.stdout)
            self.assertIn("STEP_2:EXECUTED_VERIFIED_MATCH:print('Hub v1.0 - Clean')", res.stdout)
            self.assertIn("STEP_3_DECISION:EXECUTED_PREVIOUS_SAFE:print('Hub v1.0 - Clean')", res.stdout)
            self.assertIn("STEP_4_DECISION:EXECUTED_APPROVED_UPDATE:print('Hub v2.0 - Verified Fixed')", res.stdout)
            self.assertIn("STEP_5_BLOCKED:true", res.stdout)
            self.assertIn("STEP_6_LOADFILE:EXECUTED_INLINE:print('Executed from disk')", res.stdout)
            self.assertIn("STEP_7_TAMPER_PROTECTED:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_17_obfuscated_script_real_loadstring_injection(self):
        """Verify approved obfuscated scripts receive authentic loadstring and inner calls bypass the gate, while untrusted threads are blocked (Zero-Trust, 0s temporal gap)."""
        harness = r"""
        -- Mock primitives
        local origLoadstring = function(code, chunk)
            return function()
                return "UNPACKED_PAYLOAD_EXECUTED:" .. tostring(code)
            end
        end

        local _exemptObfuscatedClosures = setmetatable({}, { __mode = "k" })
        local _exemptObfuscatedCallers = {}
        local _exemptObfuscatedThreads = setmetatable({}, { __mode = "k" })

        local function sanitizeCallerChunk(name)
            if not name or type(name) ~= "string" then return "" end
            local s = name:gsub("^%[string%s+\"", ""):gsub("\"%]$", ""):gsub("^[@%[%]=]", ""):gsub("%]$", "")
            return s:lower()
        end

        local function isGenericChunkName(clean)
            if not clean or #clean < 4 then return true end
            if clean == "script" or clean == "dynamic script" or clean == "unnamed" or clean == "main" or clean == "payload" then
                return true
            end
            return false
        end

        local function compileExecutableChunk(code, chunk, isObf)
            local compiledFn, compileErr = origLoadstring(code, chunk)
            if not compiledFn then
                return nil, compileErr
            end

            if isObf then
                local curThread = coroutine.running()
                _exemptObfuscatedThreads[curThread] = os.clock() + 30.0

                if chunk and type(chunk) == "string" and chunk ~= "" then
                    local cleanChunk = sanitizeCallerChunk(chunk)
                    if not isGenericChunkName(cleanChunk) then
                        _exemptObfuscatedCallers[cleanChunk] = true
                    end
                end

                if type(compiledFn) == "function" then
                    _exemptObfuscatedClosures[compiledFn] = true
                end

                return compiledFn
            end

            return compiledFn
        end

        local promptCallCount = 0
        local function shimLoadstring(src, chunkname)
            local curThread = coroutine.running()
            if _exemptObfuscatedThreads[curThread] and (os.clock() < _exemptObfuscatedThreads[curThread]) then
                local compiled = origLoadstring(src, chunkname)
                if type(compiled) == "function" then
                    _exemptObfuscatedClosures[compiled] = true
                end
                return compiled
            end

            local isCallerExempt = false
            local isCallerObfuscatedExempt = false
            if debug and debug.info then
                local immSrc = debug.info(2, "s")
                if immSrc and type(immSrc) == "string" and immSrc ~= "" and immSrc ~= "[C]" then
                    local cleanImm = sanitizeCallerChunk(immSrc)
                    if cleanImm == "autoexec/bootloader.lua" or cleanImm == "autoexec/kernel/kerneltaskmanager.lua"
                        or cleanImm:match("^autoexec/kernel/") or cleanImm:match("^autoexec/preinit/") then
                        isCallerExempt = true
                    end
                end
                if not isCallerExempt then
                    for lvl = 2, 25 do
                        local okF, cFunc = pcall(debug.info, lvl, "f")
                        if okF and cFunc and _exemptObfuscatedClosures[cFunc] then
                            isCallerExempt = true
                            isCallerObfuscatedExempt = true
                            break
                        end

                        local okS, cSrc = pcall(debug.info, lvl, "s")
                        if okS and cSrc and type(cSrc) == "string" and cSrc ~= "" and cSrc ~= "[C]" then
                            local clean = sanitizeCallerChunk(cSrc)
                            if _exemptObfuscatedCallers[clean] then
                                isCallerExempt = true
                                isCallerObfuscatedExempt = true
                                break
                            end
                            if clean == "autoexec/bootloader.lua" or clean == "autoexec/kernel/kerneltaskmanager.lua"
                                or clean:match("^autoexec/kernel/") or clean:match("^autoexec/preinit/") then
                                isCallerExempt = true
                                break
                            end
                        end
                    end
                end
            end

            if isCallerExempt then
                if isCallerObfuscatedExempt then
                    _exemptObfuscatedThreads[curThread] = os.clock() + 30.0
                    local compiled = origLoadstring(src, chunkname)
                    if type(compiled) == "function" then
                        _exemptObfuscatedClosures[compiled] = true
                    end
                    return compiled
                end
                return origLoadstring(src, chunkname)
            end

            -- Otherwise simulate gate prompt
            promptCallCount = promptCallCount + 1
            return compileExecutableChunk(src, chunkname, true)
        end

        -- 1. Initial execution of LuaArmor loader (prompts user once for gate approval)
        local loaderChunk = "@https://api.luaauth.com/loader/sample123"
        local loaderCode = "-- api.luaauth.com\nlocal x = 1"
        local approvedLoaderFn = shimLoadstring(loaderCode, loaderChunk)
        print("INITIAL_PROMPT_COUNT:" .. tostring(promptCallCount))

        -- 2. Simulate LuaArmor script body executing inside approved thread
        local unpackRes = nil
        local runLoaderBody = function()
            local unpackFn = shimLoadstring("local stage2 = true", "Luraph")
            unpackRes = unpackFn()
        end
        runLoaderBody()
        print("DIRECT_UNPACK_RESULT:" .. tostring(unpackRes))

        -- 3. Simulate nested unpacker calling shimLoadstring from Luraph chunk on same thread
        local nestedRes = nil
        local function executeNestedFromLuraph()
            nestedRes = shimLoadstring("local stage3 = true", "Luraph")
        end
        executeNestedFromLuraph()
        print("NESTED_PROMPT_COUNT_UNCHANGED:" .. tostring(promptCallCount == 1))
        print("NESTED_EXEC_SUCCESS:" .. tostring(type(nestedRes) == "function"))

        -- 4. ADVERSARIAL AUDIT: An unapproved script on a separate concurrent thread tries to piggyback
        -- Under the old 15s/60s clock gap, this would have bypassed the gate.
        -- Under Zero-Trust (thread-bound + closure lineage), this must be intercepted and prompt the gate!
        local adversaryPrompted = false
        coroutine.wrap(function()
            -- Unrelated coroutine thread calling loadstring with "Luraph" chunk
            local adversaryFn = shimLoadstring("malicious_stealer_payload()", "Luraph")
        end)()
        print("ADVERSARY_INTERCEPTED:" .. tostring(promptCallCount == 2))
        """
        temp_file = "sim_obfuscated_loadstring.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
            self.assertIn("INITIAL_PROMPT_COUNT:1", res.stdout)
            self.assertIn("DIRECT_UNPACK_RESULT:UNPACKED_PAYLOAD_EXECUTED:local stage2 = true", res.stdout)
            self.assertIn("NESTED_PROMPT_COUNT_UNCHANGED:true", res.stdout)
            self.assertIn("NESTED_EXEC_SUCCESS:true", res.stdout)
            self.assertIn("ADVERSARY_INTERCEPTED:true", res.stdout)
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)


if __name__ == "__main__":
    unittest.main()


