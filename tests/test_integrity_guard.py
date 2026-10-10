import json
import hashlib
import re
from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent

def compute_lf_sha256(file_path: Path) -> str:
    content = file_path.read_bytes().replace(b"\r\n", b"\n")
    return hashlib.sha256(content).hexdigest()

class TestIntegrityGuard(unittest.TestCase):

    def test_manifest_stages_integrity(self):
        """Verify all stages in manifest.json match their on-disk LF SHA-256."""
        manifest_path = REPO_ROOT / "manifest.json"
        self.assertTrue(manifest_path.exists(), "manifest.json does not exist")
        
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        
        stages = manifest.get("stages", [])
        self.assertGreaterEqual(len(stages), 2, "Manifest should have at least Kernel and GameLoaded stages")
        
        for stage in stages:
            repo_path = REPO_ROOT / stage["repoPath"]
            self.assertTrue(repo_path.exists(), f"Stage file missing: {stage['repoPath']}")
            expected_hash = stage["sha256"]
            actual_hash = compute_lf_sha256(repo_path)
            self.assertEqual(
                actual_hash,
                expected_hash,
                f"Hash mismatch for {stage['name']} ({stage['repoPath']}): expected {expected_hash}, got {actual_hash}"
            )

    def test_bootloader_embedded_manifest_sync(self):
        """Verify Bootloader.lua embedded manifest matches manifest.json."""
        bootloader_path = REPO_ROOT / "Bootloader.lua"
        self.assertTrue(bootloader_path.exists(), "Bootloader.lua does not exist")
        content = bootloader_path.read_text(encoding="utf-8")
        
        manifest_path = REPO_ROOT / "manifest.json"
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
            
        for stage in manifest.get("stages", []):
            expected_hash = stage["sha256"]
            self.assertIn(
                expected_hash,
                content,
                f"Bootloader.lua missing sha256 for {stage['name']}: {expected_hash}"
            )

    def test_kernel_game_script_isolation(self):
        """Verify KernelTaskManager.lua isolates game scripts from pause, yield, and clamp."""
        kernel_path = REPO_ROOT / "kernel" / "KernelTaskManager.lua"
        self.assertTrue(kernel_path.exists(), "KernelTaskManager.lua does not exist")
        content = kernel_path.read_text(encoding="utf-8")
        
        # 1. hookedTaskWait isolation
        self.assertIn("if not loop.isExecutor and not loop.allowGameOverride then", content)
        
        # 2. Fast-path check
        self.assertIn("getgenv()._OmniEnableWaitHooks == false or getgenv()._OmniDisableWaitHooks == true", content)
        
        # 3. PauseAllLoops preserves game loops
        self.assertIn("if loop.isExecutor then", content)
        self.assertIn("loop.paused = loopsPausedAll", content)

    def test_bootloader_wait_hooks_off_switch(self):
        """Verify Bootloader.lua supports runtime and file-based wait hook off-switch."""
        bootloader_path = REPO_ROOT / "Bootloader.lua"
        content = bootloader_path.read_text(encoding="utf-8")
        
        self.assertIn("Omni_Settings.json", content)
        self.assertIn("disable_wait_hooks", content)
        self.assertIn("_OmniDisableWaitHooks", content)

if __name__ == "__main__":
    unittest.main()
