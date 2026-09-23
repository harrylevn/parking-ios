import CoreGraphics
import Foundation

/// Chooses a column count and cell size so that **all 80 spaces fit in the space available**,
/// on whatever screen the app is running on.
///
/// This exists because section 6.3 makes "all 80 spaces legible on a 6.1-inch screen without
/// relying on pinch-zoom" a **guardrail**, while "44pt minimum touch targets" sits in the
/// Default column. Those two pull against each other at 80 cells on a 393×852 screen, and
/// when they conflict the guardrail wins: the board fits, and the touch target is the item
/// that flexes — see `Metrics.minCellWidth` and the note in docs/design.md §7.2.
///
/// The search is deliberately exhaustive rather than clever: 80 cells and a dozen candidate
/// column counts is nothing, and a readable rule beats a closed-form one that nobody can
/// check.
struct BoardLayout: Equatable {
    let columns: Int
    let rows: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let spacing: CGFloat

    enum Metrics {
        /// The reference 6.1-inch screen (iPhone 16 / 15 Pro), in points.
        static let referenceScreen = CGSize(width: 393, height: 852)

        /// Below this a cell cannot show a two-digit number and a three-character plate
        /// suffix at a legible size, which would breach the guardrail it is meant to serve.
        static let minCellWidth: CGFloat = 34
        static let minCellHeight: CGFloat = 30

        /// The vertical target never drops below 44pt, so a tap stays comfortable even
        /// where the horizontal dimension has to give.
        static let preferredCellHeight: CGFloat = 44

        /// How tall a cell may grow, relative to its own width.
        ///
        /// Cells have to stop growing somewhere or a large screen turns 80 tiles into 80
        /// slabs. The ceiling used to be a flat 64pt, which is invisible on a phone — the
        /// height available per row is smaller than that anyway — and wrong on a 13-inch
        /// iPad, where rows stopped growing with about a third of the board left empty
        /// beneath them. Tying it to the cell's own width keeps the tile roughly square at
        /// every size, and lets the board actually use the room it is given.
        static func maxCellHeight(forWidth width: CGFloat) -> CGFloat {
            max(preferredCellHeight, width * 1.25)
        }
    }

    /// The largest layout that fits `count` cells inside `size`, or `nil` if none does.
    static func fitting(
        count: Int,
        in size: CGSize,
        spacing: CGFloat = 4,
        candidateColumns: ClosedRange<Int> = 5...12
    ) -> BoardLayout? {
        var best: BoardLayout?

        for columns in candidateColumns {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let height = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)

            guard width >= Metrics.minCellWidth, height >= Metrics.minCellHeight else { continue }

            let candidate = BoardLayout(
                columns: columns, rows: rows,
                cellWidth: width.rounded(.down),
                cellHeight: min(height, Metrics.maxCellHeight(forWidth: width)).rounded(.down),
                spacing: spacing
            )

            // Ranking, in order:
            //  1. a layout that meets the 44pt target outright beats one that does not —
            //     the Default column yields to the guardrail, but only when it must;
            //  2. then the largest smallest-dimension, i.e. the most comfortable target;
            //  3. then the squarer cell.
            if let current = best {
                if candidate.isBetter(than: current) { best = candidate }
            } else {
                best = candidate
            }
        }

        return best
    }

    private var score: CGFloat { min(cellWidth, cellHeight) }
    private var squareness: CGFloat { -abs(cellWidth - cellHeight) }

    private func isBetter(than other: BoardLayout) -> Bool {
        if meetsPreferredTouchTarget != other.meetsPreferredTouchTarget {
            return meetsPreferredTouchTarget
        }
        if score != other.score { return score > other.score }
        return squareness > other.squareness
    }

    /// Total height the board occupies, for callers that need to reserve space.
    var totalHeight: CGFloat {
        CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
    }

    /// True when the touch target meets the 44×44 figure in the Default column outright,
    /// counting the gutter as part of the target (a tap in the gap between two tiles is
    /// resolved to the nearer one, so the effective target is the cell plus the spacing).
    var meetsPreferredTouchTarget: Bool {
        cellWidth + spacing >= Metrics.preferredCellHeight
            && cellHeight + spacing >= Metrics.preferredCellHeight
    }
}
