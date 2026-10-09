import AppKit
import Combine
import Foundation

/// Optional folder sync: one flat `.hmnote` per note in a folder the user
/// picks, with no server and no CloudKit. Whatever provider owns that folder —
/// iCloud Drive by default, but Dropbox or a plain local folder work the same —
/// is what moves the bytes between Macs.
///
/// Four things make this survivable in practice:
///
/// 1. **Security-scoped bookmarks.** The sandbox forgets a folder grant when
///    the app quits; the bookmark is what brings it back.
/// 2. **Coordinated, atomic writes.** `NSFileCoordinator` keeps the iCloud
///    daemon from reading a half-written file, and `.atomic` keeps a crash from
///    leaving one.
/// 3. **Tombstones.** An iCloud folder can legitimately show a file as missing
///    while it is still only a placeholder. Treating absence as deletion would
///    propagate that to every other Mac, so deletion is only ever a file that
///    says so.
/// 4. **Last-writer-wins on `updatedAt`.** Simple, and honest about its limits:
///    a badly skewed clock or two truly simultaneous edits will lose one side.
///    Conflict copies from iCloud are detected and kept, never silently
///    dropped.
@MainActor
final class FolderSyncService: NSObject, ObservableObject {
    @Published private(set) var status: Status = .off
    @Published private(set) var folderDisplayName: String?

    enum Status: Equatable {
        case off
        case active
        case needsFolder
        case failed(String)

        var summary: String {
            switch self {
            case .off: return "Off"
            case .active: return "Syncing"
            case .needsFolder: return "Choose a folder"
            case .failed(let message): return message
            }
        }
    }

    private let store: NoteStore
    private var folderURL: URL?
    private var isAccessingScope = false
    private var presenter: SyncFolderPresenter?
    private var metadataQuery: NSMetadataQuery?
    private var folderWatcher: FolderWatcher?
    private var cancellables: Set<AnyCancellable> = []

    /// The `updatedAt` of the copy the folder holds for each note, as last
    /// written or read here. A note already there as it is is not written
    /// again, and a file that only says what is already known — our own write
    /// coming back around — is not applied.
    private var folderHolds: [UUID: Held] = [:]
    /// The same for the daily template's file.
    private var templateHeld: Held?

    /// A date written here is exact. One read from a file is only kept there
    /// to the millisecond, so it stands for any moment within that.
    private struct Held {
        var date: Date
        var isExact: Bool

        func matches(_ other: Date) -> Bool {
            isExact ? date == other : abs(date.timeIntervalSince(other)) < 0.001
        }
    }

    /// Modification date of each file as last written or read, kept on `io`.
    /// A change notification for a file still carrying that date is the echo
    /// of our own write (or a repeat), and the file is not read again.
    private let stamps = FileStamps()

    /// Every coordinated read and write, one at a time and in order. A
    /// coordinated call can wait on the provider's daemon for as long as it
    /// likes; that wait belongs here, not on the main thread.
    private let io = DispatchQueue(label: "com.keepnote.sync.io", qos: .utility)

    /// A folder handed in directly, bypassing the setting and the bookmark.
    /// Only `Scripts/bench.sh` passes one, for its temporary folder.
    private let fixedFolder: URL?

    init(store: NoteStore, folder: URL? = nil) {
        self.store = store
        self.fixedFolder = folder
        super.init()

        store.changes
            .sink { [weak self] event in
                let (change, origin) = event
                // A change we just applied from the folder must not be written
                // straight back out to it.
                guard origin != .sync else { return }
                self?.handle(change)
            }
            .store(in: &cancellables)

        store.templateChanges
            .sink { [weak self] origin in
                guard origin != .sync else { return }
                self?.pushTemplate()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .keepNoteSyncSettingsChanged)
            .sink { [weak self] _ in self?.reconfigure() }
            .store(in: &cancellables)

        reconfigure()
    }

    // MARK: - Configuration

    func reconfigure() {
        teardown()
        if let fixedFolder {
            start(in: fixedFolder)
            return
        }
        guard AppSettings.shared.syncEnabled else {
            status = .off
            folderDisplayName = nil
            return
        }
        guard let url = resolveBookmark() else {
            status = .needsFolder
            return
        }
        start(in: url)
    }

    private func start(in url: URL) {
        folderURL = url
        folderDisplayName = url.lastPathComponent
        startWatching(url)
        status = .active
        folderHolds = [:]
        templateHeld = nil
        let stamps = stamps
        io.async { stamps.dates = [:] }
        // Read the folder, then write what is newer here: a note created while
        // sync was off reaches the folder, anything newer in the folder wins
        // on merge, and nothing the folder already holds is written again.
        pullAll { [weak self] in self?.pushAll() }
    }

    /// The only place a folder is granted. `NSOpenPanel` is what the sandbox
    /// accepts as consent; the bookmark preserves it across launches.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Pick a folder for your notes. iCloud Drive keeps them in sync between Macs."
        panel.directoryURL = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            AppSettings.shared.syncFolderBookmark = bookmark
            AppSettings.shared.syncEnabled = true
            reconfigure()
        } catch {
            status = .failed("Could not keep access to that folder: \(error.localizedDescription)")
        }
    }

    func forgetFolder() {
        teardown()
        AppSettings.shared.syncFolderBookmark = nil
        AppSettings.shared.syncEnabled = false
        status = .off
        folderDisplayName = nil
    }

    private func resolveBookmark() -> URL? {
        guard let bookmark = AppSettings.shared.syncFolderBookmark else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale,
               let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                AppSettings.shared.syncFolderBookmark = refreshed
            }
            isAccessingScope = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            status = .failed("The sync folder could not be reopened: \(error.localizedDescription)")
            return nil
        }
    }

    private func teardown() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter = nil
        metadataQuery?.stop()
        metadataQuery = nil
        folderWatcher?.stop()
        folderWatcher = nil
        if isAccessingScope, let folderURL {
            folderURL.stopAccessingSecurityScopedResource()
        }
        isAccessingScope = false
        folderURL = nil
    }

    // MARK: - Watching

    private func startWatching(_ url: URL) {
        let presenter = SyncFolderPresenter(folder: url) { [weak self] changed in
            Task { @MainActor in
                self?.pull(from: changed)
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter

        if isUbiquitous(url) {
            // Inside iCloud a file can exist without being downloaded yet. Only
            // NSMetadataQuery sees those, and only it can ask for the download.
            startMetadataQuery(for: url)
        } else {
            // Any other provider — Dropbox, Syncthing, a shared volume — writes
            // without coordinating, so the presenter above would never hear it.
            folderWatcher = FolderWatcher(folder: url) { [weak self] changed in
                Task { @MainActor in self?.pull(from: changed) }
            }
        }
    }

    private func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    private func startMetadataQuery(for url: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            AppPaths.noteFileExtension, AppPaths.templateFileExtension,
        ].map { NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\($0)") })

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleMetadataUpdate(notification) }
        }
        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleMetadataUpdate(notification) }
        }

        query.start()
        metadataQuery = query
    }

    private func handleMetadataUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        // An update names the items that were added or changed; only the
        // first gathering has to walk every result.
        let items: [NSMetadataItem]
        if notification.name == .NSMetadataQueryDidUpdate {
            let info = notification.userInfo
            items = ((info?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? [])
                + ((info?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? [])
        } else {
            items = (0..<query.resultCount).compactMap { query.result(at: $0) as? NSMetadataItem }
        }

        var changed: [URL] = []
        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  isInsideSyncFolder(url)
            else { continue }

            let downloaded = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if downloaded == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded {
                // Ask for it; the next update will carry the contents.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }

            if let hasConflicts = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool,
               hasConflicts {
                if url.pathExtension == AppPaths.templateFileExtension {
                    resolveTemplateConflicts(at: url)
                } else {
                    resolveConflicts(at: url)
                }
                continue
            }

            changed.append(url)
        }
        pull(from: changed)
    }

    private func isInsideSyncFolder(_ url: URL) -> Bool {
        guard let folderURL else { return false }
        return url.deletingLastPathComponent().standardizedFileURL == folderURL.standardizedFileURL
    }

    /// iCloud writes a conflicting edit as a separate version rather than
    /// overwriting. Both sides are read, the newer one wins, and the loser is
    /// kept on disk as a `.conflict` file instead of vanishing.
    private func resolveConflicts(at url: URL) {
        let presenter = presenter
        io.async { [weak self] in
            guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else {
                let current = Self.readFile(at: url, presenter: presenter)
                Task { @MainActor in self?.apply(current.map { [$0] } ?? []) }
                return
            }
            var candidates: [HMNoteFile] = []
            if let current = Self.readFile(at: url, presenter: presenter) { candidates.append(current) }

            for version in versions {
                if let text = try? String(contentsOf: version.url, encoding: .utf8),
                   let parsed = HMNoteFile.parse(text) {
                    candidates.append(parsed)
                    let keep = url
                        .deletingPathExtension()
                        .appendingPathExtension("conflict-\(Int(version.modificationDate?.timeIntervalSince1970 ?? 0)).\(AppPaths.noteFileExtension)")
                    try? FileManager.default.copyItem(at: version.url, to: keep)
                }
                version.isResolved = true
            }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)

            guard let winner = candidates.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
            Task { @MainActor in self?.apply([winner]) }
        }
    }

    /// The template's version of the same: the newest wins, the others are
    /// kept beside it as `.conflict` files.
    private func resolveTemplateConflicts(at url: URL) {
        let presenter = presenter
        io.async { [weak self] in
            var candidates: [DailyTemplate] = []
            if let current = Self.readTemplate(at: url, presenter: presenter) { candidates.append(current) }
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                if let text = try? String(contentsOf: version.url, encoding: .utf8),
                   let parsed = DailyTemplateFile.parse(text) {
                    candidates.append(parsed)
                    let keep = url
                        .deletingPathExtension()
                        .appendingPathExtension("conflict-\(Int(version.modificationDate?.timeIntervalSince1970 ?? 0)).\(AppPaths.templateFileExtension)")
                    try? FileManager.default.copyItem(at: version.url, to: keep)
                }
                version.isResolved = true
            }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            guard let winner = candidates.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
            Task { @MainActor in self?.applyTemplate(winner) }
        }
    }

    // MARK: - Pull

    /// Files are read on `io`, in order with the writes, and applied back here
    /// in one batch.
    private func pullAll(then completion: (@MainActor () -> Void)? = nil) {
        guard let folderURL else { return }
        let presenter = presenter
        let stamps = stamps
        io.async { [weak self] in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let files = contents
                .filter { $0.pathExtension == AppPaths.noteFileExtension }
                .compactMap { Self.readFileIfChanged(at: $0, presenter: presenter, stamps: stamps) }
            let template = contents
                .filter { $0.pathExtension == AppPaths.templateFileExtension }
                .compactMap { Self.readTemplateIfChanged(at: $0, presenter: presenter, stamps: stamps) }
                .max { $0.updatedAt < $1.updatedAt }
            Task { @MainActor in
                self?.apply(files)
                if let template { self?.applyTemplate(template) }
                completion?()
            }
        }
    }

    private func pull(from url: URL) {
        pull(from: [url])
    }

    private func pull(from urls: [URL]) {
        // A change reported on the folder itself means "something in here moved";
        // the only safe answer is to re-read the directory.
        if urls.contains(where: { $0.standardizedFileURL == folderURL?.standardizedFileURL }) {
            pullAll()
            return
        }
        let wanted = urls.filter { $0.pathExtension == AppPaths.noteFileExtension }
        let wantedTemplates = urls.filter { $0.pathExtension == AppPaths.templateFileExtension }
        guard !wanted.isEmpty || !wantedTemplates.isEmpty else { return }
        let presenter = presenter
        let stamps = stamps
        io.async { [weak self] in
            let files = wanted.compactMap { Self.readFileIfChanged(at: $0, presenter: presenter, stamps: stamps) }
            let template = wantedTemplates
                .compactMap { Self.readTemplateIfChanged(at: $0, presenter: presenter, stamps: stamps) }
                .max { $0.updatedAt < $1.updatedAt }
            Task { @MainActor in
                if !files.isEmpty { self?.apply(files) }
                if let template { self?.applyTemplate(template) }
            }
        }
    }

    private func apply(_ files: [HMNoteFile]) {
        // Our own writes coming back around, or a file already applied.
        let fresh = files.filter { file in
            guard let held = folderHolds[file.id] else { return true }
            return abs(held.date.timeIntervalSince(file.updatedAt)) >= 0.001
        }
        for file in fresh { folderHolds[file.id] = Held(date: file.updatedAt, isExact: false) }
        guard !fresh.isEmpty else { return }
        do {
            for file in fresh where file.isTombstone {
                if let deletedAt = file.deletedAt {
                    try store.applyIncomingTombstone(id: file.id, deletedAt: deletedAt)
                }
            }
            try store.applyIncoming(fresh.filter { !$0.isTombstone }.map(\.note))
        } catch {
            status = .failed("Could not apply a change from the folder: \(error.localizedDescription)")
        }
    }

    private func applyTemplate(_ template: DailyTemplate) {
        // Our own write coming back around, or a file already applied.
        if let held = templateHeld, held.matches(template.updatedAt) { return }
        templateHeld = Held(date: template.updatedAt, isExact: false)
        store.applyIncomingTemplate(template)
    }

    nonisolated private static func readTemplateIfChanged(at url: URL, presenter: NSFilePresenter?, stamps: FileStamps) -> DailyTemplate? {
        let modified = FileStamps.modificationDate(of: url)
        if let modified, stamps.dates[url.lastPathComponent] == modified { return nil }
        let template = readTemplate(at: url, presenter: presenter)
        if let modified { stamps.dates[url.lastPathComponent] = modified }
        return template
    }

    nonisolated private static func readTemplate(at url: URL, presenter: NSFilePresenter?) -> DailyTemplate? {
        var result: DailyTemplate?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            guard let text = try? String(contentsOf: readURL, encoding: .utf8) else { return }
            result = DailyTemplateFile.parse(text)
        }
        return result
    }

    /// Reads a file unless it still has the modification date it had when it
    /// was last written or read here. Runs on `io`.
    nonisolated private static func readFileIfChanged(at url: URL, presenter: NSFilePresenter?, stamps: FileStamps) -> HMNoteFile? {
        let modified = FileStamps.modificationDate(of: url)
        if let modified, stamps.dates[url.lastPathComponent] == modified { return nil }
        let file = readFile(at: url, presenter: presenter)
        if let modified { stamps.dates[url.lastPathComponent] = modified }
        return file
    }

    nonisolated private static func readFile(at url: URL, presenter: NSFilePresenter?) -> HMNoteFile? {
        var result: HMNoteFile?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            guard let text = try? String(contentsOf: readURL, encoding: .utf8) else { return }
            result = HMNoteFile.parse(text)
        }
        return result
    }

    // MARK: - Push

    private func handle(_ change: StoreChange) {
        guard status == .active else { return }
        switch change {
        case .inserted(let id), .updated(let id), .stateChanged(let id), .restored(let id):
            if let note = store.note(id: id) {
                push(note)
            }
        case .softDeleted:
            // Still undoable — nothing leaves the folder yet.
            break
        case .batch(let ids):
            for id in ids {
                if let note = store.note(id: id) { push(note) }
            }
        case .purged(let id):
            pushTombstone(id: id)
        case .reloaded:
            pushAll()
        }
    }

    /// Every note the folder does not already hold as it is here. After a
    /// reorder — the other `.reloaded` — that is none: the order is not in
    /// the files.
    private func pushAll() {
        guard status == .active else { return }
        for note in store.allNotesForSync() {
            push(note)
        }
        pushTemplate()
    }

    /// The template, once it has ever been set; an emptied one is still
    /// written, so that emptying it reaches the other Macs.
    private func pushTemplate() {
        guard status == .active, let folderURL else { return }
        let template = store.dailyTemplate
        guard template.isSet else { return }
        if let held = templateHeld, held.matches(template.updatedAt) { return }
        write(contents: DailyTemplateFile.serialized(template), to: folderURL.appendingPathComponent(DailyTemplateFile.fileName))
        templateHeld = Held(date: template.updatedAt, isExact: true)
    }

    private func push(_ note: Note) {
        // A locked note's body is a placeholder, not the user's text.
        guard !note.isLocked, let folderURL else { return }
        // Already there as it is.
        if let held = folderHolds[note.id], held.matches(note.updatedAt) { return }
        let file = HMNoteFile(note: note)
        write(contents: file.serialized(), to: folderURL.appendingPathComponent(file.fileName))
        folderHolds[note.id] = Held(date: note.updatedAt, isExact: true)
    }

    private func pushTombstone(id: UUID) {
        guard let folderURL else { return }
        let deletedAt = Date()
        let file = HMNoteFile.tombstone(id: id, deletedAt: deletedAt)
        write(contents: file.serialized(), to: folderURL.appendingPathComponent(file.fileName))
        folderHolds[id] = Held(date: deletedAt, isExact: true)
    }

    /// Coordinated so the provider's daemon never sees a partial file, atomic
    /// so a crash mid-write cannot leave one either. Queued on `io`, so the
    /// main thread never waits on the provider, and in order, so the newest
    /// version of a file is the one left in the folder.
    private func write(contents: String, to url: URL) {
        let presenter = presenter
        let stamps = stamps
        io.async { [weak self] in
            var failure: Error?
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: presenter)
            coordinator.coordinate(
                writingItemAt: url,
                options: [.forReplacing],
                error: &coordinationError
            ) { writeURL in
                do {
                    try contents.write(to: writeURL, atomically: true, encoding: .utf8)
                } catch {
                    failure = error
                }
            }
            if let modified = FileStamps.modificationDate(of: url) {
                stamps.dates[url.lastPathComponent] = modified
            }
            guard let error = failure ?? coordinationError else { return }
            let message = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            Task { @MainActor in self?.status = .failed(message) }
        }
    }

    /// Blocks until every file queued so far is written. For quitting, and
    /// for tests.
    func waitUntilWritten() {
        io.sync {}
    }
}

/// File name to modification date, for the sync folder. Only ever touched on
/// the sync service's `io` queue.
final class FileStamps: @unchecked Sendable {
    var dates: [String: Date] = [:]

    static func modificationDate(of url: URL) -> Date? {
        var url = url
        url.removeCachedResourceValue(forKey: .contentModificationDateKey)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Watches the sync folder. `NSFilePresenter` is the documented way to be told
/// about iCloud's own writes, and registering one is also what makes our
/// coordinated writes visible to the daemon rather than fighting it.
///
/// Handed to coordinators on the sync service's `io` queue; everything it holds
/// is immutable, so that is safe.
final class SyncFolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: (URL) -> Void

    init(folder: URL, onChange: @escaping (URL) -> Void) {
        self.presentedItemURL = folder
        self.onChange = onChange
        let queue = OperationQueue()
        queue.name = "com.keepnote.sync.presenter"
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        super.init()
    }

    func presentedSubitemDidChange(at url: URL) {
        onChange(url)
    }

    func presentedSubitemDidAppear(at url: URL) {
        onChange(url)
    }

    func presentedItemDidChange() {
        guard let presentedItemURL else { return }
        onChange(presentedItemURL)
    }

    /// A file disappearing is *not* a deletion — see the tombstone note above.
    /// Nothing is applied here on purpose.
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(nil)
    }
}
