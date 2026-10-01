# Omni 1-Click Installer
# Run: irm https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "  Omni" -ForegroundColor Cyan
Write-Host "  Zero lag. Adaptive budgeting. Silent auto-updates." -ForegroundColor DarkGray
Write-Host ""

# Target paths for Potassium
$potassiumDir = Join-Path $env:LOCALAPPDATA "Potassium"
if (-not (Test-Path $potassiumDir)) {
    Write-Host "[-] Potassium directory not found at $potassiumDir" -ForegroundColor Red
    return
}

$autoexecDir = Join-Path $potassiumDir "autoexec"
$workspaceDir = Join-Path $potassiumDir "workspace"
$targetAutoexec = Join-Path $workspaceDir "autoexec"

if (-not (Test-Path $autoexecDir)) { 
    New-Item -ItemType Directory -Path $autoexecDir -Force | Out-Null 
}
if (-not (Test-Path $targetAutoexec)) { 
    New-Item -ItemType Directory -Path $targetAutoexec -Force | Out-Null 
}

# Migrate existing scripts from root autoexec to workspace/autoexec
# Exclude Bootloader.lua and system scripts like que_on_teleport
$excludeList = @("Bootloader.lua", "CustomAutoExec.lua", "que_on_teleport.lua", "OmniBootloader.lua")
$existingScripts = Get-ChildItem -Path $autoexecDir -File | Where-Object {
    $excludeList -notcontains $_.Name -and ($_.Extension -in @(".lua", ".luau", ".txt"))
}

if ($existingScripts.Count -gt 0) {
    Write-Host "[+] Migrating $($existingScripts.Count) existing script(s) to workspace/autoexec/..." -ForegroundColor Yellow
    foreach ($file in $existingScripts) {
        $destPath = Join-Path $targetAutoexec $file.Name
        Move-Item -Path $file.FullName -Destination $destPath -Force
        Write-Host "    -> Migrated: $($file.Name)" -ForegroundColor DarkGray
    }
}

# Download latest Bootloader.lua directly into root autoexec
Write-Host "[+] Installing latest Bootloader.lua..." -ForegroundColor Cyan
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$bootloaderUrl = "https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/Bootloader.lua?v=$timestamp"
$bootloaderDest = Join-Path $autoexecDir "Bootloader.lua"

Invoke-RestMethod -Uri $bootloaderUrl -OutFile $bootloaderDest

Write-Host ""
Write-Host "[OK] Omni installed successfully." -ForegroundColor Green
Write-Host "     Launch Roblox to start." -ForegroundColor Gray
Write-Host ""
