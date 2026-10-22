# Omni Hybrid Cinema Shutter Motion Blur Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and integrate the Hybrid Cinema Shutter Motion Blur engine (`MotionBlur`) into `OmniEnhancementSuite.lua` with a 0–10 segmented intensity slider in the native Roblox ESC Settings menu, combining center-protected directional/radial `Glass` micro-refraction, 180° shutter specular light-source streaks, and gaze-locked focal `DepthOfFieldEffect`.

**Architecture:** `MotionBlur` is implemented as a self-contained module inside `gameloaded/OmniEnhancementSuite.lua` (Section 5B, directly following `PersonalSpaceBubble`). It binds a single `RenderStepped` callback at `Enum.RenderPriority.Camera.Value + 1` when `config.motion_blur > 0`, driving a pooled 8-vane `_OmniMotionBlurRig` `Glass` aperture parented to `Workspace.CurrentCamera`, 12 pooled additive shutter `Beam`s attached to nearby scene light sources (scanned at 4Hz), and non-destructive `_OmniCinemaDoF` / `_OmniCinemaBlur` post-effects in `Lighting`.

**Tech Stack:** Luau (`luau-compile.exe --binary`), Roblox `RunService:BindToRenderStep`, `Enum.Material.Glass` backbuffer UV refraction, `Beam` additive light streaks, `DepthOfFieldEffect`, Python `unittest` (`tests/test_integrity_guard.py` & `scripts/sync_hashes.py`).

## Global Constraints

- Target file: `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni\gameloaded\OmniEnhancementSuite.lua`
- Deployed Potassium target: `C:\Users\admin\AppData\Local\Potassium\workspace\autoexec\gameloaded\OmniEnhancementSuite.lua`
- Config key: `config.motion_blur = 5` (`0` = disabled, `1..10` = shutter intensity `0.1 .. 1.0`).
- Zero side effects at rest (`Transparency = 1`, `Beam.Enabled = false`, `BlurEffect.Size = 0`) and 100% teardown on `MotionBlur.Disable()` and `FullSuiteCleanup()`.
- Must compile with exit code `0` via `C:\Users\admin\luau\luau-compile.exe --binary` and pass `python scripts/sync_hashes.py` + `python -m unittest discover -s tests -v`.

---

### Task 1: Add MotionBlur Unit & Invariant Tests to `tests/test_integrity_guard.py`

**Files:**
- Modify: `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni\tests\test_integrity_guard.py`

**Interfaces:**
- Consumes: `gameloaded/OmniEnhancementSuite.lua` source text
- Produces: `test_motion_blur_integration_invariants` test method in `TestIntegrityGuard`

- [ ] **Step 1: Add the failing test in `tests/test_integrity_guard.py`**

```python
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
```

- [ ] **Step 2: Run the test to verify it fails before implementation**

Run: `python -m unittest discover -s tests -v` in `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni`
Expected: `FAIL: test_motion_blur_integration_invariants`

---

### Task 2: Implement Hybrid Cinema Shutter Motion Blur in `gameloaded/OmniEnhancementSuite.lua` & Sync Hashes

**Files:**
- Modify: `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni\gameloaded\OmniEnhancementSuite.lua`
- Modify: `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni\manifest.json` (via `scripts/sync_hashes.py`)
- Modify: `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni\Bootloader.lua` (via `scripts/sync_hashes.py`)

**Interfaces:**
- Consumes: `RunService`, `Workspace`, `Lighting`, `config.motion_blur`, `CreateSliderRow`, `FullSuiteCleanup`
- Produces: `MotionBlur.Enable()`, `MotionBlur.Disable()`, `MotionBlur.SetIntensity(step)`, `MotionBlur.GetMetrics()`, exported on `genv.OmniEnhancementSuite.MotionBlur`

- [ ] **Step 1: Add `motion_blur = 5` to `config` defaults in `gameloaded/OmniEnhancementSuite.lua`**

In `Section 3: Configuration & State Management`, add `motion_blur = 5,` to `local config = { ... }`.

- [ ] **Step 2: Implement `Section 5B: Hybrid Cinema Shutter Motion Blur Engine` after `PersonalSpaceBubble.Disable()`**

Implement the 3-stage `MotionBlur` table:
1. Pooled 8-vane `_OmniMotionBlurRig` (`Enum.Material.Glass`, `CastShadow = false`, `CanCollide = false`, `CanQuery = false`, `CanTouch = false`, `Massless = true`) parented to `Workspace.CurrentCamera` with center-protected `38%` aperture radius, rotating to match $\theta_{\text{pan}} = \text{atan2}(\omega_x, -\omega_y)$ and flaring radially on forward sprint velocity $v_{\text{fwd}}$.
2. 4Hz spatial light-emitter scanner (`PointLight`, `SpotLight`, `SurfaceLight`, `Enum.Material.Neon` within `65` studs) feeding `12` pooled additive `Beam`s (`LightInfluence = 0`, `Brightness = 2.8`, `FaceCamera = true`) that project along the inverse camera-induced velocity vector during fast pans.
3. 20Hz center-gaze raycast locking `_OmniCinemaDoF.FocusDistance` onto the looked-at surface + velocity-scaled peripheral DoF and capped whip-pan `_OmniCinemaBlur` (`Size <= 3.2 * scale`).
4. Full teardown in `MotionBlur.Disable()` unbinding `"OmniCinemaMotionBlur"` and destroying `_OmniMotionBlurRig`, `_OmniCinemaDoF`, and `_OmniCinemaBlur`.

- [ ] **Step 3: Wire ESC Menu Slider (`CreateSliderRow`), `SyncWithSystems()`, `FullSuiteCleanup()`, and exports**

In `InjectEnhancementSettings`:
```lua
    CreateSliderRow("MotionBlur", "Motion Blur", config.motion_blur or 0, function(val)
        config.motion_blur = val
        SaveConfig()
        if val > 0 then MotionBlur.Enable() else MotionBlur.Disable() end
    end, -88.5)
```
Wire `MotionBlur.Enable()` / `MotionBlur.Disable()` in `SyncWithSystems()`, `pcall(MotionBlur.Disable)` in `FullSuiteCleanup()`, and `MotionBlur = MotionBlur` in `genv.OmniEnhancementSuite` and the module return table.

- [ ] **Step 4: Compile with `luau-compile.exe --binary`, run `scripts/sync_hashes.py`, and run unit tests**

Run:
1. `C:\Users\admin\luau\luau-compile.exe --binary C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni\gameloaded\OmniEnhancementSuite.lua`
2. `python scripts/sync_hashes.py`
3. `python -m unittest discover -s tests -v`
Expected: All tests PASS (`0` errors).

- [ ] **Step 5: Deploy to Potassium Workspace, Hot-Reload on Live Client, and Commit**

1. Copy `OmniEnhancementSuite.lua`, `Bootloader.lua`, and `manifest.json` to `C:\Users\admin\AppData\Local\Potassium\`.
2. Hot-reload `OmniEnhancementSuite.lua` on active client `Ssrvnt` via `roblox_client.py` and verify `genv.OmniEnhancementSuite.MotionBlur.GetMetrics()`.
3. Commit to git in `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni`.
