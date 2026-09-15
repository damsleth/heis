<#
.SYNOPSIS
    Installer heisen - fetch Heis.ps1, wire it up, and check that it works.

.DESCRIPTION
    A first-run script. It asks where to put Heis.ps1, whether to report status
    on logon, and whether to take the heis automatically when logging in over
    SSH - then downloads the script, applies those answers and verifies the
    whole path end to end.

        irm https://heis.d0.si/install.ps1 | iex

    Everything it sets is a setting on Heis.ps1 itself, so nothing here has to
    be re-run to change your mind later:

        .\Heis.ps1 -AddToProfile -AutoElevateOnLogin $false
        .\Heis.ps1 -Verify

    No administrator rights are needed, for this or for anything Heis.ps1 does.

    Prompts are skipped when there is nobody to answer them - piped input, a
    scheduled task, CI - and the defaults are used instead. -Yes forces that
    explicitly; -Path, -AddToProfile and -AutoElevateOnLogin pre-answer
    individual questions.

.EXAMPLE
    irm https://heis.d0.si/install.ps1 | iex
    .\Install.ps1
    .\Install.ps1 -Yes
    .\Install.ps1 -Path C:\tools -AddToProfile $true -AutoElevateOnLogin $false
#>
[CmdletBinding()]
param(
    # Where to put Heis.ps1. Prompted for when not given; defaults to here.
    [string] $Path,

    # Pre-answer the prompts. Left unset, they are asked for.
    [nullable[bool]] $AddToProfile,
    [nullable[bool]] $AutoElevateOnLogin,

    # Take every default without asking.
    [switch] $Yes,

    # Where to fetch Heis.ps1 from.
    [string] $SourceUrl = 'https://heis.d0.si/Heis.ps1',

    # Overwrite an existing Heis.ps1 at the destination.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Norwegian output is composed from character codes so this file stays pure
# ASCII - see the same note in Heis.ps1. A .ps1 with non-ASCII needs a BOM to
# survive Windows PowerShell 5.1, and a BOM is exactly what stops `irm | iex`
# parsing it. This script is meant to be run both ways.
$AA = [char]0xE5   # a-ring
$OE = [char]0xF8   # o-slash

# Prompting something that cannot answer hangs it forever, and this is run
# piped into iex as often as not.
$script:CanAsk = -not $Yes -and -not [Console]::IsInputRedirected -and [Environment]::UserInteractive

function Read-YesNo {
    param([Parameter(Mandatory)][string] $Question, [bool] $Default = $true)

    if (-not $script:CanAsk) { return $Default }
    $hint = if ($Default) { '[J/n]' } else { '[j/N]' }

    while ($true) {
        $answer = (Read-Host "$Question $hint").Trim()
        if (-not $answer)                     { return $Default }
        if ($answer -match '^(j|ja|y|yes)$')  { return $true }
        if ($answer -match '^(n|nei|no)$')    { return $false }
    }
}

function Read-Text {
    param([Parameter(Mandatory)][string] $Question, [Parameter(Mandatory)][string] $Default)

    if (-not $script:CanAsk) { return $Default }
    $answer = (Read-Host "$Question [$Default]").Trim().Trim('"')
    if ($answer) { return $answer } else { return $Default }
}

Write-Host @'

  _   _ _____ ___ ____
 | | | | ____|_ _/ ___|
 | |_| |  _|  | |\___ \
 |  _  | |___ | | ___) |
 |_| |_|_____|___|____/

'@ -ForegroundColor Cyan
Write-Host '          the ABR elevator' -ForegroundColor DarkCyan
Write-Host ''

Write-Host 'Heis tar heisen for deg - Admin By Request, uten a klikke.' -ForegroundColor Gray
Write-Host ''
Write-Host 'Dette installeres:' -ForegroundColor Gray
Write-Host '  - Heis.ps1, en enkelt fil uten avhengigheter' -ForegroundColor DarkGray
Write-Host '  - en planlagt oppgave som kjorer den i skrivebordsokten,' -ForegroundColor DarkGray
Write-Host '    slik at den ogsa virker over SSH. Krever ikke administrator.' -ForegroundColor DarkGray
Write-Host ''

# --- answers ---------------------------------------------------------------
$here = if ($PWD.Provider.Name -eq 'FileSystem') { $PWD.ProviderPath } else { $HOME }

$destination = if ($Path) { $Path } else { Read-Text 'Hvor skal Heis.ps1 ligge?' $here }

$wantProfile = if ($null -ne $AddToProfile) { [bool]$AddToProfile }
               else { Read-YesNo 'Vis status ved innlogging (legg til i $PROFILE)?' $true }

$wantAuto = $false
if ($wantProfile) {
    $wantAuto = if ($null -ne $AutoElevateOnLogin) { [bool]$AutoElevateOnLogin }
                else { Read-YesNo 'Ta heisen automatisk ved SSH-innlogging?' $true }
}

# --- fetch -----------------------------------------------------------------
# Must match $script:Marker in Heis.ps1 exactly - see the note there on why it
# still says "standalone".
$marker = '### heis-standalone ###'
$target = Join-Path $destination 'Heis.ps1'

Write-Host ''
if ((Test-Path -LiteralPath $target) -and -not $Force) {
    Write-Host "Heis.ps1 finnes allerede i $destination" -ForegroundColor DarkGray
} else {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    # Prefer a copy beside this script - a clone, or a download of both - and
    # fall back to the network. Either way it has to carry the marker, so a
    # captive portal login page is caught here rather than written out and run.
    $here_ps1 = $null
    if ($PSScriptRoot) { $here_ps1 = Join-Path $PSScriptRoot 'Heis.ps1' }

    if ($here_ps1 -and (Test-Path -LiteralPath $here_ps1) -and
        ([IO.Path]::GetFullPath($here_ps1) -ne [IO.Path]::GetFullPath($target))) {
        $source = [IO.File]::ReadAllText($here_ps1)
        $from   = $here_ps1
    } else {
        Write-Host "Henter Heis.ps1 fra $SourceUrl ..." -ForegroundColor DarkGray
        $source = Invoke-RestMethod -Uri $SourceUrl
        $from   = $SourceUrl
    }

    if (-not ($source -is [string]) -or -not $source.Contains($marker)) {
        throw "det som kom fra $from er ikke Heis.ps1"
    }

    # No BOM: Heis.ps1 is pure ASCII and does not need one, and a BOM would
    # break anyone who later serves this copy over HTTP and pipes it to iex.
    [IO.File]::WriteAllText($target, $source, [Text.UTF8Encoding]::new($false))
    Write-Host "Heis.ps1 -> $target" -ForegroundColor Green
}

# --- wire up and verify ----------------------------------------------------
# Heis.ps1 owns both settings, so this just passes the answers through. -Verify
# proves the relay works, and elevates only if nothing is running already.
# A hashtable splat, not an array. Array splatting passes POSITIONALLY, so
# @('-Verify') bound the string "-Verify" to the first positional parameter -
# which is -Exe - and ran the default action against a nonsense path. It even
# looked like it worked, because Resolve-AbrExe found the running image and
# healed straight past the bad value.
$splat = @{ Verify = $true }
if ($wantProfile) {
    $splat.AddToProfile       = $true
    $splat.AutoElevateOnLogin = $wantAuto
}

Write-Host ''

# Captured rather than left to fall through. Heis.ps1 writes its result to the
# pipeline while this script reports with Write-Host, and those two do not
# interleave predictably - the completion line printed before the verification
# it was reporting on.
$result = & $target @splat
if ($LASTEXITCODE -ne 0) {
    $Host.UI.WriteErrorLine('Installasjonen feilet - se meldingen over.')
    exit 1
}
if ($result) { Write-Host "  $result" -ForegroundColor Green }

Write-Host ''
Write-Host ("Installation complete - ha det g{0}y med {1} kj{0}re heis!" -f $OE, $AA) -ForegroundColor Green
Write-Host ("  {0}" -f $target) -ForegroundColor DarkGray
