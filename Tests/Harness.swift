import Foundation

/// A tiny test harness. Text in the tests marks the selection inline: `|` is a
/// caret, `‹` and `›` bracket a selection. That keeps every case readable as
/// "before -> after".
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func state(_ marked: String) -> TextEdit {
    var text = ""
    var start: Int?
    var end: Int?
    var length = 0
    for ch in marked {
        switch ch {
        case "|": start = length; end = length
        case "‹": start = length
        case "›": end = length
        default:
            text.append(ch)
            length += String(ch).utf16.count
        }
    }
    let s = start ?? length
    return TextEdit(text: text, selection: NSRange(location: s, length: max(0, (end ?? s) - s)))
}

func marked(_ edit: TextEdit) -> String {
    let ns = edit.nsText
    let s = edit.selection.location
    let e = NSMaxRange(edit.selection)
    if edit.selection.length == 0 {
        return ns.substring(to: s) + "|" + ns.substring(from: s)
    }
    return ns.substring(to: s) + "‹" + ns.substring(with: edit.selection) + "›" + ns.substring(from: e)
}

func expect(_ name: String, _ actual: String?, _ expected: String?, file: String = #file, line: Int = #line) {
    if actual == expected {
        passes += 1
    } else {
        failures += 1
        print("FAIL \(name)  (\((file as NSString).lastPathComponent):\(line))")
        print("   expected: \(expected.map { $0.debugDescription } ?? "nil")")
        print("   actual:   \(actual.map { $0.debugDescription } ?? "nil")")
    }
}

func expectTrue(_ name: String, _ value: Bool, file: String = #file, line: Int = #line) {
    expect(name, String(value), "true", file: file, line: line)
}

/// before -> after, through a function that may decline (nil).
func check(_ name: String, _ before: String, _ after: String?, file: String = #file, line: Int = #line,
           _ transform: (TextEdit) -> TextEdit?) {
    expect(name, transform(state(before)).map(marked), after, file: file, line: line)
}

/// Like `check`, comparing only the text (no selection markers anywhere).
func checkText(_ name: String, _ before: String, _ after: String?, file: String = #file, line: Int = #line,
               _ transform: (TextEdit) -> TextEdit?) {
    expect(name, transform(state(before))?.text, after, file: file, line: line)
}

func finish() -> Never {
    print("\(passes) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
