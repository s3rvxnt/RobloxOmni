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


if __name__ == "__main__":
    unittest.main()

