<#
.SYNOPSIS
    Move a disconnected agent session back onto the console, so it keeps a
    usable input desktop and macros keep running.

.DESCRIPTION
    Disconnecting RDP locks the session: the input desktop becomes Winlogon and
    synthetic input is dropped. Reattaching the session to the console unlocks
    it again, and everything in it keeps running untouched.

    Meant to be fired by Install-ConsoleReattachTask.ps1 on the Terminal
    Services "session disconnected" event, but safe to run by hand.

    The session to move is taken from the agents' own heartbeats rather than by
    parsing `query user`: the heartbeat already states its session id and
    whether it is on the console, the column layout of `query user` shifts once
    a session goes disconnected, and a mis-parse here would tscon the wrong
    session.

    Must run as SYSTEM. Reattaching someone else's session is privileged, and a
    normal user - even an administrator - is refused.

.EXAMPLE
    .\Reattach-ConsoleSession.ps1
    .\Reattach-ConsoleSession.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Ignore heartbeats older than this; a dead agent's session is not ours to move.
    [int]    $StaleSec = 60,
    [string] $Root
)

$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $Root = $PSScriptRoot
    if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
}

$logDir = Join-Path $Root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir 'console-reattach.log'

function Write-Log {
    param([string] $Text)
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text
    Add-Content -LiteralPath $log -Value $line
    Write-Verbose $line
}

$now      = [int][math]::Floor(((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)
$agentDir = Join-Path $Root 'agents'
$targets  = @()

foreach ($f in Get-ChildItem -LiteralPath $agentDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $a = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }

    if (($now - [int] $a.unix) -gt $StaleSec) { continue }       # agent is gone
    if ([bool] $a.console)                    { continue }       # already on the console
    if (-not (Get-Process -Id $a.pid -ErrorAction SilentlyContinue)) { continue }

    $targets += [int] $a.session
}

if (-not $targets) {
    Write-Log 'nothing to do - no live agent in a non-console session'
    exit 0
}

$tscon = Join-Path $env:WINDIR 'System32\tscon.exe'

foreach ($id in $targets) {
    if (-not $PSCmdlet.ShouldProcess("session $id", 'tscon /dest:console')) { continue }

    # Reconnecting to the console is what unlocks the session. It also makes the
    # RDP client, if one is somehow still attached, drop - which is fine here:
    # this only runs once that client has already gone away.
    $out = & $tscon $id /dest:console 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "session $id reattached to console"
    } else {
        Write-Log "session $id FAILED (exit $LASTEXITCODE): $out"
    }
}
