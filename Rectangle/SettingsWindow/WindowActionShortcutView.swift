/// WindowActionShortcutView.swift

import Carbon.HIToolbox
import Cocoa
import MASShortcut

/// A recorder for Rectangle shortcuts that adds:
/// 1. Mouse button shortcut recording (middle/extra buttons).
/// 2. Modified `Tab` combinations (`Option+Tab`, `Control+Tab`, etc.).
/// 3. Temporary ASCII keyboard layout switching while recording so IMEs
///    (such as Vietnamese Telex/VNI) never swallow letter keys.
/// 4. Interactive internal conflict detection with 1-click Reassign or Cycle.
final class WindowActionShortcutView: MASShortcutView {

    struct InternalShortcutConflict {
        let defaultsKey: String
        let displayName: String
        let isWindowAction: Bool
    }

    var allowsMouseButtons = true
    private var recordingMonitor: Any?
    private var savedInputSource: TISInputSource?
    private var isResolvingConflict = false

    // Dynamic, so that setting these from Swift still notifies key-value
    // observers, such as the ShortcutRecordingObserver watching recording.
    override dynamic var shortcutValue: MASShortcut? {
        get { super.shortcutValue }
        set {
            guard !isResolvingConflict else {
                super.shortcutValue = newValue.map(MouseButtonShortcut.displayable)
                return
            }

            if isRecording,
               let candidate = newValue,
               let currentKey = associatedUserDefaultsKey,
               !currentKey.isEmpty {
                let conflicts = Self.findInternalConflicts(for: candidate, ignoringDefaultsKey: currentKey)
                if !conflicts.isEmpty {
                    resolveConflictAndApply(candidate: candidate, currentKey: currentKey, conflicts: conflicts)
                    return
                }
            }

            super.shortcutValue = newValue.map(MouseButtonShortcut.displayable)
            Self.reevaluateAllAppShortcuts()
        }
    }

    override dynamic var isRecording: Bool {
        didSet { updateRecordingState() }
    }

    deinit {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
        }
        restoreInputSourceIfNeeded()
    }

    /// Records the button of a mouse down event, if recording and the button
    /// can be a shortcut. Returns whether it was recorded.
    @discardableResult
    func recordMouseButton(_ event: NSEvent) -> Bool {
        guard allowsMouseButtons,
              isRecording,
              event.window === window,
              NSApp.modalWindow == nil,
              let shortcut = MouseButtonShortcut(buttonPress: event)
        else { return false }
        shortcutValue = shortcut
        isRecording = false
        return true
    }

    /// MASShortcutView unconditionally ignores `kVK_Tab` so plain Tab can move
    /// keyboard focus, inadvertently blocking `Option+Tab`, `Control+Tab`, etc.
    /// Intercept modified Tab combinations here while keeping plain Tab intact.
    @discardableResult
    func recordModifiedTabKey(_ event: NSEvent) -> Bool {
        guard isRecording,
              Int(event.keyCode) == kVK_Tab,
              event.window === window,
              NSApp.modalWindow == nil
        else { return false }

        let shortcut = MASShortcut(event: event)
        let primaryModifiers = shortcut.modifierFlags.intersection([.control, .option, .command])
        let allowsShiftOnly = Defaults.allowAnyShortcut.enabled && shortcut.modifierFlags.contains(.shift)
        guard !primaryModifiers.isEmpty || allowsShiftOnly else {
            return false
        }

        if let validator = shortcutValidator {
            guard validator.isShortcutValid(shortcut) else {
                NSSound.beep()
                return true
            }
            var explanation: NSString?
            if validator.isShortcutAlreadyTaken(bySystem: shortcut, explanation: &explanation) {
                isRecording = false
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = String(format: NSLocalizedString("The key combination %@ cannot be used", comment: ""), shortcut.description)
                alert.informativeText = (explanation as String?) ?? ""
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                alert.runModal()
                return true
            }
        }

        shortcutValue = shortcut
        isRecording = false
        return true
    }

    // MARK: - Internal Conflict Detection & Resolution

    static func findInternalConflicts(
        for shortcut: MASShortcut,
        ignoringDefaultsKey ignoredKey: String,
        userDefaults: UserDefaults = .standard
    ) -> [InternalShortcutConflict] {
        let identity = ShortcutCycle.ShortcutIdentity(shortcut)
        var results: [InternalShortcutConflict] = []

        for action in WindowAction.active where action.name != ignoredKey {
            guard let existing = ShortcutCycle.shortcut(for: action, userDefaults: userDefaults),
                  ShortcutCycle.ShortcutIdentity(existing) == identity
            else { continue }

            let title = action.settingsDisplayName ?? action.displayName ?? action.name
            results.append(InternalShortcutConflict(
                defaultsKey: action.name,
                displayName: title,
                isWindowAction: true
            ))
        }

        let appKeys = TodoManager.defaultsKeys + StackBadgeManager.defaultsKeys + GreenButtonManager.defaultsKeys
        for key in appKeys where key != ignoredKey {
            guard let existing = ShortcutCycle.shortcut(forDefaultsKey: key, userDefaults: userDefaults),
                  ShortcutCycle.ShortcutIdentity(existing) == identity
            else { continue }

            results.append(InternalShortcutConflict(
                defaultsKey: key,
                displayName: AppShortcutConflict.displayName(forDefaultsKey: key),
                isWindowAction: false
            ))
        }

        return results
    }

    private func resolveConflictAndApply(
        candidate: MASShortcut,
        currentKey: String,
        conflicts: [InternalShortcutConflict]
    ) {
        isResolvingConflict = true
        defer { isResolvingConflict = false }

        // Stop recording before running the modal alert so MASShortcutView's
        // event monitor and resign-key observer are cleanly deactivated.
        isRecording = false

        let displayShortcut = MouseButtonShortcut.displayable(candidate)
        let conflictNames = conflicts.map(\.displayName).joined(separator: ", ")
        let currentIsWindowAction = WindowAction.active.contains { $0.name == currentKey }
        let canCycleBoth = currentIsWindowAction && conflicts.allSatisfy(\.isWindowAction)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "Shortcut %@ is already used by “%@”"),
            displayShortcut.description,
            conflictNames
        )

        if canCycleBoth {
            alert.informativeText = String(localized: "Do you want to reassign this shortcut here (removing it from the other action), or keep both so pressing it repeatedly cycles between them?")
            alert.addButton(withTitle: String(localized: "Reassign"))
            alert.addButton(withTitle: String(localized: "Keep Both (Cycle)"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        } else {
            alert.informativeText = String(
                format: String(localized: "Do you want to remove this shortcut from “%@” and assign it here?"),
                conflictNames
            )
            alert.addButton(withTitle: String(localized: "Reassign"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            for conflict in conflicts {
                UserDefaults.standard.removeObject(forKey: conflict.defaultsKey)
            }
            super.shortcutValue = displayShortcut
            Self.reevaluateAllAppShortcuts()
            DispatchQueue.main.async {
                Notification.Name.shortcutsUpdatedInternally.post()
            }

        case .alertSecondButtonReturn where canCycleBoth:
            super.shortcutValue = displayShortcut
            Self.reevaluateAllAppShortcuts()

        default:
            needsDisplay = true
        }
    }

    private static func reevaluateAllAppShortcuts() {
        TodoManager.registerUnregisterToggleShortcut()
        TodoManager.registerUnregisterReflowShortcut()
        StackBadgeManager.reevaluateToggleShortcut()
        GreenButtonManager.reevaluateToggleShortcut()
    }

    // MARK: - Recording Monitor & Temporary ASCII Input Source

    private func updateRecordingState() {
        if isRecording {
            activateTemporaryASCIIInputSourceIfNeeded()
            guard recordingMonitor == nil else { return }
            recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .otherMouseDown:
                    return self.recordMouseButton(event) ? nil : event
                case .keyDown where Int(event.keyCode) == kVK_Tab:
                    return self.recordModifiedTabKey(event) ? nil : event
                default:
                    return event
                }
            }
        } else {
            if let recordingMonitor {
                NSEvent.removeMonitor(recordingMonitor)
                self.recordingMonitor = nil
            }
            restoreInputSourceIfNeeded()
        }
    }

    private func activateTemporaryASCIIInputSourceIfNeeded() {
        guard savedInputSource == nil,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let asciiLayout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        else { return }

        let currentID = Self.inputSourceID(of: current)
        let asciiID = Self.inputSourceID(of: asciiLayout)
        if let currentID, let asciiID, currentID != asciiID {
            savedInputSource = current
            TISSelectInputSource(asciiLayout)
        }
    }

    private func restoreInputSourceIfNeeded() {
        guard let saved = savedInputSource else { return }
        savedInputSource = nil
        TISSelectInputSource(saved)
    }

    private static func inputSourceID(of source: TISInputSource) -> String? {
        guard let rawPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(rawPtr).takeUnretainedValue() as String
    }
}
