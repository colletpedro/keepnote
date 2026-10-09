import Foundation

func runBlockTests() {
    let bold = { (e: TextEdit) in Formatting.toggle(e, .highlight) as TextEdit? }
    let code = { (e: TextEdit) in Formatting.toggle(e, .code) as TextEdit? }

    // highlight and inline code reuse the wrapping logic
    check("highlight wraps", "a ‹word› b", "a ==‹word›== b", bold)
    check("highlight unwraps", "==‹word›==", "‹word›", bold)
    check("highlight with no selection", "a|", "a==|==", bold)
    check("highlight inside an empty pair removes it", "==|==", "|", bold)
    check("inline code wraps", "a ‹word› b", "a `‹word›` b", code)
    check("inline code unwraps", "`‹word›`", "‹word›", code)
    check("inline code with no selection", "a|", "a`|`", code)
    check("inline code inside an empty pair removes it", "`|`", "|", code)
    check("inline code unwraps when included", "‹`x`›", "‹x›", code)
    check("bold is not confused with highlight", "‹==a==›", "**‹==a==›**") { Formatting.toggle($0, .bold) }

    // headings
    let h1 = { (e: TextEdit) in BlockEditing.heading(e, level: 1) as TextEdit? }
    let h2 = { (e: TextEdit) in BlockEditing.heading(e, level: 2) as TextEdit? }
    let h3 = { (e: TextEdit) in BlockEditing.heading(e, level: 3) as TextEdit? }
    check("h1 on a plain line", "title|", "# title|", h1)
    check("h2 on a plain line", "ti|tle", "## ti|tle", h2)
    check("h3 on a plain line", "title|", "### title|", h3)
    check("h1 again removes it", "# title|", "title|", h1)
    check("h2 over h1 changes the level", "# title|", "## title|", h2)
    check("h1 over h3 changes the level", "### title|", "# title|", h1)
    check("heading on an empty line", "|", "# |", h1)
    check("heading on several lines", "‹a\nb›", "# ‹a\n# b›", h1)
    check("heading on mixed levels sets them all", "‹# a\n## b›", "‹# a\n# b›", h1)
    check("heading on all-equal lines removes them", "‹## a\n## b›", "‹a\nb›", h2)
    check("heading leaves list items alone", "- a|", "- a|", h1)
    check("heading skips blank lines of a selection", "‹a\n\nb›", "# ‹a\n\n# b›", h1)
    check("heading skips fenced lines", "```\n‹a›\n```", "```\n‹a›\n```", h1)
    check("heading keeps the rest of the line", "# a **b**|", "## a **b**|", h2)

    // quote
    let quote = { (e: TextEdit) in BlockEditing.quote(e) as TextEdit? }
    check("quote on a line", "a|", "> a|", quote)
    check("quote again removes it", "> a|", "a|", quote)
    check("quote removes one level of two", ">> a|", "> a|", quote)
    check("quote on several lines", "‹a\nb›", "> ‹a\n> b›", quote)
    check("quote on mixed lines quotes the rest", "‹> a\nb›", "‹> a\n> b›", quote)
    check("quote on all-quoted lines removes them", "‹> a\n> b›", "‹a\nb›", quote)
    check("quote on an empty line", "|", "> |", quote)
    check("quote skips blank lines in a selection", "‹a\n\nb›", "> ‹a\n\n> b›", quote)
    check("quote skips fences", "```\n‹a›\n```", "```\n‹a›\n```", quote)
    check("quote on a list item", "- a|", "> - a|", quote)

    // code block
    let block = { (e: TextEdit) in BlockEditing.codeBlock(e) as TextEdit? }
    check("code block around a line", "a|", "```\na|\n```", block)
    check("code block around a selected line", "‹a›", "```\n‹a›\n```", block)
    check("code block around several lines", "‹a\nb›", "```\n‹a\nb›\n```", block)
    check("code block wraps whole lines for a partial selection", "x ‹y› z", "```\nx ‹y› z\n```", block)
    check("code block on a blank line opens an empty one", "|", "```\n|\n```", block)
    check("code block keeps text around it", "x\na|\ny", "x\n```\na|\n```\ny", block)
    check("code block inside a block removes the fences", "```\na|\n```", "a|", block)
    check("code block removes fences with a language tag", "```swift\na|\nb\n```\nafter", "a|\nb\nafter", block)
    check("code block removes an unclosed fence", "```\na|", "a|", block)
    check("code block leaves other blocks alone", "```\na\n```\nb|\n```\nc\n```", "```\na\n```\n```\nb|\n```\n```\nc\n```", block)
    check("code block across two blocks does nothing", "‹```\na\n```\nb\n```\nc›\n```", "‹```\na\n```\nb\n```\nc›\n```", block)

    // table
    let table = { (e: TextEdit) in BlockEditing.insertTable(e) as TextEdit? }
    let tableText = "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |"
    check("table in an empty note", "|", "| ‹Column 1› | Column 2 |\n| --- | --- |\n|  |  |\n", table)
    check("table after a paragraph gets a blank line first", "text|", "text\n\n| ‹Column 1› | Column 2 |\n| --- | --- |\n|  |  |\n", table)
    check("table on a blank line after text", "text\n|", "text\n\n| ‹Column 1› | Column 2 |\n| --- | --- |\n|  |  |\n", table)
    check("table between lines gets blank lines", "a\n|\nb", "a\n\n| ‹Column 1› | Column 2 |\n| --- | --- |\n|  |  |\n\nb", table)
    check("table in the middle of a line splits it", "ab|cd", "ab\n\n| ‹Column 1› | Column 2 |\n| --- | --- |\n|  |  |\n\ncd", table)
    check("table goes after a selection", "‹ab›", "ab\n\n| ‹Column 1› | Column 2 |\n| --- | --- |\n|  |  |\n", table)
    expect("table template is two columns by two rows", tableText.split(separator: "\n").map { String($0) }.joined(separator: "/"),
           BlockEditing.tableTemplate.joined(separator: "/"))

    // divider
    let rule = { (e: TextEdit) in BlockEditing.insertDivider(e) as TextEdit? }
    check("divider in an empty note", "|", "---\n|", rule)
    check("divider after a paragraph keeps it from being a heading", "text|", "text\n\n---\n|", rule)
    check("divider on a blank line below text", "text\n|", "text\n\n---\n|", rule)
    check("divider before more text", "a\n|\nb", "a\n\n---\n|\nb", rule)
    check("divider in the middle of a line", "ab|cd", "ab\n\n---\n\n|cd", rule)

    // date: the system's short format for the locale
    let day = Date(timeIntervalSince1970: 1_791_244_800) // 2026-10-06 00:00 UTC
    let utc = TimeZone(identifier: "UTC")!
    let br = Locale(identifier: "pt_BR")
    let us = Locale(identifier: "en_US")
    check("date at the caret (pt_BR)", "on |", "on 06/10/2026|") { BlockEditing.insertDate($0, date: day, timeZone: utc, locale: br) }
    check("date at the caret (en_US)", "on |", "on 10/6/26|") { BlockEditing.insertDate($0, date: day, timeZone: utc, locale: us) }
    check("date replaces the selection", "on ‹x›", "on 06/10/2026|") { BlockEditing.insertDate($0, date: day, timeZone: utc, locale: br) }
    check("date follows the time zone", "|", "05/10/2026|") {
        BlockEditing.insertDate($0, date: day, timeZone: TimeZone(identifier: "America/Sao_Paulo")!, locale: br)
    }
    check("date keeps text after the caret", "a |b", "a 06/10/2026|b") { BlockEditing.insertDate($0, date: day, timeZone: utc, locale: br) }
    let system = DateFormatter()
    system.dateStyle = .short
    system.timeStyle = .none
    expect("the default locale is the system's", BlockEditing.insertDate(state("|"), date: day).text, system.string(from: day))
}
