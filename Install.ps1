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

    -AddToProfile also writes a block into $PROFILE so the heis is taken
    automatically when you log in - but only over SSH. Locally you are at the
    desktop and can take it by hand; there is no reason to fire an elevation
    request for every console opened on the machine itself.

    It edits the profile of the host it runs under: pwsh and Windows PowerShell
    have separate ones, so run it under the shell you actually log in with. The
    block is delimited by markers and re-running replaces it, so the path stays
    current and the profile does not collect copies. Delete the block to stop
    it.

    Each remote shell then costs about a second while it checks, and rather
    more the first time, when it actually elevates.

.EXAMPLE
    .\Install.ps1
    .\Install.ps1 -Force
    .\Install.ps1 -AddToProfile
    .\Install.ps1 -Destination C:\tools -AddToProfile
#>
[CmdletBinding()]
param(
    # Overwrite an existing copy instead of leaving it alone.
    [switch] $Force,

    # Where to fetch Heis.ps1 when there is no copy beside this script.
    [string] $SourceUrl = 'https://raw.githubusercontent.com/damsleth/heis/main/Heis.ps1',

    # Install somewhere other than the current directory.
    [string] $Destination,

    # Also add a block to $PROFILE that takes the heis automatically when you
    # log in over SSH. Re-running replaces the block rather than adding another.
    [switch] $AddToProfile,

    # The value written into the block's $HEIS_AUTO_ELEVATE flag. $false still
    # reports status on logon, it just does not elevate. Editing the flag in the
    # profile afterwards works too; this only picks the initial value.
    [bool] $AutoElevateOnLogin = $true
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

if ($AddToProfile) {
    $begin = '# >>> heis >>>'
    $end   = '# <<< heis <<<'

    # Single quotes in a Windows path are legal and would end the string early.
    $quoted = $target.Replace("'", "''")

    # A single-quoted here-string with placeholders, so none of the block's own
    # $variables are interpolated while it is being written out. Escaping a
    # dozen of them by hand is the kind of thing that works until one is missed.
    $template = @'
__BEGIN__
# Added by Install.ps1 -AddToProfile. Delete this block to stop it.

# Take the heis automatically on remote logon. $false reports status only.
$HEIS_AUTO_ELEVATE = __AUTO__
$HEIS_PATH         = '__PATH__'

# Live admin check, on purpose not [WindowsPrincipal]::IsInRole: a process
# token carries the group membership it was born with, so a shell started
# before elevation answers "not admin" for the rest of its life however
# elevated the account becomes. A function rather than a variable for the same
# reason - a variable set at logon is a snapshot that quietly goes stale.
function Test-IsAdmin {
    ((net localgroup Administrators 2>$null) -join "`n") -match [regex]::Escape($env:USERNAME)
}

# Status comes from Heis.ps1 itself, which reads the countdown window on the
# desktop rather than inferring anything from this process.
function Show-HeisStatus {
    if (-not (Test-Path -LiteralPath $HEIS_PATH)) { return $null }

    $h = & $HEIS_PATH -Status -PassThru
    if     ($h.Active)  { Write-Host "ABR aktiv - $($h.Remaining) igjen"  -ForegroundColor Green }
    elseif ($h.InGroup) { Write-Host 'admin, men ingen ABR-nedtelling'    -ForegroundColor DarkYellow }
    else                { Write-Host 'ikke elevert'                       -ForegroundColor Yellow }
    return $h
}

$heis = Show-HeisStatus

# SSH_CONNECTION is set by the SSH server for its own sessions and by nothing
# else - a better test than session id, which also catches services. At the
# desktop you can take the heis by hand.
if ($HEIS_AUTO_ELEVATE -and $env:SSH_CONNECTION -and $heis -and -not $heis.Active) {
    & $HEIS_PATH | Out-Null
    $heis = Show-HeisStatus      # report where that left things
}
__END__
'@

    $auto  = if ($AutoElevateOnLogin) { '$true' } else { '$false' }
    $block = $template.Replace('__BEGIN__', $begin).
                       Replace('__END__',   $end).
                       Replace('__AUTO__',  $auto).
                       Replace('__PATH__',  $quoted)

    $dir = Split-Path -Parent $PROFILE
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $existing = ''
    $hadBom   = $false
    if (Test-Path -LiteralPath $PROFILE) {
        $bytes    = [IO.File]::ReadAllBytes($PROFILE)
        $hadBom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $existing = [IO.File]::ReadAllText($PROFILE)
    }

    # Replace any previous block instead of appending a second one.
    $pattern = [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    $cleaned = ([regex]::Replace($existing, $pattern, '', 'Singleline')).TrimEnd()

    $updated = if ($cleaned) { "$cleaned`r`n`r`n$block`r`n" } else { "$block`r`n" }

    # Preserve whatever BOM the profile already had: removing one breaks a
    # Windows PowerShell profile containing non-ASCII, and adding one where
    # there was none is an unexplained diff in someone else's file.
    [IO.File]::WriteAllText($PROFILE, $updated, [Text.UTF8Encoding]::new($hadBom))

    if ($AutoElevateOnLogin) {
        Write-Host 'Lagt til i profilen - heisen tas automatisk ved SSH-innlogging' -ForegroundColor Green
    } else {
        Write-Host 'Lagt til i profilen - status vises ved innlogging, men heisen tas ikke' -ForegroundColor Green
    }
    Write-Host "  $PROFILE" -ForegroundColor DarkGray
}
