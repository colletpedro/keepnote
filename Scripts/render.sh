#!/bin/bash
#
# Renders the note views to PNGs without launching KeepNote: compiles the app's
# sources (minus its @main) with Scripts/RenderHarness/main.swift into a
# separate command-line tool, which draws each view off screen and exits.
# Nothing is shown, nothing is installed, the real database is not touched.
#
#   ./Scripts/render.sh <output-dir>            in English
#   ./Scripts/render.sh <output-dir> pt-BR      in Portuguese, where the text
#                                               runs longer: the layout check
#   ./Scripts/render.sh <output-dir> pt-BR extraLarge
#                                               and at a Text size (small,
#                                               standard, large, extraLarge)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:?usage: render.sh <output-dir>}"
BUILD="$ROOT/build/render"
mkdir -p "$BUILD" "$OUT_DIR"

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
    -Onone \
    -framework AppKit -framework SwiftUI -framework Carbon -framework CryptoKit \
    -framework Security -framework UniformTypeIdentifiers \
    -framework CoreServices -framework ServiceManagement -lsqlite3 \
    -o "$BUILD/render" \
    "${SOURCES[@]}" "$ROOT/Scripts/RenderHarness/main.swift"

# The language comes from Resources, as the app's bundle would have it.
KEEPNOTE_TEXT_SIZE="${3:-standard}" KEEPNOTE_LANGUAGE="${2:-en}" KEEPNOTE_LPROJ_ROOT="$ROOT/Resources" "$BUILD/render" "$OUT_DIR"
