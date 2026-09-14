# Running macros unattended on a Windows 365 Cloud PC

## Conclusion first: this does not work on a Cloud PC

Tested on this machine, end to end. `tscon` reattaches the session to the
console exactly as intended — and the console then accepts synthetic input and
throws it away.

```
> .\Send-AhkCommand.ps1 probe-input
sendinput=1 landed=NO cursor 512,384 -> 512,384 desktop=Default console=yes
```

Every indicator says healthy. Session state `Active`, desktop `Default`,
`OpenInputDesktop` succeeds, and `SendInput` returns 1 — it reports inserting
the event. The cursor does not move. Neither mouse nor keyboard reaches
anything: `Win+R` opens no Run dialog.

A Windows 365 Cloud PC has no real console input stack. The only path that
delivers input is the RDP stack, and that is precisely what goes away when you
disconnect. So on a Cloud PC:

> **Synthetic input works only while an RDP session is connected.**

The agent now detects this by experiment rather than by name — see Probing
below — so it reports `Ready = False` and refuses instead of silently doing
nothing.

### What to do instead

- **Keep a session connected.** Park a `windows.app` client on a machine that
  does not sleep. This is the only way to run unattended on the Cloud PC itself.
- **Use a different machine for unattended work.** An ordinary Azure or on-prem
  VM has a working console, and the `tscon` approach below does work there.
- **Automate by window message, not synthetic input.** This works, fully. See
  below — it is the real answer for unattended work on a Cloud PC.

## Message-based automation does work headless

Verified on this machine with the input desktop provably dead
(`probe-input` → `landed=NO`) throughout:

| verb | mechanism | headless |
| --- | --- | --- |
| `run` | CreateProcess | works |
| `windows`, `win-pos`, `control-list` | enumeration | works |
| `control-settext` | `WM_SETTEXT` | works, exact |
| `control-text` | `WM_GETTEXT` | works |
| `control-press` | `BM_CLICK` | works |
| `control-click` | `WM_LBUTTONDOWN/UP` | works |
| `activate` | `SetForegroundWindow` | works |
| `control-send` | synthesised keystrokes | **unreliable** |
| `click-icon`, `send` | `SendInput` | **never** |

A whole interaction, start to finish, with nothing connected:

```powershell
.\Send-AhkCommand.ps1 run charmap.exe
.\Send-AhkCommand.ps1 'control-settext ahk_class #32770 | Edit2 | omega'
.\Send-AhkCommand.ps1 'control-press   ahk_class #32770 | Button4'
.\Send-AhkCommand.ps1 'control-text    ahk_class #32770 | Edit2'   # -> [omega]
```

### Rules that follow

- **Never use `control-send` for text.** It synthesises keystrokes, so it still
  depends on modifier state: `HEADLESS-OK` arrived as `hEAD`. Use
  `control-settext`, which is one `WM_SETTEXT` and is exact.
- **Prefer `control-press` to `control-click` for buttons.** Both work, but
  `BM_CLICK` carries no coordinates, so it cannot be thrown off by a control
  that moved, is partly offscreen or is covered.
- **Find control names with `control-list`, and confirm them with
  `control-text`.** Indices are not stable across versions or layouts — in
  Character Map, `Button3` is *Advanced view* and `Button4` is *Reset*, which is
  not guessable. Two of the tests in this repo's history were wrong because of
  exactly that.
- **This does not work on the taskbar.** The shell does not respond to posted
  messages, so `click-icon` stays connected-only. Target application windows.
- **It is per-app.** Classic Win32 controls respond well. WinUI, Electron and
  Chromium render their own controls with no window handles to address, so
  there is nothing for `control-list` to find. Check with `control-list` before
  building on it.

The rest of this document describes the `tscon` setup. It is correct, and it
works on a normal VM. Keep it for that; do not expect it to help here.

---

Goal: the same session you debug a macro in over RDP keeps running it after you
disconnect, with no change to the command you send.

## Why a Cloud PC needs a different approach

A Cloud PC is Windows 11 **Enterprise client**, not Server:

```
InstallationType      = Client
fSingleSessionPerUser = 1
```

One interactive session per user. There is no second desktop to fall back to —
logging the console session in separately and running two agents does not work
here, because connecting over RDP reconnects you to the *same* session rather
than making a new one.

That also answers the missing "connect to the console/admin session" checkbox.
That is `mstsc /admin`, a Server-SKU option for attaching to session 0's
console. Windows 365 does not expose it, and it is not what you need: `tscon`
does the equivalent from inside the box, and does it without your involvement.

So instead of two sessions, there is **one session that moves**:

| you are | session is attached to | input works |
| --- | --- | --- |
| connected over RDP | your RDP client | yes |
| disconnected, no task | nothing — locked | **no** |
| disconnected, task installed | the console | yes |

When you reconnect you land back in that same session — same agent, same PID,
same windows, same scroll position. Your debug view and your unattended runtime
are literally the same desktop, which is better than the two-agent arrangement
this doc used to describe.

This matters more on a Cloud PC than on a normal VM: Windows 365 drops idle RDP
connections on its own, so a long macro will meet a disconnect whether or not
you close the client.

## Prerequisite: one elevated install

`tscon` needs local administrator rights. Not "your own session" rights —
reattaching your *own* disconnected session as a standard user fails:

```
> tscon.exe 2 /dest:console
Could not connect sessionID 2 to sessionname console, Error code 5
Error [5]:Access is denied.
```

On a stock Cloud PC the only member of local Administrators is `BuiltInAdmin`,
so this is blocked until someone with rights installs step 2.

The good news is that it is a **one-time** elevated action, not standing admin.
The task runs as SYSTEM once registered, so everything afterwards works from
your normal account and over SSH. What to ask for is narrow:

> Please run `.\Install-ConsoleReattachTask.ps1` elevated, once, on my Cloud PC.
> It registers a SYSTEM scheduled task that runs `tscon <my session> /dest:console`
> when my RDP session disconnects, so automation keeps running. It touches no
> other session and stores no credentials.

Standing local admin would also do it, if that is easier to get.

## Setup

### 1. The agent itself

```powershell
.\Install-AhkAgentTask.ps1
```

Starts the agent on interactive logon. Already done if `-List` shows an agent.

### 2. Reattach to the console on disconnect

**Run elevated**, from the RDP session or an elevated SSH shell:

```powershell
.\Install-ConsoleReattachTask.ps1
```

Registers a SYSTEM task on event 24 (*session disconnected*) that runs
`Reattach-ConsoleSession.ps1`, which moves the agent's session to the console
and unlocks it. It picks the session from the agent's own heartbeat, so it can
never move a session that has no agent in it.

Check what it would do without waiting for a disconnect:

```powershell
.\Reattach-ConsoleSession.ps1 -WhatIf -Verbose
```

### 3. Stop the session locking itself once it is on the console

The reattach unlocks the session; these stop it re-locking while idle.

```powershell
Set-ItemProperty 'HKCU:\Control Panel\Desktop' ScreenSaveActive 0
Set-ItemProperty 'HKCU:\Control Panel\Desktop' ScreenSaverIsSecure 0

New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' InactivityTimeoutSecs 0 -Type DWord
```

Intune policy can reassert these. If the session keeps locking after a while,
that is where to look first, not at this repo.

### 4. Verify

Disconnect your RDP client, wait ~10 seconds, then over SSH:

```powershell
.\Send-AhkCommand.ps1 -List
```

`Ready` should be `True` and `Console` should be `True`:

```
Session User        Pid Ready Console Desktop Screen    Dpi
      2 DOMAIN\cj  2172  True    True Default 1144x1375  96
```

Then confirm input actually lands:

```powershell
.\Send-AhkCommand.ps1 preview-icon 1
```

If it refuses with *no usable input desktop*, the reattach did not happen —
check `logs\console-reattach.log`.

## Probing

`Ready` is a measurement, not an inference. The agent injects a no-op mouse
event, nudges the cursor 4px, reads the position back and restores it. Input
that is accepted and discarded fails that test; a name-based check cannot see
it, and `SendInput`'s own return value is worthless here — it returns 1 while
delivering nothing.

```powershell
.\Send-AhkCommand.ps1 probe-input
```

The result is cached and re-probed when the session topology changes — which
desktop is in front, and whether the session sits on the console — because that
is the only thing the outcome depends on. Disconnecting, reattaching and
reconnecting each force a fresh answer.

## Notes

- **No reboot persistence.** A Cloud PC reboot leaves no session, and nothing
  here recreates one; connect over RDP once to re-establish it. Autologon would
  avoid that but means a stored credential on an Entra-joined machine, which is
  not worth it for an occasional reboot.
- **`-Rdp` / `-Console` still work** but there is only ever one agent here, so an
  unqualified command always resolves to it. The flags matter on a multi-session
  box, not this one.
- **A virtual display adapter is not needed.** The session has a virtual display
  either way; locking was never a display problem.

## Cost

Between disconnect and your next connect, the Cloud PC sits with an unlocked
desktop, reachable by anything that can reach the machine. That is the same
bargain any unattended UI automation makes — it is the price of a desktop that
accepts input with nobody watching it. Uninstall with:

```powershell
.\Install-ConsoleReattachTask.ps1 -Uninstall
```
