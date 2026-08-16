#!/usr/bin/env bash
# Copy the deliverables from this repo to the Windows-side working copy.
#
# The repo lives in the WSL filesystem; AutoHotkey runs on the Windows side and
# the Scheduled Task points at the Windows copy. Nothing syncs automatically --
# run this after editing, then reload the script with Ctrl+Alt+Win+R.
#
#   ./sync-to-windows.sh              # default destination
#   ./sync-to-windows.sh /mnt/c/tools/accordion
#   ./sync-to-windows.sh --back       # pull Windows-side edits into the repo

set -euo pipefail

DEST_DEFAULT="/mnt/c/Users/$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n')/accordion"
FILES=(accordion.ahk install-startup.ps1 README.md AGENTS.md)

cd "$(dirname "$0")"

BACK=false
if [[ "${1:-}" == "--back" ]]; then BACK=true; shift; fi
DEST="${1:-$DEST_DEFAULT}"

if [[ ! -d "$DEST" ]]; then
    if $BACK; then
        echo "error: source '$DEST' does not exist" >&2
        exit 1
    fi
    echo "creating $DEST"
    mkdir -p "$DEST"
fi

if $BACK; then
    echo "pulling from $DEST"
    for f in "${FILES[@]}"; do
        [[ -f "$DEST/$f" ]] || continue
        if ! cmp -s "$DEST/$f" "$f"; then
            cp "$DEST/$f" "$f"
            echo "  <- $f"
        fi
    done
    echo
    echo "done. review with: git diff"
    exit 0
fi

echo "syncing to $DEST"
changed=0
for f in "${FILES[@]}"; do
    if [[ ! -f "$DEST/$f" ]] || ! cmp -s "$f" "$DEST/$f"; then
        cp "$f" "$DEST/$f"
        echo "  -> $f"
        changed=$((changed + 1))
    fi
done

if [[ $changed -eq 0 ]]; then
    echo "  (already up to date)"
else
    echo
    echo "$changed file(s) updated. Reload the running script with Ctrl+Alt+Win+R."
fi
