# Omni Hybrid Cinema Shutter Motion Blur — Design Specification

**Date:** 2026-10-22  
**Target Module:** `C:\Users\admin\.gemini\antigravity\scratch\RobloxOmni\gameloaded\OmniEnhancementSuite.lua`  
**Deployed Target:** `C:\Users\admin\AppData\Local\Potassium\workspace\autoexec\gameloaded\OmniEnhancementSuite.lua`

---

## 1. Problem Statement & Objective

Roblox's rendering engine locks out custom HLSL post-processing shaders and provides only an isotropic Gaussian `BlurEffect`. Standard Roblox "motion blur" scripts bind `BlurEffect.Size` to camera angle deltas, which blurs the entire frame uniformly in all directions—destroying center-crosshair sharpness, smearing UI/prompts, and completely ignoring forward linear velocity and specular light-source shutter trails.

The objective is to implement a **Hybrid Cinema Shutter Motion Blur** engine (`MotionBlur`) directly inside `OmniEnhancementSuite.lua`, controlled by a native 10-step segmented slider (`0 = Off`, `1..10 = Shutter Intensity`, default `5`) in the Roblox ESC Settings menu.

---

## 2. Architecture: 3-Stage Optical Cinema Shutter Pipeline

The `MotionBlur` module runs a single unified `BindToRenderStep("OmniCinemaMotionBlur", Enum.RenderPriority.Camera.Value + 1, ...)` callback when enabled (`config.motion_blur > 0`) and unbinds completely when set to `0` or during `FullSuiteCleanup()`.

### 2.1 Camera Kinematics Extractor
Every frame (`dt` clamped to `[1/240, 1/15]`), the engine computes:
1. **Camera-Space Angular Velocity $\vec{\omega}$ (`rad/s`)**:
   - Computes relative rotation $\Delta R = R_{\text{prev}}^{-1} \cdot R_{\text{curr}}$.
   - Extracts pitch rate $\omega_x$ (up/down whip), yaw rate $\omega_y$ (left/right whip), and roll rate $\omega_z$.
   - Computes 2D screen-space pan direction angle $\theta_{\text{pan}} = \text{atan2}(\omega_x, -\omega_y)$ and angular speed $|\vec{\omega}| = \sqrt{\omega_x^2 + \omega_y^2}$.
2. **Camera-Space Linear Velocity $\vec{v}_{\text{cam}}$ (`studs/s`)**:
   - Transforms world velocity $\vec{v}_{\text{world}} = (\vec{p}_{\text{curr}} - \vec{p}_{\text{prev}}) / dt$ into camera space via `camCF:VectorToObjectSpace(vWorld)`.
   - Forward sprint speed $v_{\text{fwd}} = \max(0, -v_{\text{cam}, z})$ and lateral/vertical translation $v_{\text{lat}} = \sqrt{v_{\text{cam}, x}^2 + v_{\text{cam}, y}^2}$.
3. **Temporal Exponential Smoothing**:
   - Smooths pan vectors and velocity magnitudes with asymmetric attack/release ($\alpha_{\text{attack}} = 1 - e^{-28 \cdot dt}$, $\alpha_{\text{release}} = 1 - e^{-16 \cdot dt}$) so fast whip-pans engage immediately and settle without frame-to-frame jitter.

### 2.2 Stage 1: Center-Protected Directional & Radial `Glass` Micro-Refraction Aperture
- **Why it works**: `Enum.Material.Glass` (with `Transparency` in `[0.984, 0.999]`) is the only material in Roblox's C++ renderer that samples the resolved `SceneColor` backbuffer at UV offsets proportional to the glass surface normal relative to the view ray.
- **Pooled Geometry**:
  - Creates a non-collidable, non-queryable `Folder` named `_OmniMotionBlurRig` parented to `Workspace.CurrentCamera`.
  - Contains `8` ultra-thin `Glass` wedge/prism vanes arranged in a radial ring around the outer periphery of the camera frustum (`~0.65` studs in front of the camera).
  - **Center-Protected Crosshair Cone**: The central `38%` screen radius remains unobstructed during forward linear motion so the player's crosshair, doors, and center gaze target remain `100%` razor-sharp.
  - **Dynamic Articulation**:
    - During **forward sprint / falling** ($v_{\text{fwd}} > 14\text{ studs/s}$), the 8 peripheral glass vanes flare inward radially around the frustum periphery, creating radial edge refraction along the walls rushing past.
    - During **angular camera whip-pans** ($|\vec{\omega}| > 1.2\text{ rad/s}$), the ring rotates to align with $\theta_{\text{pan}}$ and tilts the glass incidence angle (`0°` $\rightarrow$ `36°`) along the pan axis so refraction streaks strictly along the direction of camera rotation.
    - When below velocity thresholds, all vanes set `Transparency = 1` (zero rendering cost and zero visual artifacting when stationary).

### 2.3 Stage 2: Specular Light-Source Shutter Streaks (180° Cinema Shutter Rule)
- **Why it works**: In a real 180° camera shutter ($\Delta t_{\text{shutter}} = 0.5 \cdot dt \cdot \text{intensity}$), bright point lights (wall sconces, candles, chandeliers, neon parts) leave directional light trails across the frame during fast camera pans.
- **4Hz Spatial Light Scanner**:
  - A background accumulator (`0.25s` interval) scans nearby `PointLight`, `SpotLight`, `SurfaceLight` (with `Enabled == true` and `Brightness >= 0.8`), and `Enum.Material.Neon` parts within `65` studs of the camera, caching up to `12` brightest visible emitters.
- **Pooled Additive Shutter Beams**:
  - Pre-allocates `12` pooled `Beam` instances (`LightInfluence = 0`, `Brightness = 2.8`, `FaceCamera = true`, smooth falloff `Transparency` `NumberSequence`) between pairs of `Attachment`s (`A0` at the light source world position, `A1` offset along the inverse camera-induced apparent motion vector $-\vec{v}_{\text{apparent}} \cdot \Delta t_{\text{shutter}}$).
  - Active only when apparent screen-space velocity exceeds `18 studs/s` and camera line-of-sight is within the frustum (`dot > 0.15`); collapses to `Enabled = false` immediately at rest.

### 2.4 Stage 3: Gaze-Locked Focal `DepthOfFieldEffect` & Capped Whip-Pan Micro-Smoothing
- **Focal Lock**:
  - Every `0.05s` (20Hz), casts a single ray along `Camera.CFrame.LookVector` (up to `120` studs, ignoring `_OmniMotionBlurRig` and `LocalPlayer.Character`) to smoothly lock `DepthOfFieldEffect.FocusDistance` onto the exact object at the center of the player's screen.
- **Velocity-Driven Peripheral Falloff**:
  - Scales `FarIntensity` (`0 -> 0.45 * scale`) and `NearIntensity` (`0 -> 0.25 * scale`) with combined angular/linear velocity while keeping `InFocusRadius` wide (`25–45` studs) around the gaze target.
- **Capped Whip-Pan Micro-Blur**:
  - Uses a tightly capped `BlurEffect` (`Size <= 3.2 * scale`, only active during extreme `> 3.5 rad/s` camera whips) solely to blend sub-pixel refraction edges without ever washing out the image.
- **Game-Native PostEffect Preservation**:
  - Creates dedicated `_OmniCinemaDoF` and `_OmniCinemaBlur` instances inside `Lighting` (or `Workspace.CurrentCamera`) without modifying or destroying any game-created `BlurEffect` or `DepthOfFieldEffect`.

---

## 3. Configuration, UI & Lifecycle Integration

1. **Configuration (`omni_enhancement_config.json`)**:
   - Add `motion_blur = 5` to `config` defaults in `OmniEnhancementSuite.lua` (`0` = disabled, `1..10` = intensity scale `0.1 .. 1.0`).
2. **Native ESC Settings Menu (`InjectEnhancementSettings`)**:
   - Add `CreateSliderRow("MotionBlur", "Motion Blur", config.motion_blur or 0, ...)` at `LayoutOrder = -88.5` (directly beneath `Personal Space Bubble`).
3. **Global & Module API**:
   - Expose `MotionBlur.Enable()`, `MotionBlur.Disable()`, `MotionBlur.SetIntensity(step)`, and `MotionBlur.GetMetrics()` on `genv.OmniEnhancementSuite.MotionBlur`.
4. **Clean Teardown & Isolation**:
   - Register `MotionBlur.Disable()` inside `FullSuiteCleanup()`.
   - Exempt `_OmniMotionBlurRig` from `StreamerMode` GUI scanning and character/camera raycasts.

---

## 4. Verification Criteria
- Compiles with exit code `0` via `C:\Users\admin\luau\luau-compile.exe --binary`.
- `scripts/sync_hashes.py` updates `manifest.json` and `Bootloader.lua` SHA-256 hashes cleanly.
- `python -m unittest discover -s tests -v` in `RobloxOmni` passes 100%.
- Live in-game verification confirms `< 0.35ms` frame time, zero residual instances when set to `0`, and responsive directional shutter blur on camera pans and sprints.
