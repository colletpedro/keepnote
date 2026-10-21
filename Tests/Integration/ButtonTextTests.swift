import AppKit
import SwiftUI

// MARK: - No button cut short, in English and in Portuguese

/// The width SwiftUI gives a button with `title`, at its natural size.
@MainActor
private func buttonWidth(_ title: String, controlSize: ControlSize = .regular, scale: CGFloat? = nil,
                         style: ButtonKind = .bordered) -> CGFloat {
    let view: AnyView
    switch style {
    case .bordered:
        view = AnyView(Button(title) {}.controlSize(controlSize).fixedSize())
    case .checkbox:
        view = AnyView(Toggle(title, isOn: .constant(true)).toggleStyle(.checkbox).controlSize(controlSize).fixedSize())
    case .noteFooter(let color):
        view = AnyView(Button(title) {}.buttonStyle(NoteFooterButtonStyle(color: color))
            .font(.system(size: 11.5 * (scale ?? 1))).fixedSize())
    case .plain(let size):
        view = AnyView(Text(title).font(.system(size: size * (scale ?? 1))).fixedSize())
    }
    let host = NSHostingView(rootView: view)
    return ceil(host.fittingSize.width)
}

private enum ButtonKind {
    case bordered, checkbox
    case noteFooter(NoteColor)
    case plain(CGFloat)
}

@MainActor
func runButtonTextTests() {
    let language = Localization.language
    func fits(_ name: String, _ widths: [CGFloat], spacing: CGFloat, other: CGFloat = 0, in room: CGFloat) {
        let need = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)) + other
        expectTrue("buttons (\(language)): \(name) fit (\(Int(need)) of \(Int(room)) pt)", need <= room)
    }

    for size in TextSize.allCases {
        let scale = CGFloat(size.scale)
        // A floating note's footer: the five swatches, then Delete, Mark
        // complete (or Reopen) and Close, at the narrowest a note can be.
        let swatches: CGFloat = 5 * 16 + 4 * 10 + 3
        let room = EdgeMetrics.minimumNoteSize.width - EdgeMetrics.tabWidth - 28
        // The buttons go under the swatches when the line is too short, so
        // each line must fit on its own.
        for middle in [L("Mark complete"), L("Reopen")] {
            fits("the note's footer buttons, \(size), \(middle)",
                 [buttonWidth(L("Delete"), scale: scale, style: .plain(11.5)),
                  buttonWidth(middle, scale: scale, style: .noteFooter(.sky)),
                  buttonWidth(L("Close"), scale: scale, style: .noteFooter(.sky))],
                 spacing: 10, in: room)
        }
        fits("the note's swatches", [], spacing: 0, other: swatches, in: room)
    }

    // The offer at the top of a new daily: Not now and Bring.
    fits("Not now and Bring", [buttonWidth(L("Not now")), buttonWidth(L("Bring"))], spacing: 8,
         in: EdgeMetrics.anchoredSize.width - EdgeMetrics.tabWidth - 28)

    // All Notes' pane at the window's narrowest: the buttons line on its own.
    let paneRoom: CGFloat = 900 - 180 - 260 - 32
    // At its narrowest the buttons take one line and the two choices the next.
    for archived in [false, true] {
        fits("the pane's buttons\(archived ? ", archived" : "")",
             [buttonWidth(L("Open"), controlSize: .small),
              buttonWidth(archived ? L("Move to Deck") : L("Archive"), controlSize: .small),
              buttonWidth(L("Export\u{2026}"), controlSize: .small)],
             spacing: 8, in: paneRoom)
    }
    fits("the pane's choices",
         [buttonWidth(L("Pin to Center"), controlSize: .small, style: .checkbox),
          buttonWidth(L("Keep on Deck"), controlSize: .small, style: .checkbox)],
         spacing: 8, in: paneRoom)

    // The Daily list's header at the list's narrowest: its name, Edit
    // Template… and the count.
    fits("the Daily list's header", [buttonWidth(L("Daily"), style: .plain(15)),
                                     buttonWidth(L("Edit Template\u{2026}"), controlSize: .small),
                                     buttonWidth(L("%d notes", 999), style: .plain(11.5))],
         spacing: 8, other: 32 + 8, in: 260)

    // Settings: the rows of buttons, inside the form's margins.
    let settingsRoom = SettingsWindowController.paneWidth - 2 * 40
    fits("Back Up Now and Restore…", [buttonWidth(L("Back Up Now")), buttonWidth(L("Restore\u{2026}"))], spacing: 8, in: settingsRoom)
    fits("Choose Folder… and Forget Folder", [buttonWidth(L("Choose Folder\u{2026}")), buttonWidth(L("Forget Folder"))], spacing: 8, in: settingsRoom)
    fits("Export All Notes… and Show Welcome…", [buttonWidth(L("Export All Notes\u{2026}")), buttonWidth(L("Show Welcome\u{2026}"))], spacing: 10, in: settingsRoom)
    fits("Restore Defaults beside its note", [buttonWidth(L("Restore Defaults"))], spacing: 0, other: 200, in: settingsRoom)
    fits("Relaunch Now beside its note", [buttonWidth(L("Relaunch Now"))], spacing: 0, other: 200, in: settingsRoom)

    // The notice: the longest message, Undo and the close button, within its
    // widest.
    fits("the notice", [buttonWidth(L("%d notes deleted", 12), style: .plain(12)),
                        buttonWidth(L("Undo"), controlSize: .small)],
         spacing: 12, other: 16 + 12 + 14 * 2 + 12 + 10, in: 560)

    // The find bar's count beside its arrows.
    fits("the find bar", [buttonWidth(L("No matches"), style: .plain(10.5)), buttonWidth(L("Find in note"), style: .plain(11.5))],
         spacing: 6, other: 3 * 22 + 14 * 2 + 16, in: EdgeMetrics.minimumNoteSize.width - EdgeMetrics.tabWidth)

    // Welcome: Get Started.
    fits("Get Started", [buttonWidth(L("Get Started"), controlSize: .large)], spacing: 0, in: 440 - 56)
}

/// No "..." where "…" belongs: in the interface text, in both languages.
func runEllipsisTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var found: [String] = []
    for language in ["en", "pt-BR"] {
        let path = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings").path
        let table = (NSDictionary(contentsOfFile: path) as? [String: String]) ?? [:]
        for (key, value) in table where key.contains("...") || value.contains("...") {
            found.append("\(language): \(key)")
        }
    }
    let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for file in sources {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        for literal in SwiftLiteralsLite.strings(in: text) where literal.contains("...") {
            found.append("\(file.lastPathComponent): \(literal)")
        }
    }
    for page in ["README.md", "README.pt-BR.md", "docs/index.html", "docs/pt-br/index.html"] {
        let text = (try? String(contentsOf: root.appendingPathComponent(page), encoding: .utf8)) ?? ""
        for line in text.components(separatedBy: "\n") where line.contains("...") && !line.contains("```") && !line.hasPrefix("    ") {
            found.append("\(page): \(line.prefix(60))")
        }
    }
    expect("text: \"…\", never \"...\"", found.sorted().joined(separator: "\n"), "")
}

/// Just enough of Swift's grammar to find string literals: comments and
/// ranges (`0...9`) are not strings.
enum SwiftLiteralsLite {
    static func strings(in text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            let code = line.components(separatedBy: "//").first ?? line
            var inString = false
            var current = ""
            var previous: Character = " "
            for character in code {
                if character == "\"" && previous != "\\" {
                    if inString { result.append(current); current = "" }
                    inString.toggle()
                } else if inString {
                    current.append(character)
                }
                previous = character
            }
        }
        return result
    }
}
