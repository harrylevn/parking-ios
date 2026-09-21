import SwiftUI

/// Design tokens.
///
/// Defined in code rather than an asset catalog so every value is reviewable in a diff and
/// the reasoning sits next to the colour. Every colour is declared for both light and dark
/// appearance — dark mode is a guardrail, not an afterthought.
enum Theme {

    // MARK: - Palette

    /// Deliberately *not* the reference web client's green/red pairing.
    ///
    /// At 20:00 the board goes almost entirely reserved. Painting 80 cells red says
    /// "80 errors" when nothing has gone wrong — someone else simply got there first.
    /// Reserved is therefore a calm slate, and colour is spent where it carries meaning:
    /// green for what you can act on, amber for the space that is yours.
    enum Palette {
        static let available = adaptive(light: 0x1B9C5B, dark: 0x3DD68C)
        static let availableFill = adaptive(light: 0xE8F7EF, dark: 0x0F3325)

        static let reserved = adaptive(light: 0x8A94A6, dark: 0x6B7688)
        static let reservedFill = adaptive(light: 0xF1F3F7, dark: 0x1C2029)

        static let mine = adaptive(light: 0xB8860B, dark: 0xF5C451)
        static let mineFill = adaptive(light: 0xFDF4DC, dark: 0x3A2E0C)

        static let accent = adaptive(light: 0x2563EB, dark: 0x60A5FA)
        static let accentFill = adaptive(light: 0xE6EEFE, dark: 0x13294D)

        static let danger = adaptive(light: 0xC0392B, dark: 0xF87171)
        static let warning = adaptive(light: 0xB45309, dark: 0xFBBF24)

        static let canvas = adaptive(light: 0xF6F7F9, dark: 0x0B0D11)
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x161A21)
        static let hairline = adaptive(light: 0xE3E6EC, dark: 0x262B34)

        static let ink = adaptive(light: 0x0F1419, dark: 0xF2F4F7)
        static let inkMuted = adaptive(light: 0x5C6573, dark: 0x99A2B0)
    }

    // MARK: - Metrics

    enum Metric {
        /// Minimum touch target and minimum grid cell, per the accessibility guardrail.
        static let tapTarget: CGFloat = 44
        static let corner: CGFloat = 12
        static let cardCorner: CGFloat = 18
        static let gutter: CGFloat = 16
        static let cellSpacing: CGFloat = 7
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Shared building blocks

/// A surface with a hairline border rather than a drop shadow. Shadows on a board of 80
/// tiles turn into visual noise; a hairline keeps the grid legible at density.
struct CardBackground: ViewModifier {
    var padding: CGFloat = Theme.Metric.gutter

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.Palette.surface, in: .rect(cornerRadius: Theme.Metric.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.cardCorner)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                    // Without this the hairline overlay sits above the card's contents and
                    // swallows every touch inside it — which made all 80 grid cells
                    // untappable while controls outside a card still worked.
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func card(padding: CGFloat = Theme.Metric.gutter) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// Full-width primary action.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.Palette.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                tint.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                in: .rect(cornerRadius: Theme.Metric.corner)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A small labelled pill, used for plate and balance in the header.
struct Pill: View {
    let icon: String
    let text: String
    var tint: Color = Theme.Palette.inkMuted

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

/// Haptics, used sparingly: the outcome of a race is worth feeling, a poll tick is not.
enum Haptics {
    @MainActor
    static func play(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    @MainActor
    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
