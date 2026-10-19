# agentbox-bootstrap

[`bootstrap.ps1`](bootstrap.ps1) turns a fresh or rebuilt Windows 10 machine
into an SSH target: it imports a WSL2 Ubuntu 24.04 distro and publishes the
distro's sshd on a Windows port (`2222` by default). After it finishes, another
machine can reach the distro with `ssh -p 2222 <user>@<windows-host>` and take
it from there - by hand or with a configuration tool such as Ansible.

## Prerequisites

- Windows 10 version 2004 (build 19041) or later - WSL2 is not available before
  that, and the script refuses to run on older builds.
- An **elevated** PowerShell session (Windows PowerShell 5.1 is fine).
- Internet access: the script runs `wsl --update` when the host still has the
  inbox WSL runtime, and downloads the rootfs tarball (about 340 MB).
- The public SSH key of the machine that will connect, passed as
  `-AuthorizedKey`. Without it the distro comes up with no way in and the
  script says so.

## Usage

Download a tagged release rather than `main`, so the script you run is the one
you reviewed. The first line makes Windows PowerShell 5.1 offer TLS 1.2, which
GitHub requires and which older Windows 10 setups do not enable by default (the
script adds TLS 1.2 for its own downloads too, but leaves a SystemDefault
setting alone so the OS can still pick TLS 1.3):

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -OutFile bootstrap.ps1 `
    https://raw.githubusercontent.com/dddpaul/agentbox-bootstrap/v1.0.6/bootstrap.ps1
(Get-FileHash .\bootstrap.ps1 -Algorithm SHA256).Hash   # compare with the hash you expect

powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 `
    -UserName alice -AuthorizedKey "ssh-ed25519 AAAAC3Nza... alice@laptop"
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Mode` | `Bootstrap` | `BootRefresh` only restarts the distro and rewrites the portproxy; that is what the scheduled task runs. |
| `-UserName` | **none - required** | Login user created inside the distro; SSH clients connect as this user. Not needed in `BootRefresh` mode. |
| `-AuthorizedKey` | - | Public key installed into the new user's `~/.ssh/authorized_keys`; one line of plain key characters (no quotes or backslashes). |
| `-DistroName` | `ubuntu-ssh` | Name of the imported WSL distro. |
| `-WslRoot` | `%SystemDrive%\wsl` | Holds `<WslRoot>\<DistroName>` and the rootfs cache in `<WslRoot>\cache`. |
| `-SshPort` | `2222` | Windows-side port forwarded to the distro's sshd. |
| `-RootfsUrl` / `-RootfsSha256` | pinned Ubuntu 24.04 rootfs | Image to import and the checksum it must match. |
| `-RootfsPath` | - | Use an already downloaded tarball; it is still checksum-verified. |
| `-InstallRoot` | `%ProgramData%\<DistroName>` | Where the boot-refresh copy of the script and its log live. |
| `-TaskName` | `<DistroName>-boot` | Name of the registered scheduled task. |

## What it does

1. Enables the `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`
   Windows features and sets WSL default version 2. Features that are already
   enabled are left alone; when enabling them asks for a reboot, the script
   stops with exit code **3010** - reboot and run it again.
2. Brings the WSL runtime itself up to date. The runtime that comes with the
   Windows features has no WSL2 kernel and ignores `[boot] systemd=true`, so the
   script runs `wsl --update` whenever `wsl --version` reports less than
   **0.67.6**, and stops with a pointer to <https://aka.ms/wsl2kernel> if the
   host still reports an older runtime afterwards.

   It then makes sure `%UserProfile%\.wslconfig` holds:

   ```ini
   [general]
   instanceIdleTimeout=-1
   ```

   By default WSL stops a distro 15 s after the last `wsl.exe` attached to it
   exits, which would take sshd down with it. The key is merged into the
   file: other sections and keys stay as they are, and a file that already
   says `-1` is reported `[ok]`. `.wslconfig` belongs to the Windows user, so
   the setting keeps **every** WSL distro of that user running, not just this
   one - fine for a dedicated box, worth knowing on a shared one.

   A changed `.wslconfig` only takes effect once WSL restarts, so when the
   script has to write it, it runs `wsl --shutdown` right away - before the
   import and provisioning - which stops every running distro of the user. A
   re-run that finds the setting in place shuts nothing down.
3. Downloads the pinned Ubuntu 24.04 rootfs into `<WslRoot>\cache`, verifies its
   SHA256 and imports it with `wsl --import <DistroName> <WslRoot>\<DistroName>`.
   A tarball that does not match the pin is refused, never imported.
4. Provisions the distro as root: creates the login user (in `sudo`, with a
   locked password and a `NOPASSWD` drop-in `/etc/sudoers.d/90-<user>`),
   installs `openssh-server`, writes `/etc/wsl.conf` with `systemd=true` and the
   default user, installs the supplied public key, then enables and starts
   `ssh`. When `/etc/wsl.conf` had to be written - or the distro came up without
   systemd - it is terminated and the provisioner runs once more, so sshd is
   enabled under systemd. If systemd is still missing after that restart the
   run fails instead of reporting a box that has no sshd.

   The password is locked on purpose: the supplied key is the only way in over
   SSH, and `sudo` needs no password once you are in. A configuration tool that
   manages `/etc/wsl.conf` afterwards must render the same content, or every run
   reports it as changed:

   ```
   [boot]
   systemd=true

   [user]
   default=<user>
   ```
5. Adds `netsh interface portproxy` `:<SshPort> -> <wsl-ip>:22` and an inbound
   firewall rule `<DistroName> sshd (TCP <SshPort>)`.
6. Copies itself to `<InstallRoot>\bootstrap.ps1` and registers the
   `<TaskName>` scheduled task, which re-runs it in `BootRefresh` mode. A task
   left by an older version without the 5-minute trigger is re-registered.

## Idempotence

Every step prints `[ok]` when the host is already in the wanted state and
`[changed]` when it had to act, and the run ends with a `changed=N` line. A
second run of a finished host does nothing and prints `changed=0`:

```
==> Enabling WSL2 Windows features
    [ok]      Windows feature Microsoft-Windows-Subsystem-Linux already enabled
    [ok]      Windows feature VirtualMachinePlatform already enabled
    [ok]      WSL default version is already 2
...
changed=0
```

Nothing is re-downloaded either: the rootfs is only fetched when the distro is
missing, and a cached tarball that still matches the checksum is reused.

## Boot refresh

WSL2 on Windows 10 is NAT-only - mirrored networking is a Windows 11 feature -
so the distro gets a **new IP every time it starts** and a static portproxy
would point at nothing after a reboot. The scheduled task therefore runs
`bootstrap.ps1 -Mode BootRefresh` at startup (30 s delay), at logon and every
5 minutes, indefinitely: it starts the distro, makes sure `ssh` is up, reads
the current address and rewrites the portproxy only when it drifted.

The 5-minute repeat covers a distro that stops while Windows stays up: an
update of WSL from Windows Update stops WSL's processes, and so do a crash and
`wsl --shutdown`. Within 5 minutes the next run starts the distro again and
repoints the portproxy at its new address - so a distro you stop on purpose
comes back too; disable the task first if you need it down. On a running
distro a repeat changes nothing. A repeat that comes due while the previous
run is still going is skipped (`MultipleInstances IgnoreNew`).

The task runs as the user that registered the distro, with the highest
privileges and `S4U` logon - WSL distros are per-user, so a task running as
`SYSTEM` would not see the distro at all. Its log is
`<InstallRoot>\boot-refresh.log`; the repeats add a few lines every 5
minutes, and the log is rotated to `boot-refresh.log.old` past 1 MB.

Run it by hand after a suspicious boot:

```powershell
Start-ScheduledTask -TaskName <DistroName>-boot
netsh interface portproxy show v4tov4
```

## Verify

```powershell
wsl -d <DistroName> -- systemctl is-active ssh   # active
netsh interface portproxy show v4tov4            # 0.0.0.0 2222 -> <wsl-ip> 22
```

Then, from the other machine: `ssh -p 2222 <user>@<windows-host>`. The sshd host
key at this point is the one `apt` generated when it installed
`openssh-server`.

## Recreate

Deleting the distro and running the script again restores the Windows side:

```powershell
wsl --unregister <DistroName>
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -UserName <user> -AuthorizedKey "ssh-ed25519 ..."
```

## Re-pinning the rootfs

The default image is the dated Ubuntu release
`https://cloud-images.ubuntu.com/wsl/releases/24.04/20240423/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz`,
a dated directory rather than `current/`, so the pin does not move under you.
To move to a newer image, pick the release directory, read its `SHA256SUMS`, and
update both `-RootfsUrl` and `-RootfsSha256` defaults in the script (or pass
them on the command line for a one-off).

## Tests

`tests/Test-Bootstrap.ps1` runs anywhere PowerShell 5.1+ is available (`pwsh`
on Linux/macOS included): it parse-checks `bootstrap.ps1`, checks its parameter
defaults, unit-tests the WSL-address and portproxy parsers, the `.wslconfig`
merge and the boot task's trigger check (against stubbed ScheduledTasks
cmdlets), and `bash -n`-checks
the provisioning script that is generated for the distro.

```powershell
pwsh -NoProfile -File tests/Test-Bootstrap.ps1
```

The steps that need a real Windows host - enabling the features, importing the
distro, `apt-get`, netsh, the firewall rule and the scheduled task - are
verified by running the script on one.

## License

[MIT](LICENSE)
