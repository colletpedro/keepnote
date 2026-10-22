# The identity every release is signed with. Sourced by release.sh and build.sh;
# not meant to be run. See Scripts/SIGNING.md.
#
# It is chosen here, by name and by the SHA-1 of its certificate, and nowhere
# else: release.sh takes neither from the environment, so a release cannot be
# signed by whatever certificate happens to be in the keychain. The app's
# designated requirement is "identifier ... and certificate leaf = H<this hash>",
# so every release signed with this certificate is the same app to macOS, and
# one signed with a lookalike of the same name is not.
#
# "KeepNote Dev" is a self-signed Code Signing certificate whose subject is only
# CN=KeepNote Dev, C=BR: no e-mail, no personal data. (An "Apple Development"
# certificate carries the Apple ID's e-mail in its name; never ship with one.)
RELEASE_SIGN_ID="KeepNote Dev"
RELEASE_SIGN_SHA1="A86B2B382AA6B4A5FD89D1C017E23EE27EF28584"
