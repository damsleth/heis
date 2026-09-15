# Notes for whoever works on this next

Read `README.md` first for what the thing does. This file is the hard-won part:
facts that cost real debugging to establish, and that are not visible in the
code.

## How to test a change

There is no test suite. The agent is live; drive it.

```powershell
.\Send-AhkCommand.ps1 reload          # pick up your edit
Start-Sleep -Seconds 3                # reload is async, the reply beats it
.\Send-AhkCommand.ps1 status
```

Before claiming an input-related change works, check what state the session is
actually in — most "it does nothing" reports are the session, not the code:

```powershell
.\Send-AhkCommand.ps1 probe-input
```

Parsing replies in PowerShell: the reply is **one multi-line string object**, so
`Select-String '^result:'` matches nothing and `-like 'result:*'` returns only
that line, silently dropping multi-line output. Split on newline first. Also
avoid naming a helper function `R` — that is the built-in alias for
`Invoke-History`, and it fails in a way that looks like your code is broken.

## The session model

- SSH lands in **session 0**. It has no input desktop, and window handles do not
  cross session boundaries — so a process there can neither inject input into
  nor enumerate windows in the desktop session. That is the entire reason this
  repo exists, and the reason the control verbs live in the agent rather than in
  a script run over SSH.
- The agent refuses to start in session 0 and reports on stdout, never `MsgBox`
  — a modal dialog there blocks forever with nobody to dismiss it.
- Heartbeats in `agents/<session>.json` are the source of truth for which
  session to talk to. Prefer them to parsing `query user`, whose column layout
  shifts once a session disconnects.

## Input: the thing that keeps biting

**A healthy-looking desktop does not mean input works.** Every name-based
indicator can say fine while input goes nowhere:

- session state `Active`
- `OpenInputDesktop` succeeds, desktop is `Default`
- `SendInput` returns 1 — it reports inserting the event

...and the cursor does not move.

**The usual cause is UIPI, not the session.** An elevated foreground window
blocks injection from this medium-integrity agent, silently. Reproduced by
toggling focus: elevated console in front → `landed=NO`; taskbar in front →
`landed=yes`. So when input "stops working", check `active-window` *before*
suspecting the session. The agent cannot recover on its own either — UIPI blocks
`SetForegroundWindow` upward, so `activate` cannot move focus off an elevated
window and a human has to click something.

This burned a whole investigation: a Cloud PC console was declared incapable of
receiving input on the strength of `landed=NO`, while an elevated PowerShell
console sat in the foreground the entire time. Two candidate causes, never
separated. See the withdrawal in `HEADLESS-SETUP.md`. **When something reports
`landed=NO`, enumerate the causes before concluding one of them.**

Note also that `IsProcessElevated` must use `PROCESS_QUERY_LIMITED_INFORMATION`
(`0x1000`), not `PROCESS_QUERY_INFORMATION` (`0x0400`) — the latter is refused
across an integrity boundary, so it returns "not elevated" for exactly the
processes that matter. It reports `unknown` rather than `false` on failure for
the same reason.

So `InputUsable()` **probes**: it nudges the cursor 4px, reads the position back
and restores it. That is the only check that catches input which is accepted and
then discarded. Do not replace it with a cheaper name-based test; that is
exactly the bug it exists to catch. The result is cached against session
topology (input desktop name + whether the session is on the console), because
that is the only thing the answer depends on.

Corollary for the whole codebase: **a command that cannot act must fail, not
return `ok`.** A silent no-op that reports success is the single hardest failure
to diagnose here, and most of this file is the cost of having shipped one.

## DPI

- `A_ScreenWidth`/`A_ScreenHeight` are live. **`A_ScreenDPI` is cached at
  process start** and never updates. An agent started at 96 kept reporting 96
  after the session moved to a 192 display. Use `SystemDpi()`.
- Geometry maths must scale by the DPI of the **window's own monitor**
  (`WindowDpi(tray)`), not the system value. This is not cosmetic: on the
  console at 96 with a stale system DPI of 192, using the system value gives
  pitch 88 instead of 44 and clicks land on the wrong icon.
- Awareness is pinned at **thread** level. The process-level call is refused
  because stock `AutoHotkey64.exe` is manifested system-DPI-aware and a manifest
  cannot be overridden at runtime. The thread call is not so bound.
- `GetAwarenessFromDpiAwarenessContext` has only three values, so a successful
  Per-Monitor **v2** pin reports as plain `per-monitor`. That is correct, not a
  failure.

## Message-based automation

Works with no input desktop at all: `run`, `windows`, `win-pos`,
`control-list`, `buttons`, `control-settext`, `control-text`, `control-press`,
`control-click`, `activate`, `wait-window`, `press-text`.

- **`control-send` is not in that list.** It synthesises keystrokes, so it still
  depends on modifier state: `HEADLESS-OK` arrived as `hEAD`. Use
  `control-settext`, which is one `WM_SETTEXT`.
- **Address buttons by caption (`press-text`), not by ClassNN.** Index ordering
  is an artefact of creation order and is not guessable: in Character Map,
  `Button3` is *Advanced view* and `Button4` is *Reset*. Two conclusions in this
  repo's history — both "this primitive is broken headless" — were wrong tests
  pressing the wrong button. Verify a control's caption with `buttons` before
  concluding anything about a primitive.
- **Title matching is "contains", and it is z-order dependent.** Measured: a
  substring from the *middle* of a title matches. So `Admin By Request` also
  matches `Admin By Request Confirm`, and which window you get depends on which
  was activated last — it picked the right one until the other was brought to
  the front, then silently picked the wrong one. Prefix a spec with `exact:`
  whenever one title is a substring of another, and prefer `wait-gone` on the
  first dialog before waiting for the second. `ResolveWin` sets the mode per
  call rather than globally, so one `exact:` cannot change how later commands
  match.
- It is per-app. Classic Win32 responds; WinUI, Electron and Chromium draw their
  own controls with no handles, so `buttons` comes back empty and none of it
  applies.
- `wait-window` occupies the agent for its whole duration — one command at a
  time. The client's `-TimeoutSec` must exceed the wait or it gives up on a
  command that would have succeeded.
- **The agent stops heartbeating while it is busy.** It is single-threaded, and
  `ControlGetText`/`WinGetControls` use `SendMessage`, which blocks against an
  app showing a modal dialog. A short staleness cutoff therefore declares a
  healthy agent dead mid-macro — it happened during the ABR run. Liveness is
  the pid; heartbeat age only distinguishes busy from dead, and the reply
  timeout is what actually catches a wedged agent.

## Environment quirks seen here

- This Cloud PC user is **not a local administrator**, so `tscon`,
  `Get-ScheduledTask`, `Get-CimInstance`, `Get-WinEvent` and `Win32_Process` all
  fail from SSH. Use `schtasks` and registry reads instead of the CIM cmdlets;
  they work unprivileged.
- `git init` was run elevated, so `.git` is owned by `BUILTIN\Administrators`
  and git needs `safe.directory` set for the working user.
- Windows Script Host is policy-blocked — a `.vbs` opens a *Windows Script Host
  Settings* dialog instead of running. Do not build test fixtures on `wscript`;
  launch a second AutoHotkey script for a throwaway dialog instead.
- RDP resolution and DPI change under a running agent as the client window is
  resized or moved between displays. Never cache geometry.
- **Documents is redirected into OneDrive, so `$PROFILE` is a cloud
  placeholder.** `Get-Item` reports `Length 0` and a stale `LastWriteTime` for
  a dehydrated file — the real profile read 0 bytes while holding 2257 bytes of
  content, which looks exactly like having just destroyed someone's profile.
  `[IO.File]::ReadAllBytes`/`ReadAllText` hydrate it and return the truth, which
  is what the profile code already uses. Never branch on `.Length` for a file
  under OneDrive.

## Heis.ps1

The single-file version, with no AutoHotkey and no resident agent. Two traps
cost real time and are easy to reintroduce:

- **It must be saved UTF-8 *with BOM*.** The relay task runs Windows PowerShell
  5.1, which reads a `.ps1` as ANSI unless a BOM says otherwise, so the
  Norwegian strings arrive mangled (`går` → `gÃ¥r`) before anything is even
  written. Any editor that helpfully strips the BOM breaks it.
- **The scheduled task names the account by SID, not `DOMAIN\user`.** An SSH
  login reports `USERDOMAIN` as `WORKGROUP`, which does not resolve, and Task
  Scheduler rejects it with "No mapping between account names and security
  IDs". `[WindowsIdentity]::GetCurrent().User.Value` is the same however the
  session was established.

It also hardcodes Windows PowerShell's absolute path rather than `$PSHOME`,
which under pwsh 7 points at `pwsh.exe` — not something a downloaded copy can
assume is installed.

### It recovers instead of refusing

The rule for this script is that a plain `Heis.ps1` with no arguments should
just work, so it repairs what it can rather than reporting it:

- **Drive the outcome, not a script of steps.** `Invoke-DialogLoop` answers
  whatever known dialog is on screen until the countdown appears. The previous
  version replayed one exact sequence and would sit waiting for a second dialog
  that does not always come — then call a run that had already succeeded a
  failure.
- **Several captions per button.** `Yes`/`Ja`/`Continue`, so a localised or
  reworded dialog still gets answered.
- **Find the exe, do not assert it.** Running image first, then both Program
  Files roots, then a depth-limited search.
- **Fall back to a second task name.** The canonical task can be unwritable
  through no fault of the run, and a spare task is cheaper than a dead end.
- **Fail fast on what cannot be repaired.** No interactive session is checked
  up front — an `explorer.exe` outside session 0 — because `schtasks /run`
  reports success regardless and the old code only noticed 75s later.

Two things to keep in mind when editing it:

- `Get-AbrState` shells out to `net localgroup`. Never call it from a poll
  loop; use `Get-AbrCountdown`, which only looks at windows. The loop runs
  several times a second and was briefly spawning that many processes.
- The in-session side ignores a `request.json` older than three minutes.
  Without that, anything that starts the task — a person, a stale trigger —
  replays the last request and silently elevates.

## Style

Comments explain **why**, especially where the code looks like it could be
simpler — most of the odd-looking choices here are load-bearing and are
annotated with the failure that motivated them. Keep that. PowerShell must parse
under Windows PowerShell 5.1: no ternaries, and no `if`-expressions in hashtable
values.
