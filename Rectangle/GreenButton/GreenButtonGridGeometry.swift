/// GreenButtonGridGeometry.swift

import Cocoa

struct GridCell: Equatable, Hashable {
    let column: Int
    let row: Int
}

struct GridSelection: Equatable {
    static let columnRange = 2...12
    static let rowRange = 2...10
    static let quickDensities: [(columns: Int, rows: Int)] = [
        (3, 2),
        (4, 3),
        (6, 4),
        (8, 6)
    ]
    static let scrollDensities: [(columns: Int, rows: Int)] = [
        (3, 2),
        (4, 3),
        (6, 4),
        (8, 6),
        (12, 8)
    ]

    let start: GridCell
    let end: GridCell

    var minColumn: Int { min(start.column, end.column) }
    var maxColumn: Int { max(start.column, end.column) }
    var minRow: Int { min(start.row, end.row) }
    var maxRow: Int { max(start.row, end.row) }

    var columnSpan: Int { maxColumn - minColumn + 1 }
    var rowSpan: Int { maxRow - minRow + 1 }

    static func clampDimensions(columns: Int, rows: Int) -> (columns: Int, rows: Int) {
        let clampedCols = min(max(columns, columnRange.lowerBound), columnRange.upperBound)
        let clampedRows = min(max(rows, rowRange.lowerBound), rowRange.upperBound)
        return (clampedCols, clampedRows)
    }

    static func steppedDensity(fromColumns columns: Int, rows: Int, delta: Int) -> (columns: Int, rows: Int) {
        let current = clampDimensions(columns: columns, rows: rows)
        guard delta != 0 else { return current }
        let currentArea = current.columns * current.rows
        if delta > 0 {
            if let next = scrollDensities.first(where: { $0.columns * $0.rows > currentArea }) {
                return next
            }
            return scrollDensities.last ?? current
        } else {
            if let prev = scrollDensities.last(where: { $0.columns * $0.rows < currentArea }) {
                return prev
            }
            return scrollDensities.first ?? current
        }
    }

    func clamped(columns: Int, rows: Int) -> GridSelection {
        let dims = Self.clampDimensions(columns: columns, rows: rows)
        let clampCell = { (cell: GridCell) in
            GridCell(
                column: min(max(cell.column, 0), dims.columns - 1),
                row: min(max(cell.row, 0), dims.rows - 1)
            )
        }
        return GridSelection(start: clampCell(start), end: clampCell(end))
    }

    func movedBy(dCol: Int, dRow: Int, resizeEndOnly: Bool, columns: Int, rows: Int) -> GridSelection {
        let dims = Self.clampDimensions(columns: columns, rows: rows)
        let normalized = clamped(columns: dims.columns, rows: dims.rows)
        if resizeEndOnly {
            let newEnd = GridCell(
                column: min(max(normalized.end.column + dCol, 0), dims.columns - 1),
                row: min(max(normalized.end.row + dRow, 0), dims.rows - 1)
            )
            return GridSelection(start: normalized.start, end: newEnd)
        } else {
            let spanCols = normalized.columnSpan
            let spanRows = normalized.rowSpan
            let newMinCol = min(max(normalized.minColumn + dCol, 0), max(0, dims.columns - spanCols))
            let newMinRow = min(max(normalized.minRow + dRow, 0), max(0, dims.rows - spanRows))
            return GridSelection(
                start: GridCell(column: newMinCol, row: newMinRow),
                end: GridCell(column: newMinCol + spanCols - 1, row: newMinRow + spanRows - 1)
            )
        }
    }

    func contains(column: Int, row: Int) -> Bool {
        column >= minColumn && column <= maxColumn && row >= minRow && row <= maxRow
    }

    func isFullGrid(columns: Int, rows: Int) -> Bool {
        let dims = Self.clampDimensions(columns: columns, rows: rows)
        let normalized = clamped(columns: dims.columns, rows: dims.rows)
        return normalized.minColumn == 0
            && normalized.maxColumn == dims.columns - 1
            && normalized.minRow == 0
            && normalized.maxRow == dims.rows - 1
    }

    func sharedEdges(columns: Int, rows: Int) -> Edge {
        let dims = Self.clampDimensions(columns: columns, rows: rows)
        let normalized = clamped(columns: dims.columns, rows: dims.rows)
        var edges: Edge = .none
        if normalized.minColumn > 0 { edges.insert(.left) }
        if normalized.maxColumn < dims.columns - 1 { edges.insert(.right) }
        if normalized.minRow > 0 { edges.insert(.top) }
        if normalized.maxRow < dims.rows - 1 { edges.insert(.bottom) }
        return edges
    }

    /// Computes the destination frame in AppKit screen coordinates (bottom-left origin),
    /// where row `0` corresponds to the top of `visibleFrame`.
    func targetFrame(
        in visibleFrame: CGRect,
        columns: Int,
        rows: Int,
        gapSize: Float = 0,
        skipTopGap: Bool = false,
        applyGapsToMaximize: Bool = true
    ) -> CGRect {
        guard !visibleFrame.isNull, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return .null
        }

        let dims = Self.clampDimensions(columns: columns, rows: rows)
        let normalized = clamped(columns: dims.columns, rows: dims.rows)

        let cols = CGFloat(dims.columns)
        let rws = CGFloat(dims.rows)

        let xStart = visibleFrame.minX + round(visibleFrame.width * CGFloat(normalized.minColumn) / cols)
        let xEnd = visibleFrame.minX + round(visibleFrame.width * CGFloat(normalized.maxColumn + 1) / cols)

        let yTop = visibleFrame.maxY - round(visibleFrame.height * CGFloat(normalized.minRow) / rws)
        let yBottom = visibleFrame.maxY - round(visibleFrame.height * CGFloat(normalized.maxRow + 1) / rws)

        let rawRect = CGRect(
            x: xStart,
            y: yBottom,
            width: max(1, xEnd - xStart),
            height: max(1, yTop - yBottom)
        )

        guard gapSize > 0 else { return rawRect }
        if normalized.isFullGrid(columns: dims.columns, rows: dims.rows) && !applyGapsToMaximize {
            return rawRect
        }

        let interiorEdges = normalized.sharedEdges(columns: dims.columns, rows: dims.rows)
        return GapCalculation.applyGaps(
            rawRect,
            dimension: .both,
            sharedEdges: interiorEdges,
            gapSize: gapSize,
            skipTopGap: skipTopGap
        )
    }

    func summaryLabel(columns: Int, rows: Int) -> String {
        let dims = Self.clampDimensions(columns: columns, rows: rows)
        let normalized = clamped(columns: dims.columns, rows: dims.rows)
        let widthPct = Int(round(Double(normalized.columnSpan) * 100.0 / Double(dims.columns)))
        let heightPct = Int(round(Double(normalized.rowSpan) * 100.0 / Double(dims.rows)))
        return "\(normalized.columnSpan) × \(normalized.rowSpan)  •  \(widthPct)% × \(heightPct)%"
    }

    /// Returns a `[0, 1]` flipped rectangle (`y = 0` at top of `visibleFrame`) representing
    /// where `windowAppKitFrame` currently sits within `visibleFrame`.
    static func normalizedFlippedRect(of windowAppKitFrame: CGRect, in visibleFrame: CGRect) -> CGRect? {
        guard !windowAppKitFrame.isNull, !visibleFrame.isNull,
              visibleFrame.width > 1, visibleFrame.height > 1 else {
            return nil
        }
        let clipped = windowAppKitFrame.intersection(visibleFrame)
        guard !clipped.isNull, clipped.width > 4, clipped.height > 4 else {
            return nil
        }
        let normX = (clipped.minX - visibleFrame.minX) / visibleFrame.width
        let normY = (visibleFrame.maxY - clipped.maxY) / visibleFrame.height
        let normW = clipped.width / visibleFrame.width
        let normH = clipped.height / visibleFrame.height
        return CGRect(
            x: min(max(normX, 0), 1),
            y: min(max(normY, 0), 1),
            width: min(max(normW, 0.02), 1),
            height: min(max(normH, 0.02), 1)
        )
    }

    /// Approximates a window's AppKit frame onto the nearest grid selection.
    static func approximating(windowAppKitFrame: CGRect, in visibleFrame: CGRect, columns: Int, rows: Int) -> GridSelection {
        let dims = clampDimensions(columns: columns, rows: rows)
        guard let norm = normalizedFlippedRect(of: windowAppKitFrame, in: visibleFrame) else {
            return GridSelection(
                start: GridCell(column: 0, row: 0),
                end: GridCell(column: max(0, dims.columns / 2 - 1), row: dims.rows - 1)
            )
        }
        let startCol = min(dims.columns - 1, max(0, Int(round(norm.minX * CGFloat(dims.columns)))))
        let endCol = min(dims.columns - 1, max(startCol, Int(round(norm.maxX * CGFloat(dims.columns))) - 1))
        let startRow = min(dims.rows - 1, max(0, Int(round(norm.minY * CGFloat(dims.rows)))))
        let endRow = min(dims.rows - 1, max(startRow, Int(round(norm.maxY * CGFloat(dims.rows))) - 1))
        return GridSelection(
            start: GridCell(column: startCol, row: startRow),
            end: GridCell(column: endCol, row: endRow)
        )
    }

    /// Resolves a point inside a flipped (`origin = top-left`) grid bounds into a cell.
    /// When `clampOutside` is true, points within `dragSlop` outside `bounds` clamp to edge cells;
    /// points farther outside return `nil` so dragging way off the panel cancels cleanly.
    static func cell(
        at flippedPoint: CGPoint,
        in bounds: CGRect,
        columns: Int,
        rows: Int,
        clampOutside: Bool = false,
        dragSlop: CGFloat = 24
    ) -> GridCell? {
        let dims = clampDimensions(columns: columns, rows: rows)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        if clampOutside {
            let expanded = bounds.insetBy(dx: -dragSlop, dy: -dragSlop)
            guard expanded.contains(flippedPoint) else { return nil }
        } else {
            guard bounds.contains(flippedPoint) else { return nil }
        }

        let clampedX = min(max(flippedPoint.x - bounds.minX, 0), bounds.width - 0.001)
        let clampedY = min(max(flippedPoint.y - bounds.minY, 0), bounds.height - 0.001)

        let col = min(dims.columns - 1, max(0, Int(floor(clampedX * CGFloat(dims.columns) / bounds.width))))
        let row = min(dims.rows - 1, max(0, Int(floor(clampedY * CGFloat(dims.rows) / bounds.height))))
        return GridCell(column: col, row: row)
    }
}

struct GreenButtonPopoverPlacement {
    static let arrowHeight: CGFloat = 8
    static let arrowWidth: CGFloat = 16
    static let shadowOutset: CGFloat = 18
    static let screenMargin: CGFloat = 8

    /// Outer `NSPanel` frame in AppKit screen coordinates.
    let panelFrame: CGRect
    /// Card rectangle in panel-local coordinates (excluding the arrow).
    let cardRect: CGRect
    /// Green button hit/hover bridge in panel-local coordinates.
    let buttonBridgeRect: CGRect
    /// Arrow tip X in panel-local coordinates.
    let arrowTipX: CGFloat
    /// `true` when the card opens below the anchor point (standard case).
    let opensBelow: Bool
    /// `true` when anchored to a window's green stoplight button; `false` when triggered at cursor via shortcut.
    let hasButtonBridge: Bool

    var screenCardRect: CGRect {
        cardRect.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
    }

    var screenButtonBridgeRect: CGRect {
        buttonBridgeRect.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
    }

    init(buttonAppKitFrame: CGRect, screenFrame: CGRect, cardSize: CGSize) {
        let clampedScreen = screenFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)

        // Keep left expansion tiny (2pt) so we never overlap the yellow minimize button (~8pt to the left).
        let screenBridge = CGRect(
            x: buttonAppKitFrame.minX - 2,
            y: buttonAppKitFrame.minY - 5,
            width: buttonAppKitFrame.width + 6,
            height: buttonAppKitFrame.height + 9
        )

        let gapBelowButton: CGFloat = 3
        let preferredCardMaxYBelow = buttonAppKitFrame.minY - gapBelowButton - Self.arrowHeight
        let fitsBelow = (preferredCardMaxYBelow - cardSize.height) >= clampedScreen.minY

        let opensBelow = fitsBelow
        self.opensBelow = opensBelow
        self.hasButtonBridge = true

        // Align the card slightly toward the right of the green button (like macOS / Moom) while clamping on-screen.
        let preferredCardMinX = buttonAppKitFrame.midX - 34
        let cardMinX = min(
            max(preferredCardMinX, clampedScreen.minX),
            max(clampedScreen.minX, clampedScreen.maxX - cardSize.width)
        )

        let cardMinY: CGFloat
        if opensBelow {
            cardMinY = max(clampedScreen.minY, preferredCardMaxYBelow - cardSize.height)
        } else {
            let preferredCardMinYAbove = buttonAppKitFrame.maxY + gapBelowButton + Self.arrowHeight
            cardMinY = min(preferredCardMinYAbove, max(clampedScreen.minY, clampedScreen.maxY - cardSize.height))
        }

        let screenCard = CGRect(origin: CGPoint(x: cardMinX, y: cardMinY), size: cardSize)
        let paddedCard = screenCard.insetBy(dx: -Self.shadowOutset, dy: -Self.shadowOutset)
        let unionFrame = paddedCard.union(screenBridge).integral

        self.panelFrame = unionFrame
        self.cardRect = screenCard.offsetBy(dx: -unionFrame.minX, dy: -unionFrame.minY)
        self.buttonBridgeRect = screenBridge.offsetBy(dx: -unionFrame.minX, dy: -unionFrame.minY)

        let rawTipX = buttonAppKitFrame.midX - unionFrame.minX
        let minTipX = self.cardRect.minX + 18
        let maxTipX = self.cardRect.maxX - 18
        self.arrowTipX = min(max(rawTipX, minTipX), maxTipX)
    }

    init(cursorAppKitPoint: CGPoint, screenFrame: CGRect, cardSize: CGSize) {
        let clampedScreen = screenFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let cursorGap: CGFloat = 8
        let preferredCardMaxYBelow = cursorAppKitPoint.y - cursorGap - Self.arrowHeight
        let fitsBelow = (preferredCardMaxYBelow - cardSize.height) >= clampedScreen.minY

        self.opensBelow = fitsBelow
        self.hasButtonBridge = false

        let preferredCardMinX = round(cursorAppKitPoint.x - cardSize.width / 2)
        let cardMinX = min(
            max(preferredCardMinX, clampedScreen.minX),
            max(clampedScreen.minX, clampedScreen.maxX - cardSize.width)
        )

        let cardMinY: CGFloat
        if fitsBelow {
            cardMinY = max(clampedScreen.minY, preferredCardMaxYBelow - cardSize.height)
        } else {
            let preferredCardMinYAbove = cursorAppKitPoint.y + cursorGap + Self.arrowHeight
            cardMinY = min(preferredCardMinYAbove, max(clampedScreen.minY, clampedScreen.maxY - cardSize.height))
        }

        let screenCard = CGRect(origin: CGPoint(x: cardMinX, y: cardMinY), size: cardSize)
        let unionFrame = screenCard.insetBy(dx: -Self.shadowOutset, dy: -Self.shadowOutset).integral

        self.panelFrame = unionFrame
        self.cardRect = screenCard.offsetBy(dx: -unionFrame.minX, dy: -unionFrame.minY)
        self.buttonBridgeRect = .null

        let rawTipX = cursorAppKitPoint.x - unionFrame.minX
        let minTipX = self.cardRect.minX + 18
        let maxTipX = self.cardRect.maxX - 18
        self.arrowTipX = min(max(rawTipX, minTipX), maxTipX)
    }

    /// Returns whether `screenPoint` (in AppKit screen coordinates) is within the active hover zone
    /// (green button bridge, card body, or the diagonal corridor connecting them).
    func containsHoverPoint(_ screenPoint: CGPoint) -> Bool {
        let localPoint = CGPoint(x: screenPoint.x - panelFrame.minX, y: screenPoint.y - panelFrame.minY)
        return containsLocalHoverPoint(localPoint)
    }

    func containsLocalHoverPoint(_ localPoint: CGPoint) -> Bool {
        if cardRect.insetBy(dx: -8, dy: -8).contains(localPoint) {
            return true
        }
        guard hasButtonBridge, !buttonBridgeRect.isNull else {
            return false
        }
        if buttonBridgeRect.insetBy(dx: -2, dy: -3).contains(localPoint) {
            return true
        }

        // Check trapezoidal corridor between buttonBridgeRect and the card edge facing it.
        if opensBelow {
            let yTop = buttonBridgeRect.minY
            let yBottom = cardRect.maxY
            guard localPoint.y <= yTop + 2 && localPoint.y >= yBottom - 2 else { return false }
            let span = max(1, yTop - yBottom)
            let t = min(1, max(0, (yTop - localPoint.y) / span))
            let leftEdge = buttonBridgeRect.minX + (cardRect.minX - buttonBridgeRect.minX) * t - 4
            let rightEdge = buttonBridgeRect.maxX + (cardRect.maxX - buttonBridgeRect.maxX) * t + 4
            return localPoint.x >= leftEdge && localPoint.x <= rightEdge
        } else {
            let yBottom = buttonBridgeRect.maxY
            let yTop = cardRect.minY
            guard localPoint.y >= yBottom - 2 && localPoint.y <= yTop + 2 else { return false }
            let span = max(1, yTop - yBottom)
            let t = min(1, max(0, (localPoint.y - yBottom) / span))
            let leftEdge = buttonBridgeRect.minX + (cardRect.minX - buttonBridgeRect.minX) * t - 4
            let rightEdge = buttonBridgeRect.maxX + (cardRect.maxX - buttonBridgeRect.maxX) * t + 4
            return localPoint.x >= leftEdge && localPoint.x <= rightEdge
        }
    }
}
