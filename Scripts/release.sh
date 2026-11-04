#!/bin/bash
#
# Builds the downloadable KeepNote: an optimised arm64 build signed with
# the fixed release identity (Scripts/signing-identity.sh), packed into a disk image.
#
#   ./Scripts/release.sh             build and check, write dist/ (publishes nothing)
#   ./Scripts/release.sh --publish   the same, then tag vX.Y.Z and create the GitHub release
#
# A release is never changed once it is out. v1.0.0 and every tag after it
# stay on the commit they were made on, with the files they were published
# with: a fix is a new version, never a replaced file. So each release needs
#   - a new CFBundleShortVersionString (X.Y.Z) and a larger CFBundleVersion
#     in Resources/Info.plist,
#   - the same version in docs/version.json,
#   - a "## [X.Y.Z]" section in CHANGELOG.md, which becomes the release notes,
# and the script refuses, before building anything, to go on when the tag
# vX.Y.Z already exists here or on GitHub. It never moves a tag or uploads
# over an asset (no `git tag -f`, no `--clobber`).
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
# KEEPNOTE_ALLOW_ADHOC=1 to ship one on purpose. The identity cannot be changed
# from the environment: see Scripts/SIGNING.md.
#
set -euo pipefail

PUBLISH=0
case "${1:-}" in
    "") ;;
    --publish) PUBLISH=1 ;;
    *) echo "usage: $0 [--publish]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
# The site shows the version from docs/version.json; it must be the app's.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
SITE_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/docs/version.json")"
[ "$APP_VERSION" = "$SITE_VERSION" ] \
    || { echo "error: docs/version.json says \"$SITE_VERSION\" but Info.plist says \"$APP_VERSION\"" >&2; exit 1; }


# --- the version is new -------------------------------------------------------
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
TAG="v$APP_VERSION"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "error: CFBundleShortVersionString \"$APP_VERSION\" is not X.Y.Z" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] \
    || { echo "error: CFBundleVersion \"$BUILD_NUMBER\" is not a whole number" >&2; exit 1; }

if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: the tag $TAG already exists here. A release is never moved or replaced:" >&2
    echo "       raise the version in Info.plist, docs/version.json and CHANGELOG.md." >&2
    exit 1
fi
if git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "error: the tag $TAG already exists on GitHub (fetch the tags, then raise the version)." >&2
    exit 1
fi
if command -v gh >/dev/null 2>&1 && gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: GitHub already has a release $TAG." >&2
    exit 1
fi
# The build number only goes up, past every release already tagged.
for old in $(git -C "$ROOT" tag -l 'v[0-9]*'); do
    OLD_BUILD="$(git -C "$ROOT" show "$old:Resources/Info.plist" 2>/dev/null \
        | sed -n '/<key>CFBundleVersion<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}')"
    if [[ "$OLD_BUILD" =~ ^[0-9]+$ ]] && [ "$BUILD_NUMBER" -le "$OLD_BUILD" ]; then
        echo "error: CFBundleVersion $BUILD_NUMBER is not above $OLD_BUILD, the build of $old." >&2
        exit 1
    fi
done

# --- the release notes come from CHANGELOG.md ---------------------------------
NOTES="$(awk -v v="$APP_VERSION" '
    /^## \[/ { if (on) exit; on = index($0, "## [" v "]") == 1; next }
    on { print }' "$ROOT/CHANGELOG.md")"
[ -n "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ] \
    || { echo "error: CHANGELOG.md has no \"## [$APP_VERSION]\" section with text in it" >&2; exit 1; }

if [ "$PUBLISH" = "1" ]; then
    command -v gh >/dev/null 2>&1 || { echo "error: --publish needs the gh command" >&2; exit 1; }
    [ -z "$(git -C "$ROOT" status --porcelain)" ] \
        || { echo "error: --publish needs a clean working tree; commit first" >&2; exit 1; }
    git -C "$ROOT" fetch -q origin \
        && [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse '@{upstream}' 2>/dev/null)" ] \
        || { echo "error: --publish needs HEAD pushed, so the tag points at a commit GitHub has" >&2; exit 1; }
fi

WORK="$(mktemp -d)"
APP="$WORK/KeepNote.app"
DMG="$DIST/KeepNote.dmg"
# shellcheck source=signing-identity.sh
. "$ROOT/Scripts/signing-identity.sh"
SIGN_ID="$RELEASE_SIGN_ID"

if [ "${KEEPNOTE_ALLOW_ADHOC:-0}" != "1" ] \
    && ! security find-identity -p codesigning 2>/dev/null | grep -qF "$RELEASE_SIGN_SHA1 \"$SIGN_ID\""; then
    echo "error: the \"$SIGN_ID\" certificate with SHA-1 $RELEASE_SIGN_SHA1 is not in the keychain." >&2
    echo "       A certificate of the same name made later is a different signature, not this one." >&2
    echo "       Restore the original, or KEEPNOTE_ALLOW_ADHOC=1 to ship an ad-hoc build." >&2
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
if [ "${KEEPNOTE_ALLOW_ADHOC:-0}" != "1" ]; then
    codesign -d -r- "$APP" 2>&1 | grep -qi "certificate leaf = H\"$RELEASE_SIGN_SHA1\"" \
        || { echo "error: the app is not signed by the release certificate $RELEASE_SIGN_SHA1" >&2; exit 1; }
fi
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
printf '%s\n' "$NOTES" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed '/./,$!d' > "$DIST/RELEASE_NOTES.md"

echo "==> done"
ls -lh "$DMG"
cat "$DMG.sha256"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature|TeamIdentifier)" || true

if [ "$PUBLISH" = "1" ]; then
    echo "==> publishing $TAG"
    # Creates the tag on this commit and the release in one go; fails, and
    # changes nothing, if either exists. No --clobber, ever.
    gh release create "$TAG" "$DIST/KeepNote.dmg" "$DIST/KeepNote.dmg.sha256" \
        --title "KeepNote $APP_VERSION" --notes-file "$DIST/RELEASE_NOTES.md" \
        --target "$(git -C "$ROOT" rev-parse HEAD)"
    echo "    $TAG published; the notes are the $APP_VERSION section of CHANGELOG.md"
else
    echo "    $TAG not published (that is ./Scripts/release.sh --publish); notes: dist/RELEASE_NOTES.md"
fi
