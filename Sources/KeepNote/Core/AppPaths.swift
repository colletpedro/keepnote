import Foundation

/// Everything the app writes without being handed a folder lives in the
/// sandbox container. `NSHomeDirectory()` already points inside it when the
/// app is sandboxed, so no extra path juggling is needed.
enum AppPaths {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.keepnote.KeepNote"

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("KeepNote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var databaseURL: URL {
        applicationSupport.appendingPathComponent("notes.sqlite")
    }

    /// Extension of one exported/synced note.
    static let noteFileExtension = "hmnote"
    /// Extension of the daily template in the sync folder.
    static let templateFileExtension = "hmtemplate"
    /// Extension of the full archive package (all notes plus metadata).
    static let archiveFileExtension = "hmnotearchive"
}
