# Security

## If you do not know what this does, it is not for you

This automates a privilege-elevation prompt. That is a sentence worth reading
twice. It is a small, boring tool with an unglamorous job, but it touches the
part of a managed machine your security team cares most about, and running
software you have not read against that is a bad habit whatever the software.

The whole thing is one PowerShell file. Read it first.

## What it actually does

It starts `AdminByRequest.exe /Elevate` and clicks the buttons you would have
clicked — `Yes`, then `OK` — by posting `BM_CLICK` to those specific controls.
Then it checks that the countdown window appeared, so it can tell you whether
the elevator actually arrived rather than assuming it did.

That is the entire mechanism. There is no cleverness underneath it.

## What it does not do

- **It does not grant you anything.** Admin By Request decides whether you get
  elevation, on the same policy, with the same approval flow. If your policy
  requires a reason, or approval from someone else, that dialog is not one of
  the two this clicks and the run stops there.
- **It does not bypass, patch, or hook anything.** No driver, no injection, no
  token manipulation, no tampering with the ABR client.
- **It does not hide from auditing.** Every elevation is the same ABR request
  it would be if you clicked it yourself, logged the same way, with your name
  on it. Automating the click does not automate away the record.
- **It does not need administrator rights**, and never asks for them. The
  scheduled relay task runs as you, only when you are logged on.
- **It sends nothing anywhere.** No telemetry, no network calls except
  fetching the script itself when you ask it to.

## What it does change

**Auto-elevation on logon is a real change to your posture.** With
`-AutoElevateOnLogin $true`, every SSH login takes the elevator. You will hold
local administrator far more of the time than if you elevated deliberately,
which is exactly the thing just-in-time elevation exists to avoid. That may be
a fine trade for you. It is a trade.

Turn it off and keep the status line:

```powershell
.\Heis.ps1 -AddToProfile -AutoElevateOnLogin $false
```

**Your organisation may have opinions.** A tool that auto-confirms elevation
prompts is the kind of thing worth mentioning to whoever runs your endpoint
policy, before rather than after. It grants nothing, but "nothing was granted"
and "nobody was told" are different conversations.

**`irm … | iex` runs whatever the URL returns.** That is true of every
install-by-pipe one-liner, and it means `heis.d0.si` is a dependency you are
trusting. Read the file first if that bothers you — and it reasonably might:

```powershell
irm https://heis.d0.si/Heis.ps1 -OutFile Heis.ps1   # then read it
```

## Reporting

Open an issue: https://github.com/damsleth/heis/issues

This is a personal tool, licensed WTFPL, with no warranty and no support
commitment. If it breaks, you get to keep both pieces.
