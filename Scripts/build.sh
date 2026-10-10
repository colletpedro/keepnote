#!/bin/bash
#
# Builds KeepNote.app without Xcode: swiftc straight to a binary, then the
# bundle assembled around it, then a signature so the sandbox entitlements
# actually apply. The identity is KEEPNOTE_SIGN_ID (default "KeepNote Dev", a
# self-signed Code Signing certificate). On a fresh clone that certificate does
# not exist: the build then signs ad-hoc, with a warning, so one command works.
# A KEEPNOTE_SIGN_ID that is set and missing is an error.
#
#   ./Scripts/build.sh                 debug build into ./build
#   ./Scripts/build.sh --release       optimised build
#   ./Scripts/build.sh --run           build, then launch the ./build copy
#   ./Scripts/build.sh --install       release build, then the one installed
#                                      copy: quit the running KeepNote, replace
#                                      /Applications/KeepNote.app, refresh
#                                      Launch Services (refuses an ad-hoc build
#                                      unless KEEPNOTE_ALLOW_ADHOC=1)
#   ./Scripts/build.sh --refresh-icons also touch the installed bundle and
#                                      restart the Dock and Finder, to drop a
#                                      stale icon (use with --install or alone)
#
# KEEPNOTE_BUILD_DIR builds somewhere other than ./build (release.sh uses a
# fresh folder of its own).
#
# The ./build copy is for building only. --install unregisters it from Launch
# Services so Spotlight and the Finder find just the installed app.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${KEEPNOTE_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/KeepNote.app"
CONFIG="debug"
RUN=0
INSTALL=0
REFRESH_ICONS=0
DEST="${KEEPNOTE_DEST:-/Applications/KeepNote.app}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release" ;;
        --run) RUN=1 ;;
        --install) INSTALL=1; CONFIG="release" ;;
        --refresh-icons) REFRESH_ICONS=1 ;;
        --help|-h) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# --- icon cache ------------------------------------------------------------

refresh_icons() {
    # The Dock and Finder keep their own copies of an app's icon; touching the
    # bundle and re-registering it makes Launch Services re-read it, and the
    # restart makes them draw it again.
    if [ -d "$DEST" ]; then
        touch "$DEST"
        "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
    fi
    echo "==> restarting the Dock and Finder"
    killall Dock Finder 2>/dev/null || true
    # Relaunching the Finder rescans and re-registers the ./build copy; give it
    # a moment, then take that one out again.
    sleep 3
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
}

if [ "$REFRESH_ICONS" = "1" ] && [ "$INSTALL" = "0" ] && [ "$RUN" = "0" ] && [ "$CONFIG" = "debug" ]; then
    refresh_icons
    exit 0
fi

# --- toolchain -------------------------------------------------------------

if ! command -v swiftc >/dev/null 2>&1; then
    echo "error: swiftc not found. Install Xcode or the Command Line Tools." >&2
    exit 1
fi

# `xcrun --show-sdk-path` picks the highest-versioned SDK installed, which is
# not always the one this swiftc can read — a Command Line Tools install can
# carry an SDK from a newer Xcode than its own compiler, and the two must
# match. The `MacOSX.sdk` symlink is the one shipped alongside this toolchain.
if [ -n "${KEEPNOTE_SDK:-}" ]; then
    SDK="$KEEPNOTE_SDK"
else
    DEVELOPER_DIR_PATH="$(xcode-select -p)"
    SDK=""
    for candidate in \
        "$DEVELOPER_DIR_PATH/SDKs/MacOSX.sdk" \
        "$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    do
        if [ -d "$candidate" ]; then SDK="$candidate"; break; fi
    done
    SDK="${SDK:-$(xcrun --show-sdk-path)}"
fi
ARCH="${KEEPNOTE_ARCH:-$(uname -m)}"
DEPLOYMENT_TARGET="13.0"
TARGET="${ARCH}-apple-macosx${DEPLOYMENT_TARGET}"

echo "==> toolchain $(swiftc --version | head -1)"
echo "==> sdk       $SDK"
echo "==> target    $TARGET"

EXTRA_FLAGS=()

# Some Command Line Tools installs ship a stale module.modulemap next to
# bridging.modulemap; both define SwiftBridging and clang refuses the
# duplicate. A VFS overlay masks the stale one without touching /Library.
SWIFT_INCLUDE="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
if [ -f "$SWIFT_INCLUDE/module.modulemap" ] && [ -f "$SWIFT_INCLUDE/bridging.modulemap" ]; then
    echo "==> working around duplicate SwiftBridging modulemap"
    mkdir -p "$BUILD_DIR"
    : > "$BUILD_DIR/empty.modulemap"
    cat > "$BUILD_DIR/modulemap-overlay.yaml" <<YAML
{
  "version": 0,
  "roots": [
    {
      "name": "$SWIFT_INCLUDE",
      "type": "directory",
      "contents": [
        { "name": "module.modulemap", "type": "file",
          "external-contents": "$BUILD_DIR/empty.modulemap" }
      ]
    }
  ]
}
YAML
    EXTRA_FLAGS+=(-Xcc -ivfsoverlay -Xcc "$BUILD_DIR/modulemap-overlay.yaml")
fi

if [ "$CONFIG" = "release" ]; then
    EXTRA_FLAGS+=(-O -whole-module-optimization)
else
    EXTRA_FLAGS+=(-Onone -g)
fi

# --- compile ---------------------------------------------------------------

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)
echo "==> compiling ${#SOURCES[@]} files ($CONFIG)"

swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -swift-version 5 \
    -module-name KeepNote \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "${EXTRA_FLAGS[@]}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework CryptoKit \
    -framework Security \
    -framework UniformTypeIdentifiers \
    -framework CoreServices \
    -framework ServiceManagement \
    -lsqlite3 \
    -o "$APP/Contents/MacOS/KeepNote" \
    "${SOURCES[@]}"

# --- bundle ----------------------------------------------------------------

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for glyph in StatusGlyph.png StatusGlyph@2x.png StatusGlyph@3x.png; do
    cp "$ROOT/Resources/$glyph" "$APP/Contents/Resources/$glyph"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- sign ------------------------------------------------------------------
#
# Any signature is enough to run locally and to make the sandbox real. Shipping needs
# a Developer ID identity and notarisation:
#
#   codesign --force --options runtime --timestamp \
#            --entitlements Resources/KeepNote.entitlements \
#            --sign "Developer ID Application: <you>" build/KeepNote.app
#   xcrun notarytool submit ... && xcrun stapler staple build/KeepNote.app

# A stable identity keeps the app's designated requirement the same across
# rebuilds, so the Keychain item holding the notes key does not ask for
# permission again after every build (an ad-hoc signature changes with each
# binary). The identity is KEEPNOTE_SIGN_ID, "KeepNote Dev" by default — a
# self-signed Code Signing certificate is enough.
#
# Ad-hoc is used when KEEPNOTE_ALLOW_ADHOC=1, and also when the default identity
# simply is not in the keychain (a fresh clone): then with a loud warning rather
# than a failure. A named KEEPNOTE_SIGN_ID that is missing, or an identity that
# exists and still fails to sign, stays an error.
SIGN_ID="${KEEPNOTE_SIGN_ID:-KeepNote Dev}"
ADHOC_REASON=""
if [ "${KEEPNOTE_ALLOW_ADHOC:-0}" = "1" ]; then
    ADHOC_REASON="KEEPNOTE_ALLOW_ADHOC=1"
elif [ -z "${KEEPNOTE_SIGN_ID:-}" ] && ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
    ADHOC_REASON="no \"$SIGN_ID\" certificate in this Mac's keychain"
fi

warn_adhoc() {
    {
        echo
        echo "################################################################"
        echo "#  WARNING: this build is signed AD-HOC ($ADHOC_REASON)."
        echo "#"
        echo "#  It runs, and the sandbox applies, but the signature changes"
        echo "#  with every build: macOS will ask again, after each rebuild,"
        echo "#  for access to the Keychain key that encrypts your notes."
        echo "#  Your notes are not lost; choose Allow."
        echo "#"
        echo "#  To stop the prompts, create the \"$SIGN_ID\" certificate once:"
        echo "#  see \"Build from source\" in the README."
        echo "################################################################"
        echo
    } >&2
}

if [ -n "$ADHOC_REASON" ]; then
    IDENTITY="-"
    warn_adhoc
else
    echo "==> signing with \"$SIGN_ID\""
    IDENTITY="$SIGN_ID"
fi
if ! SIGN_LOG="$(codesign --force --sign "$IDENTITY" \
        --entitlements "$ROOT/Resources/KeepNote.entitlements" \
        "$APP" 2>&1)"; then
    echo "error: could not sign with \"$IDENTITY\":" >&2
    echo "$SIGN_LOG" | sed 's/^/       /' >&2
    echo "       Check that the certificate exists with a private key:" >&2
    echo "         security find-identity -p codesigning" >&2
    echo "       Set KEEPNOTE_SIGN_ID to another identity, or KEEPNOTE_ALLOW_ADHOC=1 to sign ad-hoc." >&2
    exit 1
fi

echo "==> built $APP"
codesign -d --entitlements - "$APP" 2>/dev/null | head -20 || true

if [ "$INSTALL" = "1" ]; then
    # One installed copy. Refuse an ad-hoc one unless that was asked for: it
    # would make the Keychain ask for the notes key again.
    if [ "${KEEPNOTE_ALLOW_ADHOC:-0}" != "1" ] && codesign -dvv "$APP" 2>&1 | grep -q "^Signature=adhoc"; then
        echo "error: the build is signed ad-hoc; refusing to install it." >&2
        echo "       Create the \"$SIGN_ID\" certificate, or set KEEPNOTE_ALLOW_ADHOC=1 to install it anyway." >&2
        exit 1
    fi

    if pgrep -f "KeepNote.app/Contents/MacOS/KeepNote" >/dev/null 2>&1; then
        echo "==> quitting the running KeepNote"
        # A polite quit first, so pending edits are flushed; then insist.
        osascript -e 'tell application id "com.keepnote.KeepNote" to quit' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -f "KeepNote.app/Contents/MacOS/KeepNote" >/dev/null 2>&1 || break
            sleep 0.5
        done
        pkill -f "KeepNote.app/Contents/MacOS/KeepNote" 2>/dev/null || true
        sleep 0.5
    fi

    echo "==> installing to $DEST"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    touch "$DEST"
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
    # The build copy must not compete with it in Spotlight or "Open With".
    # Launch Services registers a freshly written bundle a few seconds after the
    # fact, so the unregister has to wait for that or it is undone.
    sleep 4
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    echo "==> installed $DEST"
    [ "$REFRESH_ICONS" = "1" ] && refresh_icons
fi

if [ "$RUN" = "1" ]; then
    # `open` on an app that is already running just brings the existing
    # instance forward — the freshly built binary would never be loaded, and
    # the change would silently appear not to have worked. So the old one goes
    # first. Notes live in SQLite, so nothing is lost across the restart.
    if pkill -f "KeepNote.app/Contents/MacOS/KeepNote" 2>/dev/null; then
        echo "==> stopping the running copy"
        sleep 1
    fi
    # `open` on an app that is already running only brings the old process to
    # the front — the new binary would never load. Stop it first.
    echo "==> launching"
    pkill -f "KeepNote.app/Contents/MacOS/KeepNote" 2>/dev/null || true
    sleep 1
    open "$APP"
fi

# The last thing on the screen, where the compiler output no longer buries it.
if [ -n "$ADHOC_REASON" ]; then warn_adhoc; fi
