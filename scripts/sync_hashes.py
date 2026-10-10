#!/usr/bin/env python3
"""
scripts/sync_hashes.py

Recomputes each stage's LF SHA-256 and synchronizes it across:
- manifest.json (stages[].sha256)
- Bootloader.lua (BOOTSTRAP_STAGES table and applyVerifiedUpdateSequence fallback table)

Supports:
  --check: Exits non-zero if any hashes are out of sync, without modifying any files.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

DEFAULT_REPO_ROOT = Path(__file__).resolve().parent.parent

def compute_lf_sha256(file_path: Path) -> str:
    """Compute the SHA-256 hash of a file after normalizing CRLF to LF."""
    content = file_path.read_bytes().replace(b"\r\n", b"\n")
    return hashlib.sha256(content).hexdigest()

def update_stage_in_lua(content: str, repo_path: str, new_hash: str) -> tuple[str, int]:
    """Replace sha256 for a given stage repoPath inside table blocks."""
    # Order 1: repoPath followed by sha256 in same table
    pattern1 = re.compile(
        r'(repoPath\s*=\s*["\']' + re.escape(repo_path) + r'["\'][^}]*?sha256\s*=\s*["\'])[^"\']*(["\'])'
    )
    # Order 2: sha256 followed by repoPath in same table
    pattern2 = re.compile(
        r'(sha256\s*=\s*["\'])[^"\']*(["\'][^}]*?repoPath\s*=\s*["\']' + re.escape(repo_path) + r'["\'])'
    )
    new_content, count1 = pattern1.subn(r'\g<1>' + new_hash + r'\g<2>', content)
    new_content, count2 = pattern2.subn(r'\g<1>' + new_hash + r'\g<2>', new_content)
    return new_content, count1 + count2

def sync_hashes(check_only: bool = False, repo_root: Path | None = None) -> bool:
    root = repo_root or DEFAULT_REPO_ROOT
    manifest_path = root / "manifest.json"
    bootloader_path = root / "Bootloader.lua"

    if not manifest_path.exists():
        print(f"Error: manifest.json not found at {manifest_path}", file=sys.stderr)
        return False
    if not bootloader_path.exists():
        print(f"Error: Bootloader.lua not found at {bootloader_path}", file=sys.stderr)
        return False

    raw_manifest_bytes = manifest_path.read_bytes()
    manifest_newline = "\r\n" if b"\r\n" in raw_manifest_bytes else "\n"
    manifest = json.loads(raw_manifest_bytes.decode("utf-8"))

    raw_bootloader_bytes = bootloader_path.read_bytes()
    bootloader_newline = "\r\n" if b"\r\n" in raw_bootloader_bytes else "\n"
    bootloader_text = raw_bootloader_bytes.decode("utf-8")

    stages = manifest.get("stages", [])
    if not stages:
        print("Error: No stages found in manifest.json", file=sys.stderr)
        return False

    total_lua_replacements = 0
    updated_stages = 0
    drift_detected = False

    for stage in stages:
        repo_rel = stage.get("repoPath")
        if not repo_rel:
            continue
        stage_file = root / repo_rel
        if not stage_file.exists():
            print(f"Error: Stage file {stage_file} not found", file=sys.stderr)
            return False

        new_sha256 = compute_lf_sha256(stage_file)
        old_sha256 = stage.get("sha256")

        if old_sha256 != new_sha256:
            drift_detected = True
            if check_only:
                print(f"[DRIFT] manifest.json {stage.get('name', repo_rel)}: {old_sha256} != {new_sha256}", file=sys.stderr)
            else:
                print(f"Updating {stage.get('name', repo_rel)}: {old_sha256} -> {new_sha256}")
            updated_stages += 1
        else:
            if not check_only:
                print(f"Unchanged {stage.get('name', repo_rel)}: {new_sha256}")

        stage["sha256"] = new_sha256

        # Check / update in Bootloader.lua
        updated_bootloader, count = update_stage_in_lua(bootloader_text, repo_rel, new_sha256)
        if updated_bootloader != bootloader_text:
            drift_detected = True
            if check_only:
                print(f"[DRIFT] Bootloader.lua has stale hash for stage: {repo_rel}", file=sys.stderr)
        bootloader_text = updated_bootloader
        total_lua_replacements += count

    if check_only:
        if drift_detected:
            print("Check failed: working tree hashes are out of sync. Run 'python scripts/sync_hashes.py' to synchronize.", file=sys.stderr)
            return False
        print(f"Check passed: all {len(stages)} stages match in manifest.json and Bootloader.lua.")
        return True

    # Save manifest.json
    dumped_manifest = json.dumps(manifest, indent=2) + "\n"
    if manifest_newline == "\r\n":
        dumped_manifest = dumped_manifest.replace("\r\n", "\n").replace("\n", "\r\n")
    manifest_path.write_bytes(dumped_manifest.encode("utf-8"))

    # Save Bootloader.lua
    if bootloader_newline == "\r\n":
        bootloader_text = bootloader_text.replace("\r\n", "\n").replace("\n", "\r\n")
    else:
        bootloader_text = bootloader_text.replace("\r\n", "\n")
    bootloader_path.write_bytes(bootloader_text.encode("utf-8"))

    print(f"Sync complete: {len(stages)} stages processed, {total_lua_replacements} occurrences in Bootloader.lua updated.")
    return True

def main():
    parser = argparse.ArgumentParser(description="Synchronize stage hashes across manifest.json and Bootloader.lua")
    parser.add_argument("--check", action="store_true", help="Check for drift without modifying any files. Exits non-zero if out of sync.")
    args = parser.parse_args()

    success = sync_hashes(check_only=args.check)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
