import CoreServices
import Foundation

/// Watches an ordinary folder for changes.
///
/// `NSFilePresenter` only hears about writes that went through
/// `NSFileCoordinator`. iCloud's daemon does coordinate; Dropbox, Syncthing and
/// a plain shared folder generally do not, so their writes would land silently.
/// FSEvents sees them regardless of who wrote the file.
///
/// Sandbox note: this works because the folder came from `NSOpenPanel` and its
/// security scope is open — FSEvents needs no extra entitlement.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.keepnote.sync.fsevents", qos: .utility)
    private let onChange: ([URL]) -> Void

    init?(folder: URL, onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // `kFSEventStreamCreateFlagUseCFTypes` makes this a CFArray of
            // strings rather than a raw C array.
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            watcher.onChange(paths.map { URL(fileURLWithPath: $0) })
        }

        // `IgnoreSelf`: our own writes to the folder are not news to us, and
        // reading each one back was a full coordinated read per file.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // coalesce a burst of writes into one callback
            flags
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
