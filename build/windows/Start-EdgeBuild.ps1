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

    [ValidateSet('All','Check','Wsl','Distro','Tune','Provision','Sync','Aidl','Probe','Kernel','Build','Report')]
    [string] $Stage = 'All',

    # Swap size for WSL. 0 = automatic (2x RAM, floored at 32, capped at 128).
    #
    # Swap is OOM insurance, not a way to buy parallelism: build.sh derives -j
    # from real RAM, and deliberately does not count swap. Oversubscribing -j so
    # that ninja runs out of physical memory collapses throughput even on a fast
    # NVMe, because the access pattern becomes random 4K page faults. A large
    # swap file stops a single R8 or linker spike from killing a six-hour build;
    # it does not make the build wider.
    [ValidateRange(0,512)]
    [int] $SwapGB = 0,

    # GiB of RAM held back for Windows itself.
    [ValidateRange(2,32)]
    [int] $ReserveGB = 6,

    # Name for the WSL distribution this script creates and drives. Override it
    # only to point at an existing distro you want to reuse; note that a distro
    # created elsewhere probably has its disk on C:, which defeats the purpose of
    # putting the tree on the large drive.
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $DistroName = 'Edge1Build',

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Without this, wsl.exe emits UTF-16LE and every piped string comparison in this
# script silently fails to match. This is the single most common cause of
# PowerShell/WSL scripts misbehaving.
$env:WSL_UTF8 = '1'

$script:DistroName = $DistroName
$script:RepoUrl    = 'https://github.com/220242/android_manifest'
$script:RepoBranch = 'claude/determined-johnson-fwwaig'
# Directory index, not a fixed filename.
#
# The previous version hardcoded .../ubuntu-jammy-wsl-amd64-wsl.rootfs.tar.gz and
# broke with a 404 when Canonical renamed the artefact to
# ...-amd64-ubuntu22.04lts.rootfs.tar.gz. Resolving the name from the index at
# run time survives the next rename too.
#
# jammy (22.04) rather than noble (24.04): AOSP 14's host prebuilts are built
# against the older glibc, and 22.04 is what Google's own build images use.
$script:RootFsIndex = 'https://cloud-images.ubuntu.com/wsl/jammy/current/'
$script:StatePath  = Join-Path $Root '.build-state.json'

# Disk: ~120GiB checkout + ~150GiB output, plus the rootfs and logs.
$script:RequiredGiB = 320

$script:TranscriptOn = $false
$script:RunStamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogDir     = Join-Path $Root 'logs'
$script:Transcript = Join-Path $script:LogDir "session-$($script:RunStamp).log"
$script:ReportPath = Join-Path $Root "edge1-report-$($script:RunStamp).txt"

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
    return [pscustomobject]@{ completed = @() }  # always an array, never $null
}
function Test-Done { param([string] $Name)
    if ($Force) { return $false }
    # @(): a one-element JSON array deserialises to a bare string, and a missing
    # property to $null. Both need coercing before -contains.
    $done = @((Get-State).completed)
    return ($done -contains $Name)
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
    Assert-BashSafe $Command
    # Not $args: that is a reserved automatic variable inside a function.
    $wslArgs = @('-d', $script:DistroName)
    if ($AsRoot) { $wslArgs += @('-u','root') }
    $wslArgs += @('--','bash','-lc', $Command)
    return (Invoke-Wsl -Arguments $wslArgs -AllowFailure:$AllowFailure)
}

# Captures wsl output as a string instead of sending it to the host. Needed by
# the report, which has to put the text in a file rather than on screen.
function Invoke-WslCapture {
    param([Parameter(Mandatory)][string] $Command, [switch] $AsRoot)
    Assert-BashSafe $Command
    $wslArgs = @('-d', $script:DistroName)
    if ($AsRoot) { $wslArgs += @('-u','root') }
    $wslArgs += @('--','bash','-lc', $Command)

    # 'Continue', not the script-wide 'Stop': with 2>&1 a native command's stderr
    # becomes an ErrorRecord, and under Stop that terminates. The report collector
    # is the one thing that must never die from the output it is collecting - that
    # is precisely when it is needed.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & wsl.exe @wslArgs 2>&1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return ($out | Out-String)
}

# Guards against a PowerShell 5.1 trap that is invisible until bash chokes.
#
# When PowerShell passes a string to a native command it strips embedded double
# quotes. A command like:  ... || echo "(not cloned yet)"  reaches bash as
# ... || echo (not cloned yet)  and dies with
#   /bin/bash: -c: line 1: syntax error near unexpected token `('
# Single quotes are not special to the Windows command line and DO survive, so
# every bash command here quotes with single quotes.
function Assert-BashSafe {
    param([string] $Command)
    if ($Command.Contains('"')) {
        throw ("internal error: bash command contains a double quote, which " +
               "PowerShell strips when calling a native command. Use single " +
               "quotes instead. Command: $Command")
    }
}

# Finds the current amd64 WSL rootfs and its published SHA256.
function Resolve-RootFs {
    Write-Info "resolving the rootfs name from $($script:RootFsIndex)"
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $index = (Invoke-WebRequest -Uri $script:RootFsIndex -UseBasicParsing -TimeoutSec 60).Content
    } catch {
        throw "could not read the Ubuntu image index at $($script:RootFsIndex): $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $prev
    }

    # amd64 only: the arm64 artefact sits in the same directory and matches a
    # looser pattern.
    $names = [regex]::Matches($index, 'ubuntu-jammy-wsl-amd64-[A-Za-z0-9._-]*rootfs\.tar\.gz') |
             ForEach-Object { $_.Value } | Select-Object -Unique
    if (-not $names) {
        throw ("no amd64 rootfs found in $($script:RootFsIndex). Canonical may have " +
               "restructured the path; open it in a browser and pass the tarball " +
               "to 'wsl --import' by hand.")
    }
    $name = $names | Sort-Object | Select-Object -Last 1
    Write-Good "rootfs: $name"

    # Published checksums, so a truncated or proxy-mangled download is caught
    # before it is imported rather than as a broken distro later.
    $sha = $null
    try {
        $sums = (Invoke-WebRequest -Uri ($script:RootFsIndex + 'SHA256SUMS') -UseBasicParsing -TimeoutSec 60).Content
        foreach ($line in ($sums -split "`r?`n")) {
            if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($name))$") {
                $sha = $Matches[1].ToLower()
                break
            }
        }
    } catch {
        Write-Warn2 "could not fetch SHA256SUMS: $($_.Exception.Message)"
    }
    if ($sha) { Write-Info "expected sha256: $sha" }
    else { Write-Warn2 'no checksum available; the download will not be verified' }

    return [pscustomobject]@{
        Name   = $name
        Url    = $script:RootFsIndex + $name
        Sha256 = $sha
    }
}

function Test-FileSha256 {
    param([string] $Path, [string] $Expected)
    if (-not $Expected) { return $true }
    Write-Info 'verifying sha256'
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $Expected) { Write-Good 'checksum matches'; return $true }
    Write-Warn2 "checksum mismatch: got $actual"
    return $false
}

# Brings the device tree inside the distro up to date with origin.
#
# This is the fix for a bug that wasted two full runs: Stage-Provision used
#   test -d ~/.../.git || git clone ...
# so once the clone existed it was never updated again. Every fix pushed to the
# repo reached the Windows-side clone (the user pulls it to get this script) but
# never reached the copy inside the distro -- and the copy inside the distro is
# the one that runs sync, the kernel build and the platform build. Worse, the
# stale copy was gated behind a completed stage, so even -Stage Provision -Force
# re-ran the OLD provision-wsl.sh and its old dependency list.
#
# Done with inline git rather than provision-wsl.sh's own clone stage on purpose:
# using the in-distro script to update the in-distro script is the chicken-and-egg
# that caused this.
function Update-DistroRepo {
    $repo = '~/android_khadas/android_manifest'

    Invoke-InDistro -Command ("mkdir -p ~/android_khadas && test -d $repo/.git || " +
                              "git clone --branch $($script:RepoBranch) $($script:RepoUrl) $repo")

    # reset --hard, not pull: the working tree in the distro is never edited by
    # hand, and a merge conflict there would be a dead end with no way to resolve
    # it from this script.
    Invoke-InDistro -Command ("git -C $repo fetch --quiet origin $($script:RepoBranch) && " +
                              "git -C $repo checkout --quiet -B $($script:RepoBranch) origin/$($script:RepoBranch) && " +
                              "git -C $repo reset --hard --quiet origin/$($script:RepoBranch)")

    Invoke-InDistro -Command "chmod +x $repo/build/*.sh $repo/build/windows/*.sh"

    $head = (Invoke-WslCapture -Command "git -C $repo log --oneline -1").Trim()
    Write-Good "device tree in the distro: $head"
}

function Start-BuildLog {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    try {
        Start-Transcript -LiteralPath $script:Transcript -Force | Out-Null
        $script:TranscriptOn = $true
    } catch {
        # A transcript already running, or a locked file. Not worth aborting over.
        $script:TranscriptOn = $false
        Write-Warn2 "could not start a transcript: $($_.Exception.Message)"
    }
}

function Stop-BuildLog {
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:TranscriptOn = $false
    }
}

function Get-WindowsEnvironmentText {
    $sb = [System.Text.StringBuilder]::new()
    function Add { param($t) [void]$sb.AppendLine($t) }

    Add '##### WINDOWS ENVIRONMENT #####'
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        Add "OS:          $($os.Caption) $($os.Version) build $($build.CurrentBuildNumber).$($build.UBR)"
        Add "Edition:     $($build.EditionID)  DisplayVersion: $($build.DisplayVersion)"
        Add "CPU:         $($cpu.Name)"
        Add "Cores:       $($cpu.NumberOfCores) physical / $($cpu.NumberOfLogicalProcessors) logical"
        Add "RAM:         $([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GiB"
        Add "Hypervisor:  $($cs.HypervisorPresent)"
        Add "PowerShell:  $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    } catch { Add "environment query failed: $($_.Exception.Message)" }

    Add ''
    Add '--- volumes ---'
    try {
        Get-Volume | Where-Object DriveLetter |
            Select-Object DriveLetter, FileSystemType,
                @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
                @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Add $_ }
    } catch { Add "volume query failed: $($_.Exception.Message)" }

    Add '--- WSL ---'
    try {
        Add (( & wsl.exe --version 2>&1 ) | Out-String)
        Add (( & wsl.exe --list --verbose 2>&1 ) | Out-String)
    } catch { Add "wsl query failed: $($_.Exception.Message)" }

    $wslconfig = Join-Path $env:USERPROFILE '.wslconfig'
    Add "--- $wslconfig ---"
    if (Test-Path -LiteralPath $wslconfig) {
        Get-Content -LiteralPath $wslconfig | ForEach-Object { Add $_ }
    } else { Add '(absent)' }

    Add ''
    Add '--- script invocation ---'
    Add "Root=$Root  Stage=$Stage  SwapGB=$SwapGB  ReserveGB=$ReserveGB  Force=$Force"
    Add "state: $($script:StatePath)"
    if (Test-Path -LiteralPath $script:StatePath) {
        Add ((Get-Content -LiteralPath $script:StatePath -Raw))
    } else { Add '(no state file yet)' }

    return $sb.ToString()
}

# Builds one pasteable text file: Windows environment, the Linux-side report, and
# the PowerShell transcript. Called automatically on failure so the user does not
# have to remember a command at the moment things go wrong.
function Collect-Report {
    param([System.Management.Automation.ErrorRecord] $ErrorRecord)

    Write-Stage 'Collecting a diagnostic report'
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("Khadas Edge1 / Android TV 14 - diagnostic report")
    [void]$sb.AppendLine("generated: $(Get-Date -Format 'u')")
    [void]$sb.AppendLine('')

    if ($ErrorRecord) {
        [void]$sb.AppendLine('##### FAILURE #####')
        [void]$sb.AppendLine("message:   $($ErrorRecord.Exception.Message)")
        [void]$sb.AppendLine("type:      $($ErrorRecord.Exception.GetType().FullName)")
        [void]$sb.AppendLine("category:  $($ErrorRecord.CategoryInfo.Category)")
        [void]$sb.AppendLine('position:')
        [void]$sb.AppendLine($ErrorRecord.InvocationInfo.PositionMessage)
        [void]$sb.AppendLine('script stack trace:')
        [void]$sb.AppendLine($ErrorRecord.ScriptStackTrace)
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine((Get-WindowsEnvironmentText))
    [void]$sb.AppendLine('')

    # Linux side, only if the distro is actually registered.
    $distros = @()
    try { $distros = (& wsl.exe --list --quiet) -split "`r?`n" | ForEach-Object { $_.Trim() } } catch { }
    if ($distros -contains $script:DistroName) {
        Write-Info 'querying the distro'
        try {
            # No '|| echo ...' fallback here: the double quotes it needed were
            # stripped by PowerShell and broke the whole command. An empty result
            # is handled on this side instead.
            $linux = Invoke-WslCapture -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh report 2>&1'
            if ([string]::IsNullOrWhiteSpace($linux)) {
                [void]$sb.AppendLine('##### LINUX #####')
                [void]$sb.AppendLine('the report stage produced no output; the repo may not be cloned yet.')
            } else {
                [void]$sb.AppendLine($linux)
            }
        } catch {
            [void]$sb.AppendLine("##### LINUX REPORT FAILED #####")
            [void]$sb.AppendLine($_.Exception.Message)
        }
    } else {
        [void]$sb.AppendLine("##### LINUX #####")
        [void]$sb.AppendLine("distro '$($script:DistroName)' is not registered yet; nothing to report.")
    }

    # The transcript has to be closed before it can be read.
    Stop-BuildLog
    if (Test-Path -LiteralPath $script:Transcript) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('##### POWERSHELL TRANSCRIPT #####')
        # Tail only: a full sync transcript is large and the interesting part is
        # always at the end.
        $lines = Get-Content -LiteralPath $script:Transcript
        if ($lines.Count -gt 600) {
            [void]$sb.AppendLine("(showing the last 600 of $($lines.Count) lines; full file: $($script:Transcript))")
            $lines = $lines[-600..-1]
        }
        $lines | ForEach-Object { [void]$sb.AppendLine($_) }
    }

    Set-Content -LiteralPath $script:ReportPath -Value $sb.ToString() -Encoding UTF8
    $sizeKB = [math]::Round((Get-Item -LiteralPath $script:ReportPath).Length / 1KB, 1)

    Write-Host ''
    Write-Good "report written: $($script:ReportPath)  (${sizeKB} KB)"
    Write-Host '  Send this one file. It contains the Windows environment, the' -ForegroundColor DarkGray
    Write-Host '  Linux environment, error lines from every build log, and the' -ForegroundColor DarkGray
    Write-Host '  transcript tail.' -ForegroundColor DarkGray
    return $script:ReportPath
}

#endregion

#region stages ----------------------------------------------------------------

function Stage-Check {
    Write-Stage 'Stage 1/10  Host checks'

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
    Write-Stage 'Stage 2/10  WSL2 platform'

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
    Write-Stage 'Stage 3/10  Ubuntu 22.04 on the target drive'

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

    $image = Resolve-RootFs
    $rootfs = Join-Path $Root $image.Name

    # An existing file is trusted only if it passes the checksum. Resuming a
    # partial download whose URL has since changed would otherwise splice two
    # different tarballs together, and the failure would surface as a corrupt
    # distro much later.
    if ((Test-Path -LiteralPath $rootfs) -and (Test-FileSha256 -Path $rootfs -Expected $image.Sha256)) {
        Write-Good "rootfs already present: $rootfs"
    } else {
        if (Test-Path -LiteralPath $rootfs) {
            Write-Warn2 'discarding the existing file and downloading again'
            Remove-Item -LiteralPath $rootfs -Force
        }
        Write-Info "downloading $($image.Url) (~325 MiB)"
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            # curl.exe ships with Windows 10 1803+. -f makes an HTTP error a
            # non-zero exit instead of a saved error page.
            & curl.exe -fL --retry 3 --retry-delay 5 -o $rootfs $image.Url
            if ($LASTEXITCODE -ne 0) {
                throw "rootfs download failed (curl $LASTEXITCODE) from $($image.Url)"
            }
        } else {
            $prev = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -Uri $image.Url -OutFile $rootfs -UseBasicParsing }
            finally { $ProgressPreference = $prev }
        }
        if (-not (Test-FileSha256 -Path $rootfs -Expected $image.Sha256)) {
            throw "downloaded rootfs failed checksum verification: $rootfs"
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
    Write-Stage 'Stage 4/10  WSL resource limits'

    $cs = Get-CimInstance Win32_ComputerSystem
    $ramGiB = [math]::Floor($cs.TotalPhysicalMemory / 1GB)

    # build.sh derives its -j from the RAM it actually sees, so this value is what
    # controls build parallelism. Never hand WSL less than 8 GiB or the build
    # cannot link.
    $wslRam = [math]::Max(8, $ramGiB - $ReserveGB)

    # Swap: 2x RAM by default, floored at 32 and capped at 128.
    #
    # This is insurance against a single R8 or linker spike killing a multi-hour
    # build, not extra capacity. -j stays derived from physical RAM on purpose:
    # if ninja's working set spills to swap the build slows down by an order of
    # magnitude even on NVMe, because the pattern becomes random 4K page faults.
    # More swap buys survival, not speed.
    if ($SwapGB -gt 0) {
        $swapGiB = $SwapGB
    } else {
        $swapGiB = [math]::Min(128, [math]::Max(32, $ramGiB * 2))
    }

    # The swap file is sparse but can reach its full size, so make sure it fits
    # alongside the ~270 GiB the tree needs.
    $drive = (Split-Path -Qualifier $Root).TrimEnd(':')
    $freeGiB = [math]::Floor((Get-Volume -DriveLetter $drive).SizeRemaining / 1GB)
    if (($swapGiB + $script:RequiredGiB) -gt $freeGiB) {
        Write-Warn2 "swap ${swapGiB} GiB + tree $($script:RequiredGiB) GiB exceeds ${freeGiB} GiB free."
        $swapGiB = [math]::Max(16, $freeGiB - $script:RequiredGiB)
        Write-Warn2 "reducing swap to ${swapGiB} GiB"
    }
    Write-Info "RAM ${ramGiB} GiB -> WSL ${wslRam} GiB (${ReserveGB} GiB held for Windows), swap ${swapGiB} GiB"
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
# Host has ${ramGiB} GiB RAM; ${wslRam} GiB goes to WSL, ${ReserveGB} GiB stays with Windows.
# Swap is ${swapGiB} GiB on the target drive - OOM insurance, not added capacity.
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
    Write-Stage 'Stage 5/10  Dependencies and device tree'

    # Bootstrap: git first, then the repo, then hand off to provision-wsl.sh
    # which lives in that repo and does everything else.
    Write-Info 'installing git'
    Invoke-InDistro -AsRoot -Command 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq git ca-certificates curl'

    Write-Info 'fetching the device tree'
    Update-DistroRepo

    Write-Info 'running the provisioning script (deps, preflight, verification)'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh deps'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh preflight'
    Write-Good 'environment provisioned'
    Set-Done 'Provision'
}

function Stage-Sync {
    Write-Stage 'Stage 6/10  Sync AOSP 14 (100+ GiB, hours)'
    Write-Warn2 'Do not let the machine sleep during this. To be safe:'
    Write-Warn2 '  powercfg /change standby-timeout-ac 0'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh sync'
    Write-Good 'sync complete'
    Set-Done 'Sync'
}

function Stage-Kernel {
    Write-Stage 'Stage 9/10  Kernel (mainline 6.12)'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh kernel'
    Write-Good 'kernel built'
    Set-Done 'Kernel'
}

function Stage-Build {
    Write-Stage 'Stage 10/10  Platform build and flash pack'
    Write-Warn2 'This tree is NOT finished: the composer3 and audio.core AIDL'
    Write-Warn2 'HALs are incomplete, so the build uses AOSP fallbacks and the'
    Write-Warn2 'resulting image will have no display or audio output. See'
    Write-Warn2 'docs/STATUS.md. Running this verifies the build, not the ROM.'
    $rc = Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh build' -AllowFailure

    Write-Info "logs and the flash pack are under the distro's home, reachable"
    Write-Info "from Explorer at: \\wsl.localhost\$($script:DistroName)\home\builder\android_khadas"

    if ($rc -ne 0) {
        # Deliberately NOT Set-Done. -AllowFailure exists only so the paths above
        # still print on a failure; marking the stage complete anyway would make
        # the next run skip it, so a failed build would never be retried. That is
        # the one place where the resume logic could silently hide a failure.
        throw "the platform build failed (exit $rc). Error lines are in the report; the full log is platform.log inside the distro."
    }
    Set-Done 'Build'
}

#endregion

#region main ------------------------------------------------------------------

function Stage-Aidl {
    Write-Stage 'Stage 7/10  AIDL interface surface'
    Write-Info 'dumping the real method list for every declared AIDL HAL'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh aidl'
    Write-Good 'written to the distro home as aidl-surface.txt'
    Write-Info "reachable at \\wsl.localhost\$($script:DistroName)\home\builder\android_khadas\aidl-surface.txt"
    Set-Done 'Aidl'
}

function Stage-Probe {
    Write-Stage 'Stage 8/10  Module probe'
    Write-Info 'checking every module device.mk requests against the synced tree'
    Invoke-InDistro -Command '~/android_khadas/android_manifest/build/windows/provision-wsl.sh probe'
    Write-Good 'written to the distro home as module-probe.txt'
    Write-Info "reachable at \\wsl.localhost\$($script:DistroName)\home\builder\android_khadas\module-probe.txt"
    Set-Done 'Probe'
}

$order = @(
    @{ Name='Check';     Fn={ Stage-Check } }
    @{ Name='Wsl';       Fn={ Stage-Wsl } }
    @{ Name='Distro';    Fn={ Stage-Distro } }
    @{ Name='Tune';      Fn={ Stage-Tune } }
    @{ Name='Provision'; Fn={ Stage-Provision } }
    @{ Name='Sync';      Fn={ Stage-Sync } }
    @{ Name='Aidl';      Fn={ Stage-Aidl } }
    @{ Name='Probe';     Fn={ Stage-Probe } }
    @{ Name='Kernel';    Fn={ Stage-Kernel } }
    @{ Name='Build';     Fn={ Stage-Build } }
)

New-Item -ItemType Directory -Path $Root -Force | Out-Null
Start-BuildLog

Write-Host ''
Write-Host 'Khadas Edge1 - Android TV 14 build driver (Windows/WSL2)' -ForegroundColor White
Write-Host "root: $Root   stage: $Stage" -ForegroundColor DarkGray
Write-Host "log:  $($script:Transcript)" -ForegroundColor DarkGray

# The Windows-side clone holds this very script, so if it is behind origin the
# user is running yesterday's fixes without knowing it.
try {
    $selfRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (Test-Path (Join-Path $selfRepo '.git')) {
        & git -C $selfRepo fetch --quiet origin $script:RepoBranch 2>$null
        $local  = (& git -C $selfRepo rev-parse HEAD 2>$null)
        $remote = (& git -C $selfRepo rev-parse "origin/$($script:RepoBranch)" 2>$null)
        if ($local -and $remote -and $local -ne $remote) {
            $behind = (& git -C $selfRepo rev-list --count "HEAD..origin/$($script:RepoBranch)" 2>$null)
            Write-Warn2 "this clone is $behind commit(s) behind origin. Run 'git pull' in $selfRepo"
        } else {
            Write-Host "repo:  up to date with origin" -ForegroundColor DarkGray
        }
    }
} catch { }

# -Stage Report is diagnostics only: collect and exit without touching anything.
if ($Stage -eq 'Report') {
    $path = Collect-Report
    Write-Host ''
    Write-Host "Send this file: $path" -ForegroundColor Cyan
    exit 0
}

# Unconditional, before any stage runs. Provision is skipped once complete, so
# leaving the update inside it means a resumed run keeps using whatever the distro
# happened to have. Only possible once the distro exists; on a first run
# Stage-Provision does it.
try {
    $registered = @((& wsl.exe --list --quiet) -split "`r?`n" | ForEach-Object { $_.Trim() })
    if ($registered -contains $script:DistroName) {
        Write-Stage 'Updating the device tree inside the distro'
        Update-DistroRepo
    }
} catch {
    Write-Warn2 "could not refresh the in-distro device tree: $($_.Exception.Message)"
}

# Aidl and Probe are read-only verification passes whose whole point is their
# output. Gating them on the state file meant that once they had run, a fix that
# changed WHAT they check never ran again, and the report kept answering with a
# probe from several commits ago - which is how two rounds were spent on module
# names that a current probe would have settled. They cost minutes against a
# build that costs hours, so they always run.
$alwaysRun = @('Aidl', 'Probe')

# A stage is complete only if what it produced is still there. Kernel was marked
# done by a run in which the dtb staging step had failed, so every run
# after that skipped it - and the platform build went looking for a file nothing
# had ever written. Cheap to check, and it is checked in the distro because that
# is where the artefacts live.
function Test-StageOutputs {
    param([string] $Name)
    if ($Name -ne 'Kernel') { return $true }
    $probe = 'k=~/android_khadas/aosp-14-edge1/kernel/mainline; ' +
             'test -f $k/out/arch/arm64/boot/Image && ' +
             'ls $k/out/android-dtb/*.dtb >/dev/null 2>&1 ' +
             '&& echo OUTPUTS_OK || echo OUTPUTS_MISSING'
    try {
        return ((Invoke-WslCapture -Command $probe) -match 'OUTPUTS_OK')
    } catch {
        return $false
    }
}

$started = Get-Date
try {
    foreach ($s in $order) {
        if ($Stage -ne 'All' -and $Stage -ne $s.Name) { continue }
        if ($Stage -eq 'All' -and ($alwaysRun -notcontains $s.Name) -and (Test-Done $s.Name)) {
            if (Test-StageOutputs $s.Name) {
                Write-Host "  skipping $($s.Name) (already complete; -Force to redo)" -ForegroundColor DarkGray
                continue
            }
            Write-Warn2 "$($s.Name) is marked complete but its output is missing; re-running it"
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
    # Collect unconditionally: the moment something breaks is exactly when the
    # user should not have to remember a second command.
    $path = $null
    try { $path = Collect-Report -ErrorRecord $_ } catch {
        Write-Warn2 "could not write the report: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host '  The state file records completed stages, so re-running this' -ForegroundColor DarkGray
    Write-Host '  script resumes rather than starting over.' -ForegroundColor DarkGray
    if ($path) {
        Write-Host ''
        Write-Host "  Send this file to get it fixed: $path" -ForegroundColor Cyan
    }
    exit 1
}
finally {
    Stop-BuildLog
}

#endregion
