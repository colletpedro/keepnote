import Combine
import Foundation

/// How a change reached the store. Sync echoes are tagged so the folder writer
/// does not bounce a file back to the machine it came from.
enum ChangeOrigin: Sendable {
    case local
    case sync
    case importer
}

enum StoreChange: Sendable {
    case inserted(UUID)
    case updated(UUID)
    case stateChanged(UUID)
    case softDeleted(UUID)
    case restored(UUID)
    case purged(UUID)
    /// Many notes inserted or updated in one go — an import, a batch of new
    /// notes, a burst from the sync folder — announced once instead of once
    /// per note.
    case batch([UUID])
    case reloaded
}

/// A note about to be created: what the caller chooses, the store fills in
/// the rest.
struct NoteDraft: Sendable {
    var title: String = ""
    var body: String = ""
    var color: NoteColor?
    var tags: [String] = []
}

/// The single source of truth for notes.
///
/// The UI reads an in-memory model on the main actor — notes, the undo window,
/// tombstones — and every change lands there first, synchronously, then goes to
/// `StoreWriter`, which seals the body and writes SQLite on its own serial
/// queue. The queue keeps the writes in the order they were made, so the
/// database always ends on the latest one; `waitUntilSaved()` is how quitting
/// makes sure it got there.
///
/// Body search runs over the decrypted bodies held here: an FTS index over the
/// body would write plaintext back to disk and undo the encryption. Title and
/// tag search runs in memory too (`SearchText`), with the rules of the FTS index
/// the writer still keeps on disk.
@MainActor
final class NoteStore: ObservableObject {
    /// Every note the user still has, deleted ones excluded. Ordered by
    /// `sortIndex`, which is also the order the stack fans out in.
    @Published private(set) var notes: [Note] = []

    /// Notes inside their undo window: gone from the UI, still in the database.
    @Published private(set) var pendingDeletions: [UUID: Note] = [:]

    /// Fires after every change so sync and the panels can react.
    let changes = PassthroughSubject<(StoreChange, ChangeOrigin), Never>()

    /// A write the database refused. The change is already in memory, so the
    /// app says so instead of losing it silently.
    let writeFailures = PassthroughSubject<Error, Never>()

    /// Fires when a note becomes a daily: it received the tag, was created
    /// with it, or arrived with it. The archive rule runs on it.
    let dailyArrived = PassthroughSubject<Void, Never>()

    /// The text new daily notes start from. Not a note: it is kept apart from
    /// `notes`, so no list, search or tag ever includes it.
    @Published private(set) var dailyTemplate = DailyTemplate.empty

    /// Fires after the template changes, for sync to carry it to the folder.
    let templateChanges = PassthroughSubject<ChangeOrigin, Never>()

    /// The clock daily notes read to know what day it is. Tests replace it.
    var now: () -> Date = { Date() }

    var today: DailyDay { DailyDay(now()) }

    private let writer: StoreWriter
    private var tombstones: [UUID: Date] = [:]
    private var purgeTimers: [UUID: Timer] = [:]

    /// `now` is the clock the store reads from the start — launching on a
    /// given day settles the notes it finds with that day.
    init(databaseURL: URL = AppPaths.databaseURL, cipher: BodyCipher, now: @escaping () -> Date = { Date() }) throws {
        self.now = now
        self.writer = try StoreWriter(databaseURL: databaseURL, cipher: cipher)
        writer.onFailure = { [weak self] error in
            Task { @MainActor in self?.writeFailures.send(error) }
        }
        try reload()
        purgeExpiredDeletions()
    }

    /// The note with its daily fields the way its tags say they should be,
    /// and a day it was last opened on.
    private func settleDaily(_ note: Note) -> Note {
        var note = note
        let settled = DailyNotes.settled(tags: note.tags, day: note.dailyDay, kept: note.dailyKept, today: today)
        note.dailyDay = settled.day
        note.dailyKept = settled.kept
        note.lastOpenedDay = AutoArchive.settled(note.lastOpenedDay, today: today)
        return note
    }

    // MARK: - Reading

    var activeNotes: [Note] {
        notes.filter { $0.state == .active }
    }

    var archivedNotes: [Note] {
        notes.filter { $0.state == .archived && !$0.isDaily }
            .sorted { $0.editedAt > $1.editedAt }
    }

    func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    /// Rebuilds the in-memory model from SQLite, once every write already made
    /// has landed. Called at launch.
    func reload() throws {
        let loaded = try writer.load()
        var live: [Note] = []
        var deleted: [UUID: Note] = [:]
        var repaired: [Note] = []
        for note in loaded.notes {
            if note.deletedAt != nil {
                deleted[note.id] = note
            } else {
                let settled = settleDaily(note)
                if settled != note { repaired.append(settled) }
                live.append(settled)
            }
        }
        // A note tagged `daily` before the day existed is given today, and a
        // note never opened since the time rule existed starts counting from
        // today; the edit date stays, since nobody edited it.
        if !repaired.isEmpty { writer.save(repaired.map { .update($0) }) }
        notes = live
        pendingDeletions = deleted
        tombstones = loaded.tombstones
        dailyTemplate = loaded.template
        changes.send((.reloaded, .local))
    }

    /// Blocks until every change made so far is in the database. For quitting,
    /// and for tests; nothing else needs to wait.
    func waitUntilSaved() {
        writer.waitUntilIdle()
    }

    // MARK: - Searching

    enum SearchScope: String, CaseIterable, Identifiable, Sendable {
        case all, active, archived
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .archived: return "Archived"
            }
        }
    }

    /// Title and tags match term by term, as prefixes; the body matches as one
    /// substring. A hit in either place shows the note once.
    func search(_ query: String, scope: SearchScope = .all) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = notes.filter { note in
            switch scope {
            case .all: return true
            case .active: return note.state == .active
            // Archived dailies are kept under Daily, not in the archive.
            case .archived: return note.state == .archived && !note.isDaily
            }
        }
        guard !trimmed.isEmpty else { return pool }
        let terms = SearchText.terms(trimmed)
        return pool.filter { note in
            SearchText.matches(terms: terms, title: note.title, tags: note.tags) || note.matches(query: trimmed)
        }
    }

    // MARK: - Creating and updating

    @discardableResult
    func create(color: NoteColor? = nil, title: String = "", body: String = "", tags: [String] = []) throws -> Note {
        try create([NoteDraft(title: title, body: body, color: color, tags: tags)])[0]
    }

    /// Several notes in one transaction and one change. Each goes on top of
    /// the one before, the way creating them one at a time would leave them.
    @discardableResult
    func create(_ drafts: [NoteDraft]) throws -> [Note] {
        guard !drafts.isEmpty else { return [] }
        var topIndex = (notes.map(\.sortIndex).min() ?? 0) - 1
        var previousColor = notes.max(by: { $0.createdAt < $1.createdAt })?.color
        let created = drafts.map { draft -> Note in
            // New notes walk the palette instead of repeating one colour, so
            // a stack is legible at a glance.
            let color = draft.color ?? previousColor?.next ?? .default
            previousColor = color
            defer { topIndex -= 1 }
            return settleDaily(Note(
                title: draft.title,
                body: draft.body,
                color: color,
                state: .active,
                sortIndex: topIndex,
                tags: Note.normalizeTags(draft.tags)
            ))
        }
        insert(created, origin: .local)
        if created.contains(where: \.isDaily) { dailyArrived.send() }
        return created
    }

    func insert(_ note: Note, origin: ChangeOrigin) throws {
        insert([note], origin: origin)
    }

    private func insert(_ batch: [Note], origin: ChangeOrigin) {
        for note in batch { tombstones.removeValue(forKey: note.id) }
        apply(batch)
        writer.save(batch.map { .insert($0) })
        announce(batch.map(\.id), single: StoreChange.inserted, origin: origin)
    }

    /// Brings the in-memory model in line with notes just changed: one
    /// assignment to `notes`, so one redraw however many there were.
    private func apply(_ batch: [Note]) {
        var live = notes
        var positions = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($1.id, $0) })
        var removed = Set<UUID>()
        for note in batch {
            if note.deletedAt == nil {
                if let index = positions[note.id] {
                    live[index] = note
                } else {
                    positions[note.id] = live.count
                    live.append(note)
                }
                pendingDeletions.removeValue(forKey: note.id)
            } else {
                removed.insert(note.id)
                pendingDeletions[note.id] = note
            }
        }
        if !removed.isEmpty { live.removeAll { removed.contains($0.id) } }
        notes = Self.sorted(live)
    }

    private func announce(_ ids: [UUID], single: (UUID) -> StoreChange, origin: ChangeOrigin) {
        guard !ids.isEmpty else { return }
        changes.send((ids.count == 1 ? single(ids[0]) : .batch(ids), origin))
    }

    /// The one write path. Everything else funnels through here so `updatedAt`,
    /// the FTS row and the change feed stay in step.
    func update(id: UUID, origin: ChangeOrigin = .local, touchTimestamp: Bool = true, _ mutate: (inout Note) -> Void) throws {
        guard var note = notes.first(where: { $0.id == id }) ?? pendingDeletions[id] else { return }
        let before = note
        mutate(&note)
        // The tag decides the day: receiving it grants today, losing it clears.
        let daily = DailyNotes.reconcile(
            previousTags: before.tags, tags: note.tags, day: note.dailyDay, kept: note.dailyKept, today: today)
        note.dailyDay = daily.day
        note.dailyKept = daily.kept
        // Locked notes are read-only: text and title stay as they are.
        if note.isLocked {
            note.title = before.title
            note.body = before.body
            note.isLocked = true
        }
        guard note != before else { return }
        if touchTimestamp {
            let stamp = Date()
            note.updatedAt = stamp
            // Only the text counts as an edit. Pinning, keeping, tags, colour
            // and archiving change the note for sync, not what "Edited" says.
            if note.title != before.title || note.body != before.body { note.editedAt = stamp }
        }
        write(note, origin: origin)
        if before.dailyDay == nil && note.dailyDay != nil { dailyArrived.send() }
    }

    private func write(_ note: Note, origin: ChangeOrigin) {
        apply([note])
        writer.save([.update(note)])
        changes.send((.updated(note.id), origin))
    }

    private static func sorted(_ notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            lhs.sortIndex == rhs.sortIndex ? lhs.editedAt > rhs.editedAt : lhs.sortIndex < rhs.sortIndex
        }
    }

    // MARK: - The daily template

    /// A new daily note for today: titled "Daily" and the date, tagged `daily`,
    /// and starting from the template — its variables filled in for today —
    /// with the caret where `DailyTemplate.apply` puts it. This is the only
    /// place the template is ever applied: giving a note the tag never does.
    @discardableResult
    func createDaily(
        color: NoteColor? = nil, locale: Locale = .current, calendar: Calendar = .current
    ) throws -> (note: Note, caret: Int) {
        let date = now()
        let applied = DailyTemplate.apply(dailyTemplate.body, on: date, locale: locale, calendar: calendar)
        let note = try create(
            color: color,
            title: DailyNotes.title(for: date, locale: locale, calendar: calendar),
            body: applied.text,
            tags: [DailyNotes.tag]
        )
        return (note, applied.caret)
    }

    /// Sets the template to `body`. A text that is already the template's
    /// changes nothing — and so is not news to the other Macs.
    func setDailyTemplate(_ body: String, origin: ChangeOrigin = .local) {
        guard body != dailyTemplate.body else { return }
        // Strictly later than the copy here, whatever the clock says, so the
        // edit always wins over the text it replaced.
        let stamp = max(Date(), dailyTemplate.updatedAt.addingTimeInterval(0.001))
        commitTemplate(DailyTemplate(body: body, updatedAt: stamp), origin: origin)
    }

    /// Takes a template that arrived from the sync folder or an archive, if it
    /// is newer than the one here. Returns whether it was taken.
    @discardableResult
    func applyIncomingTemplate(_ incoming: DailyTemplate, origin: ChangeOrigin = .sync) -> Bool {
        guard dailyTemplate.accepts(incoming) else { return false }
        commitTemplate(incoming, origin: origin)
        return true
    }

    private func commitTemplate(_ template: DailyTemplate, origin: ChangeOrigin) {
        dailyTemplate = template
        writer.save([.template(template)])
        templateChanges.send(origin)
    }

    // MARK: - Convenience mutations

    func setBody(_ body: String, id: UUID, origin: ChangeOrigin = .local) throws {
        try update(id: id, origin: origin) { $0.body = body }
    }

    func setTitle(_ title: String, id: UUID, origin: ChangeOrigin = .local) throws {
        try update(id: id, origin: origin) { $0.title = title }
    }

    func setColor(_ color: NoteColor, id: UUID, origin: ChangeOrigin = .local) throws {
        try update(id: id, origin: origin) { $0.color = color }
    }

    func cycleColor(id: UUID, backwards: Bool = false) throws {
        try update(id: id) { $0.color = backwards ? $0.color.previous : $0.color.next }
    }

    func setTags(_ tags: [String], id: UUID, origin: ChangeOrigin = .local) throws {
        try update(id: id, origin: origin) { $0.tags = Note.normalizeTags(tags) }
    }

    /// Writes a tag edit from `TagLibrary` — rename, delete, add, remove —
    /// one note at a time through `update`, so each gets a new `updatedAt`, its
    /// FTS row and a `.local` change the sync folder picks up. Locked notes are
    /// never in `plan.changes`; the plan already counted them. Returns how many
    /// notes were written.
    @discardableResult
    func applyTagPlan(_ plan: TagLibrary.Plan) throws -> Int {
        var written = 0
        for (id, tags) in plan.changes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let note = note(id: id), !note.isLocked else { continue }
            try update(id: id) { $0.tags = Note.normalizeTags(tags) }
            written += 1
        }
        return written
    }

    // MARK: - Archive

    /// Archiving takes the note out of the stack and nothing else: colour,
    /// dates and search presence all survive.
    func archive(id: UUID, origin: ChangeOrigin = .local) throws {
        // An archived note is no longer on the deck, so it cannot stay pinned.
        try update(id: id, origin: origin) {
            $0.state = .archived
            $0.pinnedAt = nil
            $0.autoArchivedDay = nil
        }
        changes.send((.stateChanged(id), origin))
    }

    func unarchive(id: UUID, origin: ChangeOrigin = .local) throws {
        let topIndex = (notes.map(\.sortIndex).min() ?? 0) - 1
        // A daily the rule would archive again, brought back by hand, stays.
        let keeps = DailyNotes.restoreKeeps(id, in: notes)
        let today = today
        try update(id: id, origin: origin) {
            $0.state = .active
            $0.sortIndex = topIndex
            // Brought back: its time starts again.
            $0.lastOpenedDay = today
            $0.autoArchivedDay = nil
            if keeps { $0.dailyKept = true }
        }
        changes.send((.stateChanged(id), origin))
    }

    /// Archives the dailies the rule says are past (`DailyNotes.archivalPlan`),
    /// except those in `open`. Nothing is deleted, and the edit date stays:
    /// this is the rule at work, not an edit, and every Mac that runs it on
    /// the same notes reaches the same state without the files having to
    /// carry it. Returns the notes archived.
    @discardableResult
    func archiveDailies(open: Set<UUID> = []) throws -> [UUID] {
        let plan = DailyNotes.archivalPlan(notes, open: open)
        for id in plan {
            try update(id: id, touchTimestamp: false) { $0.state = .archived }
            changes.send((.stateChanged(id), .local))
        }
        return plan
    }

    /// A note was opened (a window docked or floating, never the peek) or
    /// closed: today is the day its time counts from. Written at most once a
    /// day, and as the rule at work rather than an edit — the edit date stays.
    func markOpened(id: UUID) throws {
        guard let note = note(id: id),
              AutoArchive.shouldRecordOpening(last: note.lastOpenedDay, today: today) else { return }
        let today = today
        try update(id: id, touchTimestamp: false) { $0.lastOpenedDay = today }
    }

    /// Keep on Deck, on or off. An edit like any other: it gets a new
    /// `updatedAt`, so the other Macs take it.
    func setKeepOnDeck(_ on: Bool, id: UUID) throws {
        try update(id: id) { $0.keepOnDeck = on }
    }

    /// How a request to pin or unpin turned out.
    enum PinOutcome: Equatable {
        case done
        /// Already `PinnedDeck.limit` pinned.
        case limitReached
        /// An archived or missing note cannot be pinned: it is not on the deck.
        case notOnDeck
    }

    /// Pin to Center on or off. Pinning also turns Keep on Deck on; unpinning
    /// leaves it as it is. The sixth pin is refused. The pin carries the
    /// moment it was made, which is the order the block is laid out in; it is
    /// always later than every pin there already is.
    @discardableResult
    func setPinned(_ on: Bool, id: UUID) throws -> PinOutcome {
        guard let note = note(id: id) else { return .notOnDeck }
        if !on {
            if note.isPinned { try update(id: id) { $0.pinnedAt = nil } }
            return .done
        }
        if note.isPinned { return .done }
        guard note.state == .active else { return .notOnDeck }
        guard PinnedDeck.canPin(pinned: pinnedNotes.count) else { return .limitReached }
        let latest = pinnedNotes.compactMap(\.pinnedAt).max() ?? .distantPast
        let stamp = max(now(), latest.addingTimeInterval(0.001))
        try update(id: id) {
            $0.pinnedAt = stamp
            $0.keepOnDeck = true
        }
        return .done
    }

    /// The notes pinned on the deck.
    var pinnedNotes: [Note] {
        notes.filter { $0.state == .active && $0.isPinned }
    }

    /// Archives the notes the time rule says have gone unopened too long
    /// (`AutoArchive.plan`), except those in `open`. Like the daily rule it
    /// only archives, leaves the edit date alone and gives every Mac that
    /// runs it on the same notes the same result. Returns the notes archived.
    @discardableResult
    func archiveStale(open: Set<UUID> = [], days: Int) throws -> [UUID] {
        let plan = AutoArchive.plan(notes, open: open, today: today, days: days)
        let today = today
        for id in plan {
            try update(id: id, touchTimestamp: false) {
                $0.state = .archived
                $0.autoArchivedDay = today
            }
            changes.send((.stateChanged(id), .local))
        }
        return plan
    }

    func toggleArchive(id: UUID) throws {
        guard let note = note(id: id) else { return }
        if note.state == .archived {
            try unarchive(id: id)
        } else {
            try archive(id: id)
        }
    }

    // MARK: - Delete with undo

    /// Deleting is a two-step move. The row is stamped `deleted_at` and leaves
    /// the UI immediately; only when the undo window expires is it purged and a
    /// tombstone written for sync.
    func delete(id: UUID, origin: ChangeOrigin = .local) throws {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        var deleted = note
        deleted.deletedAt = Date()
        write(deleted, origin: origin)
        changes.send((.softDeleted(id), origin))
        schedulePurge(for: id, after: AppSettings.shared.undoWindow)
    }

    func undoDelete(id: UUID) throws {
        guard var note = pendingDeletions[id] else { return }
        purgeTimers.removeValue(forKey: id)?.invalidate()
        note.deletedAt = nil
        write(note, origin: .local)
        changes.send((.restored(id), .local))
    }

    private func schedulePurge(for id: UUID, after delay: TimeInterval) {
        purgeTimers.removeValue(forKey: id)?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                try? self?.purge(id: id)
            }
        }
        purgeTimers[id] = timer
    }

    /// Point of no return: the row goes, a tombstone stays so other Macs stop
    /// resurrecting the note from their own copy of the file.
    func purge(id: UUID, origin: ChangeOrigin = .local, deletedAt: Date? = nil) throws {
        purgeTimers.removeValue(forKey: id)?.invalidate()
        // An incoming tombstone carries the moment the *other* Mac deleted the
        // note; stamping "now" here instead would drift the timestamp forward
        // on every hop.
        let deletedAt = deletedAt ?? pendingDeletions[id]?.deletedAt ?? Date()
        tombstones[id] = deletedAt
        pendingDeletions.removeValue(forKey: id)
        notes.removeAll { $0.id == id }
        writer.save([.purge(id, deletedAt: deletedAt)])
        changes.send((.purged(id), origin))
    }

    /// Notes deleted in a session that ended before the timer fired.
    func purgeExpiredDeletions() {
        let cutoff = Date().addingTimeInterval(-AppSettings.shared.undoWindow)
        for (id, note) in pendingDeletions {
            guard let deletedAt = note.deletedAt else { continue }
            if deletedAt <= cutoff {
                try? purge(id: id)
            } else {
                schedulePurge(for: id, after: deletedAt.timeIntervalSince(cutoff))
            }
        }
    }

    /// Held in memory: sync asks for every file it receives.
    func tombstoneIDs() -> [UUID: Date] {
        tombstones
    }

    func recordTombstone(id: UUID, deletedAt: Date) throws {
        tombstones[id] = deletedAt
        writer.save([.tombstone(id, deletedAt: deletedAt)])
    }

    // MARK: - Ordering

    /// Drag-reorder in the stack and in All Notes. Indices are rewritten as a
    /// dense 0..<n range so later inserts at "top" stay predictable.
    func move(id: UUID, to destination: Int) throws {
        var active = activeNotes
        guard let from = active.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(active.count - 1, destination))
        guard from != clamped else { return }
        let moved = active.remove(at: from)
        active.insert(moved, at: clamped)
        reindex(active)
    }

    private func reindex(_ ordered: [Note]) {
        var moves: [(UUID, Int)] = []
        var live = notes
        let positions = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($1.id, $0) })
        for (index, note) in ordered.enumerated() {
            if note.sortIndex != index { moves.append((note.id, index)) }
            if let position = positions[note.id] { live[position].sortIndex = index }
        }
        notes = Self.sorted(live)
        writer.save(moves.map { .sortIndex($0.0, $0.1) })
        changes.send((.reloaded, .local))
    }

    // MARK: - Sync ingress

    /// Applies a note that arrived from the sync folder.
    ///
    /// Last-writer-wins on `updatedAt`: the incoming copy is taken only if it
    /// is strictly newer than what is here, which also makes replayed files
    /// harmless. Anything already tombstoned is refused outright.
    @discardableResult
    func applyIncoming(_ incoming: Note) throws -> Bool {
        try !applyIncoming([incoming]).isEmpty
    }

    /// Many incoming notes in one transaction and one change. Returns the ids
    /// that were new or newer than the copy here, in the order given.
    @discardableResult
    func applyIncoming(_ incoming: [Note], origin: ChangeOrigin = .sync) throws -> [UUID] {
        var accepted: [(note: Note, isNew: Bool)] = []
        var seen: [UUID: Int] = [:]
        let existing = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .merging(pendingDeletions, uniquingKeysWith: { live, _ in live })
        for received in incoming {
            // A file from before dailies existed can carry the tag and no day.
            let candidate = settleDaily(received)
            if let tombstone = tombstones[candidate.id], tombstone >= candidate.updatedAt { continue }
            // The same note twice in one batch: the newer copy is the one compared.
            if let earlier = seen[candidate.id] {
                guard candidate.updatedAt > accepted[earlier].note.updatedAt else { continue }
                var merged = candidate
                merged.sortIndex = accepted[earlier].note.sortIndex
                accepted[earlier].note = merged
                continue
            }
            if let current = existing[candidate.id] {
                // The day it was last opened is the later of the two copies'
                // — a copy that never had one (an older KeepNote wrote it) says
                // nothing — so two Macs end up with the same day.
                let opened = AutoArchive.merged(received.lastOpenedDay, current.lastOpenedDay)
                guard candidate.updatedAt > current.updatedAt else {
                    // Nothing newer, but a later opening is still news.
                    guard current.deletedAt == nil, opened != current.lastOpenedDay else { continue }
                    var merged = current
                    merged.lastOpenedDay = opened
                    seen[candidate.id] = accepted.count
                    accepted.append((merged, false))
                    continue
                }
                var merged = candidate
                merged.lastOpenedDay = opened ?? candidate.lastOpenedDay
                merged.sortIndex = current.sortIndex
                // A file from a KeepNote that did not keep the two dates apart
                // reads as edited whenever it changed at all; if the text is
                // the same as here, nothing was edited.
                if candidate.title == current.title && candidate.body == current.body {
                    merged.editedAt = current.editedAt
                }
                seen[candidate.id] = accepted.count
                accepted.append((merged, false))
            } else {
                seen[candidate.id] = accepted.count
                accepted.append((candidate, true))
            }
        }
        guard !accepted.isEmpty else { return [] }
        for entry in accepted where entry.isNew { tombstones.removeValue(forKey: entry.note.id) }
        apply(accepted.map(\.note))
        writer.save(accepted.map { $0.isNew ? .insert($0.note) : .update($0.note) })
        let ids = accepted.map(\.note.id)
        defer { if accepted.contains(where: { $0.note.isDaily }) { dailyArrived.send() } }
        if ids.count == 1 {
            changes.send((accepted[0].isNew ? .inserted(ids[0]) : .updated(ids[0]), origin))
        } else {
            changes.send((.batch(ids), origin))
        }
        return ids
    }

    /// Applies a tombstone that arrived from the sync folder.
    func applyIncomingTombstone(id: UUID, deletedAt: Date) throws {
        if let existing = notes.first(where: { $0.id == id }) ?? pendingDeletions[id] {
            guard deletedAt >= existing.updatedAt else { return }
        }
        try purge(id: id, origin: .sync, deletedAt: deletedAt)
    }

    /// Every note the sync layer should mirror, deleted ones excluded.
    func allNotesForSync() -> [Note] { notes }
}

/// Owns the database connection and the cipher, and does every read and write
/// on one serial queue, off the main thread. Serial is the point: writes land
/// in the order the store made them, so the latest edit of a note is always
/// the one left on disk.
final class StoreWriter: @unchecked Sendable {
    enum Operation: Sendable {
        case insert(Note)
        case update(Note)
        case sortIndex(UUID, Int)
        case purge(UUID, deletedAt: Date)
        case tombstone(UUID, deletedAt: Date)
        case template(DailyTemplate)
    }

    /// Called on the writer's queue when a batch could not be written.
    var onFailure: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.keepnote.store.writer", qos: .userInitiated)
    private let db: SQLiteDatabase
    private let cipher: BodyCipher
    private let hasFTS: Bool

    init(databaseURL: URL, cipher: BodyCipher) throws {
        db = try SQLiteDatabase(path: databaseURL.path)
        self.cipher = cipher
        try NoteSchema.migrate(db)
        hasFTS = NoteSchema.hasFullTextIndex(db)
    }

    /// One batch, one transaction, after everything queued before it.
    func save(_ operations: [Operation]) {
        guard !operations.isEmpty else { return }
        queue.async { [self] in
            do {
                try db.transaction {
                    for operation in operations { try perform(operation) }
                }
            } catch {
                onFailure?(error)
            }
        }
    }

    func waitUntilIdle() {
        queue.sync {}
    }

    /// Every row, bodies opened, once the queue has caught up.
    func load() throws -> (notes: [Note], tombstones: [UUID: Date], template: DailyTemplate) {
        try queue.sync { [self] in
            let notes = try db.query(
                """
                SELECT id, title, body_ciphertext, nonce, color, state, sort_index,
                       tags, created_at, updated_at, deleted_at, daily_day, daily_kept,
                       keep_on_deck, pinned_at, last_opened_day, auto_archived_day,
                       edited_at
                FROM notes
                ORDER BY sort_index ASC, updated_at DESC;
                """
            ) { statement -> Note in
                let id = statement.uuid(at: 0) ?? UUID()
                let body: String
                var isLocked = false
                do {
                    body = try cipher.open(
                        ciphertext: statement.data(at: 2),
                        nonce: statement.data(at: 3)
                    )
                } catch {
                    // A body we cannot open is not a reason to lose the note:
                    // keep the row, show the failure, let the user decide. The
                    // note is locked — read-only — so the placeholder below can
                    // never be sealed over the ciphertext we could not open,
                    // nor pushed to the sync folder as if it were the user's text.
                    isLocked = true
                    body = "\u{26A0}\u{FE0F} This note could not be decrypted with the key on this Mac."
                }
                return Note(
                    id: id,
                    title: statement.string(at: 1),
                    body: body,
                    color: NoteColor.resolve(rawValue: statement.int(at: 4)),
                    state: NoteState(rawValue: statement.string(at: 5)) ?? .active,
                    sortIndex: statement.int(at: 6),
                    tags: Note.parseTags(statement.string(at: 7)),
                    createdAt: statement.date(at: 8),
                    updatedAt: statement.date(at: 9),
                    editedAt: statement.optionalDate(at: 17),
                    deletedAt: statement.optionalDate(at: 10),
                    dailyDay: statement.isNull(at: 11) ? nil : DailyDay(string: statement.string(at: 11)),
                    dailyKept: statement.int(at: 12) != 0,
                    keepOnDeck: statement.int(at: 13) != 0,
                    pinnedAt: statement.optionalDate(at: 14),
                    lastOpenedDay: statement.isNull(at: 15) ? nil : DailyDay(string: statement.string(at: 15)),
                    autoArchivedDay: statement.isNull(at: 16) ? nil : DailyDay(string: statement.string(at: 16)),
                    isLocked: isLocked
                )
            }
            let tombstones = try db.query("SELECT id, deleted_at FROM tombstones;") { statement in
                (statement.uuid(at: 0), statement.date(at: 1))
            }
            .reduce(into: [UUID: Date]()) { result, row in
                if let id = row.0 { result[id] = row.1 }
            }
            return (notes, tombstones, try loadTemplate())
        }
    }

    /// The template, or an empty one when there is none — or when its text
    /// cannot be opened with this Mac's key, which leaves it as if never set.
    private func loadTemplate() throws -> DailyTemplate {
        let rows = try db.query("SELECT body_ciphertext, nonce, updated_at FROM daily_template WHERE id = 1;") { statement in
            (statement.data(at: 0), statement.data(at: 1), statement.date(at: 2))
        }
        guard let row = rows.first, let body = try? cipher.open(ciphertext: row.0, nonce: row.1) else { return .empty }
        return DailyTemplate(body: body, updatedAt: row.2)
    }

    private static func dailyDay(_ note: Note) -> SQLiteValue {
        note.dailyDay.map { .text($0.string) } ?? .null
    }

    private static func autoArchivedDay(_ note: Note) -> SQLiteValue {
        note.autoArchivedDay.map { .text($0.string) } ?? .null
    }

    private static func openedDay(_ note: Note) -> SQLiteValue {
        note.lastOpenedDay.map { .text($0.string) } ?? .null
    }

    private func perform(_ operation: Operation) throws {
        switch operation {
        case .insert(let note):
            let sealed = try cipher.seal(note.body)
            try db.run(
                """
                INSERT INTO notes (id, title, body_ciphertext, nonce, color, state,
                                   sort_index, tags, created_at, updated_at, deleted_at,
                                   daily_day, daily_kept, keep_on_deck, pinned_at, last_opened_day, auto_archived_day, edited_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .uuid(note.id), .text(note.title), .blob(sealed.ciphertext), .blob(sealed.nonce),
                    .integer(note.color.rawValue), .text(note.state.rawValue), .integer(note.sortIndex),
                    .text(note.tagsCSV), .date(note.createdAt), .date(note.updatedAt),
                    .optionalDate(note.deletedAt), Self.dailyDay(note), .integer(note.dailyKept ? 1 : 0),
                    .integer(note.keepOnDeck ? 1 : 0), .optionalDate(note.pinnedAt), Self.openedDay(note),
                    Self.autoArchivedDay(note), .date(note.editedAt),
                ]
            )
            try db.run("DELETE FROM tombstones WHERE id = ?;", [.uuid(note.id)])
            try indexForSearch(note)
        case .update(let note) where note.isLocked:
            // Metadata only: the ciphertext we could not open stays exactly
            // as it is on disk, so a later key restore can still read it.
            try db.run(
                """
                UPDATE notes
                   SET title = ?, color = ?, state = ?, sort_index = ?, tags = ?,
                       created_at = ?, updated_at = ?, deleted_at = ?,
                       daily_day = ?, daily_kept = ?, keep_on_deck = ?, pinned_at = ?, last_opened_day = ?, auto_archived_day = ?, edited_at = ?
                 WHERE id = ?;
                """,
                [
                    .text(note.title), .integer(note.color.rawValue), .text(note.state.rawValue),
                    .integer(note.sortIndex), .text(note.tagsCSV), .date(note.createdAt),
                    .date(note.updatedAt), .optionalDate(note.deletedAt),
                    Self.dailyDay(note), .integer(note.dailyKept ? 1 : 0),
                    .integer(note.keepOnDeck ? 1 : 0), .optionalDate(note.pinnedAt), Self.openedDay(note), Self.autoArchivedDay(note), .date(note.editedAt), .uuid(note.id),
                ]
            )
            try indexForSearch(note)
        case .update(let note):
            let sealed = try cipher.seal(note.body)
            try db.run(
                """
                UPDATE notes
                   SET title = ?, body_ciphertext = ?, nonce = ?, color = ?, state = ?,
                       sort_index = ?, tags = ?, created_at = ?, updated_at = ?, deleted_at = ?,
                       daily_day = ?, daily_kept = ?, keep_on_deck = ?, pinned_at = ?, last_opened_day = ?, auto_archived_day = ?, edited_at = ?
                 WHERE id = ?;
                """,
                [
                    .text(note.title), .blob(sealed.ciphertext), .blob(sealed.nonce),
                    .integer(note.color.rawValue), .text(note.state.rawValue), .integer(note.sortIndex),
                    .text(note.tagsCSV), .date(note.createdAt), .date(note.updatedAt),
                    .optionalDate(note.deletedAt), Self.dailyDay(note), .integer(note.dailyKept ? 1 : 0),
                    .integer(note.keepOnDeck ? 1 : 0), .optionalDate(note.pinnedAt), Self.openedDay(note), Self.autoArchivedDay(note), .date(note.editedAt), .uuid(note.id),
                ]
            )
            try indexForSearch(note)
        case .sortIndex(let id, let index):
            try db.run("UPDATE notes SET sort_index = ? WHERE id = ?;", [.integer(index), .uuid(id)])
        case .purge(let id, let deletedAt):
            try db.run("DELETE FROM notes WHERE id = ?;", [.uuid(id)])
            if hasFTS {
                try db.run("DELETE FROM notes_fts WHERE note_id = ?;", [.uuid(id)])
            }
            try db.run(
                "INSERT OR REPLACE INTO tombstones (id, deleted_at) VALUES (?, ?);",
                [.uuid(id), .date(deletedAt)]
            )
        case .tombstone(let id, let deletedAt):
            try db.run(
                "INSERT OR REPLACE INTO tombstones (id, deleted_at) VALUES (?, ?);",
                [.uuid(id), .date(deletedAt)]
            )
        case .template(let template):
            let sealed = try cipher.seal(template.body)
            try db.run(
                "INSERT OR REPLACE INTO daily_template (id, body_ciphertext, nonce, updated_at) VALUES (1, ?, ?, ?);",
                [.blob(sealed.ciphertext), .blob(sealed.nonce), .date(template.updatedAt)]
            )
        }
    }

    /// Kept on disk with the same rules `SearchText` applies in memory, so
    /// the index stays whole for any build that reads it.
    private func indexForSearch(_ note: Note) throws {
        guard hasFTS else { return }
        try db.run("DELETE FROM notes_fts WHERE note_id = ?;", [.uuid(note.id)])
        guard note.deletedAt == nil else { return }
        try db.run(
            "INSERT INTO notes_fts (note_id, title, tags) VALUES (?, ?, ?);",
            [.uuid(note.id), .text(note.title), .text(note.tags.joined(separator: " "))]
        )
    }
}
