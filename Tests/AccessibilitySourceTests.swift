import Foundation

/// The half of the accessibility check that has to read the source: SwiftUI
/// builds the accessibility nodes of its own views only while an assistive
/// app is connected, so the integration runner cannot walk them. Here every
/// SwiftUI button whose label is only an image must carry an accessibility
/// label; no stepper may be unnamed; and a tap gesture must make its view a
/// button for VoiceOver (or say why it does not need to, with `// a11y:`).
func runAccessibilitySourceTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let folder = root.appendingPathComponent("Sources/KeepNote/UI/SwiftUI")
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    var problems: [String] = []
    var buttons = 0

    for file in files.filter({ $0.pathExtension == "swift" }).sorted(by: { $0.path < $1.path }) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let chars = Array(text)
        let name = file.lastPathComponent
        func line(at index: Int) -> Int { chars[..<index].filter { $0 == "\n" }.count + 1 }
        func closingBrace(from open: Int) -> Int? {
            var depth = 0
            var i = open
            while i < chars.count {
                if chars[i] == "{" { depth += 1 } else if chars[i] == "}" { depth -= 1; if depth == 0 { return i } }
                i += 1
            }
            return nil
        }
        // Buttons: `Button(action: …) {` and `Button {` with a label closure.
        for pattern in ["Button(action:", "Button {"] {
            var search = text.startIndex
            while let range = text.range(of: pattern, range: search..<text.endIndex) {
                search = range.upperBound
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                guard let open = chars[start...].firstIndex(of: "{"), let close = closingBrace(from: open) else { continue }
                buttons += 1
                var label = String(chars[(open + 1)..<close])
                var end = close
                if pattern == "Button {" {
                    // `Button { action } label: { … }`: the label is the second closure.
                    let rest = String(chars[close...])
                    guard rest.hasPrefix("} label:"), let labelOpen = chars[close...].firstIndex(of: "{").flatMap({ $0 == close ? chars[(close + 1)...].firstIndex(of: "{") : $0 }),
                          let labelClose = closingBrace(from: labelOpen) else { continue }
                    label = String(chars[(labelOpen + 1)..<labelClose])
                    end = labelClose
                }
                let hasText = label.contains("Text(") || label.contains("Label(") || label.contains("L(\"")
                guard !hasText else { continue }
                let after = String(chars[end..<min(chars.count, end + 900)])
                let chain = after.components(separatedBy: "\n\n").first ?? after
                if !chain.contains(".accessibilityLabel(") {
                    problems.append("\(name):\(line(at: start)): a button with only an image has no accessibilityLabel")
                }
            }
        }
        // Steppers and tap gestures.
        for (index, lineText) in text.components(separatedBy: "\n").enumerated() {
            if lineText.contains("Stepper(\"\"") {
                problems.append("\(name):\(index + 1): a stepper with no name")
            }
            if lineText.contains(".onTapGesture") && !lineText.contains("// a11y:") {
                let lines = text.components(separatedBy: "\n")
                let window = lines[max(0, index - 12)...min(lines.count - 1, index + 12)].joined(separator: "\n")
                if !window.contains(".accessibilityAddTraits(.isButton)") && !window.contains(".accessibilityAction") {
                    problems.append("\(name):\(index + 1): a tap gesture VoiceOver cannot press")
                }
            }
        }
    }
    expectTrue("a11y source: the buttons were found (\(buttons))", buttons > 12)
    expect("a11y source: every control has a name VoiceOver can read", problems.joined(separator: "\n"), "")
}
