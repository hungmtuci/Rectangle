/// GreenButtonManager.swift

import Carbon.HIToolbox
import Cocoa
import MASShortcut

class GreenButtonManager {
    private struct ActiveTarget {
        let windowElement: AccessibilityElement
        let windowId: CGWindowID?
        let windowQuartzFrame: CGRect
        let buttonQuartzFrame: CGRect?
        let screens: [NSScreen]
        let sourceScreenIndex: Int
        var selectedScreenIndex: Int

        var sourceScreen: NSScreen {
            screens[min(max(sourceScreenIndex, 0), max(0, screens.count - 1))]
        }

        var selectedScreen: NSScreen {
            screens[min(max(selectedScreenIndex, 0), max(0, screens.count - 1))]
        }
    }

    private struct TapSnapshot {
        var isPanelVisible: Bool = false
        var placement: GreenButtonPopoverPlacement?
        var interceptsGreenButtonClick: Bool = true
        var targetWindowElement: AccessibilityElement?
        var screenCount: Int = 1
        var primaryScreenMaxY: CGFloat = 0
        var ignoredBundleIds: Set<String> = []
    }

    static let toggleGridDefaultsKey = "toggleGreenButtonGrid"
    static let defaultsKeys = [toggleGridDefaultsKey]

    private static weak var sharedInstance: GreenButtonManager?
    private static var shortcutBindingsSessionActive = true
    private static var shortcutBindingsSuspended = false

    /// Ultra-short dwell (`25ms`) filters out high-speed cursor sweeps across the title bar
    /// while making intentional hover feel instantaneous and beating macOS's native hover menu.
    private static let hoverDwellDelay: TimeInterval = 0.025
    private static let hoverDismissGrace: TimeInterval = 0.11
    private static let hoverQueryInterval: TimeInterval = 0.016
    private static let maxImmediateSweepSpeed: CGFloat = 1200
    private static let negativeHitRadiusSquared: CGFloat = 9.0
    private static let negativeHitTTL: TimeInterval = 0.18

    private(set) static var isPopoverActive = false

    private var clickMonitor: ActiveEventMonitor!
    private var keyMonitor: ActiveEventMonitor!
    private var hoverMonitor: PassiveEventMonitor!
    private var interactionMonitor: PassiveEventMonitor!

    private let stateLock = NSLock()
    private var tapSnapshot = TapSnapshot()
    private var clickWindowElement: AccessibilityElement?
    private var clickButtonFrame: CGRect?

    private let axQueue = DispatchQueue(label: "com.knollsoft.Rectangle.greenButtonHoverAX", qos: .userInteractive)
    private let screenDetection = ScreenDetection()

    private lazy var gridPanel: GreenButtonGridPanel = makeGridPanel()
    private lazy var footprintWindow = FootprintWindow()
    private var isPreviewVisible = false
    private var isPostingSyntheticOcclusionMove = false

    private var activeTarget: ActiveTarget?
    private var pendingTarget: ActiveTarget?
    private var presentWorkItem: DispatchWorkItem?
    private var dismissWorkItem: DispatchWorkItem?
    private var isTrailingHoverScheduled = false
    private var trailingHoverGeneration: UInt64 = 0
    private var lastHoverSampleTime: TimeInterval = 0
    private var lastCursorPoint: CGPoint?
    private var lastCursorEventTime: TimeInterval = 0
    private var lastNegativeHitPoint: CGPoint?
    private var lastNegativeHitTime: TimeInterval = 0
    private var hoverQueryInFlight = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    init() {
        Self.sharedInstance = self
        AXUIElementSetMessagingTimeout(AXUIElement.systemWide, 0.04)

        clickMonitor = ActiveEventMonitor(
            mask: [.leftMouseDown, .leftMouseUp],
            filterer: { [weak self] event in self?.filterClick(event) ?? false }
        )

        keyMonitor = ActiveEventMonitor(
            mask: [.keyDown],
            filterer: { [weak self] event in self?.filterPanelKeyDown(event) ?? false }
        )

        hoverMonitor = PassiveEventMonitor(mask: [.mouseMoved]) { [weak self] _ in
            self?.handleMouseMoved()
        }

        interactionMonitor = PassiveEventMonitor(
            mask: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown, .flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handleInteractionEvent(event)
        }

        refreshTapSnapshot()
        toggleListening()
        setupObservers()
        Self.registerUnregisterToggleShortcut()

        // Pre-warm panel & preview layers on the next runloop turn so the very first hover
        // has zero view/layer allocation latency.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.gridPanel
            _ = self.footprintWindow
        }
    }

    deinit {
        Self.isPopoverActive = false
        Self.unregisterToggleShortcut()
        clickMonitor?.stop()
        keyMonitor?.stop()
        hoverMonitor?.stop()
        interactionMonitor?.stop()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        for obs in appObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Global Toggle Shortcut Binding

    static func reevaluateToggleShortcut() {
        unregisterToggleShortcut()
        registerUnregisterToggleShortcut()
    }

    private static func registerToggleShortcut() {
        guard isToggleShortcutBindable() else {
            unregisterToggleShortcut()
            return
        }
        MASShortcutBinder.shared()?.bindShortcut(withDefaultsKey: toggleGridDefaultsKey, toAction: {
            DispatchQueue.main.async {
                Self.sharedInstance?.toggleGridAtCursor()
            }
        })
    }

    private static func unregisterToggleShortcut() {
        MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: toggleGridDefaultsKey)
    }

    private static func registerUnregisterToggleShortcut() {
        if shortcutBindingsSessionActive && !shortcutBindingsSuspended {
            registerToggleShortcut()
        } else {
            unregisterToggleShortcut()
        }
    }

    static func setShortcutBindingsSessionActive(_ isActive: Bool) {
        guard shortcutBindingsSessionActive != isActive else { return }
        shortcutBindingsSessionActive = isActive
        unregisterToggleShortcut()
        if isActive {
            registerUnregisterToggleShortcut()
        }
    }

    static func setShortcutBindingsSuspended(_ suspended: Bool) {
        guard shortcutBindingsSuspended != suspended else { return }
        shortcutBindingsSuspended = suspended
        registerUnregisterToggleShortcut()
    }

    private static func isToggleShortcutBindable() -> Bool {
        guard let shortcut = ShortcutCycle.shortcut(forDefaultsKey: toggleGridDefaultsKey) else { return true }
        return AppShortcutConflict.conflict(for: shortcut, ignoringDefaultsKey: toggleGridDefaultsKey) == nil
    }

    private func makeGridPanel() -> GreenButtonGridPanel {
        let panel = GreenButtonGridPanel()
        panel.onPreviewAction = { [weak self] action in
            self?.handlePreviewAction(action)
        }
        panel.onSelectAction = { [weak self] action in
            self?.handleSelectAction(action)
        }
        panel.onPreviewGrid = { [weak self] selection in
            self?.handlePreviewGrid(selection)
        }
        panel.onSelectGrid = { [weak self] selection in
            self?.handleSelectGrid(selection)
        }
        panel.onClickGreenButton = { [weak self] in
            guard let self, let target = self.activeTarget else { return }
            self.dismissPanel()
            Self.executeMaximizeOrRestore(target.windowElement)
        }
        panel.onSelectScreenIndex = { [weak self] newIndex in
            guard let self else { return }
            self.activeTarget?.selectedScreenIndex = newIndex
        }
        panel.onMoveToScreenIndex = { [weak self] targetIndex in
            self?.handleMoveToScreen(at: targetIndex)
        }
        panel.onChangeGridDimensions = { newCols, newRows in
            Defaults.greenButtonGridColumns.value = newCols
            Defaults.greenButtonGridRows.value = newRows
            Notification.Name.greenButtonHoverGridChanged.post()
        }
        panel.onRequestDismiss = { [weak self] in
            self?.dismissPanel()
        }
        return panel
    }

    private func setupObservers() {
        appObservers.append(Notification.Name.greenButtonOverride.onPost { [weak self] _ in
            self?.toggleListening()
        })
        appObservers.append(Notification.Name.greenButtonHoverGridChanged.onPost { [weak self] _ in
            self?.toggleListening()
        })
        appObservers.append(Notification.Name.configImported.onPost { [weak self] _ in
            Self.reevaluateToggleShortcut()
            self?.refreshTapSnapshot()
            self?.toggleListening()
        })
        appObservers.append(Notification.Name.frontAppChanged.onPost { [weak self] _ in
            self?.invalidateNegativeHitCache()
            self?.refreshTapSnapshot()
        })
        appObservers.append(Notification.Name.windowActionWillExecute.onPost { [weak self] _ in
            self?.invalidateNegativeHitCache()
            self?.dismissPanel()
        })
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateNegativeHitCache()
            self?.refreshTapSnapshot()
            self?.dismissPanel()
        })

        let wsCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.invalidateNegativeHitCache()
            self.refreshTapSnapshot()
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return
            }
            if !self.gridPanel.isSelectingGrid {
                self.dismissPanel()
            }
        })
        workspaceObservers.append(wsCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateNegativeHitCache()
            self?.dismissPanel()
        })
    }

    private var isClickEnabled: Bool {
        Defaults.isGreenButtonClickMaximizeEnabled
    }

    private var isHoverGridEnabled: Bool {
        !Defaults.greenButtonHoverGrid.userDisabled
    }

    private func toggleListening() {
        refreshTapSnapshot()

        if isClickEnabled {
            if !clickMonitor.running {
                clickMonitor.start()
            }
        } else {
            clickMonitor.stop()
        }

        if isHoverGridEnabled {
            if !hoverMonitor.running {
                hoverMonitor.start()
            }
            if !interactionMonitor.running {
                interactionMonitor.start()
            }
        } else {
            hoverMonitor.stop()
            if activeTarget == nil || !gridPanel.isOpenedViaKeyboard {
                interactionMonitor.stop()
                dismissPanel()
            }
        }
    }

    private func refreshTapSnapshot() {
        var ignored = Defaults.disabledApps.typedValue ?? []
        if let fullIgnored = Defaults.fullIgnoreBundleIds.typedValue {
            ignored.formUnion(fullIgnored)
        }
        if let ownBundleId = Bundle.main.bundleIdentifier {
            ignored.insert(ownBundleId)
        }
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        let panelVisible = activeTarget != nil && gridPanel.isVisible
        let placement = panelVisible ? gridPanel.currentPlacement : nil
        let intercepts = isClickEnabled && (placement?.hasButtonBridge == true)
        let targetElement = panelVisible ? activeTarget?.windowElement : nil
        let screenCount = panelVisible ? max(1, activeTarget?.screens.count ?? 1) : 1
        Self.isPopoverActive = panelVisible || pendingTarget != nil

        stateLock.lock()
        tapSnapshot = TapSnapshot(
            isPanelVisible: panelVisible,
            placement: placement,
            interceptsGreenButtonClick: intercepts,
            targetWindowElement: targetElement,
            screenCount: screenCount,
            primaryScreenMaxY: maxY,
            ignoredBundleIds: ignored
        )
        stateLock.unlock()
    }

    // MARK: - Keyboard-Triggered Grid Popover at Cursor

    func toggleGridAtCursor() {
        if activeTarget != nil && gridPanel.isVisible {
            dismissPanel()
            return
        }

        stateLock.lock()
        let ignoredBundleIds = tapSnapshot.ignoredBundleIds
        stateLock.unlock()

        let cursorAppKit = NSEvent.mouseLocation
        let windowCandidate: AccessibilityElement? = {
            if let front = AccessibilityElement.getFrontWindowElement(),
               let bundleId = front.bundleIdentifier,
               !ignoredBundleIds.contains(bundleId),
               front.isEligibleStandardWindow() {
                return front
            }
            if let underCursor = AccessibilityElement.getWindowElementUnderCursor(),
               let bundleId = underCursor.bundleIdentifier,
               !ignoredBundleIds.contains(bundleId),
               underCursor.isEligibleStandardWindow() {
                return underCursor
            }
            return AccessibilityElement.getFrontWindowElement()
        }()

        guard let windowElement = windowCandidate else {
            NSSound.beep()
            return
        }
        windowElement.setMessagingTimeout(0.05)
        let windowFrame = windowElement.frame
        guard !windowFrame.isNull, windowElement.isResizable() else {
            NSSound.beep()
            return
        }

        let allScreens = orderedScreens()
        guard !allScreens.isEmpty else { return }

        let windowScreen = screenDetection.detectScreens(using: windowElement)?.currentScreen
            ?? screenContaining(appKitRect: windowFrame.screenFlipped)
            ?? allScreens[0]
        let cursorScreen = allScreens.first(where: { $0.frame.contains(cursorAppKit) }) ?? windowScreen
        let sourceIndex = allScreens.firstIndex(of: windowScreen) ?? 0
        let initialSelectedIndex = allScreens.firstIndex(of: cursorScreen) ?? sourceIndex

        let target = ActiveTarget(
            windowElement: windowElement,
            windowId: windowElement.getWindowId(),
            windowQuartzFrame: windowFrame,
            buttonQuartzFrame: nil,
            screens: allScreens,
            sourceScreenIndex: sourceIndex,
            selectedScreenIndex: initialSelectedIndex
        )

        if !interactionMonitor.running {
            interactionMonitor.start()
        }
        presentPanel(for: target, anchor: .cursor(cursorAppKitPoint: cursorAppKit), preselectKeyboardRegion: true)
    }

    // MARK: - Event Tap Click Handling

    private func filterClick(_ event: NSEvent) -> Bool {
        stateLock.lock()
        let snapshot = tapSnapshot
        stateLock.unlock()

        switch event.type {
        case .leftMouseDown:
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                let location = event.cgEvent?.location
            else {
                return false
            }

            if snapshot.isPanelVisible, let placement = snapshot.placement, snapshot.primaryScreenMaxY > 0 {
                let appKitPoint = CGPoint(x: location.x, y: snapshot.primaryScreenMaxY - location.y)
                if snapshot.interceptsGreenButtonClick,
                   placement.hasButtonBridge,
                   placement.screenButtonBridgeRect.contains(appKitPoint),
                   let targetWindow = snapshot.targetWindowElement {
                    let bridgeQuartzRect = placement.screenButtonBridgeRect.screenFlipped(primaryScreenMaxY: snapshot.primaryScreenMaxY)
                    stateLock.lock()
                    self.clickWindowElement = targetWindow
                    self.clickButtonFrame = bridgeQuartzRect
                    stateLock.unlock()

                    DispatchQueue.main.async { [weak self] in
                        self?.cancelPendingPresentation()
                        self?.dismissPanel()
                    }
                    return true
                }
                if placement.screenCardRect.insetBy(dx: -4, dy: -4).contains(appKitPoint) {
                    return false
                }
            }

            guard
                let element = AccessibilityElement(location),
                let windowElement = element.greenStoplightParentWindow(),
                case let buttonFrame = element.frame,
                buttonFrame != .null
            else {
                return false
            }

            if let bundleId = windowElement.bundleIdentifier ?? element.bundleIdentifier,
               snapshot.ignoredBundleIds.contains(bundleId) {
                return false
            }

            stateLock.lock()
            self.clickWindowElement = windowElement
            self.clickButtonFrame = buttonFrame
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingPresentation()
                self?.dismissPanel()
            }
            return true

        case .leftMouseUp:
            stateLock.lock()
            let windowElement = self.clickWindowElement
            let buttonFrame = self.clickButtonFrame
            self.clickWindowElement = nil
            self.clickButtonFrame = nil
            stateLock.unlock()

            guard let windowElement, let buttonFrame else {
                return false
            }

            if let location = event.cgEvent?.location, buttonFrame.insetBy(dx: -4, dy: -4).contains(location) {
                DispatchQueue.main.async {
                    Self.executeMaximizeOrRestore(windowElement)
                }
            }
            return true

        default:
            return false
        }
    }

    private func filterPanelKeyDown(_ event: NSEvent) -> Bool {
        stateLock.lock()
        let snapshot = tapSnapshot
        stateLock.unlock()

        guard snapshot.isPanelVisible else { return false }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags.intersection([.command, .option, .control]).isEmpty else {
            return false
        }

        let keyCode = Int(event.keyCode)
        let shouldConsume: Bool
        switch keyCode {
        case kVK_Escape:
            shouldConsume = true
        case kVK_Tab:
            shouldConsume = snapshot.screenCount > 1
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            shouldConsume = true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            shouldConsume = true
        case kVK_Space, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4:
            shouldConsume = flags.isEmpty
        default:
            shouldConsume = false
        }

        guard shouldConsume else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeTarget != nil, self.gridPanel.isVisible else { return }
            _ = self.gridPanel.handleKeyCommand(keyCode: keyCode, modifiers: flags)
        }
        return true
    }

    // MARK: - Hover Detection, Drag Forwarding & Popover Lifecycle

    private func handleInteractionEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            if activeTarget != nil, gridPanel.isDraggingGrid {
                cancelScheduledDismiss()
                gridPanel.handleGlobalMouseDragged(atScreenPoint: NSEvent.mouseLocation)
            }

        case .leftMouseUp:
            if activeTarget != nil, gridPanel.isDraggingGrid {
                gridPanel.handleGlobalMouseUp(atScreenPoint: NSEvent.mouseLocation)
            }

        case .flagsChanged:
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Allow Shift inside the popover (used for Shift+Arrow resizing and Shift+Tab display switching).
            let nonShiftModifiers = modifiers.subtracting([.shift, .capsLock, .numericPad, .function])
            if !nonShiftModifiers.isEmpty {
                cancelPendingPresentation()
                if activeTarget != nil && !gridPanel.isSelectingGrid && !gridPanel.isOpenedViaKeyboard {
                    dismissPanel()
                }
            }

        case .keyDown:
            if event.keyCode == 53 { // Escape
                cancelPendingPresentation()
                if activeTarget != nil {
                    if !gridPanel.cancelActiveGridSelection() {
                        dismissPanel()
                    }
                }
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            invalidateNegativeHitCache()
            cancelPendingPresentation()
            guard activeTarget != nil, let placement = gridPanel.currentPlacement else { return }
            let mousePoint = NSEvent.mouseLocation
            let insideCard = placement.screenCardRect.insetBy(dx: -4, dy: -4).contains(mousePoint)
            let insideBridge = gridPanel.interceptsGreenButtonClick
                && placement.hasButtonBridge
                && placement.screenButtonBridgeRect.contains(mousePoint)
            if !insideCard && !insideBridge {
                dismissPanel()
            }

        default:
            break
        }
    }

    private func invalidateNegativeHitCache() {
        lastNegativeHitPoint = nil
        lastNegativeHitTime = 0
    }

    private func cancelTrailingHoverSample() {
        if isTrailingHoverScheduled {
            isTrailingHoverScheduled = false
            trailingHoverGeneration &+= 1
        }
    }

    private func scheduleTrailingHoverSample(delay: TimeInterval) {
        guard !isTrailingHoverScheduled else { return }
        isTrailingHoverScheduled = true
        trailingHoverGeneration &+= 1
        let expectedGen = trailingHoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isTrailingHoverScheduled, self.trailingHoverGeneration == expectedGen else { return }
            self.isTrailingHoverScheduled = false
            self.sampleCursorForGreenButton()
        }
    }

    private func handleMouseMoved() {
        guard isHoverGridEnabled, !isPostingSyntheticOcclusionMove else { return }

        if NSEvent.pressedMouseButtons != 0 {
            cancelTrailingHoverSample()
            if activeTarget != nil, gridPanel.isDraggingGrid {
                cancelScheduledDismiss()
                gridPanel.handleGlobalMouseDragged(atScreenPoint: NSEvent.mouseLocation)
            } else {
                cancelPendingPresentation()
            }
            return
        }

        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let nonShiftModifiers = modifiers.subtracting([.shift, .capsLock, .numericPad, .function])
        if !nonShiftModifiers.isEmpty {
            cancelTrailingHoverSample()
            cancelPendingPresentation()
            if activeTarget != nil && !gridPanel.isSelectingGrid && !gridPanel.isOpenedViaKeyboard {
                dismissPanel()
            }
            return
        }

        let mouseAppKit = NSEvent.mouseLocation

        if activeTarget != nil, gridPanel.isVisible, let placement = gridPanel.currentPlacement {
            cancelTrailingHoverSample()
            if gridPanel.isOpenedViaKeyboard || gridPanel.isSelectingGrid || placement.containsHoverPoint(mouseAppKit) {
                cancelScheduledDismiss()
                return
            } else {
                scheduleDismissIfNeeded()
                return
            }
        }

        let now = CACurrentMediaTime()
        var cursorSpeed: CGFloat = 0
        if let prevPoint = lastCursorPoint {
            let dt = now - lastCursorEventTime
            if dt > 0.0005 && dt < 0.25 {
                cursorSpeed = hypot(mouseAppKit.x - prevPoint.x, mouseAppKit.y - prevPoint.y) / CGFloat(dt)
            }
        }
        lastCursorPoint = mouseAppKit
        lastCursorEventTime = now

        // Skip intermediate AX hit-tests while sweeping fast across the screen;
        // a single coalesced trailing check runs automatically as soon as the sweep slows/stops.
        if cursorSpeed > Self.maxImmediateSweepSpeed {
            cancelPendingPresentation()
            scheduleTrailingHoverSample(delay: 0.022)
            return
        }

        let elapsed = now - lastHoverSampleTime
        if elapsed < Self.hoverQueryInterval {
            scheduleTrailingHoverSample(delay: Self.hoverQueryInterval - elapsed + 0.002)
            return
        }

        cancelTrailingHoverSample()
        sampleCursorForGreenButton()
    }

    private func sampleCursorForGreenButton() {
        let now = CACurrentMediaTime()
        lastHoverSampleTime = now
        guard isHoverGridEnabled, NSEvent.pressedMouseButtons == 0 else {
            cancelPendingPresentation()
            return
        }
        guard NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            cancelPendingPresentation()
            return
        }

        let mouseQuartz = NSEvent.mouseLocation.screenFlipped

        if let pending = pendingTarget, let pendingButton = pending.buttonQuartzFrame {
            if pendingButton.insetBy(dx: -4, dy: -4).contains(mouseQuartz) {
                return
            } else {
                cancelPendingPresentation()
            }
        } else if let negPoint = lastNegativeHitPoint, (now - lastNegativeHitTime) < Self.negativeHitTTL {
            let dx = mouseQuartz.x - negPoint.x
            let dy = mouseQuartz.y - negPoint.y
            if (dx * dx + dy * dy) <= Self.negativeHitRadiusSquared {
                return
            }
        }

        guard !hoverQueryInFlight else { return }
        hoverQueryInFlight = true
        let queryStartedAt = now

        stateLock.lock()
        let ignoredBundleIds = tapSnapshot.ignoredBundleIds
        stateLock.unlock()

        axQueue.async { [weak self] in
            let hitResult = Self.resolveGreenButtonTarget(at: mouseQuartz, ignoredBundleIds: ignoredBundleIds)
            DispatchQueue.main.async {
                guard let self else { return }
                self.hoverQueryInFlight = false
                guard let hitResult else {
                    self.lastNegativeHitPoint = mouseQuartz
                    self.lastNegativeHitTime = CACurrentMediaTime()
                    self.cancelPendingPresentation()
                    return
                }
                self.invalidateNegativeHitCache()
                let alreadyElapsed = CACurrentMediaTime() - queryStartedAt
                let remainingDwell = max(0, Self.hoverDwellDelay - alreadyElapsed)
                self.schedulePresentation(
                    windowElement: hitResult.windowElement,
                    windowId: hitResult.windowId,
                    windowQuartzFrame: hitResult.windowQuartzFrame,
                    buttonQuartzFrame: hitResult.buttonQuartzFrame,
                    remainingDwell: remainingDwell
                )
            }
        }
    }

    private static func resolveGreenButtonTarget(
        at quartzPoint: CGPoint,
        ignoredBundleIds: Set<String>
    ) -> (windowElement: AccessibilityElement, windowId: CGWindowID?, windowQuartzFrame: CGRect, buttonQuartzFrame: CGRect)? {
        guard let element = AccessibilityElement(quartzPoint) else { return nil }
        element.setMessagingTimeout(0.04)

        guard let windowElement = element.greenStoplightParentWindow() else { return nil }
        windowElement.setMessagingTimeout(0.04)

        let buttonFrame = element.frame
        guard !buttonFrame.isNull, buttonFrame.insetBy(dx: -4, dy: -4).contains(quartzPoint) else { return nil }

        if let bundleId = windowElement.bundleIdentifier ?? element.bundleIdentifier,
           ignoredBundleIds.contains(bundleId) {
            return nil
        }

        guard windowElement.isEligibleStandardWindow() else {
            return nil
        }

        let windowFrame = windowElement.frame
        guard !windowFrame.isNull else { return nil }

        return (windowElement, windowElement.getWindowId(), windowFrame, buttonFrame)
    }

    private func schedulePresentation(
        windowElement: AccessibilityElement,
        windowId: CGWindowID?,
        windowQuartzFrame: CGRect,
        buttonQuartzFrame: CGRect,
        remainingDwell: TimeInterval
    ) {
        let allScreens = orderedScreens()
        let buttonAppKitFrame = buttonQuartzFrame.screenFlipped
        let screen = screenContaining(appKitRect: buttonAppKitFrame)
            ?? screenDetection.detectScreens(using: windowElement)?.currentScreen
            ?? allScreens.first
        guard let screen else { return }

        let screensList = allScreens.isEmpty ? [screen] : allScreens
        let screenIdx = screensList.firstIndex(of: screen) ?? 0

        let candidate = ActiveTarget(
            windowElement: windowElement,
            windowId: windowId,
            windowQuartzFrame: windowQuartzFrame,
            buttonQuartzFrame: buttonQuartzFrame,
            screens: screensList,
            sourceScreenIndex: screenIdx,
            selectedScreenIndex: screenIdx
        )

        if remainingDwell <= 0.002 {
            pendingTarget = nil
            presentWorkItem?.cancel()
            presentWorkItem = nil
            let currentQuartz = NSEvent.mouseLocation.screenFlipped
            if buttonQuartzFrame.insetBy(dx: -5, dy: -5).contains(currentQuartz) {
                presentPanel(
                    for: candidate,
                    anchor: .greenButton(buttonAppKitFrame: buttonAppKitFrame, interceptClick: isClickEnabled),
                    preselectKeyboardRegion: false
                )
            }
            return
        }

        pendingTarget = candidate
        Self.isPopoverActive = true
        presentWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.presentWorkItem = nil
            guard self.isHoverGridEnabled,
                  NSEvent.pressedMouseButtons == 0,
                  NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else {
                self.pendingTarget = nil
                self.refreshTapSnapshot()
                return
            }

            let currentQuartz = NSEvent.mouseLocation.screenFlipped
            guard buttonQuartzFrame.insetBy(dx: -5, dy: -5).contains(currentQuartz) else {
                self.pendingTarget = nil
                self.refreshTapSnapshot()
                return
            }

            self.pendingTarget = nil
            self.presentPanel(
                for: candidate,
                anchor: .greenButton(buttonAppKitFrame: buttonAppKitFrame, interceptClick: self.isClickEnabled),
                preselectKeyboardRegion: false
            )
        }
        presentWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDwell, execute: work)
    }

    private func presentPanel(
        for target: ActiveTarget,
        anchor: GreenButtonGridPanel.AnchorStyle,
        preselectKeyboardRegion: Bool
    ) {
        cancelScheduledDismiss()
        activeTarget = target

        let cols = Defaults.greenButtonGridColumns.value
        let rows = Defaults.greenButtonGridRows.value
        let isMaximized = Self.isWindowCurrentlyMaximized(windowFrame: target.windowQuartzFrame, windowId: target.windowId)
        let canRestore = Self.canRestoreWindow(windowFrame: target.windowQuartzFrame, windowId: target.windowId)

        let ignoreTodo = target.windowId.map { TodoManager.isTodoWindow($0) } ?? false
        let sourceVisibleFrame = target.sourceScreen.adjustedVisibleFrame(ignoreTodo)
        let windowAppKitFrame = target.windowQuartzFrame.screenFlipped
        let ghostRect = GridSelection.normalizedFlippedRect(of: windowAppKitFrame, in: sourceVisibleFrame)
        let initialSelection = preselectKeyboardRegion
            ? GridSelection.approximating(windowAppKitFrame: windowAppKitFrame, in: sourceVisibleFrame, columns: cols, rows: rows)
            : nil

        let hostScreen: NSScreen
        switch anchor {
        case .greenButton:
            hostScreen = target.sourceScreen
        case let .cursor(pt):
            hostScreen = target.screens.first(where: { $0.frame.contains(pt) }) ?? target.selectedScreen
        }

        let panelScreens = Defaults.combinedDisplayMode.userEnabled ? [target.sourceScreen] : target.screens

        gridPanel.present(
            anchor: anchor,
            on: hostScreen,
            screens: panelScreens,
            sourceScreenIndex: panelScreens.count > 1 ? target.sourceScreenIndex : 0,
            selectedScreenIndex: panelScreens.count > 1 ? target.selectedScreenIndex : 0,
            columns: cols,
            rows: rows,
            isTargetMaximized: isMaximized,
            canRestoreTarget: canRestore,
            currentWindowNormalizedRect: ghostRect,
            initialKeyboardSelection: initialSelection
        )
        refreshTapSnapshot()
        if !keyMonitor.running {
            keyMonitor.start()
        }

        if case .greenButton = anchor {
            notifyWindowServerOfBridgeOcclusion()
        }
    }

    private func notifyWindowServerOfBridgeOcclusion() {
        let currentQuartz = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation.screenFlipped
        isPostingSyntheticOcclusionMove = true
        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: currentQuartz,
            mouseButton: .left
        ) {
            moveEvent.post(tap: .cgSessionEventTap)
        }
        DispatchQueue.main.async { [weak self] in
            self?.isPostingSyntheticOcclusionMove = false
        }
    }

    private func cancelPendingPresentation() {
        presentWorkItem?.cancel()
        presentWorkItem = nil
        pendingTarget = nil
        if activeTarget == nil {
            Self.isPopoverActive = false
        }
    }

    private func scheduleDismissIfNeeded() {
        guard dismissWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dismissWorkItem = nil
            if let placement = self.gridPanel.currentPlacement,
               self.gridPanel.isOpenedViaKeyboard
                || self.gridPanel.isSelectingGrid
                || placement.containsHoverPoint(NSEvent.mouseLocation) {
                return
            }
            self.dismissPanel()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDismissGrace, execute: work)
    }

    private func cancelScheduledDismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    func dismissPanel() {
        cancelTrailingHoverSample()
        cancelPendingPresentation()
        cancelScheduledDismiss()
        hidePreviewFootprint()
        if keyMonitor.running {
            keyMonitor.stop()
        }
        if activeTarget != nil {
            gridPanel.dismiss()
        }
        activeTarget = nil
        if !isHoverGridEnabled && interactionMonitor.running {
            interactionMonitor.stop()
        }
        refreshTapSnapshot()
    }

    // MARK: - Live Footprint Preview & Execution

    private func handlePreviewAction(_ action: WindowAction?) {
        guard let action,
              let target = activeTarget,
              let windowManager = AppDelegate.instance.windowManager
        else {
            hidePreviewFootprint()
            return
        }
        let targetScreen = action == .nextDisplay ? target.sourceScreen : target.selectedScreen
        guard let previewRect = windowManager.previewFrame(
            for: action,
            windowElement: target.windowElement,
            screen: targetScreen
        ), !previewRect.isNull else {
            hidePreviewFootprint()
            return
        }
        showPreviewFootprint(in: previewRect)
    }

    private func handlePreviewGrid(_ selection: GridSelection?) {
        guard let selection, let target = activeTarget else {
            hidePreviewFootprint()
            return
        }
        let cols = gridPanel.columns
        let rows = gridPanel.rows
        let ignoreTodo = target.windowId.map { TodoManager.isTodoWindow($0) } ?? false
        let visibleFrame = target.selectedScreen.adjustedVisibleFrame(ignoreTodo)
        let previewRect = selection.targetFrame(
            in: visibleFrame,
            columns: cols,
            rows: rows,
            gapSize: Defaults.gapSize.value,
            skipTopGap: Defaults.skipGapTopEdge.enabled,
            applyGapsToMaximize: !Defaults.applyGapsToMaximize.userDisabled
        )
        guard !previewRect.isNull else {
            hidePreviewFootprint()
            return
        }
        showPreviewFootprint(in: previewRect)
    }

    private func showPreviewFootprint(in appKitRect: CGRect) {
        if isPreviewVisible && footprintWindow.realIsVisible {
            footprintWindow.movePreview(to: appKitRect, duration: 0.05)
        } else {
            isPreviewVisible = true
            footprintWindow.showPreview(in: appKitRect, from: nil, duration: 0.05, below: nil)
        }
    }

    private func hidePreviewFootprint() {
        guard isPreviewVisible else { return }
        isPreviewVisible = false
        footprintWindow.orderOut(nil)
    }

    private func handleSelectAction(_ action: WindowAction) {
        guard let target = activeTarget else { return }
        let destinationScreen = action == .nextDisplay ? target.sourceScreen : target.selectedScreen
        let movingToDifferentScreen = destinationScreen != target.sourceScreen
        dismissPanel()
        if movingToDifferentScreen,
           action != .nextDisplay,
           action != .restore,
           let windowId = target.windowId {
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
        }
        target.windowElement.bringToFront()
        AppDelegate.instance.windowManager?.execute(
            ExecutionParameters(
                action,
                updateRestoreRect: action != .restore,
                screen: destinationScreen,
                windowElement: target.windowElement,
                windowId: target.windowId,
                source: .titleBar
            )
        )
    }

    private func handleMoveToScreen(at index: Int) {
        guard let target = activeTarget, target.screens.indices.contains(index) else { return }
        let destinationScreen = target.screens[index]
        let sourceScreen = target.sourceScreen
        dismissPanel()
        guard destinationScreen != sourceScreen else { return }

        let ignoreTodo = target.windowId.map { TodoManager.isTodoWindow($0) } ?? false
        let sourceVisible = sourceScreen.adjustedVisibleFrame(ignoreTodo)
        let destVisible = destinationScreen.adjustedVisibleFrame(ignoreTodo)
        let currentAppKit = target.windowQuartzFrame.screenFlipped
        let transferred = DisplayTransfer.transferredRect(
            window: currentAppKit,
            source: sourceVisible,
            destination: destVisible
        )
        AppDelegate.instance.windowManager?.executeCustomFrame(
            transferred.rect,
            isMaximizeEquivalent: transferred.sharedEdges == .all,
            on: destinationScreen,
            windowElement: target.windowElement
        )
    }

    private func handleSelectGrid(_ selection: GridSelection) {
        guard let target = activeTarget else { return }
        let cols = gridPanel.columns
        let rows = gridPanel.rows
        let destinationScreen = target.selectedScreen
        dismissPanel()

        let ignoreTodo = target.windowId.map { TodoManager.isTodoWindow($0) } ?? false
        let visibleFrame = destinationScreen.adjustedVisibleFrame(ignoreTodo)
        let targetRect = selection.targetFrame(
            in: visibleFrame,
            columns: cols,
            rows: rows,
            gapSize: Defaults.gapSize.value,
            skipTopGap: Defaults.skipGapTopEdge.enabled,
            applyGapsToMaximize: !Defaults.applyGapsToMaximize.userDisabled
        )
        let isFull = selection.isFullGrid(columns: cols, rows: rows)
        AppDelegate.instance.windowManager?.executeCustomFrame(
            targetRect,
            isMaximizeEquivalent: isFull,
            on: destinationScreen,
            windowElement: target.windowElement
        )
    }

    // MARK: - Helpers

    private func orderedScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return screens }
        return screens.sorted { a, b in
            if abs(a.frame.minX - b.frame.minX) > 1 {
                return a.frame.minX < b.frame.minX
            }
            return a.frame.maxY > b.frame.maxY
        }
    }

    private func screenContaining(appKitRect: CGRect) -> NSScreen? {
        let mid = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        if let match = NSScreen.screens.first(where: { $0.frame.contains(mid) }) {
            return match
        }
        return NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(appKitRect)
            let ib = b.frame.intersection(appKitRect)
            return max(0, ia.width) * max(0, ia.height) < max(0, ib.width) * max(0, ib.height)
        }
    }

    private static func isWindowCurrentlyMaximized(windowFrame: CGRect, windowId: CGWindowID?) -> Bool {
        guard let windowId,
              !windowFrame.isNull,
              let historyAction = AppDelegate.windowHistory.lastRectangleActions[windowId],
              historyAction.action == .maximize,
              historyAction.rect == windowFrame,
              AppDelegate.windowHistory.restoreRects[windowId] != nil
        else {
            return false
        }
        return true
    }

    private static func canRestoreWindow(windowFrame: CGRect, windowId: CGWindowID?) -> Bool {
        guard let windowId,
              !windowFrame.isNull,
              let restoreRect = AppDelegate.windowHistory.restoreRects[windowId],
              !restoreRect.isNull,
              restoreRect != windowFrame
        else {
            return false
        }
        return true
    }

    static func executeMaximizeOrRestore(_ windowElement: AccessibilityElement) {
        if isWindowCurrentlyMaximized(windowFrame: windowElement.frame, windowId: windowElement.getWindowId()) {
            WindowAction.restore.postTitleBar(windowElement: windowElement)
            return
        }
        WindowAction.maximize.postTitleBar(windowElement: windowElement)
    }
}
