import AppKit
import CryptoKit

// MARK: - Back Up Now and Restore… from Settings

@MainActor
func runRestoreFlowTests() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchDirectory().appendingPathComponent("notes.sqlite")
    let settings = AppSettings.shared
    let savedPending = settings.pendingRestorePath
    defer { settings.pendingRestorePath = savedPending }

    var store: NoteStore? = reopened(url, key: key)
    var coordinator: AppCoordinator? = AppCoordinator(store: store!)
    let id = try! store!.create(title: "Before", body: "as backed up").id

    coordinator!.backUpNow()
    let manual = Backups.list(in: store!.backupDirectory).first
    expectTrue("restore flow: Back Up Now makes a copy", manual?.kind == .manual)
    expect("restore flow: Settings shows it", store!.lastBackup?.url.path, manual?.url.path)
    let title = manual.map { Backups.title($0, notes: Backups.noteCount(of: $0.url)) } ?? ""
    expectTrue("restore flow: the list names its notes and kind (\(title))", title.contains("1 note") && title.contains("Back Up Now"))

    // Afterwards: changed.
    try! store!.setBody("changed later", id: id)
    _ = try! store!.create(title: "New", body: "after")

    // Restore… chosen and confirmed: set aside, the present backed up, and
    // the swap left for the next launch.
    coordinator!.restore(manual!, relaunch: false)
    let pending = settings.pendingRestorePath
    expectTrue("restore flow: the backup waits for the next launch", pending.map { FileManager.default.fileExists(atPath: $0) } == true)
    let kinds = Backups.list(in: store!.backupDirectory).map(\.kind)
    expectTrue("restore flow: the notes as they are now are backed up first", kinds.first == .beforeRestore)
    expect("restore flow: nothing is replaced before the relaunch", store!.note(id: id)?.body, "changed later")
    let directory = store!.backupDirectory
    coordinator = nil
    store = nil

    // The next launch.
    let error = AppDelegate.applyPendingRestore(to: url, settings: settings)
    expectTrue("restore flow: the launch restores it", error == nil)
    expectTrue("restore flow: once", settings.pendingRestorePath == nil)
    expectTrue("restore flow: the waiting copy is gone", pending.map { !FileManager.default.fileExists(atPath: $0) } == true)
    let after = reopened(url, key: key)
    expect("restore flow: the notes are the backup's", after.note(id: id)?.body, "as backed up")
    expect("restore flow: and only those", String(after.notes.count), "1")

    // And the copy of before can bring the later notes back.
    let before = Backups.list(in: directory).first { $0.kind == .beforeRestore }!
    expect("restore flow: the copy made first has the later notes", Backups.noteCount(of: before.url).map(String.init), "2")

    // A launch with a waiting backup that turned out damaged: the database
    // stays, and the launch says why.
    let damaged = directory.appendingPathComponent(".pending-restore.sqlite")
    try! Data(repeating: 7, count: 2048).write(to: damaged)
    settings.pendingRestorePath = damaged.path
    after.waitUntilSaved()
    let bytes = try? Data(contentsOf: url)
    let failure = AppDelegate.applyPendingRestore(to: url, settings: settings)
    expectTrue("restore flow: a damaged one is refused", failure != nil)
    expectTrue("restore flow: the database is as it was", (try? Data(contentsOf: url)) == bytes)
    expectTrue("restore flow: and it is not tried again", settings.pendingRestorePath == nil)
}
