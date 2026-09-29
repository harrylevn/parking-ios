import SwiftUI

/// The bordered, labelled input used by both sign-in and registration.
///
/// Extracted rather than written twice: the focus ring, the border weights and the identifier
/// placement are exactly the details that drift apart when two screens each own a copy.
struct FormField<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let identifier: String
    let focused: Bool
    /// Shown while the field is fine — the rule, stated before it is broken.
    var hint: String?
    /// Replaces the hint once the field is wrong. Kept out of the way until the user has
    /// actually typed something, so an untouched form never looks like a list of mistakes.
    var problem: String?
    @ViewBuilder var content: Content

    private var borderColour: Color {
        if problem != nil { return Theme.Palette.danger }
        return focused ? Theme.Palette.accent : Theme.Palette.hairline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.inkMuted)

            content
                .frame(minHeight: Theme.Metric.tapTarget - 10)
                .padding(.horizontal, 12)
                .background(Theme.Palette.canvas, in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(borderColour, lineWidth: focused || problem != nil ? 1.5 : 1)
                )
                .accessibilityIdentifier(identifier)

            if let message = problem ?? hint {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(problem == nil ? Theme.Palette.inkMuted : Theme.Palette.danger)
                    .accessibilityIdentifier("\(identifier).note")
            }
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: problem)
    }
}
