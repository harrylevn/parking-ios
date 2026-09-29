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
    /// Driven by `BoardLayout` so the board fits the screen it is on.
    var height: CGFloat = 46
    /// Half the grid gutter. Extends the touch target into the gap between tiles, so the
    /// effective target stays close to 44pt even where the visible tile is narrower.
    var hitSlop: CGFloat = 2
    let action: () -> Void

    private var isInteractive: Bool {
        appearance == .available || appearance == .selected
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text("\(space.number)")
                    .font(.system(size: min(15, height * 0.36), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(numberColour)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                if appearance == .mine {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Palette.mine)
                } else {
                    Text(space.plateLast3 ?? " ")
                        .font(.system(size: min(9, height * 0.22), weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
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
            .contentShape(.rect.inset(by: -hitSlop))
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
            // Two keys rather than a fallback word spliced into one: "unknown" inside the
            // interpolation would have been the one untranslated word in the sentence.
            if let plate = space.plateLast3 {
                return Text("Space \(space.number), taken by plate ending \(plate)")
            }
            return Text("Space \(space.number), taken")
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
