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
        """Verify Bootloader.lua embedded manifest matches generated LF SHA-256."""
        bootloader_path = REPO_ROOT / "Bootloader.lua"
        self.assertTrue(bootloader_path.exists(), "Bootloader.lua does not exist")
        content = bootloader_path.read_text(encoding="utf-8")
        
        manifest_path = REPO_ROOT / "manifest.json"
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
            
        stage_map = {}
        for stage in manifest.get("stages", []):
            repo_file = REPO_ROOT / stage["repoPath"]
            self.assertTrue(repo_file.exists(), f"Stage file missing: {stage['repoPath']}")
            generated_hash = compute_lf_sha256(repo_file)
            stage_map[stage["repoPath"]] = generated_hash
            
            # Verify against generated value, not a typed one
            self.assertIn(
                generated_hash,
                content,
                f"Bootloader.lua missing generated sha256 for {stage['name']}: {generated_hash}"
            )

        # Verify all four stage table occurrences in Bootloader.lua match generated hashes
        pattern = re.compile(
            r'\{[^{}]*?repoPath\s*=\s*["\']([^"\']+)["\'][^{}]*?sha256\s*=\s*["\']([^"\']+)["\'][^{}]*?\}',
            re.DOTALL
        )
        matches = pattern.findall(content)
        self.assertEqual(
            len(matches), 4,
            f"Expected exactly 4 stage definitions in Bootloader.lua (3 in BOOTSTRAP_STAGES, 1 in update fallback), found {len(matches)}"
        )
        for repo_path, sha in matches:
            self.assertIn(repo_path, stage_map, f"Unknown stage repoPath in Bootloader.lua: {repo_path}")
            expected_hash = stage_map[repo_path]
            self.assertEqual(
                sha,
                expected_hash,
                f"Bootloader.lua stage table for {repo_path} has stale/mismatched sha256: expected {expected_hash}, got {sha}"
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

    def test_sync_hashes_check_mode_non_mutating(self):
        """Verify scripts/sync_hashes.py --check verifies alignment with zero disk mutation."""
        import sys
        scripts_dir = str(REPO_ROOT / "scripts")
        if scripts_dir not in sys.path:
            sys.path.insert(0, scripts_dir)
        import sync_hashes

        manifest_path = REPO_ROOT / "manifest.json"
        bootloader_path = REPO_ROOT / "Bootloader.lua"
        m_bytes_before = manifest_path.read_bytes()
        b_bytes_before = bootloader_path.read_bytes()

        success = sync_hashes.sync_hashes(check_only=True, repo_root=REPO_ROOT)
        self.assertTrue(success, "scripts/sync_hashes.py --check failed on aligned tree")

        # Guarantee zero disk mutation
        self.assertEqual(manifest_path.read_bytes(), m_bytes_before, "manifest.json was mutated during check!")
        self.assertEqual(bootloader_path.read_bytes(), b_bytes_before, "Bootloader.lua was mutated during check!")

    def test_sync_hashes_drift_detection_and_repair(self):
        """Verify scripts/sync_hashes.py catches drift and repairs it in an isolated temp directory."""
        import shutil
        import tempfile
        import sys
        scripts_dir = str(REPO_ROOT / "scripts")
        if scripts_dir not in sys.path:
            sys.path.insert(0, scripts_dir)
        import sync_hashes

        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = Path(tmp)
            for f in ["manifest.json", "Bootloader.lua"]:
                shutil.copy2(REPO_ROOT / f, tmp_root / f)
            for d in ["kernel", "gameloaded"]:
                shutil.copytree(REPO_ROOT / d, tmp_root / d)

            # 1. Mutate a kernel file in temp copy
            ktm = tmp_root / "kernel" / "KernelTaskManager.lua"
            ktm.write_bytes(ktm.read_bytes() + b"\n-- probe mutation\n")

            # 2. check_only=True must catch the drift
            drift_caught = not sync_hashes.sync_hashes(check_only=True, repo_root=tmp_root)
            self.assertTrue(drift_caught, "sync_hashes --check failed to catch drift")

            # 3. sync_hashes(check_only=False) must repair it in the temp directory
            repair_ok = sync_hashes.sync_hashes(check_only=False, repo_root=tmp_root)
            self.assertTrue(repair_ok, "sync_hashes repair failed in temp directory")

            # 4. check_only=True must now pass on repaired temp directory
            check_after_repair = sync_hashes.sync_hashes(check_only=True, repo_root=tmp_root)
            self.assertTrue(check_after_repair, "sync_hashes --check failed after repair")

if __name__ == "__main__":
    unittest.main()
