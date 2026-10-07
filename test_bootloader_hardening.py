#!/usr/bin/env python3
"""
Comprehensive Hardening Verification Test Suite for Bootloader.lua.
Tests all 4 steps of the 'Order of Business':
1. Defcon 1 Kill Switch driven by manifest.json
2. Anti-Hooking Primitive Cloning
3. TOCTOU Defense & Memory-Only Execution with SHA-256 Integrity
4. Zero-Trust Consent (Synchronous Yield) & 6.0ms Frame Budget Integrity
"""

import json
import os
import re
import subprocess
import sys
import unittest
import hashlib

BOOTLOADER_PATH = os.path.join(os.path.dirname(__file__), "Bootloader.lua")
MANIFEST_PATH = os.path.join(os.path.dirname(__file__), "manifest.json")
LUAU_PATH = r"C:\Users\admin\luau\luau.exe"
LUAU_COMPILE_PATH = r"C:\Users\admin\luau\luau-compile.exe"


class TestBootloaderHardening(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(BOOTLOADER_PATH, "r", encoding="utf-8") as f:
            cls.bootloader_source = f.read()

        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            cls.manifest_data = json.load(f)

    def test_01_luau_bytecode_compilation(self):
        """Verify Bootloader.lua compiles cleanly to Luau bytecode with zero syntax errors."""
        res = subprocess.run([LUAU_COMPILE_PATH, BOOTLOADER_PATH], capture_output=True)
        self.assertEqual(res.returncode, 0, f"Luau compilation failed: {res.stderr.decode('utf-8', errors='ignore')}")

    def test_02_step2_anti_hooking_function_cloning(self):
        """Verify primitives are cloned via clonefunction before any logic runs."""
        # Check clonefunction capture
        self.assertIn("local _rawClone = (type(clonefunction) == \"function\" and clonefunction) or nil", self.bootloader_source)
        self.assertIn("local function _safeClone(fn)", self.bootloader_source)

        # Check all required primitives are cloned
        required_primitives = [
            "_writefile", "_readfile", "_isfile", "_isfolder",
            "_makefolder", "_delfile", "_listfiles", "_loadstring",
            "_request", "_clonedHttpGet"
        ]
        for prim in required_primitives:
            self.assertIn(prim, self.bootloader_source, f"Primitive {prim} must be cloned!")

        # Verify file-scoped shadowing locals bind to cloned closures
        self.assertIn("local writefile  = _writefile", self.bootloader_source)
        self.assertIn("local readfile   = _readfile", self.bootloader_source)
        self.assertIn("local isfile     = _isfile", self.bootloader_source)
        self.assertIn("local isfolder   = _isfolder", self.bootloader_source)
        self.assertIn("local makefolder = _makefolder", self.bootloader_source)
        self.assertIn("local delfile    = _delfile", self.bootloader_source)
        self.assertIn("local listfiles  = _listfiles", self.bootloader_source)
        self.assertIn("local loadstring = _loadstring", self.bootloader_source)
        self.assertIn("local request    = _request", self.bootloader_source)

    def test_03_step3_toctou_defense_no_loadfile(self):
        """Verify complete elimination of loadfile from workspace."""
        # loadfile must not appear anywhere as a call or reference
        loadfile_matches = re.findall(r"\bloadfile\b", self.bootloader_source)
        self.assertEqual(len(loadfile_matches), 0, f"loadfile found in Bootloader.lua: {loadfile_matches}")

    def test_04_step3_sha256_cryptographic_engine_vectors(self):
        """Verify pure Luau SHA-256 implementation against standard test vectors."""
        test_harness = f"""
        local bit32 = bit32
        {self.bootloader_source[self.bootloader_source.find("local _K_SHA256 ="):self.bootloader_source.find("local bootStart = os.clock()")]}

        local tests = {{
            "",
            "hello world",
            "The quick brown fox jumps over the lazy dog",
            "Omni Defcon 1 Security Lockdown",
            string.rep("a", 1000)
        }}

        for _, t in ipairs(tests) do
            print(computeSha256(t))
        end
        """
        temp_file = "temp_sha256_test.luau"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(test_harness)

        try:
            res = subprocess.run([LUAU_PATH, temp_file], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Luau run failed: {res.stderr}")
            luau_hashes = res.stdout.strip().splitlines()

            expected_tests = [
                b"",
                b"hello world",
                b"The quick brown fox jumps over the lazy dog",
                b"Omni Defcon 1 Security Lockdown",
                b"a" * 1000
            ]
            expected_hashes = [hashlib.sha256(t).hexdigest() for t in expected_tests]

            self.assertEqual(len(luau_hashes), len(expected_hashes))
            for computed, expected in zip(luau_hashes, expected_hashes):
                self.assertEqual(computed.strip().lower(), expected.lower())
        finally:
            if os.path.exists(temp_file):
                os.remove(temp_file)

    def test_05_step3_memory_only_execution_and_hash_checks(self):
        """Verify memory-only execution via _clonedLoadstring and verifyContentHash checks."""
        # executeScript must verify hash against expectedSha
        self.assertIn("verifyContentHash(content, expectedSha)", self.bootloader_source)
        self.assertIn("_clonedLoadstring(content, \"@\" .. scriptName)", self.bootloader_source)

        # applyVerifiedUpdateSequence must verify SHA-256 before disk caching and memory execution
        self.assertIn("verifyContentHash(remoteContent, expectedSha)", self.bootloader_source)
        self.assertIn("_clonedLoadstring(remoteContent, \"@OmniEnhancementSuite\")", self.bootloader_source)
        self.assertIn("_clonedLoadstring(lastCode, \"@KernelTaskManager\")", self.bootloader_source)

    def test_06_step1_defcon1_kill_switch_manifest_structure(self):
        """Verify manifest.json contains lockdown fields and SHA-256 for stages."""
        self.assertIn("lockdown", self.manifest_data)
        self.assertIn("lockdown_message", self.manifest_data)
        self.assertIsInstance(self.manifest_data["lockdown"], bool)
        self.assertIsInstance(self.manifest_data["lockdown_message"], str)

        self.assertIn("stages", self.manifest_data)
        for stage in self.manifest_data["stages"]:
            self.assertIn("sha256", stage, f"Stage {stage.get('name')} missing sha256 hash in manifest!")
            self.assertEqual(len(stage["sha256"]), 64, f"Stage {stage.get('name')} sha256 hash is invalid length!")

    def test_07_step1_defcon1_kill_switch_airgap_and_halt(self):
        """Verify Defcon 1 halts core rings and air-gaps via LocalPlayer:Kick."""
        self.assertIn("checkDefcon1Lockdown", self.bootloader_source)
        self.assertIn("parsed.lockdown == true", self.bootloader_source)
        self.assertIn("lp:Kick(msg)", self.bootloader_source)
        self.assertIn("Players.LocalPlayer:Kick(msg)", self.bootloader_source)
        self.assertIn("getgenv()._OmniLockdownActive = true", self.bootloader_source)

        # Verify immediate halt before Ring 0
        self.assertIn("local isLockdownActive = checkDefcon1Lockdown()", self.bootloader_source)
        self.assertIn("if isLockdownActive then", self.bootloader_source)
        self.assertIn("print(\"[Bootloader]: Bootloader halted under Defcon 1 Security Lockdown.\")", self.bootloader_source)
        self.assertIn("return", self.bootloader_source)

    def test_08_step4_zero_trust_consent_synchronous_yield(self):
        """Verify pure zero-trust synchronous yield and elimination of mutable Engine tables."""
        # yieldForUserApproval must yield until userConsentCallback is invoked
        self.assertIn("local function yieldForUserApproval(lockdownFlag, lockdownMsg)", self.bootloader_source)
        self.assertIn("while approved == nil do", self.bootloader_source)
        self.assertIn("task.wait(0.1)", self.bootloader_source)

        # applyVerifiedUpdateSequence must accept zero arguments
        self.assertIn("local function applyVerifiedUpdateSequence()", self.bootloader_source)

        # Global functions must be parameterless wrappers
        self.assertIn("getgenv().OpenOmniUpdateGate = function() openUpdateModal(false) end", self.bootloader_source)
        self.assertIn("getgenv().TestOmniUpdateGate = function() openUpdateModal(false) end", self.bootloader_source)

        # No exposed mutable engine tables
        self.assertNotIn("getgenv().OmniEngine = ", self.bootloader_source)
        self.assertNotIn("getgenv().UpdateEngine = ", self.bootloader_source)

    def test_09_frame_budget_governor_intact(self):
        """Verify 6.0ms adaptive frame budget loop is completely unimpeded."""
        self.assertIn("local TARGET_BUDGET_MS = 6.0", self.bootloader_source)
        self.assertIn("(os.clock() - frameStart) * 1000 >= TARGET_BUDGET_MS", self.bootloader_source)
        self.assertIn("RunService.Heartbeat:Wait()", self.bootloader_source)


if __name__ == "__main__":
    unittest.main()
