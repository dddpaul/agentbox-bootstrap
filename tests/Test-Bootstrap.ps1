<#
.SYNOPSIS
    Checks bootstrap.ps1 without a Windows host: parse, pure helpers and the
    generated in-distro provisioning script.

.DESCRIPTION
    Runs on any platform with PowerShell 5.1+ (pwsh on Linux/macOS is enough).
    The Windows-only steps of bootstrap.ps1 are not exercised here - dot-sourcing
    the script only defines its functions, it never calls Invoke-Main.

.EXAMPLE
    pwsh -NoProfile -File tests/Test-Bootstrap.ps1
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$script:Failures = 0
$bootstrap = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'bootstrap.ps1'

function Test-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        & $Body
        Write-Information "PASS  $Name"
    }
    catch {
        $script:Failures++
        Write-Information "FAIL  $Name - $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) { throw "$Message (expected '$Expected', got '$Actual')" }
}

Test-Case 'bootstrap.ps1 parses with no errors' {
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True (@($errors).Count -eq 0) "parser reported: $(($errors | ForEach-Object { $_.Message }) -join '; ')"
}

. $bootstrap

Test-Case 'WSL IPv4 is read from "ip -4 -o addr show" output' {
    $sample = "2: eth0    inet 172.20.114.3/20 brd 172.20.127.255 scope global eth0\       valid_lft forever preferred_lft forever"
    Assert-Equal '172.20.114.3' (Get-IPv4FromWslOutput -Text $sample) 'wrong address'
}

Test-Case 'WSL IPv4 ignores output that carries no inet line' {
    Assert-True ($null -eq (Get-IPv4FromWslOutput -Text '')) 'empty output should give $null'
    Assert-True ($null -eq (Get-IPv4FromWslOutput -Text 'no address here')) 'garbage should give $null'
    Assert-True ($null -eq (Get-IPv4FromWslOutput -Text 'WSL version: 2.0.9.0')) 'a version banner is not an address'
    Assert-True ($null -eq (Get-IPv4FromWslOutput -Text '172.31.4.7 ')) 'a bare quad is not an inet line'
}

Test-Case 'WSL IPv4 skips a quad with an out-of-range octet' {
    Assert-True ($null -eq (Get-IPv4FromWslOutput -Text 'inet 999.1.1.1/20')) '999 is not an octet'
    Assert-Equal '10.0.0.4' (Get-IPv4FromWslOutput -Text "inet 300.1.1.1/20`ninet 10.0.0.4/20") 'should fall through to the valid quad'
}

Test-Case 'WSL runtime version is read from "wsl --version"' {
    Assert-Equal ([version]'2.0.9.0') (Get-WslRuntimeVersion -Text "WSL version: 2.0.9.0`nKernel version: 5.15.133.1-1") 'wrong version'
    Assert-True ($null -eq (Get-WslRuntimeVersion -Text '')) 'the inbox runtime prints no version'
    Assert-True ((Get-WslRuntimeVersion -Text 'WSL version: 2.0.9.0') -ge [version]'0.67.6') 'should satisfy the systemd floor'
}

$netshSample = @'
Listen on ipv4:             Connect to ipv4:

Address         Port        Address         Port
--------------- ----------  --------------- ----------
0.0.0.0         2222        172.20.114.3    22
127.0.0.1       2222        10.9.9.9        22
0.0.0.0         8080        172.20.114.3    80
'@

Test-Case 'portproxy row is found for the listening port' {
    $entry = Get-PortProxyEntry -Text $netshSample -ListenPort 2222
    Assert-True ($null -ne $entry) 'no row returned'
    Assert-Equal '0.0.0.0' $entry.ListenAddress 'wrong listen address'
    Assert-Equal '172.20.114.3' $entry.ConnectAddress 'wrong connect address'
    Assert-Equal 22 $entry.ConnectPort 'wrong connect port'
}

Test-Case 'portproxy lookup keeps foreign listen addresses apart' {
    $ours = Get-PortProxyEntry -Text $netshSample -ListenPort 2222 -ListenAddress '0.0.0.0'
    Assert-Equal '172.20.114.3' $ours.ConnectAddress 'wrong row for 0.0.0.0'
    $loopback = Get-PortProxyEntry -Text $netshSample -ListenPort 2222 -ListenAddress '127.0.0.1'
    Assert-Equal '10.9.9.9' $loopback.ConnectAddress 'wrong row for 127.0.0.1'
    $missing = Get-PortProxyEntry -Text $netshSample -ListenPort 8080 -ListenAddress '127.0.0.1'
    Assert-True ($null -eq $missing) 'a port on another listen address is not ours'
}

Test-Case 'portproxy lookup ignores headers and unknown ports' {
    Assert-True ($null -eq (Get-PortProxyEntry -Text $netshSample -ListenPort 2200)) 'unknown port should give $null'
    Assert-True ($null -eq (Get-PortProxyEntry -Text '' -ListenPort 2222)) 'empty output should give $null'
}

Test-Case 'provision script carries the user, sshd and systemd settings' {
    $text = New-ProvisionScriptText -UserName 'alice' -AuthorizedKey 'ssh-ed25519 AAAATEST alice@laptop'
    Assert-True ($text -notmatch "`r") 'script must use LF line endings'
    Assert-True ($text -match 'user="alice"') 'user name was not substituted'
    Assert-True ($text -match 'useradd --create-home') 'user is not created'
    Assert-True ($text -match 'apt-get install -y -qq openssh-server') 'openssh-server is not installed'
    Assert-True ($text -match 'systemd=true') '/etc/wsl.conf does not enable systemd'
    Assert-True ($text -match 'authorized_key="ssh-ed25519 AAAATEST alice@laptop"') 'public key was not substituted'
    Assert-True ($text -match 'bootstrap-provision-changed=') 'change marker is missing'
}

Test-Case 'provision script is still generated without a public key' {
    $text = New-ProvisionScriptText -UserName 'alice'
    Assert-True ($text -match 'authorized_key=""') 'the key slot should be empty'
    Assert-True ($text -match 'no authorized key supplied') 'the missing key should be reported'
}

Test-Case 'provision script rejects a multi-line authorized key' {
    try {
        New-ProvisionScriptText -UserName 'alice' -AuthorizedKey "ssh-ed25519 AAAA`nrm -rf /" | Out-Null
        throw 'a multi-line key was accepted'
    }
    catch [System.Management.Automation.RuntimeException] {
        Assert-True ($_.Exception.Message -match 'single line') "unexpected error: $($_.Exception.Message)"
    }
}

Test-Case 'provision script rejects a key with shell metacharacters' {
    try {
        New-ProvisionScriptText -UserName 'alice' -AuthorizedKey 'ssh-ed25519 AAAA" ; rm -rf /' | Out-Null
        throw 'a quoted key was accepted'
    }
    catch [System.Management.Automation.RuntimeException] {
        Assert-True ($_.Exception.Message -match 'public-key characters') "unexpected error: $($_.Exception.Message)"
    }
}

Test-Case 'provision script rejects a user name that breaks out of the quotes' {
    try {
        New-ProvisionScriptText -UserName 'alice"; touch /tmp/pwn; #' | Out-Null
        throw 'an injecting user name was accepted'
    }
    catch [System.Management.Automation.RuntimeException] {
        Assert-True ($_.Exception.Message -match 'plain Linux user name') "unexpected error: $($_.Exception.Message)"
    }
}

Test-Case 'provisioner output yields the change count and the restart flag' {
    $output = @'
[ok]      user alice exists
[changed] wrote /etc/wsl.conf
bootstrap-provision-changed=2
bootstrap-provision-restart-required=1
'@
    $result = Read-ProvisionResult -Output $output
    Assert-Equal 2 $result.Changed 'wrong change count'
    Assert-True $result.RestartRequired 'restart flag was not picked up'
    Assert-True (-not $result.SystemdMissing) 'systemd was not reported missing'
    Assert-Equal 2 @($result.Lines).Count 'marker lines must not be reported'
}

Test-Case 'provisioner reports a missing systemd apart from a wsl.conf rewrite' {
    $output = @'
[ok]      /etc/wsl.conf up to date
[warn]    systemd is not running in this distro
bootstrap-provision-changed=0
bootstrap-provision-systemd-missing=1
'@
    $result = Read-ProvisionResult -Output $output
    Assert-Equal 0 $result.Changed 'wrong change count'
    Assert-True (-not $result.RestartRequired) 'a missing systemd is not a wsl.conf rewrite'
    Assert-True $result.SystemdMissing 'the systemd marker was not picked up'
}

Test-Case 'provisioner output without markers needs no restart' {
    $result = Read-ProvisionResult -Output "[ok]      user alice exists`nbootstrap-provision-changed=0"
    Assert-Equal 0 $result.Changed 'wrong change count'
    Assert-True (-not $result.RestartRequired) 'restart must not be required'
    Assert-Equal 1 @($result.Lines).Count 'wrong number of reported lines'
}

Test-Case 'an unreadable change marker is reported, not thrown' {
    $result = Read-ProvisionResult -Output 'bootstrap-provision-changed=abc'
    Assert-Equal 0 $result.Changed 'a broken marker must not change the count'
    Assert-True ((@($result.Lines) -join "`n") -match 'unreadable change marker') 'the broken marker should be reported'
}

Test-Case 'defaults are neutral and derive from the distro name' {
    $params = (Get-Command $bootstrap).Parameters
    Assert-True ($params.ContainsKey('UserName')) 'UserName parameter is missing'
    Assert-True (-not $params['UserName'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })) 'UserName must not be mandatory, or BootRefresh could not run without it'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$null, [ref]$null)
    $defaults = @{}
    foreach ($p in $ast.ParamBlock.Parameters) {
        $defaults[$p.Name.VariablePath.UserPath] = if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { $null }
    }
    Assert-True ($null -eq $defaults['UserName']) "UserName must have no default, got $($defaults['UserName'])"
    Assert-Equal "'ubuntu-ssh'" $defaults['DistroName'] 'wrong DistroName default'
    Assert-Equal '"$env:SystemDrive\wsl"' $defaults['WslRoot'] 'wrong WslRoot default'
    Assert-Equal '"$env:ProgramData\$DistroName"' $defaults['InstallRoot'] 'InstallRoot must derive from DistroName'
    Assert-Equal '"$DistroName-boot"' $defaults['TaskName'] 'TaskName must derive from DistroName'
}

Test-Case 'Bootstrap mode refuses to run without -UserName' {
    $saved = $UserName
    $UserName = $null
    try {
        Invoke-Bootstrap
        throw 'Invoke-Bootstrap ran without a user name'
    }
    catch [System.Management.Automation.RuntimeException] {
        Assert-True ($_.Exception.Message -match '-UserName') "unexpected error: $($_.Exception.Message)"
    }
    finally {
        $UserName = $saved
    }
}

Test-Case 'provision script names the sudoers drop-in after the user' {
    $text = New-ProvisionScriptText -UserName 'alice'
    Assert-True ($text -match 'sudoers_file="/etc/sudoers.d/90-\$user"') 'sudoers drop-in should be named after the user'
}

Test-Case 'the provisioner runs wslpath and bash via --exec, not through a shell' {
    $body = (Get-Command Invoke-ProvisionPass).ScriptBlock.ToString()
    Assert-True ($body -match "'--exec', 'wslpath'") 'wslpath must run via --exec, or the shell eats the backslashes of the Windows path'
    Assert-True ($body -match "'--exec', 'bash'") 'the provisioner must run via --exec, or a Linux path with a space is split'
    Assert-True ($body -notmatch "'--', '") 'no wsl.exe call in Invoke-ProvisionPass may go through "--" (the shell)'
}

Test-Case 'provision script is valid bash' {
    if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Information '      (skipped: bash is not available)'
        return
    }
    $path = Join-Path ([IO.Path]::GetTempPath()) 'bootstrap-provision-test.sh'
    $text = New-ProvisionScriptText -UserName 'alice' -AuthorizedKey 'ssh-ed25519 AAAATEST alice@laptop'
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
    try {
        $output = & bash -n $path 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "bash -n failed: $output"
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Write-Information ''
if ($script:Failures -gt 0) {
    Write-Information "$script:Failures test(s) failed"
    exit 1
}
Write-Information 'all tests passed'
