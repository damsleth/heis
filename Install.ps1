<#
.SYNOPSIS
    Installer heisen - fetch Heis.ps1, put heis on the PATH, check that it works.

.DESCRIPTION
    One line, guided, no administrator rights:

        irm https://heis.d0.si/install.ps1 | iex

    Five steps, asking only what it has to:

      1. Checks the machine: Windows, Admin By Request, and whether PowerShell
         may run script files at all - offering to allow it for you alone
         (RemoteSigned, CurrentUser scope, no admin) when it may not.
      2. Fetches Heis.ps1 into %LOCALAPPDATA%\Programs\Heis - or to wherever
         heis already is, so running this again is also how you update.
      3. Puts heis on your PATH and, if you want it, adds a logon block to
         $PROFILE that reports status and takes the heis on SSH logon.
      4. Runs heis -Doctor, which checks every part and repairs what it can.
      5. Offers a real test - which elevates, unless ABR is already running.

    Everything it sets is a setting on Heis.ps1 itself, so you never re-run
    this to change your mind:

        heis -AddToProfile -AutoElevateOnLogin $false
        heis -Doctor
        heis -Uninstall

    Prompts are skipped when there is nobody to answer them - piped input, a
    scheduled task, CI - and the defaults are used instead. -Yes forces that;
    the other parameters pre-answer individual questions. `| iex` cannot pass
    parameters, so to use them build a script block:

        & ([scriptblock]::Create((irm https://heis.d0.si/install.ps1))) -Yes

.EXAMPLE
    irm https://heis.d0.si/install.ps1 | iex
.EXAMPLE
    .\Install.ps1 -Yes
.EXAMPLE
    .\Install.ps1 -Path C:\tools\heis -AddToProfile $false -Verify $false
.LINK
    https://heis.d0.si
#>
[CmdletBinding()]
param(
    # Folder for Heis.ps1. Default: wherever heis already is, otherwise
    # %LOCALAPPDATA%\Programs\Heis.
    [string] $Path,

    # Pre-answer the prompts. Left unset, they are asked for.
    [nullable[bool]] $AddToPath,
    [nullable[bool]] $AddToProfile,
    [nullable[bool]] $AutoElevateOnLogin,
    [nullable[bool]] $Verify,

    # Take every default without asking.
    [switch] $Yes,

    # Where to fetch Heis.ps1 from.
    [string] $SourceUrl = 'https://heis.d0.si/Heis.ps1',

    # Replace an existing Heis.ps1 without asking, and install even when
    # Admin By Request is not where it is usually found.
    [switch] $Force
)

# Everything runs in a child scope. Piped into iex, this file executes in the
# caller's own scope, so whatever it set at the top level - its functions, and
# $ErrorActionPreference above all - would stay behind in the user's shell
# after the install. Failure is a throw, caught at the bottom.
try {
$heisInstallReady = & {
    $ErrorActionPreference = 'Stop'

    # Norwegian output is composed from character codes so this file stays pure
    # ASCII - see the same note in Heis.ps1. A .ps1 with non-ASCII needs a BOM
    # to survive Windows PowerShell 5.1, and a BOM is exactly what stops
    # `irm | iex` parsing it. {a} {o} {ae} stand in for the missing letters.
    function T([string] $s) {
        $s.Replace('{a}', [string][char]0xE5).Replace('{o}', [string][char]0xF8).Replace('{ae}', [string][char]0xE6)
    }
    function Say([string] $Text, [string] $Color = 'Gray') {
        Write-Host ('  ' + (T $Text)) -ForegroundColor $Color
    }
    function Step([int] $N, [string] $Text) {
        Write-Host ''
        Write-Host (T "[$N/5] $Text") -ForegroundColor Cyan
    }

    # Prompting something that cannot answer hangs it forever, and this is run
    # piped into iex as often as not.
    $canAsk = -not $Yes -and -not [Console]::IsInputRedirected -and [Environment]::UserInteractive

    function Read-YesNo([string] $Question, [bool] $Default = $true) {
        if (-not $canAsk) { return $Default }
        $hint = if ($Default) { '[J/n]' } else { '[j/N]' }
        while ($true) {
            $answer = ([string](Read-Host (T "  $Question $hint"))).Trim()
            if (-not $answer)                     { return $Default }
            if ($answer -match '^(j|ja|y|yes)$')  { return $true }
            if ($answer -match '^(n|nei|no)$')    { return $false }
        }
    }

    function Read-Text([string] $Question, [string] $Default) {
        if (-not $canAsk) { return $Default }
        $answer = ([string](Read-Host (T "  $Question [$Default]"))).Trim().Trim('"')
        if ($answer) { return $answer } else { return $Default }
    }

    Write-Host @'

  _   _ _____ ___ ____
 | | | | ____|_ _/ ___|
 | |_| |  _|  | |\___ \
 |  _  | |___ | | ___) |
 |_| |_|_____|___|____/

'@ -ForegroundColor Cyan
    Write-Host '          elevation, express service' -ForegroundColor DarkCyan
    Write-Host ''
    Say 'Heis tar heisen for deg: Admin By Request, uten {a} klikke.'
    Say 'Ingenting her krever administrator. Enter godtar forslaget i [klammer].' DarkGray

    # --- 1. machine ------------------------------------------------------------
    Step 1 'Sjekker maskinen'

    # What to tell the user to type at the end. heis.cmd when PowerShell will
    # not run Heis.ps1, since there `heis` resolves to the .ps1 first.
    $heisCmd = 'heis'

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        throw 'heis runs on Windows - on the machine that has Admin By Request installed.'
    }
    $edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'Windows PowerShell' }
    Say "$edition $($PSVersionTable.PSVersion)" Green

    # Windows PowerShell 5.1 on an older .NET still offers TLS 1.0 first, which
    # the host refuses. Adding 1.2 is harmless where it is already on.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    # A quick look, not Heis.ps1's full search: enough to stop someone without
    # ABR before they answer questions about a tool that cannot work for them.
    $abr = $null
    $running = Get-Process -Name 'AdminByRequest' -ErrorAction SilentlyContinue | Select-Object -First 1
    try { if ($running -and $running.Path) { $abr = $running.Path } } catch { }   # denied on a more privileged process
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($abr -or -not $root) { continue }
        $candidate = Join-Path $root 'FastTrack Software\Admin By Request\AdminByRequest.exe'
        if (Test-Path -LiteralPath $candidate) { $abr = $candidate }
    }
    if ($abr) {
        Say "Admin By Request: $abr" Green
    } elseif ($running) {
        Say 'Admin By Request kj{o}rer' Green
    } else {
        Say 'Fant ikke Admin By Request p{a} vanlig sted.' Yellow
        Say 'heis klikker i ABR sine dialoger, s{a} uten ABR er det ingen heis {a} ta.' DarkGray
        if (-not ($Force -or (Read-YesNo 'Installere likevel? (heis -Doctor leter grundigere etterp{a})' $false))) {
            throw 'Admin By Request is not installed. Install the ABR client, then run this again.'
        }
    }

    # Windows PowerShell on a client defaults to Restricted: no .ps1 file runs
    # at all, Heis.ps1 and $PROFILE included. RemoteSigned for the current user
    # is the usual answer and needs no admin. A policy set by Group Policy
    # cannot be overridden from here, and should not be.
    #
    # Judged WITHOUT the Process scope. Started as `powershell -ExecutionPolicy
    # Bypass -Command "irm ... | iex"`, this process says Bypass while every
    # shell the user opens afterwards would still refuse to run heis. The list
    # comes most specific first, so the first defined entry is the one in force.
    $policy = $null
    $locked = $false
    foreach ($entry in @(Get-ExecutionPolicy -List)) {
        $p = [string]$entry.ExecutionPolicy
        if ($policy -or [string]$entry.Scope -eq 'Process' -or $p -eq 'Undefined') { continue }
        $policy = $p
        $locked = ([string]$entry.Scope -like '*Policy')
    }
    if (-not $policy) { $policy = if ($PSVersionTable.PSEdition -eq 'Core') { 'RemoteSigned' } else { 'Restricted' } }

    if ($policy -notin 'Restricted', 'AllSigned') {
        Say "ExecutionPolicy: $policy" Green
    } elseif ($locked) {
        throw ("PowerShell is locked to $policy by group policy, so no script file can run here - " +
               "and heis is one. Ask whoever manages this machine.")
    } else {
        Say "PowerShell kj{o}rer ikke skriptfiler her (ExecutionPolicy $policy)." Yellow
        Say 'heis er et skript. RemoteSigned for din bruker er vanlig, og krever ikke admin.' DarkGray
        # AllSigned is somebody's deliberate choice, so it is not loosened by default.
        $allowed = $false
        if (Read-YesNo 'Tillate skript for din bruker (RemoteSigned)?' ($policy -eq 'Restricted')) {
            # The cmdlet throws "overridden by a more specific scope" when the
            # Process scope is set, after the change has already been made. So
            # the error is ignored and the stored setting is what counts.
            try { Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force } catch { }
            $allowed = ([string](Get-ExecutionPolicy -Scope CurrentUser) -eq 'RemoteSigned')
        }
        if ($allowed) {
            Say 'ExecutionPolicy: RemoteSigned for din bruker' Green
        } else {
            # Enough to finish the install. heis.cmd brings its own Bypass, so
            # heis still works from the PATH - but PowerShell resolves `heis` to
            # Heis.ps1 first, so there it has to be typed as heis.cmd.
            if ([string](Get-ExecutionPolicy) -in 'Restricted', 'AllSigned') {
                Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
            }
            Say 'Uendret. I PowerShell m{a} du skrive heis.cmd i stedet for heis.' Yellow
            $heisCmd = 'heis.cmd'
        }
    }

    # --- 2. fetch --------------------------------------------------------------
    Step 2 'Henter Heis.ps1'

    # Re-running is the update path, so default to wherever heis already is.
    $defaultDir = Join-Path $env:LOCALAPPDATA 'Programs\Heis'
    $existing   = Get-Command 'heis.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) { $defaultDir = Split-Path -Parent $existing.Source }

    $destination = if ($Path) { $Path } else { Read-Text 'Hvor skal Heis.ps1 ligge?' $defaultDir }
    # Resolved against the PowerShell location, not the process directory,
    # which is what [IO.Path]::GetFullPath would use - they differ after a cd.
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        [Environment]::ExpandEnvironmentVariables($destination))
    $target = Join-Path $destination 'Heis.ps1'

    # Must match $script:Marker in Heis.ps1 exactly - see the note there on why
    # it still says "standalone".
    $marker = '### heis-standalone ###'

    # Prefer a copy beside this script - a clone, or a download of both - and
    # fall back to the network. Either way it has to carry the marker, so a
    # captive portal login page is caught here rather than written out and run.
    $beside = $null
    if ($PSScriptRoot) { $beside = Join-Path $PSScriptRoot 'Heis.ps1' }
    if ($beside -and (Test-Path -LiteralPath $beside) -and
        ([IO.Path]::GetFullPath($beside) -ne [IO.Path]::GetFullPath($target))) {
        $source = [IO.File]::ReadAllText($beside)
        $from   = $beside
    } else {
        Say "Henter $SourceUrl" DarkGray
        $source = Invoke-RestMethod -Uri $SourceUrl -UseBasicParsing
        $from   = $SourceUrl
    }
    if (-not ($source -is [string]) -or -not $source.Contains($marker)) {
        throw ("what came from $from is not Heis.ps1 - a proxy or a login page, perhaps. " +
               "Try again, or fetch it by hand:  irm $SourceUrl -OutFile Heis.ps1")
    }

    $write = $true
    if (Test-Path -LiteralPath $target) {
        if ([IO.File]::ReadAllText($target) -ceq $source) {
            $write = $false
            Say "Heis.ps1 er allerede nyeste versjon: $target" Green
        } elseif (-not ($Force -or (Read-YesNo "Det ligger en annen Heis.ps1 i $destination. Oppdatere den?" $true))) {
            $write = $false
            Say 'Beholder den som ligger der' Yellow
        }
    }
    if ($write) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        # No BOM: Heis.ps1 is pure ASCII and does not need one, and a BOM would
        # break anyone who later serves this copy over HTTP and pipes it to iex.
        [IO.File]::WriteAllText($target, $source, [Text.UTF8Encoding]::new($false))
        Say "Heis.ps1 -> $target" Green
    }

    # --- 3. wire up ------------------------------------------------------------
    Step 3 'Kobler opp'

    $wantPath = if ($null -ne $AddToPath) { [bool]$AddToPath }
                else { Read-YesNo 'Legge heis i PATH, s{a} du kan skrive heis i alle terminaler?' $true }

    # On an upgrade, the current setup is the default, so Enter (or -Yes) keeps
    # it - rather than quietly switching auto-elevation back on for someone
    # who chose status only, or adding a block for someone who said no.
    #
    # Read from THIS shell's profile only, since that is the one -AddToProfile
    # writes. The other edition's block keeps its own settings; Heis.ps1 -Doctor
    # repoints it at the new copy without touching them. A block only over
    # there means this shell was left out on purpose, so the default is no.
    $profileDefault = $true
    $autoDefault    = $true
    $docs  = [Environment]::GetFolderPath('MyDocuments')
    $texts = @(@([string]$PROFILE,
                 (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
                 (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { [IO.File]::ReadAllText($_) })
    $here = ''
    if ($PROFILE -and (Test-Path -LiteralPath $PROFILE)) { $here = [IO.File]::ReadAllText($PROFILE) }
    $m = [regex]::Match($here, '(?s)# >>> heis >>>.*?# <<< heis <<<')
    if ($m.Success) {
        $autoDefault = -not ($m.Value -match '(?m)^\$HEIS_AUTO_ELEVATE\s*=\s*\$false')
    } elseif ($existing -or @($texts | Where-Object { $_.Contains('# >>> heis >>>') }).Count) {
        $profileDefault = $false
    }

    $wantProfile = if ($null -ne $AddToProfile) { [bool]$AddToProfile }
                   else { Read-YesNo 'Vise heis-status n{a}r PowerShell starter (legg til i $PROFILE)?' $profileDefault }

    $wantAuto = $false
    if ($wantProfile) {
        $wantAuto = if ($null -ne $AutoElevateOnLogin) { [bool]$AutoElevateOnLogin }
                    else { Read-YesNo 'Ta heisen automatisk ved SSH-innlogging?' $autoDefault }
    }

    # Heis.ps1 owns these settings, so this just passes the answers through.
    # A hashtable splat, not an array. Array splatting passes POSITIONALLY, so
    # @('-Verify') once bound the string "-Verify" to -Exe and ran the default
    # action - elevate - against a nonsense path. And never call it with an
    # empty splat: no switches at all IS the elevate action.
    $splat = @{}
    if ($wantPath)    { $splat.AddToPath = $true }
    if ($wantProfile) { $splat.AddToProfile = $true; $splat.AutoElevateOnLogin = $wantAuto }
    if ($splat.Count) {
        & $target @splat
    } else {
        Say 'Ingenting {a} koble opp. Kj{o}r Heis.ps1 med full sti.' DarkGray
    }

    # --- 4. doctor -------------------------------------------------------------
    Step 4 'Sjekker oppsettet'

    $null = & $target -Doctor -PassThru
    $healthy = ($LASTEXITCODE -eq 0)

    # --- 5. test ---------------------------------------------------------------
    Step 5 'Tester'

    if (-not $healthy) {
        Say 'Hopper over testen. Fiks det som er merket fail over, og kj{o}r heis -Verify.' Yellow
    } else {
        $test = if ($null -ne $Verify) { [bool]$Verify }
                else { Read-YesNo 'Teste hele veien n{a}? Det tar heisen, hvis den ikke g{a}r allerede' $true }
        if ($test) {
            # Captured rather than left to fall through. Heis.ps1 writes its
            # result to the pipeline while this script reports with Write-Host,
            # and those two do not interleave predictably - the completion line
            # printed before the verification it was reporting on.
            $result = & $target -Verify
            if ($LASTEXITCODE -ne 0) { throw 'the test failed - see the message above. heis -Doctor checks every part.' }
            Say "$result" Green
        } else {
            Say 'Hoppet over. heis -Verify tester n{a}r du vil.' DarkGray
        }
    }

    # --- done ------------------------------------------------------------------
    $run = if ($wantPath) { $heisCmd } else { "& '$target'" }
    Write-Host ''
    if ($healthy) {
        Write-Host (T 'Ferdig - ha det g{o}y med {a} kj{o}re heis!') -ForegroundColor Green
    } else {
        Write-Host (T 'Installert, men ikke klar enn{a} - se fail-linjene i steg 4.') -ForegroundColor Yellow
    }
    Say "$run              ta heisen" DarkGray
    Say "$run -Status      hvor er heisen" DarkGray
    Say "$run -Help        alle knappene" DarkGray
    Say "$run -Doctor      hvis noe er galt" DarkGray
    Say "$run -Uninstall   fjern alt igjen" DarkGray
    if ($wantPath -and (Get-Process -Id $PID).SessionId -eq 0) {
        # The PATH broadcast cannot cross from session 0 to the desktop.
        Say 'heis virker i nye SSH-{o}kter n{a}. P{a} skrivebordet: logg av og p{a} f{o}rst.' DarkGray
    }

    # The block's only pipeline output: whether the setup is ready.
    $healthy
}
if (-not (@($heisInstallReady)[-1])) {
    # Installed, but -Doctor found something it could not fix. Not an error
    # worth a red line - the report is already on screen - but automation
    # should not read it as success.
    $global:LASTEXITCODE = 1
    if ($PSCommandPath) { exit 1 }
}
} catch {
    $Host.UI.WriteErrorLine('')
    $Host.UI.WriteErrorLine("Installasjonen stoppet: $($_.Exception.Message)")
    Write-Host 'Hjelp: https://github.com/damsleth/heis#troubleshooting' -ForegroundColor DarkGray
    $global:LASTEXITCODE = 1
    # Only from a file. Under `irm | iex` there is none, and exit would close the
    # user's whole shell - an SSH session included - on top of the failure.
    if ($PSCommandPath) { exit 1 }
}
