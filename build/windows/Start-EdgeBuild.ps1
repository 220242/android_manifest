#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds the Khadas Edge1 Android TV 14 ROM on a Windows host, via WSL2.

.DESCRIPTION
    AOSP cannot be compiled on Windows. There is no Windows host toolchain in
    prebuilts/, the build needs POSIX permissions, symlinks and ext4 image
    generation, and Android Studio is an application IDE with no role in a
    platform build. So this script does not build anything itself: it prepares a
    WSL2 Ubuntu environment and runs the Linux build scripts inside it.

    The important detail is WHERE the tree goes. It must NOT sit on the NTFS
    volume, even though that is the 2TB drive:

      1. NTFS is case-insensitive. AOSP contains files whose names differ only
         by case; on NTFS they collapse into one and the build fails in ways
         that look like corrupted source.
      2. The \\wsl.localhost / drvfs bridge to /mnt/* is 10-50x slower for the
         millions of small file operations a sync and build perform. A 5-hour
         build becomes a multi-day one.

    The 2TB drive is still used for all of it: the script places the WSL distro's
    own virtual disk (ext4 inside) on that drive, so the tree is on the SSD and
    case-sensitive and fast at the same time.

.PARAMETER Root
    Windows directory for the distro image, logs and output. Default D:\android_khadas.

.PARAMETER Stage
    Run a single stage instead of all of them. Stages run in this order:
    Check, Wsl, Distro, Tune, Provision, Sync, Kernel, Build.

.PARAMETER Force
    Re-run a stage that the state file records as already complete.

.EXAMPLE
    .\Start-EdgeBuild.ps1
    Runs every stage, resuming from wherever the last run stopped.

.EXAMPLE
    .\Start-EdgeBuild.ps1 -Stage Build
    Rebuilds the platform only.

.NOTES
    This script was authored on a Linux host with no PowerShell available, so its
    syntax has NOT been executed or parse-checked. Read it before running it as
    Administrator. Every destructive step (unregistering a distro, deleting the
    image directory) prompts unless -Force is given.
#>
[CmdletBinding()]
param(
    [string] $Root = 'D:\android_khadas',

    [ValidateSet('All','Check','Wsl','Distro','Tune','Provision','Sync','Kernel','Build')]
    [string] $Stage = 'All',

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Without this, wsl.exe emits UTF-16LE and every piped string comparison in this
# script silently fails to match. This is the single most common cause of
# PowerShell/WSL scripts misbehaving.
$env:WSL_UTF8 = '1'

$script:DistroName = 'Edge1Build'
$script:RepoUrl    = 'https://github.com/220242/android_manifest'
$script:RepoBranch = 'claude/determined-johnson-fwwaig'
$script:RootFsUrl  = 'https://cloud-images.ubuntu.com/wsl/jammy/current/ubuntu-jammy-wsl-amd64-wsl.rootfs.tar.gz'
$script:StatePath  = Join-Path $Root '.build-state.json'

# Disk: ~120GiB checkout + ~150GiB output, plus the rootfs and logs.
$script:RequiredGiB = 320

#region helpers ---------------------------------------------------------------

function Write-Stage { param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkGray
}
function Write-Info { param([string] $Text) Write-Host "  $Text" }
function Write-Good { param([string] $Text) Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Warn2 { param([string] $Text) Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string] $Text) Write-Host "  [fail] $Text" -ForegroundColor Red }

function Get-State {
    if (Test-Path -LiteralPath $script:StatePath) {
        try { return Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json }
        catch { Write-Warn2 'state file is unreadable, starting fresh'; }
    }
    return [pscustomobject]@{ completed = @() }
}
function Test-Done { param([string] $Name)
    if ($Force) { return $false }
    return ((Get-State).completed -contains $Name)
}
function Set-Done { param([string] $Name)
    $s = Get-State
    if ($s.completed -notcontains $Name) {
        $s.completed = @($s.completed) + $Name
    }
    $s | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

# wsl.exe does not set a useful exit code for every failure mode, so callers
# check output as well. This wrapper makes a non-zero exit fatal by default.
function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )
    Write-Verbose "wsl.exe $($Arguments -join ' ')"
    # Out-Host, not bare invocation: otherwise wsl's stdout becomes part of this
    # function's return value and callers reading the exit code get an array.
    & wsl.exe @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "wsl.exe $($Arguments -join ' ') exited with $code"
    }
    return $code
}

# Runs a bash command inside the distro as the build user. -lc so the login
# profile (PATH, ccache) is loaded.
function Invoke-InDistro {
    param(
        [Parameter(Mandatory)][string] $Command,
        [switch] $AsRoot,
        [switch] $AllowFailure
    )
    # Not $args: that is a reserved automatic variable inside a function.
    $wslArgs = @('-d', $script:DistroName)
    if ($AsRoot) { $wslArgs += @('-u','root') }
    $wslArgs += @('--','bash','-lc', $Command)
    return (Invoke-Wsl -Arguments $wslArgs -AllowFailure:$AllowFailure)
}

#endregion

#region stages ----------------------------------------------------------------

function Stage-Check {
    Write-Stage 'Stage 1/8  Host checks'

    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int] (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    Write-Info "$($os.Caption), build $build"
    if ($build -lt 19041) {
        Write-Bad "WSL2 needs Windows 10 build 19041 (2004) or newer; this is $build."
        throw 'Windows is too old for WSL2.'
    }
    Write-Good "Windows build $build supports WSL2"

    # Virtualization. WSL2 is a lightweight VM and silently fails to start
    # without it; the error it gives is unhelpful, so check here.
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.HypervisorPresent) {
        Write-Good 'hypervisor present'
    } else {
        Write-Warn2 'no hypervisor detected. If WSL2 fails to start, enable'
        Write-Warn2 'Intel VT-x / AMD-V in firmware and the "Virtual Machine'
        Write-Warn2 'Platform" Windows feature.'
    }

    $ramGiB = [math]::Floor($cs.TotalPhysicalMemory / 1GB)
    Write-Info "RAM: ${ramGiB} GiB"
    if ($ramGiB -lt 16) {
        Write-Warn2 "below Android 14's 16 GiB minimum. The Tune stage will"
        Write-Warn2 'configure a large swap file, but expect a slow build and'
        Write-Warn2 'possible out-of-memory failures in R8.'
    } else {
        Write-Good "${ramGiB} GiB RAM"
    }

    Write-Info "CPU threads: $($env:NUMBER_OF_PROCESSORS)"

    # Disk on the target volume.
    $drive = (Split-Path -Qualifier $Root).TrimEnd(':')
    $vol = Get-Volume -DriveLetter $drive -ErrorAction Stop
    $freeGiB = [math]::Floor($vol.SizeRemaining / 1GB)
    Write-Info "free space on ${drive}: ${freeGiB} GiB"
    if ($freeGiB -lt $script:RequiredGiB) {
        Write-Bad "need at least $($script:RequiredGiB) GiB, found ${freeGiB} GiB"
        throw "Not enough free space on ${drive}:."
    }
    Write-Good "${freeGiB} GiB free, need $($script:RequiredGiB) GiB"

    if ($vol.FileSystemType -ne 'NTFS') {
        Write-Warn2 "volume is $($vol.FileSystemType); NTFS expected"
    }

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Write-Good "working root: $Root"
    Set-Done 'Check'
}

function Stage-Wsl {
    Write-Stage 'Stage 2/8  WSL2 platform'

    $installed = $false
    try {
        & wsl.exe --status *> $null
        if ($LASTEXITCODE -eq 0) { $installed = $true }
    } catch { $installed = $false }

    if ($installed) {
        Write-Good 'WSL is already installed'
    } else {
        Write-Info 'installing the WSL platform (no distribution yet)'
        # --no-distribution keeps this from pulling a Store Ubuntu that would
        # land on C: and need interactive first-run setup. The distro is imported
        # onto the target drive in the next stage instead.
        Invoke-Wsl -Arguments @('--install','--no-distribution') -AllowFailure | Out-Null
        Write-Warn2 'If WSL was just enabled for the first time, Windows needs a'
        Write-Warn2 'REBOOT before it will work. Reboot, then re-run this script;'
        Write-Warn2 'it resumes from here.'
    }

    Invoke-Wsl -Arguments @('--set-default-version','2') -AllowFailure | Out-Null
    Write-Info 'updating the WSL kernel'
    Invoke-Wsl -Arguments @('--update') -AllowFailure | Out-Null
    Set-Done 'Wsl'
}

function Stage-Distro {
    Write-Stage 'Stage 3/8  Ubuntu 22.04 on the target drive'

    $existing = (& wsl.exe --list --quiet) -split "`r?`n" | ForEach-Object { $_.Trim() }
    if ($existing -contains $script:DistroName) {
        if (-not $Force) {
            Write-Good "distro '$($script:DistroName)' already registered"
            Set-Done 'Distro'
            return
        }
        Write-Warn2 "-Force given: this will UNREGISTER '$($script:DistroName)'"
        Write-Warn2 'and permanently delete everything inside it, including any'
        Write-Warn2 'AOSP tree already synced.'
        $answer = Read-Host "Type the distro name to confirm deletion"
        if ($answer -ne $script:DistroName) { throw 'Aborted by user.' }
        Invoke-Wsl -Arguments @('--unregister', $script:DistroName)
    }

    $rootfs = Join-Path $Root 'ubuntu-22.04-rootfs.tar.gz'
    if (Test-Path -LiteralPath $rootfs) {
        Write-Good "rootfs already downloaded: $rootfs"
    } else {
        Write-Info "downloading the Ubuntu 22.04 WSL rootfs (~300 MB)"
        # curl.exe ships with Windows 10 1803+ and supports resume, which
        # Invoke-WebRequest does not. -C - resumes a partial file.
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fL --retry 3 --retry-delay 5 -C - -o $rootfs $script:RootFsUrl
            if ($LASTEXITCODE -ne 0) { throw "rootfs download failed ($LASTEXITCODE)" }
        } else {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $script:RootFsUrl -OutFile $rootfs -UseBasicParsing
        }
        Write-Good 'rootfs downloaded'
    }

    $distroDir = Join-Path $Root 'wsl'
    New-Item -ItemType Directory -Path $distroDir -Force | Out-Null

    Write-Info "importing into $distroDir (this is where the ext4 disk lives)"
    Invoke-Wsl -Arguments @('--import', $script:DistroName, $distroDir, $rootfs, '--version','2')
    Write-Good "imported '$($script:DistroName)'"

    # An imported distro has no default user, so it runs as root. AOSP's build
    # works as root but repo warns and some host tools behave differently, so
    # create an ordinary user and make it the default via /etc/wsl.conf.
    Write-Info 'creating the build user'
    $setup = @(
        'set -e'
        'id -u builder >/dev/null 2>&1 || useradd -m -s /bin/bash builder'
        'usermod -aG sudo builder'
        "echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder"
        'chmod 0440 /etc/sudoers.d/builder'
        "printf '[user]\ndefault=builder\n[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf"
    ) -join '; '
    # appendWindowsPath=false keeps Windows PATH entries out of the Linux build
    # environment. Leaving them in is a real hazard: a Windows python.exe or
    # java.exe on PATH gets picked up by AOSP's build and fails confusingly.
    Invoke-Wsl -Arguments @('-d',$script:DistroName,'-u','root','--','bash','-lc',$setup)

    Write-Info 'restarting the distro so /etc/wsl.conf takes effect'
    Invoke-Wsl -Arguments @('--terminate', $script:DistroName) -AllowFailure | Out-Null
    Write-Good 'distro ready'
    Set-Done 'Distro'
}

function Stage-Tune {
    Write-Stage 'Stage 4/8  WSL resource limits'

    $cs = Get-CimInstance Win32_ComputerSystem
    $ramGiB = [math]::Floor($cs.TotalPhysicalMemory / 1GB)

    # Leave 4 GiB for Windows; never hand WSL less than 8 GiB or the build cannot
    # link. build.sh derives its -j from the RAM it actually sees, so this value
    # directly controls build parallelism.
    $wslRam = [math]::Max(8, $ramGiB - 4)
    # Swap is what keeps R8 and soong alive on a 16-32 GiB host. It is a file on
    # the target drive, not on C:.
    $swapGiB = 32
    $swapPath = (Join-Path $Root 'wsl-swap.vhdx') -replace '\\','\\'

    $wslconfig = Join-Path $env:USERPROFILE '.wslconfig'
    if ((Test-Path -LiteralPath $wslconfig) -and -not $Force) {
        Write-Warn2 "$wslconfig already exists and is left alone. Re-run with"
        Write-Warn2 '-Force to overwrite, or edit it by hand. Current contents:'
        Get-Content -LiteralPath $wslconfig | ForEach-Object { Write-Info "    $_" }
    } else {
        if (Test-Path -LiteralPath $wslconfig) {
            Copy-Item -LiteralPath $wslconfig -Destination "$wslconfig.bak" -Force
            Write-Info "backed up the old config to $wslconfig.bak"
        }
        $content = @"
# Written by Start-EdgeBuild.ps1 for the Khadas Edge1 Android 14 build.
# Host has ${ramGiB} GiB RAM; ${wslRam} GiB is given to WSL and 4 GiB kept for Windows.
[wsl2]
memory=${wslRam}GB
processors=$($env:NUMBER_OF_PROCESSORS)
swap=${swapGiB}GB
swapFile=$swapPath
# Reclaim freed page cache back to Windows instead of holding the full
# allocation for the life of the VM.
pageReporting=true
[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
"@
        Set-Content -LiteralPath $wslconfig -Value $content -Encoding ASCII
        Write-Good "wrote $wslconfig (memory=${wslRam}GB, swap=${swapGiB}GB)"
    }

    Write-Info 'shutting WSL down so the new limits apply'
    Invoke-Wsl -Arguments @('--shutdown') -AllowFailure | Out-Null

    # An imported distro's ext4.vhdx grows on demand but has a fixed maximum.
    # Recent WSL defaults to 1 TB, which is enough; older builds used 256 GB,
    # which is not. --manage exists only on newer WSL, hence AllowFailure.
    Write-Info 'ensuring the virtual disk can grow to 512 GB'
    $rc = Invoke-Wsl -Arguments @('--manage', $script:DistroName, '--resize', '512GB') -AllowFailure
    if ($rc -ne 0) {
        Write-Warn2 'could not resize automatically (needs a newer WSL).'
        Write-Warn2 'If the sync later fails with "no space left on device",'
        Write-Warn2 "run: wsl --manage $($script:DistroName) --resize 512GB"
    } else {
        Write-Good 'virtual disk maximum set to 512 GB'
    }
    Set-Done 'Tune'
}

function Stage-Provision {
    Write-Stage 'Stage 5/8  Dependencies and device tree'

    # Bootstrap: git first, then the repo, then hand off to provision-wsl.sh
    # which lives in that repo and does everything else.
    Write-Info 'installing git'
    Invoke-InDistro -AsRoot -Command 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq git ca-certificates curl'

    Write-Info 'cloning the device tree'
    $clone = "test -d ~/android_khadas/android_manifest/.git || " +
             "git clone --branch $($script:RepoBranch) $($script:RepoUrl) ~/android_khadas/android_manifest"
    Invoke-InDistro -Command "mkdir -p ~/android_khadas && $clone"

    Write-Info 'running the provisioning script (deps, preflight, verification)'
    Invoke-InDistro -Command 'chmod +x ~/android_khadas/android_manifest/build/*.sh ~/android_khadas/android_manifest/build/windows/*.sh'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh deps'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh preflight'
    Write-Good 'environment provisioned'
    Set-Done 'Provision'
}

function Stage-Sync {
    Write-Stage 'Stage 6/8  Sync AOSP 14 (100+ GiB, hours)'
    Write-Warn2 'Do not let the machine sleep during this. To be safe:'
    Write-Warn2 '  powercfg /change standby-timeout-ac 0'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh sync'
    Write-Good 'sync complete'
    Set-Done 'Sync'
}

function Stage-Kernel {
    Write-Stage 'Stage 7/8  Kernel 4.19.111'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh kernel'
    Write-Good 'kernel built'
    Set-Done 'Kernel'
}

function Stage-Build {
    Write-Stage 'Stage 8/8  Platform build and update.img'
    Write-Warn2 'This tree is NOT finished: the composer3 and audio.core AIDL'
    Write-Warn2 'HALs are incomplete, so the build uses AOSP fallbacks and the'
    Write-Warn2 'resulting image will have no display or audio output. See'
    Write-Warn2 'docs/STATUS.md. Running this verifies the build, not the ROM.'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh build' -AllowFailure | Out-Null

    Write-Info "logs and any update.img are under the distro's home, reachable"
    Write-Info "from Explorer at: \\wsl.localhost\$($script:DistroName)\home\builder\android_khadas"
    Set-Done 'Build'
}

#endregion

#region main ------------------------------------------------------------------

$order = @(
    @{ Name='Check';     Fn={ Stage-Check } }
    @{ Name='Wsl';       Fn={ Stage-Wsl } }
    @{ Name='Distro';    Fn={ Stage-Distro } }
    @{ Name='Tune';      Fn={ Stage-Tune } }
    @{ Name='Provision'; Fn={ Stage-Provision } }
    @{ Name='Sync';      Fn={ Stage-Sync } }
    @{ Name='Kernel';    Fn={ Stage-Kernel } }
    @{ Name='Build';     Fn={ Stage-Build } }
)

Write-Host ''
Write-Host 'Khadas Edge1 - Android TV 14 build driver (Windows/WSL2)' -ForegroundColor White
Write-Host "root: $Root   stage: $Stage" -ForegroundColor DarkGray

$started = Get-Date
try {
    foreach ($s in $order) {
        if ($Stage -ne 'All' -and $Stage -ne $s.Name) { continue }
        if ($Stage -eq 'All' -and (Test-Done $s.Name)) {
            Write-Host "  skipping $($s.Name) (already complete; -Force to redo)" -ForegroundColor DarkGray
            continue
        }
        & $s.Fn
    }
    $elapsed = (Get-Date) - $started
    Write-Host ''
    Write-Host "Done in $($elapsed.ToString('hh\:mm\:ss'))." -ForegroundColor Green
    Write-Host "State: $($script:StatePath)" -ForegroundColor DarkGray
}
catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    Write-Host ''
    Write-Host '  The state file records completed stages, so re-running this' -ForegroundColor DarkGray
    Write-Host '  script resumes rather than starting over.' -ForegroundColor DarkGray
    exit 1
}

#endregion
