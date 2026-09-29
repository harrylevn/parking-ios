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
    /// Landscape is the one place the guardrail yields: ~270pt of board height cannot hold
    /// ten rows at any usable size, so the board scrolls at a full target instead.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let layout = BoardLayout.fitting(count: grid.spaces.count, in: proxy.size)

            let scrolling = BoardLayout.scrolling(count: grid.spaces.count, width: proxy.size.width)

            // Ordered by what 6.3 actually asks for. "All 80 spaces legible on a 6.1-inch
            // screen without pinch-zoom" is the **guardrail**; the 44pt target is the
            // Default, and where the two collide in portrait the guardrail wins. An earlier
            // ordering put the target first, which sent the 6.1-inch board into a scroll view
            // showing nine rows of ten — the guardrail traded away to protect the thing that
            // was supposed to yield to it.
            if typeSize.isAccessibilitySize {
                // Large text needs generous cells more than it needs many of them.
                accessibleBoard()
            } else if verticalSizeClass == .compact, let scrolling {
                // Landscape. ~270pt of board height cannot show ten rows at any size worth
                // tapping, so this is the one orientation that scrolls by design, and it
                // keeps the full 44pt target while doing so.
                fixedBoard(scrolling)
                    .scrollableBoard()
            } else if let layout {
                // Portrait, and all 80 fit legibly: show them, whatever that costs the
                // vertical target. This is the 6.1-inch case the guardrail is written for.
                fixedBoard(layout)
            } else if let scrolling {
                // Smaller than the reference — a mini or an SE — where 80 legible cells do
                // not fit at all. Scrolling at a full target beats cells nobody can read.
                fixedBoard(scrolling)
                    .scrollableBoard()
            } else {
                accessibleBoard()
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
    private func accessibleBoard() -> some View {
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
        let animated = !reduceMotion && !model.disablesAnimations
        withAnimation(animated ? .snappy(duration: 0.22) : nil) {
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

    private func stat(value: Int, label: LocalizedStringKey, tint: Color) -> some View {
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

    private func item(color: Color, fill: Color, text: LocalizedStringKey, dashed: Bool) -> some View {
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

private extension View {
    /// Wraps a board that is taller than its space. Vertical indicators stay on: the whole
    /// point is that the user can tell there is more board below, which is what the old
    /// landscape rendering failed to communicate — it looked clipped rather than scrollable.
    func scrollableBoard() -> some View {
        ScrollView(.vertical, showsIndicators: true) { self }
    }
}
