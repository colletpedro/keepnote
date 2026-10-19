import Foundation

/// The interface languages. `system` follows the Mac's own list of preferred
/// languages, falling back to English for any language KeepNote is not in.
enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case portuguese = "pt-BR"

    /// Each language's name in itself, the way the system's own pickers list them.
    var nativeName: String {
        switch self {
        case .system: return L("System")
        case .english: return "English"
        case .portuguese: return "Português"
        }
    }
}

/// Every string the app shows goes through `L`, keyed by its English text.
///
/// The tables are plain-text `Localizable.strings` in `Resources/<language>.lproj`,
/// which `Scripts/build.sh` copies into the bundle as they are — no Xcode
/// step. The language is settled once, at launch: switching it in Settings
/// takes effect when the app is reopened, which is also when AppKit's own
/// strings (the open panel, Services, Emoji & Symbols) switch.
enum Localization {
    /// The choice made in Settings > General: an `AppLanguage` raw value.
    static let preferenceKey = "appLanguage"

    /// The language of this run: "en" or "pt-BR".
    static let language: String = resolveLanguage()

    /// Dates, weekdays and numbers are written in the interface's language,
    /// with the Mac's region (so English in Brazil still writes day/month).
    static let locale: Locale = makeLocale(for: language)

    fileprivate static let table: [String: String] = loadTable(for: language)

    /// The translation of `key` in a language other than the running one —
    /// for the one prompt that speaks the language just chosen.
    static func string(_ key: String, in language: String) -> String {
        language == self.language ? L(key) : (loadTable(for: language)[key] ?? key)
    }

    static func normalized(_ identifier: String) -> String {
        identifier.lowercased().hasPrefix("pt") ? AppLanguage.portuguese.rawValue : AppLanguage.english.rawValue
    }

    /// `system` resolved: the first of the Mac's preferred languages KeepNote has.
    static func systemLanguage() -> String {
        for preferred in Locale.preferredLanguages {
            let code = preferred.lowercased()
            if code.hasPrefix("pt") { return AppLanguage.portuguese.rawValue }
            if code.hasPrefix("en") { return AppLanguage.english.rawValue }
        }
        return AppLanguage.english.rawValue
    }

    static func makeLocale(for language: String, region: String? = Locale.current.region?.identifier) -> Locale {
        guard let region, !region.isEmpty else {
            return Locale(identifier: language == AppLanguage.portuguese.rawValue ? "pt_BR" : "en_US")
        }
        let code = language == AppLanguage.portuguese.rawValue ? "pt" : "en"
        return Locale(identifier: "\(code)_\(region)")
    }

    private static func resolveLanguage() -> String {
        // The render harness and the tests pick a language without settings.
        if let forced = ProcessInfo.processInfo.environment["KEEPNOTE_LANGUAGE"], !forced.isEmpty {
            return normalized(forced)
        }
        let stored = UserDefaults.standard.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        return stored == .system ? systemLanguage() : stored.rawValue
    }

    private static func loadTable(for language: String) -> [String: String] {
        let path: String?
        if let root = ProcessInfo.processInfo.environment["KEEPNOTE_LPROJ_ROOT"], !root.isEmpty {
            path = (root as NSString).appendingPathComponent("\(language).lproj/Localizable.strings")
        } else {
            path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language)
        }
        guard let path, let table = NSDictionary(contentsOfFile: path) as? [String: String] else { return [:] }
        return table
    }
}

/// The interface text for `key`, its English original.
func L(_ key: String) -> String {
    Localization.table[key] ?? key
}

/// The same, with `String(format:)` arguments: `%@` for text, `%d` for a count.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Localization.locale, arguments: arguments)
}

/// A count in a sentence: `one` when it is 1, `other` (with its `%d`) otherwise.
/// Both are passed through `L` by the caller, so both are in the tables.
func Lplural(_ count: Int, _ one: String, _ other: String) -> String {
    String(format: count == 1 ? one : other, locale: Localization.locale, count)
}
