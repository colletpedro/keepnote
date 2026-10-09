#!/bin/bash
#
# Compiles the editor's pure logic (Sources/KeepNote/Core/{TextEdit,ListEditing,
# Formatting,TagText,TagLibrary,...}.swift — Foundation only, no AppKit) together with the
# tests in ./Tests, runs them, and fails if any case fails.
#
# Then the store, sync and note-window tests in ./Tests/Integration, which need
# the whole app: its sources (minus its @main) are compiled with them into a
# second runner. They use temporary databases and folders, put no window on
# screen and never touch the real notes or the Keychain.
#
#   ./Scripts/test.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/tests"
mkdir -p "$OUT"

LOGIC=()
for name in TextEdit ListEditing Formatting BlockEditing TagText TagLibrary DailyNotes NotePalette SaveStatus PreviewText SearchText DeckGeometry TabLabel Spring FrameRestore DockPolicy FloatDrag LegacyDefaults DeckPins AutoArchive; do
    file="$ROOT/Sources/KeepNote/Core/$name.swift"
    [ -f "$file" ] && LOGIC+=("$file")
done
# The deck's geometry is built from these numbers.
LOGIC+=("$ROOT/Sources/KeepNote/UI/AppKit/EdgeMetrics.swift")

TESTS=()
while IFS= read -r file; do TESTS+=("$file"); done < <(find "$ROOT/Tests" -name '*.swift' -not -path '*/Integration/*' | sort)

# Same SDK/overlay story as build.sh, kept in step with it.
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
    : > "$OUT/empty.modulemap"
    cat > "$OUT/modulemap-overlay.yaml" <<YAML
{ "version": 0, "roots": [ { "name": "$SWIFT_INCLUDE", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file",
                  "external-contents": "$OUT/empty.modulemap" } ] } ] }
YAML
    EXTRA+=(-Xcc -ivfsoverlay -Xcc "$OUT/modulemap-overlay.yaml")
fi

swiftc \
    -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx13.0" \
    -swift-version 5 \
    -module-cache-path "$OUT/module-cache" \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    -o "$OUT/run-tests" \
    "${LOGIC[@]}" "${TESTS[@]}"

"$OUT/run-tests"

APP_SOURCES=()
while IFS= read -r file; do APP_SOURCES+=("$file"); done < <(
    find "$ROOT/Sources" -name '*.swift' ! -name 'KeepNoteApp.swift' | sort)
INTEGRATION=()
while IFS= read -r file; do INTEGRATION+=("$file"); done < <(find "$ROOT/Tests/Integration" -name '*.swift' | sort)

swiftc \
    -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx13.0" \
    -swift-version 5 \
    -module-name KeepNote \
    -module-cache-path "$OUT/module-cache" \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    -framework AppKit -framework SwiftUI -framework Carbon -framework CryptoKit \
    -framework Security -framework UniformTypeIdentifiers \
    -framework CoreServices -framework ServiceManagement -lsqlite3 \
    -o "$OUT/run-integration-tests" \
    "${APP_SOURCES[@]}" "$ROOT/Tests/Harness.swift" "${INTEGRATION[@]}"

"$OUT/run-integration-tests"
