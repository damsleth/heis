# Running macros with nobody connected

## It works, and it needs no setup

Proven end to end on this Cloud PC with the RDP client closed: `heis.ps1` ended
an Admin By Request session and requested a new one, clicking through both of
ABR's dialogs, while the session was `Disc` and had no input desktop at all.

```
probe-input: sendinput=0 landed=NO      qwinsta: session 2  Disc
─────────────────────────────────────────────────────────────────
1. launching AdminByRequest.exe
2. waiting for 'exact: Admin By Request Confirm'
3. pressing 'Yes'
4. waiting for 'exact: Admin By Request'
5. pressing 'OK'
heisen er oppe - 05:59:58 igjen
```

No `tscon`, no console reattachment, no virtual display, no admin. The only
requirement is that **an interactive session exists** with the agent in it — it
may be disconnected, but it must not be logged off. After a reboot, connect
once over RDP to re-establish it.

## Why: two kinds of automation

| | mechanism | works disconnected |
| --- | --- | --- |
| `run`, `windows`, `win-pos`, `control-list`, `buttons` | enumeration | yes |
| `wait-window`, `wait-gone` | enumeration | yes |
| `control-settext`, `control-text` | `WM_SETTEXT` / `WM_GETTEXT` | yes |
| `press-text`, `control-press` | `BM_CLICK` | yes |
| `control-click` | `WM_LBUTTONDOWN/UP` | yes |
| `activate` | `SetForegroundWindow` | yes |
| `control-send` | synthesised keystrokes | **unreliable** |
| `click-icon`, `send` | `SendInput` | **never** |

Synthetic input reaches only a live input desktop. Window messages do not care.
Build macros from the message-based verbs and disconnection stops mattering.

`control-send` is the trap in the middle: it looks message-based but
synthesises keystrokes, so it still depends on modifier state. `HEADLESS-OK`
arrived as `hEAD`. Use `control-settext`.

## Elevated windows block everything

An **elevated foreground window silently blocks all synthetic input**. UIPI
refuses injection from a medium-integrity process to a higher one, `SendInput`
still returns success, and the session is connected, unlocked and healthy in
every other respect. Reproduced by toggling focus:

| foreground window | `probe-input` |
| --- | --- |
| `Administrator: …pwsh.exe` | `landed=NO` |
| `Shell_TrayWnd` (explorer) | `landed=yes` |

```powershell
.\Send-AhkCommand.ps1 active-window     # elevated=YES means this, not a broken session
```

The agent cannot fix it: UIPI also blocks `SetForegroundWindow` upward, so
`activate` cannot move focus off an elevated window. A human has to click
something. This only affects the `SendInput` verbs — the message-based ones are
unaffected, which is another reason to prefer them.

## Probing

`Ready` is a measurement, not an inference. The agent injects a no-op mouse
event, nudges the cursor 4px, reads the position back and restores it. Input
that is accepted and discarded fails that test; `SendInput`'s own return value
is worthless — on a Cloud PC console it returned 1 while delivering nothing.

```powershell
.\Send-AhkCommand.ps1 probe-input
```

Cached, and re-probed when the session topology changes: which desktop is in
front, whether the session is on the console, and whether the foreground window
is elevated. Those are the only things the answer depends on.

## What was tried and is not needed

Reattaching the session to the console with `tscon` on disconnect. It exists to
make `SendInput` work unattended, and it is not needed here because the
message-based verbs already work. It was also actively harmful: the task fired
on reconnect as well as disconnect and pulled the session back to the console,
producing an RDP lockout loop. Removed in full.

If you ever do need `SendInput` unattended — taskbar clicking, or an app that
ignores posted messages — that is the approach to revisit, on a normal VM rather
than a Cloud PC, and with `active-window` checked at each step so UIPI is not
mistaken for a dead console. Whether a Cloud PC console can receive input at
all was never established; an elevated window was in the foreground throughout
those tests.

## Notes

- **A virtual display adapter is not needed.** The session has a virtual display
  either way, and this was never a display problem.
- **Message-based automation is per-app.** Classic Win32 and WinForms respond —
  Admin By Request is WinForms and works. WinUI, Electron and Chromium draw
  their own controls with no window handles, so `buttons` comes back empty and
  none of it applies. Check with `buttons` before building on it.
