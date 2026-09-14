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

...and the cursor does not move. Measured on a Windows 365 Cloud PC console.

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
- It is per-app. Classic Win32 responds; WinUI, Electron and Chromium draw their
  own controls with no handles, so `buttons` comes back empty and none of it
  applies.
- `wait-window` occupies the agent for its whole duration — one command at a
  time. The client's `-TimeoutSec` must exceed the wait or it gives up on a
  command that would have succeeded.

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

## Style

Comments explain **why**, especially where the code looks like it could be
simpler — most of the odd-looking choices here are load-bearing and are
annotated with the failure that motivated them. Keep that. PowerShell must parse
under Windows PowerShell 5.1: no ternaries, and no `if`-expressions in hashtable
values.
