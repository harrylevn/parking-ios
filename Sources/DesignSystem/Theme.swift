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
    ///
    /// Every value that carries text meets WCAG AA's 4.5:1 against the surface or fill it sits
    /// on, measured rather than judged by eye (docs/accessibility.md). Several did not: the
    /// green "Done" button was 3.5:1, a held space's gold number 3.0:1 on its own fill.
    enum Palette {
        static let available = adaptive(light: 0x15803D, dark: 0x3DD68C)
        static let availableFill = adaptive(light: 0xE8F7EF, dark: 0x0F3325)

        static let reserved = adaptive(light: 0x6B7588, dark: 0x7C8699)
        static let reservedFill = adaptive(light: 0xF1F3F7, dark: 0x1C2029)

        static let mine = adaptive(light: 0x8C6508, dark: 0xF5C451)
        static let mineFill = adaptive(light: 0xFDF4DC, dark: 0x3A2E0C)

        static let accent = adaptive(light: 0x1D4ED8, dark: 0x60A5FA)
        static let accentFill = adaptive(light: 0xE6EEFE, dark: 0x13294D)

        static let danger = adaptive(light: 0xC0392B, dark: 0xF87171)
        static let warning = adaptive(light: 0xB45309, dark: 0xFBBF24)

        static let canvas = adaptive(light: 0xF6F7F9, dark: 0x0B0D11)
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x161A21)
        static let hairline = adaptive(light: 0xE3E6EC, dark: 0x262B34)

        static let ink = adaptive(light: 0x0F1419, dark: 0xF2F4F7)
        static let inkMuted = adaptive(light: 0x5C6573, dark: 0x99A2B0)

        /// Text on a filled button. White on the light-mode tints, near-black on the dark-mode
        /// ones: those are brightened to read on a dark canvas, and white on them measured
        /// between 1.7:1 (amber) and 2.8:1 (red), so every primary button in dark mode failed.
        static let onTint = adaptive(light: 0xFFFFFF, dark: 0x0B0D11)
    }

    // MARK: - Metrics

    enum Metric {
        /// Minimum touch target and minimum grid cell, per the accessibility guardrail.
        static let tapTarget: CGFloat = 44
        static let corner: CGFloat = 12
        static let cardCorner: CGFloat = 18
        static let gutter: CGFloat = 16
        static let cellSpacing: CGFloat = 7

        /// Padding inside the board card, tighter than the 12–14 the other cards use.
        ///
        /// **Load-bearing, not taste.** The effective touch target of a cell is
        /// `(boardWidth + spacing) / columns`, so on the 6.1-inch reference every point of
        /// horizontal padding is worth an eighth of a point of target across eight columns.
        /// At 10 the board came to 43pt and missed the 44pt Default; at 6 it makes 44pt with
        /// all 80 cells still visible. `BoardLayoutTests` derives the board's width from this
        /// constant rather than restating it, so the two cannot drift apart — an earlier
        /// version hard-coded the inset and went on passing after the layout had changed
        /// underneath it.
        static let boardCardPadding: CGFloat = 6
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
/// The quiet counterpart to `PrimaryButtonStyle`, and it dims when disabled for the same
/// reason the primary does: a control that looks tappable and silently does nothing is worse
/// than one that reads as unavailable. SwiftUI's plain button does not dim enough to notice.
///
/// `contentShape` matters as much as the dimming. Without it the tappable region is the
/// text's own line box — measured at 20pt here — rather than the 44pt frame around it, so
/// the 6.3 Default is missed by a control that looks like it meets it.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let dimmed = isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35
        return configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.Palette.accent.opacity(dimmed))
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.Metric.tapTarget)
            .contentShape(.rect)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.Palette.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.Palette.onTint)
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

// MARK: - Large text

/// Sheets and cards laid out for the default sizes clip at the large ones, and a fixed-height
/// sheet cannot grow at all, so it truncates. Above `.large` the content is put in a scroll
/// view instead, where it can take the height it needs. At the default sizes nothing changes,
/// so the layouts measured against the 6.1-inch screen are untouched.
struct ScrollsAtLargeText: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize > .large {
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

extension View {
    func scrollsAtLargeText() -> some View {
        modifier(ScrollsAtLargeText())
    }
}

// MARK: - Sheet height

/// Opens a sheet at the height its content needs.
///
/// Fixed detents truncated text even at the default size: the ambiguous outcome's message is
/// longer than 380pt allows, and it ended "…or whether either of…". The content is laid out at
/// its ideal height and the sheet opens at exactly that, so it fits by construction. It is
/// measured in place rather than through a hidden copy: a copy laid out taller than its
/// container read to the accessibility audit as clipped text on every sheet. `minimum` only
/// covers the first frame, before a measurement exists. Above `.large` the sheet opens full
/// height and `scrollsAtLargeText` takes over.
struct FitsContentDetent: ViewModifier {
    var minimum: CGFloat = 200
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var measured: CGFloat = 0

    func body(content: Content) -> some View {
        if typeSize > .large {
            content.presentationDetents([.large])
        } else {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChangeCompat { measured = $0 }
                .presentationDetents([.height(max(minimum, measured))])
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// Reports this view's height. `onGeometryChange` would do it directly, but it needs
    /// iOS 18 and the deployment target is 17.
    func onGeometryChangeCompat(_ action: @escaping @MainActor (CGFloat) -> Void) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HeightKey.self) { height in
            Task { @MainActor in action(height) }
        }
    }
}

extension View {
    func fitsContentDetent() -> some View {
        modifier(FitsContentDetent())
    }
}
