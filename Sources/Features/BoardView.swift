import SwiftUI

/// The 80-space board.
///
/// Sizes itself to whatever space it is handed: `BoardLayout` picks the column count so that
/// every one of the 80 cells fits without scrolling, which is the 6.3 guardrail. On a 6.1-inch
/// phone that lands on 8 columns; in landscape and on iPad it spreads wider and the cells grow.
struct BoardView: View {
    let grid: SpaceGrid
    @ObservedObject var model: GridViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// At accessibility text sizes a fixed board would clip, so it is allowed to scroll —
    /// the guardrail is about the default reading size, and clipping content is worse than
    /// scrolling it.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { proxy in
            let layout = BoardLayout.fitting(count: grid.spaces.count, in: proxy.size)

            if let layout, !typeSize.isAccessibilitySize {
                fixedBoard(layout)
            } else {
                scrollingBoard()
            }
        }
    }

    private func fixedBoard(_ layout: BoardLayout) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: layout.spacing),
            count: layout.columns
        )
        return LazyVGrid(columns: columns, spacing: layout.spacing) {
            cells(height: layout.cellHeight, spacing: layout.spacing)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Fallback for accessibility text sizes: same board, allowed to scroll rather than clip.
    private func scrollingBoard() -> some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5),
                spacing: 5
            ) {
                cells(height: 52, spacing: 5)
            }
        }
    }

    @ViewBuilder
    private func cells(height: CGFloat, spacing: CGFloat) -> some View {
        ForEach(grid.spaces) { space in
            SpaceCell(
                space: space,
                appearance: appearance(for: space),
                height: height,
                hitSlop: spacing / 2
            ) {
                select(space)
            }
        }
    }

    private func appearance(for space: ParkingSpace) -> SpaceCell.Appearance {
        if space.number == model.mySpace { return .mine }
        if space.number == model.selectedSpace { return .selected }
        return space.isAvailable ? .available : .reserved
    }

    private func select(_ space: ParkingSpace) {
        guard model.mySpace == nil else { return }
        Haptics.select()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            model.selectedSpace = model.selectedSpace == space.number ? nil : space.number
        }
    }
}

struct StatStrip: View {
    let grid: SpaceGrid

    var body: some View {
        HStack(spacing: 0) {
            stat(value: grid.availableSpaces, label: "Free", tint: Theme.Palette.available)
            divider
            stat(value: grid.reservedSpaces, label: "Taken", tint: Theme.Palette.reserved)
            divider
            stat(value: grid.totalSpaces, label: "Total", tint: Theme.Palette.inkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(grid.availableSpaces) free of \(grid.totalSpaces) spaces, \(grid.reservedSpaces) taken"
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(width: 1, height: 24)
    }

    private func stat(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(label)
                .font(.caption2.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(
                color: Theme.Palette.available, fill: Theme.Palette.availableFill,
                text: "Free", dashed: false
            )
            item(
                color: Theme.Palette.reserved, fill: Theme.Palette.reservedFill,
                text: "Taken", dashed: true
            )
            item(
                color: Theme.Palette.mine, fill: Theme.Palette.mineFill,
                text: "Yours", dashed: false
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func item(color: Color, fill: Color, text: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .frame(width: 13, height: 13)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [2.5, 2] : []))
                )
            Text(text)
                .font(.caption2)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
    }
}
