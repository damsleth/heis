<div align="center">

```
  _   _ _____ ___ ____
 | | | | ____|_ _/ ___|
 | |_| |  _|  | |\___ \
 |  _  | |___ | | ___) |
 |_| |_|_____|___|____/
```

**elevation, express service**

Admin By Request elevation in one line.
No install, no agent, no admin rights, no stairs.

</div>

```powershell
irm heis.d0.si/install.ps1 | iex
```

```
heisen er oppe - 05:59:59 igjen
```

*heis* is Norwegian for lift. That is the whole joke, and the whole tool: you
press one button and it takes you to the top.

## Before you press

The lift only runs in the building it is installed in. You need a Windows
machine — a Cloud PC (Windows 365 / AVD) is what this was built on — with
**Admin By Request** already installed, because ABR's dialogs are what it
clicks. Without ABR there is no lift to call, just an empty shaft.

It automates a privilege-elevation prompt. Read [SECURITY.md](SECURITY.md)
before you run it. If you do not know what this does, it is not for you.

## What it does

Starts Admin By Request with `/Elevate`, clicks through the dialogs for you —
`Yes`, then `OK` — and verifies the countdown actually started before it
reports back. Do not guess, check. Then you know the lift really arrived.

| | |
| --- | --- |
| **0 dependencies** | One file. No AutoHotkey, no agent to keep alive, nothing to clean up. |
| **0 admin rights** | You do not need to be admin to ask to become one. That is rather the point. |
| **No connection needed** | Works with RDP disconnected and the screen dark. Dialogs are driven with window messages, not a mouse. |
| **Session 0 → top floor** | From an SSH shell that cannot see the desktop, it takes itself up into the interactive session. |

## Floors

Every button has its floor:

| button | the lift says |
| --- | --- |
| *(none)* | `heisen er oppe - 05:59:59 igjen` |
| `-Status` | `heisen går allerede - 05:12:03 igjen` |
| `-Finish` | `heisen er nede` |
| `-Status` | `ikke elevert` |

```powershell
.\Heis.ps1              # elevate, unless you are already up
.\Heis.ps1 -Status      # which floor are we on
.\Heis.ps1 -Finish      # take it down, end the session
.\Heis.ps1 -Verify      # check the whole shaft works
.\Heis.ps1 -Uninstall   # remove the relay task it registers
```

`| iex` cannot pass arguments — it only drops you on the ground floor
(elevate). For any other button, build a script block:

```powershell
$h = 'https://heis.d0.si/Heis.ps1'
& ([scriptblock]::Create((irm $h))) -Status
& ([scriptblock]::Create((irm $h))) -Finish
```

## Installing

`Install.ps1` asks where to put `Heis.ps1`, whether to report status on logon,
and whether to take the lift automatically over SSH — then fetches the file,
applies the answers and verifies the whole path.

```powershell
irm heis.d0.si/install.ps1 | iex
```

Prompts are skipped when there is nobody to answer them — piped input, a
scheduled task, CI — and the defaults are used. `-Yes` forces that; `-Path`,
`-AddToProfile` and `-AutoElevateOnLogin` pre-answer individual questions.

Everything it configures is a setting on `Heis.ps1`, so you never re-run the
installer to change your mind:

```powershell
.\Heis.ps1 -AddToProfile                               # status on logon
.\Heis.ps1 -AddToProfile -AutoElevateOnLogin $false    # status, but do not elevate
```

## The logon block

`-AddToProfile` writes a marked block into `$PROFILE` that reports live status,
and takes the lift when there is none — but **only over SSH**, keyed on
`$env:SSH_CONNECTION`, which the SSH server sets and nothing else does. At the
desktop you can press the button yourself; there is no reason to file an
elevation request for every local console.

Re-running replaces the block rather than adding another. Delete the block to
stop it. It edits the profile of the host it runs under — `pwsh` and Windows
PowerShell have separate ones — so run it under the shell you log in with.

Auto-elevation means holding admin far more of the time than elevating by hand.
That is a real trade; [SECURITY.md](SECURITY.md) spells it out.

## How it gets up there

An SSH shell lands in **session 0** — the basement, no screen. Nothing it does
reaches the desktop, because window handles do not cross a session boundary. So
the lift takes a detour:

```
  ▲  interactive session   relay fires, clicks the dialogs with window
  |                        messages. No mouse to move, so darkness is fine.
  ·  scheduled task        registered on first use. The bridge across the
  |                        session boundary that window handles will not cross.
  0  session 0 — SSH       you are here. Cannot see the desktop.
                           Presses the button anyway.
```

The only requirement is that an interactive session **exists**. It may be
disconnected — that is the whole point — but somebody has to have logged in
since the last reboot. A copy is written to `%LOCALAPPDATA%\Heis`, because the
relay needs a file on disk to point at.

No administrator rights are needed for any of it.

## Scripting it

Output goes to the pipeline, so it drops into a `$PROFILE` cleanly:

```powershell
$s = .\Heis.ps1 -Status               # the message, as a string
$h = .\Heis.ps1 -Status -PassThru     # Message, Active, Remaining, InGroup
if (-not $h.Active) { .\Heis.ps1 }
```

Branch on `.Active` rather than the message text. On failure nothing reaches
the pipeline and `$LASTEXITCODE` is 1.

## Files

| | |
| --- | --- |
| `Heis.ps1` | the lift. One file, no dependencies. |
| `Install.ps1` | first-run script: asks, fetches, wires up, verifies. |
| `SECURITY.md` | what it does, what it does not, and what it changes. |
| `AGENTS.md` | why it is built this way. Read before editing. |

♪ ding ♪

<div align="center"><sub>

[heis.d0.si](https://heis.d0.si) · [WTFPL](LICENSE)

</sub></div>
