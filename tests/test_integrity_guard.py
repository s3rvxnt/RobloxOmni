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


if __name__ == "__main__":
    unittest.main()
