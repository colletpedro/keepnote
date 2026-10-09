import Foundation

func runSearchTextTests() {
    func hit(_ query: String, title: String = "", tags: [String] = []) -> String {
        String(SearchText.matches(query: query, title: title, tags: tags))
    }

    expect("a word of the title", hit("release", title: "Release notes"), "true")
    expect("a prefix of a word", hit("rel", title: "Release notes"), "true")
    expect("not the middle of a word", hit("lease", title: "Release notes"), "false")
    expect("case and accents fold", hit("CAFE", title: "Café com leite"), "true")
    expect("accents in the query fold too", hit("açúcar", title: "Acucar mascavo"), "true")
    expect("every term must match", hit("release plan", title: "Release notes"), "false")
    expect("terms in any order", hit("notes release", title: "Release notes"), "true")
    expect("a term may match the tags", hit("rel work", title: "Release notes", tags: ["work"]), "true")
    expect("tags match by prefix", hit("proj", tags: ["projects"]), "true")
    expect("punctuation splits a term into a phrase", hit("release-no", title: "Release notes"), "true")
    expect("only the last word of a phrase is a prefix", hit("rel-no", title: "Release notes"), "false")
    expect("a phrase stays in order", hit("notes-rel", title: "Release notes"), "false")
    expect("a phrase stays within one field", hit("notes-work", title: "Release notes", tags: ["work"]), "false")
    expect("a term of punctuation alone matches nothing", hit("#", title: "Release #1"), "false")
    expect("an empty query matches nothing", hit("  ", title: "Release"), "false")
    expect("digits are tokens", hit("2027", title: "Plan 2027-01"), "true")
}
