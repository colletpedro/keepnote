# Signing

## Releases

`release.sh` signs with one identity, fixed in `signing-identity.sh`: the
self-signed Code Signing certificate **KeepNote Dev**, pinned by name *and* by
the SHA-1 of its certificate (`A86B2B38…F84`). Neither can be changed from the
environment. The script stops if that exact certificate is not in the keychain
(a new certificate with the same name is a different signature), and, after
building, checks that the app's designated requirement names that hash:

    identifier "com.keepnote.KeepNote" and certificate leaf = H"a86b2b38…"

So every release is the same app to macOS as long as it comes from the Mac that
holds the certificate's private key. Back that certificate up (Keychain Access →
export as `.p12`); without it the next release has a new identity.

The certificate's subject is only `CN=KeepNote Dev, C=BR`: no e-mail, no personal
data. It expires on 2027-10-07; renewing it means a new certificate, hence a new
identity, so update `signing-identity.sh` then.

## Releases are never changed

v1.0.0, and every release after it, stays as it was published: the tag is not
moved and the files are not swapped, not even to fix a typo or a bad build.
Anyone who verified a download (checksum, signature) must find the same bytes
later. A fix is a new release with a new version. For each release:

1. Raise `CFBundleShortVersionString` (X.Y.Z) and `CFBundleVersion` (a whole
   number above every earlier build) in `Resources/Info.plist`.
2. Put the same X.Y.Z in `docs/version.json`.
3. Add a `## [X.Y.Z]` section to `CHANGELOG.md`; it becomes the release notes.
4. Commit and push, then `./Scripts/release.sh --publish`, which tags `vX.Y.Z`.

`release.sh` checks all of this before it builds anything, and refuses when the
tag `vX.Y.Z` already exists locally or on GitHub, when the version is not
X.Y.Z, when the build number does not go up, or when the changelog has no
section for the version. It never moves a tag (`git tag -f`) and never
overwrites an asset (`--clobber`); do not do either by hand.

What does not change between releases is the identity the notes are found by:
the bundle identifier `com.keepnote.KeepNote`, the Keychain item
`com.keepnote.KeepNote.bodykey` / `default`, and the signing certificate above.
Changing any of them separates the users from their own notes.

## Not notarised

The app has no Developer ID and is not notarised, so macOS shows "could not
verify" on the first open, with **Open Anyway** in System Settings → Privacy &
Security. That is the expected result. "Damaged" would mean a broken signature
(`codesign --verify --deep --strict` fails) and must never ship.

To check a release: download the disk image from the site, then

    codesign -dvv KeepNote.app            # Authority=KeepNote Dev, TeamIdentifier=not set
    codesign -d -r- KeepNote.app          # the designated requirement above
    spctl --assess --type execute -vvv KeepNote.app   # rejected, origin=KeepNote Dev

## Local builds

`build.sh` signs with `KEEPNOTE_SIGN_ID` if set. If not, it uses an **Apple
Development** identity when the keychain has one, else the release identity
above. The Apple Development one is for the author's own Mac only: it has a Team
ID, which stops the Keychain asking for the notes key after every rebuild, but
its name carries the Apple ID's e-mail, so nothing built that way is shipped.
`release.sh` never reads `KEEPNOTE_SIGN_ID` and never picks an identity by
looking around.
