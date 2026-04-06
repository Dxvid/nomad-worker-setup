#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$Distro,
    # Disable sleep, hibernate and the physical power button.
    [switch]$PreventSleep,
    # Configure Windows to log in automatically at boot (needed for unattended startup).
    # After this script runs, set the password via netplwiz or Sysinternals Autologon.
    [switch]$AutoLogon,
    # Lock the desktop immediately after auto-logon so the screen is protected
    # while WSL2 and Nomad run in the background. Requires -AutoLogon to be useful.
    [switch]$LockAfterLogon,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments)][string[]]$ExtraArgs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TASK_NAME      = "Nomad - WSL2 Autostart"
$LOCK_TASK_NAME = "Nomad - Lock After Logon"

# Map Linux-style --flags
for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
    switch ($ExtraArgs[$i].ToLower()) {
        '--distro'          { $Distro         = $ExtraArgs[++$i] }
        '--prevent-sleep'   { $PreventSleep   = $true }
        '--auto-logon'      { $AutoLogon      = $true }
        '--lock-after-logon'{ $LockAfterLogon = $true }
        '--help'            { $Help           = $true }
        '--?'               { $Help           = $true }
    }
}

if ($Help) {
    Write-Host @"

USAGE
  .\wsl-autostart-setup.ps1 [-Distro <name>] [-PreventSleep] [-AutoLogon] [-LockAfterLogon]

DESCRIPTION
  Registers a Task Scheduler task that starts the WSL2 distro running Nomad
  automatically when a user logs in to Windows.

  WSL2 requires a user session — it cannot start before login. The recommended
  setup for an unattended worker is:
    1. -AutoLogon      Windows logs in automatically at boot
    2.                 WSL2 + Nomad start (via the scheduled task)
    3. -LockAfterLogon Desktop is locked 10 seconds later
    → Machine runs Nomad in background, screen is PIN-protected

  There is no true headless mode in Windows 11. Auto-logon + immediate lock
  is the closest equivalent.

FLAGS
  -Distro / --distro <name>       WSL2 distro that runs Nomad.
                                  Prompted if omitted and multiple distros exist.
  -PreventSleep / --prevent-sleep Disable sleep/hibernate, set power button to
                                  "Do nothing", disable login-screen shutdown.
  -AutoLogon / --auto-logon       Enable automatic login at boot for the current
                                  user. Does NOT store the password — see below.
  -LockAfterLogon / --lock-after-logon
                                  Lock the desktop 10 s after logon so the screen
                                  is protected while Nomad runs in the background.
  -Help / --help / /?             Show this help text

SETTING THE AUTO-LOGON PASSWORD
  This script configures everything except the password (storing passwords in
  scripts or the registry in plaintext is a security risk). Set it with either:
    netplwiz             — uncheck "Users must enter username and password",
                           click OK, enter password when prompted
    Sysinternals Autologon — encrypts the password in LSA secrets (recommended)
    https://learn.microsoft.com/sysinternals/downloads/autologon

RESOURCE USAGE (IDLE)
  CPU  : ~0%
  RAM  : ~100-200 MB for the VM (vmmem) + Nomad's own footprint
  The script will ask whether to use gradual or dropcache memory reclaim:
    gradual    Slowly returns unused memory — best for dedicated worker nodes
    dropcache  Aggressively frees memory when idle — best for gaming PCs that
               also run Nomad, so RAM is available for games between jobs

SHUTDOWN RESTRICTION
  -PreventSleep covers: sleep, hibernate, physical power button, login-screen
  shutdown button. It does NOT prevent a logged-in user from using
  Start > Shut Down or Ctrl+Alt+Del > Shut Down. Blocking those requires
  a third-party kiosk/MDM solution.

EXAMPLES
  # Dedicated worker node (unattended, screen locked)
  .\wsl-autostart-setup.ps1 -Distro Ubuntu-24.04 -PreventSleep -AutoLogon -LockAfterLogon

  # Gaming PC that also runs Nomad (manual login, dropcache for RAM)
  .\wsl-autostart-setup.ps1 -Distro Ubuntu-24.04

  # Linux-style flags work too
  .\wsl-autostart-setup.ps1 --distro Ubuntu-24.04 --prevent-sleep --auto-logon --lock-after-logon

"@
    exit 0
}

# ============================================================
#  LIST / SELECT WSL2 DISTRO
# ============================================================
function Get-WslDistros {
    $raw = wsl --list --quiet 2>$null
    return @($raw |
        ForEach-Object { $_.Trim() -replace '\x00','' } |
        Where-Object { $_ -ne '' })
}

function Select-WslDistro {
    $distros = Get-WslDistros

    if ($distros.Count -eq 0) {
        throw "No WSL2 distros found. Install one first."
    }

    if ($distros.Count -eq 1) {
        Write-Host "[INFO] Using WSL2 distro: $($distros[0])"
        return $distros[0]
    }

    Write-Host ""
    Write-Host "Multiple WSL2 distros detected. Which one runs Nomad?"
    Write-Host ""
    for ($i = 0; $i -lt $distros.Count; $i++) {
        Write-Host "  $($i + 1)) $($distros[$i])"
    }
    Write-Host ""

    do {
        $raw    = Read-Host "Enter number (1-$($distros.Count))"
        $choice = $raw -as [int]
    } while (-not $choice -or $choice -lt 1 -or $choice -gt $distros.Count)

    $selected = $distros[$choice - 1]
    Write-Host "[INFO] Using WSL2 distro: $selected"
    return $selected
}

# ============================================================
#  WSL2 MEMORY RECLAIM  (.wslconfig)
# ============================================================
function Select-MemoryReclaimMode {
    Write-Host ""
    Write-Host "WSL2 memory reclaim mode:"
    Write-Host "  1) gradual    — slowly returns unused RAM (best for dedicated worker nodes)"
    Write-Host "  2) dropcache  — aggressively frees RAM when idle (best for gaming PCs)"
    Write-Host ""

    do {
        $raw    = Read-Host "Enter 1 or 2"
        $choice = $raw -as [int]
    } while ($choice -ne 1 -and $choice -ne 2)

    return @("gradual","dropcache")[$choice - 1]
}

function Set-WslMemoryReclaim {
    param([string]$Mode)

    $wslconfig = Join-Path $env:USERPROFILE ".wslconfig"

    if (-not (Test-Path $wslconfig)) {
        Set-Content -Path $wslconfig -Value "[wsl2]`r`nautoMemoryReclaim=$Mode"
        Write-Host "[INFO] Created $wslconfig with autoMemoryReclaim=$Mode"
        return
    }

    $content = Get-Content $wslconfig -Raw

    if ($content -match '(?m)^\s*autoMemoryReclaim\s*=') {
        $content = $content -replace '(?m)^\s*autoMemoryReclaim\s*=.*', "autoMemoryReclaim=$Mode"
        Write-Host "[INFO] Updated autoMemoryReclaim=$Mode in $wslconfig"
    } elseif ($content -match '(?m)^\s*\[wsl2\]') {
        $content = $content -replace '(?m)(^\s*\[wsl2\])', "`$1`r`nautoMemoryReclaim=$Mode"
        Write-Host "[INFO] Added autoMemoryReclaim=$Mode to [wsl2] section in $wslconfig"
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n[wsl2]`r`nautoMemoryReclaim=$Mode"
        Write-Host "[INFO] Appended [wsl2] section with autoMemoryReclaim=$Mode to $wslconfig"
    }

    Set-Content -Path $wslconfig -Value $content
    Write-Host "[INFO] WSL2 must be restarted for this to take effect: wsl --shutdown"
}

# ============================================================
#  TASK SCHEDULER — WSL2 AUTOSTART
# ============================================================
function Register-WslAutostartTask {
    param([string]$DistroName)

    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue

    # Start the distro. With systemd enabled, all enabled services (incl. Nomad)
    # boot automatically. The 'true' command exits immediately; the distro stays
    # alive because systemd keeps running.
    $psArgs = "-NonInteractive -WindowStyle Hidden -Command `"wsl -d '$DistroName' -- true`""

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings  = New-ScheduledTaskSettingsSet `
                     -ExecutionTimeLimit  ([TimeSpan]::Zero) `
                     -RestartCount        3 `
                     -RestartInterval     (New-TimeSpan -Minutes 1) `
                     -StartWhenAvailable  $true `
                     -MultipleInstances   IgnoreNew
    $principal = New-ScheduledTaskPrincipal `
                     -UserId   $env:USERNAME `
                     -LogonType Interactive `
                     -RunLevel Highest

    Register-ScheduledTask `
        -TaskName  $TASK_NAME `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal | Out-Null

    Write-Host "[INFO] Task '$TASK_NAME' registered (trigger: logon of $env:USERNAME)"
}

# ============================================================
#  TASK SCHEDULER — LOCK AFTER LOGON
# ============================================================
function Register-LockAfterLogonTask {
    Unregister-ScheduledTask -TaskName $LOCK_TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue

    # 10-second delay so WSL2 has time to start before the screen locks
    $psArgs    = "-NonInteractive -WindowStyle Hidden -Command `"Start-Sleep -Seconds 10; rundll32.exe user32.dll,LockWorkStation`""
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal `
                     -UserId    $env:USERNAME `
                     -LogonType Interactive `
                     -RunLevel  Limited

    Register-ScheduledTask `
        -TaskName  $LOCK_TASK_NAME `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal | Out-Null

    Write-Host "[INFO] Task '$LOCK_TASK_NAME' registered (locks screen 10 s after logon)"
}

# ============================================================
#  AUTO-LOGON
# ============================================================
function Enable-AutoLogon {
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $regPath -Name "AutoAdminLogon"   -Value "1" -Type String
    Set-ItemProperty -Path $regPath -Name "DefaultUserName"  -Value $env:USERNAME -Type String
    Set-ItemProperty -Path $regPath -Name "DefaultDomainName" -Value "." -Type String
    # AutoLogonCount not set — logon repeats on every boot

    Write-Host "[INFO] Auto-logon enabled for user: $env:USERNAME"
    Write-Host ""
    Write-Host "[ACTION REQUIRED] Set the auto-logon password using one of:"
    Write-Host "  netplwiz (built-in):"
    Write-Host "    1. Run: netplwiz"
    Write-Host "    2. Uncheck 'Users must enter a user name and password'"
    Write-Host "    3. Click OK and enter the password when prompted"
    Write-Host ""
    Write-Host "  Sysinternals Autologon (recommended — encrypts password in LSA):"
    Write-Host "    https://learn.microsoft.com/sysinternals/downloads/autologon"
}

# ============================================================
#  SLEEP / POWER BUTTON
# ============================================================
function Disable-SleepAndPowerButton {
    powercfg -change standby-timeout-ac 0
    powercfg -change standby-timeout-dc 0
    Write-Host "[INFO] Sleep timeout disabled (AC + DC)"

    powercfg -hibernate off
    Write-Host "[INFO] Hibernate disabled"

    # 0 = Do nothing, 1 = Sleep, 2 = Hibernate, 3 = Shut down
    powercfg -setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0
    powercfg -setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0
    powercfg -setactive SCHEME_CURRENT
    Write-Host "[INFO] Physical power button set to 'Do nothing'"

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $regPath -Name "ShutdownWithoutLogon" -Value 0 -Type DWord
    Write-Host "[INFO] Login-screen shutdown button disabled"
    Write-Host "[WARN] Logged-in users can still shut down via Start menu or Ctrl+Alt+Del"
}

# ============================================================
#  MAIN
# ============================================================
Write-Host ""
Write-Host "=== WSL2 Nomad Autostart Setup ==="
Write-Host ""

if (-not $Distro) {
    $Distro = Select-WslDistro
}

$reclaimMode = Select-MemoryReclaimMode

Write-Host ""
Write-Host "=== Applying configuration ==="
Write-Host ""

Register-WslAutostartTask -DistroName $Distro
Set-WslMemoryReclaim -Mode $reclaimMode

if ($LockAfterLogon) {
    Register-LockAfterLogonTask
}

if ($AutoLogon) {
    Write-Host ""
    Enable-AutoLogon
}

if ($PreventSleep) {
    Write-Host ""
    Write-Host "=== Disabling sleep and configuring power button ==="
    Disable-SleepAndPowerButton
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Distro '$Distro' will start automatically at next logon."
Write-Host "Memory reclaim: $reclaimMode"
if ($LockAfterLogon) {
    Write-Host "Screen will lock 10 s after logon."
}
Write-Host ""
Write-Host "To start WSL2 right now without logging out:"
Write-Host "  Start-ScheduledTask -TaskName '$TASK_NAME'"
Write-Host ""
Write-Host "To remove the autostart task:"
Write-Host "  Unregister-ScheduledTask -TaskName '$TASK_NAME' -Confirm:`$false"
Write-Host ""
