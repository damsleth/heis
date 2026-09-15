<#
.SYNOPSIS
    Installer heisen - put Heis.ps1 next to your PowerShell profile.

.DESCRIPTION
    Copies Heis.ps1 into the current directory, where it is easy to find, move
    or copy somewhere permanent. Use -Destination to put it elsewhere.

    Run it from a clone, or straight off the web - if there is no Heis.ps1
    beside this script it is fetched from SourceUrl:

        irm https://raw.githubusercontent.com/damsleth/heis/main/Install.ps1 | iex

    Existing installs are left alone. Pass -Force to overwrite one.

.EXAMPLE
    .\Install.ps1
    .\Install.ps1 -Force
#>
[CmdletBinding()]
param(
    # Overwrite an existing copy instead of leaving it alone.
    [switch] $Force,

    # Where to fetch Heis.ps1 when there is no copy beside this script.
    [string] $SourceUrl = 'https://raw.githubusercontent.com/damsleth/heis/main/Heis.ps1',

    # Install somewhere other than the current directory.
    [string] $Destination
)

$ErrorActionPreference = 'Stop'

# Norwegian output is composed from character codes so this file stays pure
# ASCII - see the same note in Heis.ps1. A .ps1 with non-ASCII needs a BOM to
# survive Windows PowerShell 5.1, and a BOM is exactly what stops `irm | iex`
# parsing it. This script is meant to be run both ways.
$AA = [char]0xE5   # a-ring
$OE = [char]0xF8   # o-slash

# The current directory, so the file lands where you are and can be moved
# wherever you want it.
#
# Taken from the provider path rather than $PWD directly: a PowerShell location
# can sit on a drive that is not a filesystem at all - a registry or
# certificate drive - and there is nowhere to write a file there. Falling back
# to the home directory beats failing on something nobody was thinking about.
if (-not $Destination) {
    if ($PWD.Provider.Name -eq 'FileSystem') { $Destination = $PWD.ProviderPath }
    else                                     { $Destination = $HOME }
}
if (-not $Destination) { throw 'cannot work out where to install' }

$target = Join-Path $Destination 'Heis.ps1'

if ((Test-Path -LiteralPath $target) -and -not $Force) {
    Write-Host "Heisen er allerede installert" -ForegroundColor DarkGray
} else {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    # Prefer a copy sitting beside this script; fall back to the network. Both
    # are validated against the same marker Heis.ps1 uses to recognise itself,
    # so a redirect to a login page or an error blob is caught here rather than
    # being written out and run later.
    $marker = '### heis-standalone ###'
    $here   = $PSScriptRoot
    if (-not $here -and $PSCommandPath) { $here = Split-Path -Parent $PSCommandPath }
    $local  = if ($here) { Join-Path $here 'Heis.ps1' } else { $null }

    if ($local -and (Test-Path -LiteralPath $local)) {
        $source = [IO.File]::ReadAllText($local)
        $from   = $local
    } else {
        $source = Invoke-RestMethod -Uri $SourceUrl
        $from   = $SourceUrl
    }

    if (-not ($source -is [string]) -or -not $source.Contains($marker)) {
        throw "what came from $from is not Heis.ps1"
    }

    # Written without a BOM, deliberately. Heis.ps1 is pure ASCII, so it does
    # not need one, and adding one would break anyone who later serves this
    # copy over HTTP and pipes it into iex.
    [IO.File]::WriteAllText($target, $source, [Text.UTF8Encoding]::new($false))
}

Write-Host ("Heisen er installert - kj{0}r `"{1}`" for {2} ta heisen, eller `"{1}`" -? for hjelp" -f $OE, $target, $AA) -ForegroundColor Green
