# setup_novr.ps1
# Enables SteamVR's null (no-headset) driver and launches SteamVR.
# Edit $steamPath below if Steam is installed somewhere other than the default.

$steamPath = "C:\Program Files (x86)\Steam"

$nullDriverFolder = Join-Path $steamPath "steamapps\common\SteamVR\drivers\null"
$nullDriverFile = Join-Path $nullDriverFolder "resources\settings\default.vrsettings"
$userConfigFile = Join-Path $steamPath "config\steamvr.vrsettings"

Write-Host "=== SteamVR No-Headset Setup ===" -ForegroundColor Cyan

if (-not (Test-Path (Join-Path $steamPath "steamapps\common\SteamVR"))) {
    Write-Host "ERROR: Could not find SteamVR under $steamPath" -ForegroundColor Red
    Write-Host "Check that `$steamPath at the top of this script matches your Steam install location."
    Read-Host "Press Enter to exit"
    exit 1
}

# --- Step 0: Install the VR-Emulator-Driver (headset/controller emulation) if it's missing ---
# default.vrsettings already exists as part of the STOCK null driver, so it can't be used to
# detect the emulator driver specifically. Instead we write our own marker file the first time
# install succeeds, and check for that marker on future runs.
$emulatorMarker = Join-Path $nullDriverFolder ".vr_emulator_installed"
if (-not (Test-Path $emulatorMarker)) {
    Write-Host "`nVR-Emulator-Driver not found. Downloading latest release from GitHub..." -ForegroundColor Yellow
    try {
        $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/ar-zadeh/VR-Emulator-Driver/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
        $asset = $releaseInfo.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        if (-not $asset) {
            throw "No .zip asset found in the latest release."
        }
        $zipPath = Join-Path $env:TEMP "vr-emulator-driver.zip"
        Write-Host "  Downloading $($asset.name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath

        if (-not (Test-Path $nullDriverFolder)) {
            New-Item -ItemType Directory -Path $nullDriverFolder -Force | Out-Null
        }
        Write-Host "  Extracting into $nullDriverFolder..."
        Expand-Archive -Path $zipPath -DestinationPath $nullDriverFolder -Force
        Remove-Item $zipPath

        # Make sure the C:\actions folder the driver reads from exists
        if (-not (Test-Path "C:\actions")) {
            New-Item -ItemType Directory -Path "C:\actions" -Force | Out-Null
            Write-Host "  Created C:\actions for controller/headset input files."
        }
        New-Item -ItemType File -Path $emulatorMarker -Force | Out-Null
        Write-Host "  Driver installed." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Auto-install failed: $_" -ForegroundColor Red
        Write-Host "Install it manually from https://github.com/ar-zadeh/VR-Emulator-Driver/releases and re-run this script."
        Read-Host "Press Enter to exit"
        exit 1
    }
} else {
    Write-Host "`nVR-Emulator-Driver already installed, skipping download." -ForegroundColor Green
}

# --- Step 1: Back up both files before touching them ---
foreach ($f in @($nullDriverFile, $userConfigFile)) {
    if (Test-Path $f) {
        $backup = "$f.bak"
        if (-not (Test-Path $backup)) {
            Copy-Item $f $backup
            Write-Host "Backed up $f -> $backup"
        }
    }
}

# --- Step 2: Enable the null driver itself ---
Write-Host "`nEditing null driver settings..."
$nullJson = Get-Content $nullDriverFile -Raw | ConvertFrom-Json
$nullJson.driver_null.enable = $true
$nullJson | ConvertTo-Json -Depth 10 | Set-Content $nullDriverFile
Write-Host "  driver_null.enable = true" -ForegroundColor Green

# --- Step 3: Set up (or create) the user config so SteamVR boots without a real HMD ---
Write-Host "`nEditing user config ($userConfigFile)..."
if (Test-Path $userConfigFile) {
    $userJson = Get-Content $userConfigFile -Raw | ConvertFrom-Json
} else {
    $userJson = [PSCustomObject]@{}
}

# Ensure the "steamvr" section exists and has the right keys
if (-not $userJson.PSObject.Properties["steamvr"]) {
    $userJson | Add-Member -MemberType NoteProperty -Name "steamvr" -Value ([PSCustomObject]@{})
}
$userJson.steamvr | Add-Member -MemberType NoteProperty -Name "requireHmd" -Value $false -Force
$userJson.steamvr | Add-Member -MemberType NoteProperty -Name "forcedDriver" -Value "null" -Force
$userJson.steamvr | Add-Member -MemberType NoteProperty -Name "activateMultipleDrivers" -Value $true -Force

# Ensure the "driver_null" section exists too
if (-not $userJson.PSObject.Properties["driver_null"]) {
    $userJson | Add-Member -MemberType NoteProperty -Name "driver_null" -Value ([PSCustomObject]@{})
}
$userJson.driver_null | Add-Member -MemberType NoteProperty -Name "enable" -Value $true -Force

# Prevent the fake headset from going to "sleep" from inactivity
if (-not $userJson.PSObject.Properties["power"]) {
    $userJson | Add-Member -MemberType NoteProperty -Name "power" -Value ([PSCustomObject]@{})
}
$userJson.power | Add-Member -MemberType NoteProperty -Name "overrideWindowsPowerScheme" -Value $true -Force

$userJson | ConvertTo-Json -Depth 10 | Set-Content $userConfigFile
Write-Host "  requireHmd = false, forcedDriver = null, activateMultipleDrivers = true, driver_null.enable = true" -ForegroundColor Green

# --- Step 4: Make sure no stale SteamVR processes are still running ---
Write-Host "`nClosing any running SteamVR processes..."
foreach ($proc in @("vrserver", "vrmonitor", "vrdashboard", "vrcompositor")) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Stopping $proc (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force
    }
}
Start-Sleep -Seconds 2

# --- Step 5: Launch SteamVR ---
Write-Host "`nLaunching SteamVR..." -ForegroundColor Cyan
Start-Process "steam://rungameid/250820"

Write-Host "`nWaiting 15 seconds for SteamVR to start, then checking the log..."
Start-Sleep -Seconds 15

$logFile = Join-Path $steamPath "steamapps\common\SteamVR\logs\vrserver.txt"
if (Test-Path $logFile) {
    Write-Host "`n=== Last 20 lines of vrserver.txt ===" -ForegroundColor Cyan
    Get-Content $logFile -Tail 20
} else {
    Write-Host "Could not find vrserver.txt yet -- SteamVR may still be starting." -ForegroundColor Yellow
}

Write-Host "`nDone. If a SteamVR window (even a blank/black one) is now open, the null driver loaded successfully."
Read-Host "`nPress Enter to close this window"