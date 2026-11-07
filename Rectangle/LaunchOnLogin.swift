/// LaunchOnLogin.swift

import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import os.log

@available(macOS 13.0, *)
public enum LaunchOnLogin {
    public static var isEnabled: Bool {
        get {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        set {
            do {
                let status = SMAppService.mainApp.status
                if newValue {
                    if status == .enabled {
                        try? SMAppService.mainApp.unregister()
                    }
                    try SMAppService.mainApp.register()
                } else if status == .enabled || status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                os_log("Failed to \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            }
        }
    }
}

/// Shared observable state for "Khởi động cùng macOS" and "Bật bảng này khi khởi động",
/// keeping the Settings window bar, App Settings tab, and Menu Bar items synchronized.
@Observable
@MainActor
final class StartupPreferencesManager {
    static let shared = StartupPreferencesManager()

    var launchOnLogin: Bool {
        didSet {
            guard !isSyncingInternally, launchOnLogin != oldValue else { return }
            Defaults.launchOnLogin.enabled = launchOnLogin
            LaunchOnLogin.isEnabled = launchOnLogin
        }
    }

    var showSettingsOnLaunch: Bool {
        didSet {
            guard !isSyncingInternally, showSettingsOnLaunch != oldValue else { return }
            Defaults.showSettingsOnLaunch.enabled = showSettingsOnLaunch
        }
    }

    private var isSyncingInternally = false
    private var notificationObservers: [NSObjectProtocol] = []

    private init() {
        let initialLaunch = Defaults.launchOnLogin.enabled || LaunchOnLogin.isEnabled
        self.launchOnLogin = initialLaunch
        self.showSettingsOnLaunch = Defaults.showSettingsOnLaunch.enabled

        notificationObservers.append(Notification.Name.appWillBecomeActive.onPost { [weak self] _ in
            Task { @MainActor in
                self?.refreshFromSystem()
            }
        })
        notificationObservers.append(Notification.Name.configImported.onPost { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromDefaults()
            }
        })
    }

    func syncOnAppLaunch() {
        if Defaults.launchOnLogin.enabled && !LaunchOnLogin.isEnabled {
            LaunchOnLogin.isEnabled = true
        }
        refreshFromSystem()
    }

    func refreshFromSystem() {
        isSyncingInternally = true
        defer { isSyncingInternally = false }
        let systemRegistered = LaunchOnLogin.isEnabled
        Defaults.launchOnLogin.enabled = systemRegistered
        self.launchOnLogin = systemRegistered
        self.showSettingsOnLaunch = Defaults.showSettingsOnLaunch.enabled
    }

    func reloadFromDefaults() {
        isSyncingInternally = true
        defer { isSyncingInternally = false }
        LaunchOnLogin.isEnabled = Defaults.launchOnLogin.enabled
        self.launchOnLogin = Defaults.launchOnLogin.enabled
        self.showSettingsOnLaunch = Defaults.showSettingsOnLaunch.enabled
    }
}

struct SettingsStartupOptionsBarView: View {
    @State private var startup = StartupPreferencesManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Toggle(isOn: $startup.launchOnLogin) {
                    Label("Khởi động cùng macOS", systemImage: "power.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .help("Tự động khởi chạy Rectangle ngay khi đăng nhập vào macOS")

                Divider()
                    .frame(height: 13)

                Toggle(isOn: $startup.showSettingsOnLaunch) {
                    Label("Bật bảng này khi khởi động", systemImage: "macwindow.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .help("Tự động mở bảng cài đặt Rectangle ngay khi ứng dụng khởi động")

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 32)

            Divider()
                .opacity(0.6)
        }
    }
}
