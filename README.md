# ahk — drive a Windows desktop from SSH

An SSH shell on Windows lands in session 0, which has no desktop. Nothing it
does can reach the screen. This repo closes that gap: a resident AutoHotkey
agent runs inside the interactive session and executes commands dropped into a
file queue, so an SSH shell — or Claude Code running over one — can drive the
desktop it cannot touch directly.

```
SSH (session 0)                     interactive session
  Send-AhkCommand.ps1  --queue/-->  taskbar-click.ahk  --> the desktop
                       <--done/---
```

## Just want to elevate? One file, nothing to install

`Heis.ps1` does the Admin By Request dance on its own — no
AutoHotkey, no agent, no setup, no admin rights. Nothing to clone:

```powershell
irm https://raw.githubusercontent.com/damsleth/heis/main/Heis.ps1 | iex
```

`| iex` cannot pass arguments, so for anything but a plain elevate, make a
script block:

```powershell
$h = 'https://raw.githubusercontent.com/damsleth/heis/main/Heis.ps1'
& ([scriptblock]::Create((irm $h))) -Status
& ([scriptblock]::Create((irm $h))) -Finish
```

Either way it writes a copy to `%LOCALAPPDATA%\Heis`, because the relay task
needs a file on disk to point at.

Output goes to the pipeline, so it drops into a `$PROFILE` cleanly:

```powershell
$s = .\Heis.ps1 -Status               # the message, as a string
$h = .\Heis.ps1 -Status -PassThru     # Message, Active, Remaining, InGroup
if (-not $h.Active) { .\Heis.ps1 }
```

Branch on `.Active` rather than the message text. On failure nothing reaches
the pipeline and `$LASTEXITCODE` is 1.

To keep it somewhere you can find again, `Install.ps1` puts it beside your
PowerShell profile:

```powershell
irm https://raw.githubusercontent.com/damsleth/heis/main/Install.ps1 | iex
```

Or download it and run it:

```powershell
.\Heis.ps1              # elevate, unless already elevated
.\Heis.ps1 -Status
.\Heis.ps1 -Finish      # end the session
.\Heis.ps1 -Uninstall   # remove the relay task it registers
```

Works from the desktop and over SSH. Over SSH it relays itself into the
interactive session through a scheduled task it registers on first use, because
window handles do not cross a session boundary. Cold start on a machine with
nothing installed takes about a second.

It works with nobody connected over RDP — verified, with the session in `Disc`
state and no input desktop. The one requirement is that an interactive session
exists: it may be disconnected, but somebody has to have logged in since the
last reboot.

The rest of this repo is the toolkit that was built to work all of that out,
and is what you want for exploring a new app's windows interactively.

## Quick start

```powershell
.\Install-AhkAgentTask.ps1          # start the agent on interactive logon
.\Send-AhkCommand.ps1 -List         # who is live, and can they receive input
.\Send-AhkCommand.ps1 status
```

Click through an app's dialogs, without coordinates, without anyone connected:

```powershell
.\Run-Macro.ps1 -Exe C:\app\thing.exe `
                -ConfirmWindow 'Confirm Action' -ConfirmButton Yes `
                -OkWindow 'Result' -OkButton OK
```

## The one thing to understand

Two kinds of automation, and they fail in completely different places.

| | mechanism | works when disconnected |
| --- | --- | --- |
| `click-icon`, `send` | `SendInput` | **no** |
| `press-text`, `control-settext`, `run`, `wait-window` | window messages | **yes** |

Synthetic input reaches only the session's live input desktop. Lock the
session, disconnect RDP, or park it on a console and it goes nowhere — and
Windows reports success the whole time. Window messages do not care.

So: **build macros out of the message-based verbs.** They work whether or not
anyone is watching, and they address buttons by the caption a person reads
rather than by a coordinate, which means they also survive the session changing
resolution, DPI or monitor. Keep `click-icon` and `send` for the taskbar and
for things that genuinely need real input, and expect them only to work while
someone is connected.

`HEADLESS-SETUP.md` covers what survives a disconnect, how it was measured, and
what is and is not possible on a Windows 365 Cloud PC.

## Commands

Send any of these with `.\Send-AhkCommand.ps1 <command>`. Multi-part arguments
are separated with `|`.

**Diagnostics**

| command | |
| --- | --- |
| `ping` | is the agent alive |
| `status` | session, desktop, screen, DPI, taskbar geometry |
| `probe-input` | does synthetic input actually land — by experiment, not by name |
| `mouse-pos` | cursor position and the window under it |

**Finding things**

| command | |
| --- | --- |
| `windows [hidden]` | visible windows, or everything |
| `win-pos <win>` | position and size |
| `control-list <win>` | control names |
| `buttons <win>` | control names **with their captions** — start here |

**Acting — message-based, works headless**

| command | |
| --- | --- |
| `run <command>` | launch a program |
| `wait-window <win> \| <secs>` | block until it appears |
| `wait-gone <win> \| <secs>` | block until it closes |
| `press-text <win> \| <caption>` | press a button by what it says |
| `control-press <win> \| <ctl>` | `BM_CLICK` a button by name |
| `control-click <win> \| <ctl>` | post a click to a control |
| `control-settext <win> \| <ctl> \| <text>` | set text exactly |
| `control-text <win> \| <ctl>` | read text |
| `activate <win>` | bring to front |

**Acting — synthetic input, connected only**

| command | |
| --- | --- |
| `click-icon [n]` | click the nth taskbar icon |
| `preview-icon [n]` | move there without clicking |
| `send <keys>` | send keystrokes |
| `control-send <win> \| <ctl> \| <keys>` | unreliable headless — prefer `control-settext` |

**Lifecycle:** `reload`, `exit`. Hotkeys in the session: `F8` preview, `F9`
click, `F10` inspect cursor, `F12` reload, `Ctrl+Alt+Q` exit.

## Matching windows by title

Titles match on **contains** by default, so `Admin By Request` also matches
`Admin By Request Confirm` — and which one you get depends on z-order, so it
can work for weeks and then press the wrong dialog. Prefix the spec with
`exact:` whenever one title is a substring of another:

```powershell
.\Send-AhkCommand.ps1 'press-text exact: Admin By Request | OK'
```

For dialogs that appear in sequence, `wait-gone` on the first before waiting for
the second removes the ambiguity entirely, and is worth doing anyway so a macro
cannot race ahead of a dialog that is still closing.

## Targeting

Agents advertise themselves in `agents/<session>.json`. With more than one live,
an unqualified command prefers a usable desktop, then the remote one over the
console — so a macro you debug over RDP runs unattended unchanged. Pin it with
`-Rdp`, `-Console`, `-Session <n>` or `-User <name>`. Two different people's
desktops are never guessed between; that refuses.

## Files

| | |
| --- | --- |
| `taskbar-click.ahk` | the agent — runs in the interactive session |
| `Send-AhkCommand.ps1` | the client — runs anywhere, including SSH |
| `Run-Macro.ps1` | launch an app and click through its dialogs |
| `Install-AhkAgentTask.ps1` | start the agent on interactive logon |
| `Heis.ps1` | **the deliverable** — elevation in one file, no dependencies |
| `Install.ps1` | copies `Heis.ps1` next to your PowerShell profile |
| `heis_ahk.ps1` | the same thing built on the agent, kept as a worked example |
| `HEADLESS-SETUP.md` | running unattended, and the limits |
| `AGENTS.md` | notes for whoever works on this next |

`agents/`, `queue/` and `logs/` are runtime state and are not tracked.
