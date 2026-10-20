import Foundation

/// Settings > Daily > "Unfinished tasks from your last daily": what a new
/// daily does with the checklist items left unticked on the last day before.
enum CarryOverMode: String, CaseIterable, Sendable {
    case never
    case ask
    case automatic

    static let `default` = CarryOverMode.ask

    var title: String {
        switch self {
        case .never: return L("Don\u{2019}t bring")
        case .ask: return L("Ask each time")
        case .automatic: return L("Bring automatically")
        }
    }
}
