/// AppSettingsView.swift

import AppKit
import SwiftUI

class AppSettingsViewController: NSViewController {
    private var hostingController: NSHostingController<AppSettingsView>!

    override func viewDidLoad() {
        super.viewDidLoad()

        let swiftUIView = AppSettingsView()
        hostingController = NSHostingController(rootView: swiftUIView)
        
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

struct AppSettingsView: View {
    @State private var viewModel = AppSettingsViewModel()
    @State private var startup = StartupPreferencesManager.shared
    @State private var updater = GitHubSoftwareUpdater.shared

    var body: some View {
        Form {
            // MARK: - App & Updates
            Section {
                Toggle("Khởi động cùng macOS (Launch on login)", isOn: $startup.launchOnLogin)
                Toggle("Bật bảng này khi khởi động", isOn: $startup.showSettingsOnLaunch)
                Toggle("Hide menu bar icon", isOn: $viewModel.hideMenuBarIcon)

                if viewModel.hideMenuBarIcon {
                    Text("When the menu bar icon is hidden, relaunch Rectangle from Finder to open")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section {
                HStack(spacing: 10) {
                    if let newTag = updater.availableReleaseTag {
                        Button {
                            updater.checkForUpdates()
                        } label: {
                            Label("Cập nhật qua GitHub (\(newTag))…", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.isInstallingUpdate)
                    } else {
                        Button {
                            updater.checkForUpdates()
                        } label: {
                            Label("Cập nhật qua GitHub…", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(updater.isChecking || updater.isInstallingUpdate)
                    }

                    if updater.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Text(viewModel.versionString)
                        .foregroundColor(.secondary)
                        .font(.callout.monospacedDigit())
                }

                if !updater.statusMessage.isEmpty {
                    Text(updater.statusMessage)
                        .font(.caption)
                        .foregroundColor(updater.availableReleaseTag != nil ? .accentColor : .secondary)
                }

                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)

                HStack(spacing: 14) {
                    Link("GitHub Releases ↗", destination: GitHubSoftwareUpdater.releasesPageURL)
                        .font(.caption)
                    Link("Mã nguồn GitHub (hungmtuci/Rectangle) ↗", destination: GitHubSoftwareUpdater.repoHomeURL)
                        .font(.caption)
                    Spacer()
                }
            }

            Section {
                Toggle("Remove keyboard shortcut restrictions", isOn: $viewModel.allowAnyShortcut)
            }

            // MARK: - Footer Actions
            Section {
                HStack {
                    Button {
                        viewModel.importConfig()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    
                    Button {
                        viewModel.exportConfig()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }

                Button("Restore Default Shortcuts & Snap Areas") {
                    viewModel.restoreDefaults()
                }
                
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
    }
}
