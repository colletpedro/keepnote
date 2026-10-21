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

    /// The choice in effect for this run, as it was when the app started.
    static let launchChoice: AppLanguage = UserDefaults.standard.string(forKey: preferenceKey)
        .flatMap(AppLanguage.init(rawValue:)) ?? .system

    /// What a choice means: `system` resolved to the Mac's language.
    static func resolved(_ choice: AppLanguage) -> String {
        choice == .system ? systemLanguage() : choice.rawValue
    }

    /// The language of this run: "en" or "pt-BR".
    static let language: String = resolveLanguage()

    /// Dates, weekdays and numbers are written in the interface's language,
    /// with the Mac's region (so English in Brazil still writes day/month).
    static let locale: Locale = makeLocale(for: language)

    fileprivate static let table: [String: String] = loadTable(for: language)

    fileprivate static func string(_ key: String, in language: String) -> String {
        language == self.language ? (table[key] ?? shown(key)) : (loadTable(for: language)[key] ?? shown(key))
    }

    /// A key without its leading `[context] `, if any.
    static func shown(_ key: String) -> String {
        guard key.hasPrefix("["), let end = key.firstIndex(of: "]") else { return key }
        return String(key[key.index(after: end)...].drop { $0 == " " })
    }

    static func normalized(_ identifier: String) -> String {
        identifier.lowercased().hasPrefix("pt") ? AppLanguage.portuguese.rawValue : AppLanguage.english.rawValue
    }

    /// `system` resolved: the first of the Mac's preferred languages KeepNote has.
    static func systemLanguage() -> String {
        // The Mac's own list, not this app's: once a language has been picked
        // here, `Locale.preferredLanguages` reports that pick instead.
        let global = CFPreferencesCopyValue(
            "AppleLanguages" as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        for preferred in global ?? Locale.preferredLanguages {
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
        return resolved(launchChoice)
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
///
/// English sometimes uses one word for two things Portuguese tells apart —
/// "Archive" the place and "Archive" the command. The second gets a context
/// in brackets, `L("[noun] Archive")`, which is never shown: without a
/// table entry the key is shown without it.
func L(_ key: String) -> String {
    Localization.table[key] ?? Localization.shown(key)
}

/// `key` in a language other than the running one — for the one prompt that
/// speaks the language just chosen in Settings.
func L(_ key: String, in language: String) -> String {
    Localization.string(key, in: language)
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

/// A file size in the interface's language: "9.7 MB", "9,7 MB" — not in the
/// Mac's, which `ByteCountFormatter` uses whatever the app is set to.
func Lbytes(_ count: Int) -> String {
    Int64(count).formatted(.byteCount(style: .file).locale(Localization.locale))
}
