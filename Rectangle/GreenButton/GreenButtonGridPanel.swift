/// GreenButtonGridPanel.swift

import Carbon.HIToolbox
import Cocoa

final class GreenButtonGridPanel: NSPanel {
    enum AnchorStyle {
        case greenButton(buttonAppKitFrame: CGRect, interceptClick: Bool)
        case cursor(cursorAppKitPoint: CGPoint)
    }

    var onPreviewAction: ((WindowAction?) -> Void)?
    var onSelectAction: ((WindowAction) -> Void)?
    var onPreviewGrid: ((GridSelection?) -> Void)?
    var onSelectGrid: ((GridSelection) -> Void)?
    var onClickGreenButton: (() -> Void)?
    var onSelectScreenIndex: ((Int) -> Void)?
    var onMoveToScreenIndex: ((Int) -> Void)?
    var onChangeGridDimensions: ((Int, Int) -> Void)?
    var onRequestDismiss: (() -> Void)?

    private(set) var currentPlacement: GreenButtonPopoverPlacement?
    private(set) var columns: Int = 6
    private(set) var rows: Int = 4
    private(set) var selectedScreenIndex: Int = 0
    private(set) var isOpenedViaKeyboard: Bool = false
    private var screenNames: [String] = []
    private var sourceScreenIndex: Int = 0
    private var sourceWindowNormalizedRect: CGRect?

    var interceptsGreenButtonClick: Bool = true {
        didSet { hostView.interceptsGreenButtonClick = interceptsGreenButtonClick }
    }

    private let hostView = GreenButtonPanelHostView(frame: .zero)
    private let cardView = GreenButtonCardView(frame: .zero)

    var isDraggingGrid: Bool {
        cardView.isDraggingGrid
    }

    var isSelectingGrid: Bool {
        cardView.isSelectingGrid
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Rectangle Green Button Grid"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Disable system window open animation so the popover appears instantaneously.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        hostView.wantsLayer = true
        hostView.addSubview(cardView)
        contentView = hostView

        hostView.onClickGreenButton = { [weak self] in
            self?.onClickGreenButton?()
        }
        cardView.onPreviewAction = { [weak self] action in
            self?.onPreviewAction?(action)
        }
        cardView.onSelectAction = { [weak self] action in
            self?.onSelectAction?(action)
        }
        cardView.onPreviewGrid = { [weak self] selection in
            self?.onPreviewGrid?(selection)
        }
        cardView.onSelectGrid = { [weak self] selection in
            self?.onSelectGrid?(selection)
        }
        cardView.onSelectScreenIndex = { [weak self] index in
            self?.selectScreen(at: index)
        }
        cardView.onMoveToScreenIndex = { [weak self] index in
            self?.onMoveToScreenIndex?(index)
        }
        cardView.onChangeGridDimensions = { [weak self] newCols, newRows in
            self?.applyLiveGridDimensions(columns: newCols, rows: newRows)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    static func preferredCardSize(columns: Int, rows: Int, presetCount: Int, screenCount: Int) -> CGSize {
        let dims = GridSelection.clampDimensions(columns: columns, rows: rows)
        let minPresetWidth = CGFloat(presetCount) * 26 + CGFloat(max(0, presetCount - 1)) * 4 + 24
        let minFooterWidth: CGFloat = 296
        let gridPreferredWidth = CGFloat(dims.columns) * 34 + 28
        let width = min(384, max(minFooterWidth, max(minPresetWidth, gridPreferredWidth)))
        let gridHeight = min(216, max(124, CGFloat(dims.rows) * 30))
        let displayBarExtra: CGFloat = screenCount > 1 ? 28 : 0
        let height = 10 + 28 + 11 + displayBarExtra + gridHeight + 8 + 20 + 10
        return CGSize(width: round(width), height: round(height))
    }

    func present(
        anchor: AnchorStyle,
        on hostScreen: NSScreen,
        screens: [NSScreen],
        sourceScreenIndex: Int,
        selectedScreenIndex: Int,
        columns: Int,
        rows: Int,
        isTargetMaximized: Bool,
        canRestoreTarget: Bool,
        currentWindowNormalizedRect: CGRect?,
        initialKeyboardSelection: GridSelection? = nil
    ) {
        let dims = GridSelection.clampDimensions(columns: columns, rows: rows)
        self.columns = dims.columns
        self.rows = dims.rows
        self.sourceScreenIndex = sourceScreenIndex
        self.selectedScreenIndex = min(max(selectedScreenIndex, 0), max(0, screens.count - 1))
        self.sourceWindowNormalizedRect = currentWindowNormalizedRect
        self.screenNames = Self.makeScreenLabels(screens)

        let showNextDisplayButton = screens.count > 1
        let presets = Self.makePresets(
            isTargetMaximized: isTargetMaximized,
            canRestoreTarget: canRestoreTarget,
            showNextDisplay: showNextDisplayButton
        )
        let cardSize = Self.preferredCardSize(
            columns: dims.columns,
            rows: dims.rows,
            presetCount: presets.count,
            screenCount: screens.count
        )

        let placement: GreenButtonPopoverPlacement
        switch anchor {
        case let .greenButton(buttonAppKitFrame, interceptClick):
            self.isOpenedViaKeyboard = false
            self.interceptsGreenButtonClick = interceptClick
            placement = GreenButtonPopoverPlacement(
                buttonAppKitFrame: buttonAppKitFrame,
                screenFrame: hostScreen.visibleFrame,
                cardSize: cardSize
            )
            hostView.buttonHighlightRect = buttonAppKitFrame.offsetBy(
                dx: -placement.panelFrame.minX,
                dy: -placement.panelFrame.minY
            )
        case let .cursor(cursorAppKitPoint):
            self.isOpenedViaKeyboard = true
            self.interceptsGreenButtonClick = false
            placement = GreenButtonPopoverPlacement(
                cursorAppKitPoint: cursorAppKitPoint,
                screenFrame: hostScreen.visibleFrame,
                cardSize: cardSize
            )
            hostView.buttonHighlightRect = .null
        }
        self.currentPlacement = placement

        setFrame(placement.panelFrame, display: false)
        hostView.frame = CGRect(origin: .zero, size: placement.panelFrame.size)
        hostView.placement = placement
        hostView.interceptsGreenButtonClick = interceptsGreenButtonClick

        let arrowExtra = GreenButtonPopoverPlacement.arrowHeight
        let chromeFrame = CGRect(
            x: placement.cardRect.minX,
            y: placement.opensBelow ? placement.cardRect.minY : placement.cardRect.minY - arrowExtra,
            width: placement.cardRect.width,
            height: placement.cardRect.height + arrowExtra
        )
        let effectiveGhost = (self.selectedScreenIndex == self.sourceScreenIndex) ? currentWindowNormalizedRect : nil
        cardView.configure(
            frame: chromeFrame,
            opensBelow: placement.opensBelow,
            arrowTipLocalX: placement.arrowTipX - chromeFrame.minX,
            columns: dims.columns,
            rows: dims.rows,
            presets: presets,
            screenLabels: self.screenNames,
            selectedScreenIndex: self.selectedScreenIndex,
            ghostNormalizedRect: effectiveGhost,
            initialKeyboardSelection: initialKeyboardSelection
        )

        alphaValue = 1
        orderFrontRegardless()
        makeKey()
    }

    func selectScreen(at index: Int) {
        guard screenNames.indices.contains(index) else { return }
        let didChange = index != selectedScreenIndex
        selectedScreenIndex = index
        if didChange {
            onSelectScreenIndex?(index)
        }
        let effectiveGhost = (selectedScreenIndex == sourceScreenIndex) ? sourceWindowNormalizedRect : nil
        cardView.updateSelectedScreen(
            index: index,
            label: screenNames[index],
            ghostNormalizedRect: effectiveGhost
        )
    }

    func applyLiveGridDimensions(columns newColumns: Int, rows newRows: Int) {
        let dims = GridSelection.clampDimensions(columns: newColumns, rows: newRows)
        guard dims.columns != columns || dims.rows != rows else { return }
        columns = dims.columns
        rows = dims.rows
        cardView.updateGridDimensionsInPlace(columns: dims.columns, rows: dims.rows)
        onChangeGridDimensions?(dims.columns, dims.rows)
    }

    func handleGlobalMouseDragged(atScreenPoint screenPoint: CGPoint) {
        cardView.handleGlobalMouseDragged(atScreenPoint: screenPoint)
    }

    func handleGlobalMouseUp(atScreenPoint screenPoint: CGPoint) {
        cardView.handleGlobalMouseUp(atScreenPoint: screenPoint)
    }

    @discardableResult
    func cancelActiveGridSelection() -> Bool {
        cardView.cancelActiveGridSelection()
    }

    @discardableResult
    func handleKeyCommand(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let hasPrimaryModifier = !flags.intersection([.command, .option, .control]).isEmpty
        guard !hasPrimaryModifier else { return false }

        switch keyCode {
        case kVK_Escape:
            if !cancelActiveGridSelection() {
                onRequestDismiss?()
            }
            return true

        case kVK_Tab:
            guard screenNames.count > 1 else { return false }
            let delta = flags.contains(.shift) ? -1 : 1
            let next = (selectedScreenIndex + delta + screenNames.count) % screenNames.count
            selectScreen(at: next)
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            cardView.commitCurrentKeyboardOrHoverSelection()
            return true

        case kVK_Space where flags.isEmpty:
            cardView.commitCurrentKeyboardOrHoverSelection()
            return true

        case kVK_LeftArrow:
            cardView.moveSelectionByKeyboard(dCol: -1, dRow: 0, resizeEndOnly: flags.contains(.shift))
            return true

        case kVK_RightArrow:
            cardView.moveSelectionByKeyboard(dCol: 1, dRow: 0, resizeEndOnly: flags.contains(.shift))
            return true

        case kVK_UpArrow:
            cardView.moveSelectionByKeyboard(dCol: 0, dRow: -1, resizeEndOnly: flags.contains(.shift))
            return true

        case kVK_DownArrow:
            cardView.moveSelectionByKeyboard(dCol: 0, dRow: 1, resizeEndOnly: flags.contains(.shift))
            return true

        case kVK_ANSI_1 where flags.isEmpty:
            applyLiveGridDimensions(columns: 3, rows: 2)
            return true
        case kVK_ANSI_2 where flags.isEmpty:
            applyLiveGridDimensions(columns: 4, rows: 3)
            return true
        case kVK_ANSI_3 where flags.isEmpty:
            applyLiveGridDimensions(columns: 6, rows: 4)
            return true
        case kVK_ANSI_4 where flags.isEmpty:
            applyLiveGridDimensions(columns: 8, rows: 6)
            return true

        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyCommand(keyCode: Int(event.keyCode), modifiers: event.modifierFlags) {
            super.keyDown(with: event)
        }
    }

    // MARK: - Window-Coordinate Rects for Hit-Test Verification

    var presetWindowRects: [(action: WindowAction, rectInWindow: CGRect)] {
        cardView.presetWindowRects
    }

    var displayPillWindowRects: [CGRect] {
        cardView.displayPillWindowRects
    }

    var densityPillWindowRects: [(cols: Int, rows: Int, rectInWindow: CGRect)] {
        cardView.densityPillWindowRects
    }

    var gridCanvasWindowRect: CGRect {
        cardView.gridCanvasWindowRect
    }

    func dismiss() {
        cardView.resetInteractionState()
        orderOut(nil)
    }

    private static func makeScreenLabels(_ screens: [NSScreen]) -> [String] {
        guard screens.count > 1 else { return [] }
        return screens.enumerated().map { idx, screen in
            let rawName = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if screens.count <= 2, !rawName.isEmpty {
                let compact = rawName.count > 12 ? String(rawName.prefix(11)) + "…" : rawName
                return "\(idx + 1) · \(compact)"
            }
            return "\(String(localized: "Display")) \(idx + 1)"
        }
    }

    private static func makePresets(
        isTargetMaximized: Bool,
        canRestoreTarget: Bool,
        showNextDisplay: Bool
    ) -> [WindowAction] {
        var actions: [WindowAction] = []
        if isTargetMaximized {
            actions.append(.restore)
        } else {
            actions.append(.maximize)
            if canRestoreTarget {
                actions.append(.restore)
            }
        }
        actions.append(contentsOf: [
            .leftHalf,
            .rightHalf,
            .topHalf,
            .bottomHalf,
            .almostMaximize,
            .center
        ])
        if showNextDisplay {
            actions.append(.nextDisplay)
        }
        return actions
    }
}

// MARK: - Non-Draggable Visual Effect View

private final class NonDraggableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - Host View (WindowServer Hover Occlusion Bridge)

private final class GreenButtonPanelHostView: NSView {
    var placement: GreenButtonPopoverPlacement? {
        didSet { needsDisplay = true }
    }
    var buttonHighlightRect: CGRect = .null {
        didSet { needsDisplay = true }
    }
    var interceptsGreenButtonClick: Bool = true {
        didSet { needsDisplay = true }
    }
    var onClickGreenButton: (() -> Void)?

    private var pressedInBridge = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let placement, placement.hasButtonBridge, !placement.buttonBridgeRect.isNull else { return }

        // macOS SkyLight ignores transparent window pixels with alpha < 0.05 (5%) for cursor
        // tracking occlusion. Filling the green-button bridge + funnel corridor with 0.06 alpha
        // stays invisible to the eye while 100% occluding the underlying _NSThemeZoomWidget so
        // macOS's native green-button hover menu never opens on top of our grid.
        NSColor.white.withAlphaComponent(0.06).setFill()
        corridorPath(for: placement).fill()

        if !buttonHighlightRect.isNull {
            let ringRect = buttonHighlightRect.insetBy(dx: -1.5, dy: -1.5)
            let radius = min(ringRect.width, ringRect.height) / 2
            let ringPath = NSBezierPath(roundedRect: ringRect, xRadius: radius, yRadius: radius)
            NSColor.systemGreen.withAlphaComponent(0.18).setFill()
            ringPath.fill()
            NSColor.systemGreen.withAlphaComponent(0.75).setStroke()
            ringPath.lineWidth = 1.5
            ringPath.stroke()
        }
    }

    private func corridorPath(for placement: GreenButtonPopoverPlacement) -> NSBezierPath {
        let path = NSBezierPath()
        guard placement.hasButtonBridge, !placement.buttonBridgeRect.isNull else { return path }
        path.appendRect(placement.buttonBridgeRect)

        let bridge = placement.buttonBridgeRect
        let card = placement.cardRect
        if placement.opensBelow {
            path.move(to: CGPoint(x: bridge.minX, y: bridge.minY))
            path.line(to: CGPoint(x: bridge.maxX, y: bridge.minY))
            path.line(to: CGPoint(x: min(card.maxX, placement.arrowTipX + 28), y: card.maxY))
            path.line(to: CGPoint(x: max(card.minX, placement.arrowTipX - 28), y: card.maxY))
            path.close()
        } else {
            path.move(to: CGPoint(x: bridge.minX, y: bridge.maxY))
            path.line(to: CGPoint(x: bridge.maxX, y: bridge.maxY))
            path.line(to: CGPoint(x: min(card.maxX, placement.arrowTipX + 28), y: card.minY))
            path.line(to: CGPoint(x: max(card.minX, placement.arrowTipX - 28), y: card.minY))
            path.close()
        }
        return path
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview != nil ? convert(point, from: superview) : point
        guard bounds.contains(localPoint) else { return nil }

        // Prioritize the green-button bridge rect before testing the card's 8pt arrow strip.
        if let placement,
           placement.hasButtonBridge,
           !placement.buttonBridgeRect.isNull,
           placement.buttonBridgeRect.contains(localPoint) {
            return interceptsGreenButtonClick ? self : nil
        }

        // Delegate subview hit-testing to AppKit's native super.hitTest(point) so subview
        // origins (e.g. cardView.frame.origin = (18, 18)) are subtracted exactly once.
        if let hit = super.hitTest(point), hit !== self {
            return hit
        }

        guard let placement, placement.hasButtonBridge, !placement.buttonBridgeRect.isNull else { return nil }
        if corridorPath(for: placement).contains(localPoint) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard interceptsGreenButtonClick, let placement, placement.hasButtonBridge else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        pressedInBridge = placement.buttonBridgeRect.contains(localPoint)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedInBridge = false }
        guard pressedInBridge, interceptsGreenButtonClick, let placement, placement.hasButtonBridge else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        if placement.buttonBridgeRect.contains(localPoint) {
            onClickGreenButton?()
        }
    }
}

// MARK: - Popover Card View

private final class GreenButtonCardView: NSView {
    var onPreviewAction: ((WindowAction?) -> Void)?
    var onSelectAction: ((WindowAction) -> Void)?
    var onPreviewGrid: ((GridSelection?) -> Void)?
    var onSelectGrid: ((GridSelection) -> Void)?
    var onSelectScreenIndex: ((Int) -> Void)?
    var onMoveToScreenIndex: ((Int) -> Void)?
    var onChangeGridDimensions: ((Int, Int) -> Void)?

    private let effectView = NonDraggableVisualEffectView()
    private let borderLayer = CAShapeLayer()
    private let presetsContainer = NSView()
    private let dividerView = NSBox()
    private let displayBarContainer = NSView()
    private let displayTabHintLabel = NSTextField(labelWithString: "⇥")
    private let gridCanvas = GreenButtonGridCanvasView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let densityContainer = NSView()

    private var opensBelow = true
    private var arrowTipLocalX: CGFloat = 36
    private var presetButtons: [GreenButtonPresetButton] = []
    private var displayButtons: [GreenButtonSmallPillButton] = []
    private var densityButtons: [(cols: Int, rows: Int, button: GreenButtonSmallPillButton)] = []
    private var presetPreviewWorkItem: DispatchWorkItem?
    private var currentBodyRect: CGRect = .zero

    override var mouseDownCanMoveWindow: Bool { false }

    var isDraggingGrid: Bool {
        gridCanvas.isDraggingSelection
    }

    var isSelectingGrid: Bool {
        gridCanvas.isActivelySelectingRegion
    }

    var presetWindowRects: [(action: WindowAction, rectInWindow: CGRect)] {
        presetButtons.map { ($0.windowAction, $0.convert($0.bounds, to: nil)) }
    }

    var displayPillWindowRects: [CGRect] {
        guard !displayBarContainer.isHidden else { return [] }
        return displayButtons.map { $0.convert($0.bounds, to: nil) }
    }

    var densityPillWindowRects: [(cols: Int, rows: Int, rectInWindow: CGRect)] {
        densityButtons.map { ($0.cols, $0.rows, $0.button.convert($0.button.bounds, to: nil)) }
    }

    var gridCanvasWindowRect: CGRect {
        gridCanvas.convert(gridCanvas.bounds, to: nil)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -5)

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        addSubview(effectView)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)
        borderLayer.zPosition = 20

        effectView.addSubview(presetsContainer)

        dividerView.boxType = .separator
        effectView.addSubview(dividerView)

        displayTabHintLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        displayTabHintLabel.textColor = .tertiaryLabelColor
        displayTabHintLabel.alignment = .right
        displayTabHintLabel.toolTip = String(localized: "Press Tab to switch target display")
        displayBarContainer.addSubview(displayTabHintLabel)
        effectView.addSubview(displayBarContainer)

        effectView.addSubview(gridCanvas)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        effectView.addSubview(statusLabel)

        effectView.addSubview(densityContainer)

        gridCanvas.onSelectionStateChanged = { [weak self] selection, isActiveDragOrAnchor in
            guard let self else { return }
            self.presetPreviewWorkItem?.cancel()
            self.presetPreviewWorkItem = nil
            self.clearPresetHover()

            if let selection {
                self.statusLabel.stringValue = selection.summaryLabel(columns: self.gridCanvas.columns, rows: self.gridCanvas.rows)
                if isActiveDragOrAnchor {
                    self.onPreviewGrid?(selection)
                } else {
                    self.onPreviewGrid?(nil)
                }
            } else {
                self.statusLabel.stringValue = Self.idlePromptText
                self.onPreviewGrid?(nil)
            }
        }

        gridCanvas.onCommitSelection = { [weak self] selection in
            self?.onSelectGrid?(selection)
        }

        gridCanvas.onStepDensity = { [weak self] delta in
            guard let self else { return }
            let next = GridSelection.steppedDensity(
                fromColumns: self.gridCanvas.columns,
                rows: self.gridCanvas.rows,
                delta: delta
            )
            self.onChangeGridDimensions?(next.columns, next.rows)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === self || hit === effectView || hit === presetsContainer || hit === displayBarContainer || hit === densityContainer {
            let localPoint = superview != nil ? convert(point, from: superview) : point
            return currentBodyRect.contains(localPoint) ? hit : nil
        }
        return hit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderAppearance()
    }

    private static var idlePromptText: String {
        String(localized: "Drag grid or pick layout")
    }

    func handleGlobalMouseDragged(atScreenPoint screenPoint: CGPoint) {
        gridCanvas.handleGlobalMouseDragged(atScreenPoint: screenPoint)
    }

    func handleGlobalMouseUp(atScreenPoint screenPoint: CGPoint) {
        gridCanvas.handleGlobalMouseUp(atScreenPoint: screenPoint)
    }

    func cancelActiveGridSelection() -> Bool {
        gridCanvas.cancelActiveSelection()
    }

    func moveSelectionByKeyboard(dCol: Int, dRow: Int, resizeEndOnly: Bool) {
        gridCanvas.moveSelectionByKeyboard(dCol: dCol, dRow: dRow, resizeEndOnly: resizeEndOnly)
    }

    func commitCurrentKeyboardOrHoverSelection() {
        gridCanvas.commitCurrentSelectionOrDefault()
    }

    func updateSelectedScreen(index: Int, label: String, ghostNormalizedRect: CGRect?) {
        for (i, btn) in displayButtons.enumerated() {
            btn.isSelectedPill = (i == index)
        }
        gridCanvas.ghostNormalizedRect = ghostNormalizedRect
        if let selection = gridCanvas.activeSelection, gridCanvas.isActivelySelectingRegion {
            onPreviewGrid?(selection)
        } else {
            statusLabel.stringValue = "→ \(label)"
        }
    }

    func updateGridDimensionsInPlace(columns: Int, rows: Int) {
        gridCanvas.updateDimensionsPreservingRatio(columns: columns, rows: rows)
        rebuildDensityButtons(activeColumns: columns, activeRows: rows)
        layoutFooterSubviews()
        if !gridCanvas.isActivelySelectingRegion {
            statusLabel.stringValue = "\(columns) × \(rows)"
        }
    }

    func resetInteractionState() {
        presetPreviewWorkItem?.cancel()
        presetPreviewWorkItem = nil
        clearPresetHover()
        gridCanvas.resetState()
        statusLabel.stringValue = Self.idlePromptText
    }

    private func clearPresetHover() {
        for button in presetButtons {
            button.isHovered = false
        }
    }

    func configure(
        frame: CGRect,
        opensBelow: Bool,
        arrowTipLocalX: CGFloat,
        columns: Int,
        rows: Int,
        presets: [WindowAction],
        screenLabels: [String],
        selectedScreenIndex: Int,
        ghostNormalizedRect: CGRect?,
        initialKeyboardSelection: GridSelection?
    ) {
        self.frame = frame
        self.opensBelow = opensBelow
        self.arrowTipLocalX = arrowTipLocalX

        effectView.frame = bounds

        let arrowH = GreenButtonPopoverPlacement.arrowHeight
        let bodyRect = CGRect(
            x: 0,
            y: opensBelow ? 0 : arrowH,
            width: bounds.width,
            height: bounds.height - arrowH
        )
        self.currentBodyRect = bodyRect

        let bubblePath = Self.makePopoverPath(
            bodyRect: bodyRect,
            opensBelow: opensBelow,
            arrowTipX: arrowTipLocalX,
            cornerRadius: 12,
            arrowWidth: GreenButtonPopoverPlacement.arrowWidth,
            arrowHeight: arrowH
        )

        effectView.maskImage = Self.makeMaskImage(size: bounds.size, path: bubblePath)
        layer?.shadowPath = bubblePath.cgPathFallback

        borderLayer.frame = bounds
        borderLayer.path = bubblePath.cgPathFallback
        updateBorderAppearance()

        rebuildPresetButtons(presets)
        rebuildDisplayButtons(screenLabels, selectedIndex: selectedScreenIndex)
        rebuildDensityButtons(activeColumns: columns, activeRows: rows)

        let padX: CGFloat = 12
        let contentWidth = max(60, bodyRect.width - padX * 2)
        let presetBarY = bodyRect.maxY - 10 - 28
        presetsContainer.frame = CGRect(x: padX, y: presetBarY, width: contentWidth, height: 28)
        layoutPresetButtons()

        let dividerY = presetBarY - 6
        dividerView.frame = CGRect(x: padX, y: dividerY, width: contentWidth, height: 1)

        var gridTop = dividerY - 6
        if !screenLabels.isEmpty {
            displayBarContainer.isHidden = false
            let barHeight: CGFloat = 22
            let barY = gridTop - barHeight
            displayBarContainer.frame = CGRect(x: padX, y: barY, width: contentWidth, height: barHeight)
            layoutDisplayButtons()
            gridTop = barY - 6
        } else {
            displayBarContainer.isHidden = true
        }

        layoutFooterSubviews()

        let footerY = bodyRect.minY + 10
        let gridBottom = footerY + 20 + 6
        gridCanvas.frame = CGRect(
            x: padX,
            y: gridBottom,
            width: contentWidth,
            height: max(60, gridTop - gridBottom)
        )
        gridCanvas.configure(
            columns: columns,
            rows: rows,
            ghostNormalizedRect: ghostNormalizedRect,
            initialKeyboardSelection: initialKeyboardSelection
        )
        if let initialKeyboardSelection {
            statusLabel.stringValue = initialKeyboardSelection.summaryLabel(columns: columns, rows: rows)
            onPreviewGrid?(initialKeyboardSelection)
        } else {
            statusLabel.stringValue = Self.idlePromptText
        }
    }

    private func layoutPresetButtons() {
        let count = presetButtons.count
        guard count > 0 else { return }
        let spacing: CGFloat = 4
        let totalWidth = presetsContainer.bounds.width
        let buttonHeight = presetsContainer.bounds.height
        let rawWidth = (totalWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
        let buttonWidth = max(18, floor(rawWidth))
        let usedWidth = buttonWidth * CGFloat(count) + spacing * CGFloat(count - 1)
        let startX = max(0, round((totalWidth - usedWidth) / 2))

        for (index, button) in presetButtons.enumerated() {
            button.frame = CGRect(
                x: startX + CGFloat(index) * (buttonWidth + spacing),
                y: 0,
                width: buttonWidth,
                height: buttonHeight
            )
        }
    }

    private func layoutDisplayButtons() {
        let hintWidth: CGFloat = 18
        let containerWidth = displayBarContainer.bounds.width
        let containerHeight = displayBarContainer.bounds.height
        displayTabHintLabel.frame = CGRect(
            x: containerWidth - hintWidth,
            y: round((containerHeight - 16) / 2),
            width: hintWidth,
            height: 16
        )

        let count = displayButtons.count
        guard count > 0 else { return }
        let spacing: CGFloat = 4
        let pillsAreaWidth = max(60, containerWidth - hintWidth - 4)
        let pillWidth = max(28, floor((pillsAreaWidth - CGFloat(count - 1) * spacing) / CGFloat(count)))
        let pillHeight: CGFloat = 20
        let pillY = round((containerHeight - pillHeight) / 2)

        for (index, pill) in displayButtons.enumerated() {
            pill.frame = CGRect(
                x: CGFloat(index) * (pillWidth + spacing),
                y: pillY,
                width: pillWidth,
                height: pillHeight
            )
        }
    }

    private func layoutFooterSubviews() {
        let padX: CGFloat = 12
        let footerY = currentBodyRect.minY + 10
        let spacing: CGFloat = 3
        let widths = densityButtons.map { $0.button.intrinsicContentSize.width }
        let densityWidth = widths.reduce(0, +) + CGFloat(max(0, densityButtons.count - 1)) * spacing
        let containerHeight: CGFloat = 20

        densityContainer.frame = CGRect(
            x: currentBodyRect.width - padX - densityWidth,
            y: footerY - 1,
            width: densityWidth,
            height: containerHeight
        )

        var xCursor: CGFloat = 0
        for (index, entry) in densityButtons.enumerated() {
            let w = widths[index]
            let h = entry.button.intrinsicContentSize.height
            entry.button.frame = CGRect(
                x: xCursor,
                y: round((containerHeight - h) / 2),
                width: w,
                height: h
            )
            xCursor += w + spacing
        }

        statusLabel.frame = CGRect(
            x: padX,
            y: footerY + 1,
            width: max(54, densityContainer.frame.minX - padX - 6),
            height: 16
        )
    }

    private func rebuildDisplayButtons(_ labels: [String], selectedIndex: Int) {
        for button in displayButtons {
            button.removeFromSuperview()
        }
        displayButtons.removeAll()

        for (idx, title) in labels.enumerated() {
            let pill = GreenButtonSmallPillButton(title: title, fontSize: 10.5, horizontalPadding: 7, height: 20)
            pill.isSelectedPill = (idx == selectedIndex)
            pill.toolTip = "\(title) (⇥)"
            pill.onClick = { [weak self] in
                self?.onSelectScreenIndex?(idx)
            }
            pill.onDoubleClick = { [weak self] in
                self?.onMoveToScreenIndex?(idx)
            }
            displayButtons.append(pill)
            displayBarContainer.addSubview(pill)
        }
    }

    private func rebuildDensityButtons(activeColumns: Int, activeRows: Int) {
        for entry in densityButtons {
            entry.button.removeFromSuperview()
        }
        densityButtons.removeAll()

        var presets = GridSelection.quickDensities
        if !presets.contains(where: { $0.columns == activeColumns && $0.rows == activeRows }) {
            presets.append((activeColumns, activeRows))
        }

        for preset in presets {
            let title = "\(preset.columns)×\(preset.rows)"
            let pill = GreenButtonSmallPillButton(title: title, fontSize: 10, horizontalPadding: 5.5, height: 18)
            pill.isSelectedPill = (preset.columns == activeColumns && preset.rows == activeRows)
            pill.toolTip = String(localized: "Click or scroll on grid to change grid dimensions")
            pill.onClick = { [weak self] in
                self?.onChangeGridDimensions?(preset.columns, preset.rows)
            }
            densityButtons.append((preset.columns, preset.rows, pill))
            densityContainer.addSubview(pill)
        }
    }

    private func rebuildPresetButtons(_ presets: [WindowAction]) {
        for button in presetButtons {
            button.removeFromSuperview()
        }
        presetButtons.removeAll()

        for action in presets {
            let button = GreenButtonPresetButton(action: action)
            button.onHoverChanged = { [weak self, weak button] hovering in
                guard let self else { return }
                self.presetPreviewWorkItem?.cancel()
                self.presetPreviewWorkItem = nil

                if hovering {
                    guard !self.gridCanvas.isActivelySelectingRegion else { return }
                    self.gridCanvas.clearHoverIfIdle()
                    for other in self.presetButtons where other !== button {
                        other.isHovered = false
                    }
                    self.statusLabel.stringValue = action.displayName ?? action.name
                    // Debounce desktop FootprintWindow slightly so crossing the top toolbar
                    // on the way to the grid does not flash a full-screen preview box.
                    let work = DispatchWorkItem { [weak self, weak button] in
                        guard let self, let button, button.isHovered, !self.gridCanvas.isActivelySelectingRegion else { return }
                        self.onPreviewAction?(action)
                    }
                    self.presetPreviewWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
                } else if self.presetButtons.allSatisfy({ !$0.isHovered }) && !self.gridCanvas.isActivelySelectingRegion {
                    self.statusLabel.stringValue = Self.idlePromptText
                    self.onPreviewAction?(nil)
                }
            }
            button.onClick = { [weak self] in
                self?.presetPreviewWorkItem?.cancel()
                self?.presetPreviewWorkItem = nil
                self?.onSelectAction?(action)
            }
            presetButtons.append(button)
            presetsContainer.addSubview(button)
        }
    }

    private func updateBorderAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        borderLayer.strokeColor = (isDark
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor.black.withAlphaComponent(0.14)
        ).cgColor
    }

    private static func makeMaskImage(size: CGSize, path: NSBezierPath) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            NSColor.white.setFill()
            path.fill()
            return true
        }
    }

    private static func makePopoverPath(
        bodyRect: CGRect,
        opensBelow: Bool,
        arrowTipX: CGFloat,
        cornerRadius r: CGFloat,
        arrowWidth: CGFloat,
        arrowHeight: CGFloat
    ) -> NSBezierPath {
        let halfArrow = arrowWidth / 2
        let clampedTipX = min(max(arrowTipX, bodyRect.minX + r + halfArrow + 2), bodyRect.maxX - r - halfArrow - 2)
        let path = NSBezierPath()

        let minX = bodyRect.minX
        let maxX = bodyRect.maxX
        let minY = bodyRect.minY
        let maxY = bodyRect.maxY

        path.move(to: CGPoint(x: minX + r, y: minY))

        if !opensBelow {
            path.line(to: CGPoint(x: clampedTipX - halfArrow, y: minY))
            path.line(to: CGPoint(x: clampedTipX, y: minY - arrowHeight))
            path.line(to: CGPoint(x: clampedTipX + halfArrow, y: minY))
        }

        path.line(to: CGPoint(x: maxX - r, y: minY))
        path.appendArc(withCenter: CGPoint(x: maxX - r, y: minY + r), radius: r, startAngle: 270, endAngle: 360)

        path.line(to: CGPoint(x: maxX, y: maxY - r))
        path.appendArc(withCenter: CGPoint(x: maxX - r, y: maxY - r), radius: r, startAngle: 0, endAngle: 90)

        if opensBelow {
            path.line(to: CGPoint(x: clampedTipX + halfArrow, y: maxY))
            path.line(to: CGPoint(x: clampedTipX, y: maxY + arrowHeight))
            path.line(to: CGPoint(x: clampedTipX - halfArrow, y: maxY))
        }

        path.line(to: CGPoint(x: minX + r, y: maxY))
        path.appendArc(withCenter: CGPoint(x: minX + r, y: maxY - r), radius: r, startAngle: 90, endAngle: 180)

        path.line(to: CGPoint(x: minX, y: minY + r))
        path.appendArc(withCenter: CGPoint(x: minX + r, y: minY + r), radius: r, startAngle: 180, endAngle: 270)

        path.close()
        return path
    }
}

// MARK: - Compact Pill Button (Display & Density Switchers)

private final class GreenButtonSmallPillButton: NSView {
    let title: String
    private let fontSize: CGFloat
    private let horizontalPadding: CGFloat
    private let pillHeight: CGFloat
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    var isSelectedPill: Bool = false {
        didSet {
            if oldValue != isSelectedPill { needsDisplay = true }
        }
    }

    private var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }
    private var isPressed = false {
        didSet {
            if oldValue != isPressed { needsDisplay = true }
        }
    }
    private var trackingAreaRef: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, fontSize: CGFloat, horizontalPadding: CGFloat, height: CGFloat) {
        self.title = title
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.pillHeight = height
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var labelFont: NSFont {
        .monospacedDigitSystemFont(ofSize: fontSize, weight: isSelectedPill ? .semibold : .medium)
    }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: labelFont])
        return NSSize(width: ceil(size.width) + horizontalPadding * 2, height: pillHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        let local = convert(event.locationInWindow, from: nil)
        guard wasPressed && bounds.contains(local) else { return }
        if event.clickCount >= 2, let onDoubleClick {
            onDoubleClick()
        } else {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        if isSelectedPill {
            NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.34 : 0.22).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isPressed || isHovered {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.16 : 0.09).setFill()
            path.fill()
        }

        let textColor: NSColor = isSelectedPill
            ? .controlAccentColor
            : (isHovered ? .labelColor : .secondaryLabelColor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: textColor
        ]
        let textSize = (title as NSString).size(withAttributes: attrs)
        let textOrigin = CGPoint(
            x: round(bounds.midX - textSize.width / 2),
            y: round(bounds.midY - textSize.height / 2)
        )
        (title as NSString).draw(at: textOrigin, withAttributes: attrs)
    }
}

// MARK: - Quick Preset Button

private final class GreenButtonPresetButton: NSView {
    let windowAction: WindowAction
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    var isHovered: Bool = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    private var isPressed = false
    private var trackingAreaRef: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    init(action: WindowAction) {
        self.windowAction = action
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        toolTip = action.displayName
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 26)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        needsDisplay = true
        let local = convert(event.locationInWindow, from: nil)
        if wasPressed && bounds.contains(local) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pillRect = bounds.insetBy(dx: 1, dy: 1)
        if isPressed || isHovered {
            let fill = isPressed
                ? NSColor.controlAccentColor.withAlphaComponent(0.32)
                : NSColor.controlAccentColor.withAlphaComponent(0.18)
            fill.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6).fill()
        }

        let iconColor = isHovered || isPressed ? NSColor.controlAccentColor : NSColor.labelColor
        let templateImage = windowAction.image
        if templateImage.size.width > 0 && templateImage.size.height > 0,
           let tinted = templateImage.copy() as? NSImage {
            let targetSize = NSSize(width: 18, height: 12)
            let iconRect = NSRect(
                x: round((bounds.width - targetSize.width) / 2),
                y: round((bounds.height - targetSize.height) / 2),
                width: targetSize.width,
                height: targetSize.height
            )
            tinted.size = targetSize
            tinted.lockFocus()
            iconColor.set()
            NSRect(origin: .zero, size: targetSize).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: isHovered ? 1.0 : 0.88)
        } else {
            drawFallbackGlyph(in: pillRect.insetBy(dx: 4, dy: 6), color: iconColor)
        }
    }

    private func drawFallbackGlyph(in rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.45).setStroke()
        let outer = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        outer.lineWidth = 1
        outer.stroke()

        let fillRect: NSRect
        switch windowAction {
        case .leftHalf:
            fillRect = NSRect(x: rect.minX + 1.5, y: rect.minY + 1.5, width: rect.width / 2 - 2, height: rect.height - 3)
        case .rightHalf:
            fillRect = NSRect(x: rect.midX + 0.5, y: rect.minY + 1.5, width: rect.width / 2 - 2, height: rect.height - 3)
        case .topHalf:
            fillRect = NSRect(x: rect.minX + 1.5, y: rect.midY + 0.5, width: rect.width - 3, height: rect.height / 2 - 2)
        case .bottomHalf:
            fillRect = NSRect(x: rect.minX + 1.5, y: rect.minY + 1.5, width: rect.width - 3, height: rect.height / 2 - 2)
        case .center, .almostMaximize, .restore:
            fillRect = rect.insetBy(dx: 3.5, dy: 2.5)
        default:
            fillRect = rect.insetBy(dx: 1.5, dy: 1.5)
        }
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.2, yRadius: 1.2).fill()
    }
}

// MARK: - Interactive Multi-Cell Drag, Click-Anchor & Keyboard Grid Canvas

private final class GreenButtonGridCanvasView: NSView {
    /// `(selection, isActiveRegionSelection)`
    var onSelectionStateChanged: ((GridSelection?, Bool) -> Void)?
    var onCommitSelection: ((GridSelection) -> Void)?
    var onStepDensity: ((Int) -> Void)?

    private(set) var columns: Int = 6
    private(set) var rows: Int = 4
    private(set) var activeSelection: GridSelection?
    private(set) var isDraggingSelection: Bool = false
    var ghostNormalizedRect: CGRect? {
        didSet { needsDisplay = true }
    }

    private var pressAnchor: GridCell?
    private var pressDownPoint: CGPoint = .zero
    private var pressDownTime: TimeInterval = 0
    private var didDragRegion: Bool = false
    private var lockedAnchor: GridCell?
    private var isKeyboardSelectionActive: Bool = false
    private var accumulatedScrollY: CGFloat = 0
    private var trackingAreaRef: NSTrackingArea?

    var isActivelySelectingRegion: Bool {
        isDraggingSelection || lockedAnchor != nil || isKeyboardSelectionActive
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(
        columns: Int,
        rows: Int,
        ghostNormalizedRect: CGRect?,
        initialKeyboardSelection: GridSelection?
    ) {
        let dims = GridSelection.clampDimensions(columns: columns, rows: rows)
        self.columns = dims.columns
        self.rows = dims.rows
        self.ghostNormalizedRect = ghostNormalizedRect
        resetState()
        if let initialKeyboardSelection {
            self.activeSelection = initialKeyboardSelection.clamped(columns: dims.columns, rows: dims.rows)
            self.isKeyboardSelectionActive = true
            needsDisplay = true
        }
    }

    func updateDimensionsPreservingRatio(columns newCols: Int, rows newRows: Int) {
        let oldCols = max(1, self.columns)
        let oldRows = max(1, self.rows)
        let dims = GridSelection.clampDimensions(columns: newCols, rows: newRows)
        self.columns = dims.columns
        self.rows = dims.rows

        if let prev = activeSelection, isActivelySelectingRegion {
            let minCol = min(dims.columns - 1, max(0, Int(round(Double(prev.minColumn) * Double(dims.columns) / Double(oldCols)))))
            let maxCol = min(dims.columns - 1, max(minCol, Int(round(Double(prev.maxColumn + 1) * Double(dims.columns) / Double(oldCols))) - 1))
            let minRow = min(dims.rows - 1, max(0, Int(round(Double(prev.minRow) * Double(dims.rows) / Double(oldRows)))))
            let maxRow = min(dims.rows - 1, max(minRow, Int(round(Double(prev.maxRow + 1) * Double(dims.rows) / Double(oldRows))) - 1))
            let remapped = GridSelection(
                start: GridCell(column: minCol, row: minRow),
                end: GridCell(column: maxCol, row: maxRow)
            )
            activeSelection = remapped
            if lockedAnchor != nil {
                lockedAnchor = remapped.start
            }
            onSelectionStateChanged?(remapped, true)
        } else {
            activeSelection = nil
            onSelectionStateChanged?(nil, false)
        }
        needsDisplay = true
    }

    func resetState() {
        pressAnchor = nil
        lockedAnchor = nil
        didDragRegion = false
        isKeyboardSelectionActive = false
        accumulatedScrollY = 0
        activeSelection = nil
        isDraggingSelection = false
        needsDisplay = true
    }

    @discardableResult
    func cancelActiveSelection() -> Bool {
        guard isActivelySelectingRegion else { return false }
        resetState()
        onSelectionStateChanged?(nil, false)
        return true
    }

    func clearHoverIfIdle() {
        guard !isActivelySelectingRegion, activeSelection != nil else { return }
        activeSelection = nil
        needsDisplay = true
    }

    func moveSelectionByKeyboard(dCol: Int, dRow: Int, resizeEndOnly: Bool) {
        let base = activeSelection ?? GridSelection(
            start: GridCell(column: 0, row: 0),
            end: GridCell(column: max(0, columns / 2 - 1), row: rows - 1)
        )
        let updated = base.movedBy(
            dCol: dCol,
            dRow: dRow,
            resizeEndOnly: resizeEndOnly,
            columns: columns,
            rows: rows
        )
        lockedAnchor = nil
        isKeyboardSelectionActive = true
        activeSelection = updated
        needsDisplay = true
        onSelectionStateChanged?(updated, true)
    }

    func commitCurrentSelectionOrDefault() {
        let committed = activeSelection ?? GridSelection(
            start: GridCell(column: 0, row: 0),
            end: GridCell(column: columns - 1, row: rows - 1)
        )
        resetState()
        onCommitSelection?(committed)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        accumulatedScrollY += dy
        let threshold: CGFloat = 20
        if accumulatedScrollY <= -threshold {
            accumulatedScrollY = 0
            onStepDensity?(1)
        } else if accumulatedScrollY >= threshold {
            accumulatedScrollY = 0
            onStepDensity?(-1)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updatePointerHover(at: point)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isDraggingSelection else { return }
        let point = convert(event.locationInWindow, from: nil)
        updatePointerHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDraggingSelection, lockedAnchor == nil, !isKeyboardSelectionActive else { return }
        if activeSelection != nil {
            activeSelection = nil
            needsDisplay = true
            onSelectionStateChanged?(nil, false)
        }
    }

    private func updatePointerHover(at localPoint: CGPoint) {
        if let anchor = lockedAnchor {
            if let cell = GridSelection.cell(
                at: localPoint,
                in: bounds,
                columns: columns,
                rows: rows,
                clampOutside: true,
                dragSlop: 48
            ) {
                let next = GridSelection(start: anchor, end: cell)
                if activeSelection != next {
                    activeSelection = next
                    needsDisplay = true
                    onSelectionStateChanged?(next, true)
                }
            }
            return
        }

        guard !isKeyboardSelectionActive else { return }

        guard let cell = GridSelection.cell(
            at: localPoint,
            in: bounds,
            columns: columns,
            rows: rows,
            clampOutside: false
        ) else {
            if activeSelection != nil {
                activeSelection = nil
                needsDisplay = true
                onSelectionStateChanged?(nil, false)
            }
            return
        }

        let next = GridSelection(start: cell, end: cell)
        if activeSelection != next {
            activeSelection = next
            needsDisplay = true
            onSelectionStateChanged?(next, false)
        }
    }

    // MARK: - Press & Drag + Two-Click Region Selection

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        isKeyboardSelectionActive = false

        // Second click in two-click anchor mode commits the expanded region immediately!
        if let existingAnchor = lockedAnchor {
            if let endCell = GridSelection.cell(
                at: localPoint,
                in: bounds,
                columns: columns,
                rows: rows,
                clampOutside: true,
                dragSlop: 24
            ) {
                let committed = GridSelection(start: existingAnchor, end: endCell)
                resetState()
                onCommitSelection?(committed)
            } else {
                _ = cancelActiveSelection()
            }
            return
        }

        guard let anchor = GridSelection.cell(
            at: localPoint,
            in: bounds,
            columns: columns,
            rows: rows,
            clampOutside: false
        ) else {
            return
        }

        pressAnchor = anchor
        pressDownPoint = localPoint
        pressDownTime = CACurrentMediaTime()
        didDragRegion = false
        isDraggingSelection = true

        let initial = GridSelection(start: anchor, end: anchor)
        activeSelection = initial
        needsDisplay = true
        onSelectionStateChanged?(initial, true)
    }

    override func mouseDragged(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        updateActiveDrag(atLocalPoint: localPoint)
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        completeActiveDrag(atLocalPoint: localPoint)
    }

    func handleGlobalMouseDragged(atScreenPoint screenPoint: CGPoint) {
        guard isDraggingSelection, let window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        updateActiveDrag(atLocalPoint: localPoint)
    }

    func handleGlobalMouseUp(atScreenPoint screenPoint: CGPoint) {
        guard isDraggingSelection, let window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        completeActiveDrag(atLocalPoint: localPoint)
    }

    private func updateActiveDrag(atLocalPoint localPoint: CGPoint) {
        guard isDraggingSelection, let anchor = pressAnchor else { return }

        let distance = hypot(localPoint.x - pressDownPoint.x, localPoint.y - pressDownPoint.y)
        if distance >= 5 {
            didDragRegion = true
        }

        if let currentCell = GridSelection.cell(
            at: localPoint,
            in: bounds,
            columns: columns,
            rows: rows,
            clampOutside: true,
            dragSlop: 64
        ) {
            if currentCell != anchor {
                didDragRegion = true
            }
            let updated = GridSelection(start: anchor, end: currentCell)
            if activeSelection != updated {
                activeSelection = updated
                needsDisplay = true
                onSelectionStateChanged?(updated, true)
            }
        } else if activeSelection != nil {
            activeSelection = nil
            needsDisplay = true
            onSelectionStateChanged?(nil, true)
        }
    }

    private func completeActiveDrag(atLocalPoint localPoint: CGPoint) {
        guard isDraggingSelection, let anchor = pressAnchor else { return }
        updateActiveDrag(atLocalPoint: localPoint)

        let finalSelection = activeSelection
        let holdDuration = CACurrentMediaTime() - pressDownTime
        isDraggingSelection = false
        pressAnchor = nil

        guard let finalSelection else {
            didDragRegion = false
            needsDisplay = true
            onSelectionStateChanged?(nil, false)
            return
        }

        if didDragRegion || finalSelection.columnSpan > 1 || finalSelection.rowSpan > 1 || holdDuration >= 0.22 {
            didDragRegion = false
            lockedAnchor = nil
            onCommitSelection?(finalSelection)
        } else {
            didDragRegion = false
            lockedAnchor = anchor
            activeSelection = GridSelection(start: anchor, end: anchor)
            needsDisplay = true
            onSelectionStateChanged?(activeSelection, true)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard columns > 0, rows > 0, bounds.width > 0, bounds.height > 0 else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let gap: CGFloat = (columns > 8 || rows > 6) ? 3.0 : 4.0
        let cornerRadius: CGFloat = (columns > 8 || rows > 6) ? 3.5 : 5.0

        let cellWidth = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        guard cellWidth > 1, cellHeight > 1 else { return }

        let activelySelecting = isActivelySelectingRegion
        let idleFill = NSColor.labelColor.withAlphaComponent(isDark ? 0.08 : 0.045)
        let idleStroke = NSColor.labelColor.withAlphaComponent(isDark ? 0.18 : 0.14)
        let selectedFill = NSColor.controlAccentColor.withAlphaComponent(activelySelecting ? 0.30 : 0.14)
        let selectedCellStroke = NSColor.controlAccentColor.withAlphaComponent(activelySelecting ? 0.60 : 0.42)

        func rectForCell(col: Int, row: Int) -> NSRect {
            NSRect(
                x: bounds.minX + CGFloat(col) * (cellWidth + gap),
                y: bounds.minY + CGFloat(row) * (cellHeight + gap),
                width: cellWidth,
                height: cellHeight
            )
        }

        for row in 0..<rows {
            for col in 0..<columns {
                let cellRect = rectForCell(col: col, row: row)
                let isSelected = activeSelection?.contains(column: col, row: row) == true
                let path = NSBezierPath(roundedRect: cellRect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)

                (isSelected ? selectedFill : idleFill).setFill()
                path.fill()

                (isSelected ? selectedCellStroke : idleStroke).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        // Subtle dashed ghost outline showing the target window's current position on this screen
        if let ghost = ghostNormalizedRect {
            let ghostRect = NSRect(
                x: bounds.minX + ghost.minX * bounds.width,
                y: bounds.minY + ghost.minY * bounds.height,
                width: max(8, ghost.width * bounds.width),
                height: max(8, ghost.height * bounds.height)
            ).insetBy(dx: 1.25, dy: 1.25)
            let ghostPath = NSBezierPath(roundedRect: ghostRect, xRadius: cornerRadius, yRadius: cornerRadius)
            let dashPattern: [CGFloat] = [4.0, 3.0]
            ghostPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            ghostPath.lineWidth = 1.25
            NSColor.labelColor.withAlphaComponent(isDark ? 0.34 : 0.28).setStroke()
            ghostPath.stroke()
        }

        if let selection = activeSelection {
            let topLeft = rectForCell(col: selection.minColumn, row: selection.minRow)
            let bottomRight = rectForCell(col: selection.maxColumn, row: selection.maxRow)
            let unionRect = topLeft.union(bottomRight).insetBy(dx: 0.75, dy: 0.75)
            let outerPath = NSBezierPath(roundedRect: unionRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.controlAccentColor.withAlphaComponent(activelySelecting ? 1.0 : 0.65).setStroke()
            outerPath.lineWidth = activelySelecting ? 2.0 : 1.25
            outerPath.stroke()

            if activelySelecting {
                let badgeText = "\(selection.columnSpan) × \(selection.rowSpan)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
                let textSize = (badgeText as NSString).size(withAttributes: attrs)
                let pillSize = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)
                if unionRect.width >= pillSize.width + 4 && unionRect.height >= pillSize.height + 4 {
                    let pillRect = CGRect(
                        x: round(unionRect.midX - pillSize.width / 2),
                        y: round(unionRect.midY - pillSize.height / 2),
                        width: pillSize.width,
                        height: pillSize.height
                    )
                    NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: pillSize.height / 2, yRadius: pillSize.height / 2).fill()
                    let textOrigin = CGPoint(
                        x: round(pillRect.midX - textSize.width / 2),
                        y: round(pillRect.midY - textSize.height / 2)
                    )
                    (badgeText as NSString).draw(at: textOrigin, withAttributes: attrs)
                }
            }
        }
    }
}

// MARK: - NSBezierPath CGPath Compatibility

private extension NSBezierPath {
    var cgPathFallback: CGPath {
        if #available(macOS 14.0, *) {
            return cgPath
        }
        let mutable = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            let type = element(at: index, associatedPoints: &points)
            switch type {
            case .moveTo:
                mutable.move(to: points[0])
            case .lineTo:
                mutable.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                mutable.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                mutable.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                mutable.closeSubpath()
            @unknown default:
                break
            }
        }
        return mutable
    }
}
