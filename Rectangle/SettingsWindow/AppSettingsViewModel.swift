/// AppSettingsViewModel.swift

import SwiftUI
import AppKit

@Observable
final class AppSettingsViewModel {
    // MARK: - General Settings
    var hideMenuBarIcon: Bool {
        didSet {
            guard hideMenuBarIcon != oldValue else { return }
            Defaults.hideMenuBarIcon.enabled = hideMenuBarIcon
            RectangleStatusItem.instance.refreshVisibility()
        }
    }

    var versionString: String = ""

    var allowAnyShortcut: Bool {
        didSet {
            guard allowAnyShortcut != oldValue else { return }
            Defaults.allowAnyShortcut.enabled = allowAnyShortcut
            Notification.Name.allowAnyShortcut.post(object: allowAnyShortcut)
        }
    }

    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Initialization
    init() {
        self.hideMenuBarIcon = Defaults.hideMenuBarIcon.enabled
        self.allowAnyShortcut = Defaults.allowAnyShortcut.enabled

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.2-custom"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "114"
        self.versionString = "v\(appVersion) (\(build))"

        setupObservers()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupObservers() {
        notificationObservers.append(Notification.Name.menuBarIconHidden.onPost { [weak self] _ in
            self?.hideMenuBarIcon = true
        })

        notificationObservers.append(Notification.Name.configImported.onPost { [weak self] _ in
            self?.reloadFromDefaults()
        })
    }

    func reloadFromDefaults() {
        self.hideMenuBarIcon = Defaults.hideMenuBarIcon.enabled
        self.allowAnyShortcut = Defaults.allowAnyShortcut.enabled
    }

    @MainActor
    func checkForUpdates() {
        GitHubSoftwareUpdater.shared.checkForUpdates()
    }

    func restoreDefaults() {
        let currentDefaults = Defaults.alternateDefaultShortcuts.enabled ? "Rectangle" : "Spectacle"
        let defaultShortcutsTitle = String(localized: "Default Shortcuts")
        let currentlyUsingText = String(localized: "Currently using: ")
        let cancelText = String(localized: "Cancel")

        let response = AlertUtil.threeButtonAlert(question: defaultShortcutsTitle, text: currentlyUsingText + currentDefaults, buttonOneText: "Rectangle", buttonTwoText: "Spectacle", buttonThreeText: cancelText)
        if response == .alertThirdButtonReturn { return }

        let rectangleDefaults = (response == .alertFirstButtonReturn)
        WindowAction.active.forEach { UserDefaults.standard.removeObject(forKey: $0.name) }
        Defaults.alternateDefaultShortcuts.enabled = rectangleDefaults
        Notification.Name.changeDefaults.post()

        Defaults.portraitSnapAreas.typedValue = nil
        Defaults.landscapeSnapAreas.typedValue = nil
        Notification.Name.defaultSnapAreas.post()
    }

    func exportConfig() {
        Notification.Name.windowSnapping.post(object: false)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "RectangleConfig"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                if let jsonString = Defaults.encoded() {
                    try jsonString.write(to: url, atomically: false, encoding: .utf8)
                }
            } catch {
                Logger.log(error.localizedDescription)
            }
        }
        Notification.Name.windowSnapping.post(object: true)
    }

    func importConfig() {
        Notification.Name.windowSnapping.post(object: false)
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            Defaults.load(fileUrl: url)
        }
        Notification.Name.windowSnapping.post(object: true)
    }
}
