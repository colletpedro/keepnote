#!/bin/bash
#
# Builds the downloadable KeepNote: an optimised arm64 build signed with
# KEEPNOTE_SIGN_ID (default "KeepNote Dev"), packed into a disk image.
#
#   ./Scripts/release.sh
#
# The app is built from nothing, in a folder made for the purpose and removed
# afterwards, so nothing left in ./build (a debug build's KeepNote.dSYM, say)
# can end up in the disk image. The image is then opened and its contents
# checked: the script fails unless it holds the app and the shortcut to
# Applications and nothing else.
#
# Writes, into ./dist:
#   KeepNote.dmg          volume "KeepNote": the app and a shortcut to Applications
#   KeepNote.dmg.sha256   its checksum, in the format `shasum -a 256 -c` reads
#
# The app is not notarised (that needs a paid Apple Developer ID), so macOS
# shows its "could not verify" warning on the first open. Unlike build.sh this
# script never falls back to an ad-hoc signature by itself; set
# KEEPNOTE_ALLOW_ADHOC=1 to ship one on purpose.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
APP="$WORK/KeepNote.app"
DMG="$DIST/KeepNote.dmg"
SIGN_ID="${KEEPNOTE_SIGN_ID:-KeepNote Dev}"

if [ "${KEEPNOTE_ALLOW_ADHOC:-0}" != "1" ] \
    && ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
    echo "error: no \"$SIGN_ID\" code-signing certificate in the keychain." >&2
    echo "       Set KEEPNOTE_SIGN_ID to one that exists, or KEEPNOTE_ALLOW_ADHOC=1 to ship an ad-hoc build." >&2
    exit 1
fi

STAGE=""
MOUNT=""
cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    rm -rf "$WORK" ${STAGE:+"$STAGE"}
}
trap cleanup EXIT

echo "==> building (release, arm64) from a clean folder"
KEEPNOTE_BUILD_DIR="$WORK" KEEPNOTE_ARCH=arm64 KEEPNOTE_SIGN_ID="$SIGN_ID" "$ROOT/Scripts/build.sh" --release

echo "==> checking the build"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/KeepNote")"
[ "$ARCHS" = "arm64" ] || { echo "error: the binary is \"$ARCHS\", expected arm64" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
    || { echo "error: the app-sandbox entitlement is missing from the signature" >&2; exit 1; }

echo "==> packing $DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/KeepNote.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "KeepNote" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"

echo "==> checking the disk image"
MOUNT="$(mktemp -d)"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
# The system may add its own bookkeeping folder to a volume.
TOP="$(ls -A "$MOUNT" | grep -vxE '\.(fseventsd|Trashes|DS_Store)' | LC_ALL=C sort | tr '\n' ' ')"
[ "$TOP" = "Applications KeepNote.app " ] \
    || { echo "error: the disk image holds \"$TOP\", expected only the app and the Applications shortcut" >&2; exit 1; }
[ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
    || { echo "error: Applications in the disk image is not a shortcut to /Applications" >&2; exit 1; }
INSIDE="$(cd "$MOUNT/KeepNote.app/Contents" && find . -mindepth 1 -not -path './_CodeSignature/*' -not -path './Resources/*' | LC_ALL=C sort | tr '\n' ' ')"
WANTED="./Info.plist ./MacOS ./MacOS/KeepNote ./PkgInfo ./Resources ./_CodeSignature "
[ "$INSIDE" = "$WANTED" ] \
    || { echo "error: the app in the disk image holds \"$INSIDE\", expected \"$WANTED\"" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT/KeepNote.app" \
    || { echo "error: the app in the disk image does not verify" >&2; exit 1; }
hdiutil detach -quiet "$MOUNT"
MOUNT=""

( cd "$DIST" && shasum -a 256 KeepNote.dmg > KeepNote.dmg.sha256 )

echo "==> done"
ls -lh "$DMG"
cat "$DMG.sha256"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature|TeamIdentifier)" || true
