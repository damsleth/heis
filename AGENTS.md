# Notes for whoever works on this next

`README.md` and `DOCS.md` say what heis does. This file lists instructions, caveats, traps and reasoning for the underlying automation mechanisms it employs.

## The two kinds of automation

This is the axiom. Everything else follows from it.

| what | mechanism | works disconnected |
| --- | --- | --- |
| window messages: `BM_CLICK`, `WM_SETTEXT`, enumeration | posted to a control | **yes** |
| synthetic input: `SendInput`, mouse, keystrokes | needs the input desktop | **no** |

Synthetic input reaches only the session's *live input desktop*. Lock the
session, disconnect RDP, or park it on a console and input goes nowhere, and
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
returns 1, and the cursor does not move.

The usual cause is **UIPI**: an elevated foreground window silently blocks
injection from a medium-integrity process. Reproduced by toggling focus:
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
  **No administrator rights are needed**. Verified: creating a task as a
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
  does not always come, then call a run that had already succeeded a failure.
- **Several captions per button** (`Yes`/`Ja`/`Continue`), so a localised or
  reworded dialog still gets answered.
- **Find the exe, do not assert it.** Running image first, then both Program
  Files roots, then a depth-limited search.
- **Fall back to a second task name.** The canonical task can be unwritable
  through no fault of the run (see below), and a spare task beats a dead end.
- **Fail fast only on what cannot be repaired**, and say what would fix it.

## Things that look harmless and are not

- **Do not re-register the relay task on every run.** A task first created
  while ABR had granted admin carries a security descriptor an unelevated
  account cannot overwrite, so every later run from a plain SSH shell died on
  "Access is denied", while the existing task was perfectly good and would
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
  second**. Two conclusions in this repo's history (both "this primitive is
  broken") were wrong tests pressing the wrong button.
- **`Press-Button` considers only BUTTON-class controls.** A substring match
  over every control will happily find "OK" inside a label and click nothing.
- **The in-session side ignores a `request.json` older than three minutes.**
  Without that, anything that starts the task (a person, a stale trigger)
  replays the last request and silently elevates.

## Encoding: pure ASCII, no BOM

Both scripts must stay **pure ASCII with no BOM**. This is not tidiness; it is
the only encoding that survives both ways they are run:

- As a file under **Windows PowerShell 5.1**, which the relay uses, a `.ps1`
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
- **Hardcode Windows PowerShell's absolute path**, not `$PSHOME`: under pwsh 7
  that points at `pwsh.exe`, which a downloaded copy cannot assume exists.
- **`$MyInvocation.MyCommand.ScriptBlock` describes the CALLER under `iex`.**
  It returned a few hundred bytes of the invoking wrapper, which got written
  out as `Heis.ps1` and run by the relay. Symptom: a silent 75-second timeout.
  Hence the marker check in `Resolve-SelfPath`.
- **Splat a hashtable, not an array.** Array splatting passes *positionally*:
  `@('-Verify')` bound the string to `-Exe` and ran the default action against
  a nonsense path. It looked like it worked, because the exe lookup healed past
  the bad value. Self-healing hides bugs as well as it hides faults.
- **`[WindowsPrincipal]::IsInRole` is a snapshot.** A process token carries the
  group membership it was born with, so a shell started before elevation
  answers "not admin" for the rest of its life. Use live group membership, and
  prefer a function over a variable so it cannot go stale.
- **`$PROFILE` may be a OneDrive placeholder.** With Documents redirected,
  `Get-Item` reports `Length 0` and a stale `LastWriteTime` for a dehydrated
  file. The profile read as 0 bytes while holding 2257 bytes of content, which
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
- **`exit` under `iex` or a script block closes the user's shell.** Verified:
  `irm … | iex` and `& ([scriptblock]::Create(…))` both take the whole host
  down on `exit 1`, SSH session included. So a failed install used to close the
  terminal it was reporting into. Every `exit` is guarded by `$PSCommandPath`,
  which is set only for a file run, even when iex runs inside another script.
  Install.ps1 also runs its body in `& { }`, because under iex its top level
  is the caller's scope and `$ErrorActionPreference = 'Stop'` stayed behind.
- **`irm Heis.ps1 | iex` re-runs itself in a child scope.** Under iex the text
  runs in the caller's scope, so `$ErrorActionPreference = 'Stop'` would stay
  behind in their shell. The guard at the top of Heis.ps1 spots iex (no
  `$PSCommandPath`, and its own text is not in `$MyInvocation`). It then
  fetches the script once more and invokes that as a script block.
- **Native stderr is fatal in Windows PowerShell 5.1 under `Stop`.** A
  redirected stderr line (`2>$null`, `2>&1`) becomes an ErrorRecord and throws.
  So `schtasks /query` on a task that does not exist yet, which is every first
  run, ended the script instead of answering "missing". pwsh 7.2+ does not do
  this, which is how it hid: the SSH side ran pwsh. But `heis.cmd` and a stock
  install run 5.1. Every native call goes through `Invoke-Native`.
- **Profiles come in several encodings.** UTF-8 with a BOM, UTF-16, or BOM-less
  ANSI that Windows PowerShell reads as the ANSI code page.
  `Set-ProfileBlock` writes the file back in whatever encoding it found.
  Writing ANSI Norwegian letters back as UTF-8 corrupts them for 5.1.
- **`PositionalBinding = $false` is load-bearing.** With it on, any stray word
  binds to `-Exe`, `Resolve-AbrExe` heals past the bad path, and `heis statsu`
  elevates. Once `heis` is on the PATH, typos are routine.
- **Exit 0 explicitly on success.** Without it, `$LASTEXITCODE` is whatever
  native command ran last, and `query user` exits 1 from session 0 even when
  it works. The installer and `heis.cmd` both read the code.
- **PowerShell prefers `Heis.ps1` over `heis.cmd` in the same folder.** That is
  wanted, because it gives objects instead of text. But it means typing `heis`
  in PowerShell is subject to execution policy. `heis.cmd` passes
  `-ExecutionPolicy Bypass` and serves everything else, including an SSH login
  that lands in cmd.exe.
- **Edit the user PATH in the registry, not with
  `[Environment]::SetEnvironmentVariable`.** That API reads the value expanded
  and writes REG_SZ, which hardcodes the `%USERPROFILE%\…\WindowsApps` entry
  Windows ships. Read with `DoNotExpandEnvironmentNames` and keep the value kind.
- **`WM_SETTINGCHANGE` from session 0 never reaches the desktop.** After an
  install over SSH, new SSH sessions see the PATH, but desktop terminals do not
  until the user signs out and in. Say so; do not pretend it is instant.
- **Judge execution policy without the Process scope.** `powershell
  -ExecutionPolicy Bypass -Command "irm … | iex"` reports Bypass, but the
  shells the user opens later will not get it. The installer and `-Doctor`
  both skip the Process scope. Windows PowerShell and pwsh keep separate
  policies and separate profiles.
- **With no scope set, a Windows client is `Restricted` for pwsh too.** It is
  a client/server distinction, not Desktop/Core; pwsh just usually ships a
  LocalMachine `RemoteSigned` in its own config. Read `ProductType` from the
  registry.
- **The Process-scope policy outlives a child scope.** It belongs to the
  process, so under `irm | iex` a Bypass the installer sets would stay in the
  user's shell. The installer restores it in `finally`.
- **`powershell -File` cannot pass a `[bool]`.** `heis.cmd` hands over the
  text `$false`, which a `[bool]` parameter rejects. So `-AutoElevateOnLogin`
  is a string, parsed for `$false`/`false`/`0`/`no`/`nei`.
- **Start ABR with its own working directory.** It inherited the relay's,
  `%LOCALAPPDATA%\Heis`, and its long-lived process kept that folder open for
  the whole session, so `-Uninstall` could not delete it. Found with
  `handle.exe` against the live box.
- **The logon block must stay quiet in non-interactive shells.** Windows sshd
  starts the DefaultShell for `ssh host <cmd>` and for scp's SFTP subsystem
  too. One status line in there and scp dies with `Received message too
  long 1094865440`, which is "ABR " read as a length. The template checks
  `SSH_ORIGINAL_COMMAND` and `-c`/`-Command`/`-EncodedCommand`/`-File`.
- **Never rewrite an existing logon block from the template.** People edit
  them. The owner's block had its own quiet guard, an Entra-SID check and a
  token-vs-group colour fix, and an upgrade that replaced it wholesale broke
  scp. `Update-ProfileBlock` edits only the `$HEIS_PATH` and
  `$HEIS_AUTO_ELEVATE` lines, in place, indented or not, and adds the elevate
  line if a hand edit dropped it. A fresh template means
  `-AddToProfile:$false` first.
- **Refuse to edit a profile whose markers do not pair up.** The block regex
  is non-greedy from a begin to the next end. With one end marker missing, it
  runs on to the next block's end and deletes the user's code in between.
  `Set-ProfileBlock` counts and checks nesting first, and throws instead.
- **5.1's `-File` cannot pass `:$false` to a switch either.** pwsh 7 can. So
  `heis.cmd -AddToPath:$false` fails on parameter binding. It never elevates,
  but cmd users cannot remove settings that way.
- **A setting passed as `:$false` removes it.** `-AddToPath:$false` and
  `-AddToProfile:$false` take out what an earlier install set up. The
  installer always passes both, so answering "no" on an upgrade sticks rather
  than being revived by `-Doctor`. Decide "settings call or elevate" from
  `$PSBoundParameters`, never from the switches' values.
- **The default install folder is `%LOCALAPPDATA%\Programs\Heis`, not `$PWD`.**
  `$PWD` was chosen so the file landed somewhere visible. But over SSH that is
  the home folder, and putting the home folder on the PATH makes every file in
  it a command. The PATH now handles discoverability, so the file can live in a
  folder of its own. `-Uninstall` removes that folder whole, and only that one.
- **GitHub's raw CDN caches for about five minutes.** A push then a fetch will
  serve the old file, including to a cache-buster. Twice this looked like a fix
  not working.

## Environment this was built on

A Windows 365 Cloud PC, and some of it is specific to that:

- The user is **not a local administrator**, so `tscon`, `Get-ScheduledTask`,
  `Get-CimInstance`, `Get-WinEvent` and `Win32_Process` all fail from SSH. Use
  `schtasks` and registry reads; they work unprivileged.
- **Windows Script Host is policy-blocked**: a `.vbs` opens a *Windows Script
  Host Settings* dialog instead of running. Do not build test fixtures on it.
- RDP resolution and DPI change under a running process as the client window is
  resized or moved between displays. Never cache geometry.
- `tscon`-ing a disconnected session onto the console was tried and removed. It
  exists to make `SendInput` work unattended, which message-based automation
  makes unnecessary. And the task fired on reconnect too, pulling the session
  back and locking the machine out of RDP entirely.

## Testing

There is no test suite; drive it.

```powershell
.\Heis.ps1 -Status          # cheapest round-trip through the relay
.\Heis.ps1 -Doctor          # every check; from SSH, the relay round-trip too
.\Heis.ps1 -Verify          # non-destructive if a session is already running
```

Off Windows, pwsh can still catch most of what breaks the one-liner. Parse
both files and reject 7-only syntax by walking the AST for
`TernaryExpressionAst`, `PipelineChainAst` and the null-coalescing operators.
Run each file through `| iex` and through a script block, and check that the
calling shell survives a failure. The profile-block helpers can be lifted out
by AST and round-tripped against a temp file.

`DOCS.md` names exact error messages in its troubleshooting table. When you
change a `throw`, change the table with it.

Prompts are skipped when stdin is redirected, so `Install.ps1` is safe to run
from automation; it takes the defaults. Use `-Yes` to be explicit.

Before claiming an elevation change works, check what state the session is
actually in first. Most "it did nothing" reports are the session, not the code.

## Style

Comments explain **why**, especially where the code looks like it could be
simpler. Most of the odd-looking choices here are on purpose and annotated
with the failure that motivated them. Keep that. PowerShell must parse under
Windows PowerShell 5.1: no ternaries, and no `if`-expressions in hashtable
values.
