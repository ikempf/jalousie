# accordion.ahk

A **keyboard-driven accordion window manager** for Windows 11, in AutoHotkey v2:
every managed window is fullscreen on its monitor, only one is visible at a
time, and you cycle through a per-monitor stack — the yabai/skhd "everything is
fullscreen, cycle the stack" model.

- Every managed window is maximized to fill its monitor's work area.
- Only one is visible per monitor; the rest sit behind it in z-order.
- Each monitor has its own stack, ordered most-recently-focused first.
  Repeated presses walk the whole stack rather than bouncing between the top two.
- New windows are maximized, pushed to the front of the stack, and focused.
- Moving focus to another monitor takes the cursor with it; hovering a window
  focuses and raises it.

---

## Shortcuts

| Keys                   | Action                                                                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `Ctrl+Win+J` / `K`     | Focus next / previous window in the current monitor's stack                                                              |
| `Ctrl+Win+H` / `L`     | No-op today. Reserved for tiling.                                                                                        |
| `Ctrl+Alt+Win+H` / `L` | Focus display west / east, landing on its last-focused window                                                            |
| `Ctrl+Alt+Win+J` / `K` | Focus display south / north                                                                                              |
| `Ctrl+Alt+Win+O` / `P` | Move focused window to previous / next display and follow it                                                             |
| `Ctrl+Alt+Win+Space`   | Accordion off: scanning and both mouse behaviours stop, windows stay put, navigation still works. Press again to resume. |
| `Ctrl+Alt+Win+U`       | The same, plus every window goes back to the position, size and maximized state it had when the manager first saw it     |
| `Ctrl+Alt+Win+D`       | Debug dump — GUI + log (press again to close)                                                                            |
| `Ctrl+Alt+Win+R`       | Reload the script                                                                                                        |
| `Ctrl+Alt+Win+Q`       | Quit, restoring every system setting the script changed                                                                  |

`Ctrl+Alt+Win+Q` is the emergency exit: it is registered first and its handler
depends on nothing else. If the script is unresponsive, right-click the AHK tray
icon → Exit, or `taskkill /IM AutoHotkey64.exe`. A hard kill (`/F`) skips the
restore, in which case turn hover-focus off manually in
_Settings → Accessibility → Mouse_.

Remap by editing `MOD_STACK` / `MOD_DISPLAY` / `MOD_ACTION` and the `BINDINGS`
table at the top of the file.

**Conflicts:** some shortcuts are reserved by Windows, such as `Win+L`.\
Those cannot be remapped or overridden.

---

## Install

AutoHotkey **v2.0+** is required:

```powershell
winget install AutoHotkey.AutoHotkey
```

Try it out by double-clicking `accordion.ahk` in Explorer (the installer
registers the file association) and accepting the UAC prompt. `Ctrl+Alt+Win+Q`
quits and puts everything back.

### Run it at login

`install-startup.ps1` registers a Scheduled Task that starts the script at every
logon with highest privileges — so no UAC prompt, ever. Run it once from an
elevated PowerShell ("Terminal (Admin)"):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-startup.ps1
Start-ScheduledTask -TaskName accordion    # start now, without logging out
```

Switches: `-DelaySeconds 30` (default 15), `-ScriptPath`, `-AhkPath`,
`-TaskName`, `-Uninstall`.

If you keep the repo in WSL, `./sync-to-windows.sh` copies changed files to the
Windows side; then reload with `Ctrl+Alt+Win+R`.

---

## Configuration

Everything you'd want to change is in the config block at the top of
`accordion.ahk`.

| Constant                  | Default      | Meaning                                                                                                                                                                      |
| ------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FULLSCREEN_MODE`         | `"maximize"` | `"maximize"` uses `WinMaximize` (Windows handles the invisible DWM border). `"workarea"` uses `WinMove` onto the monitor work area with an extended-frame-bounds correction. |
| `POLL_INTERVAL_MS`        | `150`        | Window discovery poll period (backstop; the hooks do the fast path)                                                                                                          |
| `USE_WIN_EVENT_HOOK`      | `true`       | React to window creation via `SetWinEventHook` instead of waiting for the next poll                                                                                          |
| `EVENT_DEBOUNCE_MS`       | `40`         | Settle time after a window event before scanning                                                                                                                             |
| `MIN_WIN_W` / `MIN_WIN_H` | `200`        | Windows smaller than this are ignored                                                                                                                                        |
| `RECT_TOLERANCE`          | `4`          | Slack (px) before a window is re-fullscreened                                                                                                                                |
| `FOCUS_NEW_WINDOWS`       | `true`       | Activate newly detected windows                                                                                                                                              |
| `AUTO_ELEVATE`            | `true`       | Relaunch as admin at startup                                                                                                                                                 |
| `MOUSE_TRK_TIMEOUT`       | `0`          | Hover delay before focus follows the mouse (ms)                                                                                                                              |
| `X_MOUSE_ON_START`        | `true`       | Enable hover-focus + autoraise at startup                                                                                                                                    |
| `MOUSE_FOLLOW_TARGET`     | `"monitor"`  | Where the cursor is parked on focus change: `"monitor"` centre (cross-monitor only) or `"window"` centre                                                                     |
| `LOG_SKIPS`               | `true`       | Log filter rejections (once per window per reason)                                                                                                                           |

**Ignore lists** are plain arrays right below: `IGNORED_CLASSES` and
`IGNORED_PROCESSES`. Add a class or process name and reload (`Ctrl+Alt+Win+R`).
The debug dump and the log tell you the exact class/process of anything
misbehaving, so the loop is: press `D`, copy the class, paste it into the array.

Note `#32770` (the standard Win32 dialog class) is ignored by default. This
keeps throwaway modals out of the stack, at the cost of also excluding the
occasional real main window — some older Win32 apps, installers and Qt dialogs
use the same class. If an app never joins the stack, check the log for
`SKIP[ignored-class]` before assuming a bug.

---

## Mouse integration

- **mouse_follows_focus** — **on by default**. After any focus change we make,
  the cursor is warped. `MOUSE_FOLLOW_TARGET` picks where:
  - `"monitor"` (default) — centre of the focused window's monitor work area,
    and _only_ when focus lands on a different monitor. Cycling the stack
    within one screen leaves your pointer where it was.
  - `"window"` — centre of the focused window, unless the cursor is already
    inside it.

- **focus_follows_mouse + autoraise** — **on by default**
  (`X_MOUSE_ON_START := true`). Hovering a window focuses and raises it, the
  yabai `focus_follows_mouse autoraise` behaviour. This is Windows' own X-mouse
  feature driven via `SystemParametersInfoW`, not a mouse hook.
  `MOUSE_TRK_TIMEOUT` (default `0`) is the hover delay in ms — raise it to ~200
  if focus feels twitchy when the pointer crosses a window on its way elsewhere.

  Being a **system-wide Windows setting**, it is restored on every normal exit
  and on unhandled errors, but a hard kill will leave it on.

Both follow the manager: turning accordion off turns them off too, and turning
it back on restores them.

---

## Log

`.\accordion.log`, next to the script, appended, timestamped to the
millisecond. It records startup, hotkey registration, every command,
`ADD:` / `REMOVE:` / `MOVED:` window events, `SKIP[reason]:` filter rejections,
failures, every SPI call with its read-back verification, and the debug dump.

```powershell
Get-Content .\accordion.log -Wait -Tail 40
```

Delete it whenever you want a clean run — it is recreated on the next write.

---

## Scope

Deliberately not included:

- **Tiling layouts.** Maybe later — the accordion model works well without them.
- **Virtual desktops / workspaces.** They would mean undocumented COM.
- Gaps, borders, animations, a status bar, a config GUI.
- Persistence across restarts.

Implementation notes worth knowing:

- Monitors are identified by AHK index; a window's monitor is whichever monitor
  contains its rect centre. No `HMONITOR` mapping.
- The script runs elevated so it can manage windows owned by elevated processes
  (UIPI). Without that, admin apps silently refuse to be managed.
