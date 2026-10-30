import Foundation

/// A note's Markdown read into blocks and drawn as HTML.
func runMarkdownHTMLTests() {
    func html(_ markdown: String) -> String {
        MarkdownHTML.render(markdown) { "<img alt=\"\($0.label)\">" }
    }

    expect("html: headings", html("# One\n## Two\n###### Six"), "<h1>One</h1>\n<h2>Two</h2>\n<h6>Six</h6>")
    expect("html: a paragraph keeps its line breaks", html("a\nb\n\nc"), "<p>a<br>b</p>\n<p>c</p>")
    expect("html: bold, italic, strike, highlight, code",
           html("**b** *i* _j_ ~~s~~ ==h== `c`"),
           "<p><strong>b</strong> <em>i</em> <em>j</em> <s>s</s> <mark>h</mark> <code>c</code></p>")
    expect("html: nested emphasis", html("**bold and *both***"), "<p><strong>bold and <em>both</em></strong></p>")
    expect("html: a link", html("see [the site](https://example.com/a?b=1&c=2)"),
           "<p>see <a href=\"https://example.com/a?b=1&amp;c=2\">the site</a></p>")
    expect("html: a link's title is not part of its address", html("[x](https://a.com \"mention\")"),
           "<p><a href=\"https://a.com\">x</a></p>")
    expect("html: a script link keeps its words, not its address", html("[x](javascript:alert(1))"), "<p>x</p>")
    expect("html: text is escaped", html("1 < 2 & \"3\" > <b>"), "<p>1 &lt; 2 &amp; &quot;3&quot; &gt; &lt;b&gt;</p>")
    expect("html: underscores inside words stay", html("snake_case_name"), "<p>snake_case_name</p>")
    expect("html: an escaped star", html("2 \\* 3"), "<p>2 * 3</p>")
    expect("html: wiki links read as words", html("[[Other note|the other]] and [[Plain]]"), "<p>the other and Plain</p>")
    expect("html: comments go", html("a %%secret%% b"), "<p>a  b</p>")

    expect("html: a bullet list", html("- a\n- b"), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
    expect("html: a numbered list keeps its start", html("3. a\n4. b"), "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>")
    expect("html: tasks", html("- [ ] open\n- [x] done"),
           "<ul>\n<li><input type=\"checkbox\" disabled> open</li>\n<li><input type=\"checkbox\" disabled checked> done</li>\n</ul>")
    expect("html: nested lists", html("- a\n  - b\n    - c\n- d"),
           "<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul></li>\n</ul></li>\n<li>d</li>\n</ul>")
    expect("html: a numbered list inside a bullet", html("- a\n\t1. b"),
           "<ul>\n<li>a\n<ol>\n<li>b</li>\n</ol></li>\n</ul>")
    expect("html: a quote", html("> a\n> b"), "<blockquote>\n<p>a<br>b</p>\n</blockquote>")
    expect("html: a code block is not read", html("```\n**x** <y>\n```"), "<pre><code>**x** &lt;y&gt;</code></pre>")
    expect("html: an unclosed fence runs to the end", html("```\na\nb"), "<pre><code>a\nb</code></pre>")
    expect("html: a rule", html("a\n\n---\n\nb"), "<p>a</p>\n<hr>\n<p>b</p>")
    expect("html: a table", html("| a | b |\n|---|---|\n| 1 | 2 |"),
           "<table>\n<thead><tr><th>a</th><th>b</th></tr></thead>\n<tbody>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>")

    let id = String(repeating: "ab", count: 32)
    expect("html: an attachment line is the closure's", html("before\n![A barn](attachment:\(id))\nafter"),
           "<p>before</p>\n<img alt=\"A barn\">\n<p>after</p>")

    // The blocks themselves.
    if case .heading(let level, let spans)? = MarkdownBlocks.parse("## x").first {
        expect("blocks: a heading's level", String(level), "2")
        expectTrue("blocks: and its words", spans == [.text("x")])
    } else {
        expectTrue("blocks: a heading is a heading", false)
    }
    expect("blocks: a table row's cells", MarkdownBlocks.cells(of: "| a | b \\| c |").joined(separator: ";"), "a;b | c")
    expectTrue("blocks: an empty note is nothing", MarkdownBlocks.parse("").isEmpty)
}
