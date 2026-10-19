import Foundation

/// Settings > General > Language: the language a choice resolves to, and the
/// locale dates, weekdays and the template's {date} and {weekday} are written in.
func runLanguageTests() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    // Monday, 12 October 2026.
    let monday = utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!

    expect("language: the choices", AppLanguage.allCases.map(\.rawValue).joined(separator: ","), "system,en,pt-BR")
    expect("language: English is named in English", AppLanguage.english.nativeName, "English")
    expect("language: Portuguese in Portuguese", AppLanguage.portuguese.nativeName, "Português")
    expect("language: an explicit choice is itself", Localization.resolved(.portuguese), "pt-BR")
    expect("language: pt-PT is read as Portuguese", Localization.normalized("pt-PT"), "pt-BR")
    expect("language: anything else as English", Localization.normalized("fr-FR"), "en")
    expect("language: this runner speaks English", Localization.language, "en")

    let english = Localization.makeLocale(for: "en", region: "US")
    let portuguese = Localization.makeLocale(for: "pt-BR", region: "BR")
    expect("locale: English keeps the Mac's region", Localization.makeLocale(for: "en", region: "BR").identifier, "en_BR")
    expect("locale: Portuguese with the Mac's region", Localization.makeLocale(for: "pt-BR", region: "US").identifier, "pt_US")
    expect("locale: no region falls back by language", Localization.makeLocale(for: "pt-BR", region: nil).identifier, "pt_BR")

    let template = "{weekday}, {date}"
    expect("template: weekday and date in English",
           DailyTemplateApply.apply(template, on: monday, locale: english, calendar: utc).text, "Monday, 10/12/26")
    expect("template: weekday and date in Portuguese",
           DailyTemplateApply.apply(template, on: monday, locale: portuguese, calendar: utc).text, "segunda-feira, 12/10/2026")
    expect("template: by default, in the interface's language",
           DailyTemplateApply.apply("{weekday}", on: monday, calendar: utc).text, "Monday")
    expect("daily title: in Portuguese, day before month",
           DailyNotes.title(for: monday, locale: portuguese, calendar: utc), "Daily 12/10")
    expect("saved: a date in Portuguese",
           SaveStatus.age(of: monday, now: monday.addingTimeInterval(86_400 * 9), calendar: utc, locale: portuguese),
           "12 de out. de 2026")
}
