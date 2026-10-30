/// GreenButtonGridTests.swift

#if canImport(XCTest)
import XCTest
@testable import Rectangle

final class GreenButtonGridTests: XCTestCase {

    func testGridDimensionClamping() {
        let tooSmall = GridSelection.clampDimensions(columns: 0, rows: 1)
        XCTAssertEqual(tooSmall.columns, 2)
        XCTAssertEqual(tooSmall.rows, 2)

        let tooLarge = GridSelection.clampDimensions(columns: 99, rows: 40)
        XCTAssertEqual(tooLarge.columns, 12)
        XCTAssertEqual(tooLarge.rows, 10)

        let normal = GridSelection.clampDimensions(columns: 6, rows: 4)
        XCTAssertEqual(normal.columns, 6)
        XCTAssertEqual(normal.rows, 4)
    }

    func testLeftHalfSelectionIn6x4Grid() {
        let visibleFrame = CGRect(x: 0, y: 40, width: 1800, height: 1000)
        let selection = GridSelection(
            start: GridCell(column: 2, row: 3),
            end: GridCell(column: 0, row: 0)
        )

        XCTAssertEqual(selection.minColumn, 0)
        XCTAssertEqual(selection.maxColumn, 2)
        XCTAssertEqual(selection.minRow, 0)
        XCTAssertEqual(selection.maxRow, 3)
        XCTAssertEqual(selection.columnSpan, 3)
        XCTAssertEqual(selection.rowSpan, 4)
        XCTAssertFalse(selection.isFullGrid(columns: 6, rows: 4))
        XCTAssertEqual(selection.sharedEdges(columns: 6, rows: 4), .right)

        let frame = selection.targetFrame(in: visibleFrame, columns: 6, rows: 4)
        XCTAssertEqual(frame, CGRect(x: 0, y: 40, width: 900, height: 1000))
        XCTAssertEqual(selection.summaryLabel(columns: 6, rows: 4), "3 × 4  •  50% × 100%")
    }

    func testTopRightQuarterSelectionInAppKitCoordinates() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let selection = GridSelection(
            start: GridCell(column: 3, row: 0),
            end: GridCell(column: 5, row: 1)
        )

        XCTAssertEqual(selection.sharedEdges(columns: 6, rows: 4), [.left, .bottom])
        let frame = selection.targetFrame(in: visibleFrame, columns: 6, rows: 4)
        XCTAssertEqual(frame, CGRect(x: 700, y: 450, width: 600, height: 400))
    }

    func testCenterSelectionAppliesInteriorAndOuterGapsCorrectly() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let centerSelection = GridSelection(
            start: GridCell(column: 2, row: 1),
            end: GridCell(column: 3, row: 2)
        )
        XCTAssertEqual(centerSelection.sharedEdges(columns: 6, rows: 4), [.left, .right, .top, .bottom])

        let gapped = centerSelection.targetFrame(
            in: visibleFrame,
            columns: 6,
            rows: 4,
            gapSize: 10
        )
        XCTAssertEqual(gapped, CGRect(x: 405, y: 205, width: 390, height: 390))
    }

    func testFullGridSelectionHonorsApplyGapsToMaximize() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let full = GridSelection(
            start: GridCell(column: 0, row: 0),
            end: GridCell(column: 5, row: 3)
        )
        XCTAssertTrue(full.isFullGrid(columns: 6, rows: 4))

        let withoutMaxGaps = full.targetFrame(
            in: visibleFrame,
            columns: 6,
            rows: 4,
            gapSize: 12,
            applyGapsToMaximize: false
        )
        XCTAssertEqual(withoutMaxGaps, visibleFrame)

        let withMaxGaps = full.targetFrame(
            in: visibleFrame,
            columns: 6,
            rows: 4,
            gapSize: 12,
            applyGapsToMaximize: true
        )
        XCTAssertEqual(withMaxGaps, visibleFrame.insetBy(dx: 12, dy: 12))
    }

    func testCellHitTestingAndDragSlop() {
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 120)

        XCTAssertEqual(
            GridSelection.cell(at: CGPoint(x: 5, y: 5), in: bounds, columns: 6, rows: 4),
            GridCell(column: 0, row: 0)
        )
        XCTAssertEqual(
            GridSelection.cell(at: CGPoint(x: 239, y: 119), in: bounds, columns: 6, rows: 4),
            GridCell(column: 5, row: 3)
        )
        XCTAssertNil(
            GridSelection.cell(at: CGPoint(x: -10, y: 20), in: bounds, columns: 6, rows: 4, clampOutside: false)
        )
        XCTAssertEqual(
            GridSelection.cell(at: CGPoint(x: -10, y: 130), in: bounds, columns: 6, rows: 4, clampOutside: true, dragSlop: 24),
            GridCell(column: 0, row: 3)
        )
        XCTAssertNil(
            GridSelection.cell(at: CGPoint(x: -50, y: 20), in: bounds, columns: 6, rows: 4, clampOutside: true, dragSlop: 24)
        )
    }

    func testPopoverPlacementKeepsYellowMinimizeButtonClearAndFlipsNearBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let greenButton = CGRect(x: 156, y: 840, width: 12, height: 12)
        let cardSize = CGSize(width: 260, height: 197)

        let placement = GreenButtonPopoverPlacement(
            buttonAppKitFrame: greenButton,
            screenFrame: screen,
            cardSize: cardSize
        )

        XCTAssertTrue(placement.opensBelow)
        XCTAssertFalse(placement.containsHoverPoint(CGPoint(x: 142, y: 846)))
        XCTAssertTrue(placement.containsHoverPoint(CGPoint(x: 162, y: 846)))
        let midCorridorY = (placement.screenButtonBridgeRect.minY + placement.screenCardRect.maxY) / 2
        XCTAssertTrue(placement.containsHoverPoint(CGPoint(x: 162, y: midCorridorY)))

        let lowGreenButton = CGRect(x: 200, y: 60, width: 12, height: 12)
        let flippedPlacement = GreenButtonPopoverPlacement(
            buttonAppKitFrame: lowGreenButton,
            screenFrame: screen,
            cardSize: cardSize
        )
        XCTAssertFalse(flippedPlacement.opensBelow)
        XCTAssertGreaterThan(flippedPlacement.screenCardRect.minY, lowGreenButton.maxY)
    }

    func testKeyboardMoveResizeDensitySteppingAndCursorPlacement() {
        let initial = GridSelection(start: GridCell(column: 0, row: 0), end: GridCell(column: 2, row: 1))
        let shifted = initial.movedBy(dCol: 3, dRow: 2, resizeEndOnly: false, columns: 6, rows: 4)
        XCTAssertEqual(shifted, GridSelection(start: GridCell(column: 3, row: 2), end: GridCell(column: 5, row: 3)))

        let resized = initial.movedBy(dCol: 1, dRow: 1, resizeEndOnly: true, columns: 6, rows: 4)
        XCTAssertEqual(resized, GridSelection(start: GridCell(column: 0, row: 0), end: GridCell(column: 3, row: 2)))

        let finer = GridSelection.steppedDensity(fromColumns: 6, rows: 4, delta: 1)
        XCTAssertEqual(finer.columns, 8)
        XCTAssertEqual(finer.rows, 6)

        let coarser = GridSelection.steppedDensity(fromColumns: 6, rows: 4, delta: -1)
        XCTAssertEqual(coarser.columns, 4)
        XCTAssertEqual(coarser.rows, 3)

        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let topRightWindow = CGRect(x: 600, y: 400, width: 600, height: 400)
        let norm = GridSelection.normalizedFlippedRect(of: topRightWindow, in: screen)
        XCTAssertEqual(norm, CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5))

        let approx = GridSelection.approximating(windowAppKitFrame: topRightWindow, in: screen, columns: 6, rows: 4)
        XCTAssertEqual(approx, GridSelection(start: GridCell(column: 3, row: 0), end: GridCell(column: 5, row: 1)))

        let cursorPlacement = GreenButtonPopoverPlacement(
            cursorAppKitPoint: CGPoint(x: 700, y: 500),
            screenFrame: screen,
            cardSize: CGSize(width: 300, height: 220)
        )
        XCTAssertFalse(cursorPlacement.hasButtonBridge)
        XCTAssertTrue(cursorPlacement.opensBelow)
        XCTAssertTrue(cursorPlacement.containsHoverPoint(CGPoint(x: 700, y: cursorPlacement.screenCardRect.midY)))
    }

    @MainActor
    func testPanelHitTestingClicksAndKeyboardCommands() throws {
        _ = NSApplication.shared
        guard let hostScreen = NSScreen.screens.first else { return }

        let panel = GreenButtonGridPanel()
        defer { panel.dismiss() }

        var triggeredActions: [WindowAction] = []
        var selectedScreens: [Int] = []
        var movedToScreens: [Int] = []
        var changedDensities: [(Int, Int)] = []
        var committedGrids: [GridSelection] = []
        var clickedGreenButtonCount = 0
        var dismissCount = 0

        panel.onSelectAction = { triggeredActions.append($0) }
        panel.onSelectScreenIndex = { selectedScreens.append($0) }
        panel.onMoveToScreenIndex = { movedToScreens.append($0) }
        panel.onChangeGridDimensions = { changedDensities.append(($0, $1)) }
        panel.onSelectGrid = { committedGrids.append($0) }
        panel.onClickGreenButton = { clickedGreenButtonCount += 1 }
        panel.onRequestDismiss = { dismissCount += 1 }

        let buttonFrame = CGRect(
            x: hostScreen.visibleFrame.minX + 80,
            y: hostScreen.visibleFrame.maxY - 40,
            width: 12,
            height: 12
        )
        panel.present(
            anchor: .greenButton(buttonAppKitFrame: buttonFrame, interceptClick: true),
            on: hostScreen,
            screens: [hostScreen, hostScreen],
            sourceScreenIndex: 1,
            selectedScreenIndex: 1,
            columns: 6,
            rows: 4,
            isTargetMaximized: false,
            canRestoreTarget: true,
            currentWindowNormalizedRect: CGRect(x: 0, y: 0, width: 0.33, height: 1.0)
        )
        panel.layoutIfNeeded()

        let contentView = try XCTUnwrap(panel.contentView)

        func simulateClick(at windowPoint: CGPoint, clickCount: Int = 1) throws {
            let hitView = try XCTUnwrap(contentView.hitTest(windowPoint), "Expected non-nil hitTest at \(windowPoint)")
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: clickCount,
                pressure: 1
            ))
            let up = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.02,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: clickCount,
                pressure: 0
            ))
            hitView.mouseDown(with: down)
            hitView.mouseUp(with: up)
        }

        // 1. Transparent shadow padding outside card & corridor must pass clicks through (nil)
        XCTAssertNil(contentView.hitTest(CGPoint(x: 2, y: 2)))

        // 2. Every single preset button (including leftmost Maximize & Restore) must hit-test & fire onSelectAction
        let presets = panel.presetWindowRects
        XCTAssertEqual(presets.count, 9)
        for preset in presets {
            triggeredActions.removeAll()
            let center = CGPoint(x: preset.rectInWindow.midX, y: preset.rectInWindow.midY)
            try simulateClick(at: center)
            XCTAssertEqual(triggeredActions, [preset.action], "Failed clicking preset \(preset.action)")
        }

        // 3. Display switcher pills: single-click switches screen, double-click moves window to screen
        let displayRects = panel.displayPillWindowRects
        XCTAssertEqual(displayRects.count, 2)
        try simulateClick(at: CGPoint(x: displayRects[0].midX, y: displayRects[0].midY), clickCount: 1)
        XCTAssertEqual(selectedScreens, [0])
        XCTAssertEqual(panel.selectedScreenIndex, 0)

        try simulateClick(at: CGPoint(x: displayRects[1].midX, y: displayRects[1].midY), clickCount: 2)
        XCTAssertEqual(movedToScreens, [1])

        // 4. Bottom density chips (3x2, 4x3, 6x4, 8x6) in bottom 18pt of card must hit-test & fire
        let initialDensities = panel.densityPillWindowRects
        XCTAssertEqual(initialDensities.count, 4)
        let chip8x6 = try XCTUnwrap(initialDensities.first { $0.cols == 8 && $0.rows == 6 })
        try simulateClick(at: CGPoint(x: chip8x6.rectInWindow.midX, y: chip8x6.rectInWindow.midY))
        XCTAssertEqual(panel.columns, 8)
        XCTAssertEqual(panel.rows, 6)
        XCTAssertEqual(changedDensities.last?.0, 8)
        XCTAssertEqual(changedDensities.last?.1, 6)

        let updatedDensities = panel.densityPillWindowRects
        let chip3x2 = try XCTUnwrap(updatedDensities.first { $0.cols == 3 && $0.rows == 2 })
        try simulateClick(at: CGPoint(x: chip3x2.rectInWindow.midX, y: chip3x2.rectInWindow.midY))
        XCTAssertEqual(panel.columns, 3)
        XCTAssertEqual(panel.rows, 2)

        // 5. Green button bridge click
        let placement = try XCTUnwrap(panel.currentPlacement)
        let bridgeMid = CGPoint(x: placement.buttonBridgeRect.midX, y: placement.buttonBridgeRect.midY)
        try simulateClick(at: bridgeMid)
        XCTAssertEqual(clickedGreenButtonCount, 1)

        // 6. Grid multi-cell drag (top-left cell to cell (2, 1))
        let gridRect = panel.gridCanvasWindowRect
        let startDragPt = CGPoint(x: gridRect.minX + 12, y: gridRect.maxY - 12)
        let endDragPt = CGPoint(x: gridRect.minX + gridRect.width * 0.75, y: gridRect.minY + 12)
        let gridHit = try XCTUnwrap(contentView.hitTest(startDragPt))
        let dragDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startDragPt,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 10,
            clickCount: 1,
            pressure: 1
        ))
        let dragMove = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endDragPt,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.02,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 11,
            clickCount: 1,
            pressure: 1
        ))
        let dragUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endDragPt,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.04,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 12,
            clickCount: 1,
            pressure: 0
        ))
        gridHit.mouseDown(with: dragDown)
        gridHit.mouseDragged(with: dragMove)
        gridHit.mouseUp(with: dragUp)
        XCTAssertEqual(committedGrids.count, 1)
        XCTAssertGreaterThan(committedGrids[0].columnSpan, 1)
        XCTAssertGreaterThan(committedGrids[0].rowSpan, 1)

        // 7. Keyboard commands (Tab, 3 -> 6x4, Arrow, Shift+Arrow, Return, Escape)
        committedGrids.removeAll()
        XCTAssertTrue(panel.handleKeyCommand(keyCode: 48, modifiers: [])) // Tab -> screen 1
        XCTAssertEqual(panel.selectedScreenIndex, 1)
        XCTAssertTrue(panel.handleKeyCommand(keyCode: 20, modifiers: [])) // '3' -> 6x4
        XCTAssertEqual(panel.columns, 6)
        XCTAssertEqual(panel.rows, 4)
        XCTAssertTrue(panel.handleKeyCommand(keyCode: 124, modifiers: [])) // RightArrow
        XCTAssertTrue(panel.handleKeyCommand(keyCode: 36, modifiers: [])) // Return
        XCTAssertEqual(committedGrids.count, 1)
        XCTAssertTrue(panel.handleKeyCommand(keyCode: 53, modifiers: [])) // Escape -> dismiss
        XCTAssertEqual(dismissCount, 1)
    }

    func testGitHubUpdaterSemanticVersionComparison() {
        XCTAssertEqual(GitHubSoftwareUpdater.cleanVersionString("v2.1.0-custom"), "2.1.0")
        XCTAssertEqual(GitHubSoftwareUpdater.cleanVersionString("V2.2"), "2.2")
        XCTAssertFalse(GitHubSoftwareUpdater.isRemoteVersionNewer("v2.1.0-custom", than: "2.1.0-custom"))
        XCTAssertFalse(GitHubSoftwareUpdater.isRemoteVersionNewer("v2.0.4", than: "2.1.0-custom"))
        XCTAssertTrue(GitHubSoftwareUpdater.isRemoteVersionNewer("v2.1.1-custom", than: "2.1.0-custom"))
        XCTAssertTrue(GitHubSoftwareUpdater.isRemoteVersionNewer("v2.2.0", than: "2.1.0-custom"))
    }
}

#elseif canImport(Testing)
import AppKit
import Testing
@testable import Rectangle

struct GreenButtonGridTests {

    @Test func gridDimensionClamping() {
        let tooSmall = GridSelection.clampDimensions(columns: 0, rows: 1)
        #expect(tooSmall.columns == 2)
        #expect(tooSmall.rows == 2)

        let tooLarge = GridSelection.clampDimensions(columns: 99, rows: 40)
        #expect(tooLarge.columns == 12)
        #expect(tooLarge.rows == 10)

        let normal = GridSelection.clampDimensions(columns: 6, rows: 4)
        #expect(normal.columns == 6)
        #expect(normal.rows == 4)
    }

    @Test func leftHalfSelectionIn6x4Grid() {
        let visibleFrame = CGRect(x: 0, y: 40, width: 1800, height: 1000)
        let selection = GridSelection(
            start: GridCell(column: 2, row: 3),
            end: GridCell(column: 0, row: 0)
        )

        #expect(selection.minColumn == 0)
        #expect(selection.maxColumn == 2)
        #expect(selection.minRow == 0)
        #expect(selection.maxRow == 3)
        #expect(selection.columnSpan == 3)
        #expect(selection.rowSpan == 4)
        #expect(!selection.isFullGrid(columns: 6, rows: 4))
        #expect(selection.sharedEdges(columns: 6, rows: 4) == .right)

        let frame = selection.targetFrame(in: visibleFrame, columns: 6, rows: 4)
        #expect(frame == CGRect(x: 0, y: 40, width: 900, height: 1000))
        #expect(selection.summaryLabel(columns: 6, rows: 4) == "3 × 4  •  50% × 100%")
    }

    @Test func topRightQuarterSelectionInAppKitCoordinates() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let selection = GridSelection(
            start: GridCell(column: 3, row: 0),
            end: GridCell(column: 5, row: 1)
        )

        #expect(selection.sharedEdges(columns: 6, rows: 4) == [.left, .bottom])
        let frame = selection.targetFrame(in: visibleFrame, columns: 6, rows: 4)
        #expect(frame == CGRect(x: 700, y: 450, width: 600, height: 400))
    }

    @Test func centerSelectionAppliesInteriorAndOuterGapsCorrectly() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let centerSelection = GridSelection(
            start: GridCell(column: 2, row: 1),
            end: GridCell(column: 3, row: 2)
        )
        #expect(centerSelection.sharedEdges(columns: 6, rows: 4) == [.left, .right, .top, .bottom])

        let gapped = centerSelection.targetFrame(
            in: visibleFrame,
            columns: 6,
            rows: 4,
            gapSize: 10
        )
        #expect(gapped == CGRect(x: 405, y: 205, width: 390, height: 390))
    }

    @Test func fullGridSelectionHonorsApplyGapsToMaximize() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let full = GridSelection(
            start: GridCell(column: 0, row: 0),
            end: GridCell(column: 5, row: 3)
        )
        #expect(full.isFullGrid(columns: 6, rows: 4))

        let withoutMaxGaps = full.targetFrame(
            in: visibleFrame,
            columns: 6,
            rows: 4,
            gapSize: 12,
            applyGapsToMaximize: false
        )
        #expect(withoutMaxGaps == visibleFrame)

        let withMaxGaps = full.targetFrame(
            in: visibleFrame,
            columns: 6,
            rows: 4,
            gapSize: 12,
            applyGapsToMaximize: true
        )
        #expect(withMaxGaps == visibleFrame.insetBy(dx: 12, dy: 12))
    }

    @Test func cellHitTestingAndDragSlop() {
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 120)

        #expect(
            GridSelection.cell(at: CGPoint(x: 5, y: 5), in: bounds, columns: 6, rows: 4)
                == GridCell(column: 0, row: 0)
        )
        #expect(
            GridSelection.cell(at: CGPoint(x: 239, y: 119), in: bounds, columns: 6, rows: 4)
                == GridCell(column: 5, row: 3)
        )
        #expect(
            GridSelection.cell(at: CGPoint(x: -10, y: 20), in: bounds, columns: 6, rows: 4, clampOutside: false)
                == nil
        )
        #expect(
            GridSelection.cell(at: CGPoint(x: -10, y: 130), in: bounds, columns: 6, rows: 4, clampOutside: true, dragSlop: 24)
                == GridCell(column: 0, row: 3)
        )
        #expect(
            GridSelection.cell(at: CGPoint(x: -50, y: 20), in: bounds, columns: 6, rows: 4, clampOutside: true, dragSlop: 24)
                == nil
        )
    }

    @Test func popoverPlacementKeepsYellowMinimizeButtonClearAndFlipsNearBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let greenButton = CGRect(x: 156, y: 840, width: 12, height: 12)
        let cardSize = CGSize(width: 260, height: 197)

        let placement = GreenButtonPopoverPlacement(
            buttonAppKitFrame: greenButton,
            screenFrame: screen,
            cardSize: cardSize
        )

        #expect(placement.opensBelow)
        #expect(!placement.containsHoverPoint(CGPoint(x: 142, y: 846)))
        #expect(placement.containsHoverPoint(CGPoint(x: 162, y: 846)))
        let midCorridorY = (placement.screenButtonBridgeRect.minY + placement.screenCardRect.maxY) / 2
        #expect(placement.containsHoverPoint(CGPoint(x: 162, y: midCorridorY)))

        let lowGreenButton = CGRect(x: 200, y: 60, width: 12, height: 12)
        let flippedPlacement = GreenButtonPopoverPlacement(
            buttonAppKitFrame: lowGreenButton,
            screenFrame: screen,
            cardSize: cardSize
        )
        #expect(!flippedPlacement.opensBelow)
        #expect(flippedPlacement.screenCardRect.minY > lowGreenButton.maxY)
    }

    @Test func keyboardMoveResizeDensitySteppingAndCursorPlacement() {
        let initial = GridSelection(start: GridCell(column: 0, row: 0), end: GridCell(column: 2, row: 1))
        let shifted = initial.movedBy(dCol: 3, dRow: 2, resizeEndOnly: false, columns: 6, rows: 4)
        #expect(shifted == GridSelection(start: GridCell(column: 3, row: 2), end: GridCell(column: 5, row: 3)))

        let resized = initial.movedBy(dCol: 1, dRow: 1, resizeEndOnly: true, columns: 6, rows: 4)
        #expect(resized == GridSelection(start: GridCell(column: 0, row: 0), end: GridCell(column: 3, row: 2)))

        let finer = GridSelection.steppedDensity(fromColumns: 6, rows: 4, delta: 1)
        #expect(finer.columns == 8 && finer.rows == 6)

        let coarser = GridSelection.steppedDensity(fromColumns: 6, rows: 4, delta: -1)
        #expect(coarser.columns == 4 && coarser.rows == 3)

        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let topRightWindow = CGRect(x: 600, y: 400, width: 600, height: 400)
        let norm = GridSelection.normalizedFlippedRect(of: topRightWindow, in: screen)
        #expect(norm == CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5))

        let approx = GridSelection.approximating(windowAppKitFrame: topRightWindow, in: screen, columns: 6, rows: 4)
        #expect(approx == GridSelection(start: GridCell(column: 3, row: 0), end: GridCell(column: 5, row: 1)))

        let cursorPlacement = GreenButtonPopoverPlacement(
            cursorAppKitPoint: CGPoint(x: 700, y: 500),
            screenFrame: screen,
            cardSize: CGSize(width: 300, height: 220)
        )
        #expect(!cursorPlacement.hasButtonBridge)
        #expect(cursorPlacement.opensBelow)
        #expect(cursorPlacement.containsHoverPoint(CGPoint(x: 700, y: cursorPlacement.screenCardRect.midY)))
    }

    @Test @MainActor func panelHitTestingClicksAndKeyboardCommands() throws {
        _ = NSApplication.shared
        guard let hostScreen = NSScreen.screens.first else { return }

        let panel = GreenButtonGridPanel()
        defer { panel.dismiss() }

        var triggeredActions: [WindowAction] = []
        var selectedScreens: [Int] = []
        var movedToScreens: [Int] = []
        var changedDensities: [(Int, Int)] = []
        var committedGrids: [GridSelection] = []
        var clickedGreenButtonCount = 0
        var dismissCount = 0

        panel.onSelectAction = { triggeredActions.append($0) }
        panel.onSelectScreenIndex = { selectedScreens.append($0) }
        panel.onMoveToScreenIndex = { movedToScreens.append($0) }
        panel.onChangeGridDimensions = { changedDensities.append(($0, $1)) }
        panel.onSelectGrid = { committedGrids.append($0) }
        panel.onClickGreenButton = { clickedGreenButtonCount += 1 }
        panel.onRequestDismiss = { dismissCount += 1 }

        let buttonFrame = CGRect(
            x: hostScreen.visibleFrame.minX + 80,
            y: hostScreen.visibleFrame.maxY - 40,
            width: 12,
            height: 12
        )
        panel.present(
            anchor: .greenButton(buttonAppKitFrame: buttonFrame, interceptClick: true),
            on: hostScreen,
            screens: [hostScreen, hostScreen],
            sourceScreenIndex: 1,
            selectedScreenIndex: 1,
            columns: 6,
            rows: 4,
            isTargetMaximized: false,
            canRestoreTarget: true,
            currentWindowNormalizedRect: CGRect(x: 0, y: 0, width: 0.33, height: 1.0)
        )
        panel.layoutIfNeeded()

        let contentView = try #require(panel.contentView)

        func simulateClick(at windowPoint: CGPoint, clickCount: Int = 1) throws {
            let hitView = try #require(contentView.hitTest(windowPoint))
            let down = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: clickCount,
                pressure: 1
            ))
            let up = try #require(NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.02,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: clickCount,
                pressure: 0
            ))
            hitView.mouseDown(with: down)
            hitView.mouseUp(with: up)
        }

        #expect(contentView.hitTest(CGPoint(x: 2, y: 2)) == nil)

        let presets = panel.presetWindowRects
        #expect(presets.count == 9)
        for preset in presets {
            triggeredActions.removeAll()
            let center = CGPoint(x: preset.rectInWindow.midX, y: preset.rectInWindow.midY)
            try simulateClick(at: center)
            #expect(triggeredActions == [preset.action])
        }

        let displayRects = panel.displayPillWindowRects
        #expect(displayRects.count == 2)
        try simulateClick(at: CGPoint(x: displayRects[0].midX, y: displayRects[0].midY), clickCount: 1)
        #expect(selectedScreens == [0])
        #expect(panel.selectedScreenIndex == 0)

        try simulateClick(at: CGPoint(x: displayRects[1].midX, y: displayRects[1].midY), clickCount: 2)
        #expect(movedToScreens == [1])

        let initialDensities = panel.densityPillWindowRects
        #expect(initialDensities.count == 4)
        let chip8x6 = try #require(initialDensities.first { $0.cols == 8 && $0.rows == 6 })
        try simulateClick(at: CGPoint(x: chip8x6.rectInWindow.midX, y: chip8x6.rectInWindow.midY))
        #expect(panel.columns == 8)
        #expect(panel.rows == 6)
        #expect(changedDensities.last?.0 == 8)
        #expect(changedDensities.last?.1 == 6)

        let updatedDensities = panel.densityPillWindowRects
        let chip3x2 = try #require(updatedDensities.first { $0.cols == 3 && $0.rows == 2 })
        try simulateClick(at: CGPoint(x: chip3x2.rectInWindow.midX, y: chip3x2.rectInWindow.midY))
        #expect(panel.columns == 3)
        #expect(panel.rows == 2)

        let placement = try #require(panel.currentPlacement)
        let bridgeMid = CGPoint(x: placement.buttonBridgeRect.midX, y: placement.buttonBridgeRect.midY)
        try simulateClick(at: bridgeMid)
        #expect(clickedGreenButtonCount == 1)

        #expect(panel.handleKeyCommand(keyCode: 48, modifiers: []))
        #expect(panel.selectedScreenIndex == 1)
        #expect(panel.handleKeyCommand(keyCode: 20, modifiers: []))
        #expect(panel.columns == 6)
        #expect(panel.rows == 4)
        #expect(panel.handleKeyCommand(keyCode: 124, modifiers: []))
        #expect(panel.handleKeyCommand(keyCode: 36, modifiers: []))
        #expect(committedGrids.count == 1)
        #expect(panel.handleKeyCommand(keyCode: 53, modifiers: []))
        #expect(dismissCount == 1)
    }

    @Test func githubUpdaterSemanticVersionComparison() {
        #expect(GitHubSoftwareUpdater.cleanVersionString("v2.1.0-custom") == "2.1.0")
        #expect(GitHubSoftwareUpdater.cleanVersionString("V2.2") == "2.2")
        #expect(!GitHubSoftwareUpdater.isRemoteVersionNewer("v2.1.0-custom", than: "2.1.0-custom"))
        #expect(!GitHubSoftwareUpdater.isRemoteVersionNewer("v2.0.4", than: "2.1.0-custom"))
        #expect(GitHubSoftwareUpdater.isRemoteVersionNewer("v2.1.1-custom", than: "2.1.0-custom"))
        #expect(GitHubSoftwareUpdater.isRemoteVersionNewer("v2.2.0", than: "2.1.0-custom"))
    }
}
#endif
