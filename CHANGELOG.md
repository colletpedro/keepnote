# Changelog

Every release has its own version and is never changed after it is published:
a fix is a new release. `Scripts/release.sh` uses the section of the version
being released, between its `## [X.Y.Z]` line and the next one, as the notes of
the GitHub release, so write each section for the people who update.

## Template for the next release

Copy this above the newest release below, and fill it in. Raise
`CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` and
`docs/version.json` to match. Leave out the headings with nothing under them.

```
## [X.Y.Z] - YYYY-MM-DD

### Added
- What is new, in a sentence a user would say.

### Changed
- What works differently now.

### Fixed
- What was broken and no longer is.

### Notes
- Anything to know before or after updating (a database change, a setting moved).
```

## [1.0.0] - 2026-11-03

First public release.

- Sticky notes as colored tabs on a screen edge, with groups, daily notes, pinning, tags, search and a note pane in All Notes.
- Markdown as you type, images and files in notes, and Copy with images.
- Text sealed on disk with a key that stays in this Mac's Keychain; no network access.
- Daily backups, and one before any change to how notes are stored.
- Sync through a folder you choose, import and export (Markdown, plain text, the KeepNote archive).
- English and Portuguese (Brazil), for Macs with an Apple chip and macOS 13 or newer.
