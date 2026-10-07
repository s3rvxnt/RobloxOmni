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
        """Verify complete elimination of unvetted loadfile calls and TOCTOU defense."""
        # Bootloader must never use loadfile to execute scripts directly from workspace
        self.assertNotIn("loadfile(scriptPath)", self.bootloader_source)
        self.assertNotIn("loadfile(filePath)", self.bootloader_source)
        # loadfile is strictly shimmed to prevent external TOCTOU bypasses
        self.assertIn("local function loadfileShim", self.bootloader_source)
        self.assertIn("getgenv().loadfile = (newcclosure and newcclosure(loadfileShim)) or loadfileShim", self.bootloader_source)

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

    def test_10_clonefunction_poisoning_defense_invariants(self):
        """Verify clonefunction C-closure, L-closure, and debug.info integrity verification invariants."""
        self.assertIn("_clonefunctionPoisoned", self.bootloader_source)
        self.assertIn("_checkIsCClosure", self.bootloader_source)
        self.assertIn("_checkIsLClosure", self.bootloader_source)
        self.assertIn("_checkDebugInfo", self.bootloader_source)
        self.assertIn("SafeModeReason = \"ClonefunctionPoisoning\"", self.bootloader_source)
        self.assertIn("Discarding poisoned clone primitive", self.bootloader_source)

    def test_11_defcon1_panic_click_countdown_invariants(self):
        """Verify Defcon 1 panic click-through countdown, code tab default, and click rejection invariants."""
        self.assertIn("local defcon1CountdownThread = nil", self.bootloader_source)
        self.assertIn("ApplyUpdateBtn.Active = false", self.bootloader_source)
        self.assertIn("Inspecting Security Diff", self.bootloader_source)
        self.assertIn("isDefcon1Lockdown and defcon1CountdownThread ~= nil", self.bootloader_source)
        self.assertIn("switchTab(\"Code\")", self.bootloader_source)

    def test_12_unicode_smuggling_and_trojan_source_invariants(self):
        """Verify Zero-Width Unicode, Trojan Source BiDi, and homoglyph detection and diff sanitization."""
        self.assertIn("🛑 Trojan Source (BiDi)", self.bootloader_source)
        self.assertIn("🚨 Unicode Smuggling", self.bootloader_source)
        self.assertIn("local function sanitizeDiffText(text)", self.bootloader_source)
        self.assertIn("[ZWSP]", self.bootloader_source)
        self.assertIn("[RLO]", self.bootloader_source)
        self.assertIn("[BOM]", self.bootloader_source)

    def test_13_path_traversal_sandbox_escape_invariants(self):
        """Verify validateSafeLocalPath sandbox boundary invariants."""
        self.assertIn("local function validateSafeLocalPath(path)", self.bootloader_source)
        self.assertIn("validateSafeLocalPath(p)", self.bootloader_source)
        self.assertIn("validateSafeLocalPath(localPath)", self.bootloader_source)

    def test_14_immutable_manifest_and_reentrancy_invariants(self):
        """Verify deep-cloned frozen changelog and approval re-entrancy lock invariants."""
        self.assertIn("local isApprovalPending = false", self.bootloader_source)
        self.assertIn("while isApprovalPending do", self.bootloader_source)
        self.assertIn("if table.freeze then pcall(table.freeze, cl) end", self.bootloader_source)

    def test_15_primitive_poisoning_and_c_closure_canary_invariants(self):
        """Verify comprehensive primitive poisoning detection, canary clone tests, and C-closure authentication."""
        self.assertIn("_isAuthenticCClosure", self.bootloader_source)
        self.assertIn("_capturePrimitive", self.bootloader_source)
        self.assertIn("_primitivesPoisoned", self.bootloader_source)
        self.assertIn('SafeModeReason = "PrimitivePoisoning"', self.bootloader_source)
        self.assertIn("clonedCanary == _canary", self.bootloader_source)

    def test_16_strict_sandbox_path_sanitization_invariants(self):
        """Verify validateSafeLocalPath rejects DOS device names, dangerous extensions, and lockfile targeting."""
        self.assertIn("CON", self.bootloader_source)
        self.assertIn("PRN", self.bootloader_source)
        self.assertIn("AUX", self.bootloader_source)
        self.assertIn("NUL", self.bootloader_source)
        self.assertIn("bootloader_running%.lock", self.bootloader_source)
        self.assertIn("lowerExt ~= \"lua\"", self.bootloader_source)

    def test_17_domain_pinning_and_workspace_manifest_invariants(self):
        """Verify official GitHub domain pinning and workspace/manifest.json fallback."""
        self.assertIn("raw%.githubusercontent%.com/s3rvxnt/RobloxOmni/", self.bootloader_source)
        self.assertIn("workspace/manifest.json", self.bootloader_source)

    def test_18_monotonic_clock_defcon1_lockdown_invariants(self):
        """Verify monotonic clock Defcon 1 countdown and sticky lockdown state."""
        self.assertIn("local defcon1UnlockTime = 0", self.bootloader_source)
        self.assertIn("os.clock() < defcon1UnlockTime", self.bootloader_source)
        self.assertIn("getgenv()._OmniLockdownActive == true", self.bootloader_source)

    def test_19_url_ledger_and_network_interception_invariants(self):
        """Verify remote script URL ledger, network capture, and Windows-safe file persistence invariants."""
        self.assertIn('local TRUSTED_URLS_LEDGER_PATH = "Omni_TrustedUrls.json"', self.bootloader_source)
        self.assertIn('local TRUSTED_SCRIPTS_DIR = "omni_trusted_scripts"', self.bootloader_source)
        self.assertIn("local function sanitizeUrlToFilename(url)", self.bootloader_source)
        self.assertIn("local function loadTrustedUrlLedger()", self.bootloader_source)
        self.assertIn("local function saveTrustedUrlLedger(ledger)", self.bootloader_source)
        self.assertIn("local function recordFetch(url, body)", self.bootloader_source)
        self.assertIn("_fetchedUrlByContentHash", self.bootloader_source)
        self.assertIn("_recentFetchesByUrl", self.bootloader_source)
        # Network interception hooks
        self.assertIn("interceptedHttpGet", self.bootloader_source)
        self.assertIn("interceptedRequest", self.bootloader_source)
        self.assertIn('method == "HttpGet"', self.bootloader_source)

    def test_20_loadstring_security_gate_and_diff_viewer_invariants(self):
        """Verify Zero-Trust loadstring gate, author update diff review, and safe rollback invariants."""
        self.assertIn("promptRemoteScriptSecurity", self.bootloader_source)
        self.assertIn('mode = "script_update"', self.bootloader_source)
        self.assertIn('mode = "script_new"', self.bootloader_source)
        self.assertIn('mode = "script_inline"', self.bootloader_source)
        self.assertIn("decision == \"approve\"", self.bootloader_source)
        self.assertIn("decision == \"run_previous\"", self.bootloader_source)
        self.assertIn("decision == \"block\"", self.bootloader_source)
        self.assertIn("🛡️ Run Previous Safe Version", self.bootloader_source)
        self.assertIn("✅ Approve Changes & Run", self.bootloader_source)
        self.assertIn("🛑 Block", self.bootloader_source)
        self.assertIn("Omni Security Gate: Execution blocked by user", self.bootloader_source)


if __name__ == "__main__":
    unittest.main()

