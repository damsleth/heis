<#
.SYNOPSIS
    Register a SYSTEM task that reattaches the session to the console whenever
    RDP disconnects, keeping macros runnable while nobody is connected.

.DESCRIPTION
    Triggers on event 24 (session disconnected) in
    Microsoft-Windows-TerminalServices-LocalSessionManager/Operational and runs
    Reattach-ConsoleSession.ps1 as SYSTEM.

    Registered through schtasks /create /xml rather than the ScheduledTasks
    cmdlets on purpose: those go through CIM, which is refused from an SSH
    session, so the cmdlet route can only be run from the desktop. This route
    works from either.

    Run elevated.

.EXAMPLE
    .\Install-ConsoleReattachTask.ps1
    .\Install-ConsoleReattachTask.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'AHK Console Reattach',
    # Let the disconnect settle, and let the agent publish one more heartbeat,
    # before deciding which session to move.
    [int]    $DelaySec = 5,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

if ($Uninstall) {
    schtasks /delete /tn $TaskName /f
    exit $LASTEXITCODE
}

$action = Join-Path $root 'Reattach-ConsoleSession.ps1'
if (-not (Test-Path -LiteralPath $action)) { throw "Not found: $action" }

$subscription = @"
<QueryList><Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"><Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">*[System[Provider[@Name='Microsoft-Windows-TerminalServices-LocalSessionManager'] and (EventID=24)]]</Select></Query></QueryList>
"@

# The subscription is XML nested inside XML, so it has to arrive escaped.
$escaped = [System.Security.SecurityElement]::Escape($subscription.Trim())

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Reattaches a disconnected AHK agent session to the console so macros keep running unattended.</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$escaped</Subscription>
      <Delay>PT${DelaySec}S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$action"</Arguments>
      <WorkingDirectory>$root</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

# schtasks reads the file, and the declared encoding above must match the bytes.
$xmlPath = Join-Path $env:TEMP 'ahk-console-reattach.xml'
[IO.File]::WriteAllText($xmlPath, $xml, [Text.Encoding]::Unicode)

try {
    schtasks /create /tn $TaskName /xml $xmlPath /f
    if ($LASTEXITCODE -ne 0) { throw "schtasks failed with exit code $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output "Registered '$TaskName' (SYSTEM, on RDP disconnect, ${DelaySec}s delay)."
Write-Output "Test it without waiting for a disconnect:"
Write-Output "    .\Reattach-ConsoleSession.ps1 -WhatIf -Verbose"
Write-Output "    schtasks /run /tn `"$TaskName`""
