#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][ValidateSet("server","worker")][string]$Mode,
    # Use -Legacy on Win10, Win11 LTSB/LTSC, or any build older than 22H2 (22621).
    # Falls back to ipconfig-based IP detection, netsh advfirewall rules, and
    # forces NAT-style WSL setup (mirrored networking is not available there).
    [switch]$Legacy,
    [Alias("?")][switch]$Help,
    # Catch Linux-style --flags so they can be mapped below
    [Parameter(ValueFromRemainingArguments)][string[]]$ExtraArgs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Map Linux-style --flags to their PowerShell equivalents
for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
    switch ($ExtraArgs[$i].ToLower()) {
        '--mode'   { $Mode   = $ExtraArgs[++$i] }
        '--legacy' { $Legacy = $true }
        '--help'   { $Help   = $true }
        '--?'      { $Help   = $true }
    }
}

if ($Help -or -not $Mode) {
    Write-Host @"

USAGE
  .\wsl-firewall-setup.ps1 -Mode <server|worker> [-Legacy]
  .\wsl-firewall-setup.ps1 --mode <server|worker> [--legacy]

FLAGS
  -Mode / --mode server   Open ports 4646, 4647, 4648 (Nomad server + RPC + Serf)
  -Mode / --mode worker   Open port 4646 only (Nomad HTTP API — clients don't use 4647/4648)
  -Legacy / --legacy      Use ipconfig + netsh instead of PS modules. Required on Win10,
                          Win11 LTSC, or any build older than 22H2 (build 22621).
  -Help / --help / /?     Show this help text

WSL2 NETWORKING MODE
  The script reads networkingMode from %USERPROFILE%\.wslconfig and adapts
  automatically. Default is nat if the file is absent or the key is not set.

  Supported modes:
    nat       (default) WSL2 gets its own private IP. Script adds port forwarding
              from Windows host to the WSL2 VM automatically.

    mirrored  WSL2 shares the host's network interfaces directly. No port
              forwarding needed. Requires Win11 22H2 (build 22621) or later
              and WSL version 2.0.0 or later.

    bridged   WSL2 is placed directly on the LAN via a physical adapter.
              No port forwarding needed.

  To change networking mode, edit (or create) %USERPROFILE%\.wslconfig:

    [wsl2]
    networkingMode=mirrored

  Then restart WSL:
    wsl --shutdown

  Verify the active WSL version:
    wsl --version

EXAMPLES
  .\wsl-firewall-setup.ps1 -Mode worker
  .\wsl-firewall-setup.ps1 -Mode server
  .\wsl-firewall-setup.ps1 -Mode worker -Legacy
  .\wsl-firewall-setup.ps1 --mode worker --legacy

"@
    exit 0
}

$NOMAD_PORTS = if ($Mode -eq "server") { @(4646, 4647, 4648) } else { @(4646) }
$RULE_PREFIX = "Nomad"

# Minimum build for WSL2 mirrored networking (Win11 22H2 + KB5031455)
$MIN_MIRRORED_BUILD = 22621

# ============================================================
#  WINDOWS VERSION CHECK
# ============================================================
function Get-WindowsBuild {
    return [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
}

function Assert-MirroredSupport {
    $build = Get-WindowsBuild
    if ($build -lt $MIN_MIRRORED_BUILD) {
        Write-Warning ("WSL2 mirrored networking requires build $MIN_MIRRORED_BUILD+ " +
                       "(you have $build). Treating as NAT. " +
                       "Update .wslconfig to networkingMode=nat or upgrade Windows.")
        return $false
    }
    return $true
}

# ============================================================
#  DETECT WSL2 NETWORKING MODE
# ============================================================
function Get-WslNetworkingMode {
    $wslconfig = Join-Path $env:USERPROFILE ".wslconfig"

    if (Test-Path $wslconfig) {
        $match = Select-String -Path $wslconfig -Pattern '^\s*networkingMode\s*=\s*(\S+)' |
            Select-Object -First 1
        if ($match) {
            return $match.Matches[0].Groups[1].Value.ToLower()
        }
    }

    # Default WSL2 mode when .wslconfig is absent or networkingMode is not set
    return "nat"
}

# ============================================================
#  DETECT HOST LAN IP — modern (Win11 22H2+ default)
# ============================================================
function Get-HostLanIP {
    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne "0.0.0.0" } |
        Sort-Object RouteMetric |
        Select-Object -First 1

    if (-not $defaultRoute) {
        throw "Could not find default route — is the machine connected to a network?"
    }

    $ip = Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex `
            -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $ip) {
        throw "Could not find IPv4 address on default route interface (index $($defaultRoute.InterfaceIndex))"
    }

    return $ip   # object with .IPAddress and .PrefixLength
}

# ============================================================
#  DETECT HOST LAN IP — legacy (ipconfig parsing, no PS modules needed)
# ============================================================
function Get-HostLanIP-Legacy {
    # Parse ipconfig /all to find the first non-loopback, non-APIPA IPv4 with a subnet mask
    $ipconfigOutput = ipconfig /all

    $currentAdapter = $null
    $candidates     = @()

    foreach ($line in $ipconfigOutput) {
        if ($line -match '^[A-Za-z]') {
            $currentAdapter = $line.Trim()
        }

        if ($line -match 'IPv4[^:]*:\s+([\d\.]+)') {
            $ip = $Matches[1].TrimEnd('(Preferred)')
            # Peek at next lines for subnet mask — collect for pairing below
            $candidates += [PSCustomObject]@{ Adapter = $currentAdapter; IP = $ip.Trim() }
        }
    }

    # Extract subnet masks in order (they follow their IPv4 line in ipconfig output)
    $masks = @()
    foreach ($line in $ipconfigOutput) {
        if ($line -match 'Subnet Mask[^:]*:\s+([\d\.]+)') {
            $masks += $Matches[1].Trim()
        }
    }

    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $ip   = $candidates[$i].IP
        $mask = if ($i -lt $masks.Count) { $masks[$i] } else { $null }

        # Skip loopback and APIPA
        if ($ip -eq "127.0.0.1" -or $ip.StartsWith("169.254")) { continue }
        if (-not $mask) { continue }

        $prefix = ConvertMaskToPrefix $mask
        return [PSCustomObject]@{ IPAddress = $ip; PrefixLength = $prefix }
    }

    throw "Could not detect host LAN IP via ipconfig — is the machine connected to a network?"
}

function ConvertMaskToPrefix {
    param([string]$Mask)
    $bytes = ([System.Net.IPAddress]$Mask).GetAddressBytes()
    $bits  = 0
    foreach ($b in $bytes) {
        $n = [int]$b
        while ($n -gt 0) { $bits += ($n -band 1); $n = $n -shr 1 }
    }
    return $bits
}

# ============================================================
#  CALCULATE SUBNET CIDR  (e.g. 192.168.1.50/24 → 192.168.1.0/24)
# ============================================================
function Get-NetworkCIDR {
    param([string]$IPAddress, [int]$PrefixLength)

    $ipBytes   = ([System.Net.IPAddress]$IPAddress).GetAddressBytes()
    $maskBytes = [byte[]]::new(4)

    for ($i = 0; $i -lt 4; $i++) {
        $bits          = [Math]::Max(0, [Math]::Min(8, $PrefixLength - $i * 8))
        $maskBytes[$i] = [byte]([byte](0xFF -shl (8 - $bits)) -band 0xFF)
    }

    $networkBytes = for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] -band $maskBytes[$i] }
    return "$($networkBytes -join '.')/$PrefixLength"
}

# ============================================================
#  GET WSL2 VM IP  (only relevant in NAT mode)
# ============================================================
function Get-WslIP {
    try {
        $ip = (wsl hostname -I 2>$null).Trim().Split(" ")[0]
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
    } catch { }

    throw "Could not get WSL2 IP — is a WSL2 distro running? Start one and re-run this script."
}

# ============================================================
#  FIREWALL RULES — modern (New-NetFirewallRule)
# ============================================================
function Remove-ExistingNomadRules {
    $existing = Get-NetFirewallRule -DisplayName "$RULE_PREFIX *" -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetFirewallRule
        Write-Host "[INFO] Removed $($existing.Count) existing Nomad firewall rule(s)"
    }
}

function Add-FirewallRule {
    param(
        [string]$Name,
        [string]$RemoteAddress = "Any",
        [string]$InterfaceAlias = $null
    )

    $params = @{
        DisplayName   = "$RULE_PREFIX $Name"
        Direction     = "Inbound"
        Protocol      = "TCP"
        LocalPort     = $NOMAD_PORTS
        RemoteAddress = $RemoteAddress
        Action        = "Allow"
    }
    if ($InterfaceAlias) { $params["InterfaceAlias"] = $InterfaceAlias }

    New-NetFirewallRule @params | Out-Null
    $portList = $NOMAD_PORTS -join ", "
    Write-Host "[INFO] Firewall rule added: '$RULE_PREFIX $Name' ports $portList"
}

# ============================================================
#  FIREWALL RULES — legacy (netsh advfirewall, works on Win10/LTSC/Home)
# ============================================================
function Remove-ExistingNomadRules-Legacy {
    foreach ($port in $NOMAD_PORTS) {
        netsh advfirewall firewall delete rule `
            name="$RULE_PREFIX port $port" 2>&1 | Out-Null
    }
    Write-Host "[INFO] Removed any existing Nomad firewall rules (netsh)"
}

function Add-FirewallRule-Legacy {
    param([string]$Name, [string]$RemoteIP = "any")

    foreach ($port in $NOMAD_PORTS) {
        netsh advfirewall firewall add rule `
            name="$RULE_PREFIX port $port" `
            dir=in action=allow protocol=TCP `
            localport=$port remoteip=$RemoteIP | Out-Null
    }
    $portList = $NOMAD_PORTS -join ", "
    Write-Host "[INFO] Firewall rule added (netsh): '$RULE_PREFIX $Name' ports $portList remoteip=$RemoteIP"
}

# ============================================================
#  PORT FORWARDING  (NAT mode only)
# ============================================================
function Set-PortForwarding {
    param([string]$WslIP)

    foreach ($port in $NOMAD_PORTS) {
        netsh interface portproxy add v4tov4 `
            listenport=$port   listenaddress=0.0.0.0 `
            connectport=$port  connectaddress=$WslIP 2>&1 | Out-Null
    }
    Write-Host "[INFO] Port forwarding configured → WSL2 at $WslIP"
}

function Remove-PortForwarding {
    foreach ($port in $NOMAD_PORTS) {
        netsh interface portproxy delete v4tov4 `
            listenport=$port listenaddress=0.0.0.0 2>&1 | Out-Null
    }
    Write-Host "[INFO] Removed any existing port forwarding rules for Nomad ports"
}

# ============================================================
#  CONNECTIVITY TEST
# ============================================================
function Test-NomadPorts {
    param([string]$Target)

    Write-Host ""
    Write-Host "=== Testing connectivity to $Target ==="
    foreach ($port in $NOMAD_PORTS) {
        $result = Test-NetConnection -ComputerName $Target -Port $port -WarningAction SilentlyContinue
        $status  = if ($result.TcpTestSucceeded) { "OPEN  " } else { "CLOSED" }
        Write-Host "  [$status] port $port"
    }
}

# ============================================================
#  MAIN
# ============================================================
Write-Host ""
Write-Host "=== WSL2 Nomad Firewall Setup ==="
Write-Host ""

if ($Legacy) {
    Write-Host "[INFO] Running in legacy mode (ipconfig + netsh advfirewall)"
    $hostIP = Get-HostLanIP-Legacy
} else {
    $hostIP = Get-HostLanIP
}

$subnet = Get-NetworkCIDR -IPAddress $hostIP.IPAddress -PrefixLength $hostIP.PrefixLength

Write-Host "[INFO] Host LAN IP    : $($hostIP.IPAddress)/$($hostIP.PrefixLength)"
Write-Host "[INFO] Allowed subnet : $subnet"
Write-Host ""

if ($Legacy) {
    # Legacy: no PS firewall module, no mirrored-mode support — always NAT
    Remove-ExistingNomadRules-Legacy
    Remove-PortForwarding

    $wslIP = Get-WslIP
    Write-Host "[INFO] NAT mode (forced) — WSL2 IP: $wslIP"
    Add-FirewallRule-Legacy -Name "LAN" -RemoteIP $subnet
    Set-PortForwarding -WslIP $wslIP

} else {
    $wslMode = Get-WslNetworkingMode
    Write-Host "[INFO] WSL2 networking mode : $wslMode"
    Write-Host ""

    Remove-ExistingNomadRules

    switch ($wslMode) {
        "mirrored" {
            if (-not (Assert-MirroredSupport)) {
                # Build too old — fall through to NAT
                $wslIP = Get-WslIP
                Write-Host "[INFO] Falling back to NAT mode — WSL2 IP: $wslIP"
                Add-FirewallRule -Name "LAN"         -RemoteAddress $subnet
                Add-FirewallRule -Name "WSL2 bridge" -InterfaceAlias "vEthernet (WSL)"
                Set-PortForwarding -WslIP $wslIP
            } else {
                Write-Host "[INFO] Mirrored mode — WSL2 shares host network, no port forwarding needed"
                Add-FirewallRule -Name "LAN (mirrored)" -RemoteAddress $subnet
                Remove-PortForwarding
            }
        }

        "nat" {
            $wslIP = Get-WslIP
            Write-Host "[INFO] NAT mode — WSL2 IP: $wslIP"
            Add-FirewallRule -Name "LAN"         -RemoteAddress $subnet
            Add-FirewallRule -Name "WSL2 bridge" -InterfaceAlias "vEthernet (WSL)"
            Set-PortForwarding -WslIP $wslIP
        }

        "bridged" {
            Write-Host "[INFO] Bridged mode — WSL2 is directly on LAN, no port forwarding needed"
            Add-FirewallRule -Name "LAN (bridged)" -RemoteAddress $subnet
            Remove-PortForwarding
        }

        default {
            Write-Warning "Unknown networking mode '$wslMode' — falling back to NAT-style setup"
            $wslIP = Get-WslIP
            Write-Host "[INFO] Detected WSL2 IP: $wslIP"
            Add-FirewallRule -Name "LAN (fallback)"         -RemoteAddress $subnet
            Add-FirewallRule -Name "WSL2 bridge (fallback)" -InterfaceAlias "vEthernet (WSL)"
            Set-PortForwarding -WslIP $wslIP
        }
    }
}

Test-NomadPorts -Target $hostIP.IPAddress

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Re-run this script after rebooting if WSL2 networking mode is NAT"
Write-Host "(WSL2 IP changes on every restart in NAT mode)"
Write-Host ""
