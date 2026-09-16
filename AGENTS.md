# Notes for whoever works on this next

`README.md` says what it does. This file is the hard-won part: things that cost
real debugging to establish and are not visible in the code.

This repo started as a general AutoHotkey automation toolkit and narrowed to
one job. The agent, its command queue and its client are gone — if you ever
need them, they are in the git history before the single-purpose rewrite. What
survived is the reasoning, because most of it is why `Heis.ps1` is shaped the
way it is.

## The two kinds of automation

This is the load-bearing fact. Everything else follows from it.

| | mechanism | works disconnected |
| --- | --- | --- |
| window messages — `BM_CLICK`, `WM_SETTEXT`, enumeration | posted to a control | **yes** |
| synthetic input — `SendInput`, mouse, keystrokes | needs the input desktop | **no** |

Synthetic input reaches only the session's *live input desktop*. Lock the
session, disconnect RDP, or park it on a console and input goes nowhere — and
**Windows reports success the whole time**. `SendInput` returns 1 while
delivering nothing.

Window messages do not care. That is the only reason this works with the RDP
client closed, and it is why `Press-Button` posts `BM_CLICK` instead of
clicking a coordinate. Never "improve" it into a mouse click.

Proven end to end with the session in `Disc` state and no input desktop at all:
finish an ABR session, elevate again, both dialogs clicked, nobody connected.

### The corollary that keeps biting

**A healthy-looking desktop does not mean input works.** Session state
`Active`, `OpenInputDesktop` succeeds, desktop is `Default`, `SendInput`
returns 1 — and the cursor does not move.

The usual cause is **UIPI**: an elevated foreground window silently blocks
injection from a medium-integrity process. Reproduced by toggling focus —
elevated console in front, nothing lands; taskbar in front, it works. It does
not affect message-based automation, which is another reason to prefer it.

That one cost an entire investigation. A Cloud PC console was declared
incapable of receiving input on the strength of a failed probe, while an
elevated PowerShell console sat in the foreground the whole time. Two candidate
causes, never separated, and a confident wrong conclusion written down as fact.
**When something fails, enumerate the causes before picking one.**

## Session model

- SSH lands in **session 0**. Window handles do not cross a session boundary,
  so a process there can neither see nor message the desktop's windows. That is
  the entire reason the relay task exists.
- The relay is a scheduled task set to *run only when the user is logged on*.
  **No administrator rights are needed** — verified: creating a task as a
  non-admin over SSH succeeds.
- An interactive session must exist, though it may be disconnected. Checked up
  front via an `explorer.exe` outside session 0, because `schtasks /run`
  reports success even when nothing can start and the only other symptom is a
  75-second silence.

## Recover instead of refusing

A plain `Heis.ps1` with no arguments should just work, so it repairs what it
can rather than reporting it.

- **Drive the outcome, not a script of steps.** `Invoke-DialogLoop` answers
  whatever known dialog is on screen until the countdown appears. An earlier
  version replayed one exact sequence and would wait for a second dialog that
  does not always come — then call a run that had already succeeded a failure.
- **Several captions per button** (`Yes`/`Ja`/`Continue`), so a localised or
  reworded dialog still gets answered.
- **Find the exe, do not assert it.** Running image first, then both Program
  Files roots, then a depth-limited search.
- **Fall back to a second task name.** The canonical task can be unwritable
  through no fault of the run — see below — and a spare task beats a dead end.
- **Fail fast only on what cannot be repaired**, and say what would fix it.

## Things that look harmless and are not

- **Do not re-register the relay task on every run.** A task first created
  while ABR had granted admin carries a security descriptor an unelevated
  account cannot overwrite, so every later run from a plain SSH shell died on
  "Access is denied" — while the existing task was perfectly good and would
  have worked untouched. Read its action first; only register when missing or
  wrong.
- **Never `Get-AbrState` from a poll loop.** It shells out to `net localgroup`.
  The dialog loop runs several times a second and was briefly spawning that
  many processes. Use `Get-AbrCountdown`, which only looks at windows.
- **Match dialog titles exactly.** ABR reuses `Admin By Request Confirm` for
  both the elevation prompt and the finish prompt, and `Admin By Request` is a
  substring of it. A "contains" match picks by z-order: right until the day it
  is not, and then it presses a button on the wrong dialog.
- **Address buttons by caption, never by index.** Ordering is an artefact of
  creation order. On ABR's confirm dialog the buttons are **No first, Yes
  second**. Two conclusions in this repo's history — both "this primitive is
  broken" — were wrong tests pressing the wrong button.
- **`Press-Button` considers only BUTTON-class controls.** A substring match
  over every control will happily find "OK" inside a label and click nothing.
- **The in-session side ignores a `request.json` older than three minutes.**
  Without that, anything that starts the task — a person, a stale trigger —
  replays the last request and silently elevates.

## Encoding: pure ASCII, no BOM

Both scripts must stay **pure ASCII with no BOM**. This is not tidiness; it is
the only encoding that survives both ways they are run:

- As a file under **Windows PowerShell 5.1** — which the relay uses — a `.ps1`
  is read as ANSI unless it carries a BOM, mangling every non-ASCII character.
- **Piped from a URL**, `irm … | iex` keeps the BOM as a *character*, and
  PowerShell then refuses to parse the script at all. It fails to recognise the
  comment-based help and reports `Missing expression after unary operator '-'`
  from inside the help text a dozen lines below, which points nowhere useful.

A BOM fixes the first and breaks the second. The Norwegian letters in output
are composed from character codes (`$AA`, `$OE`) so neither is needed. Do not
type an `å` back in.

## Other traps, all hit at least once

- **The scheduled task names the account by SID**, not `DOMAIN\user`. An SSH
  login reports `USERDOMAIN` as `WORKGROUP`, which does not resolve, and Task
  Scheduler answers "No mapping between account names and security IDs".
- **Hardcode Windows PowerShell's absolute path**, not `$PSHOME` — under pwsh 7
  that points at `pwsh.exe`, which a downloaded copy cannot assume exists.
- **`$MyInvocation.MyCommand.ScriptBlock` describes the CALLER under `iex`.**
  It returned a few hundred bytes of the invoking wrapper, which got written
  out as `Heis.ps1` and run by the relay. Symptom: a silent 75-second timeout.
  Hence the marker check in `Resolve-SelfPath`.
- **Splat a hashtable, not an array.** Array splatting passes *positionally*:
  `@('-Verify')` bound the string to `-Exe` and ran the default action against
  a nonsense path. It looked like it worked, because the exe lookup healed past
  the bad value — self-healing hides bugs as well as it hides faults.
- **`[WindowsPrincipal]::IsInRole` is a snapshot.** A process token carries the
  group membership it was born with, so a shell started before elevation
  answers "not admin" for the rest of its life. Use live group membership, and
  prefer a function over a variable so it cannot go stale.
- **`$PROFILE` may be a OneDrive placeholder.** With Documents redirected,
  `Get-Item` reports `Length 0` and a stale `LastWriteTime` for a dehydrated
  file — the profile read as 0 bytes while holding 2257 bytes of content, which
  looks exactly like having just destroyed it. `ReadAllBytes`/`ReadAllText`
  hydrate it. Never branch on `.Length` there.
- **Raw URLs are case-sensitive, and `core.ignorecase` hides renames.** Git
  recorded `heis.ps1` while the disk said `Heis.ps1`, which would have 404'd
  the self-fetch in a way that looks nothing like a case problem.
- **Never let a second thing call `/Elevate`.** A caller that raises the Confirm
  dialog and does not answer it leaves ABR with a request pending. ABR then
  ignores every later request in silence: no window, and the tray menu's
  "Request administrator access" does nothing. Only a reboot clears it. A
  predecessor of this script polled every 30 seconds and did exactly that,
  including through disconnected sessions, and the symptom was `started Admin
  By Request but no countdown appeared` from a Heis that was working correctly.
  Before blaming this code, check what else is calling ABR:
  `Get-ScheduledTask | Where-Object { $_.TaskPath -eq '\' }`.
- **GitHub's raw CDN caches for about five minutes.** A push then a fetch will
  serve the old file, including to a cache-buster. Twice this looked like a fix
  not working.

## Environment this was built on

A Windows 365 Cloud PC, and some of it is specific to that:

- The user is **not a local administrator**, so `tscon`, `Get-ScheduledTask`,
  `Get-CimInstance`, `Get-WinEvent` and `Win32_Process` all fail from SSH. Use
  `schtasks` and registry reads; they work unprivileged.
- **Windows Script Host is policy-blocked** — a `.vbs` opens a *Windows Script
  Host Settings* dialog instead of running. Do not build test fixtures on it.
- RDP resolution and DPI change under a running process as the client window is
  resized or moved between displays. Never cache geometry.
- `tscon`-ing a disconnected session onto the console was tried and removed. It
  exists to make `SendInput` work unattended, which message-based automation
  makes unnecessary — and the task fired on reconnect too, pulling the session
  back and locking the machine out of RDP entirely.

## Testing

There is no test suite; drive it.

```powershell
.\Heis.ps1 -Status          # cheapest round-trip through the relay
.\Heis.ps1 -Verify          # non-destructive if a session is already running
```

Prompts are skipped when stdin is redirected, so `Install.ps1` is safe to run
from automation — it takes the defaults. Use `-Yes` to be explicit.

Before claiming an elevation change works, check what state the session is
actually in first. Most "it did nothing" reports are the session, not the code.

## Style

Comments explain **why**, especially where the code looks like it could be
simpler — most of the odd-looking choices here are load-bearing and annotated
with the failure that motivated them. Keep that. PowerShell must parse under
Windows PowerShell 5.1: no ternaries, and no `if`-expressions in hashtable
values.
