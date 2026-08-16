# accordion.ahk

A disposable AutoHotkey v2 proof-of-concept for a **keyboard-driven accordion
window manager** on Windows 11: every managed window is fullscreen on its
monitor, only one is visible at a time, and you cycle through a per-monitor
stack — the yabai/skhd "everything is fullscreen, cycle the stack" model.

It was built to answer *"does this interaction model feel good with my real
apps on my real monitors?"* before any of it gets written properly in Rust.
The answer so far is yes — see `FINDINGS.md`, which is the actual deliverable
of the exercise and doubles as the requirements list for the Rust version.

---

## Quick start

```powershell
winget install AutoHotkey.AutoHotkey     # once
AutoHotkey64.exe .\accordion.ahk         # accept the UAC prompt
```

Then: `Ctrl+Win+J` / `Ctrl+Win+K` cycle the windows on the current screen,
`Ctrl+Alt+Win+H/J/K/L` jump between screens, `Ctrl+Alt+Win+Q` quits and puts
every system setting back.

## What it does

- Every managed window is **maximized** to fill its monitor's work area.
- Only one is visible per monitor; the rest sit behind it in z-order.
- Each monitor has its own **stack**, ordered most-recently-focused first.
  `Ctrl+Win+J`/`K` walk it; repeated presses walk the whole stack rather than
  bouncing between the top two.
- New windows are maximized, pushed to the front of their monitor's stack, and
  focused.
- Moving focus to another monitor takes the **cursor** with it (to that
  monitor's centre), and **hovering** a window focuses and raises it.
- Nothing is persisted. Quit the script and Windows is exactly as it was,
  except that windows stay maximized (`Ctrl+Alt+Win+U` undoes that).

---

## Emergency exit: `Ctrl + Alt + Win + Q`

This is the first hotkey registered and its handler depends on nothing else in
the script. It restores every `SystemParametersInfo` value the script changed
(foreground lock timeout, active-window tracking, autoraise, tracking timeout)
and exits.

If the script is somehow unresponsive, right-click the AHK tray icon → Exit,
or `taskkill /IM AutoHotkey64.exe`. `OnExit` restores the system settings on
every exit path, including unhandled errors — but a hard kill (`/F`) will not
run it, in which case turn X-mouse focus off manually in
*Settings → Accessibility → Mouse* / `Control Panel → Ease of Access → Make
the mouse easier to use → "Activate a window by hovering over it"`.

---

## Install

AutoHotkey **v2.0+** is required. It is not installed for you.

```powershell
winget install AutoHotkey.AutoHotkey
```

Verify: `AutoHotkey64.exe /version` should print `2.x`.

## Run

```powershell
AutoHotkey64.exe .\accordion.ahk
```

or just double-click `accordion.ahk` once AHK v2 is the registered handler.

On start the script tries to **relaunch itself elevated** (`*RunAs`). Windows'
UIPI prevents a non-elevated process from moving or activating windows owned by
elevated processes, so without this, any admin app silently refuses to be
managed. Decline the UAC prompt and it keeps running non-elevated, warns you,
and logs it. Set `AUTO_ELEVATE := false` in the config block to stop asking.

### Run it at login

`Win+R` → `shell:startup` → put a shortcut to `accordion.ahk` in that folder.
Because the script elevates itself, that produces a UAC prompt at every login.
To avoid it, create a Task Scheduler task instead:

```powershell
$exe = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$ahk = "$HOME\accordion\accordion.ahk"
$action  = New-ScheduledTaskAction -Execute $exe -Argument "`"$ahk`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$princ   = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
Register-ScheduledTask -TaskName "accordion" -Action $action -Trigger $trigger -Principal $princ
```

Set `AUTO_ELEVATE := false` in the script when you do this — the task already
runs elevated, and the script's own `*RunAs` relaunch would be redundant.

---

## Keybindings

`MOD_STACK` = `Ctrl+Win` (`^#`) · `MOD_DISPLAY` = `MOD_ACTION` = `Ctrl+Alt+Win` (`^!#`)

| Keys | Action |
|---|---|
| `Ctrl+Win+J` | Focus **next** window in the current monitor's stack |
| `Ctrl+Win+K` | Focus **previous** window in the current monitor's stack |
| `Ctrl+Win+H` | No-op in accordion mode (logged). Reserved for tiling. |
| `Ctrl+Win+L` | No-op in accordion mode (logged). Reserved for tiling. |
| `Ctrl+Alt+Win+H` | Focus display **west**, landing on its last-focused window |
| `Ctrl+Alt+Win+L` | Focus display **east** |
| `Ctrl+Alt+Win+J` | Focus display **south** |
| `Ctrl+Alt+Win+K` | Focus display **north** |
| `Ctrl+Alt+Win+O` | Move focused window to **previous** display and follow it |
| `Ctrl+Alt+Win+P` | Move focused window to **next** display and follow it |
| `Ctrl+Alt+Win+Space` | Toggle accordion mode on/off |
| `Ctrl+Alt+Win+C` | Mouse integration **OFF** |
| `Ctrl+Alt+Win+V` | Mouse integration **ON** |
| `Ctrl+Alt+Win+D` | Debug dump — GUI + log (press again to close) |
| `Ctrl+Alt+Win+U` | Restore all windows to their pre-management rects |
| `Ctrl+Alt+Win+R` | Reload the script |
| `Ctrl+Alt+Win+Q` | **Emergency exit** |

Remap by editing `MOD_STACK` / `MOD_DISPLAY` / `MOD_ACTION` and the `BINDINGS`
table at the top of the file. `MOD_DISPLAY` and `MOD_ACTION` are the same
prefix today; they are separate constants so directional display jumps can be
moved off `Ctrl+Alt+Win` without disturbing the command keys.

There are no `::` hotkey labels anywhere in the script — every binding is
registered at runtime through `Hotkey()` from the `BINDINGS` table, so adding
or moving one is a single line. A binding that Windows refuses is logged as
`HOTKEY FAILED:` and the rest still load.

### Known Windows shortcut conflicts

- **`Win+L` (lock) cannot be overridden.** `Ctrl+Win+L` is now the *tiling
  no-op*, so if Windows swallows it you lose nothing — but **test it
  explicitly** anyway, because it tells you whether `Ctrl+Win` is a viable
  prefix at all. If it locks the screen, move `MOD_STACK` to something else
  (`^!` Ctrl+Alt is the obvious candidate) and record it in `FINDINGS.md`.
- `Ctrl+Win+Left/Right/D/F4` are virtual-desktop shortcuts. Unused here, but
  avoid them when remapping.
- `Win+H` (voice typing), `Win+G` (Game Bar), `Win+K` (Cast), `Win+P`
  (Project), `Win+X` (power menu): adding `Ctrl` normally frees them, but
  `Ctrl+Win+H`/`K`/`P` are worth a deliberate test.
- Terminals, IDEs and Electron apps often grab `Ctrl+Alt+<letter>` internally.
  Hotkeys registered by AHK win over app-level handling, so this is usually
  the other way round: **we** may steal something your editor wanted.

---

## Configuration

Everything you'd want to change is in the config block at the top of
`accordion.ahk`.

| Constant | Default | Meaning |
|---|---|---|
| `FULLSCREEN_MODE` | `"maximize"` | `"maximize"` uses `WinMaximize` (Windows handles the invisible DWM border). `"workarea"` uses `WinMove` onto the monitor work area with an extended-frame-bounds correction. |
| `POLL_INTERVAL_MS` | `400` | Window discovery poll period |
| `MIN_WIN_W` / `MIN_WIN_H` | `200` | Windows smaller than this are ignored |
| `RECT_TOLERANCE` | `4` | Slack (px) before a window is re-fullscreened |
| `FOCUS_NEW_WINDOWS` | `true` | Activate newly detected windows |
| `AUTO_ELEVATE` | `true` | Relaunch as admin at startup |
| `MOUSE_TRK_TIMEOUT` | `0` | Hover delay before focus follows the mouse (ms) |
| `X_MOUSE_ON_START` | `true` | Enable hover-focus + autoraise at startup |
| `MOUSE_FOLLOW_TARGET` | `"monitor"` | Where the cursor is parked on focus change: `"monitor"` centre (cross-monitor only) or `"window"` centre |
| `LOG_SKIPS` | `true` | Log filter rejections (once per window per reason) |

**Ignore lists** are plain arrays right below: `IGNORED_CLASSES` and
`IGNORED_PROCESSES`. Add a class or process name and reload (`Ctrl+Alt+Win+R`).
The debug dump and the log tell you the exact class/process of anything
misbehaving, so the loop is: press `D`, copy the class, paste it into the array.

Note `#32770` (the standard Win32 dialog class) is ignored by default. This
keeps modals out of the stack but also excludes some real app main windows.
See `FINDINGS.md`.

---

## Mouse integration

- **mouse_follows_focus** — **on by default**. After any focus change we make,
  the cursor is warped. `MOUSE_FOLLOW_TARGET` picks where:
  - `"monitor"` (default) — centre of the focused window's monitor work area,
    and *only* when focus lands on a different monitor. Cycling the stack
    within one screen leaves your pointer where it was.
  - `"window"` — centre of the focused window, unless the cursor is already
    inside it.

- **focus_follows_mouse + autoraise** — **on by default**
  (`X_MOUSE_ON_START := true`). Hovering a window focuses it and raises it,
  the yabai `focus_follows_mouse autoraise` behaviour. This is Windows' own
  X-mouse feature driven via `SystemParametersInfoW`
  (`SPI_SETACTIVEWINDOWTRACKING`, `SPI_SETACTIVEWNDTRKZORDER`,
  `SPI_SETACTIVEWNDTRKTIMEOUT`), not a mouse hook. `MOUSE_TRK_TIMEOUT`
  (default `0`) is the hover delay in ms — raise it to ~200 if focus feels
  twitchy when the pointer crosses a window on its way somewhere else.

  This is a **system-wide Windows setting**, not a property of this script.
  It is restored on every normal exit and on unhandled errors, but a hard kill
  (`taskkill /F`, a crash of the AHK host) will leave it on. Set
  `X_MOUSE_ON_START := false` if you would rather opt in per session with
  `Ctrl+Alt+Win+V`.

`Ctrl+Alt+Win+V` and `Ctrl+Alt+Win+C` turn **both** halves on and off
together. Both are on at startup.

The original values are captured before the first enable and restored on exit.
Every SPI call is logged with a read-back verification (`VERIFIED` /
`MISMATCH` / `FAILED`) — check the log if hover-focus doesn't behave.

---

## Log

`.\accordion.log`, next to the script, appended, timestamped to the
millisecond. It records: startup (AHK version, admin, DPI path), every hotkey
registration, every command, `ADD:` / `REMOVE:` / `MOVED:` window events,
`SKIP[reason]:` filter rejections, `ACTIVATE FAILED:`,
`FULLSCREEN FAILED:`, `MISBEHAVING:` (a window that undid its own fullscreen
within two poll ticks), every SPI call with its verification, and the full
debug dump.

Tail it while you work:

```powershell
Get-Content .\accordion.log -Wait -Tail 40
```

Delete the file whenever you want a clean run — it is recreated on the next
write.

---

## Known shortcuts taken in this PoC

- Window discovery is a **400 ms polling timer**, not `SetWinEventHook`.
- Monitors are identified by AHK index; a window's monitor is whichever
  monitor contains its rect centre. No `HMONITOR` mapping.
- No virtual-desktop awareness, no tiling, no gaps/borders, no persistence.
