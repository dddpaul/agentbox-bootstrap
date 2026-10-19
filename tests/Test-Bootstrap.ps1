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
    # A stand-in for Invoke-Wsl, visible to Invoke-ProvisionPass while this
    # case runs: it records each argument array and answers like wsl.exe.
    $calls = [Collections.Generic.List[object]]::new()
    function Invoke-Wsl {
        param([string[]]$Arguments, [switch]$IgnoreExitCode)
        $calls.Add($Arguments)
        if ($Arguments -contains 'wslpath') { return "/mnt/c/Users/alice/My Files/provision.sh`n" }
        return 'bootstrap-provision-changed=0'
    }

    $windowsPath = 'C:\Users\alice\My Files\provision.sh'
    Invoke-ProvisionPass -Name 'agentbox' -WindowsScriptPath $windowsPath | Out-Null

    Assert-Equal 2 $calls.Count 'Invoke-ProvisionPass should call wsl.exe twice'
    Assert-Equal ('-d|agentbox|--exec|wslpath|-a|' + $windowsPath) ($calls[0] -join '|') `
        'wslpath must run via --exec, or the shell eats the backslashes of the Windows path'
    Assert-Equal '-d|agentbox|-u|root|--exec|bash|/mnt/c/Users/alice/My Files/provision.sh' ($calls[1] -join '|') `
        'the provisioner must run via --exec with the Linux path as one argument, or a path with a space is split'
}

Test-Case '.wslconfig: a missing file gets [general] instanceIdleTimeout=-1' {
    $merge = Merge-WslConfigText -Text $null -Section 'general' -Key 'instanceIdleTimeout' -Value '-1'
    Assert-True $merge.Changed 'an empty file must be reported as changed'
    Assert-Equal "[general]`r`ninstanceIdleTimeout=-1`r`n" $merge.Text 'wrong text for a new file'
}

Test-Case '.wslconfig: a file without [general] keeps its sections and gains one' {
    $text = "[wsl2]`r`nmemory=8GB`r`nswap=0`r`n"
    $merge = Merge-WslConfigText -Text $text -Section 'general' -Key 'instanceIdleTimeout' -Value '-1'
    Assert-True $merge.Changed 'the file must be reported as changed'
    Assert-Equal "[wsl2]`r`nmemory=8GB`r`nswap=0`r`n`r`n[general]`r`ninstanceIdleTimeout=-1`r`n" $merge.Text 'wrong merged text'
}

Test-Case '.wslconfig: [general] with another key keeps that key and the next section' {
    $text = "# box settings`n[general]`nguiApplications=false`n`n[wsl2]`nmemory=8GB`n"
    $merge = Merge-WslConfigText -Text $text -Section 'general' -Key 'instanceIdleTimeout' -Value '-1'
    Assert-True $merge.Changed 'the file must be reported as changed'
    Assert-Equal "# box settings`n[general]`ninstanceIdleTimeout=-1`nguiApplications=false`n`n[wsl2]`nmemory=8GB`n" $merge.Text 'wrong merged text (LF endings must be kept)'
}

Test-Case '.wslconfig: another value of the key is replaced in place, whatever its case' {
    $text = "[General]`r`ninstanceidletimeout = 15000`r`n[wsl2]`r`ninstanceIdleTimeout=7`r`n"
    $merge = Merge-WslConfigText -Text $text -Section 'general' -Key 'instanceIdleTimeout' -Value '-1'
    Assert-True $merge.Changed 'the file must be reported as changed'
    Assert-Equal "[General]`r`ninstanceIdleTimeout=-1`r`n[wsl2]`r`ninstanceIdleTimeout=7`r`n" $merge.Text 'only the [general] key may change'
}

Test-Case '.wslconfig: a value already -1 leaves the text alone' {
    $text = "[wsl2]`r`nmemory=8GB`r`n[general]`r`ninstanceIdleTimeout=-1`r`n"
    $merge = Merge-WslConfigText -Text $text -Section 'general' -Key 'instanceIdleTimeout' -Value '-1'
    Assert-True (-not $merge.Changed) 'an already set value must not be reported as changed'
    Assert-Equal $text $merge.Text 'the text must be unchanged'
}

Test-Case '.wslconfig file: written when missing, then reported [ok] on a re-run' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("wslconfig-test-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir '.wslconfig'
    $savedCount = $script:ChangeCount
    try {
        Assert-True (Set-WslIdleTimeout -Path $path) 'the first run must change the file'
        Assert-Equal "[general]`r`ninstanceIdleTimeout=-1`r`n" ([IO.File]::ReadAllText($path)) 'wrong file content'
        Assert-True (-not (Set-WslIdleTimeout -Path $path)) 'the second run must report [ok]'
        Assert-Equal ($savedCount + 1) $script:ChangeCount 'exactly one change must be counted'

        [IO.File]::WriteAllText($path, "[wsl2]`nmemory=4GB`n")
        Assert-True (Set-WslIdleTimeout -Path $path) 'a file without the key must change'
        Assert-Equal "[wsl2]`nmemory=4GB`n`n[general]`ninstanceIdleTimeout=-1`n" ([IO.File]::ReadAllText($path)) 'other keys must survive'
    }
    finally {
        $script:ChangeCount = $savedCount
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Stand-ins for the ScheduledTasks cmdlets, which exist only on Windows: they
# build trigger objects shaped like the CIM instances Task Scheduler returns
# and record what Register-ScheduledTask receives.
function New-FakeTrigger {
    param([string]$Class, [string]$Interval, [string]$Duration)

    return [pscustomobject]@{
        CimClass   = [pscustomobject]@{ CimClassName = $Class }
        Delay      = $null
        Repetition = [pscustomobject]@{ Interval = $Interval; Duration = $Duration }
    }
}

function New-ScheduledTaskTrigger {
    param([switch]$AtStartup, [switch]$AtLogOn, [string]$User, [switch]$Once, $At, [TimeSpan]$RepetitionInterval)

    if ($AtStartup) { return New-FakeTrigger -Class 'MSFT_TaskBootTrigger' }
    if ($AtLogOn) { return New-FakeTrigger -Class 'MSFT_TaskLogonTrigger' }
    return New-FakeTrigger -Class 'MSFT_TaskTimeTrigger' -Interval ('PT{0}M' -f $RepetitionInterval.TotalMinutes)
}

function New-ScheduledTaskAction { param($Execute, $Argument) [pscustomobject]@{ Arguments = $Argument } }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [pscustomobject]@{ UserId = $UserId } }
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable,
        $ExecutionTimeLimit, [string]$MultipleInstances)
    [pscustomobject]@{ MultipleInstances = $MultipleInstances }
}
function Get-ScheduledTask { param($TaskName, $ErrorAction) $script:FakeTask }
function Register-ScheduledTask {
    param($TaskName, $Action, $Principal, $Trigger, $Settings, [switch]$Force)
    $script:Registered = [pscustomobject]@{ Action = $Action; Principal = $Principal; Trigger = @($Trigger); Settings = $Settings }
}

function Invoke-FakeBootTaskInstall {
    <# Runs Install-BootTask against the stubs; returns the change count it added. #>
    param($ExistingTask)

    # A fixed root: the action arguments embed it and must match across calls.
    $root = Join-Path ([IO.Path]::GetTempPath()) 'boot-task-test'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $source = Join-Path $root 'bootstrap.ps1'
    Set-Content -LiteralPath $source -Value '# copy'
    $script:FakeTask = $ExistingTask
    $script:Registered = $null
    $savedCount = $script:ChangeCount
    try {
        Install-BootTask -Name 'agentbox-boot' -Root $root -SourcePath $source -Distro 'agentbox' `
            -DistroRoot 'C:\wsl' -Port 2222
        return $script:ChangeCount - $savedCount
    }
    finally {
        $script:ChangeCount = $savedCount
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-FakeExistingTask {
    <# A registered task whose action and principal match, built from what a fresh install registered. #>
    param([object[]]$Trigger)

    return [pscustomobject]@{
        Actions   = @($script:Registered.Action)
        Principal = $script:Registered.Principal
        Triggers  = $Trigger
    }
}

Test-Case 'boot task is registered with boot, logon and a 5-minute indefinite repeat, IgnoreNew' {
    Assert-Equal 1 (Invoke-FakeBootTaskInstall -ExistingTask $null) 'a fresh install must count one change'
    Assert-True ($null -ne $script:Registered) 'Register-ScheduledTask was not called'
    $classes = @($script:Registered.Trigger | ForEach-Object { $_.CimClass.CimClassName })
    Assert-Equal 'MSFT_TaskBootTrigger,MSFT_TaskLogonTrigger,MSFT_TaskTimeTrigger' ($classes -join ',') 'wrong triggers'
    Assert-Equal 'PT30S' $script:Registered.Trigger[0].Delay 'the boot trigger lost its delay'
    Assert-Equal 'PT5M' $script:Registered.Trigger[2].Repetition.Interval 'wrong repetition interval'
    Assert-True (-not $script:Registered.Trigger[2].Repetition.Duration) 'the repetition must have no duration (indefinitely)'
    Assert-Equal 'IgnoreNew' $script:Registered.Settings.MultipleInstances 'wrong MultipleInstances'
    Assert-True (Test-BootTaskTrigger -Trigger $script:Registered.Trigger -IntervalMinutes 5) 'the registered triggers must pass the existing-task check'
}

Test-Case 'boot task with only boot and logon triggers is re-registered with all three' {
    Invoke-FakeBootTaskInstall -ExistingTask $null | Out-Null
    $old = New-FakeExistingTask -Trigger @(
        (New-FakeTrigger -Class 'MSFT_TaskBootTrigger'), (New-FakeTrigger -Class 'MSFT_TaskLogonTrigger'))
    Assert-Equal 1 (Invoke-FakeBootTaskInstall -ExistingTask $old) 'a v1.0.2 task must be reported [changed]'
    Assert-True ($null -ne $script:Registered) 'the v1.0.2 task was not re-registered'
    Assert-Equal 3 @($script:Registered.Trigger).Count 'the re-registered task must carry three triggers'
}

Test-Case 'boot task with all three triggers is left alone' {
    Invoke-FakeBootTaskInstall -ExistingTask $null | Out-Null
    $current = New-FakeExistingTask -Trigger $script:Registered.Trigger
    Assert-Equal 0 (Invoke-FakeBootTaskInstall -ExistingTask $current) 'a current task must be reported [ok]'
    Assert-True ($null -eq $script:Registered) 'a current task must not be re-registered'
}

Test-Case 'boot task trigger check rejects a wrong interval or a finite repetition' {
    $boot = New-FakeTrigger -Class 'MSFT_TaskBootTrigger'
    $logon = New-FakeTrigger -Class 'MSFT_TaskLogonTrigger'
    Assert-True (-not (Test-BootTaskTrigger -Trigger @($boot, $logon, (New-FakeTrigger -Class 'MSFT_TaskTimeTrigger' -Interval 'PT10M')) -IntervalMinutes 5)) 'a 10-minute repeat must not pass'
    Assert-True (-not (Test-BootTaskTrigger -Trigger @($boot, $logon, (New-FakeTrigger -Class 'MSFT_TaskTimeTrigger' -Interval 'PT5M' -Duration 'P1D')) -IntervalMinutes 5)) 'a one-day repetition must not pass'
    Assert-True (-not (Test-BootTaskTrigger -Trigger @($boot, $logon, $logon) -IntervalMinutes 5)) 'a missing repeat must not pass'
    Assert-True (-not (Test-BootTaskTrigger -Trigger @() -IntervalMinutes 5)) 'no triggers must not pass'
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
