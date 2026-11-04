import Foundation
import CryptoKit

/// What an update must never break: the identity the notes are found by, and an
/// older app meeting notes from a newer one.
@MainActor
func runUpdateSafetyTests() {
    // The bundle identifier, the Keychain item and the folder the database
    // lives in are how an updated app finds its key and its notes. They never
    // change (see the comment in KeychainKeyStore).
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let plist = NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
    expect("identity: bundle identifier", plist?["CFBundleIdentifier"] as? String, "com.keepnote.KeepNote")
    expect("identity: fallback identifier", AppPaths.bundleIdentifier.isEmpty ? nil : "com.keepnote.KeepNote", "com.keepnote.KeepNote")
    expect("identity: Keychain service", KeychainKeyStore.service, "com.keepnote.KeepNote.bodykey")
    expect("identity: Keychain account", KeychainKeyStore.account, "default")
    expect("identity: database file", AppPaths.databaseURL.lastPathComponent, "notes.sqlite")
    expect("identity: database folder", AppPaths.databaseURL.deletingLastPathComponent().lastPathComponent, "KeepNote")

    // An app with a smaller schema opens a database with a bigger one.
    let key = SymmetricKey(size: .bits256)
    let url = scratchDirectory().appendingPathComponent("notes.sqlite")
    var store: NoteStore? = reopened(url, key: key)
    _ = try! store!.create(title: "From the future", body: "must stay as it is")
    store!.waitUntilSaved()
    store = nil
    let newer = NoteSchema.currentVersion + 1
    do {
        let db = try! SQLiteDatabase(path: url.path)
        try! db.execute("CREATE TABLE from_a_newer_version (x TEXT);")
        db.userVersion = newer
    }
    func snapshot() -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map {
            ($0, (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent($0))) ?? Data())
        })
    }
    let before = snapshot()
    var refused: NoteSchema.NewerThanApp?
    do { _ = try NoteStore(databaseURL: url, cipher: BodyCipher(key: key)) }
    catch { refused = error as? NoteSchema.NewerThanApp }
    expectTrue("newer notes: the store refuses to open", refused != nil)
    expect("newer notes: and says which version it found", refused.map { String($0.found) }, String(newer))
    let after = snapshot()
    expect("newer notes: the same files", after.keys.sorted().joined(separator: ","), before.keys.sorted().joined(separator: ","))
    expectTrue("newer notes: not one byte written", after == before)
    expectTrue("newer notes: no backup made", !FileManager.default.fileExists(
        atPath: Backups.directory(for: url).path))
    do {
        let db = try! SQLiteDatabase(readOnlyPath: url.path)
        expect("newer notes: the version is untouched", String(db.userVersion), String(newer))
        expect("newer notes: the notes are still there", String(try! db.scalarInt("SELECT COUNT(*) FROM notes;")), "1")
    }

    // The warning, in both languages, and the site it points to.
    let key1 = "These notes are from a newer version of KeepNote. Install the latest version."
    expect("newer notes: English", L(key1, in: "en"), key1)
    expect("newer notes: Portuguese", L(key1, in: "pt-BR"),
           "Estas notas são de uma versão mais nova do KeepNote. Instale a versão mais recente.")
    expect("newer notes: the link is the site", AppInfo.siteURL.absoluteString, "https://colletpedro.github.io/keepnote/")

    // The same database at the app's own version, and a missing one, still open.
    do {
        let db = try! SQLiteDatabase(path: url.path)
        db.userVersion = NoteSchema.currentVersion
    }
    var opened = false
    do { _ = try NoteStore(databaseURL: url, cipher: BodyCipher(key: key)); opened = true } catch {}
    expectTrue("newer notes: at the app's own version it opens", opened)
    expectTrue("newer notes: a first launch is not refused",
               (try? NoteSchema.refuseIfNewer(at: scratchDirectory().appendingPathComponent("none.sqlite"))) != nil)
}
