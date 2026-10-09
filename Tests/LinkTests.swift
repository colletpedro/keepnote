import Foundation

func runLinkTests() {
    let url = "https://example.com/a?b=1"
    let link = { (e: TextEdit) in Formatting.link(e, clipboard: nil) }
    let linkWithURL = { (e: TextEdit) in Formatting.link(e, clipboard: url) }

    // URL detection
    expect("url: https", Formatting.url(from: "https://a.com"), "https://a.com")
    expect("url: http with path and query", Formatting.url(from: "http://a.com/x?y=1#z"), "http://a.com/x?y=1#z")
    expect("url: mailto", Formatting.url(from: "mailto:a@b.com"), "mailto:a@b.com")
    expect("url: trims whitespace and newline", Formatting.url(from: "  https://a.com\n"), "https://a.com")
    expect("url: scheme is case-insensitive", Formatting.url(from: "HTTPS://A.COM"), "HTTPS://A.COM")
    expect("url: plain text is not a url", Formatting.url(from: "hello world"), nil)
    expect("url: two urls are not a url", Formatting.url(from: "https://a.com https://b.com"), nil)
    expect("url: text before is not a url", Formatting.url(from: "see https://a.com"), nil)
    expect("url: bare domain is not a url", Formatting.url(from: "example.com"), nil)
    expect("url: empty and nil", Formatting.url(from: ""), nil)
    expect("url: nil", Formatting.url(from: nil), nil)
    expect("url: scheme alone", Formatting.url(from: "https://"), nil)
    expect("destination escapes parentheses", Formatting.destination("https://a.com/x_(y)"), "https://a.com/x_%28y%29")

    // ⌘K
    check("link with an empty clipboard puts the caret in the url", "a ‹word› b", "a [word](|) b", link)
    check("link with a url on the clipboard uses it", "a ‹word› b", "a [word](https://example.com/a?b=1|) b", linkWithURL)
    check("link ignores a clipboard that is not a url",
          "‹word›", "[word](|)") { Formatting.link($0, clipboard: "just text") }
    check("link with no selection and no url", "a |b", "a [|]()b", link)
    check("link with no selection and a url", "a |b", "a [|](https://example.com/a?b=1)b", linkWithURL)
    check("link keeps surrounding blanks outside", "x‹ word ›y", "x [word](|) y", link)
    check("link over several lines does nothing", "‹a\nb›", nil, link)
    check("link in a fence does nothing", "```\n‹a›\n```", nil, link)
    check("link on a selection that is a whole line", "‹- item›", "[- item](|)", link)
    check("link escapes parentheses of the clipboard url", "‹w›", "[w](https://a.com/x_%28y%29|)") {
        Formatting.link($0, clipboard: "https://a.com/x_(y)")
    }
    check("link with accents and emoji", "‹ação 😀›", "[ação 😀](|)", link)

    // paste a URL over a selection
    let paste = { (e: TextEdit) in Formatting.pasteURL(e, pasted: url) }
    check("pasting a url over a selection makes a link", "a ‹word› b", "a [word](https://example.com/a?b=1)| b", paste)
    check("pasting a url with no selection is an ordinary paste", "a |b", nil, paste)
    check("pasting text over a selection is an ordinary paste", "a ‹word› b", nil) {
        Formatting.pasteURL($0, pasted: "plain")
    }
    check("pasting a url over a url replaces it", "‹https://old.com›", nil, paste)
    check("pasting a url over several lines is an ordinary paste", "‹a\nb›", nil, paste)
    check("pasting a url in a fence is an ordinary paste", "```\n‹a›\n```", nil, paste)
    check("pasting a url over blanks is an ordinary paste", "a‹  ›b", nil, paste)
    check("pasting a url with a trailing newline", "‹w›", "[w](https://example.com/a?b=1)|") {
        Formatting.pasteURL($0, pasted: url + "\n")
    }
    check("pasting keeps blanks outside the link", "‹ w ›", " [w](https://example.com/a?b=1)| ", paste)
}
