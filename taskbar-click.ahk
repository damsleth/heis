#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"

; Pin DPI awareness before anything reads a coordinate. See PinDpiAwareness.
DPI_MODE := PinDpiAwareness()

; Taskbar automation agent.
;
; Runs resident in an interactive session and executes commands dropped into
; its own queue by Send-AhkCommand.ps1, so an SSH shell (which has no input
; desktop of its own) can drive the mouse and keyboard of a logged-on session.
;
; Multiple users can be logged on at once (fast user switching, or one on the
; console and one over RDP). Each agent therefore owns a PRIVATE queue keyed by
; session id, and advertises itself in .\agents\<session>.json so the client can
; discover it and address a specific session instead of racing for commands.
;
;   .\agents\<session>.json      heartbeat: who and where this agent is
;   .\queue\<session>\*.cmd      requests for this agent only
;   .\queue\<session>\*.done     replies
;   .\logs\agent-s<session>.log  per-session log, no interleaving
;
; Hotkeys:  F8 preview target   F9 click it   F10 inspect cursor
;           F12 reload          Ctrl+Alt+Q exit

ICON_INDEX   := 1                     ; 1 = icon immediately right of Start
SESSION      := SessionId()
QUEUE_DIR    := A_ScriptDir "\queue\" SESSION
AGENT_DIR    := A_ScriptDir "\agents"
HEARTBEAT    := AGENT_DIR "\" SESSION ".json"
LOG_FILE     := A_ScriptDir "\logs\agent-s" SESSION ".log"
POLL_MS      := 200
HEARTBEAT_MS := 5000                  ; clients treat >30s as dead

; Session 0 is the non-interactive services session. It has no display and no
; input queue that reaches any desktop, so an agent there can never click
; anything. Refuse to start rather than sit there looking healthy: a phantom
; entry in .\agents is worse than nothing, because it makes every client call
; ambiguous and forces a -Session flag that should not be needed.
;
; This deliberately tests the SESSION, not the input desktop. A session that is
; merely locked or disconnected - RDP client closed, fast-user-switched away -
; also reports no input desktop, but it is a real session whose desktop returns
; on reconnect, and the agent must stay alive across that.
;
; Reported on stdout, never MsgBox: the way you hit this is launching the script
; over SSH, where a modal dialog would block forever with nobody to dismiss it.
if SESSION = 0 {
    FileAppend(
        "taskbar-click.ahk: refusing to start in session 0, the non-interactive`n"
      . "services session. Input sent from here reaches no desktop.`n`n"
      . "Start the agent inside the interactive session instead, then drive it`n"
      . "from here:    .\Send-AhkCommand.ps1 -Session <id> <command>`n"
      . "Live agents:  .\Send-AhkCommand.ps1 -List`n", "*")
    ExitApp 2
}

for dir in [QUEUE_DIR, AGENT_DIR, A_ScriptDir "\logs"]
    if !DirExist(dir)
        DirCreate dir

; A previous run may have died holding queued work. Commands are not replayed:
; a stale request is almost never still wanted, and re-running input blind is
; worse than dropping it.
stale := 0
Loop Files, QUEUE_DIR "\*.*"
    if A_LoopFileExt ~= "^(cmd|done|tmp)$"
        stale++, FileDelete(A_LoopFileFullPath)

A_IconTip := "AHK taskbar agent (session " SESSION ")"
WriteHeartbeat()
Log(Format("agent started - pid {}, session {}, user {}, desktop {}, dpi {} ({}), dropped {} stale file(s)",
    ProcessExist(), SESSION, FullUserName(), InputDesktopName(), SystemDpi(), DPI_MODE, stale))

SetTimer PollQueue, POLL_MS
SetTimer WriteHeartbeat, HEARTBEAT_MS
OnExit ExitHandler

ExitHandler(reason, code) {
    global HEARTBEAT
    Log("agent stopping (" reason ")")
    try FileDelete HEARTBEAT           ; stop advertising immediately
}

; ---------------------------------------------------------------- geometry ---

; Screen-coordinate center of the Nth taskbar icon. Geometry is read live, so
; this survives taskbar moves, left/center alignment, icon-size changes and
; per-user display-scaling differences between sessions.
TaskbarIconPos(n) {
    tray := WinExist("ahk_class Shell_TrayWnd")
    if !tray
        throw Error("Taskbar (Shell_TrayWnd) not found")

    WinGetPos(&tx, &ty, &tw, &th, tray)
    ; MSTaskListWClass is the icon strip; its left edge is where icons begin.
    ControlGetPos(&lx, &ly, &lw, &lh, "MSTaskListWClass1", tray)

    ; Scale by the DPI of the monitor the taskbar is actually on, not the
    ; system-wide value: under Per-Monitor v2 those differ whenever the taskbar
    ; sits on a secondary monitor with its own scaling.
    dpi   := WindowDpi(tray)
    pitch := 44 * (dpi / 96)           ; 44 device-independent px per icon slot
    return {
        x: tx + lx + pitch * (n - 0.5),
        y: ty + ly + lh / 2,
        pitch: pitch,
        dpi: dpi,
        tray: Format("{}, {} {}x{}", tx, ty, tw, th),
        list: Format("+{}, +{} {}x{}", lx, ly, lw, lh)
    }
}

; --------------------------------------------------------------- heartbeat ---

WriteHeartbeat() {
    global HEARTBEAT, QUEUE_DIR, SESSION, DPI_MODE
    q := Chr(34)
    body := "{"
        . q "session" q ":" SESSION ","
        . q "user"    q ":" q JsonEscape(FullUserName())     q ","
        . q "pid"     q ":" ProcessExist() ","
        . q "desktop" q ":" q JsonEscape(InputDesktopName()) q ","
        . q "ready"   q ":" (InputUsable() ? "true" : "false") ","
        . q "console" q ":" (IsConsoleSession() ? "true" : "false") ","
        . q "screen"  q ":" q A_ScreenWidth "x" A_ScreenHeight q ","
        . q "dpi"     q ":" SystemDpi() ","
        . q "dpimode" q ":" q JsonEscape(DPI_MODE)           q ","
        . q "queue"   q ":" q JsonEscape(QUEUE_DIR)          q ","
        . q "unix"    q ":" EpochSeconds()
        . "}"
    AtomicWrite(HEARTBEAT, body)
}

; Write then rename, so a client polling the file can never read it half-built.
AtomicWrite(path, text) {
    tmp := path ".tmp"
    try {
        if FileExist(tmp)
            FileDelete tmp
        FileAppend text, tmp, "UTF-8-RAW"
        FileMove tmp, path, true
    }
}

JsonEscape(s) => StrReplace(StrReplace(s, "\", "\\"), Chr(34), "\" Chr(34))

EpochSeconds() => DateDiff(A_NowUTC, "19700101000000", "Seconds")

; ------------------------------------------------------------ command queue ---

PollQueue() {
    static busy := false               ; a command can outlast one timer tick
    global QUEUE_DIR

    if busy
        return
    busy := true
    try {
        names := ""
        Loop Files, QUEUE_DIR "\*.cmd"
            names .= A_LoopFileName "`n"
        if names != "" {
            for name in StrSplit(Sort(RTrim(names, "`n")), "`n")
                RunQueuedCommand(name)
        }
    }
    busy := false
}

RunQueuedCommand(name) {
    global QUEUE_DIR
    path := QUEUE_DIR "\" name
    id   := RegExReplace(name, "\.cmd$")

    cmd := ""
    try cmd := Trim(FileRead(path, "UTF-8"), " `t`r`n")
    try FileDelete path                ; consume before acting, never replay

    ok := 1, result := ""
    try
        result := Execute(cmd)
    catch as e
        ok := 0, result := e.Message

    Log(Format("{} [{}] {} -> {}", id, ok ? "ok" : "ERR", cmd, result))
    WriteDone(id, ok, cmd, result)
}

Execute(cmd) {
    global ICON_INDEX, SESSION, DPI_MODE
    parts := StrSplit(cmd, " ", " `t", 2)
    verb  := StrLower(parts.Has(1) ? parts[1] : "")
    arg   := parts.Has(2) ? Trim(parts[2]) : ""

    ; Synthetic input goes nowhere while the session is locked or disconnected,
    ; and SendInput reports no error when that happens. Fail the command instead:
    ; a no-op that answers "ok" is precisely what makes this hard to diagnose.
    ; Verbs that only read state or post window messages are left alone.
    if verb ~= "^(click-icon|preview-icon|send)$" && !InputUsable()
        throw Error(Format("session {} cannot receive synthetic input right now "
            . "(desktop {}, console {}). Foreground: {}. "
            . "If that window is elevated, UIPI is blocking injection and focusing "
            . "anything unelevated fixes it; otherwise the session is locked or "
            . "disconnected and needs an RDP client.",
            SESSION, InputDesktopName(), IsConsoleSession() ? "yes" : "no",
            ActiveWindowInfo()))

    switch verb {
        case "ping":
            return "pong"

        case "status":
            p := TaskbarIconPos(1)
            return Format("session={} ({}) user={} desktop={} screen={}x{} dpi={}/{} ({}) pitch={} tray=[{}] list=[{}] icon1={},{}",
                SESSION, IsConsoleSession() ? "console" : "remote", FullUserName(),
                InputDesktopName(), A_ScreenWidth, A_ScreenHeight,
                p.dpi, SystemDpi(), DPI_MODE, p.pitch, p.tray, p.list, Round(p.x), Round(p.y))

        case "click-icon":
            n := arg = "" ? ICON_INDEX : Integer(arg)
            p := TaskbarIconPos(n)
            Click p.x, p.y
            return Format("clicked icon #{} at {},{}", n, Round(p.x), Round(p.y))

        case "preview-icon":
            n := arg = "" ? ICON_INDEX : Integer(arg)
            p := TaskbarIconPos(n)
            MouseMove p.x, p.y, 2
            return Format("moved to icon #{} at {},{} (no click)", n, Round(p.x), Round(p.y))

        case "send":
            if arg = ""
                throw Error("send requires keys, for example: send ^s")
            Send arg
            return "sent: " arg

        case "activate":
            if arg = ""
                throw Error("activate requires a window title, for example: activate ahk_exe notepad.exe")
            if !WinExist(arg)
                throw Error("no window matching: " arg)
            WinActivate
            return "activated: " WinGetTitle("A")

        ; ---- message-based automation ------------------------------------
        ; These post messages to a window instead of injecting input, so they
        ; need no input desktop and keep working while the session is locked,
        ; disconnected or parked on a console that eats input. They are
        ; deliberately NOT gated on InputUsable.
        ;
        ; They must still run in the agent's own session: window handles do not
        ; cross a session boundary, which is why this cannot be done from SSH
        ; directly however persistent that connection is.

        case "run":
            if arg = ""
                throw Error("run requires a command, for example: run notepad.exe")
            Run arg, , , &pid
            return Format("started '{}' as pid {}", arg, pid)

        case "windows":
            DetectHiddenWindows arg = "hidden"     ; `windows hidden` includes them
            out := "", n := 0
            for hwnd in WinGetList() {
                try {
                    t := WinGetTitle(hwnd), c := WinGetClass(hwnd)
                } catch
                    continue
                if t = "" && arg != "hidden"
                    continue
                out .= Format("{} [{}] {}`n", hwnd, c, t)
                if ++n >= 40 {
                    out .= "... truncated`n"
                    break
                }
            }
            return "`n" RTrim(out, "`n")

        case "wait-window":                        ; win | seconds (default 10)
            p := StrSplit(arg, "|", " `t")
            if p.Length < 1 || p[1] = ""
                throw Error("wait-window requires: <window> [| <seconds>]")
            secs := (p.Length >= 2 && p[2] != "") ? Number(p[2]) : 10
            ; Hidden windows deliberately excluded: a dialog worth waiting for
            ; is one that has actually appeared.
            DetectHiddenWindows false
            if !WinWait(p[1], , secs)
                throw Error(Format("timed out after {}s waiting for: {}", secs, p[1]))
            return Format("appeared: [{}] {}", WinGetClass(p[1]), WinGetTitle(p[1]))

        ; Press a button by the caption a person reads off the screen.
        ;
        ; Use this in preference to control-press. ClassNN ordering is an
        ; artefact of creation order and is not guessable or stable: in
        ; Character Map, Button3 is "Advanced view" while Button4 is "Reset".
        ; A caption is what the dialog actually says, and it survives the
        ; control moving, the window resizing and the display changing DPI -
        ; none of which a coordinate survives.
        case "press-text":                         ; win | button caption
            p := SplitArgs(arg, 2, "press-text requires: <window> | <button caption>")
            DetectHiddenWindows true
            if !WinExist(p[1])
                throw Error("no window matching: " p[1])
            ctl := FindControlByText(p[1], p[2])
            PostMessage 0x00F5, 0, 0, ctl, p[1]    ; BM_CLICK
            return Format("pressed '{}' via {} in [{}] {}",
                p[2], ctl, WinGetClass(p[1]), WinGetTitle(p[1]))

        ; What can actually be pressed, and what it says. Run this first against
        ; any new dialog: an empty list means the app draws its own controls
        ; (WinUI, Electron, Chromium) and none of this will reach it.
        case "buttons":                            ; win
            if arg = ""
                throw Error("buttons requires a window")
            DetectHiddenWindows true
            if !WinExist(arg)
                throw Error("no window matching: " arg)
            out := ""
            for ctl in WinGetControls(arg) {
                t := ""
                try t := ControlGetText(ctl, arg)
                out .= Format("{}{}`n", ctl, t != "" ? "  = " t : "")
            }
            return "`n" (out = "" ? "(no addressable controls)" : RTrim(out, "`n"))

        case "win-pos":                            ; win
            if arg = ""
                throw Error("win-pos requires a window")
            DetectHiddenWindows true
            if !WinExist(arg)
                throw Error("no window matching: " arg)
            WinGetPos(&wx, &wy, &ww, &wh, arg)
            return Format("{},{} {}x{}", wx, wy, ww, wh)

        case "control-list":                       ; win
            if arg = ""
                throw Error("control-list requires a window, for example: control-list ahk_class Notepad")
            DetectHiddenWindows true
            if !WinExist(arg)
                throw Error("no window matching: " arg)
            out := ""
            for ctl in WinGetControls(arg)
                out .= ctl "`n"
            return "`n" RTrim(out, "`n")

        case "control-click":                      ; win | control
            p := SplitArgs(arg, 2, "control-click requires: <window> | <control>")
            DetectHiddenWindows true
            ControlClick p[2], p[1]
            return Format("clicked control '{}' in '{}'", p[2], p[1])

        ; BM_CLICK asks a button to activate itself, one message, no coordinates
        ; and no hit-testing. control-click works headless too - both were
        ; verified toggling a checkbox with the input desktop dead - but this
        ; one cannot be thrown off by a control that has moved, is partly
        ; offscreen, or sits under another window, so it is the better default
        ; for buttons. Buttons only: anything else ignores BM_CLICK.
        case "control-press":                      ; win | control
            p := SplitArgs(arg, 2, "control-press requires: <window> | <control>")
            DetectHiddenWindows true
            PostMessage 0x00F5, 0, 0, p[2], p[1]   ; BM_CLICK
            return Format("pressed control '{}' in '{}'", p[2], p[1])

        case "control-send":                       ; win | control | keys
            p := SplitArgs(arg, 3, "control-send requires: <window> | <control> | <keys>")
            DetectHiddenWindows true
            ControlSend p[3], p[2], p[1]
            return Format("sent '{}' to control '{}'", p[3], p[2])

        ; Prefer this over control-send for text. ControlSend synthesises
        ; keystrokes, so it still depends on modifier state and on the control
        ; keeping up: headless it mangles case and drops characters
        ; ("HEADLESS-OK" arrived as "hEAD"). ControlSetText is a single
        ; WM_SETTEXT and is exact.
        case "control-settext":                    ; win | control | text
            p := SplitArgs(arg, 3, "control-settext requires: <window> | <control> | <text>")
            DetectHiddenWindows true
            ControlSetText p[3], p[2], p[1]
            return Format("set control '{}' to '{}'", p[2], p[3])

        case "control-text":                       ; win | control
            p := SplitArgs(arg, 2, "control-text requires: <window> | <control>")
            DetectHiddenWindows true
            return "[" ControlGetText(p[2], p[1]) "]"

        case "probe-input":
            InputUsable(true)              ; force, so this reports live truth
            pr := InputProbe()
            return Format("sendinput={} landed={} cursor {} -> {} desktop={} console={}",
                pr.sent, pr.landed ? "yes" : "NO", pr.from, pr.to,
                InputDesktopName(), IsConsoleSession() ? "yes" : "no")

        ; The foreground window decides whether synthetic input is allowed at
        ; all. UIPI blocks a medium-integrity process from injecting input while
        ; an elevated window has focus - SendInput still returns success and the
        ; input is discarded, which is indistinguishable from a dead desktop
        ; unless you look at what is in front.
        case "active-window":
            return ActiveWindowInfo()

        case "mouse-pos":
            MouseGetPos &mx, &my, &win
            return Format("{},{} over {}", mx, my, win ? WinGetClass(win) : "(none)")

        case "reload":
            SetTimer () => Reload(), -250      ; answer first, then restart
            return "reloading"

        case "exit":
            SetTimer () => ExitApp(), -250
            return "exiting"
    }
    throw Error("unknown command: " cmd)
}

; Is the given process running elevated (high or system integrity)?
;
; Matters because UIPI silently refuses input injection from a lower integrity
; level to a higher one. A non-elevated agent cannot drive an elevated window,
; and gets no error saying so - the only symptom is that nothing happens.
; Returns "unknown" rather than false when the token cannot be read, because
; being refused is itself evidence the target outranks us - reporting that as
; "not elevated" points the investigation in exactly the wrong direction, which
; it did once already.
IsProcessElevated(pid) {
    static TOKEN_QUERY := 0x0008, TokenElevation := 20
    ; PROCESS_QUERY_LIMITED_INFORMATION (0x1000), not QUERY_INFORMATION
    ; (0x0400): the latter is refused across an integrity boundary, so it fails
    ; on precisely the elevated processes worth identifying.
    h := DllCall("kernel32\OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")
    if !h
        return "unknown"
    elevated := "unknown"
    if DllCall("advapi32\OpenProcessToken", "Ptr", h, "UInt", TOKEN_QUERY, "Ptr*", &tok := 0) {
        if DllCall("advapi32\GetTokenInformation", "Ptr", tok, "Int", TokenElevation,
                   "UInt*", &val := 0, "UInt", 4, "UInt*", &len := 0)
            elevated := val != 0 ? "YES" : "no"
        DllCall("kernel32\CloseHandle", "Ptr", tok)
    }
    DllCall("kernel32\CloseHandle", "Ptr", h)
    return elevated
}

; One line describing the foreground window, for diagnostics and for the error
; a refused input command raises. What is in front decides whether input is
; permitted at all, so it belongs in any report of input not working.
ActiveWindowInfo() {
    hwnd := WinExist("A")
    if !hwnd
        return "(no foreground window)"
    pid := WinGetPID(hwnd)
    exe := ""
    try exe := WinGetProcessName(hwnd)
    return Format("[{}] {} (pid {}, {}) elevated={}",
        WinGetClass(hwnd), WinGetTitle(hwnd), pid, exe, IsProcessElevated(pid))
}

; Locate a control by the caption it displays. Exact match wins outright;
; otherwise the first substring match is taken, so "OK" finds "&OK" and "Yes"
; finds "&Yes" without the caller worrying about accelerator ampersands.
FindControlByText(win, text) {
    want     := StrLower(StrReplace(text, "&"))
    fallback := ""

    for ctl in WinGetControls(win) {
        t := ""
        try t := ControlGetText(ctl, win)
        if t = ""
            continue
        got := StrLower(StrReplace(t, "&"))
        if got = want
            return ctl
        if fallback = "" && InStr(got, want)
            fallback := ctl                ; remember, but keep hunting for exact
    }

    if fallback != ""
        return fallback
    throw Error(Format("no control captioned '{}' in '{}'", text, win))
}

; Split a "a | b | c" argument into exactly n trimmed parts, or explain what was
; wanted. Pipe rather than space: window specs and key sequences both contain
; spaces, so there is no whitespace split that does not eventually misread one.
SplitArgs(arg, n, usage) {
    parts := StrSplit(arg, "|", " `t")
    if parts.Length != n
        throw Error(usage . Format(" (got {} part{})", parts.Length, parts.Length = 1 ? "" : "s"))
    for p in parts
        if p = ""
            throw Error(usage . " (a part was empty)")
    return parts
}

WriteDone(id, ok, cmd, result) {
    global QUEUE_DIR, SESSION
    AtomicWrite(QUEUE_DIR "\" id ".done",
        Format("ok: {}`ncommand: {}`nsession: {}`nuser: {}`ndesktop: {}`nresult: {}`n",
            ok, cmd, SESSION, FullUserName(), InputDesktopName(), result))
}

Log(text) {
    global LOG_FILE
    try FileAppend FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " text "`n", LOG_FILE, "UTF-8"
}

; ------------------------------------------------------------- diagnostics ---

SessionId() {
    DllCall("kernel32\ProcessIdToSessionId", "UInt", DllCall("kernel32\GetCurrentProcessId", "UInt"),
        "UInt*", &sid := 0)
    return sid
}

; Session currently attached to the physical console, or 0xFFFFFFFF when none is.
; Worth asking live rather than assuming session 1: `tscon <id> /dest:console`
; reassigns the console to an existing session, so which one it is can change
; underneath a running agent.
ConsoleSessionId() => DllCall("kernel32\WTSGetActiveConsoleSessionId", "UInt")

; Declared global rather than fat-arrow: an expression function cannot carry a
; `global` declaration, and assume-local would read an empty SESSION.
IsConsoleSession() {
    global SESSION
    return SESSION = ConsoleSessionId()
}

; Pin DPI awareness so a coordinate means the same thing in every agent, however
; that agent was started. Left unpinned, awareness is inherited from whatever
; launched the process: the same desktop was reported as 3440x2656 @192 by an
; agent started from Task Scheduler and as 1720x1378 @96 by one restarted with
; `reload` - physical pixels versus pixels Windows had virtualised down for a
; DPI-unaware process. Clicks still landed, because pitch scales with the same
; DPI, but two logs of the same machine could not be compared.
;
; Per-Monitor v2 is the mode worth pinning to: coordinates are true physical
; pixels and each monitor reports its own scaling, which is what the taskbar
; geometry probe needs on a mixed-DPI setup.
;
; Must run before any window exists, hence the call at the top of the file.
PinDpiAwareness() {
    PMV2 := -4                         ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2

    ; Process-level first. Stock AutoHotkey64.exe ships manifested as system-DPI
    ; aware, and a manifest cannot be overridden at runtime, so this call is
    ; expected to fail here - it is kept for a host exe built without that
    ; manifest. Its failure is not worth reporting; the probe below tells the
    ; truth either way.
    DllCall("user32\SetProcessDpiAwarenessContext", "Ptr", PMV2, "Int")

    ; Thread-level is NOT bound by the manifest, and the script (timers and
    ; hotkeys included) runs on one thread, so this is what actually buys
    ; per-monitor behaviour. It matters beyond multi-monitor: a system-aware
    ; process caches the DPI it started with, so when an RDP client is resized
    ; and the session changes resolution underneath it, its geometry silently
    ; goes stale until restarted. Per-monitor v2 re-reads it every call.
    DllCall("user32\SetThreadDpiAwarenessContext", "Ptr", PMV2, "Ptr")

    ctx := DllCall("user32\GetThreadDpiAwarenessContext", "Ptr")
    ; DPI_AWARENESS has only three values; v2 is a context, not an awareness
    ; level, so a successful v2 pin reports here as plain "per-monitor".
    switch DllCall("user32\GetAwarenessFromDpiAwarenessContext", "Ptr", ctx, "Int") {
        case 0:  return "unaware"
        case 1:  return "system"
        case 2:  return "per-monitor"
        case -1: return "invalid"
    }
    return "unknown"
}

; DPI of the monitor a given window is on. Under Per-Monitor v2 this is the only
; honest source for scaling: A_ScreenDPI is the system-wide value and is simply
; wrong for a taskbar on a secondary monitor with different scaling.
WindowDpi(hwnd) {
    dpi := DllCall("user32\GetDpiForWindow", "Ptr", hwnd, "UInt")
    return dpi ? dpi : SystemDpi()
}

; A_ScreenDPI is captured once at process start and never updated, so a
; long-lived agent keeps reporting the scaling it was born with. Observed
; directly: an agent started at 96 went on reporting 96 after the RDP session
; moved to a 192 display, while GetDpiForWindow correctly said 192. Only the
; geometry maths escaped, because it asks per-window; anything that reported
; A_ScreenDPI was lying. Ask the system live instead.
SystemDpi() {
    dpi := DllCall("user32\GetDpiForSystem", "UInt")
    return dpi ? dpi : A_ScreenDPI     ; pre-1607 has no live call to make
}

FullUserName() {
    domain := EnvGet("USERDOMAIN")
    return domain ? domain "\" A_UserName : A_UserName
}

; Name of the desktop currently receiving input in this session, or "" when
; this session owns no input desktop at all - locked, disconnected, or another
; session is in front.
InputDesktopRaw() {
    h := DllCall("user32\OpenInputDesktop", "UInt", 0, "Int", 0, "UInt", 0x0001, "Ptr")
    if !h
        return ""
    buf := Buffer(512, 0)
    ok  := DllCall("user32\GetUserObjectInformationW", "Ptr", h, "Int", 2,
        "Ptr", buf, "UInt", buf.Size, "UInt*", &len := 0)
    DllCall("user32\CloseDesktop", "Ptr", h)
    return ok ? StrGet(buf, "UTF-16") : ""
}

; Display form, for heartbeats, logs and replies.
InputDesktopName() {
    d := InputDesktopRaw()
    return d = "" ? "(unavailable - locked, disconnected, or not the input session)" : d
}

; "Default" is the ordinary desktop. "Winlogon" is the secure desktop behind the
; lock screen. Only the former accepts synthetic input; on the others SendInput
; is accepted and then silently dropped.
DesktopAvailable() => InputDesktopRaw() = "Default"

; Whether synthetic input actually reaches anything, asked by experiment.
;
; A usable input desktop turns out not to imply a usable input path. On a
; Windows 365 Cloud PC a session reattached to the console reports session
; state Active, desktop "Default", and accepts Send and Click without error -
; and nothing moves. Name-based checks cannot see that; only a probe can.
;
; Returns an object with both signals:
;   sent    SendInput's own return, the number of events it actually inserted.
;           0 means the injection was refused outright.
;   landed  whether the cursor could be observed to move. The stronger signal:
;           it catches input that is accepted and then discarded.
;
; The cursor is nudged 4px and put back, so this is close to invisible even if
; someone is watching, but it is still a real mouse move - keep it on demand
; rather than on the heartbeat timer.
; DesktopAvailable answers "is there a desktop", InputProbe answers "does input
; work" - this caches the second so it can be asked as cheaply as the first.
;
; Re-probed only when the session's topology changes, because that is the only
; thing the failure depends on: which desktop is in front, and whether the
; session is sitting on the console. Disconnecting, reattaching or reconnecting
; all move that key and force a fresh answer.
InputUsable(force := false) {
    static key := "", ok := false

    ; The foreground window's elevation is part of the key, because UIPI
    ; blocking depends on what is in front rather than on the desktop. Without
    ; it a probe taken behind an elevated window stays cached as "not usable"
    ; long after focus moved somewhere harmless, and every later command is
    ; refused for a reason that stopped being true.
    ;
    ; Keyed on elevation and not on the window or process, so switching between
    ; ordinary windows does not re-probe - a probe twitches the cursor, and
    ; doing that on every alt-tab would be its own bug.
    fg := ""
    try fg := IsProcessElevated(WinGetPID(WinExist("A")))

    k := InputDesktopRaw() "|" (IsConsoleSession() ? 1 : 0) "|" fg
    if (!force && k = key)
        return ok

    key := k
    ok := DesktopAvailable() && InputProbe().landed    ; no desktop, no probe
    return ok
}

InputProbe() {
    ; INPUT on x64: UINT type, 4 bytes padding, then MOUSEINPUT
    ; (dx, dy, mouseData, dwFlags, time, dwExtraInfo) = 40 bytes total.
    buf := Buffer(40, 0)
    NumPut("UInt", 0, buf, 0)              ; type = INPUT_MOUSE
    NumPut("Int",  0, buf, 8)              ; dx
    NumPut("Int",  0, buf, 12)             ; dy
    NumPut("UInt", 0x0001, buf, 20)        ; dwFlags = MOUSEEVENTF_MOVE, no-op
    sent := DllCall("user32\SendInput", "UInt", 1, "Ptr", buf, "Int", 40, "UInt")

    MouseGetPos &x0, &y0
    nudge := x0 > 8 ? -4 : 4               ; stay on screen at the left edge
    MouseMove x0 + nudge, y0, 0
    MouseGetPos &x1, &y1
    landed := (x1 != x0)
    if landed
        MouseMove x0, y0, 0                ; put it back only if it went anywhere

    return { sent: sent, landed: landed, from: x0 "," y0, to: x1 "," y1 }
}

; ----------------------------------------------------------------- hotkeys ---

F8:: {
    p := TaskbarIconPos(ICON_INDEX)
    MouseMove p.x, p.y, 2
    ToolTip Format("icon #{}: {}, {}`npitch {}  dpi {}`ntray {}`nlist {}",
        ICON_INDEX, Round(p.x), Round(p.y), p.pitch, A_ScreenDPI, p.tray, p.list)
    SetTimer () => ToolTip(), -4000
}

F9:: {
    p := TaskbarIconPos(ICON_INDEX)
    Click p.x, p.y
}

F10:: {
    MouseGetPos &mx, &my, &win, &ctl
    ToolTip Format("{}, {}`nwindow: {}`ncontrol: {}", mx, my, win ? WinGetClass(win) : "(none)", ctl)
    SetTimer () => ToolTip(), -4000
}

F12::Reload
^!q::ExitApp
