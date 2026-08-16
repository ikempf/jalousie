# AGENTS.md

Guidance for AI agents working in this repository.

## What this is

A single-file AutoHotkey v2 window manager (`accordion.ahk`) reproducing a
yabai/skhd workflow on Windows 11: every window fullscreen, one visible per
monitor, keyboard-driven cycling through a per-monitor stack.

**This is working software in daily use.** It starts at logon via a Scheduled
Task and the user works under it all day, so any regression is felt within
minutes. Do not casually restructure it. It is feature complete for its
purpose; tiling layouts are the only likely future addition, and they are not
committed to.

## Non-negotiables

- **AutoHotkey v2.0+ only.** Never emit v1 syntax. Every script starts with
  `#Requires AutoHotkey v2.0`.
- **No compiled components.** Pure `.ahk`.
- **No virtual desktop / workspace code.** `IVirtualDesktopManager` and other
  undocumented COM are explicitly out of scope.
- **No tiling layouts.** That is the Rust version's problem.
- Polling over hooks is fine, duplication is fine, no abstractions "for later".
  The simplicity is deliberate; it is also why it works. Do not add structure
  the current feature set does not need.

## The AHK v2 trap that will bite you

**v2 has no super-globals.** A top-level `global X := 1` does *not* make `X`
writable from inside a function. Within a function, v2 will happily *read* an
undeclared global — but the moment the function *assigns* to that name,
the name is local for the entire function body.

Two failure modes:

- Reading before the local is assigned → runtime error
  *"This local variable has not been assigned a value"*.
- Assigning only → **silent** failure. The global never changes. This is how
  the saved `SystemParametersInfo` values were being written into locals, which
  would have left the user's system settings unrestored on exit.

**Every function that assigns to a global must declare it.** After any edit,
re-run this audit:

```bash
python3 - <<'PY'
import re
src=open('accordion.ahk',encoding='utf-8').read(); lines=src.split('\n')
g=set(re.findall(r'^global\s+(\w+)',src,re.M)); i=0; funcs=[]
while i<len(lines):
    m=re.match(r'^([A-Za-z_]\w*)\(.*\)\s*\{\s*$',lines[i])
    if m:
        st=i; d=1; i+=1
        while i<len(lines) and d>0:
            c=re.sub(r'"[^"]*"','',lines[i]); d+=c.count('{')-c.count('}'); i+=1
        funcs.append((m.group(1),st,i))
    else: i+=1
bad=[]
for n,a,b in funcs:
    body=lines[a:b]; dec=set()
    for l in body:
        d=re.match(r'\s*global\s+([\w,\s]+)$',l)
        if d: dec|={x.strip() for x in d.group(1).split(',')}
    for k,l in enumerate(body,a+1):
        m=re.match(r'\s*(\w+)\s*(:=|\+\+|--|\.=|\+=|-=)',l)
        if m and m.group(1) in g and m.group(1) not in dec: bad.append((n,k,l.strip()))
print("undeclared global assignments:", bad or "none")
PY
```

It only scans named functions declared as `Name(...) {` on their own line —
inline arrow closures need checking by hand. Note that *item* assignment
(`SomeMap[k] := v`) is a read of the variable, not an assignment to it, and
needs no declaration.

## Other AHK v2 syntax hazards seen here

- A continuation line must **begin with an operator**. A line starting with
  `(` opens a continuation *section* instead, which parses but does something
  entirely different. Prefix wrapped string concatenation with `. `.
- Keep the file **ASCII**. It has no UTF-8 BOM, so non-ASCII literals are
  mis-decoded.
- `/validate` catches syntax only. It will not catch the global-scope bug
  above, or any `DllCall` signature error.

## Win32 correctness

Wrong `DllCall` types fail *silently* — this is the single largest source of
bugs in a script like this. Check signatures against the actual Win32
documentation, never against memory.

Specifically for `SystemParametersInfoW`:

- `SPI_GET*` for a BOOL/DWORD takes a **pointer** in `pvParam` (`"uint*", &v`).
- `SPI_SET*` for a BOOL/DWORD passes the value **by value** in the `pvParam`
  slot (`"ptr", value`) with `uiParam = 0`.
- Get the constants right. The values are
  `GET/SET ACTIVEWINDOWTRACKING = 0x1000/0x1001`,
  `GET/SET ACTIVEWNDTRKZORDER = 0x100C/0x100D`,
  `GET/SET ACTIVEWNDTRKTIMEOUT = 0x2002/0x2003`,
  `GET/SET FOREGROUNDLOCKTIMEOUT = 0x2000/0x2001`.
  Off-by-one here silently toggles menu animation instead of hover-focus.
- **Always read the value back and log the result.** `SpiSetValue()` does this;
  use it rather than a bare `DllCall`.

Any system-wide setting the script changes must be captured at startup and
restored in `OnExit` — leaving X-mouse focus enabled after the script dies is
a genuinely hostile bug.

## Invariants to preserve when editing

- `Ctrl+Alt+Win+Q` (emergency exit) is registered **first**, and its handler
  depends on nothing but the saved SPI globals. Keep it that way.
- `OnExit` restores system settings on every path, including unhandled errors.
- `ScanWindows` is guarded by the `Scanning` re-entrancy flag; it calls
  `Sleep()` internally, during which the poll timer would otherwise re-enter.
- `WinEventProc` runs during message dispatch. It must stay cheap, must never
  throw, and must not do the work itself — it only schedules `ScanSoon`. Keep
  `ScanSoon` a distinct function object from `ScanWindows`, or `SetTimer` will
  replace the periodic poll instead of adding a one-shot alongside it.
- `WinEventCallback` must stay referenced by a global or it is collected while
  Windows still holds the pointer. Every hook handle is unhooked in `OnExit`.
- The poll is a **backstop, not dead code**. The hooks miss windows that resize
  or change monitor on their own. Do not remove it when tempted.
- The fullscreen policy is **never** applied while a mouse button is held, and
  never to a window already correct within `RECT_TOLERANCE`. Both rules exist
  to stop the manager fighting the user; violating either produces flicker and
  broken drags.
- `SetAccordion()` is the single on/off path: it starts or stops the scan and
  both mouse behaviours together. Anything that needs the manager to stand down
  must go through it, not flip `ACCORDION_ENABLED` directly. `Cmd_RestoreAll`
  depends on this — restoring window rects while the scan is live just
  re-maximizes them within one tick.
- Hotkeys are registered from the `BINDINGS` table via `Hotkey()`, never with
  `::` labels. A registration failure is caught, logged, and does not abort
  the remaining registrations.
- Stack cycling stability depends on the per-monitor `cycleIndex` plus the
  `SuppressPromote` hwnd. Do not let a cycle-initiated activation reorder the
  MRU stack.

## Instrumentation is a feature, not debug scaffolding

The log is how anything gets diagnosed here — there are no tests and no way to
reproduce a window-manager bug on demand. Preserve and extend it. Anything unexpected —
an activation failure, a window that reverts its own size (`MISBEHAVING:`), a
filter rejection — gets logged with title + class + process. **Do not swallow
errors**; a surfaced failure is a finding.

Skip logging is edge-triggered (once per window per reason). Keep it that way;
logging every rejection on every poll tick produces tens of thousands of
useless lines a minute.

## Why the non-obvious bits are the way they are

Rationale that is not derivable from the code, and that has already been paid
for once:

- **`#32770` is ignored wholesale.** It is the standard Win32 dialog class, so
  ignoring it keeps throwaway modals out of the stack — but it also excludes
  some real main windows (older Win32 apps, installers, Qt dialogs). A better
  dialog heuristic would be a genuine improvement; a naive un-ignore is not.
- **Filter-skip logging is edge-triggered**, once per window per reason, and
  never for `no-title`. Logging every rejection every tick produced tens of
  thousands of useless lines a minute.
- **`mouse_follows_focus` targets the monitor centre, not the window centre**,
  and fires only when focus crosses to a different monitor. With everything
  fullscreen the two targets nearly coincide; the cross-monitor guard is what
  makes it pleasant, because cycling a stack never touches the pointer.
- **Navigation hotkeys stay live when accordion mode is off.** They are
  harmless without the fullscreen policy, and it means the disable switch does
  not cost you focus control.
- **`AutoHotkeyGUI` is in `IGNORED_CLASSES`** so the debug window does not join
  the stack it is reporting on.
- **Original rects are snapshotted on first management**, which is what makes
  `Ctrl+Alt+Win+U` possible. Disabling alone does not restore them.
- **Elevation is required, not optional.** UIPI blocks a non-elevated process
  from touching windows owned by elevated ones. The Scheduled Task exists to
  supply that without a UAC prompt at every logon.

## Testing

The script can only be meaningfully tested on Windows with AHK v2 installed,
by a human, interactively. If you are working in WSL or any Linux environment:

- You **cannot** verify behaviour. Say so plainly rather than implying you did.
- Do the checks you actually can: the global-scope audit above, brace balance,
  `DllCall` signatures against documentation, and a read-through for the
  invariants listed above.
- The user's Windows-side working copy is `C:\Users\iljak\accordion\`, reachable
  from WSL at `/mnt/c/Users/iljak/accordion/`. It is what the Scheduled Task
  actually runs. **Nothing syncs automatically** — run `./sync-to-windows.sh`
  after editing, and tell the user to reload with `Ctrl+Alt+Win+R`. Use
  `./sync-to-windows.sh --back` to pull in edits they made on the Windows side
  before you commit. The git repo remains the source of truth.

## Files

| File | Role |
|---|---|
| `accordion.ahk` | The whole thing. Ordered: directives → config → state → bootstrap → handlers → core → Win32 helpers → logging → `OnExit`. |
| `README.md` | Install, run, full keybinding table, config reference, known Windows conflicts. |
| `install-startup.ps1` | Registers a Scheduled Task to launch the script elevated at logon. Must be run elevated. Parse-check edits with `[System.Management.Automation.Language.Parser]::ParseFile`. |
| `sync-to-windows.sh` | Copies deliverables between the repo and the Windows-side working copy, both directions. |
| `accordion.log` | Runtime log, gitignored. |
