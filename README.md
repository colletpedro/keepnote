<p align="right"><a href="README.pt-BR.md">Português</a></p>

![KeepNote — sticky notes on the edge of your screen](docs/cover.png)

<p align="center"><a href="https://colletpedro.github.io/keepnote/"><img src="docs/media/keepnote-preview.gif" alt="Preview of the KeepNote video" width="640"><br>Watch the full video</a></p>

# KeepNote

Sticky notes for macOS that wait as a row of colored tabs on the right edge of your screen: move the cursor there, pick a note, write, and it slides back out of the way.

**[Download KeepNote.dmg](https://github.com/colletpedro/keepnote/releases/latest/download/KeepNote.dmg)**

Requires a Mac with an Apple chip (M1 or later) and macOS 13 or newer. The download is built for Apple chips only.

## Install

**1. Open the download and drag KeepNote onto Applications.**

**2. Open KeepNote from Applications.** macOS will say it could not verify the app. Click **Done** (or **OK**). This is expected; [the reason is below](#why-does-macos-show-a-warning).

**3. Allow it once.** Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next to KeepNote, and confirm. macOS will not ask again for this copy of the app. (On macOS 13 and 14 you can also Control-click the app and choose **Open**.)

## Updates

KeepNote does not check for updates by itself, because it has no network access. New versions are published on [the site](https://colletpedro.github.io/keepnote/) and on the [releases page](https://github.com/colletpedro/keepnote/releases). **Settings → About → Check for Updates…** opens the site in your browser.

## Why does macOS show a warning?

KeepNote is not notarized by Apple. Notarization needs a paid Apple Developer membership (US$ 99 a year), and KeepNote is a free, open-source project, so it ships without it for now. macOS shows this warning for every app that has not been through that process. It says Apple has not checked the app, not that something is wrong with it. These are the four things you can check for yourself instead:

1. **You can read it, and build it.** All of the source code is in this repository, with no third-party libraries. `./Scripts/build.sh` builds the same app from it.
2. **It cannot use the network.** KeepNote runs in the macOS sandbox without the network entitlements, so the system refuses any connection it tried to make. See for yourself: `codesign -d --entitlements - /Applications/KeepNote.app` lists no network access.
3. **It only reaches what you give it.** Outside its own container, the sandbox lets KeepNote open only the folders and files you pick, for sync, import and export. The text of your notes is encrypted on disk with a key that stays in this Mac's Keychain.
4. **You can check the download.** Each release carries a `KeepNote.dmg.sha256` file. `shasum -a 256 KeepNote.dmg` must print the same value.

## What it does

- **A deck on the screen edge.** Notes are tabs on the right edge, or on the left one (Settings → Deck → Screen edge): the whole deck, its peeks and anchored notes mirror to come out towards the middle of the screen, and a Dock on either side is left clear. Hovering the edge fans them out, each with its own color and label; the deck scrolls when there are many. Touching a tab shows a quick look at the note without taking focus from the app you are in; clicking opens it for editing.
- **Anchored or floating.** An open note is anchored to the deck and closes when you click elsewhere. **Float Note** (⌥⌘P) lifts it off the edge so it stays on screen, resizable, and remembers its place; dragging a floating note back to the deck's edge returns it.
- **Markdown as you type.** Bold, italic, strikethrough, highlight, links, headings, bulleted, numbered and checklist items (with indent and automatic renumbering), quotes, code, tables and dividers, all with shortcuts and in a Tools menu in the note.
- **Colors and tags.** Five paper colors, changeable at any moment, and `#tags` with suggestions while you type. All Notes filters by tag and searches title, tags and text.
- **Edit in All Notes.** The note selected in All Notes opens in its pane with everything a note has — title, text, lists and checklists, the note's shortcuts, Tools, find (⌘F), the colours, tags, Pin to Center and Keep on Deck — and saves on its own. A note open in the pane and in a window at the same time is one note: what you type in one shows in the other at once, and nothing is lost. Archived notes and dailies can be edited there and stay archived; a note that cannot be decrypted shows read-only, with the reason. Selecting a note counts as opening it for the archiving rule. **New Note** makes the note right in the pane, with the caret in its title — with the list's tag on a tag, as today's daily under Daily. The list sorts by **Edited**, **Created** or **Title** (kept between openings); ↑ and ↓ move through it, Return goes into the note's text, Esc comes back. **Open** lifts the note out as a floating note, and a toolbar button hides the sidebar and the list so the note fills the window.
- **Daily notes.** Give a note the `daily` tag, or use **Today's Daily** (⌥⌘Y, or the calendar button on the deck). The deck keeps the dailies of your two most recent days; older ones are archived and stay under **Daily** in All Notes, grouped by day. You can set a template for new daily notes. **Unfinished tasks** (Settings → Daily) carry over: when a new daily is made, the checklist items left unticked in the dailies of the last day before can be offered at the top of it (*Ask each time*, the default), brought in at once with an Undo (*Bring automatically*), or left where they are (*Don't bring*). They go at the end of the new daily, subitems indented, under the day they came from ("From Thursday, 15/10"), without repeating what the template already has; the earlier daily is never changed.
- **Pin, keep and archive by time.** *Pin to Center* holds up to five notes in the middle of the deck, always whole. *Keep on Deck* exempts a note from archiving. Notes you have not opened for 7, 14 or 30 days (you choose; 14 by default) move to the Archive on their own, never deleted; in the last two days a clock appears on the tab. Pinning, keeping and the archiving rules do not change a note's *Edited* date, which only moves when you change its text or title.
- **Backups.** Once a day KeepNote copies its database into a `Backups` folder beside it, sealed exactly like the original, and keeps the seven most recent; it also makes one before an update changes how notes are stored. Settings → General → **Backups** shows when the last one was made, with **Back Up Now** and **Restore…**, which lists the backups with their date and number of notes, asks first, backs up your notes as they are now, and reopens KeepNote with the chosen one. Nothing leaves the Mac.
- **Archive and undo.** Archived notes have their own window. Deleting a note gives you 10 seconds (adjustable) to undo it.
- **Images and files.** Drag a picture from the Finder or a browser into a note, paste one (a screenshot too), or use **Insert Image…** in Tools: it sits in the text at the note's width, with rounded corners. Other files — drag them in, paste them, or **Attach File…** — show as a card with their icon, name and size. A click selects an image and opens a file in its app; Space shows either in Quick Look; the right click has Open, Save As…, Remove and, for an image, **Edit Description…**, which is what VoiceOver reads. Each attachment can be up to 25 MB. They are kept in the database, sealed like the text, once however many notes hold the same file, and go away with the notes that held them. The peek shows a note's first image, All Notes marks notes with attachments with a paperclip.
- **Links and mentions.** A click on a link opens it in your browser (⌥-click to edit it). Paste an address on its own and KeepNote offers it as a **Mention**: the site's initial in a colour of its own and a title read from the address itself — `…/jack-johnson/traffic-in-the-sky` reads "Traffic in the Sky – Jack Johnson". Nothing is fetched, since KeepNote makes no network connection. The right click on a link has Open Link, Copy Link and Show as Mention or Show as Link; a mention is a Markdown link, so it stays a link anywhere else.
- **Sync through a folder.** Optionally, KeepNote writes one plain-text `.hmnote` file per note into a folder you choose (iCloud Drive is suggested). Attachments go with them as plain copies in the folder's `Attachments`. The folder's provider moves them between Macs; KeepNote has no server of its own.
- **Import and export.** Export notes as Markdown or plain text, one file per note or one document, or as a KeepNote archive (`.hmnotearchive`) that keeps colors, states and dates. Images and files go along, in an `Attachments` folder the exported text links to (inside the archive, which becomes a package). Import reads that archive or a folder of `.hmnote` files.
- **Where it lives.** In the menu bar, and in the Dock only while one of its windows is open. Optional launch at login and display over full-screen apps.

## Build from source

You need only Apple's Command Line Tools (`xcode-select --install`), or Xcode. KeepNote has no dependencies beyond the system frameworks.

```bash
git clone https://github.com/colletpedro/keepnote.git
cd keepnote
./Scripts/build.sh --run
```

That builds the app into `build/` and opens it. On a fresh clone there is no signing certificate, so the build is signed **ad-hoc** and prints a visible warning. An ad-hoc signature changes with every build, so after each rebuild macOS asks again for access to the Keychain item holding the key that encrypts your notes; choose Allow, no notes are lost.

To stop those prompts, sign with a certificate that has a **Team ID**: an **Apple Development** certificate, which Xcode makes for any Apple ID, free (Xcode → Settings → Accounts → Manage Certificates → +). The build finds it and uses it by itself. The Keychain keeps the key's permission per team for such an app, so every build is the same app to it. A self-signed certificate does not do this: it has no Team ID, so the Keychain asks again after every rebuild, however stable its signature. Another certificate with a Team ID works with `KEEPNOTE_SIGN_ID="Name"`. Releases are signed differently, by a fixed identity; see `Scripts/SIGNING.md`.

| Command | What it does |
|---|---|
| `./Scripts/build.sh` | debug build into `build/` |
| `./Scripts/build.sh --release` | optimized build |
| `./Scripts/build.sh --install` | release build, replaces `/Applications/KeepNote.app` (refuses an ad-hoc build unless `KEEPNOTE_ALLOW_ADHOC=1`) |
| `./Scripts/release.sh` | arm64 release signed with `KEEPNOTE_SIGN_ID`, packed into `dist/KeepNote.dmg` with its `.sha256` |
| `./Scripts/test.sh` | the test suites; they use temporary databases and never touch your notes |

`KEEPNOTE_SDK=/path/to/MacOSX.sdk` overrides the SDK the build picks.

## Shortcuts

These are the defaults. Every shortcut below except Close can be changed in Settings → Shortcuts: click it and press the new combination, which needs ⌘, ⌥ or ⌃. Esc cancels, Delete leaves the command without a shortcut, and **Restore Defaults** brings these back. A combination another KeepNote command already uses, or one the system refuses because another app holds it, is not taken; the field says why. Your shortcuts are kept on this Mac, and the menus, tooltips and the welcome window always show the current ones. The formatting shortcuts are fixed.

| Global, from any app | What it does |
|---|---|
| `⌥⌘N` | New note |
| `⌥⌘A` | All Notes |
| `⌥⌘E` | Archive |
| `⌥⌘Y` | Today's Daily |
| `⌃⌥⌘D` | Focus Deck (arrows, Return, Space, Esc) |

| In a note | What it does |
|---|---|
| `esc` / `⌘W` | Close |
| `⌘F` | Find in the note |
| `⌘G` / `⇧⌘G` | Next / previous match |
| `⌥⌘C` / `⇧⌥⌘C` | Next / previous color |
| `⌥⌘P` | Float Note / Return to Deck |
| `⇧⌘E` | Archive / bring back |
| `⇧⌘⌫` | Delete (undoable) |
| `⌘↩` | Tick or untick the task |
| `⇥` / `⇧⇥` | Indent / outdent a list item |
| `Space` | Quick Look on the selected image or file |

| In All Notes | What it does |
|---|---|
| `↑` / `↓` | Previous / next note in the list |
| `↩` | Into the selected note's text |
| `esc` | From the note back to the list |

| Formatting | What it does |
|---|---|
| `⌘B` `⌘I` `⇧⌘X` | Bold, italic, strikethrough |
| `⇧⌘H` | Highlight |
| `⌘E` | Inline code |
| `⌘K` | Link |
| `⌥⌘1` `⌥⌘2` `⌥⌘3` | Heading 1, 2, 3 |
| `⇧⌘7` `⇧⌘9` `⇧⌘L` | Bulleted list, numbered list, checklist |
| `⇧⌘B` | Quote |
| `⌥⌘K` | Code block |
| `⌥⌘T` `⌥⌘R` | Table, divider |
| `⇧⌘D` | Today's date |

## Accessibility

- **VoiceOver.** The resting stripe is a button that opens the deck. Each tab reads as the note's title, then its colour and states (pinned, kept on deck, floating, daily, archives in N days), in the order the tabs are drawn; its actions menu (VO-Shift-M) has the right-click commands. Every icon-only control in a note has a label and a hint, checklist items are checkboxes VoiceOver can tick, tag chips have a *Remove tag* action, and the colour swatches say which one is chosen. KeepNote announces what changes away from the cursor: a note made, archived, deleted (the notice then takes the keyboard, so Undo is one step away), pinned, floated or back on the deck, tasks brought into a daily, and notes archived by the time rule.
- **Keyboard.** **Focus Deck** (`⌃⌥⌘D`, changeable) gives the deck the keyboard: the arrows or Tab move between the tabs and the buttons, Space shows the peek, Return opens, Esc gives the keyboard back. `⌘↩` ticks the task the caret is on. In All Notes, ↑ and ↓ move through the list, Return goes into the selected note and Esc comes back. With System Settings → Keyboard → *Keyboard navigation* on, Tab reaches every button of notes, All Notes and Settings, with a focus ring in the note's ink that shows on every paper colour. Every global and in-note shortcut can be recorded again in Settings → Shortcuts.
- **Display.** *Increase contrast* firms up outlines, the perforation and quiet text; *Reduce transparency* makes the stripe, chips and notices solid; *Reduce motion* turns the deck's and notes' movement into fades. Settings → General → **Text size** (Small to Extra Large) sizes the text of notes, the peek and All Notes. Text on every paper colour is at least 4.5:1, with and without Increase contrast, and no state is shown by colour alone.

## Privacy

KeepNote makes no network connection. It has no server, account, telemetry or analytics, and its entitlements (`Resources/KeepNote.entitlements`) are the sandbox, folders you choose, and bookmarks to them, nothing more. A link inside a note opens in your browser.

The text of your notes is encrypted in the local database (AES-GCM) with a key kept in this Mac's Keychain, which never leaves it and is not synced. Images and files attached to notes are encrypted the same way. Note titles and tags are stored unencrypted so they can be searched; the synced `.hmnote` files are plain text, so they stay readable without the app and are protected by whatever protects the folder.

The database lives at `~/Library/Containers/com.keepnote.KeepNote/Data/Library/Application Support/KeepNote/notes.sqlite`, and its backups in the `Backups` folder beside it; they are copies of the database, with the text encrypted the same way.

## Uninstall

Quit KeepNote first (menu bar icon → Quit KeepNote). If **Launch at login** is on, turn it off in Settings → General before you delete the app. Then remove each of these:

| What | Where | How to remove it |
|---|---|---|
| The app | `/Applications/KeepNote.app` | Move it to the Trash. |
| Database (your notes) | `~/Library/Containers/com.keepnote.KeepNote/Data/Library/Application Support/KeepNote/notes.sqlite`, with `notes.sqlite-wal` and `notes.sqlite-shm` beside it | Delete the whole container, `~/Library/Containers/com.keepnote.KeepNote`. In the Finder: Go → Go to Folder…, type `~/Library/Containers`, and move the folder named **KeepNote** to the Trash. |
| Backups (copies of your notes) | `~/Library/Containers/com.keepnote.KeepNote/Data/Library/Application Support/KeepNote/Backups`, up to seven `notes-….sqlite` files | Goes with the container above. To remove only the backups, move the `Backups` folder to the Trash. |
| Preferences | `~/Library/Containers/com.keepnote.KeepNote/Data/Library/Preferences/com.keepnote.KeepNote.plist` | Goes with the container above. |
| Encryption key | Login keychain, password item with service `com.keepnote.KeepNote.bodykey`, account `default` | Keychain Access: search for `com.keepnote.KeepNote.bodykey` and delete it. Or in Terminal: `security delete-generic-password -s com.keepnote.KeepNote.bodykey` |
| Login item | KeepNote itself, registered with macOS (`SMAppService`) when Launch at login is on | Turn off Launch at login before deleting the app. If the app is already gone: System Settings → General → Login Items (Login Items & Extensions on macOS 15 and later), select KeepNote under Open at Login and click −. |

The key only decrypts that database and its backups; remove them together. Once the container is gone, your notes and their backups are gone with it, so export them first (Settings → About → Export All Notes…) if you want to keep them.

**Your sync folder is yours.** KeepNote never deletes it, and uninstalling leaves it, its `.hmnote` and `.hmtemplate` files and its `Attachments` folder exactly where they are. Delete it yourself if you no longer want it.

## License

MIT. See [LICENSE](LICENSE).
