<#
.SYNOPSIS
    Kjører heisen - request Admin By Request elevation, unless it is already up.

.DESCRIPTION
    Asks the desktop session whether an ABR window is already counting down. If
    one is, this does nothing and reports the time left; otherwise it launches
    /Elevate and clicks through the two dialogs.

    Safe to run repeatedly and safe to run over SSH, which is the point: the
    check reads the state of the interactive session rather than of whatever
    process happens to be asking.

.EXAMPLE
    .\heis.ps1
    .\heis.ps1 -Status
    .\heis.ps1 -Force
#>
[CmdletBinding()]
param(
    # Report and exit without elevating.
    [switch] $Status,

    # End the running session by pressing Finish on ABR's countdown window.
    [switch] $Finish,

    # Elevate even if a session already looks active. Rarely useful: with a
    # session running, /Elevate exits silently without showing a dialog, so the
    # macro just waits for a confirmation that never comes and times out.
    [switch] $Force,

    [string] $Exe = 'C:\Program Files (x86)\FastTrack Software\Admin By Request\AdminByRequest.exe',

    # Titles overlap - "Admin By Request" is a substring of "Admin By Request
    # Confirm" - so both are matched exactly. Without exact:, whichever window
    # was activated last wins and the macro presses the wrong dialog.
    [string] $ConfirmWindow = 'exact: Admin By Request Confirm',
    [string] $ConfirmButton = 'Yes',
    [string] $OkWindow      = 'exact: Admin By Request',
    [string] $OkButton      = 'OK',

    [int] $WaitSec = 20
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$client = Join-Path $root 'Send-AhkCommand.ps1'

# Is an ABR session running, and how long is left?
#
# Read from the countdown window ABR leaves on the desktop, whose title IS the
# remaining time. That beats both of the obvious alternatives:
#
#   - A token check ([WindowsPrincipal]::IsInRole) reports the group membership
#     the CURRENT PROCESS was born with. A shell that started before elevation
#     keeps saying "not admin" for its whole life, however elevated the account
#     becomes. Measured: ABR active, countdown on screen, account in local
#     Administrators, and IsInRole still False in an SSH session opened earlier.
#   - The event log needs a provider name that is not present on this machine,
#     and then needs the policy window length hardcoded to turn a start time
#     into a remaining time. The window title already is the remaining time.
#
# Local group membership is checked too, since it is live rather than a
# snapshot, and disagreement between the two is worth surfacing.
function Get-AbrState {
    $state = [pscustomobject]@{
        Active    = $false
        Remaining = $null
        Hwnd      = $null
        InGroup   = $false
        Note      = ''
    }

    # net localgroup is queried fresh every call, so unlike a process token it
    # notices elevation granted after this script started.
    try {
        $state.InGroup = ((net localgroup Administrators 2>$null) -join "`n") -match [regex]::Escape($env:USERNAME)
    } catch { }

    $reply = & $client windows 2>$null
    if ($LASTEXITCODE -ne 0) {
        $state.Note = 'no agent reachable - cannot see the desktop session'
        return $state
    }

    foreach ($line in (($reply | Out-String) -split "`n")) {
        # "<hwnd> [<class>] (<exe>) <title>" - match the exe as well as the
        # clock-shaped title, so another app showing a time cannot be mistaken
        # for an elevation session.
        if ($line -match '^(\d+)\s+\[[^\]]+\]\s+\(AdminByRequest\.exe\)\s+(\d{1,2}:\d{2}:\d{2})\s*$') {
            $state.Hwnd      = $Matches[1]
            $state.Active    = $true
            $state.Remaining = $Matches[2]
            break
        }
    }

    if ($state.Active -and -not $state.InGroup) {
        $state.Note = 'countdown is up but the account is not in Administrators - session may be expiring'
    } elseif ($state.InGroup -and -not $state.Active) {
        $state.Note = 'account is in Administrators but no countdown window - elevated by something other than ABR, or the window was closed'
    }

    return $state
}

$abr = Get-AbrState

if ($abr.Active) {
    Write-Host "heisen går allerede - $($abr.Remaining) igjen" -ForegroundColor Green
} elseif ($abr.InGroup) {
    Write-Host "konto er admin, men ingen ABR-nedtelling" -ForegroundColor DarkYellow
} else {
    Write-Host "ikke elevert" -ForegroundColor Yellow
}
if ($abr.Note) { Write-Host "  ($($abr.Note))" -ForegroundColor DarkGray }

if ($Status) { return }

if ($Finish) {
    if (-not $abr.Active) {
        Write-Host "ingen heis å stoppe" -ForegroundColor DarkGray
        return
    }
    # Addressed by hwnd, not by title: the countdown window's title is a clock
    # and changes every second, so any title match races the tick.
    Write-Host "stopper heisen..." -ForegroundColor Cyan
    & $client "press-text ahk_id $($abr.Hwnd) | Finish" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'could not press Finish' }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Seconds 2
        $after = Get-AbrState
    } while ($after.Active -and (Get-Date) -lt $deadline)

    if ($after.Active) {
        Write-Warning "Finish pressed but the session is still running ($($after.Remaining) left)."
        exit 1
    }
    Write-Host "heisen er nede" -ForegroundColor Green
    return
}

if ($abr.Active -and -not $Force) {
    Write-Host "ingenting å gjøre. -Force for å kjøre likevel." -ForegroundColor DarkGray
    return
}

Write-Host "kjører heisen..." -ForegroundColor Cyan

& (Join-Path $root 'Run-Macro.ps1') `
    -Exe $Exe -Arguments '/Elevate' `
    -ConfirmWindow $ConfirmWindow -ConfirmButton $ConfirmButton `
    -OkWindow $OkWindow -OkButton $OkButton `
    -WaitSec $WaitSec

# Confirm it actually took, rather than trusting that the clicks landed. The
# countdown can lag the last dialog by a moment, so allow for that.
$deadline = (Get-Date).AddSeconds(15)
do {
    Start-Sleep -Seconds 2
    $after = Get-AbrState
} while (-not $after.Active -and (Get-Date) -lt $deadline)

if ($after.Active) {
    Write-Host "heisen er oppe - $($after.Remaining) igjen" -ForegroundColor Green
} else {
    Write-Warning "macro ran, but no ABR countdown appeared. Check:  .\Send-AhkCommand.ps1 windows"
    exit 1
}
