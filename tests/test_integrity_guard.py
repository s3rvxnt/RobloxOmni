import hashlib
import json
import os
import re
import subprocess
import unittest


class TestIntegrityGuard(unittest.TestCase):
    def setUp(self):
        self.repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        self.manifest_path = os.path.join(self.repo_root, "manifest.json")
        self.bootloader_path = os.path.join(self.repo_root, "Bootloader.lua")

    def _compute_lf_sha256(self, file_path):
        with open(file_path, "rb") as f:
            raw_bytes = f.read()
        normalized_bytes = raw_bytes.replace(b"\r\n", b"\n")
        return hashlib.sha256(normalized_bytes).hexdigest().lower()

    def test_manifest_hashes_match_disk(self):
        self.assertTrue(os.path.exists(self.manifest_path), "manifest.json does not exist")
        with open(self.manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)

        stages = manifest.get("stages", [])
        self.assertGreater(len(stages), 0, "manifest.json contains no stages")

        for stage in stages:
            name = stage.get("name")
            repo_path = stage.get("repoPath")
            expected_sha = stage.get("sha256", "").lower()

            self.assertTrue(name, "Stage missing 'name'")
            self.assertTrue(repo_path, f"Stage {name} missing 'repoPath'")
            self.assertEqual(len(expected_sha), 64, f"Stage {name} has invalid sha256 length")

            full_path = os.path.join(self.repo_root, repo_path)
            self.assertTrue(os.path.exists(full_path), f"Stage file {repo_path} does not exist on disk")

            actual_sha = self._compute_lf_sha256(full_path)
            self.assertEqual(
                actual_sha,
                expected_sha,
                f"SHA-256 mismatch for {name} ({repo_path})!\n"
                f"  manifest.json: {expected_sha}\n"
                f"  disk (LF):     {actual_sha}\n"
                f"Run 'python scripts/sync_hashes.py' before committing.",
            )

    def test_bootloader_bootstrap_stages_match_manifest(self):
        self.assertTrue(os.path.exists(self.bootloader_path), "Bootloader.lua does not exist")
        with open(self.manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        with open(self.bootloader_path, "r", encoding="utf-8") as f:
            bootloader_content = f.read()

        for stage in manifest.get("stages", []):
            name = stage.get("name")
            manifest_sha = stage.get("sha256", "").lower()
            pattern = r'name\s*=\s*"' + re.escape(name) + r'",\s*\n\s*sha256\s*=\s*"([0-9a-fA-F]{64})"'
            matches = re.findall(pattern, bootloader_content)
            self.assertGreater(
                len(matches),
                0,
                f"Could not find stage '{name}' in Bootloader.lua BOOTSTRAP_STAGES",
            )
            for bl_sha in matches:
                self.assertEqual(
                    bl_sha.lower(),
                    manifest_sha,
                    f"Bootloader.lua hardcoded sha256 for {name} does not match manifest.json!\n"
                    f"  Bootloader.lua: {bl_sha.lower()}\n"
                    f"  manifest.json:  {manifest_sha}\n"
                    f"Run 'python scripts/sync_hashes.py' to synchronize.",
                )

    def test_luau_syntax_compilation(self):
        luau_compile = r"C:\Users\admin\luau\luau-compile.exe"
        if not os.path.exists(luau_compile):
            self.skipTest("luau-compile.exe not installed at expected path")

        with open(self.manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)

        files_to_check = ["Bootloader.lua"] + [
            stage["repoPath"] for stage in manifest.get("stages", []) if stage.get("repoPath")
        ]

        for rel_path in files_to_check:
            full_path = os.path.join(self.repo_root, rel_path)
            proc = subprocess.run(
                [luau_compile, "--binary", full_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(
                proc.returncode,
                0,
                f"Luau compilation failed for {rel_path}:\n{proc.stderr}",
            )

    def test_regression_invariants(self):
        with open(self.bootloader_path, "r", encoding="utf-8") as f:
            bootloader_src = f.read()

        # 1. Bootloader declaration order & Theme.StatusDanger
        self.assertIn("StatusDanger", bootloader_src)
        self.assertLess(
            bootloader_src.index("local function lookupManifestStage("),
            bootloader_src.index("autoexec/Bootloader_Updated.lua"),
            "lookupManifestStage must be declared before Bootloader_Updated.lua handoff",
        )
        self.assertLess(
            bootloader_src.index("local function loadLedger()"),
            bootloader_src.index("autoexec/Bootloader_Updated.lua"),
            "loadLedger must be declared before Bootloader_Updated.lua handoff",
        )
        self.assertLess(
            bootloader_src.index("local function getLatestCommitSha()"),
            bootloader_src.index("initUpdateGate = function("),
            "getLatestCommitSha must be hoisted above initUpdateGate",
        )
        self.assertNotIn(
            "_trustedUrlByThread",
            bootloader_src,
            "Bootloader must not permanently taint threads with _trustedUrlByThread",
        )

        # 2. KernelTaskManager virgin environment & scheduler invariants
        ktm_path = os.path.join(self.repo_root, "kernel", "KernelTaskManager.lua")
        with open(ktm_path, "r", encoding="utf-8") as f:
            ktm_src = f.read()

        self.assertNotIn("getgenv().game = rawGame", ktm_src)
        self.assertNotIn("getgenv().game = origGame", ktm_src)
        self.assertIn('local GuiService = game:GetService("GuiService")', ktm_src)
        self.assertNotIn("local cachedGameRows = {}\n\nlocal function renderGameTaskRow", ktm_src)
        self.assertIn("getgenv()._OmniLoopIdCounter = loopIdCounter", ktm_src)

        # 3. OmniEnhancementSuite lifecycle & Janitor thread cancellation
        oes_path = os.path.join(self.repo_root, "gameloaded", "OmniEnhancementSuite.lua")
        with open(oes_path, "r", encoding="utf-8") as f:
            oes_src = f.read()

        self.assertLess(
            oes_src.index("local function FullSuiteCleanup()"),
            oes_src.index("\nSetupWatcher()"),
            "FullSuiteCleanup must be defined and exported before SetupWatcher()",
        )
        self.assertIn('elseif typeof(x) == "thread" then', oes_src)
        self.assertGreaterEqual(oes_src.count("Own(task.spawn(function()"), 2)

    def test_motion_blur_integration_invariants(self):
        oes_path = os.path.join(self.repo_root, "gameloaded", "OmniEnhancementSuite.lua")
        with open(oes_path, "r", encoding="utf-8") as f:
            oes_src = f.read()

        self.assertIn("motion_blur = 5", oes_src)
        self.assertIn("local MotionBlur = {}", oes_src)
        self.assertIn("function MotionBlur.Enable()", oes_src)
        self.assertIn("function MotionBlur.Disable()", oes_src)
        self.assertIn("function MotionBlur.GetMetrics()", oes_src)
        self.assertIn('"_OmniMotionBlurRig"', oes_src)
        self.assertIn('"_OmniCinemaDoF"', oes_src)
        self.assertIn('"_OmniCinemaBlur"', oes_src)
        self.assertIn('CreateSliderRow("MotionBlur", "Motion Blur"', oes_src)
        self.assertIn("MotionBlur = MotionBlur,", oes_src)


    def test_kernel_packet_logger_invariants(self):
        kpl_path = os.path.join(self.repo_root, "kernel", "KernelPacketLogger.lua")
        self.assertTrue(os.path.exists(kpl_path), "kernel/KernelPacketLogger.lua does not exist")
        with open(kpl_path, "r", encoding="utf-8") as f:
            kpl_src = f.read()

        self.assertIn("--!stage Kernel", kpl_src)
        self.assertIn("add_receive_hook", kpl_src)
        self.assertIn("add_send_hook", kpl_src)
        self.assertIn("GetOmniPacketMetrics", kpl_src)
        self.assertIn("ToggleOmniPacketLogger", kpl_src)
        self.assertIn("_KernelPacketLoggerCleanUp", kpl_src)
        self.assertIn("SUBPACKET_0X83_NAMES", kpl_src)


if __name__ == "__main__":
    unittest.main()
