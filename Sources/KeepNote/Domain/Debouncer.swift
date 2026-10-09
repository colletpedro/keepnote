import Foundation

/// Collapses a burst of calls into one, `delay` after the burst stops.
///
/// Used for autosave (250 ms after the last keystroke) and for the panel
/// rebuild that follows a screen change. A cancellable `Task` is enough here —
/// no Combine subscription to keep alive, and `flush()` can run the pending
/// work early, which is what closing a note does.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    private var pendingAction: (() -> Void)?

    let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    deinit {
        task?.cancel()
    }

    var hasPendingWork: Bool { pendingAction != nil }

    func schedule(_ action: @escaping () -> Void) {
        pendingAction = action
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.fire()
        }
    }

    /// Runs the pending action right now. Called when a note closes, when the
    /// app resigns active, and before the app terminates, so nothing typed is
    /// ever waiting on a timer that will not fire.
    func flush() {
        task?.cancel()
        task = nil
        fire()
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingAction = nil
    }

    private func fire() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
    }
}
