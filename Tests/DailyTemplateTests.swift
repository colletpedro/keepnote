import Foundation

func runDailyTemplateTests() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    // Friday, 9 October 2026.
    let friday = utc.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
    let monday = utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
    let english = Locale(identifier: "en_US")
    let portuguese = Locale(identifier: "pt_BR")

    func apply(_ template: String, _ date: Date = friday, _ locale: Locale = english) -> DailyTemplateApply.Applied {
        DailyTemplateApply.apply(template, on: date, locale: locale, calendar: utc)
    }
    /// The text with `|` where the caret is.
    func marked(_ applied: DailyTemplateApply.Applied) -> String {
        let ns = applied.text as NSString
        return ns.substring(to: applied.caret) + "|" + ns.substring(from: applied.caret)
    }

    // MARK: An empty template

    expect("template: empty gives an empty body", apply("").text, "")
    expect("template: and the caret at its start", String(apply("").caret), "0")
    expect("template: only spaces stays as typed", marked(apply("  \n ")), "  \n |")

    // MARK: The variables

    expect("template: {date} in en-US", apply("{date}").text, "10/9/26")
    expect("template: {date} in pt-BR", apply("{date}", friday, portuguese).text, "09/10/2026")
    expect("template: {weekday} in en-US", apply("{weekday}").text, "Friday")
    expect("template: {weekday} in pt-BR", apply("{weekday}", friday, portuguese).text, "sexta-feira")
    expect("template: another day, another weekday", apply("{weekday}", monday, portuguese).text, "segunda-feira")
    expect("template: both in a sentence", apply("# {weekday}, {date}\n").text, "# Friday, 10/9/26\n")
    expect("template: repeated variables are all replaced",
           apply("{date} {date}\n{weekday}/{weekday} {date}").text, "10/9/26 10/9/26\nFriday/Friday 10/9/26")
    expect("template: other braces are left alone",
           apply("{name} {Date} {date {weekday}").text, "{name} {Date} {date Friday")
    expect("template: a lone brace is left alone", apply("a { b } c {").text, "a { b } c {")
    expect("template: no variable, no change", apply("- [ ] one\n- [ ] two").text, "- [ ] one\n- [ ] two")
    expect("template: accents and emoji survive", apply("Olá 🌞 {weekday}", friday, portuguese).text, "Olá 🌞 sexta-feira")
    expect("template: the day is the one given, not today's", apply("{date}", utc.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 12))!).text, "1/2/30")

    // MARK: The caret

    expect("caret: the first empty checklist item", marked(apply("# Plan\n- [ ] \n- [ ] later")), "# Plan\n- [ ] |\n- [ ] later")
    expect("caret: the first empty bullet", marked(apply("Notes\n- \n")), "Notes\n- |\n")
    expect("caret: a numbered item", marked(apply("1. one\n2. \n")), "1. one\n2. |\n")
    expect("caret: the first of several empty items", marked(apply("- [ ] \n- [ ] \n- [ ] ")), "- [ ] |\n- [ ] \n- [ ] ")
    expect("caret: a filled item is skipped for a later empty one", marked(apply("- a\n- b\n- [ ] ")), "- a\n- b\n- [ ] |")
    expect("caret: a nested empty item", marked(apply("- a\n    - \n")), "- a\n    - |\n")
    expect("caret: no empty item, the end of the text", marked(apply("# Day\n- one\n- two")), "# Day\n- one\n- two|")
    expect("caret: the end, after a final newline", marked(apply("Hello\n")), "Hello\n|")
    expect("caret: a marker with no space is no item", marked(apply("-\n- [ ]")), "-\n- [ ]|")
    expect("caret: an empty item in a code block is not one", marked(apply("```\n- \n```\nend")), "```\n- \n```\nend|")
    expect("caret: after the block, a real one", marked(apply("```\n- \n```\n- [ ] ")), "```\n- \n```\n- [ ] |")
    expect("caret: counts UTF-16, so emoji before it are two",
           String(apply("🌞\n- [ ] ").caret), "9")
    expect("caret: with the variables replaced first",
           marked(apply("## {weekday} {date}\n- [ ] ", friday, portuguese)), "## sexta-feira 09/10/2026\n- [ ] |")
    expect("caret: a checked empty item counts too", marked(apply("- [x] ")), "- [x] |")
    expect("caret: the text alone", String(DailyTemplateApply.caret(in: "- [ ] ")), "6")
    expect("caret: of nothing", String(DailyTemplateApply.caret(in: "")), "0")
}
