#!/bin/bash
# Dev-only, not part of the release: opens ./build/KeepNote.app (closing a running one),
# opens All Notes and has rowclick click <clicks> rows with real mouse events.
#   abc.sh <label> <clicks> [app args...]
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/KeepNote.app"
TOOL="$ROOT/build/rowclick"
# Needs the Accessibility permission of the terminal that runs it.
[ "$TOOL" -nt "$ROOT/Scripts/dev/rowclick.swift" ] \
    || swiftc -sdk "$(xcode-select -p)/SDKs/MacOSX.sdk" "$ROOT/Scripts/dev/rowclick.swift" -o "$TOOL"
label=$1; n=$2; shift 2
pkill -x KeepNote; sleep 1.5
if [ $# -gt 0 ]; then open -n "$APP" --args "$@"; else open -n "$APP"; fi
sleep 3
osascript -e 'tell application "System Events" to tell process "KeepNote" to click menu item "All Notes" of menu "File" of menu bar 1' >/dev/null
sleep 1.5
echo "== $label"
"$TOOL" run "$(pgrep -x KeepNote)" "$n" 1.0
