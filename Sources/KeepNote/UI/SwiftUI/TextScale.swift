import SwiftUI

/// The Text size setting, handed down the view tree so every font in a note,
/// the peek and All Notes follows it — and redraws the moment it changes.
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// `.font(.system(size:weight:design:))`, times the Text size.
struct ScaledFont: ViewModifier {
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var monospacedDigit = false
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                    monospacedDigit: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// The root of a note, the peek or All Notes: the setting, kept current.
    func followsTextSize() -> some View { modifier(FollowsTextSize()) }
}

private struct FollowsTextSize: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared
    func body(content: Content) -> some View {
        content.environment(\.textScale, settings.textSize.scale)
    }
}
