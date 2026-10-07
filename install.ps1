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
        $hasAe = (Test-Path (Join-Path $searchRoot 'autoexec')) -or (Test-Path (Join-Path $searchRoot 'autoexe'))
        if ($hasWs -and $hasAe) {
            $full = (Get-Item $searchRoot).FullName
            if (-not $detectedRoots.Contains($full)) { $detectedRoots.Add($full) }
        }

        # Check 1-level deep subdirectories
        Get-ChildItem -Path $searchRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $subWs = Test-Path (Join-Path $_.FullName 'workspace')
            $subAe = (Test-Path (Join-Path $_.FullName 'autoexec')) -or (Test-Path (Join-Path $_.FullName 'autoexe'))
            if ($subWs -and $subAe) {
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

# Fetch or load components once into memory
$components = [ordered]@{
    "Bootloader" = @{
        LocalPath = "Bootloader.lua"
        RemoteUrl = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/Bootloader.lua"
    }
    "KernelTaskManager" = @{
        LocalPath = "kernel\KernelTaskManager.lua"
        RemoteUrl = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/kernel/KernelTaskManager.lua"
    }
    "OmniEnhancementSuite" = @{
        LocalPath = "gameloaded\OmniEnhancementSuite.lua"
        RemoteUrl = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/gameloaded/OmniEnhancementSuite.lua"
    }
}

$contents = @{}
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

foreach ($comp in $components.Keys) {
    $info = $components[$comp]
    $localFile = if ($PSScriptRoot) { Join-Path $PSScriptRoot $info.LocalPath } else { $null }
    if ($localFile -and (Test-Path $localFile)) {
        Write-Host "[+] Using local $($info.LocalPath)..." -ForegroundColor Cyan
        $contents[$comp] = [IO.File]::ReadAllText($localFile, [Text.Encoding]::UTF8)
    } else {
        Write-Host "[+] Fetching latest $($info.LocalPath) from GitHub..." -ForegroundColor Cyan
        $contents[$comp] = (Invoke-RestMethod -Uri "$($info.RemoteUrl)?v=$timestamp")
    }
}

$excludeList = @("Bootloader.lua", "CustomAutoExec.lua", "OmniBootloader.lua", "que_on_teleport.lua")

# Deploy to each detected executor
foreach ($root in $detectedRoots) {
    $execName = Split-Path $root -Leaf
    $autoexecDir = if (Test-Path (Join-Path $root "autoexe")) { Join-Path $root "autoexe" } else { Join-Path $root "autoexec" }
    $workspaceDir = Join-Path $root "workspace"
    $targetPreinit = Join-Path $workspaceDir "autoexec\preinit"
    $targetKernel = Join-Path $workspaceDir "autoexec\kernel"
    $targetGameloaded = Join-Path $workspaceDir "autoexec\gameloaded"

    if (-not (Test-Path $autoexecDir)) {
        New-Item -ItemType Directory -Path $autoexecDir -Force | Out-Null
    }
    if (-not (Test-Path $workspaceDir)) {
        New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
    }
    if (-not (Test-Path $targetPreinit)) {
        New-Item -ItemType Directory -Path $targetPreinit -Force | Out-Null
    }
    if (-not (Test-Path $targetKernel)) {
        New-Item -ItemType Directory -Path $targetKernel -Force | Out-Null
    }
    if (-not (Test-Path $targetGameloaded)) {
        New-Item -ItemType Directory -Path $targetGameloaded -Force | Out-Null
    }

    # Safe migration: backup and move loose third-party scripts from autoexec into workspace/autoexec/preinit/
    # PreInit ensures they execute immediately at Frame 0 just like native autoexec
    $legacyFiles = Get-ChildItem -Path $autoexecDir -File -ErrorAction SilentlyContinue | Where-Object {
        $excludeList -notcontains $_.Name -and ($_.Extension -in @(".lua", ".luau", ".txt"))
    }

    $migratedCount = 0
    $skippedCount = 0
    if ($legacyFiles) {
        $backupTimestamp = (Get-Date -Format 'yyyyMMdd_HHmmss')
        $backupDir = Join-Path $autoexecDir ("_legacy_backup_" + $backupTimestamp)
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        Write-Host "     [i] Backing up $($legacyFiles.Count) legacy script(s) to $(Split-Path -Leaf $backupDir)..." -ForegroundColor Cyan
        foreach ($file in $legacyFiles) {
            Copy-Item -Path $file.FullName -Destination (Join-Path $backupDir $file.Name) -Force
            $dest = Join-Path $targetPreinit $file.Name
            if (Test-Path $dest) {
                Write-Host "     [!] Collision: '$($file.Name)' already exists in preinit/ -- preserved original, kept in backup" -ForegroundColor Yellow
                $skippedCount++
            } else {
                Move-Item -Path $file.FullName -Destination $dest
                $migratedCount++
            }
        }
    }

    # Deploy Bootloader.lua (strictly UTF-8 WITHOUT BOM)
    $bootloaderDest = Join-Path $autoexecDir "Bootloader.lua"
    [IO.File]::WriteAllText($bootloaderDest, $contents["Bootloader"], [Text.UTF8Encoding]::new($false))

    # Deploy KernelTaskManager.lua
    $ktmDest = Join-Path $targetKernel "KernelTaskManager.lua"
    [IO.File]::WriteAllText($ktmDest, $contents["KernelTaskManager"], [Text.UTF8Encoding]::new($false))

    # Deploy OmniEnhancementSuite.lua
    $oesDest = Join-Path $targetGameloaded "OmniEnhancementSuite.lua"
    [IO.File]::WriteAllText($oesDest, $contents["OmniEnhancementSuite"], [Text.UTF8Encoding]::new($false))

    # Write Omni_Installed.marker into workspace for zero-race teleport persistence
    $markerDest = Join-Path $workspaceDir "Omni_Installed.marker"
    [IO.File]::WriteAllText($markerDest, [string]$timestamp, [Text.UTF8Encoding]::new($false))

    # Write Omni_KernelInitialized.marker into workspace
    $kernelMarkerDest = Join-Path $workspaceDir "Omni_KernelInitialized.marker"
    [IO.File]::WriteAllText($kernelMarkerDest, [string]$timestamp, [Text.UTF8Encoding]::new($false))

    # Initialize Omni_Ledger.json with pre-installed components
    $ledgerObj = [PSCustomObject]@{
        version = "1.0.0"
        components = [PSCustomObject]@{
            KernelTaskManager = [PSCustomObject]@{
                installed = $true
                lastSeenVersion = "1.0.0"
                path = "autoexec/kernel/KernelTaskManager.lua"
                updatedAt = [int]$timestamp
            }
            OmniEnhancementSuite = [PSCustomObject]@{
                installed = $true
                lastSeenVersion = "1.0.0"
                path = "autoexec/gameloaded/OmniEnhancementSuite.lua"
                updatedAt = [int]$timestamp
            }
        }
    }
    $ledgerJson = $ledgerObj | ConvertTo-Json -Depth 4
    $ledgerDest = Join-Path $workspaceDir "Omni_Ledger.json"
    [IO.File]::WriteAllText($ledgerDest, $ledgerJson, [Text.UTF8Encoding]::new($false))

    Write-Host "[OK] $execName" -ForegroundColor Green
    if ($migratedCount -gt 0) {
        Write-Host "     -> Safely migrated $migratedCount script(s) to workspace/autoexec/preinit/" -ForegroundColor Yellow
    }
    if ($skippedCount -gt 0) {
        Write-Host "     -> Skipped $skippedCount colliding file(s) to prevent overwriting" -ForegroundColor DarkYellow
    }
    Write-Host "     -> Deployed Bootloader.lua to autoexec/ (UTF-8 without BOM)" -ForegroundColor Gray
    Write-Host "     -> Deployed KernelTaskManager.lua to workspace/autoexec/kernel/" -ForegroundColor Gray
    Write-Host "     -> Deployed OmniEnhancementSuite.lua to workspace/autoexec/gameloaded/" -ForegroundColor Gray
    Write-Host "     -> Created markers and initialized Omni_Ledger.json (v1.0.0)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "All set. Launch Roblox to start." -ForegroundColor Green
Write-Host ""
