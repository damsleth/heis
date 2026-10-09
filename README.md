<div align="center">

```
▐▄▄▌  ▐▄▄▌ ▐▄▄▄▄▄▄▄▌▐▄▄▄▄▄▄▄▄▌ ▐▄▄▄▄▄▄▄▌
▐██▌  ▐██▌▐██▌         ▐██▌   ▐██▌      
▐████████▌▐██████▌     ▐██▌    ▐██████▌ 
▐▀▀▌  ▐▀▀▌▐▀▀▌         ▐▀▀▌         ▐▀▀▌
▐▄▄▌  ▐▄▄▌ ▐▄▄▄▄▄▄▄▌▐▄▄▄▄▄▄▄▄▌▐▄▄▄▄▄▄▄▌ 
```

***[hæɪs]*** *(NOR): "to hoist", "lift", "elevator"*  
*Admin By Request elevation from unprivileged SSH*

```
irm https://heis.d0.si/install.ps1 | iex
```
</div>


## What it does

`heis` automates privilege elevation for users on corporate-managed Windows systems with Admin By Request installed and running.  
Read [SECURITY.md](SECURITY.md) before you run it. ***If you do not understand what this does, it is not for you.***

`heis` runs ABR with `/Elevate`, clicks through the dialogs and verifies the ABR-countdown started before reporting back.

| | |
| --- | --- |
| **zero dependencies** | Uses win32 `user32.dll` via PowerShell, no AutoHotkey, no agent to keep alive, nothing to clean up |
| **zero admin rights** | You do not need to be admin to ask to become one. That is kinda the whole point |
| **zero RDP needed** | Works with RDP disconnected and the screen dark. Dialogs are driven with window messages |
| **floor 0 to penthouse** | From a shell in Session 0 that cannot see the desktop, it takes itself up into the interactive session |

## Installation

One-liner in PowerShell from the Windows machine:

```powershell
irm https://heis.d0.si/install.ps1 | iex

# or with curl
curl.exe -fsSL https://heis.d0.si/install.ps1 | Out-String | iex
```

The installer is guided: it checks the machine, puts `heis` on your PATH, and
offers a real test at the end. Sane defaults.  
Then it's just
`heis`, in any terminal. Run the `irm` line again to update.

From cmd, over SSH, or with options: see [DOCS.md](DOCS.md#installing). Or
[skip installing](DOCS.md#without-installing) and run it straight off the URL.

## Parameters

| parameter | elevator goes |
| --- | --- |
| *(none)* | `heisen er oppe - 05:59:59 igjen` |
| `-Status`, while up | `heisen går allerede - 05:12:03 igjen` |
| `-Status`, while down | `ikke elevert` |
| `-Finish` | `heisen er nede` |

```powershell
heis                # elevate, unless you are already up
heis -Status        # which floor are we on
heis -Finish        # take it down, end the session
heis -Verify        # check the whole shaft works
heis -Doctor        # check the setup, repair what can be repaired
heis -Help          # this list
heis -Uninstall     # remove everything heis has set up
```

`Get-Help heis -Full` has all parameters and examples. An unknown argument is an error, not a reason to elevate:  
`heis statsu` will not take you anywhere.

Everything else, from the logon block and scripting to how it reaches the
desktop from SSH and troubleshooting, is in [DOCS.md](DOCS.md).

♪ ding ♪

<div align="center"><sub>

[heis.d0.si](https://heis.d0.si) · [WTFPL](LICENSE)

</sub></div>
