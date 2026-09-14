<#
.SYNOPSIS
    Register a logon task that keeps taskbar-click.ahk running in the
    interactive (console/RDP) session.

.DESCRIPTION
    The trigger is the INTERACTIVE logon, not an SSH logon: an SSH session has
    no input desktop, so there would be nothing for the agent to drive. (The
    agent enforces this itself too - it refuses to start in session 0.)

    One registration covers every interactive session this user logs into, so a
    machine that allows several at once gets one agent per session and
    Send-AhkCommand.ps1 picks between them. A Windows client SKU - a Windows 365
    Cloud PC included - allows only one, so there it simply means the agent
    starts in whichever session you get. See HEADLESS-SETUP.md for keeping that
    session usable after RDP disconnects.

    Because the task is registered with LogonType Interactive, the Task
    Scheduler service launches it into the logged-on user's session. That makes

        schtasks /run /tn "AHK Taskbar Agent"

    a way to (re)start the agent on the interactive desktop from an SSH shell,
    which SSH cannot do directly.

.EXAMPLE
    .\Install-AhkAgentTask.ps1
    .\Install-AhkAgentTask.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'AHK Taskbar Agent',
    [string] $AhkExe   = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
    [int]    $DelaySec = 15,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$scriptPath = Join-Path $root 'taskbar-click.ahk'
$userId     = "$env:USERDOMAIN\$env:USERNAME"

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Removed task '$TaskName'."
    exit 0
}

foreach ($p in @($AhkExe, $scriptPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
}

$action = New-ScheduledTaskAction -Execute $AhkExe -Argument "`"$scriptPath`"" -WorkingDirectory $root

# Delay the start so Explorer and the taskbar are up before the agent logs its
# first geometry probe.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$trigger.Delay = "PT${DelaySec}S"

# RunLevel Limited (not Highest): a non-elevated agent cannot send input to
# elevated windows, but it also avoids a permanently elevated process that
# anything on the desktop could drive. Re-register with -RunLevel Highest only
# if you actually need to automate elevated apps.
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

# Parallel, not IgnoreNew: the AtLogOn trigger fires for EVERY interactive logon
# of this user, so one task covers both the console session and any remote one,
# and the agents keep each other out of the way through their per-session queues.
# Under IgnoreNew a console logon would be skipped whenever an RDP agent already
# happened to be running - the unattended target would exist only sometimes,
# which is the least debuggable failure available.
#
# Two instances in two sessions do not fight over #SingleInstance either: AHK
# matches on a hidden window, and window lookup does not cross a session
# boundary. Two agents in the SAME session still collapse to one, as intended.
$settings = New-ScheduledTaskSettingsSet -MultipleInstances Parallel -StartWhenAvailable
$settings.DisallowStartIfOnBatteries = $false   # a laptop on battery still has a desktop
$settings.StopIfGoingOnBatteries     = $false
$settings.ExecutionTimeLimit         = 'PT0S'   # resident agent: never time it out
$settings.IdleSettings.StopOnIdleEnd = $false

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Keeps the AHK taskbar automation agent running in the interactive session so SSH can drive it.' `
    -Force | Out-Null

Write-Output "Registered '$TaskName' for $userId (interactive logon + ${DelaySec}s delay)."
Write-Output "Start it now from anywhere, including SSH:  schtasks /run /tn `"$TaskName`""
