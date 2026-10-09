import Foundation

func runBaseTests() {
    // TextEdit.applying: selection mapping
    expect("applying: insert before caret moves it",
           marked(state("ab|").applying([Replacement(range: NSRange(location: 0, length: 0), string: "xx")])), "xxab|")
    expect("applying: insert at caret moves it after",
           marked(state("a|b").applying([Replacement(range: NSRange(location: 1, length: 0), string: "X")])), "aX|b")
    expect("applying: caret inside replaced range clamps",
           marked(state("a1|23b").applying([Replacement(range: NSRange(location: 1, length: 3), string: "9")])), "a9|b")
    expect("applying: caret before change stays",
           marked(state("|abc").applying([Replacement(range: NSRange(location: 2, length: 1), string: "XYZ")])), "|abXYZ")
    expect("applying: two changes",
           marked(state("a b c|").applying([
            Replacement(range: NSRange(location: 4, length: 1), string: "CC"),
            Replacement(range: NSRange(location: 0, length: 1), string: "A")])), "A b CC|")

    // minimalChange
    let a = state("hello world|")
    let b = state("hello brave world|")
    let change = a.minimalChange(to: b)
    expect("minimalChange range", NSStringFromRange(change.range), "{6, 0}")
    expect("minimalChange string", change.string, "brave ")
    let same = state("same").minimalChange(to: state("same"))
    expect("minimalChange identical", NSStringFromRange(same.range) + same.string, "{4, 0}")
    let emoji = state("a😀b").minimalChange(to: state("a😁b"))
    expect("minimalChange keeps surrogate pairs whole", NSStringFromRange(emoji.range) + emoji.string, "{1, 2}😁")

    // TextLines
    let text = "a\n\nbc\n" as NSString
    expect("ranges", TextLines.ranges(in: text).map { NSStringFromRange($0) }.joined(separator: " "),
           "{0, 1} {2, 0} {3, 2} {6, 0}")
    expect("ranges of empty text", TextLines.ranges(in: "" as NSString).map { NSStringFromRange($0) }.joined(), "{0, 0}")
    let r = TextLines.ranges(in: text)
    expect("index: caret at line end", String(TextLines.index(of: 1, in: r)), "0")
    expect("index: caret after newline", String(TextLines.index(of: 2, in: r)), "1")
    expect("index: end of text", String(TextLines.index(of: 6, in: r)), "3")
    expect("indexes: selection stopping after a newline excludes next line",
           String(describing: TextLines.indexes(of: NSRange(location: 0, length: 2), in: r)), "0...0")
    expect("indexes: spans lines",
           String(describing: TextLines.indexes(of: NSRange(location: 0, length: 5), in: r)), "0...2")
    expect("fenced: open and close",
           String(describing: TextLines.fenced(["a", "```", "- x", "```", "- y"])), "[false, true, true, true, false]")
    expect("fenced: unclosed runs to the end",
           String(describing: TextLines.fenced(["```swift", "1. a", "b"])), "[true, true, true]")
    expect("fenced: tildes",
           String(describing: TextLines.fenced(["~~~", "x", "~~~", "y"])), "[true, true, true, false]")

    // ListEditing.newline: the behaviour that existed before the extraction
    check("return continues a bullet", "- a|", "- a\n- |") { ListEditing.newline($0) }
    check("return continues '*' and '+'", "* a|", "* a\n* |") { ListEditing.newline($0) }
    check("return continues an indented bullet", "  - a|", "  - a\n  - |") { ListEditing.newline($0) }
    check("return increments '.'", "1. a|", "1. a\n2. |") { ListEditing.newline($0) }
    check("return increments ')'", "9) a|", "9) a\n10) |") { ListEditing.newline($0) }
    check("return increments ':'", "3: a|", "3: a\n4: |") { ListEditing.newline($0) }
    check("return continues a checkbox unticked", "- [x] a|", "- [x] a\n- [ ] |") { ListEditing.newline($0) }
    check("return splits the item at the caret", "- ab|cd", "- ab\n- |cd") { ListEditing.newline($0) }
    check("return on empty item ends the list", "- a\n- |", "- a\n|") { ListEditing.newline($0) }
    check("return on empty checkbox ends the list", "- [ ] |", "|") { ListEditing.newline($0) }
    check("return on empty ordered item ends the list", "1. a\n2. |", "1. a\n|") { ListEditing.newline($0) }
    check("return inside the marker is not a list return", "-| a", nil) { ListEditing.newline($0) }
    check("return with a selection is left alone", "- ‹a›", nil) { ListEditing.newline($0) }
    check("return on plain text is left alone", "hello|", nil) { ListEditing.newline($0) }
    check("return continues a quote", "> a|", "> a\n> |") { ListEditing.newline($0) }
    check("return on empty quote ends it", "> a\n> |", "> a\n|") { ListEditing.newline($0) }
    check("return continues a nested quote", ">> a|", ">> a\n>> |") { ListEditing.newline($0) }
}

func runIndentTests() {
    let tab = { (e: TextEdit) in ListEditing.indent(e, outdent: false) }
    let back = { (e: TextEdit) in ListEditing.indent(e, outdent: true) }

    check("tab indents with the caret at the end", "- a|", "    - a|", tab)
    check("tab indents with the caret in the middle of the text", "- a|bc", "    - a|bc", tab)
    check("tab indents with the caret at the very start", "|- a", "    |- a", tab)
    check("tab indents with the caret inside the marker", "-| a", "    -| a", tab)
    check("tab indents a numbered item", "1. a|", "    1. a|", tab)
    check("tab indents a checkbox", "- [ ] a|", "    - [ ] a|", tab)
    check("tab nests one more level", "    - a|", "        - a|", tab)
    check("tab keeps tabs when the item uses them", "\t- a|", "\t\t- a|", tab)
    check("tab on several selected items",
          "‹- a\n- b\n- c›", "    ‹- a\n    - b\n    - c›", tab)
    check("tab on a selection that stops at the next line's start",
          "‹- a\n›- b", "    ‹- a\n›- b", tab)
    check("tab only touches the list items of a mixed selection",
          "‹text\n- a\nmore›", "‹text\n    - a\nmore›", tab)
    check("tab outside a list is left alone", "plain|", nil, tab)
    check("tab on a selection with no list items is left alone", "‹one\ntwo›", nil, tab)
    check("tab in a quote is left alone", "> a|", nil, tab)
    check("tab in a fenced code block is left alone", "```\n- a|\n```", nil, tab)

    check("shift-tab outdents", "    - a|", "- a|", back)
    check("shift-tab outdents one level only", "        - a|", "    - a|", back)
    check("shift-tab outdents a tab", "\t\t- a|", "\t- a|", back)
    check("shift-tab with partial indent", "  - a|", "- a|", back)
    check("shift-tab at level zero does nothing but is handled", "- a|", "- a|", back)
    check("shift-tab on several items", "‹    - a\n        - b›", "‹- a\n    - b›", back)
    check("shift-tab outside a list is left alone", "plain|", nil, back)
}

func runEmptyItemTests() {
    let ret = { (e: TextEdit) in ListEditing.newline(e) }
    check("return on an empty nested item goes back a level", "- a\n    - b\n    - |", "- a\n    - b\n- |", ret)
    check("return on an empty twice-nested item goes back one level", "- a\n        - |", "- a\n    - |", ret)
    check("return on an empty nested checkbox goes back a level", "    - [ ] |", "- [ ] |", ret)
    check("return on an empty nested ordered item goes back a level", "1. a\n    1. |", "1. a\n2. |", ret)
    check("return on an empty top-level item ends the list", "- a\n    - b\n- |", "- a\n    - b\n|", ret)
    check("return on an empty tab-indented item goes back a level", "\t- |", "- |", ret)
}

func runRenumberTests() {
    let all = { (e: TextEdit) in ListEditing.renumber(e) as TextEdit? }

    check("renumber closes a gap", "1. a\n3. b|\n4. c", "1. a\n2. b|\n3. c", all)
    checkText("renumber starts from the first number", "5. a\n1. b\n1. c", "5. a\n6. b\n7. c", all)
    checkText("renumber keeps the ) delimiter", "1) a\n5) b", "1) a\n2) b", all)
    checkText("renumber keeps the : delimiter", "1: a\n5: b", "1: a\n2: b", all)
    checkText("renumber handles two digits", "9. a\n9. b\n9. c", "9. a\n10. b\n11. c", all)
    check("renumber shrinks digits and moves the caret", "9. a\n10. b|", "9. a\n10. b|", all)
    check("renumber moves the caret when digits change", "1. a\n10. b|", "1. a\n2. b|", all)
    checkText("a blank line separates blocks", "1. a\n2. b\n\n7. c\n9. d", "1. a\n2. b\n\n7. c\n8. d", all)
    checkText("sublevel restarts at 1", "1. a\n    4. x\n    5. y\n2. b", "1. a\n    1. x\n    2. y\n2. b", all)
    checkText("each parent gets its own sublist from 1",
          "1. a\n    1. x\n    2. y\n2. b\n    3. z",
          "1. a\n    1. x\n    2. y\n2. b\n    1. z", all)
    checkText("a deeper bullet does not break the run", "1. a\n    - x\n5. b", "1. a\n    - x\n2. b", all)
    checkText("a bullet at the same level ends the run", "1. a\n- x\n5. b", "1. a\n- x\n5. b", all)
    checkText("a checkbox item is numbered too", "1. [ ] a\n4. [x] b", "1. [ ] a\n2. [x] b", all)
    checkText("bullets are untouched", "- a\n- b", "- a\n- b", all)
    checkText("code fences are skipped", "1. a\n\n```\n1. x\n5. y\n```", "1. a\n\n```\n1. x\n5. y\n```", all)
    checkText("numbers inside a block after a fence", "```\n```\n3. a\n9. b", "```\n```\n3. a\n4. b", all)

    // touching: only blocks near the edit
    check("touching limits renumbering to nearby blocks",
          "1. a\n3. b|\n\ntext\n\n5. x\n9. y", "1. a\n2. b|\n\ntext\n\n5. x\n9. y") {
        ListEditing.renumber($0, touching: $0.selection)
    }

    // the editing commands renumber what they change
    let ret = { (e: TextEdit) in ListEditing.newline(e) }
    let tab = { (e: TextEdit) in ListEditing.indent(e, outdent: false) }
    let back = { (e: TextEdit) in ListEditing.indent(e, outdent: true) }
    check("return in the middle of a numbered list renumbers the rest",
          "1. a|\n2. b\n3. c", "1. a\n2. |\n3. b\n4. c", ret)
    check("return at the end renumbers the rest", "1. a\n2. b|\n3. c", "1. a\n2. b\n3. |\n4. c", ret)
    check("ending a list by return on an empty item renumbers", "1. a\n2. |\n3. c", "1. a\n|\n3. c", ret)
    check("return on empty nested item rejoins the parent run",
          "1. a\n    1. |\n2. b", "1. a\n2. |\n3. b", ret)
    check("tab restarts the item at 1 and closes the gap",
          "1. a\n2. b|\n3. c", "1. a\n    1. b|\n2. c", tab)
    check("tab on a middle item", "1. a\n2. b\n3. c|", "1. a\n2. b\n    1. c|", tab)
    check("shift-tab rejoins the parent run", "1. a\n    1. b|\n2. c", "1. a\n2. b|\n3. c", back)
    check("shift-tab renumbers the sublist that stays behind",
          "1. a\n    1. b|\n    2. c", "1. a\n2. b|\n    1. c", back)
    check("tab on several numbered items", "1. a\n‹2. b\n3. c›\n4. d", "1. a\n    ‹1. b\n    2. c›\n2. d", tab)
}

func runFenceTests() {
    let ret = { (e: TextEdit) in ListEditing.newline(e) }
    check("return in a fenced block does not continue a bullet", "```\n- a|\n```", nil, ret)
    check("return in a fenced block does not continue a number", "```\n1. a|\n```", nil, ret)
    check("return in a fenced block does not continue a quote", "```\n> a|\n```", nil, ret)
    check("return on an empty item in a fence leaves it alone", "```\n- |\n```", nil, ret)
    check("return in an unclosed fence does not continue", "```sh\n- a|", nil, ret)
    check("return in a ~~~ fence does not continue", "~~~\n- a|\n~~~", nil, ret)
    check("return after the closing fence continues again", "```\nx\n```\n- a|", "```\nx\n```\n- a\n- |", ret)
    check("return before a fence continues", "- a|\n```\nx\n```", "- a\n- |\n```\nx\n```", ret)
    check("return in a list that follows two fences", "```\na\n```\n```\nb\n```\n1. x|", "```\na\n```\n```\nb\n```\n1. x\n2. |", ret)
}

func runBulletTests() {
    expect("level 0 is a disc", String(ListEditing.bulletKind(level: 0).glyph), "•")
    expect("level 1 is a ring", String(ListEditing.bulletKind(level: 1).glyph), "◦")
    expect("level 2 is a square", String(ListEditing.bulletKind(level: 2).glyph), "▪")
    expect("level 3 wraps to a disc", String(ListEditing.bulletKind(level: 3).glyph), "•")
    expect("negative level is a disc", String(ListEditing.bulletKind(level: -1).glyph), "•")
    expect("level of no indent", String(ListEditing.level(ofLeading: "")), "0")
    expect("level of four spaces", String(ListEditing.level(ofLeading: "    ")), "1")
    expect("level of two spaces counts as one", String(ListEditing.level(ofLeading: "  ")), "1")
    expect("level of a tab", String(ListEditing.level(ofLeading: "\t")), "1")
    expect("level of tab and four spaces", String(ListEditing.level(ofLeading: "\t    ")), "2")
    expect("level of five spaces", String(ListEditing.level(ofLeading: "     ")), "2")
}
