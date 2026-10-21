#!/bin/bash
#
# The finishing gallery: every screen, drawn off screen, in every combination
# that changes how it looks — English and Portuguese, the four Text sizes —
# and, inside each, light and dark, both screen edges and Increase contrast.
# Runs Scripts/render.sh and Scripts/Gallery/main.swift for each combination,
# into <output-dir>/<language>-<size>/. Nothing is shown or installed; the
# real notes are not touched.
#
#   ./Scripts/gallery.sh <output-dir>                  every combination
#   ./Scripts/gallery.sh <output-dir> en standard      one
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: gallery.sh <output-dir> [language size]}"
BUILD="$ROOT/build/gallery"
mkdir -p "$BUILD" "$OUT"

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
    -framework CoreServices -framework ServiceManagement -framework Quartz -lsqlite3 \
    -o "$BUILD/gallery" \
    "${SOURCES[@]}" "$ROOT/Scripts/Gallery/main.swift"

if [ $# -ge 3 ]; then
    COMBOS=("$2:$3")
else
    COMBOS=()
    for language in en pt-BR; do
        for size in small standard large extraLarge; do COMBOS+=("$language:$size"); done
    done
fi

for combo in "${COMBOS[@]}"; do
    language="${combo%%:*}"
    size="${combo##*:}"
    dir="$OUT/$language-$size"
    mkdir -p "$dir"
    echo "==> $language, $size"
    "$ROOT/Scripts/render.sh" "$dir" "$language" "$size" > "$dir/render.log" 2>&1
    KEEPNOTE_TEXT_SIZE="$size" KEEPNOTE_LANGUAGE="$language" KEEPNOTE_LPROJ_ROOT="$ROOT/Resources" \
        "$BUILD/gallery" "$dir" > "$dir/gallery.log" 2>&1
    echo "    $(ls "$dir"/*.png | wc -l | tr -d ' ') pictures"
done
