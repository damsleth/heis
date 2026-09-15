<#
.SYNOPSIS
    Kjoer heisen - request Admin By Request elevation. One file, no dependencies.

.DESCRIPTION
    Launches Admin By Request with /Elevate and clicks through its dialogs. Works
    with nobody connected over RDP, because it drives the dialogs with window
    messages rather than by moving a mouse that has no screen to move on.

    Run it from anywhere:

      - From the desktop, it does the work directly.
      - From SSH, which lands in session 0 and cannot see the desktop's windows
        at all, it relays itself into the interactive session through a
        scheduled task it registers on first use. No administrator rights are
        needed for any of that.

    Nothing to install. No AutoHotkey, no agent left running, no configuration.
    The only requirement is that an interactive session exists - it may be
    disconnected, but somebody has to have logged in since the last reboot.

    It can also be run straight off a URL, with no file saved by hand:

        irm https://example.com/heis | iex

    Note that `| iex` cannot pass arguments. For anything but a plain elevate,
    build a script block instead:

        & ([scriptblock]::Create((irm https://example.com/heis))) -Status

    Either way the script writes a copy of itself to LOCALAPPDATA\Heis, because
    the relay task has to point at a file on disk.

    Output goes to the pipeline, so it can be captured:

        $s = .\Heis.ps1 -Status                    # the message, as a string
        $h = .\Heis.ps1 -Status -PassThru          # Message, Active, Remaining, InGroup

    Prefer branching on -PassThru's .Active over matching the message text.
    On failure nothing is written to the pipeline and $LASTEXITCODE is 1.

.EXAMPLE
    .\Heis.ps1              # elevate, unless already elevated
    .\Heis.ps1 -Status      # report and exit
    .\Heis.ps1 -Finish      # end the running session
    .\Heis.ps1 -PassThru    # emit the state object, not just the message
    .\Heis.ps1 -Uninstall   # remove the relay task and the copy
#>
[CmdletBinding()]
param(
    [switch] $Status,
    [switch] $Finish,
    [switch] $Uninstall,

    [string] $Exe = 'C:\Program Files (x86)\FastTrack Software\Admin By Request\AdminByRequest.exe',
    [int]    $WaitSec = 30,

    # Where to re-fetch this script if it cannot recover its own source - see
    # Resolve-SelfPath. Having a default here is what makes `irm <url> | iex`
    # work at all, since that form leaves a script no way to know its own text.
    # Point it at your own host if you serve a copy from somewhere else.
    [string] $SourceUrl = 'https://raw.githubusercontent.com/damsleth/heis/main/Heis.ps1',

    # Emit the full state object instead of just the message, so a caller can
    # branch on .Active or .Remaining rather than matching on Norwegian text.
    [switch] $PassThru,

    # Set when this instance is the one running inside the interactive session.
    # Not for humans.
    [switch] $InSession
)

### heis-standalone ###

# Norwegian output is composed from character codes so this file can stay pure
# ASCII. That is not tidiness - it is the only encoding that works in both
# places this script has to run:
#
#   - As a file under Windows PowerShell 5.1, which reads a .ps1 as ANSI unless
#     it carries a BOM, mangling every non-ASCII character in it.
#   - Piped in from a URL, where `irm ... | iex` keeps the BOM as a character
#     and PowerShell then refuses to parse the script at all - it fails on the
#     comment-based help and reports a syntax error a dozen lines further down.
#
# A BOM fixes the first and breaks the second. Pure ASCII needs neither.
# Keep it that way: no non-ASCII characters anywhere in this file.
$script:AA = [char]0xE5   # a-ring
$script:OE = [char]0xF8   # o-slash

$ErrorActionPreference = 'Stop'

# TaskName is settled at run time by Resolve-RelayTask, which falls back to a
# per-user name when the canonical one exists but cannot be written.
$script:TaskNameDefault = 'Heis - Admin By Request'
$script:TaskName        = $script:TaskNameDefault
$script:StateDir = Join-Path $env:LOCALAPPDATA 'Heis'

# Sentinel proving a recovered blob really is this script. Do not remove.
$script:Marker = '### heis-standalone ###'

# This script's own source text, captured at script scope because $MyInvocation
# inside a function describes the function instead.
#
# Needed because the relay task has to point at a file on disk, and there is no
# file when the script arrives down a pipe:
#
#     irm https://example/heis | iex
#
# So Resolve-SelfPath writes this text out and points the task there. Doing it
# for a file-based run too, rather than using $PSCommandPath, keeps the task
# independent of wherever the copy you ran happened to live - a task pointing
# into a Downloads folder someone later tidies up is a task that breaks
# silently, weeks later.
$script:SelfSource = $MyInvocation.MyCommand.ScriptBlock.ToString()

# ---------------------------------------------------------------- win32 ---
# Everything this script does to a window is a message: enumerate, read a
# caption, post BM_CLICK. None of it needs an input desktop, which is what lets
# the whole thing work while the session is disconnected. Injected input
# (SendInput) would not - it reaches only a live input desktop and is silently
# discarded otherwise.
function Initialize-Win32 {
    if ('HeisWin32' -as [type]) { return }
    Add-Type -Language CSharp @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class HeisWin32
{
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

    private const string SEP = "\u0001";   // titles may contain anything printable

    private static string Text(IntPtr h) { var sb = new StringBuilder(512); GetWindowTextW(h, sb, sb.Capacity); return sb.ToString(); }
    private static string Cls(IntPtr h)  { var sb = new StringBuilder(256); GetClassNameW(h, sb, sb.Capacity);  return sb.ToString(); }

    public static List<string> Windows(bool includeHidden)
    {
        var list = new List<string>();
        // The delegate is held in a local for the duration of the call so it
        // cannot be collected while native code still holds the pointer.
        EnumProc cb = delegate(IntPtr h, IntPtr p) {
            if (includeHidden || IsWindowVisible(h)) {
                uint pid; GetWindowThreadProcessId(h, out pid);
                list.Add(h.ToInt64() + SEP + Cls(h) + SEP + pid + SEP + Text(h));
            }
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        return list;
    }

    public static List<string> Controls(long parent)
    {
        var list = new List<string>();
        EnumProc cb = delegate(IntPtr h, IntPtr p) {
            list.Add(h.ToInt64() + SEP + Cls(h) + SEP + Text(h));
            return true;
        };
        EnumChildWindows(new IntPtr(parent), cb, IntPtr.Zero);
        return list;
    }

    // BM_CLICK. Asks the button to activate itself: no coordinates, no
    // hit-testing, and nothing that depends on the window being visible.
    public static void Click(long hwnd) { PostMessageW(new IntPtr(hwnd), 0x00F5, IntPtr.Zero, IntPtr.Zero); }
}
'@
}

function Get-Windows {
    param([switch] $IncludeHidden)
    Initialize-Win32

    $byPid = @{}
    foreach ($p in Get-Process) { $byPid[[uint32]$p.Id] = $p.ProcessName }

    foreach ($row in [HeisWin32]::Windows([bool]$IncludeHidden)) {
        $f = $row -split ([char]1)
        [pscustomobject]@{
            Hwnd  = [int64] $f[0]
            Class = $f[1]
            Pid   = [uint32] $f[2]
            Exe   = $byPid[[uint32]$f[2]]
            Title = $f[3]
        }
    }
}

function Get-Controls {
    param([Parameter(Mandatory)][int64] $Hwnd)
    Initialize-Win32
    foreach ($row in [HeisWin32]::Controls($Hwnd)) {
        $f = $row -split ([char]1)
        [pscustomobject]@{ Hwnd = [int64] $f[0]; Class = $f[1]; Text = $f[2] }
    }
}

# Titles are matched whole, never by substring.
#
# Admin By Request reuses "Admin By Request Confirm" for both the elevation
# prompt and the finish prompt, and "Admin By Request" is a substring of it. A
# "contains" match picks between them by z-order, which works until the day it
# does not and then presses a button on the wrong dialog.
function Find-Window {
    param([Parameter(Mandatory)][string] $Title)
    Get-Windows | Where-Object { $_.Title -eq $Title } | Select-Object -First 1
}

# Press a button by the caption a person reads off the screen.
#
# Not by index: control ordering is an artefact of creation order and is not
# guessable. On ABR's confirm dialog the buttons are No first and Yes second,
# and on its countdown window the Finish button sits after four labels.
# Takes a list of captions and tries them in order, so a localised or reworded
# dialog still gets answered instead of stopping the run. Returns whether it
# pressed anything; callers decide whether that is a problem, because in the
# dialog loop below it usually is not.
function Press-Button {
    param([Parameter(Mandatory)][int64] $Hwnd, [Parameter(Mandatory)][string[]] $Captions)

    # Buttons only. Searching every control would let a substring match find
    # "OK" inside a label and click something that is not a button - the class
    # covers both plain Win32 `Button` and WinForms `...BUTTON...`.
    $buttons = @(Get-Controls -Hwnd $Hwnd | Where-Object { $_.Class -match 'BUTTON' -and $_.Text })

    foreach ($caption in $Captions) {
        $want = $caption.Replace('&', '')
        $hit  = $buttons | Where-Object { $_.Text.Replace('&', '') -eq $want } | Select-Object -First 1
        if (-not $hit) {
            $hit = $buttons | Where-Object { $_.Text.Replace('&', '') -like "*$want*" } | Select-Object -First 1
        }
        if ($hit) {
            [HeisWin32]::Click($hit.Hwnd)
            return $true
        }
    }
    return $false
}

# ------------------------------------------------------------------ abr ---
# Whether a session is running is read from ABR's countdown window, whose title
# is the time remaining.
#
# The obvious check does not work. [WindowsPrincipal]::IsInRole reports the
# group membership the CURRENT PROCESS was born with, so a shell started before
# elevation reports "not admin" for its whole life however elevated the account
# becomes. Local group membership is queried alongside it because that one is
# live rather than a snapshot.
# The countdown window on its own. Kept separate from Get-AbrState because the
# dialog loop polls several times a second, and Get-AbrState shells out to
# `net localgroup` - which at that rate means a few processes a second for the
# length of the wait, to answer a question the loop never asks.
function Get-AbrCountdown {
    Get-Windows | Where-Object {
        $_.Exe -eq 'AdminByRequest' -and $_.Title -match '^\d{1,2}:\d{2}:\d{2}$'
    } | Select-Object -First 1
}

function Get-AbrState {
    $w = Get-AbrCountdown

    $inGroup = $false
    try { $inGroup = ((net localgroup Administrators 2>$null) -join "`n") -match [regex]::Escape($env:USERNAME) } catch { }

    [pscustomobject]@{
        Active    = [bool] $w
        Remaining = $(if ($w) { $w.Title } else { $null })
        Hwnd      = $(if ($w) { $w.Hwnd }  else { $null })
        InGroup   = $inGroup
    }
}

# Dialogs Admin By Request may raise, and what to press on each. Several
# captions per dialog because the wording and the UI language are not
# guaranteed to be the ones seen here.
$script:AbrDialogs = @(
    @{ Title = 'Admin By Request Confirm'; Buttons = @('Yes', 'Ja', 'Continue', 'OK') }
    @{ Title = 'Admin By Request';         Buttons = @('OK', 'Yes', 'Ja', 'Close', 'Lukk') }
)

# Answer whatever dialogs turn up until $Done says we are there.
#
# Driving the outcome rather than replaying one exact sequence, because the
# sequence is not reliable: the second dialog does not always appear, the two
# flows share a dialog title, and a run that had already succeeded used to sit
# waiting for a window that was never coming and then call itself a failure.
# Anything unrecognised is simply left alone.
function Invoke-DialogLoop {
    param([Parameter(Mandatory)][scriptblock] $Done, [int] $Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    $pressed  = @{}

    while ((Get-Date) -lt $deadline) {
        if (& $Done) { return $true }

        foreach ($dialog in $script:AbrDialogs) {
            $w = Find-Window -Title $dialog.Title
            if (-not $w) { continue }

            # Once per window. Pressing again while the app is still handling
            # the first click can land on whatever dialog replaces this one.
            if ($pressed.ContainsKey($w.Hwnd)) { continue }
            if (Press-Button -Hwnd $w.Hwnd -Captions $dialog.Buttons) { $pressed[$w.Hwnd] = $true }
        }

        Start-Sleep -Milliseconds 300
    }
    return (& $Done)
}

function Invoke-Elevate {
    param([int] $Seconds)

    $abr = Get-AbrState
    if ($abr.Active) { return "heisen g$($script:AA)r allerede - $($abr.Remaining) igjen" }

    Start-Process -FilePath (Resolve-AbrExe) -ArgumentList '/Elevate' | Out-Null

    if (-not (Invoke-DialogLoop -Seconds $Seconds -Done { [bool](Get-AbrCountdown) })) {
        throw 'started Admin By Request but no countdown appeared'
    }
    return "heisen er oppe - $((Get-AbrCountdown).Title) igjen"
}

function Invoke-Finish {
    param([int] $Seconds)

    $abr = Get-AbrState
    if (-not $abr.Active) { return "ingen heis $($script:AA) stoppe" }

    # Addressed by hwnd: the countdown window's title is a clock and changes
    # every second, so any title match races the tick.
    Press-Button -Hwnd $abr.Hwnd -Captions @('Finish', 'Avslutt', 'Stop') | Out-Null

    # Finish raises the same Confirm dialog the elevation flow uses, so the
    # loop handles it without needing to know which flow it is in.
    if (-not (Invoke-DialogLoop -Seconds $Seconds -Done { -not (Get-AbrCountdown) })) {
        throw "pressed Finish but the session is still running ($((Get-AbrCountdown).Title) left)"
    }
    return 'heisen er nede'
}

# Find AdminByRequest.exe rather than insisting on one path. Installers move
# between Program Files and Program Files (x86) between versions, and where it
# is already running the running image is the most reliable answer there is.
function Resolve-AbrExe {
    if ($Exe -and (Test-Path -LiteralPath $Exe)) { return $Exe }

    $running = Get-Process -Name 'AdminByRequest' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running) {
        try { if ($running.Path) { return $running.Path } } catch { }   # denied on a more privileged process
    }

    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'FastTrack Software\Admin By Request\AdminByRequest.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    # Last resort, and depth-limited: a full scan of Program Files is slow
    # enough to look like a hang.
    $found = Get-ChildItem -Path $roots -Filter 'AdminByRequest.exe' -Recurse -Depth 4 `
                           -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }

    throw 'cannot find AdminByRequest.exe - pass its path with -Exe'
}

function Format-Status {
    $abr = Get-AbrState
    if ($abr.Active) { return "heisen g$($script:AA)r allerede - $($abr.Remaining) igjen" }
    if ($abr.InGroup) { return 'konto er admin, men ingen ABR-nedtelling' }
    return 'ikke elevert'
}

# Every action returns the same shape: the human message, plus the state it
# left things in. The message goes to the pipeline so `$s = .\Heis.ps1 -Status`
# works; -PassThru gives the object so a profile can branch on .Active instead
# of matching Norwegian text that may get reworded.
function Invoke-Action {
    param([string] $Action, [int] $Seconds)

    $message = switch ($Action) {
        'Status'  { Format-Status }
        'Finish'  { Invoke-Finish  -Seconds $Seconds }
        default   { Invoke-Elevate -Seconds $Seconds }
    }

    $state = Get-AbrState
    [pscustomobject]@{
        Message   = $message
        Active    = $state.Active
        Remaining = $state.Remaining
        InGroup   = $state.InGroup
    }
}

# ---------------------------------------------------------------- relay ---
# Window handles do not cross a session boundary: a process in session 0, which
# is where SSH lands, cannot enumerate or message the desktop's windows at all.
# A scheduled task registered to run as this user, only when logged on, is the
# unprivileged way to get code into the interactive session.
# Write this script to a stable location and return that path.
#
# Recovering the source is not as simple as it looks. Under `iex` the
# $MyInvocation captured at script scope describes the CALLER, so it hands back
# whatever wrapper invoked the pipeline - a few hundred bytes of something else
# entirely, which then gets written out and run by the relay task as if it were
# this script. The failure is a silent 75-second timeout with no clue in it.
#
# So a recovered blob is only trusted if it carries the marker, and there are
# three sources in order of reliability.
function Resolve-SelfPath {
    $src = $null

    if ($script:SelfSource -and $script:SelfSource.Contains($script:Marker)) {
        $src = $script:SelfSource                       # normal, and the & (...) form
    } elseif ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $src = [IO.File]::ReadAllText($PSCommandPath)   # run from a file
    } elseif ($SourceUrl) {
        $src = (Invoke-RestMethod -Uri $SourceUrl)      # piped in from a URL
        if (-not ($src -is [string]) -or -not $src.Contains($script:Marker)) {
            throw "what $SourceUrl returned is not this script"
        }
    } else {
        throw @'
cannot recover my own source, so there is nothing to point the relay task at.

This happens with `irm <url> | iex`, where PowerShell does not tell a script
what its own text was. Either of these works instead:

  & ([scriptblock]::Create((irm <url>)))            # and it takes -Status etc.
  irm <url> -OutFile heis.ps1; .\heis.ps1

or bake the URL in, by hosting a copy whose $SourceUrl default points at itself.
'@
    }

    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    $path = Join-Path $script:StateDir 'Heis.ps1'

    # UTF-8 WITH BOM, always. The relay runs Windows PowerShell 5.1, which reads
    # a .ps1 as ANSI unless a BOM says otherwise and mangles every non-ASCII
    # character in it before a single line executes.
    [IO.File]::WriteAllText($path, $src, [Text.UTF8Encoding]::new($true))
    return $path
}

# The relay task's action, or $null when there is no task. Used to decide
# whether it needs registering at all.
function Get-RelayTaskArguments {
    $out = schtasks /query /tn $script:TaskName /xml 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($out | Out-String)
    if ($text -match '(?s)<Arguments>(.*?)</Arguments>') { return $Matches[1] }
    return ''
}

function Register-RelayTask {
    param([Parameter(Mandatory)][string] $Self)

    # Windows PowerShell by absolute path, not $PSHOME: under pwsh 7 that would
    # point at pwsh.exe, which a downloaded copy of this script cannot assume is
    # installed. System32\WindowsPowerShell is always present.
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }

    # The account is named by SID, not DOMAIN\user. An SSH login reports
    # USERDOMAIN as WORKGROUP, which is not an authority that resolves - Task
    # Scheduler answers "No mapping between account names and security IDs".
    # The SID is the same however the session was established.
    $sid  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $self = $Self

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Runs Heis inside the interactive session on demand.</Description>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$ps</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$self" -InSession</Arguments>
      <WorkingDirectory>$(Split-Path -Parent $self)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    $path = Join-Path $env:TEMP "heis-task-$PID.xml"
    [IO.File]::WriteAllText($path, $xml, [Text.Encoding]::Unicode)
    try {
        schtasks /create /tn $script:TaskName /xml $path /f 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

# Settle on a task name that works, and leave $script:TaskName pointing at it.
#
# The canonical name can be unusable through no fault of this run: a task
# registered while Admin By Request had granted admin carries a security
# descriptor an unelevated account cannot overwrite. Rather than dead-end on
# that and demand an elevated shell, fall back to a name of our own. A second
# task is a much smaller cost than a tool that stops working.
function Resolve-RelayTask {
    param([Parameter(Mandatory)][string] $Self)

    $names = @($script:TaskNameDefault, "$($script:TaskNameDefault) ($env:USERNAME)")

    foreach ($name in $names) {
        $script:TaskName = $name

        # Already pointing at the right script: reuse it untouched. Rewriting a
        # task that is already correct is what made the canonical one
        # unusable from SSH in the first place.
        $have = Get-RelayTaskArguments
        if ($null -ne $have -and $have.Contains($Self)) { return }

        if (Register-RelayTask -Self $Self) { return }
    }

    $script:TaskName = $script:TaskNameDefault
    throw @"
could not register a relay task under any name.

Creating scheduled tasks may be blocked by policy on this machine. Check with:
    schtasks /create /tn HeisTest /tr cmd.exe /sc once /st 00:00 /f
"@
}

function Invoke-ViaSession {
    param([string] $Action, [int] $Seconds)

    # `schtasks /run` reports success even when the task cannot actually start
    # because nobody is logged on, so the only way to notice used to be the
    # reply never arriving - 75 seconds later. An explorer.exe outside session
    # 0 is a reliable, cheap sign that a desktop session exists to relay into.
    $interactive = @(Get-Process -Name explorer -ErrorAction SilentlyContinue |
                     Where-Object { $_.SessionId -ne 0 })
    if (-not $interactive) {
        throw @'
nobody is logged in, so there is no desktop session to drive.

The session may be disconnected - that is fine - but it has to exist. Connect
over RDP once and this works from here afterwards.
'@
    }

    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null

    # Replies from runs that timed out or died never get collected. Clearing
    # them keeps the directory from growing forever.
    Get-ChildItem -LiteralPath $script:StateDir -Filter 'result-*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $id      = [guid]::NewGuid().ToString('N')
    $reqFile = Join-Path $script:StateDir 'request.json'
    $resFile = Join-Path $script:StateDir "result-$id.json"

    @{ Id = $id; Action = $Action; WaitSec = $Seconds; Exe = $Exe } |
        ConvertTo-Json | Set-Content -LiteralPath $reqFile -Encoding UTF8

    Resolve-RelayTask -Self (Resolve-SelfPath)

    $out = schtasks /run /tn $script:TaskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        # A disabled task refuses to run. Enabling one this account owns is
        # within its rights, so try that before giving up.
        schtasks /change /tn $script:TaskName /enable 2>&1 | Out-Null
        $out = schtasks /run /tn $script:TaskName 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw "could not start the relay task: $out"
    }

    $deadline = (Get-Date).AddSeconds($Seconds + 45)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resFile) {
            $r = Get-Content -LiteralPath $resFile -Raw | ConvertFrom-Json
            Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue
            if (-not $r.Ok) { throw $r.Message }
            return $r.Data
        }
        Start-Sleep -Milliseconds 400
    }
    throw "no reply from the interactive session within $($Seconds + 45)s. Is anyone logged in?"
}

# ----------------------------------------------------------------- main ---
if ($Uninstall) {
    # Both names, since a fallback task may have been registered alongside the
    # canonical one.
    $stuck = @()
    foreach ($name in @($script:TaskNameDefault, "$($script:TaskNameDefault) ($env:USERNAME)")) {
        $script:TaskName = $name
        $out = schtasks /delete /tn $name /f 2>&1
        if ($LASTEXITCODE -ne 0 -and (Get-RelayTaskArguments)) { $stuck += $name }
    }
    $script:TaskName = $script:TaskNameDefault
    $taskGone = -not $stuck
    Remove-Item -LiteralPath $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($taskGone) {
        Write-Host 'heis avinstallert' -ForegroundColor Green
    } else {
        # Do not claim success for work that did not happen. A task registered
        # from an elevated context cannot be deleted from an unelevated one.
        Write-Host 'heis-filene er fjernet' -ForegroundColor Yellow
        Write-Warning ("could not remove: $($stuck -join ', '). " +
            "Delete from an elevated session:  schtasks /delete /tn `"$($stuck[0])`" /f")
        exit 1
    }
    return
}

$action = 'Elevate'
if ($Status) { $action = 'Status' }
if ($Finish) { $action = 'Finish' }

if ($InSession) {
    # Running inside the interactive session, launched by the relay task.
    $reqFile = Join-Path $script:StateDir 'request.json'
    if (-not (Test-Path -LiteralPath $reqFile)) { return }

    # Only act on a request somebody is still waiting for. The task can be
    # started by hand, or by a leftover trigger, and replaying the last request
    # then would elevate - or end a session - with nobody having asked.
    if ((Get-Item -LiteralPath $reqFile).LastWriteTime -lt (Get-Date).AddMinutes(-3)) { return }

    $req = Get-Content -LiteralPath $reqFile -Raw | ConvertFrom-Json
    $resFile = Join-Path $script:StateDir "result-$($req.Id).json"

    try {
        $Exe = $req.Exe
        $result = @{ Ok = $true; Data = (Invoke-Action -Action $req.Action -Seconds ([int]$req.WaitSec)) }
    } catch {
        $result = @{ Ok = $false; Message = $_.Exception.Message }
    }
    $result | ConvertTo-Json | Set-Content -LiteralPath $resFile -Encoding UTF8
    return
}

# Session 0 is the non-interactive services session, which is where an SSH
# login lands. It can see none of the desktop's windows, so the work has to
# happen somewhere else.
$mySession = (Get-Process -Id $PID).SessionId

try {
    if ($mySession -eq 0) {
        $result = Invoke-ViaSession -Action $action -Seconds $WaitSec
    } else {
        $result = Invoke-Action -Action $action -Seconds $WaitSec
    }
} catch {
    # WriteErrorLine rather than Write-Error: one clean red line, and no
    # ErrorRecord to terminate a caller that runs with $ErrorActionPreference
    # 'Stop' - which matters when the caller is a $PROFILE that still has to
    # finish loading.
    #
    # The trade-off is that this writes to the host, not to a redirectable
    # stream, so `2>&1` does not capture it. $LASTEXITCODE is the programmatic
    # signal: non-zero means nothing was done, and nothing is written to the
    # pipeline in that case.
    $Host.UI.WriteErrorLine($_.Exception.Message)
    exit 1
}

# The message on the pipeline, so `$s = .\Heis.ps1 -Status` captures it and an
# interactive run still prints it. Write-Host would do neither: it cannot be
# captured, and emitting both would print twice.
if ($PassThru) { $result } else { $result.Message }
