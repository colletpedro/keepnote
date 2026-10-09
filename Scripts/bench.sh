#!/bin/bash
#
# Measures how long the main thread is blocked while notes are created,
# imported and synced, and while the deck, the peek and a note are used.
# Compiles the app's sources (minus its @main) with Scripts/Benchmark/main.swift
# into a command-line tool, optimised like the installed build. Everything
# runs against a temporary database and a temporary sync folder; the real
# notes, the Keychain and the real sync folder are never touched, and no window
# is put on screen.
#
#   ./Scripts/bench.sh                 50 and 200 notes
#   ./Scripts/bench.sh 500             other sizes
#   KEEPNOTE_BENCH_JSON=out.json       also write the results as JSON
#   KEEPNOTE_BENCH_BEFORE=before.json  print a before/after table against it
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/bench"
mkdir -p "$BUILD"

DEVELOPER_DIR_PATH="$(xcode-select -p)"
SDK="${KEEPNOTE_SDK:-}"
if [ -z "$SDK" ]; then
    for candidate in \
        "$DEVELOPER_DIR_PATH/SDKs/MacOSX.sdk" \
        "$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    do
        if [ -d "$candidate" ]; then SDK="$candidate"; break; fi
    done
    SDK="${SDK:-$(xcrun --show-sdk-path)}"
fi

EXTRA=()
SWIFT_INCLUDE="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
if [ -f "$SWIFT_INCLUDE/module.modulemap" ] && [ -f "$SWIFT_INCLUDE/bridging.modulemap" ]; then
    : > "$BUILD/empty.modulemap"
    cat > "$BUILD/modulemap-overlay.yaml" <<YAML
{ "version": 0, "roots": [ { "name": "$SWIFT_INCLUDE", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file",
                  "external-contents": "$BUILD/empty.modulemap" } ] } ] }
YAML
    EXTRA+=(-Xcc -ivfsoverlay -Xcc "$BUILD/modulemap-overlay.yaml")
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
    find "$ROOT/Sources" -name '*.swift' ! -name 'KeepNoteApp.swift' | sort)

swiftc \
    -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx13.0" \
    -swift-version 5 \
    -module-name KeepNote \
    -module-cache-path "$BUILD/module-cache" \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    -O -whole-module-optimization \
    -framework AppKit -framework SwiftUI -framework Carbon -framework CryptoKit \
    -framework Security -framework UniformTypeIdentifiers \
    -framework CoreServices -framework ServiceManagement -lsqlite3 \
    -o "$BUILD/keepnote-bench" \
    "${SOURCES[@]}" "$ROOT/Scripts/Benchmark/main.swift"

"$BUILD/keepnote-bench" "$@"
