import CoreGraphics
import Foundation

func runFrameRestoreTests() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    let minimum = CGSize(width: 280, height: 220)
    func fit(_ r: CGRect, _ screens: [CGRect] = [main, second]) -> CGRect {
        FrameRestore.fit(r, screens: screens, minimum: minimum)
    }

    // Encoding
    let frame = CGRect(x: 120.5, y: -30, width: 420, height: 440)
    expect("encode", FrameRestore.encode(frame), "120.5 -30.0 420.0 440.0")
    expectTrue("round trip", FrameRestore.decode(FrameRestore.encode(frame)) == frame)
    expectTrue("decode rejects junk", FrameRestore.decode("a b c d") == nil)
    expectTrue("decode rejects too few numbers", FrameRestore.decode("1 2 3") == nil)
    expectTrue("decode rejects an empty size", FrameRestore.decode("1 2 0 5") == nil)
    expectTrue("decode rejects nan", FrameRestore.decode("1 2 nan 5") == nil)
    expectTrue("decode rejects empty", FrameRestore.decode("") == nil)

    // Fitting
    let ok = CGRect(x: 200, y: 100, width: 420, height: 440)
    expectTrue("a frame already on screen is untouched", fit(ok) == ok)
    expectTrue("a frame on the second screen stays there",
               fit(CGRect(x: 1600, y: 200, width: 420, height: 440)) == CGRect(x: 1600, y: 200, width: 420, height: 440))
    expectTrue("a gone second screen brings the note back onto the first",
               fit(CGRect(x: 1600, y: 200, width: 420, height: 440), [main]) == CGRect(x: 1020, y: 200, width: 420, height: 440))
    expectTrue("hanging off the right edge is pulled in",
               fit(CGRect(x: 1300, y: 100, width: 420, height: 440), [main]) == CGRect(x: 1020, y: 100, width: 420, height: 440))
    expectTrue("hanging off the bottom is pulled up",
               fit(CGRect(x: 200, y: -300, width: 420, height: 440), [main]) == CGRect(x: 200, y: 0, width: 420, height: 440))
    expectTrue("hanging off the top is pulled down",
               fit(CGRect(x: 200, y: 700, width: 420, height: 440), [main]) == CGRect(x: 200, y: 435, width: 420, height: 440))
    expectTrue("larger than the screen is shrunk to it",
               fit(CGRect(x: 0, y: 0, width: 3000, height: 2000), [main]) == main)
    expectTrue("tiny is raised to the minimum",
               fit(CGRect(x: 10, y: 10, width: 50, height: 50), [main]) == CGRect(x: 10, y: 10, width: 280, height: 220))
    expectTrue("no screens: unchanged", fit(ok, []) == ok)
    expectTrue("it prefers the screen it overlaps most",
               fit(CGRect(x: 1300, y: 100, width: 420, height: 440)) == CGRect(x: 1440, y: 100, width: 420, height: 440))
}
