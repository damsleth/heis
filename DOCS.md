# `heis`: manual

The [README](README.md) has the one-liner and the everyday buttons. This is
everything else.

## Installing

The installer is guided and walks five steps, asking only what it has to.
Enter accepts the suggestion in `[brackets]`.

1. **Checks the machine.** Windows, Admin By Request, and whether PowerShell
   may run script files. Windows PowerShell defaults to `Restricted`, which
   runs none. If so, it offers `RemoteSigned` for your user only, which needs no admin.
2. **Fetches `Heis.ps1`** into `%LOCALAPPDATA%\Programs\Heis`, or wherever
   heis already is.
3. **Wires it up.** Puts `heis` on your user PATH, and optionally adds a
   [logon block](#the-logon-block) to `$PROFILE`.
4. **Runs `heis -Doctor`.** Checks every part, repairs what belongs to heis,
   and says what to do about the rest.
5. **Offers a real test.** It elevates, unless ABR is already running.

After that it is just `heis`, in any terminal: PowerShell, cmd, Git Bash, or
an SSH session.

### Other ways in

The same installer, from wherever you happen to be:

```powershell
# PowerShell, if iwr is what your fingers know
iwr -useb https://heis.d0.si/install.ps1 | iex

# PowerShell, with curl
curl.exe -fsSL https://heis.d0.si/install.ps1 | Out-String | iex
```

```bat
:: cmd.exe
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://heis.d0.si/install.ps1 | iex"

:: cmd.exe, with curl
curl.exe -fsSLo "%TEMP%\heis-install.ps1" https://heis.d0.si/install.ps1 && powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\heis-install.ps1"
```

```sh
# from a Mac or Linux box, over SSH - -t so the installer can ask its questions
ssh -t cloudpc 'powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://heis.d0.si/install.ps1 | iex"'
```

Without `-t` there is nobody to answer, and the installer takes the defaults.
That is fine too. `-ExecutionPolicy Bypass` covers only that one process: the
installer still checks the policy your later shells will get.

### Options

`| iex` cannot pass parameters. To pre-answer questions, build a script block:

```powershell
& ([scriptblock]::Create((irm https://heis.d0.si/install.ps1))) -Yes
```

| parameter | |
| --- | --- |
| `-Yes` | take every default, ask nothing |
| `-Path <dir>` | where `Heis.ps1` goes |
| `-AddToPath $false` | no PATH entry, and remove one an earlier install added |
| `-AddToProfile $false` | no logon block, and remove one an earlier install added |
| `-AutoElevateOnLogin $false` | logon block reports status, but never elevates |
| `-Verify $false` | skip the test at the end |
| `-Force` | replace an existing `Heis.ps1` without asking |

Prompts are skipped on their own when there is nobody to answer them, such as
piped input, a scheduled task or CI.

### Updating

Run the one-liner again. It finds the installed copy, replaces it if it has
changed, and re-checks everything. Your current answers become the defaults,
so pressing Enter (or `-Yes`) keeps the setup you have. Answering no takes the
PATH entry or logon block out again. An install from before
heis had a folder of its own moves into `%LOCALAPPDATA%\Programs\Heis`. The
doctor then points your logon block at the new copy, and the old file can be
deleted.

### Uninstalling

```powershell
heis -Uninstall
```

It removes the relay task, its state in `%LOCALAPPDATA%\Heis`, the PATH entry
and `heis.cmd`, and the logon block in both PowerShell profiles. If heis is in
the default folder, that folder goes too. It leaves the execution policy alone,
because other scripts may rely on it now.

## Without installing

Nothing has to be installed. A script block runs it straight off the URL, and
takes any button:

```powershell
$h = 'https://heis.d0.si/Heis.ps1'
& ([scriptblock]::Create((irm $h)))            # elevate
& ([scriptblock]::Create((irm $h))) -Status
& ([scriptblock]::Create((irm $h))) -Finish
```

It still writes a copy to `%LOCALAPPDATA%\Heis`, because the relay task needs
a file on disk to point at.

## The PATH

`heis -AddToPath` writes `heis.cmd` next to `Heis.ps1` and adds that folder to
your **user** PATH. No admin is needed, and other entries are untouched,
including `%VARIABLES%`. In PowerShell, `heis` runs `Heis.ps1` directly, so
`-PassThru` objects work. Every other shell goes through `heis.cmd`.

The PowerShell that ran the installer sees the change at once, and new
terminals do too. A cmd or Git Bash that started that PowerShell does not; open
a new one. One more exception: if you installed over SSH, the desktop's
Explorer is not told. A terminal opened from the desktop finds `heis` after you
sign out and in again.

## The logon block

`-AddToProfile` writes a marked block into `$PROFILE` that reports live status,
and takes the elevator when there is none, but **only over SSH**, keyed on
`$env:SSH_CONNECTION`, which the SSH server sets and nothing else does. At the
desktop you can press the button yourself; there is no reason to file an
elevation request for every local console.

```powershell
heis -AddToProfile                               # status, and elevate over SSH
heis -AddToProfile -AutoElevateOnLogin $false    # status only
heis -AddToProfile:$false                        # remove the block (PowerShell only)
heis -AddToPath:$false                           # take heis off the PATH
```

From cmd, write `false` instead of `$false`:
`heis -AddToProfile -AutoElevateOnLogin false`. The `:$false` forms only
work in PowerShell, because Windows PowerShell's `-File`, which `heis.cmd`
uses, cannot pass them.

Re-running updates the block in place. Only its path and its elevate setting
change, so your own edits to it survive. For a fresh copy of the template,
take it out and add it again:
`heis -AddToProfile:$false; heis -AddToProfile`. `heis -Uninstall`, or
deleting the block, stops it.

The block stays quiet in shells that are not a person at a prompt, such as
`ssh host <cmd>`, scp, sftp and rsync. Output there would corrupt their data
stream. It edits the profile of the shell it runs
under: `pwsh` and Windows PowerShell have separate profiles. Run it under the
shell your SSH logins start. `heis -Doctor` checks the SSH server's
`DefaultShell` and tells you if they differ.

Auto-elevation means holding admin far more of the time than elevating by hand.
That is a real trade; [SECURITY.md](SECURITY.md) spells it out.

## How it gets up there

An SSH shell lands in **session 0**: the basement, no screen. Nothing it does
reaches the desktop, because window handles do not cross a session boundary. So
the elevator takes a detour:

```
  ▲  interactive session   relay fires, clicks the dialogs with window
  |                        messages. No mouse to move, so darkness is fine.
  ·  scheduled task        registered on first use. The bridge across the
  |                        session boundary that window handles will not cross.
  0  session 0, SSH       you are here. Cannot see the desktop.
                           Presses the button anyway.
```

The only requirement is that an interactive session **exists**.  
It may be disconnected (that is the point), but **somebody has to have logged in since the last reboot.**

No administrator rights are needed for any of it.

## Scripting it

Output goes to the pipeline, so it drops into a `$PROFILE` cleanly:

```powershell
$s = heis -Status                # the message, as a string
$h = heis -Status -PassThru      # Message, Active, Remaining, InGroup
if (-not $h.Active) { heis }
```

Branch on `.Active` rather than the message text. On failure nothing reaches
the pipeline and `$LASTEXITCODE` is 1; on success it is 0. An error never
closes your shell, even when heis runs from a URL.

## Troubleshooting

Start here. It checks each part, repairs what belongs to heis, and prints the
fix for the rest:

```powershell
heis -Doctor
```

If `heis` itself is not found, call the file:
`& "$env:LOCALAPPDATA\Programs\Heis\Heis.ps1" -Doctor`.

| you see | why | do this |
| --- | --- | --- |
| `heis : The term 'heis' is not recognized` | This terminal started before heis was on the PATH. | Open a new terminal. After an install over SSH, sign out and in on the desktop. |
| `Heis.ps1 cannot be loaded because running scripts is disabled` | Execution policy is `Restricted`. | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (no admin), or type `heis.cmd`. |
| `PowerShell is locked to … by group policy` | Your organisation forbids script files. | Nothing heis can do. Ask whoever manages the machine. |
| `Admin By Request is not installed` / `cannot find AdminByRequest.exe` | ABR is missing, or in an odd place. | Install the ABR client, or pass `-Exe <path>`. |
| `this account has no desktop session` | Nobody has logged in since the reboot, or it was another account. | Connect over RDP once. You can disconnect again straight away. |
| `no reply from the interactive session within 75s` | An earlier relay run is still going, and Task Scheduler ignores new starts until it ends. | Wait a minute and try again. If it repeats, run `heis -Doctor`. |
| `started Admin By Request but no countdown appeared` | ABR asked for something heis does not answer, such as a reason or an approval. Or ABR is wedged. | Elevate once by hand to see what it asks. If nothing appears at all, ABR is wedged. `heis -Doctor` lists other tasks calling `/Elevate`, and a reboot clears it. |
| `could not register a relay task under any name` | Policy blocks creating scheduled tasks. | The message includes a `schtasks` command that confirms it. |
| `heis er avinstallert, unntatt: scheduled task …` | The task was created while elevated, and only an elevated shell can delete it. | Elevate through the Admin By Request tray icon, open an elevated shell, and run the `schtasks /delete` line it printed. |
| `what came from … is not Heis.ps1` | A proxy or a login page answered instead. | Try again, or download it yourself: `irm https://heis.d0.si/Heis.ps1 -OutFile Heis.ps1`. |
| `Could not create SSL/TLS secure channel` on the one-liner | Old Windows PowerShell offers TLS 1.0 first. | `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'`, then run the one-liner again. |
| scp or sftp fails with `Received message too long` | A logon block from before the quiet guard prints its status into scp's stream. | `heis -AddToProfile:$false; heis -AddToProfile`. `heis -Doctor` flags it. |
| Logon block does nothing over SSH | The SSH server starts `cmd.exe`, or a PowerShell whose profile has no block. | `heis -Doctor` prints the exact command for your setup. |

Before blaming heis, check what state the session is actually in. Most "it
did nothing" reports are the session, not the code.

## Files

| | |
| --- | --- |
| `Heis.ps1` | the elevator. One file, no dependencies. |
| `Install.ps1` | the guided installer: checks, fetches, wires up, verifies. |
| `DOCS.md` | this manual. |
| `SECURITY.md` | what it does, what it does not, and what it changes. |
| `AGENTS.md` | why it is built this way. Read before editing. |

