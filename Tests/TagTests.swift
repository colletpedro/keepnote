import Foundation

func runTagTests() {
    func list(_ tags: [String]) -> String { tags.joined(separator: ",") }

    expect("parse: hashes", list(TagText.parse("#work #ideas")), "work,ideas")
    expect("parse: commas", list(TagText.parse("work, ideas")), "work,ideas")
    expect("parse: mixed separators", list(TagText.parse("#a,#b  c")), "a,b,c")
    expect("parse: lower-cases", list(TagText.parse("#Work")), "work")
    expect("parse: drops duplicates", list(TagText.parse("#a #A a")), "a")
    expect("parse: lone hash and blanks", list(TagText.parse("# #  ,")), "")
    expect("parse: empty", list(TagText.parse("")), "")
    expect("parse: keeps inner slashes and accents", list(TagText.parse("#área/sub")), "área/sub")
    expect("parse: a double hash is one tag", list(TagText.parse("##a")), "a")
    expect("normalize is shared with the store", list(TagText.normalize([" #A ", "b", "", "a"])), "a,b")

    expect("format", TagText.format(["a", "b"]), "#a #b")
    expect("format: none", TagText.format([]), "")
    expect("format then parse round-trips", list(TagText.parse(TagText.format(["x", "y/z"]))), "x,y/z")

    // refreshFromStore: does the field have to change?
    expectTrue("field differs when the store has other tags", TagText.fieldDiffers(from: ["a", "b"], field: "#a"))
    expectTrue("field differs when a tag came from sync", TagText.fieldDiffers(from: ["a", "new"], field: "#a"))
    expectTrue("field differs when tags were cleared remotely", TagText.fieldDiffers(from: [], field: "#a"))
    expectTrue("field differs when the field is empty and the store has tags", TagText.fieldDiffers(from: ["a"], field: ""))
    expectTrue("an equal field does not differ", !TagText.fieldDiffers(from: ["a", "b"], field: "#a #b"))
    expectTrue("another spelling of the same tags does not differ", !TagText.fieldDiffers(from: ["a", "b"], field: "A, b"))
    expectTrue("a trailing separator being typed does not differ", !TagText.fieldDiffers(from: ["a"], field: "#a, "))
    expectTrue("an empty field matches no tags", !TagText.fieldDiffers(from: [], field: ""))
    expectTrue("order matters", TagText.fieldDiffers(from: ["b", "a"], field: "#a #b"))
}

func runSuggestionTests() {
    let usage = [
        TagText.Usage(tag: "work", count: 5), TagText.Usage(tag: "workout", count: 2),
        TagText.Usage(tag: "homework", count: 9), TagText.Usage(tag: "ideas", count: 3),
        TagText.Usage(tag: "área", count: 1), TagText.Usage(tag: "personal", count: 4),
        TagText.Usage(tag: "reading", count: 4), TagText.Usage(tag: "travel", count: 2),
        TagText.Usage(tag: "zeta", count: 2),
    ]
    func suggest(_ token: String, existing: [String] = [], limit: Int = 6) -> String {
        TagText.suggestions(for: token, usage: usage, existing: existing, limit: limit).joined(separator: ",")
    }

    expect("empty token: the most used first", suggest(""), "homework,work,personal,reading,ideas,travel")
    expect("empty token: ties alphabetical", suggest("", limit: 9), "homework,work,personal,reading,ideas,travel,workout,zeta,área")
    expect("limit is respected", suggest("", limit: 2), "homework,work")
    expect("default limit is six", String(TagText.suggestions(for: "", usage: usage, existing: []).count), "6")
    expect("prefix before contains", suggest("wor"), "work,workout,homework")
    expect("prefix ties break on use then alphabet", suggest("work"), "work,workout,homework")
    expect("contains matches the middle", suggest("ea"), "reading,ideas,área")
    expect("case is ignored", suggest("WoRk"), "work,workout,homework")
    expect("accents are ignored in the token", suggest("area"), "área")
    expect("accents are ignored in the tags", suggest("ár"), "área")
    expect("a leading # is ignored", suggest("#wor"), "work,workout,homework")
    expect("blanks around the token are ignored", suggest("  wor "), "work,workout,homework")
    expect("no match gives nothing", suggest("xyz"), "")
    expect("tags the note has are excluded", suggest("wor", existing: ["work"]), "workout,homework")
    expect("exclusion ignores case and accents", suggest("", existing: ["HOMEWORK", "Area"], limit: 9), "work,personal,reading,ideas,travel,workout,zeta")
    expect("empty token excludes existing too", suggest("", existing: ["homework", "work"]), "personal,reading,ideas,travel,workout,zeta")
    expect("an exact match is still suggested", suggest("ideas"), "ideas")
    expect("no usage, no suggestions", String(TagText.suggestions(for: "a", usage: [], existing: []).count), "0")
    expect("limit zero", suggest("", limit: 0), "")

    let counted = TagText.usage(of: [["a", "B"], ["a"], ["#a", "a", "c"], []]).sorted { $0.tag < $1.tag }
    expect("usage counts notes, once each, normalised",
           counted.map { "\($0.tag)=\($0.count)" }.joined(separator: ","), "a=3,b=1,c=1")
    expect("name(ofToken:)", TagText.name(ofToken: " ##Wor "), "Wor")
}

func runTokenTests() {
    func tok(_ marked: String) -> String {
        let e = state(marked)
        let t = TagText.token(in: e.text, caret: e.selection.location)
        return "\(NSStringFromRange(t.range))\(t.name)"
    }
    expect("token at the end", tok("#a #wo|"), "{3, 3}wo")
    expect("token in the middle takes the whole word", tok("#a #wo|rk #b"), "{3, 5}work")
    expect("token at the start", tok("#a| #b"), "{0, 2}a")
    expect("token before a comma", tok("#a|, #b"), "{0, 2}a")
    expect("caret between words is an empty token", tok("#a | #b"), "{3, 0}")
    expect("caret after a trailing space is empty", tok("#a |"), "{3, 0}")
    expect("empty field", tok("|"), "{0, 0}")
    expect("caret right after a comma", tok("#a,|#b"), "{3, 2}b")
    expect("a word without a hash", tok("wor|"), "{0, 3}wor")
    expect("an out of range caret is clamped", String(TagText.token(in: "ab", caret: 99).range.location), "0")
    expect("text without the token", TagText.text("#a #b #c", without: TagText.token(in: "#a #b #c", caret: 4)), "#a   #c")

    func accept(_ tag: String, _ before: String) -> String {
        let e = state(before)
        let r = TagText.accept(tag, in: e.text, caret: e.selection.location)
        return marked(TextEdit(text: r.text, caret: r.caret))
    }
    expect("accept at the end adds a space and parks the caret after it", accept("work", "#wo|"), "#work |")
    expect("accept replaces a word without a hash", accept("work", "wo|"), "#work |")
    expect("accept after other tags", accept("work", "#a #wo|"), "#a #work |")
    expect("accept on an empty token", accept("work", "#a |"), "#a #work |")
    expect("accept in an empty field", accept("work", "|"), "#work |")
    expect("accept in the middle reuses the following space", accept("work", "#wo|k #b"), "#work |#b")
    expect("accept replaces the whole token", accept("work", "#xx|yy #b"), "#work |#b")
    expect("accept before a comma", accept("work", "#wo|, #b"), "#work |, #b")
    expect("accept keeps text before it", accept("b", "#a, #|"), "#a, #b |")
}

func runSelectionTests() {
    func move(_ current: Int?, _ count: Int, _ delta: Int) -> String {
        TagText.moveSelection(current, count: count, delta: delta).map(String.init) ?? "nil"
    }
    expect("down from nothing selects the first", move(nil, 3, 1), "0")
    expect("up from nothing selects the last", move(nil, 3, -1), "2")
    expect("down moves on", move(0, 3, 1), "1")
    expect("up moves back", move(2, 3, -1), "1")
    expect("down wraps from the last", move(2, 3, 1), "0")
    expect("up wraps from the first", move(0, 3, -1), "2")
    expect("no rows, no selection", move(nil, 0, 1), "nil")
    expect("a stale selection is replaced", move(5, 3, 1), "0")
    expect("one row stays selected", move(0, 1, 1), "0")

    func initial(_ typed: String, _ rows: Int) -> String {
        TagText.initialSelection(token: TagText.token(in: typed, caret: (typed as NSString).length), suggestionCount: rows).map(String.init) ?? "nil"
    }
    expect("the first suggestion starts selected", initial("#wo", 3), "0")
    expect("an empty token selects nothing, so Return still means done", initial("#a ", 6), "nil")
    expect("no suggestions select nothing", initial("#zz", 0), "nil")
}

func runCreateTests() {
    let usage = [TagText.Usage(tag: "work", count: 2), TagText.Usage(tag: "área", count: 1)]
    func create(_ token: String, existing: [String] = []) -> String {
        TagText.createCandidate(for: token, usage: usage, existing: existing) ?? "nil"
    }
    expect("a new word can be created", create("wor"), "wor")
    expect("creation is lower-cased", create("#NewTag"), "newtag")
    expect("an existing tag is not created again", create("work"), "nil")
    expect("existing is compared ignoring case", create("WORK"), "nil")
    expect("existing is compared ignoring accents", create("area"), "nil")
    expect("a tag the note already has is not created", create("mine", existing: ["Mine"]), "nil")
    expect("an empty token creates nothing", create(""), "nil")
    expect("only a hash creates nothing", create("#"), "nil")
    expect("blanks around are ignored", create("  new "), "new")
    expect("a prefix of an existing tag is still new", create("wo"), "wo")
}

func runFilterTests() {
    expectTrue("no filter shows everything", TagText.matches(tags: ["a"], filter: nil))
    expectTrue("no filter shows untagged notes", TagText.matches(tags: [], filter: nil))
    expectTrue("a note with the tag matches", TagText.matches(tags: ["a", "b"], filter: "b"))
    expectTrue("a note without the tag does not", !TagText.matches(tags: ["a"], filter: "b"))
    expectTrue("an untagged note does not match a tag", !TagText.matches(tags: [], filter: "a"))
    expectTrue("matching ignores case", TagText.matches(tags: ["work"], filter: "WORK"))
    expectTrue("matching ignores accents", TagText.matches(tags: ["área"], filter: "area"))
    expectTrue("matching ignores a leading hash", TagText.matches(tags: ["work"], filter: "#work"))
    expectTrue("the tag must match whole, not as a prefix", !TagText.matches(tags: ["workout"], filter: "work"))
    expectTrue("an empty filter shows everything", TagText.matches(tags: ["a"], filter: "#"))
}
