import SwiftUI

/// The app's visual language (SPEC N-9, DECISIONS ADR-016).
///
/// - One accent color, `AccentColor` in the asset catalog: a confident blue. It marks the
///   primary action on a screen and the app's icons, and nothing else.
/// - Red, orange and green appear only when they mean something: destructive actions,
///   recording, and Wrong / Partial / Correct grades.
/// - Everything else is neutral: system backgrounds, secondary text, bordered buttons.
enum Theme {
    static let accent = Color.accentColor
    /// Cards, tiles and grouped panels.
    static let cornerRadius: CGFloat = 16
    static let tileRadius: CGFloat = 14
    /// Readable line length on iPad.
    static let readableWidth: CGFloat = 640
}

extension View {
    /// The primary action of a screen: filled with the accent color. Disabled, it greys out,
    /// so the accent only shows once the action is ready.
    func primaryActionStyle() -> some View {
        buttonStyle(.glassProminent)
    }
}

/// An SF Symbol in a soft accent circle, used for feature icons.
struct AccentIcon: View {
    let systemName: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}
