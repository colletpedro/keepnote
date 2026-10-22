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
