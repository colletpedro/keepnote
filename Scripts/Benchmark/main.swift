import AppKit
import CryptoKit
import ObjectiveC

// Main-thread benchmark. See Scripts/bench.sh.
//
// Every stage runs as work on the main run loop, the way a click or a sync
// callback would, and a run-loop observer records the longest stretch the
// main thread spent without coming back to the run loop: that is how long
// the deck, the peek and every open note would have been frozen.

// MARK: - Nothing on screen

/// The real deck, peek and note windows are built and driven, but never
/// ordered in, and the benchmark never takes focus from the app in front.
extension NSWindow {
    @objc func bench_orderFrontRegardless() {}
    @objc func bench_makeKeyAndOrderFront(_ sender: Any?) {}
    @objc func bench_orderFront(_ sender: Any?) {}
}

extension NSApplication {
    @objc func bench_activate(ignoringOtherApps flag: Bool) {}
}

func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else {
        fatalError("cannot swizzle \(original)")
    }
    method_exchangeImplementations(a, b)
}

swizzle(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.bench_orderFrontRegardless))
swizzle(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.bench_makeKeyAndOrderFront(_:)))
swizzle(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.bench_orderFront(_:)))
swizzle(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.bench_activate(ignoringOtherApps:)))

// MARK: - Measuring

/// The longest time the main thread went between two run-loop activities
/// without sleeping in between.
final class BlockMeter {
    private var last: CFAbsoluteTime = 0
    private var busy = false
    private(set) var maxBlock: Double = 0
    private(set) var lastBusyAt: CFAbsoluteTime = 0
    private var observer: CFRunLoopObserver?

    init() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { [unowned self] _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if self.busy {
                let block = now - self.last
                self.maxBlock = max(self.maxBlock, block)
                if block > 0.004 { self.lastBusyAt = now }
            }
            // Asleep, or outside the run loop altogether (harness code between
            // stages): neither counts.
            self.busy = activity != .beforeWaiting && activity != .exit
            self.last = now
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func reset() {
        maxBlock = 0
        lastBusyAt = CFAbsoluteTimeGetCurrent()
    }
}

let meter = BlockMeter()

/// Runs the main run loop until it has been quiet (no block over 4 ms) for
/// `quiet` seconds, after at least `minimum`, at most `limit`.
func settle(minimum: Double = 0.8, quiet: Double = 0.6, limit: Double = 60) {
    let start = CFAbsoluteTimeGetCurrent()
    while true {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let now = CFAbsoluteTimeGetCurrent()
        if now - start >= limit { break }
        if now - start >= minimum, now - meter.lastBusyAt >= quiet, Bench.isIdle() { break }
    }
}

struct Result: Codable {
    var stage: String
    var notes: Int
    var maxBlockMS: Double
    var wallMS: Double
}

var results: [Result] = []

/// One stage: `work` is posted to the main queue, as an event would be, and
/// the run loop is spun until everything it set off (autosave, sync, echo,
/// animations) has finished.
func stage(_ name: String, notes: Int, settleMinimum: Double = 0.8, _ work: @escaping @MainActor () -> Void) {
    meter.reset()
    let start = CFAbsoluteTimeGetCurrent()
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    settle(minimum: settleMinimum)
    let wall = (meter.lastBusyAt - start) * 1000
    let result = Result(stage: name, notes: notes, maxBlockMS: meter.maxBlock * 1000, wallMS: max(0, wall))
    results.append(result)
    print("  " + name.padding(toLength: 34, withPad: " ", startingAt: 0)
          + String(format: "%9.1f ms max   %9.1f ms until idle", result.maxBlockMS, result.wallMS))
}

// MARK: - Fixtures

enum Bench {
    /// Whatever the store and sync still have queued off the main thread.
    @MainActor static var idleCheck: () -> Bool = { true }
    static func isIdle() -> Bool { MainActor.assumeIsolated { idleCheck() } }
}

func body(_ index: Int) -> String {
    let paragraph = """
    Planning for **week \(index)**: see [the doc](https://example.com/\(index)) and the `config` file, ==highlight== this.

    - Write the release notes for build \(index) #work
    - Review the [[Roadmap]] draft with _the team_
    - [ ] Book the room
    - [x] Send the invite ~~yesterday~~

    > Keep it small. Ship it #later

    | Item | Owner |
    |------|-------|
    | Draft | Ana |
    """
    // Half the notes have no title, so their label comes from the body.
    return (index % 2 == 0 ? "# Heading \(index)\n\n" : "") + Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
}

func title(_ index: Int) -> String { index % 2 == 0 ? "" : "Note \(index)" }

/// Several notes in one go, through the store's public API.
@MainActor func createNotes(_ count: Int, in store: NoteStore) {
    _ = try! store.create((0..<count).map { NoteDraft(title: title($0), body: body($0)) })
}

var temporaryDirectories: [URL] = []

func temporaryDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepnote-bench-\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    temporaryDirectories.append(url)
    return url
}

/// A folder of `count` .hmnote files to import.
func importFolder(count: Int) -> URL {
    let folder = temporaryDirectory("import")
    for index in 0..<count {
        let note = Note(title: title(index), body: body(index), color: NoteColor.allCases[index % NoteColor.allCases.count],
                        sortIndex: index, tags: ["imported"])
        let file = HMNoteFile(note: note)
        try! file.serialized().write(to: folder.appendingPathComponent(file.fileName), atomically: true, encoding: .utf8)
    }
    return folder
}

/// The app's wiring, minus the hotkeys and the status item: the store, sync
/// on a temporary folder, one deck on the main screen fed from the store.
@MainActor
final class Environment {
    let directory = temporaryDirectory("env")
    let syncFolder: URL
    let key: SymmetricKey
    var store: NoteStore!
    var sync: FolderSyncService!
    var deck: EdgePanelController!
    var windows: [NoteWindowController] = []
    private var subscriptions: [Any] = []

    init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.key = key
        syncFolder = directory.appendingPathComponent("Sync", isDirectory: true)
        try! FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
    }

    func launch() {
        store = try! NoteStore(databaseURL: directory.appendingPathComponent("notes.sqlite"), cipher: BodyCipher(key: key))
        sync = FolderSyncService(store: store, folder: syncFolder)
        deck = EdgePanelController(screen: NSScreen.main!)
        // As `AppCoordinator.start` does.
        subscriptions.append(store.$notes.receive(on: RunLoop.main).sink { [weak self] notes in
            self?.deck.update(notes: notes.filter { $0.state == .active })
        })
        subscriptions.append(store.changes.sink { [weak self] _ in
            self?.windows.forEach { $0.refresh() }
        })
        deck.update(notes: store.activeNotes)
        Bench.idleCheck = { [store, sync] in
            store?.waitUntilSaved()
            sync?.waitUntilWritten()
            return true
        }
    }

    func shutDown() {
        windows.forEach { $0.close() }
        windows = []
        deck?.collapse()
        deck?.hidePanel()
        subscriptions = []
        sync = nil
        deck = nil
        store = nil
    }

    /// The deck's tabs, in order.
    func cards() -> [NoteCardView] {
        func collect(_ view: NSView) -> [NoteCardView] {
            (view as? NoteCardView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return NSApp.windows.compactMap(\.contentView).flatMap(collect)
    }
}

/// The cursor moving over the middle of the part of `card` that shows, where
/// the deck is putting it (its spring may still be on the way).
@MainActor func moveEvent(over card: NoteCardView) -> NSEvent {
    let stack = card.window?.contentView as? EdgeStackView
    let index = stack.flatMap { stack in (card.superview?.subviews.compactMap { $0 as? NoteCardView }.firstIndex(of: card)) }
    var point = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.maxY - card.visibleSlice / 2), to: nil)
    if let stack, let index, stack.geometry.frames.indices.contains(index) {
        let frame = stack.geometry.frames[index]
        point = card.superview!.convert(NSPoint(x: frame.maxX - 20, y: frame.maxY - stack.geometry.slices[index] / 2), to: nil)
    }
    return NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: card.window?.windowNumber ?? 0, context: nil,
                              eventNumber: 0, clickCount: 0, pressure: 0)!
}

// MARK: - Stages

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let counts = CommandLine.arguments.dropFirst().compactMap { Int($0) }
    let sizes = counts.isEmpty ? [50, 200] : counts
    let jsonPath = ProcessInfo.processInfo.environment["KEEPNOTE_BENCH_JSON"]

    for count in sizes {
        print("== \(count) notes")

        // Creating notes into an empty store, sync on.
        let created = Environment()
        created.launch()
        settle()
        stage("criar \(count) notas", notes: count) {
            createNotes(count, in: created.store)
        }
        created.shutDown()
        settle(minimum: 0.3)

        // Importing them instead, then using the deck over them.
        let env = Environment()
        env.launch()
        settle()
        let source = importFolder(count: count)
        stage("importar \(count) notas", notes: count) {
            _ = try! NoteImporter.importContents(of: source, into: env.store)
        }

        stage("relançar (store + sync)", notes: count) {
            env.shutDown()
            env.launch()
        }

        stage("abrir o deck", notes: count) {
            env.deck.cursorDidEnter()
        }

        let cards = env.cards()
        precondition(cards.count == count, "deck shows \(cards.count) of \(count) tabs")
        // Every tab in turn, each one its own event, as a sweep down the deck.
        meter.reset()
        var peekMax = 0.0
        var opened = 0
        // Only tabs with something showing in the column can be pointed at.
        let resting = (cards.first?.window?.contentView as? EdgeStackView)?.geometry
        let reachable = resting.map { geometry in
            geometry.frames.indices.filter { index in
                let middle = geometry.frames[index].maxY - geometry.slices[index] / 2
                return middle > 0 && middle < geometry.columnHeight
            }.count
        } ?? 0
        let peekStart = CFAbsoluteTimeGetCurrent()
        for card in cards {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The deck this tab is in: earlier stages left closed decks behind.
                    (card.window?.contentView as? EdgeStackView)?.mouseMoved(with: moveEvent(over: card))
                    // Draws the tabs and the peek as the window server would ask.
                    NSApp.windows.forEach { $0.displayIfNeeded() }
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            peekMax = max(peekMax, meter.maxBlock)
            if (card.window?.contentView as? EdgeStackView)?.hoveredNoteID == card.noteID { opened += 1 }
        }
        if opened != reachable {
            FileHandle.standardError.write("the sweep opened \(opened) of the \(reachable) tabs in view\n".data(using: .utf8)!)
            exit(1)
        }
        settle(minimum: 0.3)
        peekMax = max(peekMax, meter.maxBlock)
        results.append(Result(stage: "peek em todas as abas", notes: count, maxBlockMS: peekMax * 1000,
                              wallMS: (CFAbsoluteTimeGetCurrent() - peekStart) * 1000))
        print("  " + "peek em todas as abas".padding(toLength: 34, withPad: " ", startingAt: 0)
              + String(format: "%9.1f ms max   (%d abas visíveis abertas)", peekMax * 1000, opened))

        let target = env.store.activeNotes[count / 2]
        stage("abrir uma nota", notes: count) {
            let controller = NoteWindowController(note: target, store: env.store, originFrame: nil, cascadeIndex: 0)
            env.windows.append(controller)
            controller.show()
            controller.window.displayIfNeeded()
        }

        stage("salvar uma edição (autosave)", notes: count) {
            try! env.store.update(id: target.id) { $0.body += "\nmore text" }
        }

        env.shutDown()
        settle(minimum: 0.3)
    }

    temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)

    printTable(results, title: "Maior bloqueio da thread principal (ms)")
    if let beforePath = ProcessInfo.processInfo.environment["KEEPNOTE_BENCH_BEFORE"],
       let data = try? Data(contentsOf: URL(fileURLWithPath: beforePath)),
       let before = try? JSONDecoder().decode([Result].self, from: data) {
        printComparison(before: before, after: results)
    }

    if let jsonPath {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try! encoder.encode(results).write(to: URL(fileURLWithPath: jsonPath))
        print("wrote \(jsonPath)")
    }
}


// MARK: - Report

func stageKey(_ result: Result) -> String {
    result.stage.replacingOccurrences(of: "\(result.notes) ", with: "N ")
}

func printTable(_ results: [Result], title: String) {
    let counts = Array(Set(results.map(\.notes))).sorted()
    var order: [String] = []
    for result in results where !order.contains(stageKey(result)) { order.append(stageKey(result)) }
    print("\n\(title)\n")
    print("| etapa | " + counts.map { "\($0) notas" }.joined(separator: " | ") + " |")
    print("|---|" + counts.map { _ in "---:|" }.joined())
    for key in order {
        let cells = counts.map { count -> String in
            results.first { stageKey($0) == key && $0.notes == count }.map { String(format: "%.1f", $0.maxBlockMS) } ?? "–"
        }
        print("| \(key) | " + cells.joined(separator: " | ") + " |")
    }
}

func printComparison(before: [Result], after: [Result]) {
    let counts = Array(Set(after.map(\.notes))).sorted()
    var order: [String] = []
    for result in after where !order.contains(stageKey(result)) { order.append(stageKey(result)) }
    print("\nAntes x depois — maior bloqueio da thread principal (ms)\n")
    print("| etapa | " + counts.map { "\($0): antes | \($0): depois" }.joined(separator: " | ") + " |")
    print("|---|" + counts.map { _ in "---:|---:|" }.joined())
    for key in order {
        let cells = counts.flatMap { count -> [String] in
            let old = before.first { stageKey($0) == key && $0.notes == count }
            let new = after.first { stageKey($0) == key && $0.notes == count }
            return [old.map { String(format: "%.1f", $0.maxBlockMS) } ?? "–",
                    new.map { String(format: "%.1f", $0.maxBlockMS) + ($0.maxBlockMS > 50 ? " ⚠️" : "") } ?? "–"]
        }
        print("| \(key) | " + cells.joined(separator: " | ") + " |")
    }
}
