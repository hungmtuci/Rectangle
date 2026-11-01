/// AppDelegate.swift

import Cocoa
import MASShortcut
import os.log

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private let accessibilityAuthorization = AccessibilityAuthorization()
    private let statusItem = RectangleStatusItem.instance
    static let windowHistory = WindowHistory()
    var hasPendingUpdate = false {
        didSet {
            Notification.Name.updateAvailability.post()
        }
    }

    private static var retainedDelegate: AppDelegate?
    private var retainedMenus: [NSMenu] = []

    private var shortcutManager: ShortcutManager!
    private(set) var windowManager: WindowManager!
    private var applicationToggle: ApplicationToggle!
    private var windowCalculationFactory: WindowCalculationFactory!
    private var snappingManager: SnappingManager!
    private var stackBadgeManager: StackBadgeManager!
    private var titleBarManager: TitleBarManager!
    private var greenButtonManager: GreenButtonManager!
    
    private var settingsWindowController: NSWindowController?
    
    private var prevActiveAppObservation: NSKeyValueObservation?
    private var prevActiveApp: NSRunningApplication?
    private var additionalSizeMenuItems: [NSMenuItem] = []
    private var dynamicMenuItemCount: Int = 0

    @IBOutlet weak var mainStatusMenu: NSMenu!
    @IBOutlet weak var unauthorizedMenu: NSMenu!
    @IBOutlet weak var ignoreMenuItem: NSMenuItem!
    @IBOutlet weak var viewLoggingMenuItem: NSMenuItem!
    @IBOutlet weak var updatesMenuItem: NSMenuItem!
    @IBOutlet weak var quitMenuItem: NSMenuItem!
    weak var launchOnLoginMenuItem: NSMenuItem?
    weak var showSettingsOnLaunchMenuItem: NSMenuItem?
    
    static var instance: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    static func main() {
        let app = NSApplication.shared
        if Bundle.main.path(forResource: "Main", ofType: "storyboardc") == nil {
            let delegate = AppDelegate()
            retainedDelegate = delegate
            delegate.configureProgrammaticMenusIfNeeded(for: app)
            app.delegate = delegate
        }
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        terminateOtherRunningInstances()
        MASShortcutValidator.shared()?.allowAnyShortcutWithOptionModifier = true
        MASShortcutValidator.shared()?.allowOverridingServicesShortcut = true
        configureProgrammaticMenusIfNeeded(for: NSApp)
        Defaults.loadFromSupportDir()
        migrateShowEighthsInMenu()

        checkVersion()
        mainStatusMenu.delegate = self
        statusItem.refreshVisibility()
        checkLaunchOnLogin()
        
        let alreadyTrusted = accessibilityAuthorization.checkAccessibility {
            WelcomeView.show()
            self.checkForConflictingApps()
            self.openPreferences(self)
            self.statusItem.statusMenu = self.mainStatusMenu
            self.accessibilityTrusted()
        }
        
        if alreadyTrusted {
            accessibilityTrusted()
            if Defaults.showSettingsOnLaunch.enabled {
                DispatchQueue.main.async {
                    self.openPreferences(self)
                }
            }
        }
        
        statusItem.statusMenu = alreadyTrusted
            ? mainStatusMenu
            : unauthorizedMenu
        
        mainStatusMenu.autoenablesItems = false
        addMenuIcons()
        addWindowActionMenuItems()

        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMenu), name: .showAdditionalSizesInMenuChanged, object: nil)

        _ = GitHubSoftwareUpdater.shared
        checkAutoCheckForUpdates()
        syncUpdateMenuItemTitle()
        
        Notification.Name.configImported.onPost(using: { _ in
            self.checkAutoCheckForUpdates()
            self.statusItem.refreshVisibility()
            self.applicationToggle.reloadFromDefaults()
            self.shortcutManager.reloadFromDefaults()
            self.snappingManager.reloadFromDefaults()
            self.initializeTodo(false)
        })
        
        Notification.Name.todoMenuToggled.onPost(using: { _ in
            self.initializeTodo(false)
        })
        
        prevActiveAppObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: .old) { workspace, change in
            self.prevActiveApp = change.oldValue ?? nil
        }
    }
    
    func checkVersion() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let lastVersion = Defaults.lastVersion.value,
           let intLastVersion = Int(lastVersion) {
            if intLastVersion < 46 {
                MASShortcutMigration.migrate()
            }
            if intLastVersion < 64 {
                SnapAreaModel.instance.migrate()
            }
        } else {
            Defaults.installVersion.value = currentVersion
            Defaults.allowAnyShortcut.enabled = true
        }
        MASShortcutMigration.syncRenamedSideShortcutAliases()
        
        Defaults.lastVersion.value = currentVersion
    }
    
    func applicationWillBecomeActive(_ notification: Notification) {
        Notification.Name.appWillBecomeActive.post()
    }
    
    private func addMenuIcons() {
        guard #available(macOS 11, *) else { return }
        for item in mainStatusMenu.items {
            switch item.action {
            case #selector(openPreferences):
                item.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
            case #selector(toggleLaunchOnLoginMenuItem):
                item.image = NSImage(systemSymbolName: "power.circle", accessibilityDescription: nil)
            case #selector(toggleShowSettingsOnLaunchMenuItem):
                item.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)
            case #selector(viewLogging):
                item.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            case #selector(checkForUpdates):
                item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            case #selector(openGitHubReleases):
                item.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            default:
                break
            }
        }
    }

    @MainActor
    func checkAutoCheckForUpdates() {
        let updater = GitHubSoftwareUpdater.shared
        updater.automaticallyChecksForUpdates = Defaults.SUEnableAutomaticChecks.enabled
        updater.checkSilentlyIfDue()
    }

    @MainActor
    func syncUpdateMenuItemTitle() {
        guard let updatesMenuItem else { return }
        if let newTag = GitHubSoftwareUpdater.shared.availableReleaseTag {
            updatesMenuItem.title = "Cập nhật mới trên GitHub (\(newTag))…"
            updatesMenuItem.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        } else {
            updatesMenuItem.title = "Cập nhật qua GitHub…"
            updatesMenuItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        }
    }
    
    func accessibilityTrusted() {
        self.windowCalculationFactory = WindowCalculationFactory()
        self.windowManager = WindowManager()
        self.shortcutManager = ShortcutManager(windowManager: windowManager)
        self.applicationToggle = ApplicationToggle(shortcutManager: shortcutManager)
        self.snappingManager = SnappingManager()
        self.stackBadgeManager = StackBadgeManager()
        self.titleBarManager = TitleBarManager()
        self.greenButtonManager = GreenButtonManager()
        self.initializeTodo()
        checkForProblematicApps()
        MacTilingDefaults.checkForBuiltInTiling(skipIfAlreadyNotified: true)
    }
    
    func checkForConflictingApps() {
        let conflictingAppsIds: [String: String] = [
            "com.divisiblebyzero.Spectacle": "Spectacle",
            "com.crowdcafe.windowmagnet": "Magnet",
            "com.hegenberg.BetterSnapTool": "BetterSnapTool",
            "com.manytricks.Moom": "Moom"
        ]
        
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard let bundleId = app.bundleIdentifier else { continue }
            if let conflictingAppName = conflictingAppsIds[bundleId] {
                AlertUtil.oneButtonAlert(question: "Potential window manager conflict: \(conflictingAppName)", text: "Since \(conflictingAppName) might have some overlapping behavior with Rectangle, it's recommended that you either disable or quit \(conflictingAppName).")
                break
            }
        }
        
    }
    
    /// certain applications have issues with the click listening done by the drag to snap feature
    func checkForProblematicApps() {
        guard !Defaults.windowSnapping.userDisabled, !Defaults.notifiedOfProblemApps.enabled else { return }
        
        let problemBundleIds: [String] = [
            "com.mathworks.matlab",
            "com.live2d.cubism.CECubismEditorApp",
            "com.aquafold.datastudio.DataStudio",
            "com.adobe.illustrator",
            "com.adobe.AfterEffects"
        ]
        
        // these apps are java based with dynamic bundleIds
        let problemJavaAppNames: [String] = [
            "thinkorswim",
            "Trader Workstation"
        ]

        var problemBundles: [Bundle] = problemBundleIds.compactMap { bundleId in
            if applicationToggle.isDisabled(bundleId: bundleId) { return nil }
            
            // Directly instantiating the Bundle from the bundle id didn't work for matlab for some reason
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return Bundle(url: url)
            }
            return nil
        }
        
        let runningApps = NSWorkspace.shared.runningApplications

        for name in problemJavaAppNames {
            if let runningApp = runningApps.first(where: { $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame }),
               let bundleId = runningApp.bundleIdentifier,
               let appURL = runningApp.bundleURL,
               let bundle = Bundle(url: appURL) {
                
                if !applicationToggle.isDisabled(bundleId: bundleId),
                   bundleId.starts(with: "com.install4j") {
                    problemBundles.append(bundle)
                }
            }
        }
        
        let displayNames = problemBundles.compactMap { $0.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String }
        let displayNameString = displayNames.joined(separator: "\n")
        
        if !problemBundles.isEmpty {
            AlertUtil.oneButtonAlert(question: "Known issues with installed applications", text: "\(displayNameString)\n\nThese applications have issues with the drag to screen edge to snap functionality in Rectangle.\n\nYou can either ignore the applications using the menu item in Rectangle, or disable drag to screen edge snapping in Rectangle preferences.")
            Defaults.notifiedOfProblemApps.enabled = true
        }
    }
        
    private func showWelcomeWindow() {
        let welcomeWindowController = NSStoryboard(name: "Main", bundle: nil)
            .instantiateController(withIdentifier: "WelcomeWindowController") as? NSWindowController
        guard let welcomeWindow = welcomeWindowController?.window else { return }
        welcomeWindow.delegate = self
        
        NSApp.activate(ignoringOtherApps: true)
        
        let response = NSApp.runModal(for: welcomeWindow)
        
        let usingRecommended = response == .alertFirstButtonReturn || response == .abort
        
        Defaults.alternateDefaultShortcuts.enabled = usingRecommended
        
        Defaults.subsequentExecutionMode.value = usingRecommended ? .acrossMonitor : .resize
        
        welcomeWindowController?.close()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Defaults.relaunchOpensMenu.enabled {
            statusItem.openMenu()
        } else {
            openPreferences(sender)
        }
        return true
    }
    
    @IBAction func openPreferences(_ sender: Any) {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            controller.onClose = { [weak self] in self?.settingsWindowController = nil }
            settingsWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(self)
    }
    
    @IBAction func showAbout(_ sender: Any) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(sender)
    }
    
    @IBAction func viewLogging(_ sender: Any) {
        Logger.showLogging(sender: sender)
    }
    
    @IBAction func ignoreFrontMostApp(_ sender: NSMenuItem) {
        if sender.state == .on {
            applicationToggle.enableApp()
        } else {
            applicationToggle.disableApp()
        }
    }
    
    @MainActor
    @IBAction func checkForUpdates(_ sender: Any) {
        GitHubSoftwareUpdater.shared.checkForUpdates()
    }

    @MainActor
    @objc func openGitHubReleases(_ sender: Any) {
        GitHubSoftwareUpdater.shared.openReleasesPage()
    }
    
    @IBAction func authorizeAccessibility(_ sender: Any) {
        accessibilityAuthorization.showAuthorizationWindow()
    }

    @MainActor
    @objc func toggleLaunchOnLoginMenuItem(_ sender: NSMenuItem) {
        StartupPreferencesManager.shared.launchOnLogin.toggle()
        syncStartupMenuItems(refreshSystemStatus: false)
    }

    @MainActor
    @objc func toggleShowSettingsOnLaunchMenuItem(_ sender: NSMenuItem) {
        StartupPreferencesManager.shared.showSettingsOnLaunch.toggle()
        syncStartupMenuItems(refreshSystemStatus: false)
    }

    @MainActor
    func syncStartupMenuItems(refreshSystemStatus: Bool = false) {
        let prefs = StartupPreferencesManager.shared
        if refreshSystemStatus {
            prefs.refreshFromSystem()
        } else if prefs.showSettingsOnLaunch != Defaults.showSettingsOnLaunch.enabled {
            prefs.refreshFromSystem()
        }
        launchOnLoginMenuItem?.state = prefs.launchOnLogin ? .on : .off
        showSettingsOnLaunchMenuItem?.state = prefs.showSettingsOnLaunch ? .on : .off
    }

    @MainActor
    private func checkLaunchOnLogin() {
        StartupPreferencesManager.shared.syncOnAppLaunch()
        syncStartupMenuItems(refreshSystemStatus: false)
    }

}

extension AppDelegate: NSMenuDelegate {
    
    func menuWillOpen(_ menu: NSMenu) {
        if menu != mainStatusMenu {
            updateWindowActionMenuItems(menu: menu)
            updateTodoModeMenuItems(menu: menu)
            return
        }
        
        if let frontAppName = ApplicationToggle.frontAppName {
            let ignoreString = String(localized: "Ignore frontmost.app")
            ignoreMenuItem.title = ignoreString.replacingOccurrences(of: "frontmost.app", with: frontAppName)
            ignoreMenuItem.state = ApplicationToggle.shortcutsDisabled ? .on : .off
            ignoreMenuItem.isHidden = false
        } else {
            ignoreMenuItem.isHidden = true
        }
        
        updateWindowActionMenuItems(menu: menu)
        updateTodoModeMenuItems(menu: menu)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.syncStartupMenuItems(refreshSystemStatus: false)
                self.syncUpdateMenuItemTitle()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.syncStartupMenuItems(refreshSystemStatus: false)
                self?.syncUpdateMenuItemTitle()
            }
        }

        viewLoggingMenuItem.keyEquivalentModifierMask = .option
        quitMenuItem.keyEquivalent = "q"
        quitMenuItem.keyEquivalentModifierMask = .command
    }
    
    private func updateWindowActionMenuItems(menu: NSMenu) {
        let frontmostWindow = AccessibilityElement.getFrontWindowElement()
        let screenCount = NSScreen.screens.count
        let isPortrait = NSScreen.main?.frame.isLandscape == false

        for menuItem in menu.items {
            guard let windowAction = menuItem.representedObject as? WindowAction else { continue }

            menuItem.image = windowAction.image.copy() as? NSImage
            menuItem.image?.size = NSSize(width: 18, height: 12)
            
            if isPortrait && windowAction.classification == .thirds {
                menuItem.image = menuItem.image?.rotated(by: 270)
                menuItem.image?.isTemplate = true
            }

            if !ApplicationToggle.shortcutsDisabled {
                if let fullKeyEquivalent = shortcutManager.getKeyEquivalent(action: windowAction),
                    let keyEquivalent = fullKeyEquivalent.0?.lowercased() {
                    menuItem.keyEquivalent = keyEquivalent
                    menuItem.keyEquivalentModifierMask = fullKeyEquivalent.1
                }
            }
            if frontmostWindow == nil {
                menuItem.isEnabled = false
            }
            if windowAction == .nextDisplay || windowAction == .previousDisplay {
                menuItem.isHidden = screenCount == 1 || Defaults.combinedDisplayMode.userEnabled
            }
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        for menuItem in menu.items {
            
            menuItem.keyEquivalent = ""
            menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags()
            
            menuItem.isEnabled = true
        }
    }
    
    @objc func executeMenuWindowAction(sender: NSMenuItem) {
        guard let windowAction = sender.representedObject as? WindowAction else { return }
        windowAction.postMenu()
    }
    
    func addWindowActionMenuItems(showAdditional: Bool = Defaults.showAdditionalSizesInMenu.userEnabled,
                                  showAllActions: Bool = Defaults.showAllActionsInMenu.userEnabled) {
        let additionalSizeCategories: Set<WindowActionCategory> = [.eighths, .ninths, .twelfths, .sixteenths, .tiling]
        let submenuOnlyWhenAdditional: Set<WindowActionCategory> = [.thirds, .size]
        var menuIndex = 0
        var categoryMenus: [CategoryMenu] = []
        for action in WindowAction.active {
            guard !action.excludedFromMenu, let displayName = action.displayName else { continue }
            let newMenuItem = NSMenuItem(title: displayName, action: #selector(executeMenuWindowAction), keyEquivalent: "")
            newMenuItem.representedObject = action
            if newMenuItem.responds(to: Selector(("setPreferredImageVisibility:"))) {
                newMenuItem.setValue(1, forKey: "preferredImageVisibility")
            }
            if !showAllActions, let category = action.category {
                // When additional sizes are off, keep Thirds and Size as flat items
                if submenuOnlyWhenAdditional.contains(category) && !showAdditional {
                    // Fall through to flat item handling below
                } else {
                    if menuIndex != 0 && action.firstInGroup {
                        let menu = NSMenu(title: category.displayName)
                        menu.autoenablesItems = false
                        categoryMenus.append(CategoryMenu(menu: menu, category: category))
                    }
                    categoryMenus.last?.menu.addItem(newMenuItem)
                    continue
                }
            }

            // Flat item - suppress extra separator for almostMaximize when Size is not a submenu
            let showSeparator = action.firstInGroup && !(action == .almostMaximize && !showAdditional)
            if menuIndex != 0 && showSeparator {
                mainStatusMenu.insertItem(NSMenuItem.separator(), at: menuIndex)
                menuIndex += 1
            }
            mainStatusMenu.insertItem(newMenuItem, at: menuIndex)
            menuIndex += 1
        }

        if !categoryMenus.isEmpty {
            mainStatusMenu.insertItem(NSMenuItem.separator(), at: menuIndex)
            menuIndex += 1

            let sortedCategoryMenus = categoryMenus.sorted { $0.category.menuOrder < $1.category.menuOrder }
            for categoryMenu in sortedCategoryMenus {
                categoryMenu.menu.delegate = self
                let menuMenuItem = NSMenuItem(title: categoryMenu.category.displayName, action: nil, keyEquivalent: "")
                if additionalSizeCategories.contains(categoryMenu.category) {
                    menuMenuItem.isHidden = !showAdditional
                    additionalSizeMenuItems.append(menuMenuItem)
                }
                mainStatusMenu.insertItem(menuMenuItem, at: menuIndex)
                mainStatusMenu.setSubmenu(categoryMenu.menu, for: menuMenuItem)
                menuIndex += 1
            }
        }

        mainStatusMenu.insertItem(NSMenuItem.separator(), at: menuIndex)

        menuIndex += 1
        addTodoModeMenuItems(startingIndex: menuIndex)
        // Track total dynamic items: window actions + separators + todo items (4 items + 1 separator)
        dynamicMenuItemCount = menuIndex + 5
    }

    @objc func rebuildMenu() {
        // Remove all dynamically added items
        for _ in 0..<dynamicMenuItemCount {
            mainStatusMenu.removeItem(at: 0)
        }
        dynamicMenuItemCount = 0
        additionalSizeMenuItems.removeAll()
        addWindowActionMenuItems()
    }

    private func migrateShowEighthsInMenu() {
        let oldKey = "showEighthsInMenu"
        let oldValue = UserDefaults.standard.integer(forKey: oldKey)
        if oldValue != 0 && Defaults.showAdditionalSizesInMenu.notSet {
            Defaults.showAdditionalSizesInMenu.enabled = (oldValue == 1)
        }
    }

    struct CategoryMenu {
        let menu: NSMenu
        let category: WindowActionCategory
    }

}

// todo mode
extension AppDelegate {
    func initializeTodo(_ bringToFront: Bool = true) {
        self.showHideTodoMenuItems()
        TodoManager.registerUnregisterToggleShortcut()
        TodoManager.registerUnregisterReflowShortcut()
        TodoManager.moveAllIfNeeded(bringToFront)
    }

    enum TodoItem {
        case mode, app, reflow, separator, window

        var tag: Int {
            switch self {
            case .mode: return 101
            case .app: return 102
            case .reflow: return 103
            case .separator: return 104
            case .window: return 105
            }
        }
        
        static let tags = [101, 102, 103, 104, 105]
    }

    private func addTodoModeMenuItems(startingIndex: Int) {
        var menuIndex = startingIndex

        let todoModeItemTitle = String(localized: "Enable Todo Mode")
        let todoModeMenuItem = NSMenuItem(title: todoModeItemTitle, action: #selector(toggleTodoMode), keyEquivalent: "")
        todoModeMenuItem.tag = TodoItem.mode.tag
        todoModeMenuItem.target = self
        mainStatusMenu.insertItem(todoModeMenuItem, at: menuIndex)
        menuIndex += 1

        let todoAppItemTitle = String(localized: "Use frontmost.app as Todo App")
        let todoAppMenuItem = NSMenuItem(title: todoAppItemTitle, action: #selector(setTodoApp), keyEquivalent: "")
        todoAppMenuItem.tag = TodoItem.app.tag
        mainStatusMenu.insertItem(todoAppMenuItem, at: menuIndex)
        menuIndex += 1

        let todoWindowItemTitle = String(localized: "Use as Todo Window")
        let todoWindowMenuItem = NSMenuItem(title: todoWindowItemTitle, action: #selector(setTodoWindow), keyEquivalent: "")
        todoWindowMenuItem.tag = TodoItem.window.tag
        mainStatusMenu.insertItem(todoWindowMenuItem, at: menuIndex)
        menuIndex += 1
        
        let todoReflowItemTitle = String(localized: "Reflow Todo")
        let todoReflowItem = NSMenuItem(title: todoReflowItemTitle, action: #selector(todoReflow), keyEquivalent: "")
        todoReflowItem.tag = TodoItem.reflow.tag
        mainStatusMenu.insertItem(todoReflowItem, at: menuIndex)
        menuIndex += 1
        
        let separator = NSMenuItem.separator()
        separator.tag = TodoItem.separator.tag
        mainStatusMenu.insertItem(separator, at: menuIndex)
        
        showHideTodoMenuItems()
    }
    
    private func showHideTodoMenuItems() {
        for item in mainStatusMenu.items {
            if TodoItem.tags.contains(item.tag) {
                item.isHidden = !Defaults.todo.userEnabled
            }
        }
    }

    @objc func toggleTodoMode(_ sender: NSMenuItem) {
        let enabled = sender.state == .off
        TodoManager.setTodoMode(enabled)
    }

    @objc func setTodoApp(_ sender: NSMenuItem) {
        applicationToggle.setTodoApp()
        TodoManager.moveAllIfNeeded()
    }

    @objc func todoReflow(_ sender: NSMenuItem) {
        TodoManager.moveAll()
    }
    
    @objc func setTodoWindow(_ sender: NSMenuItem) {
        TodoManager.resetTodoWindow()
        TodoManager.moveAllIfNeeded()
    }

    private func updateTodoModeMenuItems(menu: NSMenu) {
        guard Defaults.todo.userEnabled,
              let todoAppMenuItem = menu.item(withTag: TodoItem.app.tag),
              let todoModeMenuItem = menu.item(withTag: TodoItem.mode.tag),
              let todoReflowMenuItem = menu.item(withTag: TodoItem.reflow.tag),
              let todoWindowMenuItem = menu.item(withTag: TodoItem.window.tag)
        else {
            return
        }

        if let frontAppName = ApplicationToggle.frontAppName {
            let appString = String(localized: "Use frontmost.app as Todo App")
            todoAppMenuItem.title = appString.replacingOccurrences(
                of: "frontmost.app", with: frontAppName)
            todoAppMenuItem.isEnabled = !applicationToggle.todoAppIsActive()
            todoAppMenuItem.state = applicationToggle.todoAppIsActive() ? .on : .off
            todoAppMenuItem.isHidden = false
        } else {
            todoAppMenuItem.isHidden = true
        }

        todoModeMenuItem.state = Defaults.todoMode.enabled ? .on : .off
        
        if let fullKeyEquivalent = TodoManager.getToggleKeyDisplay(),
            let keyEquivalent = fullKeyEquivalent.0?.lowercased() {
            todoModeMenuItem.keyEquivalent = keyEquivalent
            todoModeMenuItem.keyEquivalentModifierMask = fullKeyEquivalent.1
        }

        if let fullKeyEquivalent = TodoManager.getReflowKeyDisplay(),
            let keyEquivalent = fullKeyEquivalent.0?.lowercased() {
            todoReflowMenuItem.keyEquivalent = keyEquivalent
            todoReflowMenuItem.keyEquivalentModifierMask = fullKeyEquivalent.1
        }
        
        todoReflowMenuItem.isEnabled = Defaults.todoMode.enabled
        
        todoWindowMenuItem.isHidden = !applicationToggle.todoAppIsActive() || TodoManager.isTodoWindowFront()
    }
}

extension AppDelegate: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        NSApp.abortModal()
    }
    
}

extension AppDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let triggeringApp = NSWorkspace.shared.frontmostApplication
        
        if triggeringApp == NSRunningApplication.current {
            prevActiveApp?.activate()
        }
        DispatchQueue.main.async {
            
            func getUrlName(_ name: String) -> String {
                return name.map { $0.isUppercase ? "-" + $0.lowercased() : String($0) }.joined()
            }
            
            func extractBundleIdParameter(fromComponents components: URLComponents) -> String? {
                (components.queryItems?.first { $0.name == "app-bundle-id" })?.value ?? ApplicationToggle.frontAppId
            }
            
            func isValidParameter(bundleId: String?) -> Bool {
                let isValid = bundleId?.isEmpty != true
                if !isValid {
                    Logger.log("Received an empty app-bundle-id parameter. Either pass a valid app bundle id or remove the parameter.")
                }
                return isValid
            }
            
            func confirmExecuteTask(action: String, bundleId: String) -> Bool {
                if triggeringApp == NSRunningApplication.current {
                    return true
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Allow Rectangle URL action?")
                alert.informativeText = String(localized: "An external source asked Rectangle to perform \"\(action)\" on app bundle id \"\(bundleId)\". Allow?")
                alert.addButton(withTitle: String(localized: "Allow"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            }
            
            for url in urls {
                guard
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                    components.path.isEmpty
                else {
                    continue
                }
                    
                let name = (components.queryItems?.first { $0.name == "name" })?.value
                switch (components.host, name) {
                case ("execute-action", _):
                    let action = (WindowAction.active.first { windowAction in
                        if let aliasName = windowAction.aliasName, getUrlName(aliasName) == name {
                            return true
                        }
                        return getUrlName(windowAction.name) == name
                    })
                    action?.postUrl()
                case ("execute-task", "ignore-app"):
                    let bundleId = extractBundleIdParameter(fromComponents: components)
                    guard isValidParameter(bundleId: bundleId), let bundleId else { continue }
                    guard confirmExecuteTask(action: "ignore-app", bundleId: bundleId) else { continue }
                    self.applicationToggle.disableApp(appBundleId: bundleId)
                case ("execute-task", "unignore-app"):
                    let bundleId = extractBundleIdParameter(fromComponents: components)
                    guard isValidParameter(bundleId: bundleId), let bundleId else { continue }
                    guard confirmExecuteTask(action: "unignore-app", bundleId: bundleId) else { continue }
                    self.applicationToggle.enableApp(appBundleId: bundleId)
                default:
                    continue
                }
            }
        }
    }
}

extension AppDelegate {
    func configureProgrammaticMenusIfNeeded(for app: NSApplication) {
        guard mainStatusMenu == nil else { return }

        if app.mainMenu == nil {
            let mainMenu = NSMenu(title: "Main Menu")

            let appMenuItem = NSMenuItem(title: "Rectangle", action: nil, keyEquivalent: "")
            let appMenu = NSMenu(title: "Rectangle")
            appMenu.addItem(withTitle: String(localized: "About Rectangle"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            appMenu.addItem(.separator())
            let prefsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openPreferences(_:)), keyEquivalent: ",")
            prefsItem.target = self
            appMenu.addItem(prefsItem)
            let appUpdateItem = NSMenuItem(title: "Cập nhật qua GitHub…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            appUpdateItem.target = self
            appMenu.addItem(appUpdateItem)
            appMenu.addItem(.separator())
            appMenu.addItem(withTitle: String(localized: "Hide Rectangle"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let hideOthers = NSMenuItem(title: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            appMenu.addItem(hideOthers)
            appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            appMenu.addItem(.separator())
            appMenu.addItem(withTitle: String(localized: "Quit Rectangle"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appMenuItem.submenu = appMenu
            mainMenu.addItem(appMenuItem)

            let fileMenuItem = NSMenuItem(title: String(localized: "File"), action: nil, keyEquivalent: "")
            let fileMenu = NSMenu(title: String(localized: "File"))
            fileMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            fileMenuItem.submenu = fileMenu
            mainMenu.addItem(fileMenuItem)

            let editMenuItem = NSMenuItem(title: String(localized: "Edit"), action: nil, keyEquivalent: "")
            let editMenu = NSMenu(title: String(localized: "Edit"))
            editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
            editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
            editMenu.addItem(.separator())
            editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            editMenuItem.submenu = editMenu
            mainMenu.addItem(editMenuItem)

            let windowMenuItem = NSMenuItem(title: String(localized: "Window"), action: nil, keyEquivalent: "")
            let windowMenu = NSMenu(title: String(localized: "Window"))
            windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            windowMenuItem.submenu = windowMenu
            app.windowsMenu = windowMenu
            mainMenu.addItem(windowMenuItem)

            app.mainMenu = mainMenu
        }

        let statusMenu = NSMenu()
        let ignoreItem = NSMenuItem(title: String(localized: "Ignore frontmost.app"), action: #selector(ignoreFrontMostApp(_:)), keyEquivalent: "")
        ignoreItem.target = self
        statusMenu.addItem(ignoreItem)
        statusMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openPreferences(_:)), keyEquivalent: "")
        settingsItem.target = self
        statusMenu.addItem(settingsItem)

        let launchAtLoginItem = NSMenuItem(title: "Khởi động cùng macOS", action: #selector(toggleLaunchOnLoginMenuItem(_:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        statusMenu.addItem(launchAtLoginItem)

        let showOnLaunchItem = NSMenuItem(title: "Bật bảng cài đặt khi khởi động", action: #selector(toggleShowSettingsOnLaunchMenuItem(_:)), keyEquivalent: "")
        showOnLaunchItem.target = self
        statusMenu.addItem(showOnLaunchItem)
        statusMenu.addItem(.separator())

        let aboutItem = NSMenuItem(title: String(localized: "About"), action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        statusMenu.addItem(aboutItem)

        let loggingItem = NSMenuItem(title: String(localized: "View Logging…"), action: #selector(viewLogging(_:)), keyEquivalent: "")
        loggingItem.target = self
        loggingItem.isAlternate = true
        loggingItem.keyEquivalentModifierMask = .option
        statusMenu.addItem(loggingItem)

        let updatesItem = NSMenuItem(title: "Cập nhật qua GitHub…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = self
        statusMenu.addItem(updatesItem)

        let githubItem = NSMenuItem(title: "GitHub Releases ↗", action: #selector(openGitHubReleases(_:)), keyEquivalent: "")
        githubItem.target = self
        statusMenu.addItem(githubItem)

        let quitItem = NSMenuItem(title: String(localized: "Quit Rectangle"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = app
        statusMenu.addItem(quitItem)

        let unauthMenu = NSMenu()
        unauthMenu.addItem(withTitle: String(localized: "Not Authorized to Control Your Computer"), action: nil, keyEquivalent: "")
        let authItem = NSMenuItem(title: String(localized: "Authorize…"), action: #selector(authorizeAccessibility(_:)), keyEquivalent: "")
        authItem.target = self
        unauthMenu.addItem(authItem)
        unauthMenu.addItem(.separator())
        let unauthUpdateItem = NSMenuItem(title: "Cập nhật qua GitHub…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        unauthUpdateItem.target = self
        unauthMenu.addItem(unauthUpdateItem)
        let unauthAboutItem = NSMenuItem(title: String(localized: "About"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        unauthAboutItem.target = app
        unauthMenu.addItem(unauthAboutItem)
        let unauthQuitItem = NSMenuItem(title: String(localized: "Quit Rectangle"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        unauthQuitItem.target = app
        unauthMenu.addItem(unauthQuitItem)

        retainedMenus = [statusMenu, unauthMenu]
        mainStatusMenu = statusMenu
        unauthorizedMenu = unauthMenu
        ignoreMenuItem = ignoreItem
        viewLoggingMenuItem = loggingItem
        updatesMenuItem = updatesItem
        quitMenuItem = quitItem
        launchOnLoginMenuItem = launchAtLoginItem
        showSettingsOnLaunchMenuItem = showOnLaunchItem
    }

    private func terminateOtherRunningInstances() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) where running.processIdentifier != currentPid {
            if !running.terminate() {
                running.forceTerminate()
            }
        }
    }
}
