<#
.SYNOPSIS
    Send a command to a resident taskbar-click.ahk agent and print its reply.

.DESCRIPTION
    Agents advertise themselves in .\agents\<session>.json. This script finds
    the live ones, picks the agent to talk to, drops a command into that
    agent's private queue and waits for the matching reply.

    Safe to call from an SSH session: the SSH process has no input desktop, but
    the agent already runs on an interactive one.

    If more than one agent is live (fast user switching, or one user on the
    console and another over RDP) the target is ambiguous and you must say
    which with -Session or -User. Guessing would fire input at the wrong
    desktop, so this refuses instead.

    With agents in both the console session and a remote one, an unqualified
    call prefers the remote desktop - the one you can watch a macro run on.
    Disconnect, and the same call falls through to the console agent, which is
    what makes a macro debuggable over RDP and runnable unattended without
    changing the command. Say -Rdp or -Console to pin the choice.

.EXAMPLE
    .\Send-AhkCommand.ps1 -List
    .\Send-AhkCommand.ps1 ping
    .\Send-AhkCommand.ps1 status
    .\Send-AhkCommand.ps1 -Rdp click-icon 1
    .\Send-AhkCommand.ps1 -Console click-icon 1
    .\Send-AhkCommand.ps1 -Session 2 click-icon 1
    .\Send-AhkCommand.ps1 -User cj preview-icon 3
#>
[CmdletBinding(DefaultParameterSetName = 'Send')]
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments, ParameterSetName = 'Send')]
    [string[]] $Command,

    # List live agents and exit.
    [Parameter(Mandatory, ParameterSetName = 'List')]
    [switch] $List,

    # Disambiguate when several agents are live.
    [int]    $Session = 0,
    [string] $User,

    # Target by role instead of by number. -Rdp is the desktop you can actually
    # watch, for debugging a macro; -Console is the always-present unattended
    # one. Mutually exclusive, and both beat the automatic preference below.
    [switch] $Rdp,
    [switch] $Console,

    [int]    $TimeoutSec = 10,

    # Treat an agent as dead if its heartbeat is older than this.
    [int]    $StaleSec = 30,

    [string] $Root
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated inside a param-block default under Windows
# PowerShell 5.1, so resolve the script's own directory here instead.
if (-not $Root) {
    $Root = $PSScriptRoot
    if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
}
$agentDir = Join-Path $Root 'agents'

function Get-EpochNow {
    [int][math]::Floor(((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)
}

function Get-LiveAgents {
    param([string] $Dir, [int] $StaleSec)

    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $now = Get-EpochNow
    $out = @()

    foreach ($f in Get-ChildItem -LiteralPath $Dir -Filter '*.json' -ErrorAction SilentlyContinue) {
        try { $a = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json }
        catch { continue }          # half-written or corrupt: ignore, not fatal

        $age = $now - [int] $a.unix
        # Two independent liveness checks: a fresh heartbeat AND a process that
        # still exists. A killed agent leaves its file behind if it died hard.
        $alive = (Get-Process -Id $a.pid -ErrorAction SilentlyContinue) -ne $null
        # Agents predating the 'ready' field are judged on the desktop name,
        # which is what that field was distilled from. Computed here rather than
        # inline below: an if-expression in a hashtable value is not something
        # Windows PowerShell 5.1 can be trusted to parse.
        if ($null -ne $a.ready) { $ready = [bool] $a.ready }
        else                    { $ready = ($a.desktop -eq 'Default') }

        # Agents predating the 'console' field cannot be placed. Calling them
        # remote is the safe guess: it only ever costs an ambiguity error, where
        # guessing 'console' could silently divert input to the wrong desktop.
        if ($null -ne $a.console) { $isConsole = [bool] $a.console } else { $isConsole = $false }

        if ($age -le $StaleSec -and $alive) {
            $out += [pscustomobject] @{
                Session = [int] $a.session
                User    = [string] $a.user
                Pid     = [int] $a.pid
                Desktop = [string] $a.desktop
                Ready   = $ready
                Console = $isConsole
                Screen  = [string] $a.screen
                Dpi     = [int] $a.dpi
                Queue   = [string] $a.queue
                AgeSec  = $age
            }
        }
    }
    return @($out | Sort-Object Session)
}

$agents = Get-LiveAgents -Dir $agentDir -StaleSec $StaleSec

if ($List) {
    if (-not $agents) { Write-Output 'No live agents.'; exit 3 }
    $agents | Format-Table Session, User, Pid, Ready, Console, Desktop, Screen, Dpi, AgeSec -AutoSize
    exit 0
}

# Narrow to the requested target. -User matches on the account name, so either
# "cj" or "DOMAIN\cj" works.
$candidates = $agents
if ($Session) { $candidates = @($candidates | Where-Object { $_.Session -eq $Session }) }
if ($User) {
    $candidates = @($candidates | Where-Object {
        # Split on [char]92 rather than a regex: a literal backslash in a
        # -split pattern is too easy to lose a level of escaping on.
        $_.User -eq $User -or ($_.User.Split([char]92))[-1] -eq $User
    })
}
if ($Rdp -and $Console) { throw '-Rdp and -Console are mutually exclusive.' }
if ($Rdp)     { $candidates = @($candidates | Where-Object { -not $_.Console }) }
if ($Console) { $candidates = @($candidates | Where-Object {      $_.Console }) }

# Nothing was named explicitly, so choose - but only between agents that differ
# in ROLE. Two people's remote desktops are still an ambiguity worth refusing;
# the rule below can never pick between them.
#
#   1. a usable desktop beats a locked one - a locked agent would only refuse
#   2. the visible remote desktop beats the console one
#
# Order (2) that way round because the remote session is the one you can watch:
# when you are connected you are almost certainly debugging a macro and want to
# see it run. Unattended, there is no remote session and this falls through to
# the console agent on its own, which is the whole point of running both.
if (-not ($Session -or $User -or $Rdp -or $Console) -and $candidates.Count -gt 1) {
    $usable = @($candidates | Where-Object { $_.Ready })
    if ($usable) { $candidates = $usable }

    $visible = @($candidates | Where-Object { -not $_.Console })
    if ($visible) { $candidates = $visible }
}

if (-not $candidates) {
    $hint = if ($agents) {
        "Live agents: " + (($agents | ForEach-Object { "session $($_.Session) ($($_.User))" }) -join ', ')
    } else {
        'No live agents. Start one:  Start-ScheduledTask -TaskName "AHK Taskbar Agent"'
    }
    $Host.UI.WriteErrorLine("No agent matches the requested target. $hint")
    exit 3
}

if ($candidates.Count -gt 1) {
    Write-Output 'Several agents are live - narrow the target with -Session, -User, -Rdp or -Console:'
    $candidates | Format-Table Session, User, Pid, Ready, Console, Desktop -AutoSize | Out-String | Write-Output
    $Host.UI.WriteErrorLine('Ambiguous target; refusing to guess which desktop to drive.')
    exit 4
}

$agent = $candidates[0]

# Ready is the agent's probe result, not a guess from the desktop name: it has
# actually tried to move the cursor and watched whether it went anywhere. Warn
# rather than refuse - read-only commands (status, probe-input) and
# window-message ones (activate) still work, and the agent rejects the rest with
# a precise error, so there is nothing to gain by second-guessing it here.
if (-not $agent.Ready) {
    # Deliberately does not guess the cause. The common one is not the obvious
    # one: an elevated foreground window blocks injection via UIPI while the
    # session is connected, unlocked and in every visible respect fine. Saying
    # "locked or disconnected" there sends people off debugging the session.
    Write-Warning ("Session $($agent.Session) cannot receive synthetic input; click/send will be refused. " +
                   "Ask why:  .\Send-AhkCommand.ps1 active-window  - an elevated window in front blocks " +
                   "injection even on a perfectly healthy session.")
}

$text = ($Command -join ' ').Trim()
if (-not $text) { throw 'No command given.' }

$queue = $agent.Queue
if (-not (Test-Path -LiteralPath $queue)) {
    New-Item -ItemType Directory -Path $queue -Force | Out-Null
}

$id   = '{0:yyyyMMdd-HHmmss-fff}-{1}' -f (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 6)
$tmp  = Join-Path $queue "$id.tmp"
$cmdF = Join-Path $queue "$id.cmd"
$done = Join-Path $queue "$id.done"

# Write then rename, so the agent's poll can never read a half-written command.
[IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
Move-Item -LiteralPath $tmp -Destination $cmdF

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $done) {
        $reply = (Get-Content -LiteralPath $done -Raw).TrimEnd()
        Remove-Item -LiteralPath $done -Force
        Write-Output $reply
        # No ternary here: this must also parse under Windows PowerShell 5.1.
        if ($reply -match '(?m)^ok:\s*1') { exit 0 } else { exit 2 }
    }
    Start-Sleep -Milliseconds 100
}

Remove-Item -LiteralPath $cmdF -Force -ErrorAction SilentlyContinue
$Host.UI.WriteErrorLine("No reply from session $($agent.Session) in ${TimeoutSec}s. Check $Root\logs\agent-s$($agent.Session).log")
exit 1
