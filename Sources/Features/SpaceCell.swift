import SwiftUI

/// One of the 80 tiles.
///
/// Compact by necessity. The brief asks for all 80 spaces legible on a 6.1-inch screen
/// *and* a 44pt minimum touch target; at 80 cells those two pull against each other, so the
/// cell carries only what it must — the number, and the plate suffix the brief requires —
/// and spends no height on decoration.
///
/// State is carried by fill, border *and* shape, never by colour alone, so the board stays
/// readable in greyscale and to colour-blind users: free is solid, taken is dashed.
struct SpaceCell: View {
    enum Appearance {
        case available
        case reserved
        case mine
        case selected

        var stroke: Color {
            switch self {
            case .available: return Theme.Palette.available
            case .reserved: return Theme.Palette.reserved.opacity(0.5)
            case .mine: return Theme.Palette.mine
            case .selected: return Theme.Palette.accent
            }
        }

        var fill: Color {
            switch self {
            case .available: return Theme.Palette.availableFill
            case .reserved: return Theme.Palette.reservedFill
            case .mine: return Theme.Palette.mineFill
            case .selected: return Theme.Palette.accentFill
            }
        }
    }

    let space: ParkingSpace
    let appearance: Appearance
    let action: () -> Void

    private var isInteractive: Bool {
        appearance == .available || appearance == .selected
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text("\(space.number)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(numberColour)

                if appearance == .mine {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Palette.mine)
                } else {
                    Text(space.plateLast3 ?? " ")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(appearance.fill, in: .rect(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        appearance.stroke,
                        style: StrokeStyle(
                            lineWidth: appearance == .selected ? 2 : 1,
                            dash: appearance == .reserved ? [3, 2.5] : []
                        )
                    )
            )
            // The visible tile is ~45pt wide; the hit area is extended into the surrounding
            // gutter so the real touch target clears 44pt on both axes.
            .contentShape(.rect.inset(by: -3))
        }
        .buttonStyle(SpringyCellStyle(isInteractive: isInteractive))
        .disabled(!isInteractive)
        .accessibilityIdentifier("space.\(space.number)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(appearance == .selected ? [.isButton, .isSelected] : [.isButton])
    }

    private var numberColour: Color {
        switch appearance {
        case .reserved: return Theme.Palette.inkMuted
        case .mine: return Theme.Palette.mine
        case .selected: return Theme.Palette.accent
        case .available: return Theme.Palette.ink
        }
    }

    private var accessibilityLabel: Text {
        switch appearance {
        case .available:
            return Text("Space \(space.number), available")
        case .selected:
            return Text("Space \(space.number), selected")
        case .mine:
            return Text("Space \(space.number), reserved by you")
        case .reserved:
            return Text("Space \(space.number), taken by plate ending \(space.plateLast3 ?? "unknown")")
        }
    }
}

/// Press feedback only on tiles you can actually act on, so the board does not pretend
/// a taken space is tappable.
private struct SpringyCellStyle: ButtonStyle {
    let isInteractive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isInteractive && configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
