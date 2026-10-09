import Foundation

func runListToggleTests() {
    let bullets = { (e: TextEdit) in Formatting.toggleList(e, .bullet) as TextEdit? }
    let numbers = { (e: TextEdit) in Formatting.toggleList(e, .numbered) as TextEdit? }
    let checks = { (e: TextEdit) in Formatting.toggleList(e, .checklist) as TextEdit? }

    // plain text -> list
    check("bullet on one line", "hello|", "- hello|", bullets)
    check("bullet with the caret in the middle", "he|llo", "- he|llo", bullets)
    check("bullet with the caret at the start", "|hello", "- |hello", bullets)
    check("numbered on one line", "hello|", "1. hello|", numbers)
    check("checklist on one line", "hello|", "- [ ] hello|", checks)
    check("bullet on an empty line", "|", "- |", bullets)
    check("bullet keeps indentation of plain text", "  hello|", "  - hello|", bullets)
    check("bullet on several lines", "‹a\nb\nc›", "- ‹a\n- b\n- c›", bullets)
    check("numbered on several lines counts up", "‹a\nb\nc›", "1. ‹a\n2. b\n3. c›", numbers)
    check("checklist on several lines", "‹a\nb›", "- [ ] ‹a\n- [ ] b›", checks)
    check("blank lines in a selection are skipped", "‹a\n\nb›", "- ‹a\n\n- b›", bullets)
    check("a selection ending at a line start leaves that line alone", "‹a\n›b", "- ‹a\n›b", bullets)
    check("lines outside the selection are untouched", "x\n‹a›\ny", "x\n- ‹a›\ny", bullets)
    check("fenced lines are skipped", "```\n‹a›\n```", "```\n‹a›\n```", bullets)
    check("fenced lines are skipped within a selection", "‹a\n```\nb\n```\nc›", "- ‹a\n```\nb\n```\n- c›", bullets)

    // toggling off
    check("bullet toggles off", "- hello|", "hello|", bullets)
    check("numbered toggles off", "1. hello|", "hello|", numbers)
    check("checklist toggles off", "- [ ] hello|", "hello|", checks)
    check("a ticked checklist toggles off", "- [x] hello|", "hello|", checks)
    check("toggling off drops the indentation", "    - hello|", "hello|", bullets)
    check("bullets toggle off on several lines", "‹- a\n- b›", "‹a\nb›", bullets)
    check("an empty item toggles off", "- |", "|", bullets)
    check("on and off returns to the start", "x‹a›y".replacingOccurrences(of: "x", with: "").replacingOccurrences(of: "y", with: ""),
          "‹a›") { Formatting.toggleList(Formatting.toggleList($0, .bullet), .bullet) }

    // switching kinds
    check("bullet to numbered", "- hello|", "1. hello|", numbers)
    check("numbered to bullet", "3. hello|", "- hello|", bullets)
    check("bullet to checklist", "- hello|", "- [ ] hello|", checks)
    check("checklist to bullet", "- [x] hello|", "- hello|", bullets)
    check("numbered to checklist", "2. hello|", "- [ ] hello|", checks)
    check("checklist to numbered", "- [ ] hello|", "1. hello|", numbers)
    check("switching keeps indentation", "    - hello|", "    1. hello|", numbers)
    check("star bullets count as bullets", "* hello|", "hello|", bullets)
    check("mixed selection converts everything", "‹- a\nb\n1. c›", "‹- a\n- b\n- c›", bullets)
    check("mixed selection with a line already in kind joins the rest",
          "‹- a\nb›", "‹- a\n- b›", bullets)
    check("a ticked box that is already a checklist item stays ticked in a mixed selection",
          "‹- [x] a\nb›", "‹- [x] a\n- [ ] b›", checks)

    // numbering
    check("numbered joins a list above", "1. a\n2. b\nc|", "1. a\n2. b\n3. c|", numbers)
    check("numbered continues from the first number of the list it joins", "5. a\nb|", "5. a\n6. b|", numbers)
    check("numbered after a bullet list starts at 1", "- a\nb|", "- a\n1. b|", numbers)
    check("numbered renumbers the items below", "a|\n2. b\n3. c", "1. a|\n2. b\n3. c", numbers)
    check("removing numbers from the end leaves the rest", "1. a\n2. b|", "1. a\nb|", numbers)
    check("two separate selections' lists stay separate", "‹a›\n\n7. x", "1. ‹a›\n\n7. x", numbers)
}
