import Foundation

/// Mentions: a title and a site from the address alone.
func runLinkMentionTests() {
    func title(_ url: String) -> String { LinkMention.title(for: url) }
    expect("mention: a song's page", title("https://www.cifraclub.com.br/jack-johnson/traffic-in-the-sky/"),
           "Traffic in the Sky \u{2013} Jack Johnson")
    expect("mention: capitals kept, small words small", title("https://www.cifraclub.com.br/jack-johnson/you-and-your-heart/"),
           "You and Your Heart \u{2013} Jack Johnson")
    expect("mention: an id is not a title", title("https://example.com/articles/3f9a1c2b7d8e4f60a1b2/how_to-bake_bread"),
           "How to Bake Bread \u{2013} Articles")
    expect("mention: extensions and index pages go", title("https://example.com/docs/getting-started.html"),
           "Getting Started \u{2013} Docs")
    expect("mention: a language code is not a word", title("https://support.apple.com/pt-br/guide/mac-help"),
           "Mac Help \u{2013} Guide")
    expect("mention: a generic page name, the site", title("https://www.youtube.com/watch?v=abc"), "youtube.com")
    expect("mention: nothing at all, the site", title("https://www.notion.so/"), "notion.so")
    expect("mention: words with their own capitals kept", title("https://apple.com/iphone-16/iPhone-specs"), "iPhone Specs \u{2013} Iphone 16")
    expect("mention: accents decoded", title("https://pt.wikipedia.org/wiki/S%C3%A3o_Paulo"), "São Paulo \u{2013} Wiki")
    expect("mention: the site", LinkMention.site(for: "https://www.cifraclub.com.br/x"), "cifraclub.com.br")
    expect("mention: its initial", LinkMention.initial(for: "https://www.cifraclub.com.br/x"), "C")
    expect("mention: the same colour for a site, every time",
           String(LinkMention.colorIndex(for: "https://cifraclub.com.br/a")), String(LinkMention.colorIndex(for: "https://www.cifraclub.com.br/b")))

    // In the text.
    let url = "https://www.cifraclub.com.br/jack-johnson/traffic-in-the-sky/"
    let token = LinkMention.token(url: url)
    expect("mention: a Markdown link titled \"mention\"", token, "[Traffic in the Sky \u{2013} Jack Johnson](\(url) \"mention\")")
    let text = "See \(token) and [the brief](https://example.com) or https://example.org/x today"
    let ns = text as NSString
    expect("span: a mention", LinkMention.span(at: ns.range(of: "Traffic").location + 2, in: text)?.kind == .mention ? "mention" : "other", "mention")
    expect("span: a link", LinkMention.span(at: ns.range(of: "brief").location, in: text)?.url, "https://example.com")
    expect("span: an address", LinkMention.span(at: ns.range(of: "example.org").location, in: text)?.kind == .bare ? "bare" : "other", "bare")
    expectTrue("span: plain words are not one", LinkMention.span(at: ns.range(of: "today").location + 2, in: text) == nil)
    if let bare = LinkMention.span(at: ns.range(of: "example.org").location, in: text) {
        expect("convert: an address into a mention", LinkMention.converted(bare, toMention: true), "[example.org](https://example.org/x \"mention\")")
    }
    if let link = LinkMention.span(at: ns.range(of: "brief").location, in: text) {
        expect("convert: a link keeps its words", LinkMention.converted(link, toMention: true), "[the brief](https://example.com \"mention\")")
    }
    if let mention = LinkMention.span(at: ns.range(of: "Traffic").location, in: text) {
        expect("convert: a mention back into a link", LinkMention.converted(mention, toMention: false), "[Traffic in the Sky \u{2013} Jack Johnson](\(url))")
    }
}
