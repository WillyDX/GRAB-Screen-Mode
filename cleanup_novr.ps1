# cleanup_novr.ps1
# Undoes setup_novr.ps1 so SteamVR (and apps like Roblox Studio) stop thinking a
# headset is connected. Run setup_novr.ps1 again whenever you want to play.
# Edit $steamPath below if Steam is installed somewhere other than the default.

# Restoring the OpenXR runtime writes to HKLM, which needs admin. Re-launch elevated if needed.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$steamPath = "C:\Program Files (x86)\Steam"

$nullDriverFolder = Join-Path $steamPath "steamapps\common\SteamVR\drivers\null"
$nullDriverFile   = Join-Path $nullDriverFolder "resources\settings\default.vrsettings"
$userConfigFile   = Join-Path $steamPath "config\steamvr.vrsettings"

Write-Host "=== SteamVR No-Headset Cleanup ===" -ForegroundColor Cyan

# --- Step 1: Close SteamVR first. It rewrites steamvr.vrsettings when it exits,
#             which would undo our edits if it were still running. ---
Write-Host "`nClosing any running SteamVR processes..."
foreach ($proc in @("vrmonitor", "vrdashboard", "vrcompositor", "vrwebhelper", "vrstartup", "vrserver")) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Stopping $proc (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force
    }
}
Start-Sleep -Seconds 2

# --- Step 2: Revert the user config keys that setup changed ---
# If the pre-setup backup exists, put each key back to its original value
# (or remove it if it wasn't there). Other settings SteamVR saved since then are kept.
if (Test-Path $userConfigFile) {
    Write-Host "`nReverting $userConfigFile..."
    $userJson = Get-Content $userConfigFile -Raw | ConvertFrom-Json
    $backupFile = "$userConfigFile.bak"
    $orig = $null
    if (Test-Path $backupFile) {
        $orig = Get-Content $backupFile -Raw | ConvertFrom-Json
    }

    function Restore-Key($section, $key) {
        $cur = $userJson.PSObject.Properties[$section]
        if (-not $cur) { return }
        $origSection = if ($orig) { $orig.PSObject.Properties[$section] } else { $null }
        $origValue = if ($origSection) { $origSection.Value.PSObject.Properties[$key] } else { $null }
        if ($origValue) {
            $cur.Value | Add-Member -MemberType NoteProperty -Name $key -Value $origValue.Value -Force
            Write-Host "  $section.$key restored to $($origValue.Value)"
        } elseif ($cur.Value.PSObject.Properties[$key]) {
            $cur.Value.PSObject.Properties.Remove($key)
            Write-Host "  $section.$key removed"
        }
        # Drop the section entirely if it's now empty
        if (@($cur.Value.PSObject.Properties).Count -eq 0) {
            $userJson.PSObject.Properties.Remove($section)
        }
    }

    Restore-Key "steamvr" "requireHmd"
    Restore-Key "steamvr" "forcedDriver"
    Restore-Key "steamvr" "activateMultipleDrivers"
    Restore-Key "power"   "overrideWindowsPowerScheme"
    Restore-Key "driver_null" "enable"

    # Whatever the backup said, make sure the null driver ends up disabled.
    if ($userJson.PSObject.Properties["driver_null"]) {
        $userJson.driver_null | Add-Member -MemberType NoteProperty -Name "enable" -Value $false -Force
        Write-Host "  driver_null.enable = false"
    }

    $userJson | ConvertTo-Json -Depth 10 | Set-Content $userConfigFile
} else {
    Write-Host "`n$userConfigFile not found, nothing to revert there." -ForegroundColor Yellow
}

# --- Step 3: Disable the driver in the null driver's own settings file ---
if (Test-Path $nullDriverFile) {
    Write-Host "`nDisabling driver in $nullDriverFile..."
    $nullJson = Get-Content $nullDriverFile -Raw | ConvertFrom-Json
    foreach ($section in $nullJson.PSObject.Properties) {
        if ($section.Value -is [PSCustomObject] -and $section.Value.PSObject.Properties["enable"]) {
            $section.Value.enable = $false
            Write-Host "  $($section.Name).enable = false" -ForegroundColor Green
        }
    }
    $nullJson | ConvertTo-Json -Depth 10 | Set-Content $nullDriverFile
}

# --- Step 3b: Give OpenXR back to whatever runtime was active before setup (e.g. Oculus) ---
$savedRuntimeFile = "C:\actions\.previous_openxr_runtime.txt"
if (Test-Path $savedRuntimeFile) {
    $prev = (Get-Content $savedRuntimeFile -Raw).Trim()
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Khronos\OpenXR\1" -Name "ActiveRuntime" -Value $prev
    Remove-Item $savedRuntimeFile -Force
    Write-Host "`nOpenXR runtime restored to $prev" -ForegroundColor Green
}

# --- Step 4: Reset the emulator's input files so the next session starts clean ---
foreach ($f in @("headset_position_changes.txt", "headset_rotation_changes.txt", ".flatscreen_state.json")) {
    $p = Join-Path "C:\actions" $f
    if (Test-Path $p) { Remove-Item $p -Force }
}

Write-Host "`nDone. SteamVR will no longer fake a headset." -ForegroundColor Green
Write-Host "The emulator driver files are still installed (just disabled), so setup_novr.ps1 can re-enable them instantly."
Write-Host "To fully restore SteamVR's original null driver: Steam > Library > SteamVR > Properties > Installed Files > Verify integrity."
Write-Host "(setup_novr.ps1 will notice and reinstall the emulator next time.)"
Read-Host "`nPress Enter to close this window"
