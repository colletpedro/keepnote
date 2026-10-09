import Foundation

func runPreviewTextTests() {
    func make(title: String, plainBody: String) -> String { PreviewText.make(title: title, plainBody: plainBody) }
    expect("untitled: first line stands in for the title, so it is dropped",
           make(title: "", plainBody: "Call the dentist\nBring the card"), "Bring the card")
    expect("titled: the body is kept whole",
           make(title: "Errands", plainBody: "Call the dentist\nBring the card"), "Call the dentist Bring the card")
    expect("titled: a first line equal to the title is dropped",
           make(title: "Weekly plan", plainBody: "Weekly plan\nThings to finish"), "Things to finish")
    expect("titled: equality ignores case and padding",
           make(title: "weekly plan", plainBody: "  Weekly Plan  \nThings"), "Things")
    expect("titled: only the first line can repeat the title",
           make(title: "Plan", plainBody: "Intro\nPlan\nEnd"), "Intro Plan End")
    expect("leading blank lines are skipped before judging the first line",
           make(title: "", plainBody: "\n\nTitle line\nRest"), "Rest")
    expect("nothing left is the empty marker", make(title: "", plainBody: "Only a title"), PreviewText.empty)
    expect("empty body", make(title: "T", plainBody: ""), PreviewText.empty)
    expect("title repeated and nothing else", make(title: "Same", plainBody: "Same"), PreviewText.empty)
    expect("whitespace is collapsed", make(title: "T", plainBody: "a\t\tb\n\n  c"), "a b c")
}
