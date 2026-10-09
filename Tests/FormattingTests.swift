import Foundation

func runToggleTests() {
    let bold = { (e: TextEdit) in Formatting.toggle(e, .bold) as TextEdit? }
    let italic = { (e: TextEdit) in Formatting.toggle(e, .italic) as TextEdit? }
    let strike = { (e: TextEdit) in Formatting.toggle(e, .strike) as TextEdit? }

    // wrapping
    check("bold wraps a selection", "a ‹word› b", "a **‹word›** b", bold)
    check("italic wraps a selection", "a ‹word› b", "a *‹word›* b", italic)
    check("strike wraps a selection", "a ‹word› b", "a ~~‹word›~~ b", strike)
    check("wrapping keeps the selection on the inner text so it toggles back",
          "‹a›", "**‹a›**", bold)
    check("whitespace around the selection stays outside the marks", "x‹ word ›y", "x **‹word›** y", bold)
    check("selection of only spaces does nothing", "a‹  ›b", "a‹  ›b", bold)
    check("works with accents and emoji", "‹ação 😀›", "**‹ação 😀›**", bold)

    // unwrapping
    check("bold unwraps when the selection includes the marks", "‹**word**›", "‹word›", bold)
    check("bold unwraps when the marks sit just outside", "**‹word›**", "‹word›", bold)
    check("italic unwraps outside marks", "*‹word›*", "‹word›", italic)
    check("italic unwraps inside marks", "‹*word*›", "‹word›", italic)
    check("italic recognises underscores", "_‹word›_", "‹word›", italic)
    check("bold recognises double underscores", "__‹word›__", "‹word›", bold)
    check("strike unwraps", "~~‹word›~~", "‹word›", strike)
    check("unwrapping in the middle of a line", "a **‹b›** c", "a ‹b› c", bold)

    // bold and italic do not confuse each other
    check("italic on bold text adds a star pair", "**‹word›**", "***‹word›***", italic)
    check("bold on italic text adds a star pair", "*‹word›*", "***‹word›***", bold)
    check("italic unwraps from bold-italic", "***‹word›***", "**‹word›**", italic)
    check("bold unwraps from bold-italic", "***‹word›***", "*‹word›*", bold)
    check("italic on included bold-italic", "‹***word***›", "‹**word**›", italic)

    // no selection
    check("bold with no selection inserts a pair", "a |b", "a **|**b", bold)
    check("italic with no selection inserts a pair", "|", "*|*", italic)
    check("strike with no selection inserts a pair", "a|", "a~~|~~", strike)
    check("bold with the caret inside an empty pair removes it", "a **|** b", "a | b", bold)
    check("italic with the caret inside an empty pair removes it", "*|*", "|", italic)
    check("italic inside an empty bold pair adds to it", "**|**", "***|***", italic)

    // several lines
    check("a multi-line selection is wrapped line by line",
          "‹one\ntwo›", "**‹one**\n**two›**", bold)
    check("blank lines are skipped",
          "‹one\n\ntwo›", "**‹one**\n\n**two›**", bold)
    check("list markers stay outside the marks",
          "‹- one\n- two›", "- **‹one**\n- **two›**", bold)
    check("numbered markers and checkboxes stay outside",
          "‹1. one\n- [ ] two›", "1. **‹one**\n- [ ] **two›**", bold)
    check("headings and quotes stay outside", "‹# t\n> q›", "# **‹t**\n> **q›**", bold)
    check("a multi-line selection of wrapped lines unwraps all",
          "‹**one**\n**two**›", "‹one\ntwo›", bold)
    check("mixed lines wrap the unwrapped ones only",
          "‹**one**\ntwo›", "‹**one**\n**two›**", bold)
    check("a selection ending at a line start ignores that line",
          "‹one\n›two", "**‹one›**\ntwo", bold)
    check("code fences are not marked", "```\n‹a›\n```", "```\n‹a›\n```", bold)
    check("fenced lines are skipped in a multi-line selection",
          "‹a\n```\nb\n```\nc›", "**‹a**\n```\nb\n```\n**c›**", bold)
    check("caret in a fence does nothing", "```\n|\n```", "```\n|\n```", bold)

    // wrapping twice returns to the start
    let once = Formatting.toggle(state("a ‹word› b"), .bold)
    expect("toggling twice is the identity", marked(Formatting.toggle(once, .bold)), "a ‹word› b")
}
