<#
.SYNOPSIS
    Prepares a Windows 10 host to run a WSL2 Ubuntu 24.04 distro and publishes
    its sshd on a Windows TCP port, so the distro can be managed over SSH.

.DESCRIPTION
    Idempotent, elevated bootstrap for the Windows side of a WSL2 distro that is
    reached and configured over SSH - by hand, or by a configuration tool such
    as Ansible:

      1. enables the WSL2 Windows features and makes 2 the default WSL version,
      2. updates the WSL runtime itself, because the one that ships with those
         features has no WSL2 kernel and ignores "[boot] systemd=true",
         and sets "[general] instanceIdleTimeout=-1" in the user's .wslconfig,
         so WSL does not stop the distro when no wsl.exe is attached,
      3. imports a checksum-pinned Ubuntu 24.04 rootfs as the distro,
      4. provisions the login user and openssh-server inside the distro,
      5. publishes the distro's sshd on a Windows port, 2222 by default (netsh portproxy
         plus an inbound firewall rule),
      6. registers a scheduled task that starts the distro and rewrites the
         portproxy at every boot, at logon and every 5 minutes.

    Step 6 exists because WSL2 on Windows 10 is NAT-only (mirrored networking is
    Windows 11 only), so the distro gets a fresh IP every time it starts and a
    static portproxy would point at nothing after a reboot.

    Every step prints [ok] when the host is already in the wanted state and
    [changed] when it had to act, and the run ends with a "changed=N" summary -
    re-running a finished box prints changed=0.

.PARAMETER Mode
    Bootstrap (default) runs the full setup. BootRefresh only starts the distro
    and repoints the portproxy at its current IP; that is what the scheduled
    task runs at boot, at logon and every 5 minutes.

.PARAMETER DistroName
    Name of the WSL distro to import and manage. Default: ubuntu-ssh.

.PARAMETER WslRoot
    Directory that holds the imported distros. The distro lands in
    <WslRoot>\<DistroName> and the rootfs download is cached in <WslRoot>\cache.
    Default: %SystemDrive%\wsl.

.PARAMETER UserName
    Login user created inside the distro; SSH clients connect as this user.
    Required in Bootstrap mode - there is no default. BootRefresh does not
    need it.

.PARAMETER SshPort
    Windows-side listening port forwarded to the distro's sshd. Default: 2222.

.PARAMETER RootfsUrl
    URL of the Ubuntu 24.04 WSL rootfs tarball. Pinned to a dated
    cloud-images.ubuntu.com release, not to "current".

.PARAMETER RootfsSha256
    Expected SHA256 of the rootfs tarball. The import is refused when the
    downloaded (or supplied) tarball does not match.

.PARAMETER RootfsPath
    Use an already downloaded rootfs tarball instead of fetching RootfsUrl. It
    is still checked against RootfsSha256.

.PARAMETER AuthorizedKey
    Public SSH key of the machine that will connect, installed into the new user's
    ~/.ssh/authorized_keys. Without it the distro comes up with no way in and
    the script says so.

.PARAMETER InstallRoot
    Directory the boot-refresh copy of this script and its log are written to.
    Default: %ProgramData%\<DistroName>.

.PARAMETER TaskName
    Name of the scheduled task registered for the boot refresh.
    Default: <DistroName>-boot.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 `
        -UserName alice -AuthorizedKey "ssh-ed25519 AAAAC3Nza... alice@laptop"

.NOTES
    Run from an elevated PowerShell 5.1 (or later) session. Exit code 3010 means
    the WSL Windows features were just enabled and the host must reboot before
    the script can finish; re-run it after the reboot.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'BootRefresh')]
    [string]$Mode = 'Bootstrap',

    [ValidateNotNullOrEmpty()]
    [string]$DistroName = 'ubuntu-ssh',

    [ValidateNotNullOrEmpty()]
    [string]$WslRoot = "$env:SystemDrive\wsl",

    # No default: the login user is the caller's choice. Required in Bootstrap
    # mode (checked in Invoke-Bootstrap, so BootRefresh can run without it).
    [ValidateNotNullOrEmpty()]
    [string]$UserName,

    [ValidateRange(1, 65535)]
    [int]$SshPort = 2222,

    [ValidateNotNullOrEmpty()]
    [string]$RootfsUrl = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/20240423/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz',

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$RootfsSha256 = '8251e27ffff381a4af5f41dcb94d867de3e0d9774a9241908ab34555d99315ea',

    [string]$RootfsPath,

    [string]$AuthorizedKey,

    [string]$InstallRoot = "$env:ProgramData\$DistroName",

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = "$DistroName-boot"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 on Windows 10 can still default to an explicit
# Ssl3/Tls list without TLS 1.2, which cloud-images.ubuntu.com and GitHub
# refuse, so the rootfs download would fail. Add TLS 1.2 to such a list. Leave
# SystemDefault alone: there the OS picks the protocols, and OR-ing Tls12 into
# its zero value would pin the process to TLS 1.2 and drop TLS 1.3. Compare
# with 0, not the SystemDefault member: that member exists only from .NET
# Framework 4.7, and under strict mode an older host would stop here with an
# unclear error before the Windows build check.
if ([int][Net.ServicePointManager]::SecurityProtocol -ne 0) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Ask wsl.exe for UTF-8 output; without it every wsl.exe pipe is UTF-16LE and
# string matching silently fails.
$env:WSL_UTF8 = '1'

$script:ChangeCount = 0
$script:LogPath = $null

$script:WindowsFeatures = @(
    'Microsoft-Windows-Subsystem-Linux',
    'VirtualMachinePlatform'
)

# Minimum Windows 10 build with WSL2 support (version 2004).
$script:MinimumBuild = 19041

# First WSL runtime that honours "[boot] systemd=true"; the inbox runtime that
# ships with the Windows optional feature ignores it.
$script:MinimumWslVersion = [version]'0.67.6'

# Marker lines the in-distro provisioner prints so the Windows side can count
# changes, learn whether the distro has to be restarted and whether systemd
# came up at all.
$script:ProvisionChangedMarker = 'bootstrap-provision-changed='
$script:ProvisionRestartMarker = 'bootstrap-provision-restart-required=1'
$script:ProvisionSystemdMarker = 'bootstrap-provision-systemd-missing=1'

# Minutes between the boot task's repeated BootRefresh runs, which start the
# distro again after anything stops it while Windows stays up (a WSL update,
# a crash, wsl --shutdown).
$script:BootRefreshIntervalMinutes = 5

#region output helpers

function Write-Line {
    param([string]$Message)

    Write-Information $Message
    if ($script:LogPath) {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $script:LogPath -Value "$stamp $Message" -ErrorAction SilentlyContinue
    }
}

function Write-Step {
    param([string]$Message)

    Write-Line "==> $Message"
}

function Write-Ok {
    param([string]$Message)

    Write-Line "    [ok]      $Message"
}

function Write-Changed {
    param([string]$Message)

    $script:ChangeCount++
    Write-Line "    [changed] $Message"
}

#endregion

#region pure helpers (unit tested by tests/Test-Bootstrap.ps1)

function Get-IPv4FromWslOutput {
    <#
    .SYNOPSIS
        Extracts the address of the distro from "ip -4 -o addr show" output.
    .DESCRIPTION
        Only a well-formed dotted quad behind an "inet" keyword is accepted. A
        bare dotted-quad fallback would happily read a version banner such as
        "WSL version: 2.0.9.0" as an address and point the portproxy at it.
    #>
    param([string]$Text)

    if (-not $Text) { return $null }

    foreach ($match in [regex]::Matches($Text, 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})')) {
        $candidate = $match.Groups[1].Value
        $octets = $candidate -split '\.'
        if (@($octets | Where-Object { [int]$_ -gt 255 }).Count -eq 0) { return $candidate }
    }

    return $null
}

function Get-WslRuntimeVersion {
    <#
    .SYNOPSIS
        Reads the runtime version out of "wsl --version" output, or $null when
        the output holds no version (the inbox runtime has no --version).
    #>
    param([string]$Text)

    if (-not $Text) { return $null }

    $match = [regex]::Match($Text, '(\d+\.\d+\.\d+(?:\.\d+)?)')
    if (-not $match.Success) { return $null }

    return [version]$match.Groups[1].Value
}

function Get-PortProxyEntry {
    <#
    .SYNOPSIS
        Finds the "netsh interface portproxy show v4tov4" row for a listening
        port. Returns $null when the port is not forwarded.
    .DESCRIPTION
        Only data rows match: the table header and its dashed separator have no
        numeric port columns, and localized Windows builds keep the same row
        shape, so no output string has to be translated. The listen address is
        part of the lookup - a foreign "127.0.0.1 2222" row belongs to someone
        else and must not be mistaken for ours.
    #>
    param(
        [string]$Text,
        [int]$ListenPort,
        [string]$ListenAddress
    )

    if (-not $Text) { return $null }

    foreach ($line in ($Text -split "`r?`n")) {
        $match = [regex]::Match($line.Trim(), '^(\S+)\s+(\d+)\s+(\S+)\s+(\d+)$')
        if (-not $match.Success) { continue }
        if ([int]$match.Groups[2].Value -ne $ListenPort) { continue }
        if ($ListenAddress -and $match.Groups[1].Value -ne $ListenAddress) { continue }

        return [pscustomobject]@{
            ListenAddress  = $match.Groups[1].Value
            ListenPort     = [int]$match.Groups[2].Value
            ConnectAddress = $match.Groups[3].Value
            ConnectPort    = [int]$match.Groups[4].Value
        }
    }

    return $null
}

function Read-ProvisionResult {
    <#
    .SYNOPSIS
        Splits provisioner output into its reportable lines, the number of
        changes it made, whether the distro has to be restarted and whether it
        came up without systemd.
    #>
    param([string]$Output)

    $lines = @()
    $changed = 0
    $restartRequired = $false
    $systemdMissing = $false

    foreach ($line in ($Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith($script:ProvisionChangedMarker)) {
            $value = $trimmed.Substring($script:ProvisionChangedMarker.Length)
            if ($value -match '^\d+$') { $changed = [int]$value }
            else { $lines += "unreadable change marker: $trimmed" }
            continue
        }
        if ($trimmed -eq $script:ProvisionRestartMarker) {
            $restartRequired = $true
            continue
        }
        if ($trimmed -eq $script:ProvisionSystemdMarker) {
            $systemdMissing = $true
            continue
        }
        $lines += $trimmed
    }

    return [pscustomobject]@{
        Changed         = $changed
        RestartRequired = $restartRequired
        SystemdMissing  = $systemdMissing
        Lines           = $lines
    }
}

function Merge-WslConfigText {
    <#
    .SYNOPSIS
        Sets a key in a section of .wslconfig text and reports whether the text
        changed.
    .DESCRIPTION
        Every other section, key, comment and blank line is kept as it is, and
        the line endings of the input are reused (CRLF for a new file). Section
        and key names match case-insensitively, so an existing
        "instanceidletimeout" is updated instead of duplicated. A key that is
        missing from the section is added right below the section header; a
        missing section is appended at the end.
    #>
    param(
        [string]$Text,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if (-not $Text) { $Text = '' }
    $newline = if ($Text -match "`r`n" -or -not $Text) { "`r`n" } else { "`n" }
    $wanted = "$Key=$Value"
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`r?`n")) { $lines.Add($line) }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

    $headerIndex = -1
    $found = $false
    $changed = $false
    $current = $null
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*?)\s*$'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $header = [regex]::Match($lines[$i], '^\s*\[([^\]]*)\]\s*$')
        if ($header.Success) {
            $current = $header.Groups[1].Value.Trim()
            if ($headerIndex -lt 0 -and $current -eq $Section) { $headerIndex = $i }
            continue
        }
        if ($current -ne $Section) { continue }

        $entry = [regex]::Match($lines[$i], $keyPattern, 'IgnoreCase')
        if (-not $entry.Success) { continue }
        $found = $true
        if ($entry.Groups[1].Value -ne $Value) {
            $lines[$i] = $wanted
            $changed = $true
        }
    }

    if (-not $found) {
        $changed = $true
        if ($headerIndex -ge 0) {
            $lines.Insert($headerIndex + 1, $wanted)
        }
        else {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
            $lines.Add("[$Section]")
            $lines.Add($wanted)
        }
    }

    return [pscustomobject]@{
        Text    = ($lines -join $newline) + $newline
        Changed = $changed
    }
}

function Test-BootTaskTrigger {
    <#
    .SYNOPSIS
        Tells whether a registered task's triggers are the boot, logon and
        repeating triggers this script registers.
    .DESCRIPTION
        The repeating trigger must fire every IntervalMinutes with no
        repetition duration - an empty duration is how Task Scheduler stores
        "indefinitely". A task registered by v1.0.2 has only the boot and logon
        triggers and fails this check, so a re-run re-registers it.
    #>
    param(
        [object[]]$Trigger,
        [Parameter(Mandatory = $true)][int]$IntervalMinutes
    )

    $classes = @($Trigger | Where-Object { $_ } | ForEach-Object { $_.CimClass.CimClassName })
    if ($classes.Count -ne 3) { return $false }
    if (@($classes | Where-Object { $_ -eq 'MSFT_TaskBootTrigger' }).Count -ne 1) { return $false }
    if (@($classes | Where-Object { $_ -eq 'MSFT_TaskLogonTrigger' }).Count -ne 1) { return $false }

    $repeat = @($Trigger | Where-Object { $_ -and $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' })
    if ($repeat.Count -ne 1 -or -not $repeat[0].Repetition) { return $false }

    return ($repeat[0].Repetition.Interval -eq "PT${IntervalMinutes}M" -and -not $repeat[0].Repetition.Duration)
}

function New-ProvisionScriptText {
    <#
    .SYNOPSIS
        Builds the idempotent first-boot provisioning script that runs as root
        inside the distro.
    .DESCRIPTION
        Line endings are forced to LF so the script survives a CRLF checkout of
        this repository. The user name and public key are substituted literally
        into a double-quoted shell assignment, so both are validated here -
        anything that could close the quote is refused.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [string]$AuthorizedKey
    )

    if ($UserName -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw "UserName '$UserName' is not a plain Linux user name."
    }
    if ($AuthorizedKey -and $AuthorizedKey -match "[`r`n]") {
        throw 'AuthorizedKey must be a single line.'
    }
    if ($AuthorizedKey -and $AuthorizedKey -notmatch '^[A-Za-z0-9@:.,=+/ _-]+$') {
        throw 'AuthorizedKey may only hold public-key characters; quotes, backslashes and other shell metacharacters are refused.'
    }

    $template = @'
#!/bin/bash
# Provisions the distro far enough to be managed over SSH: a login user,
# openssh-server and a systemd-enabled /etc/wsl.conf. Idempotent.
set -euo pipefail

user="__USER__"
authorized_key="__AUTHORIZED_KEY__"
changed=0
restart_required=0
systemd_missing=0

if id -u "$user" >/dev/null 2>&1; then
    echo "[ok]      user $user exists"
else
    useradd --create-home --shell /bin/bash --groups sudo "$user"
    passwd --lock "$user" >/dev/null
    changed=$((changed + 1))
    echo "[changed] created user $user"
fi

# Named after the user, not the distro: sudo ignores drop-ins whose name
# contains a dot, and distro names often do. The user name cannot.
sudoers_file="/etc/sudoers.d/90-$user"
sudoers_line="$user ALL=(ALL) NOPASSWD:ALL"
if [ -f "$sudoers_file" ] && [ "$(cat "$sudoers_file")" = "$sudoers_line" ]; then
    echo "[ok]      $sudoers_file up to date"
else
    wanted_sudoers="$(mktemp)"
    printf '%s\n' "$sudoers_line" >"$wanted_sudoers"
    if command -v visudo >/dev/null 2>&1; then
        visudo -cf "$wanted_sudoers" >/dev/null
    fi
    install -m 0440 "$wanted_sudoers" "$sudoers_file"
    rm -f "$wanted_sudoers"
    changed=$((changed + 1))
    echo "[changed] wrote $sudoers_file"
fi

if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'ok installed'; then
    echo "[ok]      openssh-server installed"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openssh-server
    changed=$((changed + 1))
    echo "[changed] installed openssh-server"
fi

wsl_conf=/etc/wsl.conf
wanted_conf="$(mktemp)"
{
    printf '%s\n' '[boot]'
    printf '%s\n' 'systemd=true'
    printf '\n'
    printf '%s\n' '[user]'
    printf 'default=%s\n' "$user"
} >"$wanted_conf"
if cmp -s "$wanted_conf" "$wsl_conf"; then
    echo "[ok]      $wsl_conf up to date"
else
    install -m 0644 "$wanted_conf" "$wsl_conf"
    changed=$((changed + 1))
    restart_required=1
    echo "[changed] wrote $wsl_conf"
fi
rm -f "$wanted_conf"

if [ -n "$authorized_key" ]; then
    home_dir="$(getent passwd "$user" | cut -d: -f6)"
    group="$(id -gn "$user")"
    install -d -m 0700 -o "$user" -g "$group" "$home_dir/.ssh"
    if grep -qxF "$authorized_key" "$home_dir/.ssh/authorized_keys" 2>/dev/null; then
        echo "[ok]      authorized key present for $user"
    else
        printf '%s\n' "$authorized_key" >>"$home_dir/.ssh/authorized_keys"
        chown "$user:$group" "$home_dir/.ssh/authorized_keys"
        chmod 0600 "$home_dir/.ssh/authorized_keys"
        changed=$((changed + 1))
        echo "[changed] added authorized key for $user"
    fi
else
    echo "[warn]    no authorized key supplied - pass -AuthorizedKey to let an SSH client in"
fi

if [ -d /run/systemd/system ]; then
    if [ "$(systemctl is-enabled ssh 2>/dev/null || true)" = "enabled" ]; then
        echo "[ok]      ssh.service enabled"
    else
        systemctl enable ssh >/dev/null
        changed=$((changed + 1))
        echo "[changed] enabled ssh.service"
    fi
    if [ "$(systemctl is-active ssh 2>/dev/null || true)" = "active" ]; then
        echo "[ok]      ssh.service active"
    else
        systemctl start ssh
        changed=$((changed + 1))
        echo "[changed] started ssh.service"
    fi
else
    systemd_missing=1
    echo "[warn]    systemd is not running in this distro"
fi

echo "bootstrap-provision-changed=$changed"
if [ "$restart_required" -eq 1 ]; then
    echo "bootstrap-provision-restart-required=1"
fi
if [ "$systemd_missing" -eq 1 ]; then
    echo "bootstrap-provision-systemd-missing=1"
fi
'@

    $text = $template.Replace('__USER__', $UserName)
    $text = $text.Replace('__AUTHORIZED_KEY__', $AuthorizedKey)
    $text = ($text -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }

    return $text
}

#endregion

#region Windows / WSL primitives

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Runs a native executable and returns its exit code plus merged output.
    .DESCRIPTION
        ErrorActionPreference is relaxed for the call because with 2>&1 and a
        Stop preference PowerShell turns any stderr line into a terminating
        NativeCommandError, which would hide the real exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "$FilePath was not found on PATH."
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $text = (($raw | ForEach-Object { [string]$_ }) -join "`n") -replace "`0", ''

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
    }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$IgnoreExitCode
    )

    $result = Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments $Arguments
    if (-not $IgnoreExitCode -and $result.ExitCode -ne 0) {
        throw ("wsl.exe {0} failed (exit {1}): {2}" -f ($Arguments -join ' '), $result.ExitCode, $result.Output)
    }

    return $result.Output
}

function Invoke-Netsh {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $result = Invoke-NativeCommand -FilePath 'netsh.exe' -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw ("netsh.exe {0} failed (exit {1}): {2}" -f ($Arguments -join ' '), $result.ExitCode, $result.Output)
    }

    return $result.Output
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WslDistro {
    param([Parameter(Mandatory = $true)][string]$Name)

    $result = Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--list', '--quiet')
    if ($result.ExitCode -ne 0) { return $false }

    $names = foreach ($line in ($result.Output -split "`r?`n")) { $line.Trim() }

    return (@($names | Where-Object { $_ }) -contains $Name)
}

function Enable-WslFeature {
    <#
    .SYNOPSIS
        Enables the WSL2 Windows features. Returns $true when a reboot is
        pending before WSL can be used.
    #>
    param([Parameter(Mandatory = $true)][string[]]$FeatureName)

    $restartNeeded = $false
    foreach ($name in $FeatureName) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
        if ($feature.State -eq 'Enabled') {
            Write-Ok "Windows feature $name already enabled"
            continue
        }

        $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
        Write-Changed "enabled Windows feature $name"
        if ($result.RestartNeeded) { $restartNeeded = $true }
    }

    return $restartNeeded
}

function Update-WslRuntime {
    <#
    .SYNOPSIS
        Makes sure the host runs a WSL runtime that can serve WSL2 and systemd.
    .DESCRIPTION
        Enabling the Windows features alone leaves the inbox runtime in place:
        it has no WSL2 kernel and ignores "[boot] systemd=true". "wsl --update"
        installs the current runtime; a host that still reports no usable
        version afterwards needs the kernel package installed by hand.
    #>
    $version = Get-WslRuntimeVersion -Text (Invoke-Wsl -Arguments @('--version') -IgnoreExitCode)
    if ($version -and $version -ge $script:MinimumWslVersion) {
        Write-Ok "WSL runtime $version is current enough for systemd"
        return
    }

    Write-Line '    ...       updating the WSL runtime (wsl --update)'
    $update = Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--update')
    if ($update.ExitCode -ne 0) {
        throw ("wsl --update failed (exit {0}): {1}`n" -f $update.ExitCode, $update.Output) +
        'Install the WSL2 kernel update from https://aka.ms/wsl2kernel and run this script again.'
    }
    Write-Changed 'updated the WSL runtime'

    $version = Get-WslRuntimeVersion -Text (Invoke-Wsl -Arguments @('--version') -IgnoreExitCode)
    if (-not $version -or $version -lt $script:MinimumWslVersion) {
        throw ("This host still runs WSL runtime '{0}'; {1} or later is needed for systemd. " -f
            $version, $script:MinimumWslVersion) +
        'Install the current WSL from https://aka.ms/wsl2kernel (or the Microsoft Store) and run this script again.'
    }
    Write-Ok "WSL runtime $version supports systemd"
}

function Set-WslDefaultVersion {
    param([int]$Version = 2)

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $current = 0
    $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($item -and ($item.PSObject.Properties.Name -contains 'DefaultVersion')) {
        $current = [int]$item.DefaultVersion
    }

    if ($current -eq $Version) {
        Write-Ok "WSL default version is already $Version"
        return
    }

    Invoke-Wsl -Arguments @('--set-default-version', "$Version") | Out-Null
    Write-Changed "set WSL default version to $Version"
}

function Resolve-RootfsPath {
    <#
    .SYNOPSIS
        Returns the path of a rootfs tarball whose SHA256 matches the pin,
        downloading it into the cache directory when needed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$CacheRoot
    )

    $expected = $Sha256.ToUpperInvariant()

    if ($LocalPath) {
        if (-not (Test-Path -LiteralPath $LocalPath)) {
            throw "Rootfs tarball not found: $LocalPath"
        }
        Assert-FileHash -Path $LocalPath -Expected $expected
        Write-Ok "using supplied rootfs $LocalPath"
        return $LocalPath
    }

    $target = Join-Path $CacheRoot ([IO.Path]::GetFileName(([uri]$Url).LocalPath))
    if (Test-Path -LiteralPath $target) {
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $expected) {
            Write-Ok "cached rootfs $target matches the pinned checksum"
            return $target
        }
        Write-Line "    [warn]    cached rootfs $target does not match the pin - downloading again"
        Remove-Item -LiteralPath $target -Force
    }

    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    Write-Line "    ...       downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing
    try {
        Assert-FileHash -Path $target -Expected $expected
    }
    catch {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Changed "downloaded rootfs to $target"

    return $target
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected) {
        throw "SHA256 mismatch for $Path (expected $Expected, got $actual)"
    }
}

function Import-WslDistro {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [Parameter(Mandatory = $true)][string]$RootfsFile
    )

    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    Invoke-Wsl -Arguments @('--import', $Name, $InstallPath, $RootfsFile, '--version', '2') | Out-Null
    Write-Changed "imported distro $Name into $InstallPath"
}

function Get-WslIpAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$RetryCount = 1,
        [int]$RetryDelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $result = Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @(
            '-d', $Name, '-u', 'root', '--', 'ip', '-4', '-o', 'addr', 'show', 'dev', 'eth0')
        if ($result.ExitCode -eq 0) {
            $ip = Get-IPv4FromWslOutput -Text $result.Output
            if ($ip) { return $ip }
        }
        if ($attempt -lt $RetryCount) { Start-Sleep -Seconds $RetryDelaySeconds }
    }

    throw "Could not read an IPv4 address from $Name after $RetryCount attempt(s)."
}

#endregion

#region bootstrap steps

function Invoke-ProvisionPass {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$WindowsScriptPath
    )

    # --exec, not --: "wsl.exe -- <cmd>" hands the command line to the distro's
    # shell, which eats the backslashes of a Windows path (wslpath then sees
    # C:UsersaliceAppData...) and would split a Linux path that holds a space.
    # --exec runs the program directly with its arguments untouched.
    $linuxPath = (Invoke-Wsl -Arguments @('-d', $Name, '--exec', 'wslpath', '-a', $WindowsScriptPath)).Trim()
    $output = Invoke-Wsl -Arguments @('-d', $Name, '-u', 'root', '--exec', 'bash', $linuxPath)

    $result = Read-ProvisionResult -Output $output
    foreach ($line in $result.Lines) { Write-Line "    $line" }

    return $result
}

function Invoke-Provision {
    <#
    .SYNOPSIS
        Runs the first-boot provisioner inside the distro, restarting the distro
        once when /etc/wsl.conf was (re)written or when systemd is not up, so
        the second pass runs under systemd and can enable sshd.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$User,
        [string]$PublicKey
    )

    $scriptText = New-ProvisionScriptText -UserName $User -AuthorizedKey $PublicKey
    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) "bootstrap-provision-$Name.sh"
    [IO.File]::WriteAllText($scriptPath, $scriptText, (New-Object Text.UTF8Encoding($false)))

    try {
        $pass = Invoke-ProvisionPass -Name $Name -WindowsScriptPath $scriptPath
        $script:ChangeCount += $pass.Changed

        if ($pass.RestartRequired -or $pass.SystemdMissing) {
            $reason = if ($pass.RestartRequired) { 'to pick up /etc/wsl.conf' } else { 'to start systemd' }
            Invoke-Wsl -Arguments @('--terminate', $Name) | Out-Null
            Write-Changed "restarted $Name $reason"
            $pass = Invoke-ProvisionPass -Name $Name -WindowsScriptPath $scriptPath
            $script:ChangeCount += $pass.Changed
        }

        if ($pass.SystemdMissing) {
            throw ("systemd is still not running in $Name after a restart, so sshd cannot be enabled. " +
                'The WSL runtime is too old to honour "[boot] systemd=true" - run "wsl --update" and try again.')
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-SshPortProxy {
    param(
        [Parameter(Mandatory = $true)][int]$ListenPort,
        [Parameter(Mandatory = $true)][string]$ConnectAddress,
        [int]$ConnectPort = 22,
        [string]$ListenAddress = '0.0.0.0'
    )

    $existing = Get-PortProxyEntry -ListenPort $ListenPort -ListenAddress $ListenAddress `
        -Text (Invoke-Netsh -Arguments @('interface', 'portproxy', 'show', 'v4tov4'))
    if ($existing -and $existing.ConnectAddress -eq $ConnectAddress -and $existing.ConnectPort -eq $ConnectPort) {
        Write-Ok "portproxy :$ListenPort -> ${ConnectAddress}:$ConnectPort already set"
        return
    }

    if ($existing) {
        Invoke-Netsh -Arguments @('interface', 'portproxy', 'delete', 'v4tov4',
            "listenport=$ListenPort", "listenaddress=$ListenAddress") | Out-Null
    }

    Invoke-Netsh -Arguments @('interface', 'portproxy', 'add', 'v4tov4',
        "listenport=$ListenPort", "listenaddress=$ListenAddress",
        "connectport=$ConnectPort", "connectaddress=$ConnectAddress") | Out-Null
    Write-Changed "portproxy :$ListenPort -> ${ConnectAddress}:$ConnectPort"
}

function Set-SshFirewallRule {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if ($rule) {
        Write-Ok "firewall rule '$DisplayName' already present"
        return
    }

    New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -Profile Any | Out-Null
    Write-Changed "created firewall rule '$DisplayName' for TCP $Port"
}

function Set-WslIdleTimeout {
    <#
    .SYNOPSIS
        Makes .wslconfig say "[general] instanceIdleTimeout=-1", so WSL does
        not stop a distro once no wsl.exe is attached to it. Returns $true when
        the file was changed.
    .DESCRIPTION
        .wslconfig belongs to the Windows user, so the setting keeps every WSL
        distro of that user running. Other sections and keys are kept. The file
        is written as UTF-8 without a BOM.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $merge = Merge-WslConfigText -Text $text -Section 'general' -Key 'instanceIdleTimeout' -Value '-1'
    if (-not $merge.Changed) {
        Write-Ok "instanceIdleTimeout=-1 already set in $Path"
        return $false
    }

    [IO.File]::WriteAllText($Path, $merge.Text, (New-Object Text.UTF8Encoding($false)))
    Write-Changed "set [general] instanceIdleTimeout=-1 in $Path"
    return $true
}

function New-BootTaskTrigger {
    <#
    .SYNOPSIS
        Builds the boot task's triggers: at startup (30 s delay), at logon, and
        every BootRefreshIntervalMinutes indefinitely.
    .DESCRIPTION
        The repeating trigger leaves -RepetitionDuration unset: that is
        "indefinitely", while [TimeSpan]::MaxValue is rejected as out of range
        by Task Scheduler on Windows 10.
    #>
    param([Parameter(Mandatory = $true)][string]$UserId)

    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT30S'
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
        -RepetitionInterval (New-TimeSpan -Minutes $script:BootRefreshIntervalMinutes)

    return @($startup, $logon, $repeat)
}

function Install-BootTask {
    <#
    .SYNOPSIS
        Copies this script next to its log under InstallRoot and registers the
        scheduled task that re-runs it in BootRefresh mode at boot, at logon
        and every BootRefreshIntervalMinutes.
    .DESCRIPTION
        The installed copy makes the task independent of where the repository is
        checked out. The task runs as the user that registered the distro,
        because WSL distros are per-user and are invisible to SYSTEM.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][string]$DistroRoot,
        [Parameter(Mandatory = $true)][int]$Port
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $installed = Join-Path $Root 'bootstrap.ps1'
    if ($SourcePath -ne $installed) {
        $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        $installedHash = if (Test-Path -LiteralPath $installed) {
            (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
        }
        else { '' }
        if ($sourceHash -ne $installedHash) {
            Copy-Item -LiteralPath $SourcePath -Destination $installed -Force
            Write-Changed "installed boot-refresh copy at $installed"
        }
        else {
            Write-Ok "boot-refresh copy at $installed is current"
        }
    }

    $argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" ' -f $installed
    $argument += '-Mode BootRefresh -DistroName {0} -WslRoot "{1}" -SshPort {2} -InstallRoot "{3}"' -f `
        $Distro, $DistroRoot.TrimEnd('\'), $Port, $Root.TrimEnd('\')

    $userId = "$env:USERDOMAIN\$env:USERNAME"
    $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($existing -and @($existing.Actions).Count -eq 1 -and
        $existing.Actions[0].Arguments -eq $argument -and
        $existing.Principal.UserId -eq $userId -and
        (Test-BootTaskTrigger -Trigger @($existing.Triggers) -IntervalMinutes $script:BootRefreshIntervalMinutes)) {
        Write-Ok "scheduled task '$Name' already registered"
        return
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Highest
    # IgnoreNew: a repeat that comes due while a slow BootRefresh still runs is
    # skipped instead of starting a second copy.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $Name -Action $action -Principal $principal `
        -Trigger (New-BootTaskTrigger -UserId $userId) -Settings $settings -Force | Out-Null
    Write-Changed ("registered scheduled task '{0}' (boot + logon + every {1} min) as {2}" -f `
            $Name, $script:BootRefreshIntervalMinutes, $userId)
}

function Invoke-BootRefresh {
    <#
    .SYNOPSIS
        Starts the distro and repoints the portproxy at its current NAT address.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Port
    )

    Write-Step "Starting distro $Name"
    Invoke-Wsl -Arguments @('-d', $Name, '-u', 'root', '--', '/bin/true') | Out-Null
    Invoke-Wsl -Arguments @('-d', $Name, '-u', 'root', '--', 'systemctl', 'start', 'ssh') -IgnoreExitCode | Out-Null
    Write-Ok "distro $Name is running"

    Write-Step "Refreshing portproxy :$Port"
    $ip = Get-WslIpAddress -Name $Name -RetryCount 10 -RetryDelaySeconds 6
    Set-SshPortProxy -ListenPort $Port -ConnectAddress $ip
}

function Invoke-Bootstrap {
    if (-not $UserName) {
        throw 'Pass -UserName <name>: the login user to create inside the distro. It has no default.'
    }
    if ([Environment]::OSVersion.Version.Build -lt $script:MinimumBuild) {
        throw ("WSL2 needs Windows 10 build {0} or later; this host reports build {1}." -f `
                $script:MinimumBuild, [Environment]::OSVersion.Version.Build)
    }

    Write-Step 'Enabling WSL2 Windows features'
    if (Enable-WslFeature -FeatureName $script:WindowsFeatures) {
        Write-Line ''
        Write-Line 'REBOOT REQUIRED: the WSL features were just enabled.'
        Write-Line 'Reboot this host and run the script again to finish the setup.'
        exit 3010
    }
    Write-Step 'Checking the WSL runtime'
    Update-WslRuntime
    Set-WslDefaultVersion -Version 2

    # A changed .wslconfig only applies once WSL restarts. Shut WSL down now,
    # before the distro is imported and provisioned, so the rest of the run and
    # the box afterwards use the new setting without a reboot.
    Write-Step 'Keeping WSL distros running when no wsl.exe is attached'
    if (Set-WslIdleTimeout -Path (Join-Path $env:USERPROFILE '.wslconfig')) {
        Invoke-Wsl -Arguments @('--shutdown') | Out-Null
        Write-Changed 'stopped every WSL distro of this user (wsl --shutdown) to apply .wslconfig'
    }

    Write-Step "Importing distro $DistroName"
    $wslDrive = [IO.Path]::GetPathRoot($WslRoot)
    if ($wslDrive -and -not (Test-Path -LiteralPath $wslDrive)) {
        throw "WslRoot drive $wslDrive does not exist; pass -WslRoot <path> on an existing drive."
    }
    if (Test-WslDistro -Name $DistroName) {
        Write-Ok "distro $DistroName is already registered"
    }
    else {
        $rootfs = Resolve-RootfsPath -Url $RootfsUrl -Sha256 $RootfsSha256 -LocalPath $RootfsPath `
            -CacheRoot (Join-Path $WslRoot 'cache')
        Import-WslDistro -Name $DistroName -InstallPath (Join-Path $WslRoot $DistroName) -RootfsFile $rootfs
    }

    Write-Step "Provisioning $DistroName (user $UserName, openssh-server, systemd)"
    Invoke-Provision -Name $DistroName -User $UserName -PublicKey $AuthorizedKey

    Write-Step "Publishing sshd on TCP $SshPort"
    Set-SshPortProxy -ListenPort $SshPort -ConnectAddress (Get-WslIpAddress -Name $DistroName -RetryCount 5)
    Set-SshFirewallRule -DisplayName "$DistroName sshd (TCP $SshPort)" -Port $SshPort

    Write-Step "Registering boot task '$TaskName'"
    Install-BootTask -Name $TaskName -Root $InstallRoot -SourcePath $PSCommandPath `
        -Distro $DistroName -DistroRoot $WslRoot -Port $SshPort
}

function Invoke-Main {
    if (-not (Test-Administrator)) {
        throw 'bootstrap.ps1 must run from an elevated PowerShell session.'
    }

    if ($Mode -eq 'BootRefresh') {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
        $script:LogPath = Join-Path $InstallRoot 'boot-refresh.log'
        if ((Test-Path -LiteralPath $script:LogPath) -and
            (Get-Item -LiteralPath $script:LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogPath -Destination "$script:LogPath.old" -Force
        }
        try {
            Invoke-BootRefresh -Name $DistroName -Port $SshPort
        }
        catch {
            Write-Line "    [error]   $($_.Exception.Message)"
            throw
        }
    }
    else {
        Invoke-Bootstrap
    }

    Write-Line ''
    Write-Line "changed=$script:ChangeCount"
    if ($Mode -eq 'Bootstrap') {
        Write-Line "Connect with: ssh -p $SshPort $UserName@<this host>"
    }
}

#endregion

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
