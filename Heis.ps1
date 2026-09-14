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

.EXAMPLE
    .\Heis.ps1              # elevate, unless already elevated
    .\Heis.ps1 -Status      # report and exit
    .\Heis.ps1 -Finish      # end the running session
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
$script:TaskName = 'Heis - Admin By Request'
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
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
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

    public static bool Alive(long hwnd) { return IsWindow(new IntPtr(hwnd)); }
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

function Wait-ForWindow {
    param([Parameter(Mandatory)][string] $Title, [int] $Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $w = Find-Window -Title $Title
        if ($w) { return $w }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    throw "timed out after ${Seconds}s waiting for window '$Title'"
}

function Wait-ForWindowGone {
    param([Parameter(Mandatory)][string] $Title, [int] $Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (-not (Find-Window -Title $Title)) { return }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    throw "window '$Title' still open after ${Seconds}s"
}

# Press a button by the caption a person reads off the screen.
#
# Not by index: control ordering is an artefact of creation order and is not
# guessable. On ABR's confirm dialog the buttons are No first and Yes second,
# and on its countdown window the Finish button sits after four labels.
function Press-Button {
    param([Parameter(Mandatory)][int64] $Hwnd, [Parameter(Mandatory)][string] $Caption)

    $want = $Caption.Replace('&', '')
    $ctls = @(Get-Controls -Hwnd $Hwnd)

    $hit = $ctls | Where-Object { $_.Text.Replace('&', '') -eq $want } | Select-Object -First 1
    if (-not $hit) {
        $hit = $ctls | Where-Object { $_.Text.Replace('&', '') -like "*$want*" } | Select-Object -First 1
    }
    if (-not $hit) {
        $seen = ($ctls | Where-Object { $_.Text } | ForEach-Object { "'$($_.Text)'" }) -join ', '
        if (-not $seen) { $seen = '(none - the app draws its own controls)' }
        throw "no button captioned '$Caption'. Found: $seen"
    }

    [HeisWin32]::Click($hit.Hwnd)
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
function Get-AbrState {
    $w = Get-Windows | Where-Object {
        $_.Exe -eq 'AdminByRequest' -and $_.Title -match '^\d{1,2}:\d{2}:\d{2}$'
    } | Select-Object -First 1

    $inGroup = $false
    try { $inGroup = ((net localgroup Administrators 2>$null) -join "`n") -match [regex]::Escape($env:USERNAME) } catch { }

    [pscustomobject]@{
        Active    = [bool] $w
        Remaining = $(if ($w) { $w.Title } else { $null })
        Hwnd      = $(if ($w) { $w.Hwnd }  else { $null })
        InGroup   = $inGroup
    }
}

function Invoke-Elevate {
    param([int] $Seconds)

    $abr = Get-AbrState
    if ($abr.Active) { return "heisen g$($script:AA)r allerede - $($abr.Remaining) igjen" }

    if (-not (Test-Path -LiteralPath $Exe)) { throw "not found: $Exe" }
    Start-Process -FilePath $Exe -ArgumentList '/Elevate' | Out-Null

    $confirm = Wait-ForWindow -Title 'Admin By Request Confirm' -Seconds $Seconds
    Press-Button -Hwnd $confirm.Hwnd -Caption 'Yes'

    $done = Wait-ForWindow -Title 'Admin By Request' -Seconds $Seconds
    Press-Button -Hwnd $done.Hwnd -Caption 'OK'

    # Verify rather than trust: confirm the countdown actually appeared.
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Seconds 1
        $after = Get-AbrState
    } while (-not $after.Active -and (Get-Date) -lt $deadline)

    if (-not $after.Active) { throw 'clicked through, but no countdown appeared' }
    return "heisen er oppe - $($after.Remaining) igjen"
}

function Invoke-Finish {
    param([int] $Seconds)

    $abr = Get-AbrState
    if (-not $abr.Active) { return "ingen heis $($script:AA) stoppe" }

    # Addressed by hwnd: the countdown window's title is a clock and changes
    # every second, so any title match races the tick.
    Press-Button -Hwnd $abr.Hwnd -Caption 'Finish'

    # Finish raises the same "Admin By Request Confirm" dialog the elevation
    # flow uses, asking whether you are done. Its buttons are No then Yes.
    $confirm = Wait-ForWindow -Title 'Admin By Request Confirm' -Seconds $Seconds
    Press-Button -Hwnd $confirm.Hwnd -Caption 'Yes'

    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Seconds 1
        $after = Get-AbrState
    } while ($after.Active -and (Get-Date) -lt $deadline)

    if ($after.Active) { throw "Finish pressed but the session is still running ($($after.Remaining) left)" }
    return 'heisen er nede'
}

function Format-Status {
    $abr = Get-AbrState
    if ($abr.Active) { return "heisen g$($script:AA)r allerede - $($abr.Remaining) igjen" }
    if ($abr.InGroup) { return 'konto er admin, men ingen ABR-nedtelling' }
    return 'ikke elevert'
}

function Invoke-Action {
    param([string] $Action, [int] $Seconds)
    switch ($Action) {
        'Status'  { Format-Status }
        'Finish'  { Invoke-Finish  -Seconds $Seconds }
        default   { Invoke-Elevate -Seconds $Seconds }
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

function Register-RelayTask {
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
    $self = Resolve-SelfPath

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
        $out = schtasks /create /tn $script:TaskName /xml $path /f 2>&1
        if ($LASTEXITCODE -ne 0) { throw "could not register the relay task: $out" }
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ViaSession {
    param([string] $Action, [int] $Seconds)

    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    $id      = [guid]::NewGuid().ToString('N')
    $reqFile = Join-Path $script:StateDir 'request.json'
    $resFile = Join-Path $script:StateDir "result-$id.json"

    @{ Id = $id; Action = $Action; WaitSec = $Seconds; Exe = $Exe } |
        ConvertTo-Json | Set-Content -LiteralPath $reqFile -Encoding UTF8

    # Registered every run rather than only when missing: it is cheap, and it
    # repairs a task left pointing at an older copy of this script.
    Register-RelayTask

    $out = schtasks /run /tn $script:TaskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "could not start the relay task: $out`nIs anyone logged in? The task runs only when a session exists."
    }

    $deadline = (Get-Date).AddSeconds($Seconds + 45)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resFile) {
            $r = Get-Content -LiteralPath $resFile -Raw | ConvertFrom-Json
            Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue
            if (-not $r.Ok) { throw $r.Message }
            return $r.Message
        }
        Start-Sleep -Milliseconds 400
    }
    throw "no reply from the interactive session within $($Seconds + 45)s. Is anyone logged in?"
}

# ----------------------------------------------------------------- main ---
if ($Uninstall) {
    schtasks /delete /tn $script:TaskName /f 2>&1 | Out-Null
    Remove-Item -LiteralPath $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'heis avinstallert' -ForegroundColor Green
    return
}

$action = 'Elevate'
if ($Status) { $action = 'Status' }
if ($Finish) { $action = 'Finish' }

if ($InSession) {
    # Running inside the interactive session, launched by the relay task.
    $reqFile = Join-Path $script:StateDir 'request.json'
    $req = Get-Content -LiteralPath $reqFile -Raw | ConvertFrom-Json
    $resFile = Join-Path $script:StateDir "result-$($req.Id).json"

    try {
        $Exe = $req.Exe
        $msg = Invoke-Action -Action $req.Action -Seconds ([int]$req.WaitSec)
        $result = @{ Ok = $true; Message = $msg }
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
        $msg = Invoke-ViaSession -Action $action -Seconds $WaitSec
    } else {
        $msg = Invoke-Action -Action $action -Seconds $WaitSec
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

$colour = 'Green'
if ($msg -like 'ikke elevert*' -or $msg -like 'ingen heis*') { $colour = 'Yellow' }
Write-Host $msg -ForegroundColor $colour
