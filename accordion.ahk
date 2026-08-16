#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
;  accordion.ahk -- keyboard-driven accordion window manager (feasibility PoC)
;
;  Everything is fullscreen; one window visible per monitor; cycle the stack.
;  Disposable code. The findings are the deliverable. See FINDINGS.md.
;
;  EMERGENCY EXIT: Ctrl+Alt+Win+Q  (restores all system settings, exits)
;
;  Ctrl+Win+hjkl      -> cycle the current monitor's stack
;  Ctrl+Alt+Win+hjkl  -> focus the display in that direction
; ============================================================================

; ---------------------------------------------------------------------------
;  DIRECTIVES / PROCESS SETUP  (DPI first -- before any coordinate maths)
; ---------------------------------------------------------------------------
global DPI_PATH := "none"
try {
    ; -4 == DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    if DllCall("SetProcessDpiAwarenessContext", "ptr", -4, "int")
        DPI_PATH := "SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)"
}
if (DPI_PATH = "none") {
    try {
        ; shcore!SetProcessDpiAwareness(2 == PROCESS_PER_MONITOR_DPI_AWARE), returns HRESULT (0 == S_OK)
        if (DllCall("Shcore\SetProcessDpiAwareness", "int", 2, "int") = 0)
            DPI_PATH := "Shcore\SetProcessDpiAwareness(PER_MONITOR_DPI_AWARE)"
    }
}

DetectHiddenWindows(false)
SetWinDelay(0)
SetControlDelay(0)
SetTitleMatchMode(2)
CoordMode("Mouse", "Screen")
CoordMode("ToolTip", "Screen")

; ---------------------------------------------------------------------------
;  CONFIG  (everything you are likely to edit lives in this block)
; ---------------------------------------------------------------------------

; "maximize" (default) or "workarea"
global FULLSCREEN_MODE   := "maximize"

global POLL_INTERVAL_MS  := 400      ; window discovery poll period (safety net)
; React to window creation via SetWinEventHook instead of waiting for the next
; poll. The poll stays on as a backstop for anything the hooks miss.
global USE_WIN_EVENT_HOOK := true
global EVENT_DEBOUNCE_MS  := 40      ; settle time after an event before scanning
global MIN_WIN_W         := 200      ; smaller than this -> not managed
global MIN_WIN_H         := 200
global RECT_TOLERANCE    := 4        ; px slack before we touch a window again
global FOCUS_NEW_WINDOWS := true     ; activate newly detected managed windows
global AUTO_ELEVATE      := true     ; try to relaunch as admin (UIPI)
global MOUSE_TRK_TIMEOUT := 0        ; hover delay before focus follows (ms)
; Enable Windows' native X-mouse (focus_follows_mouse + autoraise) at startup.
; NOTE: this is a *system-wide* setting. It is captured and restored on exit,
; including on unhandled errors -- but NOT if the process is hard-killed
; (taskkill /F). See the README for how to switch it off by hand.
global X_MOUSE_ON_START := true
; where mouse_follows_focus parks the cursor:
;   "monitor" -- centre of the focused window's monitor work area, and only
;                when focus lands on a DIFFERENT monitor (default)
;   "window"  -- centre of the focused window, unless the cursor is already
;                inside it
global MOUSE_FOLLOW_TARGET := "monitor"
global LOG_FILE          := A_ScriptDir "\accordion.log"
global LOG_SKIPS         := true     ; log filter rejections (on change only)

global IGNORED_CLASSES := [
    "Progman",
    "WorkerW",
    "Shell_TrayWnd",
    "Shell_SecondaryTrayWnd",
    "Windows.UI.Core.CoreWindow",
    "TaskManagerWindow",
    "#32770",                                  ; standard dialog class -- see FINDINGS.md
    "Xaml_WindowedPopupClass",
    "TopLevelWindowForOverflowXamlIsland",
    "ForegroundStaging",
    "MultitaskingViewFrame",
    "AutoHotkeyGUI"                            ; our own debug dump window
]

global IGNORED_PROCESSES := [
    "SearchHost.exe",
    "StartMenuExperienceHost.exe",
    "ShellExperienceHost.exe",
    "TextInputHost.exe",
    "LockApp.exe",
    "PeopleExperienceHost.exe",
    "SystemSettings.exe",
    "SearchApp.exe",
    "Widgets.exe"
]

; --- hotkeys ---------------------------------------------------------------
global MOD_STACK   := "^#"    ; Ctrl + Win        -- stack navigation (hjkl)
global MOD_DISPLAY := "^!#"   ; Ctrl + Alt + Win  -- display navigation (hjkl)
global MOD_ACTION  := "^!#"   ; Ctrl + Alt + Win  -- everything else

; { key, modifier-prefix, handler, description }
global BINDINGS := [
    [MOD_STACK,   "j",     Cmd_StackNext,        "focus next window in stack"],
    [MOD_STACK,   "k",     Cmd_StackPrev,        "focus previous window in stack"],
    [MOD_STACK,   "h",     Cmd_NotApplicable,    "reserved for tiling (no-op)"],
    [MOD_STACK,   "l",     Cmd_NotApplicable,    "reserved for tiling (no-op)"],
    [MOD_DISPLAY, "h",     Cmd_DisplayWest,      "focus display west"],
    [MOD_DISPLAY, "l",     Cmd_DisplayEast,      "focus display east"],
    [MOD_DISPLAY, "j",     Cmd_DisplaySouth,     "focus display south"],
    [MOD_DISPLAY, "k",     Cmd_DisplayNorth,     "focus display north"],
    [MOD_ACTION,  "o",     Cmd_MoveDisplayPrev,  "move window to prev display"],
    [MOD_ACTION,  "p",     Cmd_MoveDisplayNext,  "move window to next display"],
    [MOD_ACTION,  "Space", Cmd_ToggleAccordion,  "toggle accordion mode"],
    [MOD_ACTION,  "c",     Cmd_MouseOff,         "mouse integration OFF"],
    [MOD_ACTION,  "v",     Cmd_MouseOn,          "mouse integration ON"],
    [MOD_ACTION,  "d",     Cmd_DebugDump,        "debug dump (toggle)"],
    [MOD_ACTION,  "u",     Cmd_RestoreAll,       "restore original window rects"],
    [MOD_ACTION,  "r",     Cmd_Reload,           "reload script"]
]

; ---------------------------------------------------------------------------
;  STATE
; ---------------------------------------------------------------------------
global ACCORDION_ENABLED  := true
global MOUSE_INTEGRATION  := false   ; X-mouse: focus_follows_mouse + autoraise
global MOUSE_FOLLOW_FOCUS := true    ; warp the cursor after we change focus

global Managed      := Map()   ; hwnd -> {cls, proc, title, mon}
global Stacks       := Map()   ; monitor index -> array of hwnd, MRU first
global LastFocused  := Map()   ; monitor index -> hwnd
global CycleIndex   := Map()   ; monitor index -> current cycle position
global Original     := Map()   ; hwnd -> {x,y,w,h,max}  (first-seen snapshot)
global AppliedTick  := Map()   ; hwnd -> scan counter when policy last applied
global Misbehaved   := Map()   ; hwnd -> true (already shouted about it)
global SkipLogged   := Map()   ; hwnd -> last logged skip reason
global FilterCounts := Map()

global ScanCounter    := 0
global Scanning       := false          ; re-entrancy guard for the timer
global LastKnownActive := 0
global SuppressPromote := 0             ; hwnd whose activation must not reorder
global DebugGui        := 0
global ActivationFailures := 0

global WinEventCallback := 0         ; must stay referenced or it is collected
global WinEventHooks    := []        ; HWINEVENTHOOK handles, unhooked on exit

; saved SystemParametersInfo values, restored on exit
global ORIG_FGLOCK   := ""
global ORIG_TRACKING := ""
global ORIG_ZORDER   := ""
global ORIG_TRKTIME  := ""

; SPI constants (verified against Win32 docs -- note these differ from the
; values quoted in the brief; see FINDINGS.md "Decisions")
global SPI_GETACTIVEWINDOWTRACKING  := 0x1000
global SPI_SETACTIVEWINDOWTRACKING  := 0x1001
global SPI_GETACTIVEWNDTRKZORDER    := 0x100C
global SPI_SETACTIVEWNDTRKZORDER    := 0x100D
global SPI_GETACTIVEWNDTRKTIMEOUT   := 0x2002
global SPI_SETACTIVEWNDTRKTIMEOUT   := 0x2003
global SPI_GETFOREGROUNDLOCKTIMEOUT := 0x2000
global SPI_SETFOREGROUNDLOCKTIMEOUT := 0x2001
global SPIF_SENDCHANGE := 2

; window styles
global WS_CAPTION     := 0x00C00000
global WS_MAXIMIZEBOX := 0x00010000
global WS_CHILD       := 0x40000000
global WS_EX_TOOLWINDOW := 0x00000080
global WS_EX_NOACTIVATE := 0x08000000

; ---------------------------------------------------------------------------
;  BOOTSTRAP
; ---------------------------------------------------------------------------

; Emergency exit is registered FIRST and its handler depends on nothing but
; the saved SPI globals, so it works even if startup later goes sideways.
try Hotkey(MOD_ACTION "q", Cmd_EmergencyExit, "On")

OnExit(OnExitHandler)
OnError(OnErrorHandler)

Log("=== accordion.ahk start === AHK " A_AhkVersion "  admin=" (A_IsAdmin ? "yes" : "no") "  dpi=" DPI_PATH)

MaybeElevate()
SaveAndPatchForegroundLock()
RegisterHotkeys()

if (X_MOUSE_ON_START)
    SetMouseIntegration(true)

InitStacks()
ScanWindows()                 ; first pass: adopt + fullscreen everything
SetTimer(ScanWindows, POLL_INTERVAL_MS)

if (USE_WIN_EVENT_HOOK)
    RegisterWinEventHooks()

Notify("accordion ON  (" FULLSCREEN_MODE ")"
       . "  mouse->focus=" (MOUSE_FOLLOW_FOCUS ? MOUSE_FOLLOW_TARGET : "off")
       . "  hover-focus=" (MOUSE_INTEGRATION ? "on" : "off"))
return

; ---------------------------------------------------------------------------
;  HOTKEY REGISTRATION
; ---------------------------------------------------------------------------
RegisterHotkeys() {
    for b in BINDINGS {
        combo := b[1] b[2]
        try {
            Hotkey(combo, b[3], "On")
            Log("hotkey registered: " combo "  -> " b[4])
        } catch as e {
            Log("HOTKEY FAILED: " combo "  (" b[4] ") -- " e.Message)
        }
    }
}

; ---------------------------------------------------------------------------
;  COMMAND HANDLERS
; ---------------------------------------------------------------------------

Cmd_StackNext(*)  => CycleStack(+1)
Cmd_StackPrev(*)  => CycleStack(-1)

Cmd_NotApplicable(*) {
    Log("cmd: h/l -- not applicable in accordion mode")
    Notify("h/l: not applicable in accordion mode (stack is j/k)")
}

Cmd_DisplayWest(*)  => FocusDisplay("west")
Cmd_DisplayEast(*)  => FocusDisplay("east")
Cmd_DisplayNorth(*) => FocusDisplay("north")
Cmd_DisplaySouth(*) => FocusDisplay("south")

Cmd_MoveDisplayPrev(*) => MoveWindowToDisplay(-1)
Cmd_MoveDisplayNext(*) => MoveWindowToDisplay(+1)

Cmd_ToggleAccordion(*) {
    global ACCORDION_ENABLED
    ACCORDION_ENABLED := !ACCORDION_ENABLED
    Log("cmd: toggle accordion -> " (ACCORDION_ENABLED ? "ON" : "OFF"))
    if (ACCORDION_ENABLED) {
        SetTimer(ScanWindows, POLL_INTERVAL_MS)
        Notify("accordion ON")
    } else {
        SetTimer(ScanWindows, 0)
        SetMouseIntegration(false)
        Notify("accordion OFF  (navigation hotkeys still live)")
    }
}

Cmd_MouseOn(*)  => SetMouseIntegration(true)
Cmd_MouseOff(*) => SetMouseIntegration(false)

Cmd_Reload(*) {
    Log("cmd: reload")
    RestoreSystemSettings()
    Reload()
}

Cmd_EmergencyExit(*) {
    ; Deliberately dependency-free.
    try RestoreSystemSettings()
    try Log("cmd: EMERGENCY EXIT")
    ExitApp()
}

Cmd_RestoreAll(*) {
    Log("cmd: restore all (" Original.Count " snapshots)")
    n := 0
    for hwnd, o in Original {
        if !WinExist("ahk_id " hwnd)
            continue
        try {
            if (o.max)
                WinMaximize("ahk_id " hwnd)
            else {
                WinRestore("ahk_id " hwnd)
                WinMove(o.x, o.y, o.w, o.h, "ahk_id " hwnd)
            }
            n++
        }
    }
    Notify("restored " n " windows")
}

; ---------------------------------------------------------------------------
;  CORE: stack navigation
; ---------------------------------------------------------------------------

CycleStack(dir) {
    global SuppressPromote
    mon := ActiveMonitor()
    stack := GetStack(mon)
    if (stack.Length = 0) {
        Log("cmd: cycle " dir " -- monitor " mon " stack empty")
        Notify("stack empty on monitor " mon)
        return
    }
    if (stack.Length = 1) {
        Log("cmd: cycle " dir " -- monitor " mon " has a single window")
        FocusWindow(stack[1], false)
        return
    }
    idx := CycleIndex.Has(mon) ? CycleIndex[mon] : 1
    idx += dir
    while (idx > stack.Length)
        idx -= stack.Length
    while (idx < 1)
        idx += stack.Length
    CycleIndex[mon] := idx
    hwnd := stack[idx]
    Log("cmd: cycle " (dir > 0 ? "next" : "prev") " mon=" mon " idx=" idx "/" stack.Length " -> " Describe(hwnd))
    SuppressPromote := hwnd          ; keep stack order stable while cycling
    FocusWindow(hwnd, false)
}

FocusDisplay(dir) {
    cur := ActiveMonitor()
    target := NeighbourMonitor(cur, dir)
    if (!target) {
        Log("cmd: display " dir " from mon " cur " -- no monitor in that direction (no-op)")
        Notify("no display " dir)
        return
    }
    hwnd := 0
    if (LastFocused.Has(target) && WinExist("ahk_id " LastFocused[target]))
        hwnd := LastFocused[target]
    else {
        stack := GetStack(target)
        if (stack.Length)
            hwnd := stack[1]
    }
    if (!hwnd) {
        Log("cmd: display " dir " -> mon " target " has no managed window; moving cursor only")
        MonitorGetWorkArea(target, &l, &t, &r, &b)
        DllCall("SetCursorPos", "int", (l + r) // 2, "int", (t + b) // 2)
        Notify("display " target ": no windows")
        return
    }
    Log("cmd: display " dir " mon " cur " -> " target " : " Describe(hwnd))
    FocusWindow(hwnd, true)
}

MoveWindowToDisplay(dir) {
    hwnd := WinExist("A")
    if (!hwnd || !Managed.Has(hwnd)) {
        Log("cmd: move-display " dir " -- active window is not managed (" Describe(hwnd) ")")
        Notify("active window is not managed")
        return
    }
    order := MonitorOrder()
    if (order.Length < 2) {
        Log("cmd: move-display " dir " -- only one monitor")
        Notify("only one display")
        return
    }
    cur := MonitorOfWindow(hwnd)
    pos := 1
    for i, m in order
        if (m = cur)
            pos := i
    pos += dir
    while (pos > order.Length)
        pos -= order.Length
    while (pos < 1)
        pos += order.Length
    target := order[pos]

    Log("cmd: move-display " (dir > 0 ? "next" : "prev") " " Describe(hwnd) " mon " cur " -> " target)

    MonitorGetWorkArea(target, &l, &t, &r, &b)
    try {
        if (WinGetMinMax("ahk_id " hwnd) = 1)
            WinRestore("ahk_id " hwnd)
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        nw := Min(w, r - l), nh := Min(h, b - t)
        WinMove(l + ((r - l) - nw) // 2, t + ((b - t) - nh) // 2, nw, nh, "ahk_id " hwnd)
    } catch as e {
        Log("  move failed: " e.Message)
    }
    RemoveFromStacks(hwnd)
    Managed[hwnd].mon := target
    PushStack(target, hwnd)
    ApplyFullscreen(hwnd)
    FocusWindow(hwnd, true)
}

; ---------------------------------------------------------------------------
;  CORE: focus
; ---------------------------------------------------------------------------

FocusWindow(hwnd, promote := true) {
    global LastKnownActive, ActivationFailures
    if (!hwnd || !WinExist("ahk_id " hwnd))
        return false

    if (ACCORDION_ENABLED)
        ApplyFullscreen(hwnd)

    ok := ActivateVerified(hwnd)
    if (!ok) {
        ActivationFailures++
        Log("ACTIVATE FAILED: " Describe(hwnd))
        Notify("activate failed: " Truncate(SafeTitle(hwnd), 40))
        return false
    }

    LastKnownActive := hwnd
    mon := MonitorOfWindow(hwnd)
    LastFocused[mon] := hwnd
    if (promote)
        PromoteInStack(mon, hwnd)
    MouseFollowFocus(hwnd)
    return true
}

ActivateVerified(hwnd) {
    try WinActivate("ahk_id " hwnd)
    if WinActive("ahk_id " hwnd)
        return true
    Sleep(30)
    try WinActivate("ahk_id " hwnd)
    return WinActive("ahk_id " hwnd) ? true : false
}

MouseFollowFocus(hwnd) {
    if (!MOUSE_FOLLOW_FOCUS)
        return
    MouseGetPos(&mx, &my)

    if (MOUSE_FOLLOW_TARGET = "monitor") {
        mon := MonitorOfWindow(hwnd)
        if (MonitorOfPoint(mx, my) = mon)
            return                    ; already on that screen -- leave it be
        MonitorGetWorkArea(mon, &l, &t, &r, &b)
        DllCall("SetCursorPos", "int", (l + r) // 2, "int", (t + b) // 2)
        Log("  mouse -> centre of monitor " mon)
        return
    }

    try WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    catch
        return
    if (mx >= x && mx < x + w && my >= y && my < y + h)
        return                        ; already inside -- don't yank the pointer
    DllCall("SetCursorPos", "int", x + w // 2, "int", y + h // 2)
    Log("  mouse -> centre of window " hwnd)
}

; ---------------------------------------------------------------------------
;  CORE: stacks
; ---------------------------------------------------------------------------

InitStacks() {
    Loop MonitorGetCount() {
        Stacks[A_Index] := []
        CycleIndex[A_Index] := 1
    }
}

GetStack(mon) {
    if !Stacks.Has(mon)
        Stacks[mon] := []
    return Stacks[mon]
}

PushStack(mon, hwnd) {
    stack := GetStack(mon)
    for i, h in stack
        if (h = hwnd)
            return
    stack.InsertAt(1, hwnd)
}

PromoteInStack(mon, hwnd) {
    stack := GetStack(mon)
    found := 0
    for i, h in stack {
        if (h = hwnd) {
            found := i
            break
        }
    }
    if (found > 1) {
        stack.RemoveAt(found)
        stack.InsertAt(1, hwnd)
    } else if (found = 0) {
        stack.InsertAt(1, hwnd)
    }
    CycleIndex[mon] := 1              ; focus changed by non-cycle means
}

RemoveFromStacks(hwnd) {
    for mon, stack in Stacks {
        i := stack.Length
        while (i >= 1) {
            if (stack[i] = hwnd)
                stack.RemoveAt(i)
            i--
        }
        if (CycleIndex.Has(mon) && CycleIndex[mon] > stack.Length)
            CycleIndex[mon] := 1
    }
    for mon, h in LastFocused.Clone()
        if (h = hwnd)
            LastFocused.Delete(mon)
}

; ---------------------------------------------------------------------------
;  CORE: window event hooks
;
;  A new window would otherwise sit at its natural size until the next poll
;  tick -- visibly "small, then jump". These hooks cut that to EVENT_DEBOUNCE_MS.
;  The hook itself does no work: it just schedules a scan, so all the real
;  logic stays on one path and the Scanning re-entrancy guard still holds.
; ---------------------------------------------------------------------------

RegisterWinEventHooks() {
    global WinEventCallback, WinEventHooks

    ; void CALLBACK WinEventProc(HWINEVENTHOOK, DWORD event, HWND, LONG idObject,
    ;                            LONG idChild, DWORD idEventThread, DWORD dwmsEventTime)
    WinEventCallback := CallbackCreate(WinEventProc, "", 7)

    ; WINEVENT_OUTOFCONTEXT (0) | WINEVENT_SKIPOWNPROCESS (2) -- events are
    ; delivered to our message loop, and our own windows are not reported.
    flags := 0x0002

    ; 0x8000 EVENT_OBJECT_CREATE .. 0x8003 EVENT_OBJECT_HIDE
    AddWinEventHook(0x8000, 0x8003, flags, "OBJECT_CREATE..HIDE")
    ; 0x0003 EVENT_SYSTEM_FOREGROUND -- focus changed by any means
    AddWinEventHook(0x0003, 0x0003, flags, "SYSTEM_FOREGROUND")
    ; 0x0016 EVENT_SYSTEM_MINIMIZEEND -- restored from the taskbar
    AddWinEventHook(0x0016, 0x0016, flags, "SYSTEM_MINIMIZEEND")
}

AddWinEventHook(evMin, evMax, flags, name) {
    global WinEventHooks, WinEventCallback
    h := DllCall("SetWinEventHook", "uint", evMin, "uint", evMax,
                 "ptr", 0, "ptr", WinEventCallback,
                 "uint", 0, "uint", 0, "uint", flags, "ptr")
    if (h) {
        WinEventHooks.Push(h)
        Log("win event hook registered: " name " (" Format("0x{:04X}", evMin)
            . ".." Format("0x{:04X}", evMax) ")")
    } else {
        Log("WIN EVENT HOOK FAILED: " name " -- falling back to the "
            . POLL_INTERVAL_MS "ms poll")
    }
}

WinEventProc(hHook, event, hwnd, idObject, idChild, idEventThread, dwmsEventTime) {
    ; Runs during message dispatch: stay cheap and never throw.
    try {
        if (!ACCORDION_ENABLED)
            return
        if (idObject != 0 || idChild != 0)     ; OBJID_WINDOW only, not controls
            return
        ; Debounce: a burst of events (create, show, foreground) collapses into
        ; one scan, and the delay lets the window finish settling first.
        SetTimer(ScanSoon, -EVENT_DEBOUNCE_MS)
    }
}

; Separate function object from ScanWindows so this one-shot does not replace
; the periodic timer.
ScanSoon() {
    ScanWindows()
}

; ---------------------------------------------------------------------------
;  CORE: discovery loop
; ---------------------------------------------------------------------------

ScanWindows() {
    global Scanning, ScanCounter, FilterCounts, LastKnownActive, SuppressPromote

    if (Scanning)                     ; re-entrancy guard (timer + Sleep inside)
        return
    Scanning := true
    try {
        ScanCounter++
        FilterCounts := Map()
        seen := Map()
        mouseDown := GetKeyState("LButton", "P") || GetKeyState("RButton", "P")

        for hwnd in WinGetList() {
            reason := FilterReason(hwnd)
            if (reason != "") {
                CountFilter(reason)
                LogSkip(hwnd, reason)
                continue
            }
            seen[hwnd] := true
            mon := MonitorOfWindow(hwnd)

            if (!Managed.Has(hwnd)) {
                Managed[hwnd] := {cls: SafeClass(hwnd), proc: SafeProc(hwnd), title: SafeTitle(hwnd), mon: mon}
                SnapshotOriginal(hwnd)
                PushStack(mon, hwnd)
                Log("ADD: " Describe(hwnd) " mon=" mon)
                if (ACCORDION_ENABLED && !mouseDown) {
                    ApplyFullscreen(hwnd)
                    if (FOCUS_NEW_WINDOWS)
                        FocusWindow(hwnd, true)
                }
                continue
            }

            info := Managed[hwnd]
            if (info.mon != mon) {                 ; migrated between monitors
                Log("MOVED: " Describe(hwnd) " mon " info.mon " -> " mon)
                RemoveFromStacks(hwnd)
                info.mon := mon
                PushStack(mon, hwnd)
                if (ACCORDION_ENABLED && !mouseDown)
                    ApplyFullscreen(hwnd)
                continue
            }

            if (!ACCORDION_ENABLED || mouseDown)
                continue

            if (NeedsFullscreen(hwnd)) {
                ; naughty list: it was correct 1-2 ticks ago and undid itself
                if (AppliedTick.Has(hwnd) && (ScanCounter - AppliedTick[hwnd]) <= 2 && !Misbehaved.Has(hwnd)) {
                    Misbehaved[hwnd] := true
                    Log("MISBEHAVING: window reverted its own size within "
                        . (ScanCounter - AppliedTick[hwnd]) . " tick(s) -- " . Describe(hwnd))
                }
                ApplyFullscreen(hwnd)
            }
        }

        ; --- gone windows ---
        for hwnd, info in Managed.Clone() {
            if (seen.Has(hwnd))
                continue
            Log("REMOVE: hwnd=" hwnd " " info.cls " / " info.proc " / " Truncate(info.title, 60))
            Managed.Delete(hwnd)
            RemoveFromStacks(hwnd)
            AppliedTick.Delete(hwnd)
            Misbehaved.Delete(hwnd)
            Original.Delete(hwnd)
            SkipLogged.Delete(hwnd)
        }

        ; --- external focus change (alt-tab, mouse, app self-activation) ---
        act := WinExist("A")
        if (act && act != LastKnownActive && Managed.Has(act)) {
            LastKnownActive := act
            mon := MonitorOfWindow(act)
            LastFocused[mon] := act
            if (act != SuppressPromote)
                PromoteInStack(mon, act)
            SuppressPromote := 0
        }
    } catch as e {
        Log("SCAN ERROR: " e.Message " (" e.File ":" e.Line ")")
    }
    Scanning := false
}

CountFilter(reason) {
    FilterCounts[reason] := FilterCounts.Has(reason) ? FilterCounts[reason] + 1 : 1
}

LogSkip(hwnd, reason) {
    if (!LOG_SKIPS)
        return
    if (SkipLogged.Has(hwnd) && SkipLogged[hwnd] = reason)
        return
    SkipLogged[hwnd] := reason
    ; noise-free: only report skips that have a title (nameless ones are legion)
    t := SafeTitle(hwnd)
    if (t = "" && reason = "no-title")
        return
    Log("SKIP[" reason "]: " Describe(hwnd))
}

; "" == managed; otherwise the reason it was rejected
FilterReason(hwnd) {

    if (SafeTitle(hwnd) = "")
        return "no-title"
    if (IsCloaked(hwnd))
        return "dwm-cloaked"

    cls := SafeClass(hwnd)
    for c in IGNORED_CLASSES
        if (cls = c)
            return "ignored-class"

    proc := SafeProc(hwnd)
    for p in IGNORED_PROCESSES
        if (proc = p)
            return "ignored-process"

    try {
        style := WinGetStyle("ahk_id " hwnd)
        ex    := WinGetExStyle("ahk_id " hwnd)
    } catch
        return "gone"

    if (ex & WS_EX_TOOLWINDOW)
        return "toolwindow"
    if (ex & WS_EX_NOACTIVATE)
        return "noactivate"
    if (style & WS_CHILD)
        return "child"
    ; err on the side of including: a top-level, non-tool, owner-less window
    ; without WS_CAPTION is still probably a real app window (borderless apps).
    if (!(style & WS_CAPTION) && DllCall("GetWindow", "ptr", hwnd, "uint", 4, "ptr"))
        return "owned-no-caption"      ; GW_OWNER == 4

    try WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    catch
        return "gone"
    if (w < MIN_WIN_W || h < MIN_WIN_H)
        return "too-small"

    return ""
}

SnapshotOriginal(hwnd) {
    if (Original.Has(hwnd))
        return
    try {
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        Original[hwnd] := {x: x, y: y, w: w, h: h, max: (WinGetMinMax("ahk_id " hwnd) = 1)}
    }
}

; ---------------------------------------------------------------------------
;  CORE: fullscreen policy
; ---------------------------------------------------------------------------

; true if the window is not currently where the policy wants it
NeedsFullscreen(hwnd) {
    try {
        style := WinGetStyle("ahk_id " hwnd)
        if (FULLSCREEN_MODE = "maximize" && (style & WS_MAXIMIZEBOX))
            return WinGetMinMax("ahk_id " hwnd) != 1
        mon := MonitorOfWindow(hwnd)
        MonitorGetWorkArea(mon, &l, &t, &r, &b)
        GetVisibleRect(hwnd, &vx, &vy, &vw, &vh)
        return Abs(vx - l) > RECT_TOLERANCE || Abs(vy - t) > RECT_TOLERANCE
            || Abs(vw - (r - l)) > RECT_TOLERANCE || Abs(vh - (b - t)) > RECT_TOLERANCE
    } catch
        return false
}

ApplyFullscreen(hwnd) {
    if (GetKeyState("LButton", "P") || GetKeyState("RButton", "P"))
        return                         ; never fight a drag
    if (!WinExist("ahk_id " hwnd))
        return
    if (!NeedsFullscreen(hwnd))
        return                         ; already correct -- do not touch (flicker)

    try {
        style := WinGetStyle("ahk_id " hwnd)
        if (FULLSCREEN_MODE = "maximize" && (style & WS_MAXIMIZEBOX)) {
            WinMaximize("ahk_id " hwnd)
        } else {
            ApplyWorkAreaFullscreen(hwnd)
        }
        AppliedTick[hwnd] := ScanCounter
    } catch as e {
        Log("FULLSCREEN FAILED: " Describe(hwnd) " -- " e.Message)
    }
}

ApplyWorkAreaFullscreen(hwnd) {
    mon := MonitorOfWindow(hwnd)
    MonitorGetWorkArea(mon, &l, &t, &r, &b)
    if (WinGetMinMax("ahk_id " hwnd) != 0)
        WinRestore("ahk_id " hwnd)
    ; Compensate for the invisible DWM resize border: the difference between
    ; the window rect (WinGetPos) and the visible frame (extended frame bounds).
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    GetVisibleRect(hwnd, &vx, &vy, &vw, &vh)
    dx := vx - wx, dy := vy - wy
    dw := ww - vw, dh := wh - vh
    WinMove(l - dx, t - dy, (r - l) + dw, (b - t) + dh, "ahk_id " hwnd)
}

; Visible frame via DWMWA_EXTENDED_FRAME_BOUNDS; falls back to WinGetPos.
GetVisibleRect(hwnd, &x, &y, &w, &h) {
    rect := Buffer(16, 0)              ; RECT { LONG left, top, right, bottom }
    ; 9 == DWMWA_EXTENDED_FRAME_BOUNDS
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9,
                  "ptr", rect, "uint", 16, "int")
    if (hr = 0) {
        x := NumGet(rect, 0, "int")
        y := NumGet(rect, 4, "int")
        w := NumGet(rect, 8, "int") - x
        h := NumGet(rect, 12, "int") - y
        return
    }
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
}

IsCloaked(hwnd) {
    cloaked := 0
    ; 14 == DWMWA_CLOAKED; non-zero result means the window is cloaked (UWP ghosts)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14,
                  "int*", &cloaked, "uint", 4, "int")
    return (hr = 0) ? (cloaked != 0) : false
}

; ---------------------------------------------------------------------------
;  CORE: monitors
; ---------------------------------------------------------------------------

MonitorOfPoint(px, py) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (px >= l && px < r && py >= t && py < b)
            return A_Index
    }
    ; off-screen point: nearest monitor centre
    best := 1, bestD := ""
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        cx := (l + r) / 2, cy := (t + b) / 2
        d := (cx - px) ** 2 + (cy - py) ** 2
        if (bestD = "" || d < bestD)
            bestD := d, best := A_Index
    }
    return best
}

MonitorOfWindow(hwnd) {
    try WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    catch
        return 1
    return MonitorOfPoint(x + w // 2, y + h // 2)
}

ActiveMonitor() {
    hwnd := WinExist("A")
    if (hwnd)
        return MonitorOfWindow(hwnd)
    MouseGetPos(&mx, &my)
    return MonitorOfPoint(mx, my)
}

MonitorCentre(i, &cx, &cy) {
    MonitorGet(i, &l, &t, &r, &b)
    cx := (l + r) / 2
    cy := (t + b) / 2
}

; strictly-beyond-the-edge candidates, nearest centre wins, no wrap-around
NeighbourMonitor(from, dir) {
    MonitorGet(from, &fl, &ft, &fr, &fb)
    MonitorCentre(from, &fcx, &fcy)
    best := 0, bestD := ""
    Loop MonitorGetCount() {
        if (A_Index = from)
            continue
        MonitorCentre(A_Index, &cx, &cy)
        ok := false
        if (dir = "west")
            ok := (cx < fl)
        else if (dir = "east")
            ok := (cx > fr)
        else if (dir = "north")
            ok := (cy < ft)
        else if (dir = "south")
            ok := (cy > fb)
        if (!ok)
            continue
        d := (cx - fcx) ** 2 + (cy - fcy) ** 2
        if (bestD = "" || d < bestD)
            bestD := d, best := A_Index
    }
    return best
}

; left-to-right by .left, tie-broken top-to-bottom by .top
MonitorOrder() {
    list := []
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        list.Push({i: A_Index, l: l, t: t})
    }
    ; insertion sort -- at most a handful of monitors
    i := 2
    while (i <= list.Length) {
        cur := list[i], j := i - 1
        while (j >= 1 && (list[j].l > cur.l || (list[j].l = cur.l && list[j].t > cur.t))) {
            list[j + 1] := list[j]
            j--
        }
        list[j + 1] := cur
        i++
    }
    out := []
    for m in list
        out.Push(m.i)
    return out
}

; ---------------------------------------------------------------------------
;  SYSTEM SETTINGS (SystemParametersInfoW)
;
;  Pointer-vs-value matters here:
;    SPI_GET* boolean/dword  -> pvParam is a POINTER to the output
;    SPI_SET* boolean/dword  -> the value travels BY VALUE in the pvParam slot,
;                               uiParam is 0.
; ---------------------------------------------------------------------------

SpiGetDword(action) {
    val := 0
    ok := DllCall("SystemParametersInfoW", "uint", action, "uint", 0,
                  "uint*", &val, "uint", 0, "int")
    return ok ? val : ""
}

SpiSetValue(action, value, name := "", verifyAction := 0) {
    ok := DllCall("SystemParametersInfoW", "uint", action, "uint", 0,
                  "ptr", value, "uint", SPIF_SENDCHANGE, "int")
    msg := "SPI " (name != "" ? name : Format("0x{:04X}", action)) " := " value
         . "  call=" (ok ? "ok" : "FAILED(" A_LastError ")")
    if (verifyAction) {
        got := SpiGetDword(verifyAction)
        msg .= "  readback=" (got = "" ? "<get failed>" : got)
             . ((got != "" && got = value) ? "  VERIFIED" : "  MISMATCH")
    }
    Log(msg)
    return ok
}

SaveAndPatchForegroundLock() {
    global ORIG_FGLOCK
    ORIG_FGLOCK := SpiGetDword(SPI_GETFOREGROUNDLOCKTIMEOUT)
    Log("SPI foreground lock timeout original = " (ORIG_FGLOCK = "" ? "<unknown>" : ORIG_FGLOCK))
    SpiSetValue(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, "SETFOREGROUNDLOCKTIMEOUT", SPI_GETFOREGROUNDLOCKTIMEOUT)
}

SetMouseIntegration(on) {
    global MOUSE_INTEGRATION, MOUSE_FOLLOW_FOCUS, ORIG_TRACKING, ORIG_ZORDER, ORIG_TRKTIME
    if (on && ORIG_TRACKING = "") {            ; capture originals once
        ORIG_TRACKING := SpiGetDword(SPI_GETACTIVEWINDOWTRACKING)
        ORIG_ZORDER   := SpiGetDword(SPI_GETACTIVEWNDTRKZORDER)
        ORIG_TRKTIME  := SpiGetDword(SPI_GETACTIVEWNDTRKTIMEOUT)
        Log("SPI originals: tracking=" ORIG_TRACKING " zorder=" ORIG_ZORDER " trktimeout=" ORIG_TRKTIME)
    }
    MOUSE_INTEGRATION  := on ? true : false
    MOUSE_FOLLOW_FOCUS := on ? true : false
    Log("cmd: mouse integration -> " (on ? "ON" : "OFF"))
    if (on) {
        SpiSetValue(SPI_SETACTIVEWNDTRKTIMEOUT, MOUSE_TRK_TIMEOUT, "SETACTIVEWNDTRKTIMEOUT", SPI_GETACTIVEWNDTRKTIMEOUT)
        SpiSetValue(SPI_SETACTIVEWNDTRKZORDER, 1, "SETACTIVEWNDTRKZORDER (autoraise)", SPI_GETACTIVEWNDTRKZORDER)
        SpiSetValue(SPI_SETACTIVEWINDOWTRACKING, 1, "SETACTIVEWINDOWTRACKING", SPI_GETACTIVEWINDOWTRACKING)
    } else {
        SpiSetValue(SPI_SETACTIVEWINDOWTRACKING, ORIG_TRACKING = "" ? 0 : ORIG_TRACKING,
                    "SETACTIVEWINDOWTRACKING (restore)", SPI_GETACTIVEWINDOWTRACKING)
        SpiSetValue(SPI_SETACTIVEWNDTRKZORDER, ORIG_ZORDER = "" ? 0 : ORIG_ZORDER,
                    "SETACTIVEWNDTRKZORDER (restore)", SPI_GETACTIVEWNDTRKZORDER)
        if (ORIG_TRKTIME != "")
            SpiSetValue(SPI_SETACTIVEWNDTRKTIMEOUT, ORIG_TRKTIME, "SETACTIVEWNDTRKTIMEOUT (restore)", SPI_GETACTIVEWNDTRKTIMEOUT)
    }
    Notify("mouse integration " (on ? "ON (follows focus + X-mouse + autoraise)" : "OFF"))
}

RestoreSystemSettings() {
    if (ORIG_FGLOCK != "")
        DllCall("SystemParametersInfoW", "uint", SPI_SETFOREGROUNDLOCKTIMEOUT, "uint", 0,
                "ptr", ORIG_FGLOCK, "uint", SPIF_SENDCHANGE, "int")
    if (ORIG_TRACKING != "")
        DllCall("SystemParametersInfoW", "uint", SPI_SETACTIVEWINDOWTRACKING, "uint", 0,
                "ptr", ORIG_TRACKING, "uint", SPIF_SENDCHANGE, "int")
    if (ORIG_ZORDER != "")
        DllCall("SystemParametersInfoW", "uint", SPI_SETACTIVEWNDTRKZORDER, "uint", 0,
                "ptr", ORIG_ZORDER, "uint", SPIF_SENDCHANGE, "int")
    if (ORIG_TRKTIME != "")
        DllCall("SystemParametersInfoW", "uint", SPI_SETACTIVEWNDTRKTIMEOUT, "uint", 0,
                "ptr", ORIG_TRKTIME, "uint", SPIF_SENDCHANGE, "int")
}

MaybeElevate() {
    if (A_IsAdmin || !AUTO_ELEVATE)
        return
    try {
        Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
        Log("relaunching elevated; this instance exits")
        ExitApp()
    } catch as e {
        Log("ELEVATION DECLINED/FAILED (" e.Message ") -- continuing non-elevated;"
            . " windows owned by elevated processes will be unmanageable (UIPI)")
        Notify("Running NON-ELEVATED: elevated apps' windows cannot be managed")
    }
}

; ---------------------------------------------------------------------------
;  DEBUG DUMP
; ---------------------------------------------------------------------------

Cmd_DebugDump(*) {
    global DebugGui
    if (IsObject(DebugGui)) {
        try DebugGui.Destroy()
        DebugGui := 0
        return
    }
    txt := BuildDebugText()
    Log("--- DEBUG DUMP ---`n" txt "`n--- END DUMP ---")
    DebugGui := Gui("+AlwaysOnTop +Resize", "accordion debug  (press the dump hotkey again to close)")
    DebugGui.SetFont("s9", "Consolas")
    DebugGui.Add("Edit", "ReadOnly w1000 r40 vDump", txt)
    DebugGui.OnEvent("Close", (*) => CloseDebugGui())
    DebugGui.Show()
}

CloseDebugGui(*) {
    global DebugGui
    if (IsObject(DebugGui)) {
        try DebugGui.Destroy()
        DebugGui := 0
    }
}

BuildDebugText() {

    s := "accordion=" (ACCORDION_ENABLED ? "ON" : "OFF")
       . "   x_mouse=" (MOUSE_INTEGRATION ? "ON" : "OFF")
       . "   mouse_follows_focus=" (MOUSE_FOLLOW_FOCUS ? "ON" : "OFF")
       . " (" MOUSE_FOLLOW_TARGET ")"
       . "   fullscreen_mode=" FULLSCREEN_MODE
       . "   poll=" POLL_INTERVAL_MS "ms"
       . "   hooks=" (WinEventHooks.Length ? WinEventHooks.Length " active, debounce " EVENT_DEBOUNCE_MS "ms" : "none (polling only)")
       . "   admin=" (A_IsAdmin ? "yes" : "no")
       . "   dpi=" DPI_PATH "`r`n"
    s .= "managed=" Managed.Count "   activation_failures=" ActivationFailures
       . "   misbehaving=" Misbehaved.Count "`r`n`r`n"

    s .= "MONITORS (" MonitorGetCount() ", primary=" MonitorGetPrimary() ")`r`n"
    order := MonitorOrder()
    ord := ""
    for m in order
        ord .= (ord = "" ? "" : " -> ") m
    s .= "  prev/next order: " ord "`r`n"
    Loop MonitorGetCount() {
        i := A_Index
        MonitorGet(i, &l, &t, &r, &b)
        MonitorGetWorkArea(i, &wl, &wt, &wr, &wb)
        s .= Format("  [{}] full={},{} {}x{}   work={},{} {}x{}`r`n",
                    i, l, t, r - l, b - t, wl, wt, wr - wl, wb - wt)
        s .= Format("       neighbours: W={} E={} N={} S={}`r`n",
                    NeighbourMonitor(i, "west"), NeighbourMonitor(i, "east"),
                    NeighbourMonitor(i, "north"), NeighbourMonitor(i, "south"))
    }

    s .= "`r`nSTACKS (most-recently-focused first)`r`n"
    for mon, stack in Stacks {
        s .= "  monitor " mon "   cycleIndex=" (CycleIndex.Has(mon) ? CycleIndex[mon] : "-")
           . "   lastFocused=" (LastFocused.Has(mon) ? LastFocused[mon] : "-") "`r`n"
        if (stack.Length = 0)
            s .= "    (empty)`r`n"
        for i, hwnd in stack {
            rect := "gone"
            try {
                WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
                rect := Format("{},{} {}x{}", x, y, w, h)
            }
            s .= Format("    {}. hwnd={}  [{}]  {}  {}`r`n      {}`r`n",
                        i, hwnd, SafeClass(hwnd), SafeProc(hwnd), rect,
                        Truncate(SafeTitle(hwnd), 60))
        }
    }

    act := WinExist("A")
    s .= "`r`nFOCUSED: " Describe(act) "`r`n"
    s .= "  manager thinks monitor = " (act ? MonitorOfWindow(act) : "-")
       . "   managed=" ((act && Managed.Has(act)) ? "yes" : "no") "`r`n"

    s .= "`r`nFILTER EXCLUSIONS (last scan)`r`n"
    if (FilterCounts.Count = 0)
        s .= "  (none)`r`n"
    for reason, n in FilterCounts
        s .= Format("  {:-22} {}`r`n", reason, n)

    s .= "`r`nlog: " LOG_FILE "`r`n"
    return s
}

; ---------------------------------------------------------------------------
;  HELPERS / LOGGING
; ---------------------------------------------------------------------------

SafeTitle(hwnd) {
    try return WinGetTitle("ahk_id " hwnd)
    catch
        return ""
}
SafeClass(hwnd) {
    try return WinGetClass("ahk_id " hwnd)
    catch
        return "?"
}
SafeProc(hwnd) {
    try return WinGetProcessName("ahk_id " hwnd)
    catch
        return "?"
}

Describe(hwnd) {
    if (!hwnd)
        return "<none>"
    return Format('hwnd={} [{}] {} "{}"', hwnd, SafeClass(hwnd), SafeProc(hwnd),
                  Truncate(SafeTitle(hwnd), 60))
}

Truncate(s, n) => (StrLen(s) > n) ? SubStr(s, 1, n - 1) . "..." : s

Notify(msg) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -1800)
}

Log(msg) {
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "." Format("{:03}", A_MSec)
                   . " " . msg . "`n", LOG_FILE, "UTF-8")
}

OnErrorHandler(err, mode) {
    Log("UNHANDLED ERROR: " err.Message " (" err.File ":" err.Line ")")
    return 0        ; let AHK show it too; OnExit still restores settings
}

OnExitHandler(reason, code) {
    Log("=== accordion.ahk exit (" reason ") -- restoring system settings ===")
    try RestoreSystemSettings()
    try SetTimer(ScanWindows, 0)
    try SetTimer(ScanSoon, 0)
    for h in WinEventHooks
        try DllCall("UnhookWinEvent", "ptr", h)
    return 0
}
