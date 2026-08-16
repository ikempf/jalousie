# AGENTS.md

Guidance for AI agents working in this repository.

## What this is

A single-file AutoHotkey v2 proof-of-concept (`accordion.ahk`) reproducing a
yabai/skhd workflow on Windows 11: every window fullscreen, one visible per
monitor, keyboard-driven cycling through a per-monitor stack.

It is a **feasibility spike**, and it succeeded. The eventual plan is a proper
daemon in Rust. Treat the AHK code as disposable and `FINDINGS.md` as the
durable artefact — it records design decisions, real-world quirks, and the
requirements the Rust version must honour.

## Non-negotiables

- **AutoHotkey v2.0+ only.** Never emit v1 syntax. Every script starts with
  `#Requires AutoHotkey v2.0`.
- **No compiled components.** Pure `.ahk`.
- **No virtual desktop / workspace code.** `IVirtualDesktopManager` and other
  undocumented COM are explicitly out of scope.
- **No tiling layouts.** That is the Rust version's problem.
- Optimise for "evaluable in 30 minutes of real use", not architecture.
  Polling over hooks is fine. Duplication is fine. No abstractions "for later".

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
- The fullscreen policy is **never** applied while a mouse button is held, and
  never to a window already correct within `RECT_TOLERANCE`. Both rules exist
  to stop the manager fighting the user; violating either produces flicker and
  broken drags.
- Hotkeys are registered from the `BINDINGS` table via `Hotkey()`, never with
  `::` labels. A registration failure is caught, logged, and does not abort
  the remaining registrations.
- Stack cycling stability depends on the per-monitor `cycleIndex` plus the
  `SuppressPromote` hwnd. Do not let a cycle-initiated activation reorder the
  MRU stack.

## Instrumentation is a feature, not debug scaffolding

The log is the point of the PoC. Preserve and extend it. Anything unexpected —
an activation failure, a window that reverts its own size (`MISBEHAVING:`), a
filter rejection — gets logged with title + class + process. **Do not swallow
errors**; a surfaced failure is a finding.

Skip logging is edge-triggered (once per window per reason). Keep it that way;
logging every rejection on every 400 ms tick produces tens of thousands of
useless lines a minute.

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
| `accordion.ahk` | The entire PoC. Ordered: directives → config → state → bootstrap → handlers → core → Win32 helpers → logging → `OnExit`. |
| `README.md` | Install, run, full keybinding table, config reference, known Windows conflicts. |
| `FINDINGS.md` | Evaluation checklist plus the `## Decisions` log. Update `## Decisions` whenever you make a non-obvious choice or correct the spec. |
| `install-startup.ps1` | Registers a Scheduled Task to launch the script elevated at logon. Must be run elevated. Parse-check edits with `[System.Management.Automation.Language.Parser]::ParseFile`. |
| `sync-to-windows.sh` | Copies deliverables between the repo and the Windows-side working copy, both directions. |
| `accordion.log` | Runtime log, gitignored. |
