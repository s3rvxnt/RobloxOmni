# Omni Universal 1-Click Installer
# Run: irm https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.ps1 | iex

param([string]$Path)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "  Omni" -ForegroundColor Cyan
Write-Host "  Zero lag. Adaptive budgeting. Zero-trust security gate." -ForegroundColor DarkGray
Write-Host ""

$detectedRoots = [System.Collections.Generic.List[string]]::new()

# If user provided an explicit path
if ($Path -and (Test-Path $Path)) {
    $detectedRoots.Add((Get-Item $Path).FullName)
} else {
    # Scan standard executor locations across the system
    # Universal Invariant: Every Roblox executor places 'autoexec' and 'workspace' as sibling folders in its root.
    $searchRoots = @(
        (Get-Location).Path,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Documents')
    )

    foreach ($searchRoot in $searchRoots) {
        if (-not (Test-Path $searchRoot)) { continue }

        # Check the search root itself
        $hasWs = Test-Path (Join-Path $searchRoot 'workspace')
        $hasAe = Test-Path (Join-Path $searchRoot 'autoexec')
        if ($hasWs -and $hasAe) {
            $full = (Get-Item $searchRoot).FullName
            if (-not $detectedRoots.Contains($full)) { $detectedRoots.Add($full) }
        }

        # Check 1-level deep subdirectories
        Get-ChildItem -Path $searchRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $subWs = Test-Path (Join-Path $_.FullName 'workspace')
            $subAe = Test-Path (Join-Path $_.FullName 'autoexec')
            if ($subWs -and ($subAe -or (Get-ChildItem -Path $_.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue))) {
                if (-not $detectedRoots.Contains($_.FullName)) {
                    $detectedRoots.Add($_.FullName)
                }
            }
        }
    }
}

# If still not found, prompt interactively
if ($detectedRoots.Count -eq 0) {
    Write-Host "[?] No executor directory automatically detected." -ForegroundColor Yellow
    $userPath = Read-Host "    Enter your executor folder path (e.g. C:\Executors\Solara)"
    if ($userPath -and (Test-Path $userPath)) {
        $detectedRoots.Add((Get-Item $userPath).FullName)
    } else {
        Write-Host "[-] Invalid directory path. Installation aborted." -ForegroundColor Red
        return
    }
}

Write-Host "[+] Discovered $($detectedRoots.Count) executor installation(s):" -ForegroundColor Cyan
foreach ($root in $detectedRoots) {
    $execName = Split-Path $root -Leaf
    Write-Host "    -> $execName ($root)" -ForegroundColor DarkGray
}
Write-Host ""

# Fetch latest Bootloader.lua once into memory
$localBootloader = Join-Path $PSScriptRoot "Bootloader.lua"
if ($PSScriptRoot -and (Test-Path $localBootloader)) {
    Write-Host "[+] Using local Bootloader.lua..." -ForegroundColor Cyan
    $bootloaderContent = Get-Content -Path $localBootloader -Raw
} else {
    Write-Host "[+] Fetching latest Bootloader.lua from GitHub..." -ForegroundColor Cyan
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $bootloaderUrl = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/Bootloader.lua?v=$timestamp"
    $bootloaderContent = (Invoke-RestMethod -Uri $bootloaderUrl)
}

$excludeList = @("Bootloader.lua", "CustomAutoExec.lua", "OmniBootloader.lua", "que_on_teleport.lua")

# Deploy to each detected executor
foreach ($root in $detectedRoots) {
    $execName = Split-Path $root -Leaf
    $autoexecDir = Join-Path $root "autoexec"
    $workspaceDir = Join-Path $root "workspace"
    $targetWorkspaceAutoexec = Join-Path $workspaceDir "autoexec"

    if (-not (Test-Path $autoexecDir)) {
        New-Item -ItemType Directory -Path $autoexecDir -Force | Out-Null
    }
    if (-not (Test-Path $workspaceDir)) {
        New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
    }
    if (-not (Test-Path $targetWorkspaceAutoexec)) {
        New-Item -ItemType Directory -Path $targetWorkspaceAutoexec -Force | Out-Null
    }

    # Universal migration: move loose scripts from real autoexec into workspace/autoexec
    $legacyFiles = Get-ChildItem -Path $autoexecDir -File -ErrorAction SilentlyContinue | Where-Object {
        $excludeList -notcontains $_.Name -and ($_.Extension -in @(".lua", ".luau", ".txt"))
    }

    $migratedCount = 0
    if ($legacyFiles) {
        foreach ($file in $legacyFiles) {
            $dest = Join-Path $targetWorkspaceAutoexec $file.Name
            Move-Item -Path $file.FullName -Destination $dest -Force
            $migratedCount++
        }
    }

    # Deploy Bootloader.lua
    $bootloaderDest = Join-Path $autoexecDir "Bootloader.lua"
    Set-Content -Path $bootloaderDest -Value $bootloaderContent -NoNewline

    Write-Host "[OK] $execName" -ForegroundColor Green
    if ($migratedCount -gt 0) {
        Write-Host "     -> Migrated $migratedCount script(s) to workspace/autoexec/" -ForegroundColor Yellow
    }
    Write-Host "     -> Deployed Bootloader.lua to autoexec/" -ForegroundColor Gray
}

Write-Host ""
Write-Host "All set. Launch Roblox to start." -ForegroundColor Green
Write-Host ""
