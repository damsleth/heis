<#
.SYNOPSIS
    Kjoer heisen - request Admin By Request elevation. One file, no dependencies.

.DESCRIPTION
    Launches Admin By Request with /Elevate and clicks through its dialogs. Works
    with nobody connected over RDP, because it drives the dialogs with window
    messages rather than by moving a mouse that has no screen to move on.

    Install it - one line, guided, no administrator rights:

        irm https://heis.d0.si/install.ps1 | iex

    That puts Heis.ps1 in %LOCALAPPDATA%\Programs\Heis, adds `heis` to your
    PATH, and checks the whole path end to end. After that it is just `heis`.

    Run it from anywhere:

      - From the desktop, it does the work directly.
      - From SSH, which lands in session 0 and cannot see the desktop's windows
        at all, it relays itself into the interactive session through a
        scheduled task it registers on first use. No administrator rights are
        needed for any of that.

    The only requirement is that an interactive session exists - it may be
    disconnected, but somebody has to have logged in since the last reboot.

    It can also be run straight off a URL, with no file saved at all:

        & ([scriptblock]::Create((irm https://heis.d0.si/Heis.ps1))) -Status

    Either way the script writes a copy of itself to LOCALAPPDATA\Heis, because
    the relay task has to point at a file on disk.

    Output goes to the pipeline, so it can be captured:

        $s = heis -Status                    # the message, as a string
        $h = heis -Status -PassThru          # Message, Active, Remaining, InGroup

    Prefer branching on -PassThru's .Active over matching the message text.
    On failure nothing is written to the pipeline and $LASTEXITCODE is 1.

    Something wrong? `heis -Doctor` checks every part of the setup, repairs what
    belongs to heis, and says what to do about the rest.

.EXAMPLE
    heis                    # elevate, unless already elevated
.EXAMPLE
    heis -Status            # which floor are we on
.EXAMPLE
    heis -Finish            # end the running session
.EXAMPLE
    heis -Doctor            # check the setup and repair what can be repaired
.EXAMPLE
    heis -AddToProfile -AutoElevateOnLogin $false   # status on logon, no auto-elevate
.EXAMPLE
    heis -Uninstall         # remove everything heis has set up

.LINK
    https://heis.d0.si
#>
# PositionalBinding off: with it on, any stray word binds to -Exe, the exe
# lookup heals straight past the nonsense path, and `heis statsu` ELEVATES.
# An unknown argument has to be an error, never the default action.
[CmdletBinding(PositionalBinding = $false)]
param(
    # Report whether an ABR session is running, and how long it has left.
    [switch] $Status,

    # End the running ABR session.
    [switch] $Finish,

    # Remove everything heis has set up: the relay task, its state, the PATH
    # entry and heis.cmd, and the logon block in both PowerShell profiles.
    [switch] $Uninstall,

    # Print a short summary of the commands.
    [Alias('h')]
    [switch] $Help,

    # Check the setup end to end, repair what belongs to heis, and say what to
    # do about anything else. Exits 1 if something is still broken.
    [switch] $Doctor,

    # Where AdminByRequest.exe is. Only needed if it is somewhere unusual: when
    # this path does not exist, the running process and both Program Files
    # roots are searched.
    [string] $Exe = 'C:\Program Files (x86)\FastTrack Software\Admin By Request\AdminByRequest.exe',

    # How long to wait for ABR's dialogs and countdown, in seconds.
    [int]    $WaitSec = 30,

    # Where to re-fetch this script if it cannot recover its own source - see
    # Resolve-SelfPath. Having a default here is what makes `irm <url> | iex`
    # work at all, since that form leaves a script no way to know its own text.
    # Point it at your own host if you serve a copy from somewhere else.
    [string] $SourceUrl = 'https://heis.d0.si/Heis.ps1',

    # Write a block into $PROFILE that reports status on logon, and takes the
    # heis when there is none. Re-running replaces the block. These live here
    # rather than in Install.ps1 because they are settings, not install steps:
    # changing your mind later should not mean re-running an installer.
    [switch] $AddToProfile,

    # With -AddToProfile: whether the logon block elevates over SSH ($true) or
    # only reports status ($false).
    [bool]   $AutoElevateOnLogin = $true,

    # Put `heis` on the PATH: writes heis.cmd beside this script, so any shell
    # can run it, and adds this folder to the user PATH. No admin needed.
    [switch] $AddToPath,

    # Check that the whole path works: the relay, and elevation itself.
    # Non-destructive when a session is already running - see Invoke-Verify.
    [switch] $Verify,

    # Emit the full state object instead of just the message, so a caller can
    # branch on .Active or .Remaining rather than matching on Norwegian text.
    [switch] $PassThru,

    # Set when this instance is the one running inside the interactive session.
    # Not for humans.
    [switch] $InSession
)

# Piped into iex, this text runs in the CALLER's scope: every function and
# variable below - and $ErrorActionPreference 'Stop' above all - would stay
# behind in the user's shell, turning their next harmless error fatal. A file
# run has $PSCommandPath, and the script block form finds its own text in
# $MyInvocation. Anything else is iex, so fetch the script once more and run it
# in a scope of its own. `| iex` passes no arguments, so there are none to
# forward. Matched on the line that assigns the marker, not the bare marker:
# Install.ps1 carries the bare marker too, as might any wrapper that checks
# for it, and a caller containing it would skip the isolation.
if (-not $PSCommandPath -and -not ([string]$MyInvocation.MyCommand.ScriptBlock).Contains("`$script:Marker = '### heis-standalone ###'")) {
    & ([scriptblock]::Create((Invoke-RestMethod -Uri $SourceUrl -UseBasicParsing)))
    return
}

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
#
# It still says "standalone" from when this file was Heis-Standalone.ps1, and
# is deliberately left that way: Install.ps1 and any deployed copy check for
# this exact string, so renaming it would make a cached installer reject a
# fresh script, and a fresh installer reject a copy already on disk. It is an
# opaque token nobody reads, and churning it buys nothing.
$script:Marker = '### heis-standalone ###'

# This script's own source text, captured at script scope because $MyInvocation
# inside a function describes the function instead.
#
# Needed because the relay task has to point at a file on disk, and there is no
# file when the script arrives down a pipe:
#
#     irm https://heis.d0.si/Heis.ps1 | iex
#
# So Resolve-SelfPath writes this text out and points the task there. Doing it
# for a file-based run too, rather than using $PSCommandPath, keeps the task
# independent of wherever the copy you ran happened to live - a task pointing
# into a Downloads folder someone later tidies up is a task that breaks
# silently, weeks later.
$script:SelfSource = $MyInvocation.MyCommand.ScriptBlock.ToString()

# --------------------------------------------------------------- native ---
# Run a native command so that its stderr cannot end the script.
#
# Windows PowerShell 5.1 turns every redirected stderr line into an ErrorRecord,
# and under $ErrorActionPreference 'Stop' the first one throws. So `schtasks
# /query` for a task that does not exist yet - the normal first run - ended the
# run instead of answering "missing". pwsh 7.2+ does not do this, which is how
# it stayed hidden while the SSH side was pwsh; heis.cmd and a stock install
# run 5.1. Output and stderr come back as plain strings, and $LASTEXITCODE is
# the verdict. The script block sees the caller's variables, as any does.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock] $Command)
    $ErrorActionPreference = 'Continue'
    & $Command 2>&1 | ForEach-Object { "$_" }
}

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

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, UIntPtr w, string l, uint flags, uint timeout, out UIntPtr result);

    // WM_SETTINGCHANGE "Environment", so Explorer - and every terminal it
    // starts afterwards - picks up a changed PATH without a logoff. Reaches
    // only this session's desktop: from SSH, Explorer never hears it.
    public static void EnvironmentChanged() { UIntPtr r; SendMessageTimeoutW(new IntPtr(0xFFFF), 0x001A, UIntPtr.Zero, "Environment", 0x0002, 2000, out r); }
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

# Prove the whole path works, without breaking anything that already does.
#
# When a session is running, elevating again proves nothing that is not already
# proven - the countdown on screen IS the proof - while ending it costs a live
# admin session, files another audit event, and leaves you worse off than
# before if the re-elevation then fails. So that case only confirms the relay
# and status round-trip. With nothing running, a real elevation is both the
# best test available and something you wanted anyway.
function Invoke-Verify {
    param([int] $Seconds)

    if ((Get-AbrState).Active) {
        return "verifisert - relayet svarer, og heisen gikk allerede"
    }
    $msg = Invoke-Elevate -Seconds $Seconds
    return "verifisert - $msg"
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
        'Verify'  { Invoke-Verify  -Seconds $Seconds }
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
    $out = Invoke-Native { schtasks /query /tn $script:TaskName /xml }
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
        $null = Invoke-Native { schtasks /create /tn $script:TaskName /xml $path /f }
        return ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

# Settle on a task name that works, and leave $script:TaskName pointing at it.
# Returns 'reused' or 'registered', for -Doctor to report.
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
        if ($null -ne $have -and $have.Contains($Self)) { return 'reused' }

        if (Register-RelayTask -Self $Self) { return 'registered' }
    }

    $script:TaskName = $script:TaskNameDefault
    throw @"
could not register a relay task under any name.

Creating scheduled tasks may be blocked by policy on this machine. Check with:
    schtasks /create /tn HeisTest /tr cmd.exe /sc once /st 00:00 /f
"@
}

# Whether THIS account has a desktop session to relay into.
#
# `schtasks /run` reports success even when the task cannot actually start
# because nobody is logged on, so the only way to notice used to be the reply
# never arriving - 75 seconds later. An explorer.exe outside session 0 is a
# reliable, cheap sign that a desktop session exists to relay into.
#
# It has to be this account's session. The relay task runs as this user with
# an interactive token, so another account's desktop is no use to it - and an
# explorer.exe check cannot tell whose it is without admin. A second local
# account logging in over SSH saw the owner's explorer, fired a task that could
# never start, and sat out the full 75 seconds. `query user` names each
# session's owner and works unprivileged; the explorer check stays as the
# fallback for SKUs that do not ship it.
function Test-DesktopSession {
    # Judged by the header, not the exit code: run from session 0, `query user`
    # lists the sessions correctly and still exits 1.
    $sessions = @(Invoke-Native { query user })
    if ($sessions.Count -gt 0 -and $sessions[0] -match 'USERNAME') {
        # USERNAME is truncated to 20 characters, and the caller's own session
        # is prefixed with '>'.
        $me = $env:USERNAME
        if ($me.Length -gt 20) { $me = $me.Substring(0, 20) }
        $mine = @($sessions | Select-Object -Skip 1 | Where-Object {
            ($_ -replace '^[\s>]+', '' -split '\s+')[0] -eq $me
        })
        return ($mine.Count -gt 0)
    }
    $explorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue |
                  Where-Object { $_.SessionId -ne 0 })
    return ($explorer.Count -gt 0)
}

$script:NoSessionHelp = @'
this account has no desktop session, so there is nothing to drive.

The session may be disconnected - that is fine - but it has to exist. Connect
over RDP once (or sign in at the console) and this works from here afterwards.
After a reboot that has to happen again.
'@

function Invoke-ViaSession {
    param([string] $Action, [int] $Seconds)

    if (-not (Test-DesktopSession)) { throw $script:NoSessionHelp }

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

    $null = Resolve-RelayTask -Self (Resolve-SelfPath)

    $out = Invoke-Native { schtasks /run /tn $script:TaskName }
    if ($LASTEXITCODE -ne 0) {
        # A disabled task refuses to run. Enabling one this account owns is
        # within its rights, so try that before giving up.
        $null = Invoke-Native { schtasks /change /tn $script:TaskName /enable }
        $out  = Invoke-Native { schtasks /run /tn $script:TaskName }
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
    throw @"
no reply from the interactive session within $($Seconds + 45)s.

The relay task was started but never answered. Usually an earlier run of it is
still going - Task Scheduler ignores a new start until that one ends - so try
again in a minute. If it keeps happening, run heis -Doctor.
"@
}

# --------------------------------------------------------------- profile ---
$script:BlockBegin = '# >>> heis >>>'
$script:BlockEnd   = '# <<< heis <<<'

# The logon block, for a given Heis.ps1 path.
#
# Built from a single-quoted template with placeholders so none of the block's
# own $variables are interpolated while it is written out. Escaping a dozen of
# them by hand works right until one is missed, and a missed one bakes this
# run's values into somebody's profile.
function New-ProfileBlock {
    param([Parameter(Mandatory)][string] $Target, [bool] $AutoElevate = $true)

    $quoted = $Target.Replace("'", "''")   # single quotes are legal in a path

    $template = @'
__BEGIN__
# Added by Heis.ps1 -AddToProfile. Delete this block, or run heis -Uninstall,
# to stop it.

# Take the heis automatically on remote logon. $false reports status only.
$HEIS_AUTO_ELEVATE = __AUTO__
$HEIS_PATH         = '__PATH__'

# Live admin check, on purpose not [WindowsPrincipal]::IsInRole: a process
# token carries the group membership it was born with, so a shell started
# before elevation answers "not admin" for the rest of its life however
# elevated the account becomes. A function rather than a variable for the same
# reason - a variable set at logon is a snapshot that quietly goes stale.
function Test-IsAdmin {
    ((net localgroup Administrators 2>$null) -join "`n") -match [regex]::Escape($env:USERNAME)
}

# Status comes from Heis.ps1 itself, which reads the countdown window on the
# desktop rather than inferring anything from this process.
function Show-HeisStatus {
    if (-not (Test-Path -LiteralPath $HEIS_PATH)) {
        Write-Host "heis: finner ikke $HEIS_PATH - irm https://heis.d0.si/install.ps1 | iex" -ForegroundColor DarkYellow
        return $null
    }

    $h = & $HEIS_PATH -Status -PassThru
    if     (-not $h)    { return $null }    # the error is already on screen
    if     ($h.Active)  { Write-Host "ABR aktiv - $($h.Remaining) igjen"  -ForegroundColor Green }
    elseif ($h.InGroup) { Write-Host 'admin, men ingen ABR-nedtelling'    -ForegroundColor DarkYellow }
    else                { Write-Host 'ikke elevert'                       -ForegroundColor Yellow }
    return $h
}

$heis = Show-HeisStatus

# SSH_CONNECTION is set by the SSH server for its own sessions and by nothing
# else - a better test than session id, which also catches services. At the
# desktop you can take the heis by hand.
if ($HEIS_AUTO_ELEVATE -and $env:SSH_CONNECTION -and $heis -and -not $heis.Active) {
    & $HEIS_PATH | Out-Null
    $heis = Show-HeisStatus      # report where that left things
}
__END__
'@

    $auto = if ($AutoElevate) { '$true' } else { '$false' }
    return $template.Replace('__BEGIN__', $script:BlockBegin).
                     Replace('__END__',   $script:BlockEnd).
                     Replace('__AUTO__',  $auto).
                     Replace('__PATH__',  $quoted)
}

# Every profile a heis block may be in. Windows PowerShell and pwsh keep
# separate ones and an SSH login may start either, so -Uninstall and -Doctor
# look in both, not just the one this process happens to have loaded.
# MyDocuments rather than $HOME\Documents, because it follows a Documents
# folder redirected into OneDrive.
function Get-ProfilePaths {
    $docs  = [Environment]::GetFolderPath('MyDocuments')
    $paths = @([string]$PROFILE)
    if ($docs) {
        $paths += Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        $paths += Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'
    }
    $seen = @{}                                  # hashtable keys ignore case, as paths do
    foreach ($p in $paths) {
        if ($p -and -not $seen.ContainsKey($p)) { $seen[$p] = $true; $p }
    }
}

# The heis block in one profile file - where it points and whether it
# elevates - or $null when there is none. Read with ReadAllText and never judged
# by Length: a OneDrive placeholder reports 0 bytes while holding the lot.
function Read-ProfileBlock {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $pattern = [regex]::Escape($script:BlockBegin) + '.*?' + [regex]::Escape($script:BlockEnd)
    $m = [regex]::Match([IO.File]::ReadAllText($Path), $pattern, 'Singleline')
    if (-not $m.Success) { return $null }

    $target = $null
    $auto   = $true
    if ($m.Value -match '(?m)^\$HEIS_PATH\s*=\s*''((?:[^'']|'''')*)''') { $target = $Matches[1].Replace("''", "'") }
    if ($m.Value -match '(?m)^\$HEIS_AUTO_ELEVATE\s*=\s*\$(\w+)')      { $auto   = $Matches[1] -eq 'true' }
    [pscustomobject]@{ Path = $Path; Target = $target; AutoElevate = $auto }
}

# Put $Block into a profile file in place of any existing heis block, or with
# an empty $Block just take the old one out. Returns whether the file changed.
function Set-ProfileBlock {
    param([Parameter(Mandatory)][string] $Path, [string] $Block)

    $existing = ''
    $encoding = [Text.UTF8Encoding]::new($false)
    if (Test-Path -LiteralPath $Path) {
        $encoding = Get-TextEncoding -Bytes ([IO.File]::ReadAllBytes($Path))
        $existing = [IO.File]::ReadAllText($Path, $encoding)
    } elseif (-not $Block) {
        return $false
    }

    $pattern = [regex]::Escape($script:BlockBegin) + '.*?' + [regex]::Escape($script:BlockEnd)
    $cleaned = ([regex]::Replace($existing, $pattern, '', 'Singleline')).TrimEnd()

    if ($Block) {
        $updated = if ($cleaned) { "$cleaned`r`n`r`n$Block`r`n" } else { "$Block`r`n" }
    } else {
        if ($cleaned -eq $existing.TrimEnd()) { return $false }   # no block to remove
        $updated = if ($cleaned) { "$cleaned`r`n" } else { '' }
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Written back in the encoding it came in, BOM and all - see
    # Get-TextEncoding. This file belongs to the user, not to heis.
    [IO.File]::WriteAllText($Path, $updated, $encoding)
    return $true
}

# The encoding a profile is already in, so that rewriting it changes only the
# heis block. Windows PowerShell reads a BOM-less file as ANSI, so a profile
# holding Norwegian letters may be UTF-8 with a BOM, UTF-16 with one, or plain
# ANSI - and writing any of them back as BOM-less UTF-8 mangles those letters
# on the next load. Bytes that decode as strict UTF-8 are taken as UTF-8, which
# covers pure ASCII, where the choice makes no difference.
function Get-TextEncoding {
    param([byte[]] $Bytes)

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.UTF8Encoding]::new($true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [Text.UnicodeEncoding]::new($false, $true) }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [Text.UnicodeEncoding]::new($true, $true) }
    try {
        $null = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        return [Text.UTF8Encoding]::new($false)
    } catch {
        # The SYSTEM ANSI code page - what Windows PowerShell actually reads a
        # BOM-less file as - not the current culture's, which can differ.
        $acp = 1252
        try { $acp = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction Stop).ACP } catch { }
        return [Text.Encoding]::GetEncoding($acp)
    }
}

# ------------------------------------------------------------------ path ---
# The installer's default home for Heis.ps1. Ours entirely, so -Uninstall
# removes the whole folder; anywhere else, only what heis wrote there.
$script:InstallDirDefault = Join-Path $env:LOCALAPPDATA 'Programs\Heis'
$script:ShimMarker        = 'heis-shim'

# The user PATH, expanded, one directory per entry without a trailing slash.
function Get-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        $raw = [string] $key.GetValue('Path', '')
    } finally { $key.Close() }
    $raw -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
}

# Add a directory to the user PATH, or take it out with -Remove. Returns
# whether anything changed.
#
# Edited in the registry rather than with [Environment]::SetEnvironmentVariable.
# That reads the value expanded and writes it back as REG_SZ, which quietly
# turns every %USERPROFILE%-style entry - Windows ships one - into a hardcoded
# path. So: read raw, keep the value kind, touch only our own entry.
function Edit-UserPath {
    param([Parameter(Mandatory)][string] $Dir, [switch] $Remove)

    $want = $Dir.TrimEnd('\')
    $same = { [Environment]::ExpandEnvironmentVariables($args[0]).TrimEnd('\') -eq $want }   # -eq ignores case

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $raw  = [string] $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') { $kind = $key.GetValueKind('Path') }

        $entries = @($raw -split ';' | Where-Object { $_ })
        $present = @($entries | Where-Object { & $same $_ }).Count -gt 0

        if ($Remove) {
            if (-not $present) { return $false }
            $entries = @($entries | Where-Object { -not (& $same $_) })
        } else {
            if ($present) { return $false }
            $entries += $want
        }
        $key.SetValue('Path', ($entries -join ';'), $kind)
    } finally { $key.Close() }

    # Best effort: an older HeisWin32 already loaded in this process lacks the
    # method, and a missed broadcast only means "open a new terminal".
    try { Initialize-Win32; [HeisWin32]::EnvironmentChanged() } catch { }
    return $true
}

# Write heis.cmd beside Heis.ps1 and put that folder on the PATH. Returns
# whether the PATH changed.
#
# The .cmd is for everything that is not PowerShell: cmd.exe, Git Bash, and an
# SSH login, which lands in cmd.exe unless the server's DefaultShell says
# otherwise. PowerShell itself picks Heis.ps1 over heis.cmd when both sit in
# one folder, which is what we want there - objects on the pipeline, not text.
# The .cmd is not subject to execution policy, and passes Bypass on so that a
# shell that refuses to run Heis.ps1 directly can still reach it through here.
function Add-HeisToPath {
    param([Parameter(Mandatory)][string] $Dir)

    $shim = @(
        '@echo off'
        "rem $($script:ShimMarker): written by Heis.ps1 -AddToPath, removed by heis -Uninstall."
        '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Heis.ps1" %*'
        'exit /b %ERRORLEVEL%'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $Dir 'heis.cmd'), "$shim`r`n", [Text.Encoding]::ASCII)

    $changed = Edit-UserPath -Dir $Dir

    # This process too, so `heis` works in the shell that ran the installer.
    $want = $Dir.TrimEnd('\')
    if (@($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -eq $want }).Count -eq 0) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $want
    }
    return $changed
}

# Every folder on the user PATH holding a heis.cmd that heis wrote - not just
# the one beside the copy that happens to be running.
function Get-HeisPathDirs {
    foreach ($dir in Get-UserPath) {
        $shim = Join-Path $dir 'heis.cmd'
        if ((Test-Path -LiteralPath $shim) -and ([IO.File]::ReadAllText($shim)).Contains($script:ShimMarker)) { $dir }
    }
}

# ---------------------------------------------------------------- doctor ---
# Each check prints as it completes - the relay round trip takes seconds, and a
# report that appears all at once looks hung until it does - and is returned
# for -PassThru.
function New-Check {
    param([string] $Check, [string] $State, [string] $Detail)

    $color = @{ ok = 'Green'; fixed = 'Cyan'; info = 'DarkGray'; warn = 'Yellow'; fail = 'Red' }[$State]
    $lines = @($Detail -split "`n")
    Write-Host ('  {0,-5} {1,-17} {2}' -f $State, $Check, $lines[0]) -ForegroundColor $color
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        Write-Host ((' ' * 26) + $line) -ForegroundColor $color
    }
    [pscustomobject]@{ Check = $Check; State = $State; Detail = $Detail }
}

# The execution policy a NEW shell of this edition gets: Get-ExecutionPolicy
# minus the Process scope. Through heis.cmd the process runs with Bypass, which
# would say "fine" about a shell where typing `heis` fails.
function Get-PersistentPolicy {
    $list = @(Get-ExecutionPolicy -List)
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        $p = [string]($list | Where-Object { [string]$_.Scope -eq $scope } | Select-Object -First 1).ExecutionPolicy
        if ($p -and $p -ne 'Undefined') {
            return [pscustomobject]@{ Policy = $p; Locked = ($scope -like '*Policy') }
        }
    }
    # Nothing set: the edition's built-in default.
    $default = if ($PSVersionTable.PSEdition -eq 'Core') { 'RemoteSigned' } else { 'Restricted' }
    return [pscustomobject]@{ Policy = $default; Locked = $false }
}

# Check everything heis depends on, repair what belongs to heis, and say what
# to do about the rest. Read-only towards anything heis does not own: it never
# touches execution policy, the SSH server, or another task.
function Invoke-Doctor {
    $self = $null
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) { $self = $PSCommandPath }
    $edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'Windows PowerShell' }

    New-Check 'PowerShell' ok "$edition $($PSVersionTable.PSVersion), session $($script:MySession)"

    $policy = Get-PersistentPolicy
    if ($policy.Policy -notin 'Restricted', 'AllSigned') {
        New-Check 'execution policy' ok "$($policy.Policy) ($edition)"
    } elseif ($policy.Locked) {
        New-Check 'execution policy' fail ("$($policy.Policy), set by group policy. No script file can run here,`n" +
            "heis and its relay included - ask whoever manages this machine.")
    } else {
        New-Check 'execution policy' warn ("$($policy.Policy) ($edition) - PowerShell will not run Heis.ps1 or the logon block.`n" +
            "heis.cmd still works. Fix, no admin needed:`n" +
            "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
    }

    try {
        New-Check 'Admin By Request' ok (Resolve-AbrExe)
    } catch {
        New-Check 'Admin By Request' fail ("not found. Install the Admin By Request client first, or pass`n" +
            "its path with -Exe <path> if it lives somewhere unusual.")
    }

    $hasDesktop = Test-DesktopSession
    if ($hasDesktop) {
        $where = if ($script:MySession -eq 0) { 'exists - disconnected is fine' } else { "this one (session $($script:MySession))" }
        New-Check 'desktop session' ok $where
    } else {
        New-Check 'desktop session' fail ("none for $env:USERNAME. Connect over RDP once - it may be`n" +
            "disconnected afterwards. Needed again after every reboot.")
    }

    try {
        $how = Resolve-RelayTask -Self (Resolve-SelfPath)
        if ($how -eq 'reused') { New-Check 'relay task' ok "'$($script:TaskName)'" }
        else                   { New-Check 'relay task' fixed "registered '$($script:TaskName)'" }
    } catch {
        New-Check 'relay task' fail $_.Exception.Message
    }

    # The one failure nothing else can see. A second caller of /Elevate that
    # leaves ABR's Confirm dialog unanswered wedges ABR until a reboot, and the
    # symptom - no countdown - points straight at heis. See AGENTS.md.
    $others = @(Invoke-Native { schtasks /query /fo csv /v /nh } |
        Where-Object { $_ -match '(?i)AdminByRequest[^,]*/Elevate' } |
        ForEach-Object { ($_ | ConvertFrom-Csv -Header Host, Name).Name } |
        Where-Object { $_ -and $_ -notlike "*$($script:TaskNameDefault)*" } |
        Select-Object -Unique)
    if ($others) {
        New-Check 'other callers' warn ("these scheduled tasks also start ABR /Elevate: $($others -join ', ').`n" +
            "One that leaves a Confirm dialog unanswered wedges ABR until a reboot.")
    } else {
        New-Check 'other callers' ok 'no other scheduled task starts ABR /Elevate'
    }

    if ($hasDesktop) {
        try {
            if ($script:MySession -eq 0) {
                $r = Invoke-ViaSession -Action 'Status' -Seconds $WaitSec
                New-Check 'relay round trip' ok $r.Message
            } else {
                New-Check 'status' ok (Format-Status)
            }
        } catch {
            New-Check 'relay round trip' fail $_.Exception.Message
        }
    }

    # Whether this copy is THE installed one: beside a heis.cmd that heis wrote,
    # in a folder on the PATH. Only then may it repoint logon blocks at itself.
    $installed = $false
    if ($self) {
        $dir  = Split-Path -Parent $self
        $shim = Join-Path $dir 'heis.cmd'
        if (-not (Test-Path -LiteralPath $shim)) {
            New-Check 'PATH' info 'heis is not on the PATH. heis -AddToPath puts it there.'
        } elseif (-not ([IO.File]::ReadAllText($shim)).Contains($script:ShimMarker)) {
            New-Check 'PATH' warn "$shim was not written by heis - left alone, and $dir not added to the PATH."
        } else {
            # Rewritten every time, PATH entry or not: it is ours, and this
            # also repairs one that was edited or truncated.
            if (Add-HeisToPath -Dir $dir) {
                New-Check 'PATH' fixed "put $dir back on the user PATH - open a new terminal"
            } else {
                New-Check 'PATH' ok $dir
            }
            $installed = $true
        }
    }

    $blocks = @(Get-ProfilePaths | ForEach-Object { Read-ProfileBlock -Path $_ } | Where-Object { $_ })
    if (-not $blocks) {
        New-Check 'logon block' info 'none. heis -AddToProfile adds one.'
    }
    foreach ($b in $blocks) {
        $mode = if ($b.AutoElevate) { 'elevates over SSH' } else { 'status only' }
        if ($b.Target -and (Test-Path -LiteralPath $b.Target)) {
            if ($installed -and $b.Target -ne $self) {
                # An install from before heis had a folder of its own, still
                # running an old copy. Repointed, keeping its settings.
                $null = Set-ProfileBlock -Path $b.Path -Block (New-ProfileBlock -Target $self -AutoElevate $b.AutoElevate)
                New-Check 'logon block' fixed "$($b.Path) ran an older copy, $($b.Target).`nNow $self ($mode) - the old file can be deleted."
            } else {
                New-Check 'logon block' ok "$($b.Path) ($mode)"
            }
        } elseif ($self) {
            $null = Set-ProfileBlock -Path $b.Path -Block (New-ProfileBlock -Target $self -AutoElevate $b.AutoElevate)
            New-Check 'logon block' fixed "$($b.Path) pointed at a missing file - now $self"
        } else {
            New-Check 'logon block' warn "$($b.Path) points at $($b.Target), which is gone. Re-run the installer."
        }
    }

    # Over SSH the logon block only runs if the server starts a PowerShell
    # whose profile has it. The server's choice is a machine setting, readable
    # without admin but only changeable with it.
    # The registry key only exists once something has written to it; a stock
    # sshd has the service and no key, and then starts cmd.exe.
    $sshd = Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue
    $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if (($sshd -or $sshdService) -and $blocks) {
        $shell = [string]$sshd.DefaultShell
        $docs  = [Environment]::GetFolderPath('MyDocuments')
        $sshProfile = $null
        if     ($shell -match '(?i)pwsh(\.exe)?$')       { $sshProfile = Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1' }
        elseif ($shell -match '(?i)powershell(\.exe)?$') { $sshProfile = Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1' }

        if (-not $shell) {
            # New-Item only when the key is missing: -Force on an existing
            # registry key replaces it, values and all.
            $makeKey = if ($sshd) { '' } else { "  New-Item HKLM:\SOFTWARE\OpenSSH`n" }
            New-Check 'SSH shell' warn ("cmd.exe - the logon block never runs over SSH, though heis does.`n" +
                "An admin can make it PowerShell:`n" + $makeKey +
                "  New-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Force -Value `"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`"")
        } elseif (-not $sshProfile) {
            New-Check 'SSH shell' info "$shell - not PowerShell, so the logon block does not run over SSH"
        } elseif (@($blocks | Where-Object { $_.Path -eq $sshProfile }).Count -gt 0) {
            New-Check 'SSH shell' ok $shell
        } else {
            $flag = if ($blocks[0].AutoElevate) { '' } else { ' -AutoElevateOnLogin $false' }
            $fix  = if ($self) { "  & `"$shell`" -NoProfile -Command `"& '$self' -AddToProfile$flag`"" } else { '  re-run the installer from that shell' }
            New-Check 'SSH shell' warn ("$shell reads a profile without the heis block, so SSH logins skip it. Fix:`n$fix")
        }
    }
}

# ------------------------------------------------------------------ help ---
function Show-Usage {
    Write-Host @'
heis - Admin By Request elevation, one command. No admin rights needed.

  heis                 take the heis: elevate, unless it is already up
  heis -Status         which floor are we on
  heis -Finish         take it down: end the ABR session
  heis -Verify         prove the whole path works (elevates if not up)
  heis -Doctor         check the setup, repair what can be repaired
  heis -AddToPath      run heis from any terminal (user PATH)
  heis -AddToProfile   status on logon, and elevate on SSH logon
        -AutoElevateOnLogin $false     ... status only
  heis -Uninstall      remove everything heis has set up
  heis -PassThru       with any of the above: an object, not text

  Get-Help heis -Full  all of it, with examples
  https://heis.d0.si
'@
}

# ----------------------------------------------------------------- main ---
# `exit` from a file sets the exit code heis.cmd and the installer read. Under
# `irm | iex` or `& ([scriptblock]::Create(...))` there is no file, and `exit`
# there closes the user's whole shell - an SSH session included - which is why
# every exit below is guarded by $PSCommandPath. That is set only for a file
# run, even when iex is called from inside some other script.
if ($Help) {
    Show-Usage
    $global:LASTEXITCODE = 0
    if ($PSCommandPath) { exit 0 }
    return
}

# Session 0 is the non-interactive services session, which is where an SSH
# login lands. It can see none of the desktop's windows, so the work has to
# happen somewhere else.
$script:MySession = (Get-Process -Id $PID).SessionId

if ($Uninstall) {
    # Everything that should be gone and is not. Reported at the end rather
    # than stopping at the first, so one stubborn item does not leave the rest
    # behind too.
    $left = @()

    # Both names, since a fallback task may have been registered alongside the
    # canonical one. A task registered from an elevated context cannot be
    # deleted from an unelevated one.
    foreach ($name in @($script:TaskNameDefault, "$($script:TaskNameDefault) ($env:USERNAME)")) {
        $script:TaskName = $name
        $null = Invoke-Native { schtasks /delete /tn $name /f }
        if ($LASTEXITCODE -ne 0 -and $null -ne (Get-RelayTaskArguments)) {
            $left += "scheduled task '$name' - from an elevated shell:  schtasks /delete /tn `"$name`" /f"
        }
    }
    $script:TaskName = $script:TaskNameDefault

    # Every PATH entry and shim heis wrote, wherever it was installed from.
    $gone = @()
    foreach ($dir in @(Get-HeisPathDirs)) {
        $null = Edit-UserPath -Dir $dir -Remove
        $shim = Join-Path $dir 'heis.cmd'
        Remove-Item -LiteralPath $shim -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $shim) { $left += $shim }
        $gone += $dir
        Write-Host "  PATH: fjernet $dir" -ForegroundColor DarkGray
    }
    if ($gone) {
        $env:Path = (@($env:Path -split ';' | Where-Object { $_ -and ($gone -notcontains $_.TrimEnd('\')) })) -join ';'
    }

    foreach ($p in @(Get-ProfilePaths)) {
        if (Set-ProfileBlock -Path $p -Block '') { Write-Host "  profil: fjernet blokken i $p" -ForegroundColor DarkGray }
    }

    foreach ($dir in @($script:StateDir, $script:InstallDirDefault)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dir) { $left += $dir } else { Write-Host "  fjernet $dir" -ForegroundColor DarkGray }
    }
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        Write-Host "  $PSCommandPath er igjen - slett den selv om du vil" -ForegroundColor DarkGray
    }

    if (-not $left) {
        Write-Host 'heis avinstallert' -ForegroundColor Green
        $global:LASTEXITCODE = 0
        if ($PSCommandPath) { exit 0 }
        return
    }

    # Do not claim success for work that did not happen.
    Write-Host 'heis er avinstallert, unntatt:' -ForegroundColor Yellow
    foreach ($item in $left) { Write-Host "  $item" -ForegroundColor Yellow }
    $global:LASTEXITCODE = 1
    if ($PSCommandPath) { exit 1 }
    return
}

# -AddToPath and -AddToProfile are settings, not actions, so on their own they
# configure and stop. The installer pairs them with -Doctor and -Verify to
# prove the thing works once it is wired up.
if (($AddToPath -or $AddToProfile) -and -not $InSession) {
    $self = $PSCommandPath
    if (-not $self -or -not (Test-Path -LiteralPath $self)) { $self = Resolve-SelfPath }

    if ($AddToPath) {
        $dir = Split-Path -Parent $self
        if (Add-HeisToPath -Dir $dir) {
            Write-Host 'Lagt til i PATH - heis virker i alle nye terminaler' -ForegroundColor Green
        } else {
            Write-Host 'heis er allerede i PATH' -ForegroundColor Green
        }
        Write-Host "  $dir" -ForegroundColor DarkGray
    }

    if ($AddToProfile) {
        $null = Set-ProfileBlock -Path $PROFILE -Block (New-ProfileBlock -Target $self -AutoElevate $AutoElevateOnLogin)
        if ($AutoElevateOnLogin) {
            Write-Host 'Lagt til i profilen - heisen tas automatisk ved SSH-innlogging' -ForegroundColor Green
        } else {
            Write-Host 'Lagt til i profilen - status vises ved innlogging, men heisen tas ikke' -ForegroundColor Green
        }
        Write-Host "  $PROFILE" -ForegroundColor DarkGray
    }
}

if ($Doctor -and -not $InSession) {
    $checks = @(Invoke-Doctor)
    $bad    = @($checks | Where-Object { $_.State -eq 'fail' })
    Write-Host ''
    if ($bad) {
        Write-Host "  $($bad.Count) problem(s) left - see the fail lines above." -ForegroundColor Red
    } else {
        Write-Host '  heisen er klar' -ForegroundColor Green
    }
    if ($PassThru) { $checks }

    $code = if ($bad) { 1 } else { 0 }
    $global:LASTEXITCODE = $code
    if ($PSCommandPath) { exit $code }
    return
}

$action = $null
if     ($Verify) { $action = 'Verify' }
elseif ($Finish) { $action = 'Finish' }
elseif ($Status) { $action = 'Status' }
elseif (-not ($AddToProfile -or $AddToPath)) { $action = 'Elevate' }

if (-not $action) {
    $global:LASTEXITCODE = 0
    if ($PSCommandPath) { exit 0 }
    return
}

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

try {
    if ($script:MySession -eq 0) {
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
    Write-Host 'heis -Doctor sjekker hele oppsettet.' -ForegroundColor DarkGray
    $global:LASTEXITCODE = 1
    if ($PSCommandPath) { exit 1 }
    return
}

# The message on the pipeline, so `$s = heis -Status` captures it and an
# interactive run still prints it. Write-Host would do neither: it cannot be
# captured, and emitting both would print twice.
if ($PassThru) { $result } else { $result.Message }

# Exit 0 explicitly. Left alone, $LASTEXITCODE is whatever native command ran
# last - `query user` exits 1 from session 0 even when it works - and the
# installer, heis.cmd and any caller checking it would read that as failure.
$global:LASTEXITCODE = 0
if ($PSCommandPath) { exit 0 }
