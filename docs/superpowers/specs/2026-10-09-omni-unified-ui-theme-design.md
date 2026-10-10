# Omni Unified UI Design System Specification

**Date:** 2026-10-09  
**Status:** Approved  
**Author:** Pair Programming Session  
**Target Components:**
- Reference Standard: `kernel/KernelTaskManager.lua` (`Shift + F8`)
- Target Window 1: `gameloaded/OmniLoadstringManager.lua` (`Shift + F6`)
- Target Window 2: `Bootloader.lua` (Update Gate & Diff Viewer, `Shift + F7`)

---

## 1. Overview & Goal

Currently, the native GUI components of Omni have visual inconsistencies across styling, color palettes, typography, and geometry:
- **Task Manager** (`KernelTaskManager.lua`) features a polished `#0F1117` obsidian background, `#141821` 38px titlebar, `#2D3444` subtle 1px slate stroke, `#40C4FF` electric cyan accents, `GothamBold` titles, and clean keybind pills.
- **Loadstring & Trust Manager** (`OmniLoadstringManager.lua`) features a 48px header with `#16141C` reddish close buttons, mismatched `Enum.Font.Code`, 10px corners, and 1.5px thick strokes.
- **Update Gate & Diff Viewer** (`Bootloader.lua`) features VS Code blue `#007ACC` buttons and active tabs, bright blue 1.5px strokes (`#236EB4`), and 50px header heights.

The goal is to bring all standalone native Omni windows into complete visual harmony with Task Manager's design language, using self-contained, inlined design tokens to preserve Omni's zero-cross-file-runtime-dependency architecture.

---

## 2. Standard Design Tokens

Every standalone Omni window shall adhere to these shared tokens:

### 2.1 Color Palette
```lua
local Theme = {
    Background    = Color3.fromRGB(15, 17, 23),   -- #0F1117: Main window background
    TitleBar      = Color3.fromRGB(20, 24, 33),   -- #141821: Window header bar
    Card          = Color3.fromRGB(24, 30, 42),   -- #181E2A: Content cards & panels
    CardSelected  = Color3.fromRGB(30, 38, 52),   -- #1E2634: Active tabs & focused rows
    Stroke        = Color3.fromRGB(45, 52, 68),   -- #2D3444: Main window outer border (1px)
    CardStroke    = Color3.fromRGB(40, 50, 68),   -- #283244: Card & section border (1px)
    Accent        = Color3.fromRGB(64, 196, 255), -- #40C4FF: Electric cyan primary accent
    AccentHover   = Color3.fromRGB(20, 180, 255), -- #14B4FF: Active hover highlight
    PrimaryBtn    = Color3.fromRGB(30, 80, 140),  -- #1E508C: Affirmative button background
    DangerBtn     = Color3.fromRGB(60, 25, 32),   -- #3C1920: Destructive button background
    CloseBtnBg    = Color3.fromRGB(28, 32, 42),   -- #1C202A: Window close button background
    KeybindBg     = Color3.fromRGB(30, 36, 50),   -- #1E2432: Keybind pill background
    
    TextPrimary   = Color3.fromRGB(240, 244, 255),-- #F0F4FF: High-contrast title & tab text
    TextSecondary = Color3.fromRGB(140, 155, 180),-- #8C9BB4: Subtitles & inactive tab labels
    TextMuted     = Color3.fromRGB(85, 100, 125), -- #55647D: Placeholders & timestamps
    KeybindText   = Color3.fromRGB(160, 175, 200),-- #A0AFCC: Keybind pill text
    CloseBtnText  = Color3.fromRGB(200, 210, 225),-- #C8D2E1: Close button text ("X")
    
    StatusSuccess = Color3.fromRGB(50, 220, 120), -- #32DC78: Green status / additions
    StatusWarning = Color3.fromRGB(255, 175, 50), -- #FFAF32: Yellow advisory / warnings
    StatusDanger  = Color3.fromRGB(255, 75, 75),  -- #FF4B4B: Red errors / removals
}
```

### 2.2 Typography & Radii
* **Typography**:
  * Title & Brand: `Enum.Font.GothamBold`, 13px
  * Tab Headers & Badges: `Enum.Font.GothamMedium`, 11px
  * Keybind Pill: `Enum.Font.GothamBold`, 10px
  * Body / Descriptions: `Enum.Font.Gotham`, 11-12px
  * Code / Diffs / Hashes: `Enum.Font.RobotoMono`, 11px
* **Radii & Thickness**:
  * Window Outer: `8px` (`UDim.new(0, 8)`)
  * Outer Stroke: `1px` (`Theme.Stroke`)
  * Content Cards: `6px` (`UDim.new(0, 6)`)
  * Buttons & Badges: `4px` - `5px` (`UDim.new(0, 4)`)

### 2.3 TitleBar Standard (Height: 38px)
* Header frame size: `UDim2.new(1, 0, 0, 38)`
* Background: `Theme.TitleBar`
* `TitleLabel`:
  * Position: `UDim2.new(0, 12, 0, 0)`, Size: auto / `UDim2.new(0, 260, 1, 0)`
  * Font: `Enum.Font.GothamBold`, TextSize: `13px`, TextColor3: `Theme.Accent`
  * Format: `⚡ OMNI [COMPONENT_NAME]`
* `KeybindBadge`:
  * Position: right of title label, Size: `UDim2.new(0, 74, 0, 20)`, centered vertically `(0.5, -10)`
  * Background: `Theme.KeybindBg`, TextColor3: `Theme.KeybindText`, Font: `GothamBold`, TextSize: `10px`
  * Format: `Shift + F#`
* `CloseBtn`:
  * Position: `UDim2.new(1, -34, 0.5, -14)`, Size: `UDim2.new(0, 28, 0, 28)`
  * Background: `Theme.CloseBtnBg`, TextColor3: `Theme.CloseBtnText`, Font: `GothamBold`, TextSize: `13px`
  * Corner: `4px`
* `TitleBarCover`:
  * Seamless 8px bar at `UDim2.new(0, 0, 1, -8)` of height 8px with `Theme.TitleBar` to eliminate top-corner rounding artifacts.

---

## 3. Component Overhauls

### 3.1 Omni Loadstring & Trust Manager (`OmniLoadstringManager.lua`)
1. **Window Frame**:
   * Change `Window.BackgroundColor3` from `(16, 20, 28)` to `Theme.Background` (`15, 17, 23`).
   * Change `WindowCorner.CornerRadius` from `10px` to `8px`.
   * Change `WindowStroke.Thickness` from `1.5px` to `1px`, and color to `Theme.Stroke` (`45, 52, 68`).
2. **TitleBar**:
   * Change `Header` height from `48px` to `38px`.
   * Replace icon + separate title with standard `TitleLabel`: `⚡ OMNI LOADSTRING & TRUST MANAGER` in `GothamBold` size `13px`, cyan `#40C4FF`.
   * Replace `KeybindPill` with standard Task Manager keybind badge (`GothamBold` 10px, background `#1E2432`, text `#A0AFCC`, text `"Shift + F6"`).
   * Replace custom image close button with standardized `CloseBtn` (text `"X"` in `GothamBold` 13px, background `#1C202A`, corner 4px).
   * Reposition `RefreshBtn` cleanly next to the close button or in the toolbar.
3. **Tab System (`NavFrame`)**:
   * Adopt Task Manager's active indicator: background `Theme.CardSelected` (`30, 38, 52`), text `Theme.TextPrimary` (`240, 244, 255`), and 2px bottom cyan indicator bar.
   * Inactive tabs: transparent background, `Theme.TextSecondary` (`140, 155, 180`) text.
4. **Lists & Code Cards**:
   * Script rows and URL cards: background `Theme.Card` (`24, 30, 42`), stroke `Theme.CardStroke` (`40, 50, 68`), corner `6px`.
   * URLs, hashes, and code snippets: font updated from `Enum.Font.Code` to `Enum.Font.RobotoMono`.
   * Search bar: background `#141821`, stroke `#283244`, font `GothamMedium`.

### 3.2 Omni Update & Security Gate / Diff Viewer (`Bootloader.lua`)
1. **Modal Frame**:
   * Change `ModalCorner.CornerRadius` from `10px` to `8px`.
   * Change `ModalStroke.Thickness` from `1.5px` to `1px`, and color from bright blue `(35, 110, 180)` to `Theme.Stroke` (`45, 52, 68`).
   * Change `ModalFrame.BackgroundColor3` to `Theme.Background` (`15, 17, 23`).
2. **TitleBar**:
   * Header height normalized to `42px` (accommodating title + 10px subtitle).
   * Background set to `Theme.TitleBar` (`20, 24, 33`).
   * Add `KeybindBadge`: `Shift + F7` in standard `GothamBold` 10px badge.
   * Close button normalized to standard 28x28px `[X]`.
3. **Buttons & Action Controls**:
   * Replace all VS Code blues (`#007ACC` / `Color3.fromRGB(0, 122, 204)`) on "Apply Update", "Review", and active tabs with `Theme.PrimaryBtn` (`30, 80, 140`) / `Theme.Accent` border.
   * Dismiss button updated to `Theme.Card` with clean hover highlight.
4. **Floating Pill Toast**:
   * Background: `Theme.TitleBar` (`20, 24, 33`).
   * Stroke: `Theme.Stroke` (`45, 52, 68`) with 1px thickness (replacing bright blue stroke).
   * "Review" button: electric cyan accent theme.
5. **Diff Viewer Well**:
   * Code background: `#0C0E13` (`12, 14, 19`).
   * Font: `Enum.Font.RobotoMono`.
   * Color-coded additions (`#32DC78`) and removals (`#FF4B4B`).

---

## 4. Architectural Invariants
* **Zero Runtime Cross-File Coupling**: No `_G` or `getgenv()` UI dependencies introduced. All tokens are localized to the respective UI files.
* **Integrity Guard**: Running `scripts/sync_hashes.py` is no longer needed since `scripts/` was removed, but all 5 files must compile with real Luau (`luau-compile --binary`).
* **Frame-Budget Preserved**: Zero impact on frame budget or execution performance (pure UI styling and instance property assignments).

---

## 5. Verification Plan
1. **Luau Syntax & Binary Compilation**: Compile `Bootloader.lua` and `OmniLoadstringManager.lua` with `luau-compile.exe --binary`.
2. **Potassium Deployment**: Copy updated files to `C:\Users\admin\AppData\Local\Potassium\autoexec\` and `workspace/autoexec/`.
3. **In-Game Live Verification**:
   * Trigger `Shift + F8` (Task Manager): observe reference gold-standard theme.
   * Trigger `Shift + F6` (Loadstring Manager): confirm window frame, 38px titlebar, keybind badge, tab indicator, and card styling match Task Manager.
   * Trigger `Shift + F7` (Update Gate / Diff Viewer): confirm modal frame, titlebar, keybind badge, and cyan button styling match Task Manager.
