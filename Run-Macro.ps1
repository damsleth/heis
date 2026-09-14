<#
.SYNOPSIS
    Launch a program and click through its dialogs, without coordinates and
    without needing anyone connected over RDP.

.DESCRIPTION
    Buttons are addressed by the caption they display, not by position. That is
    what makes this work unattended - it survives the session changing
    resolution, DPI or monitor, none of which a coordinate survives, and it
    needs no input desktop because each press is a BM_CLICK message rather than
    a synthesised mouse click.

    Find the right captions first:

        .\Send-AhkCommand.ps1 windows
        .\Send-AhkCommand.ps1 'buttons <window title>'

    If `buttons` comes back empty the app draws its own controls (WinUI,
    Electron, Chromium). Nothing here will reach it, and the macro has to run
    with someone connected.

    -Arguments is passed to the program verbatim - write it exactly as you would
    type it on a command line, and quote anything containing spaces. Nothing is
    added or rewritten on the way through.

    A caveat specific to switches like /Elevate: this agent runs unelevated, so
    it can neither answer a UAC consent prompt (that appears on the secure
    desktop, where nothing can reach it) nor drive the windows of a process that
    ends up elevated - UIPI blocks both injected input and posted messages from
    a lower integrity level. Check with `active-window` once the app is up: if
    it reports elevated=YES, the agent itself has to run elevated, which means
    re-registering its task with -RunLevel Highest.

.EXAMPLE
    .\Run-Macro.ps1 -Exe notepad.exe
    .\Run-Macro.ps1 -Exe C:\app\thing.exe -ConfirmWindow 'Confirm Action' -ConfirmButton Yes
    .\Run-Macro.ps1 -Exe C:\app\thing.exe -Arguments '/Elevate'
    .\Run-Macro.ps1 -Exe C:\app\thing.exe -Arguments '/Elevate "C:\some path\x.txt"'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Exe,
    [string] $Arguments,

    # The confirmation dialog, and the button on it to press.
    [string] $ConfirmWindow = 'Confirm Action',
    [string] $ConfirmButton = 'Yes',

    # The dialog that follows it, and its button. Leave the window empty to skip.
    [string] $OkWindow = 'Result',
    [string] $OkButton = 'OK',

    # How long each dialog is allowed to take to appear.
    [int] $WaitSec = 30
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$client = Join-Path $root 'Send-AhkCommand.ps1'

function Invoke-Agent {
    param([string] $Command, [int] $TimeoutSec = 15)

    # The agent handles one command at a time, so a wait-window occupies it for
    # the full duration. The client has to outlast that or it gives up on a
    # command that is still running and would have succeeded.
    $reply = & $client -TimeoutSec $TimeoutSec $Command 2>$null
    $text  = ($reply | Out-String)

    if ($LASTEXITCODE -ne 0) {
        $result = ($text -split "`n" | Where-Object { $_ -like 'result:*' }) -join ''
        if (-not $result) { $result = "no reply within ${TimeoutSec}s" }
        throw "$Command --> $result"
    }
    return $text
}

Write-Host "1. launching $Exe" -ForegroundColor Cyan
$cmd = if ($Arguments) { "run `"$Exe`" $Arguments" } else { "run `"$Exe`"" }
Invoke-Agent $cmd | Out-Null

# +10s so the client outlives the agent's own wait rather than racing it.
$clientWait = $WaitSec + 10

Write-Host "2. waiting for '$ConfirmWindow'" -ForegroundColor Cyan
Invoke-Agent "wait-window $ConfirmWindow | $WaitSec" $clientWait | Out-Null

Write-Host "3. pressing '$ConfirmButton'" -ForegroundColor Cyan
Invoke-Agent "press-text $ConfirmWindow | $ConfirmButton" | Out-Null

if ($OkWindow) {
    Write-Host "4. waiting for '$OkWindow'" -ForegroundColor Cyan
    Invoke-Agent "wait-window $OkWindow | $WaitSec" $clientWait | Out-Null

    Write-Host "5. pressing '$OkButton'" -ForegroundColor Cyan
    Invoke-Agent "press-text $OkWindow | $OkButton" | Out-Null
}

Write-Host "done" -ForegroundColor Green
