# setup_novr.ps1
# Installs/enables the VR-Emulator-Driver (headset + 2 controllers, no real hardware),
# points OpenXR at SteamVR, and launches SteamVR. Undo everything with cleanup_novr.ps1.
# Edit $steamPath below if Steam is installed somewhere other than the default.

# -NoPause: don't wait for Enter at the end (used by run_flatscreen.bat). Errors still pause.
param([switch]$NoPause)

# Switching the OpenXR runtime writes to HKLM, which needs admin. Re-launch elevated if needed,
# and wait for that elevated copy to finish so callers know when SteamVR is up.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NoPause) { $argList += " -NoPause" }
    try {
        $p = Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait -PassThru
        exit $p.ExitCode
    } catch {
        Write-Host "Admin permission was declined, so SteamVR setup couldn't run." -ForegroundColor Red
        exit 1
    }
}

$steamPath = "C:\Program Files (x86)\Steam"

$steamVrFolder    = Join-Path $steamPath "steamapps\common\SteamVR"
$nullDriverFolder = Join-Path $steamVrFolder "drivers\null"
$nullDriverDll    = Join-Path $nullDriverFolder "bin\win64\driver_null.dll"
$nullDriverFile   = Join-Path $nullDriverFolder "resources\settings\default.vrsettings"
$userConfigFile   = Join-Path $steamPath "config\steamvr.vrsettings"
$emulatorMarker   = Join-Path $nullDriverFolder ".vr_emulator_installed"
$steamXrJson      = Join-Path $steamVrFolder "steamxr_win64.json"
$openXrKey        = "HKLM:\SOFTWARE\Khronos\OpenXR\1"
$savedRuntimeFile = "C:\actions\.previous_openxr_runtime.txt"

Write-Host "=== SteamVR No-Headset Setup ===" -ForegroundColor Cyan

if (-not (Test-Path $steamVrFolder)) {
    Write-Host "ERROR: Could not find SteamVR under $steamPath" -ForegroundColor Red
    Write-Host "Check that `$steamPath at the top of this script matches your Steam install location."
    Read-Host "Press Enter to exit"
    exit 1
}
New-Item -ItemType Directory -Path "C:\actions" -Force | Out-Null

# --- Step 1: Close SteamVR FIRST. It rewrites steamvr.vrsettings on exit and would undo our edits. ---
Write-Host "`nClosing any running SteamVR processes..."
foreach ($proc in @("vrmonitor", "vrdashboard", "vrcompositor", "vrwebhelper", "vrstartup", "vrserver")) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Stopping $proc (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force
    }
}
Start-Sleep -Seconds 2

# Reset the emulator's input files. The driver adds whatever is in them the moment it
# starts, so leftovers (e.g. an old comma-separated file) would bake in a permanent tilt.
foreach ($dev in "headset", "controller1", "controller2") {
    foreach ($kind in "position", "rotation") {
        Set-Content -Path "C:\actions\${dev}_${kind}_changes.txt" -Value "0 0 0"
    }
}
Remove-Item "C:\actions\.flatscreen_state.json" -Force -ErrorAction SilentlyContinue

# --- Step 2: Install the emulator if the DLL in place isn't the one we installed ---
# The marker stores the installed DLL's hash. SteamVR updates restore the stock
# null driver, which changes the hash, so we notice and reinstall.
function Get-DllHash { if (Test-Path $nullDriverDll) { (Get-FileHash $nullDriverDll -Algorithm SHA256).Hash } else { "" } }
$installedHash = if (Test-Path $emulatorMarker) { (Get-Content $emulatorMarker -Raw).Trim() } else { "" }

if (-not $installedHash -or $installedHash -ne (Get-DllHash)) {
    Write-Host "`nVR-Emulator-Driver missing or replaced by a SteamVR update. Installing..." -ForegroundColor Yellow
    try {
        $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/ar-zadeh/VR-Emulator-Driver/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
        $asset = $releaseInfo.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        if (-not $asset) { throw "No .zip asset found in the latest release." }

        $zipPath = Join-Path $env:TEMP "vr-emulator-driver.zip"
        $extractDir = Join-Path $env:TEMP "vr-emulator-driver"
        Write-Host "  Downloading $($asset.name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        # Find the driver root inside the zip, however deep it's nested
        # (the folder holding driver.vrdrivermanifest, or the one above bin\win64).
        $root = Get-ChildItem $extractDir -Recurse -Filter "driver.vrdrivermanifest" | Select-Object -First 1 | ForEach-Object { $_.DirectoryName }
        if (-not $root) {
            $dll = Get-ChildItem $extractDir -Recurse -Filter "driver_null.dll" | Where-Object { $_.FullName -like "*win64*" } | Select-Object -First 1
            if (-not $dll) { throw "Couldn't find driver_null.dll in the release zip. Contents:`n$((Get-ChildItem $extractDir -Recurse -File).FullName -join "`n")" }
            $root = $dll.Directory.Parent.Parent.FullName
        }
        Write-Host "  Copying driver files from $root into $nullDriverFolder..."
        New-Item -ItemType Directory -Path $nullDriverFolder -Force | Out-Null
        Copy-Item -Path (Join-Path $root "*") -Destination $nullDriverFolder -Recurse -Force
        Remove-Item $zipPath, $extractDir -Recurse -Force

        Set-Content -Path $emulatorMarker -Value (Get-DllHash)
        Write-Host "  Driver installed." -ForegroundColor Green
        if (-not (Test-Path (Join-Path $nullDriverFolder "input\mycontroller_profile.json"))) {
            Write-Host "  Warning: input\mycontroller_profile.json wasn't in the release. Controllers may show but bindings may be off." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "ERROR: Auto-install failed: $_" -ForegroundColor Red
        Write-Host "Install it manually from https://github.com/ar-zadeh/VR-Emulator-Driver/releases and re-run this script."
        Read-Host "Press Enter to exit"
        exit 1
    }
} else {
    Write-Host "`nVR-Emulator-Driver already installed, skipping download." -ForegroundColor Green
}

# --- Step 3: Back up both settings files once, before the first edit ---
foreach ($f in @($nullDriverFile, $userConfigFile)) {
    if ((Test-Path $f) -and -not (Test-Path "$f.bak")) {
        Copy-Item $f "$f.bak"
        Write-Host "Backed up $f -> $f.bak"
    }
}

# --- Step 4: Enable the driver in its own settings file (whatever section name it uses) ---
Write-Host "`nEditing null driver settings..."
$nullJson = Get-Content $nullDriverFile -Raw | ConvertFrom-Json
foreach ($section in $nullJson.PSObject.Properties) {
    if ($section.Value -is [PSCustomObject] -and $section.Value.PSObject.Properties["enable"]) {
        $section.Value.enable = $true
        Write-Host "  $($section.Name).enable = true" -ForegroundColor Green
    }
}
$nullJson | ConvertTo-Json -Depth 10 | Set-Content $nullDriverFile

# --- Step 5: User config so SteamVR boots without a real HMD ---
Write-Host "`nEditing user config ($userConfigFile)..."
$userJson = if (Test-Path $userConfigFile) { Get-Content $userConfigFile -Raw | ConvertFrom-Json } else { [PSCustomObject]@{} }
foreach ($s in "steamvr", "driver_null", "power") {
    if (-not $userJson.PSObject.Properties[$s]) {
        $userJson | Add-Member -MemberType NoteProperty -Name $s -Value ([PSCustomObject]@{})
    }
}
$userJson.steamvr | Add-Member -MemberType NoteProperty -Name "requireHmd" -Value $false -Force
$userJson.steamvr | Add-Member -MemberType NoteProperty -Name "forcedDriver" -Value "null" -Force
$userJson.steamvr | Add-Member -MemberType NoteProperty -Name "activateMultipleDrivers" -Value $true -Force
$userJson.driver_null | Add-Member -MemberType NoteProperty -Name "enable" -Value $true -Force
$userJson.power | Add-Member -MemberType NoteProperty -Name "overrideWindowsPowerScheme" -Value $true -Force
$userJson | ConvertTo-Json -Depth 10 | Set-Content $userConfigFile
Write-Host "  requireHmd = false, forcedDriver = null, activateMultipleDrivers = true" -ForegroundColor Green

# --- Step 6: Point OpenXR at SteamVR (remember the old runtime so cleanup can restore it) ---
Write-Host "`nSetting SteamVR as the OpenXR runtime..."
$current = (Get-ItemProperty $openXrKey -ErrorAction SilentlyContinue).ActiveRuntime
if ($current -and $current -ne $steamXrJson -and -not (Test-Path $savedRuntimeFile)) {
    Set-Content -Path $savedRuntimeFile -Value $current
    Write-Host "  Saved previous runtime: $current"
}
if (Test-Path $steamXrJson) {
    New-Item -Path $openXrKey -Force | Out-Null
    Set-ItemProperty -Path $openXrKey -Name "ActiveRuntime" -Value $steamXrJson
    Write-Host "  ActiveRuntime = $steamXrJson" -ForegroundColor Green
} else {
    Write-Host "  WARNING: $steamXrJson not found; set it in SteamVR > Settings > OpenXR instead." -ForegroundColor Yellow
}

# --- Step 7: Launch SteamVR and show the log ---
Write-Host "`nLaunching SteamVR..." -ForegroundColor Cyan
Start-Process "steam://rungameid/250820"
Write-Host "Waiting 15 seconds for SteamVR to start..."
Start-Sleep -Seconds 15

$logFile = Join-Path $steamPath "logs\vrserver.txt"
if (Test-Path $logFile) {
    Write-Host "`n=== Driver/device lines from vrserver.txt ===" -ForegroundColor Cyan
    Select-String -Path $logFile -Pattern "null|Controller|TrackedDevice|error|Unable" | Select-Object -Last 25 | ForEach-Object { $_.Line }
} else {
    Write-Host "Could not find $logFile yet -- SteamVR may still be starting." -ForegroundColor Yellow
}

Write-Host "`nDone. The SteamVR status window should show a headset AND two controllers."
if (-not $NoPause) { Read-Host "`nPress Enter to close this window" }
exit 0
