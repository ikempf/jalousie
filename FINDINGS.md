# FINDINGS — accordion window manager PoC

Fill this in *while using it*, not afterwards. This file is the deliverable —
it is what the Rust version gets built from.

**Status: the spike succeeded and the script is in daily use.** It starts at
logon via a Scheduled Task. The interaction model reproduces the yabai setup
closely enough that replacing it is no longer urgent; what remains is to find
out which apps misbehave over longer use.

Log lives at `.\accordion.log`. `Ctrl+Alt+Win+D` dumps state to both the log
and a GUI window.

---

## Session notes

| Date | Duration | Monitors (count / arrangement) | Build |
|---|---|---|---|
|  |  |  | Win11 ____ , AHK ____ |

---

## Confirmed working

Verified in real use, not just by reading the log:

- [x] **Stack cycling** — `Ctrl+Win+J/K` walks the current monitor's stack.
- [x] **Directional display focus** — `Ctrl+Alt+Win+H/J/K/L` lands on the
      neighbouring monitor's last-focused window.
- [x] **Hover focus** — `focus_follows_mouse` + autoraise via Windows' native
      X-mouse (`SPI_SETACTIVEWINDOWTRACKING` / `SPI_SETACTIVEWNDTRKZORDER`)
      works. Hovering a window focuses and raises it.
- [x] **Cursor follows keyboard focus across screens** — jumping displays with
      the keyboard warps the pointer to the centre of the target monitor;
      cycling the stack within one screen leaves it alone.
- [x] The two mouse behaviours cooperate rather than fight: the warp lands the
      pointer, X-mouse then agrees with the window we just focused.
- [x] Elevated startup via Scheduled Task, no UAC prompt.

Still to confirm:

- [ ] **Survives a reboot** — task fires at logon, script starts, all bindings
      register, nothing needs a manual nudge. *(testing now)*
- [ ] Long-run stability: no drift in the stacks, no leak, no runaway CPU
      from the 400 ms poll over a full working day.
- [ ] Which apps misbehave (see below) — needs more than a session to surface.

## Checklist

### 1. Does stack cycling feel right?
- [ ] `Ctrl+Win+J/K` walks the *whole* stack rather than bouncing between two windows
- [ ] MRU ordering (most-recently-focused first) is what I actually want, or I'd prefer a stable creation order
- [ ] Do I want `h`/`l` to do something after all? If so, what — *(ideas: jump to first/last in stack; swap with the window below; move focus by app)*

Notes:

### 2. Which apps refuse to be fullscreened, and which fight back?
Grep the log: `Select-String "MISBEHAVING|FULLSCREEN FAILED" .\accordion.log`

| App | Class | Process | Symptom (refuses / reverts / flickers / crashes) |
|---|---|---|---|
|  |  |  |  |

- [ ] Any app that needed adding to `IGNORED_CLASSES` / `IGNORED_PROCESSES`:
- [ ] Did `FULLSCREEN_MODE := "workarea"` behave better or worse than `"maximize"` for the offenders?

### 3. Did any `WinActivate` calls fail?
Grep: `Select-String "ACTIVATE FAILED" .\accordion.log`

- [ ] Failure count after a full session: ____
- [ ] Which windows? (elevated? UWP? fullscreen games? installers?)
- [ ] Did running elevated fix them?

### 4. Is 400 ms polling perceptibly laggy for new windows?
**Yes — confirmed.** New windows visibly appeared at their natural size and then
jumped to fullscreen. Fixed by adding `SetWinEventHook` (create/show/hide/destroy,
foreground, un-minimize) which schedules a scan `EVENT_DEBOUNCE_MS` (40 ms) later;
the poll stays as a backstop for self-resizing and monitor-hopping windows.
This is the one place the PoC's "polling is fine" shortcut did not survive
real use.
- [ ] Is 40 ms debounce right? Lower if the flash is still visible; raise if
      windows get maximized before they finish laying out.
- [ ] Any app where the hook fires but the poll is what actually catches it?
- [ ] CPU cost over a full day with hooks on (they fire far more often than 2.5/s)
- [ ] Does a faster poll cause noticeable CPU use or fight with drags?
- Chosen value that felt right: ____ ms
- Conclusion for the Rust version: is `SetWinEventHook` (or `WinEventProc` on
  `EVENT_OBJECT_SHOW` / `EVENT_SYSTEM_FOREGROUND`) mandatory, or is polling fine?

### 5. Does `focus_follows_mouse` via SPI work reliably?
*Confirmed working. Remaining questions are about edge cases and restore-on-exit.*
Grep: `Select-String "SPI " .\accordion.log` — look for `VERIFIED` vs `MISMATCH`.
- [ ] `SPI_SETACTIVEWINDOWTRACKING` read back as 1
- [ ] Autoraise (`SPI_SETACTIVEWNDTRKZORDER`) actually raises
- [ ] Hover focus is reliable, or flaky over: taskbar / drag-drop / menus / Alt-Tab
- [ ] Does hover-focus fight the monitor-centre cursor warp? (warp lands the pointer,
      X-mouse then focuses whatever is under it — should agree, but check the log)
- [ ] Is `MOUSE_TRK_TIMEOUT := 0` too twitchy when the pointer merely crosses a window?
- [ ] Does hover-focus work over elevated windows / UWP apps, or only some?
- [ ] Was it restored correctly on exit? (**check this** — leaving it on is hostile)
- [x] Both mouse behaviours are wanted permanently — the manual on/off hotkeys
      (`V`/`C`) were removed as clutter. They now follow accordion mode.
- [ ] Is mouse_follows_focus welcome, or does the pointer warp feel wrong on a wide setup?
- [ ] `MOUSE_FOLLOW_TARGET`: is monitor-centre right, or do you want window-centre / no warp at all?
- [ ] Does the "only warp across monitors" rule hold up, or do you want a warp on every focus change?

### 6. Do multi-monitor directional jumps land where I expect?
Open the debug dump and check the computed `neighbours: W= E= N= S=` line per monitor
against your physical arrangement.
- [ ] Neighbours match reality
- [ ] Non-rectangular / stacked arrangements resolve sensibly
- [ ] "No wrap-around" for directional jumps is right, or I want wrapping
- [ ] `o`/`p` prev/next display order (left-to-right by `left`) matches my mental order

### 7. Did `Ctrl+Win+L` survive?
Now the tiling no-op rather than display-east, so a failure costs nothing
functionally — but it is the canary for whether `Ctrl+Win` works as the stack
prefix at all.
- [ ] Registered without an error in the log (`HOTKEY FAILED:` absent)
- [ ] Actually fires (does not lock the screen or get swallowed)
- [ ] `Ctrl+Win+J/K/H` all reach the script
- If `Ctrl+Win` is unusable, chosen fallback prefix for `MOD_STACK`:

### 8. Other conflicts to verify
- [ ] `Ctrl+Win+H` (vs Win+H voice typing)
- [ ] `Ctrl+Win+K` (vs Win+K cast)
- [ ] `Ctrl+Alt+Win+H/J/K/L` (display jumps) all reach the script
- [ ] `Ctrl+Alt+Win+Space`, `+D`, `+P`, `+O`, `+V`, `+C` all reach the script
- [ ] Any app that steals one of these first:

### 9. Model-level questions the PoC exists to answer
- [ ] Does "only one window visible per monitor" actually work for my workflow,
      or do I keep wanting two side-by-side? Which pairs?
- [ ] With N monitors, is the per-monitor stack the right granularity, or do I
      want a global stack / tags / workspaces after all?
- [ ] Is the absence of workspaces painful?
- [ ] How often did I hit the global disable (`Ctrl+Alt+Win+Space`), and why?

---

## Verdict

**Does the accordion model work?** Yes — confirmed in real use, and close
enough to the yabai setup that it is now the daily driver rather than an
experiment.

**Is it worth rebuilding in Rust?** Not urgent any more. The AHK version is
sufficient for daily work, so the Rust daemon becomes a question of what it
would add rather than what it would rescue. Candidates:

- ~~Event hooks instead of polling~~ — **done in the AHK version**, since the
  lag was the one thing real use would not tolerate. A Rust version could go
  further and drop the backstop poll entirely.
- Tiling layouts, which were always out of scope here.
- Not needing an elevated interpreter running all session.

Must-haves for any future version, proved by this one:

- The DWM cloak check. Without it the stack fills with UWP ghost windows.
- Per-monitor-v2 DPI awareness before any coordinate maths.
- Never touching a window that is already correct, and never while a mouse
  button is down.
- Stable cycling (cycle index + suppressed promotion), or repeated presses
  bounce between two windows.
- Capture-and-restore for every system-wide setting, on every exit path.

Things to leave behind:

- The backstop poll, if hooks can be made complete enough to cover
  self-resizing and monitor-hopping windows.
- The `#32770` blanket exclusion, if a better dialog heuristic exists.

---

## Decisions

Choices made while implementing, where the brief left room or where reality
disagreed with it.

0. **Prefixes: `Ctrl+Win` = stack navigation, `Ctrl+Alt+Win` = display
   navigation and all other commands.** This inverts the brief's original
   mapping, at the user's request, on the reasoning that within-stack cycling
   is the far more frequent action and deserves the shorter chord. Side
   benefit: the at-risk `Ctrl+Win+L` binding is now the no-op rather than
   display-east.
1. **SPI constant values corrected.** The brief lists
   `SPI_SETACTIVEWINDOWTRACKING = 0x1002`, `SPI_SETACTIVEWNDTRKZORDER = 0x100C`
   and `SPI_GETACTIVEWINDOWTRACKING = 0x1001`. Per the Win32 headers the actual
   values are `GET/SET ACTIVEWINDOWTRACKING = 0x1000/0x1001`,
   `GET/SET ACTIVEWNDTRKZORDER = 0x100C/0x100D`,
   `GET/SET ACTIVEWNDTRKTIMEOUT = 0x2002/0x2003`. The brief's `0x1002` is
   `SPI_GETMENUANIMATION` and `0x100C` is the *get* for z-order tracking — using
   them would have silently toggled menu animation instead of X-mouse focus.
   The script uses the corrected values and read-back-verifies each one.
2. **Boolean/DWORD `SPI_SET*` calls pass the value by value in the `pvParam`
   slot** (`"ptr", value`) with `uiParam = 0`, while `SPI_GET*` passes a real
   pointer (`"uint*", &val`). Each set is logged with its read-back result.
3. **Navigation hotkeys stay live when accordion mode is off** (as the brief
   suggested). Disabling stops the scan timer, stops applying the fullscreen
   policy and turns mouse integration off; focus/move commands still work
   because they are harmless without the fullscreen policy.
4. **Original rects are snapshotted** on first management (position, size,
   maximized flag) — it was cheap. `Ctrl+Alt+Win+U` restores them all. This is
   *not* automatic on disable; disabling leaves windows as they are.
5. **`#32770` is ignored by default**, per the brief. Trade-off to evaluate:
   this excludes throwaway modals *and* some real app main windows (older
   Win32 apps, several installers, some Qt dialogs). If an app is missing from
   the stack, check the log for `SKIP[ignored-class]` before assuming a bug.
6. **Extra filter reasons beyond the brief**: `WS_EX_NOACTIVATE` windows,
   `WS_CHILD` windows, and windows that both lack `WS_CAPTION` *and* have an
   owner (`GetWindow(GW_OWNER)`) are excluded. A borderless top-level window
   with no owner is still included — erring on the side of managing it, per
   the brief's instruction to lean inclusive.
7. **`AutoHotkeyGUI` is in `IGNORED_CLASSES`** so the debug dump window doesn't
   join the stack it is reporting on.
8. **Filter-skip logging is edge-triggered** (logged once per window per
   reason, and never for the `no-title` case) — logging every rejection on
   every 400 ms tick produced tens of thousands of useless lines per minute.
9. **Extra binding `Ctrl+Alt+Win+U`** for "restore all", which the brief
   described but did not assign a key.
10. **Re-entrancy**: `ScanWindows` sets a `Scanning` flag for its whole body.
    It calls `Sleep(30)` on an activation retry, during which the timer would
    otherwise re-enter and double-process the same window set.
11. **Stable cycling** is implemented with a per-monitor `cycleIndex` plus a
    `SuppressPromote` hwnd: an activation caused by a cycle command does not
    reorder the stack, and the external-focus detector in the scan loop skips
    promotion for exactly that one window.
12. **mouse_follows_focus targets the monitor centre, not the window centre**
    (`MOUSE_FOLLOW_TARGET := "monitor"`), and only fires when focus moves to a
    *different* monitor. With every window fullscreen the two targets are
    nearly the same point, but the cross-monitor guard is what makes it
    pleasant: cycling the stack on one screen never touches the pointer. Set
    it to `"window"` for the original window-centre behaviour.
13. **mouse_follows_focus is ON at startup while X-mouse is OFF.** They are
    still toggled together by `V`/`C`, but the warp is harmless and useful on
    its own, whereas leaving X-mouse focus enabled is the risky half.
14. **X-mouse (focus_follows_mouse + autoraise) is enabled at startup**
    (`X_MOUSE_ON_START := true`), matching the yabai config. The safety
    trade-off is explicit: it is a system-wide setting, restored on every
    normal exit and on unhandled errors, but a `taskkill /F` will strand it
    on. Set the flag to `false` to opt in per session with `V` instead.
15. **`MOUSE_TRK_TIMEOUT` defaults to 0 ms**, per the brief.

## Not verified by the author of the code

The script was written on Linux; it has **not** been executed, syntax-checked
by AHK, or tested against real windows. What was done instead: every `DllCall`
signature checked against the Win32 documentation (pointer-vs-value for
`SystemParametersInfoW`, `DwmGetWindowAttribute` buffer sizes,
`SetProcessDpiAwarenessContext` fallback), and a manual read-through for
unhandled `Hotkey()` failures, missing `OnExit` restoration, and timer
re-entrancy. First run may still surface a load-time syntax error — if so,
note the line here and fix in place.
