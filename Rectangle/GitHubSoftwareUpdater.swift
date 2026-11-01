/// GitHubSoftwareUpdater.swift

import AppKit
import Foundation
import Observation
import SwiftUI

private struct GitHubReleaseAssetDTO: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

private struct GitHubReleaseDTO: Decodable, Sendable {
    let tagName: String
    let htmlURL: String
    let name: String?
    let body: String?
    let draft: Bool?
    let publishedAt: String?
    let assets: [GitHubReleaseAssetDTO]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case body
        case draft
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubTagDTO: Decodable, Sendable {
    let name: String
}

/// Native macOS GitHub Releases Auto-Updater for `https://github.com/hungmtuci/Rectangle`.
/// Supports silent background version checks, a native macOS update window with release notes,
/// live download progress (.zip & .dmg), automatic Gatekeeper quarantine removal (`xattr -cr`),
/// code-signature verification, atomic `.app` replacement, and automatic relaunch.
@Observable
@MainActor
final class GitHubSoftwareUpdater {
    static let shared = GitHubSoftwareUpdater()

    enum AssetKind: Equatable, Sendable {
        case zip
        case dmg
    }

    struct ResolvedRelease: Equatable, Sendable {
        let rawTag: String
        let cleanVersion: String
        let title: String
        let releaseNotes: String
        let pageURL: URL
        let downloadURL: URL?
        let assetName: String?
        let assetSize: Int64
        let assetKind: AssetKind
    }

    nonisolated static let githubOwner = "hungmtuci"
    nonisolated static let githubRepo = "Rectangle"
    nonisolated static let expectedBundleId = "com.knollsoft.Rectangle"

    static let repoHomeURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)")!
    static let releasesPageURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases")!
    private static let releasesListAPIURL = URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases?per_page=5")!
    private static let tagsListAPIURL = URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/tags?per_page=10")!
    private static let latestReleaseRedirectURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases/latest")!
    private static let lastCheckDefaultsKey = "githubUpdaterLastCheckedAt"

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter
    }()

    var isChecking: Bool = false
    var isInstallingUpdate: Bool = false
    var downloadProgress: Double = 0.0
    var statusMessage: String = ""
    var errorMessage: String?
    var availableReleaseTag: String?

    fileprivate var pendingRelease: ResolvedRelease?
    private var cachedReleasesETag: String?
    private var cachedResolvedRelease: ResolvedRelease?
    private var updateWindow: NSWindow?
    private var activeDownloadTask: Task<Void, Never>?

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            Defaults.SUEnableAutomaticChecks.enabled = automaticallyChecksForUpdates
            if automaticallyChecksForUpdates {
                checkSilentlyIfDue()
            }
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Defaults.SUEnableAutomaticChecks.key) == nil {
            Defaults.SUEnableAutomaticChecks.enabled = true
        }
        self.automaticallyChecksForUpdates = Defaults.SUEnableAutomaticChecks.enabled
    }

    var currentVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "2.1.2-custom"
    }

    var currentBuildString: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "114"
    }

    func openRepositoryPage() {
        NSWorkspace.shared.open(Self.repoHomeURL)
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(Self.releasesPageURL)
    }

    func checkSilentlyIfDue() {
        guard automaticallyChecksForUpdates else { return }
        let lastEpoch = UserDefaults.standard.double(forKey: Self.lastCheckDefaultsKey)
        if lastEpoch > 0 {
            let elapsed = Date().timeIntervalSince1970 - lastEpoch
            if elapsed < 43_200 {
                return
            }
        }
        guard !isChecking, !isInstallingUpdate else { return }
        Task { @MainActor in
            isChecking = true
            defer { isChecking = false }
            await performUpdateCheck(userInitiated: false)
        }
    }

    func checkForUpdates() {
        if isInstallingUpdate {
            showUpdateWindow()
            return
        }
        guard !isChecking else {
            if pendingRelease != nil {
                showUpdateWindow()
            }
            return
        }
        isChecking = true
        errorMessage = nil
        statusMessage = "Đang kiểm tra bản cập nhật trên GitHub…"
        Task { @MainActor in
            defer { isChecking = false }
            await performUpdateCheck(userInitiated: true)
        }
    }

    // MARK: - GitHub API & Redirect Discovery

    private func performUpdateCheck(userInitiated: Bool) async {
        let localVersion = currentVersionString

        do {
            let discovered = try await fetchNewestReleaseOrTag()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckDefaultsKey)

            guard let latest = discovered else {
                availableReleaseTag = nil
                pendingRelease = nil
                syncAppDelegateUpdateFlag(false)
                statusMessage = "Đang dùng phiên bản mới nhất (v\(localVersion))."
                if userInitiated {
                    presentUpToDateAlert(localVersion: localVersion, remoteTag: nil, url: Self.releasesPageURL)
                }
                return
            }

            if Self.isRemoteVersionNewer(latest.rawTag, than: localVersion) {
                pendingRelease = latest
                availableReleaseTag = latest.rawTag
                syncAppDelegateUpdateFlag(true)
                statusMessage = "Đã có bản cập nhật mới trên GitHub: \(latest.rawTag)"
                if userInitiated {
                    showUpdateWindow()
                }
            } else {
                pendingRelease = nil
                availableReleaseTag = nil
                syncAppDelegateUpdateFlag(false)
                statusMessage = "Đang dùng bản mới nhất (v\(localVersion) • GitHub: \(latest.rawTag))."
                if userInitiated {
                    presentUpToDateAlert(localVersion: localVersion, remoteTag: latest.rawTag, url: latest.pageURL)
                }
            }
        } catch {
            statusMessage = "Không thể kết nối GitHub: \(error.localizedDescription)"
            if userInitiated {
                presentConnectionErrorAlert(error: error)
            }
        }
    }

    private func syncAppDelegateUpdateFlag(_ available: Bool) {
        guard let delegate = NSApp?.delegate as? AppDelegate else { return }
        if delegate.hasPendingUpdate != available {
            delegate.hasPendingUpdate = available
        }
        delegate.syncUpdateMenuItemTitle()
    }

    private func fetchNewestReleaseOrTag() async throws -> ResolvedRelease? {
        let userAgent = "Rectangle-GitHub-Updater/\(currentVersionString)"

        let relResult = try await fetchGitHubData(
            url: Self.releasesListAPIURL,
            userAgent: userAgent,
            ifNoneMatch: cachedResolvedRelease != nil ? cachedReleasesETag : nil
        )

        if relResult.statusCode == 304, let cachedResolvedRelease {
            return cachedResolvedRelease
        }

        if relResult.statusCode == 403 || relResult.statusCode == 429 {
            return await fetchViaHTMLRedirectFallback()
        }

        var releases: [GitHubReleaseDTO] = []
        if (200...299).contains(relResult.statusCode), let data = relResult.data {
            releases = ((try? JSONDecoder().decode([GitHubReleaseDTO].self, from: data)) ?? [])
                .filter { $0.draft != true }
        }

        var bestRelease: GitHubReleaseDTO?
        for rel in releases {
            guard !Self.cleanVersionString(rel.tagName).isEmpty else { continue }
            if let existing = bestRelease {
                if Self.isRemoteVersionNewer(rel.tagName, than: existing.tagName) {
                    bestRelease = rel
                }
            } else {
                bestRelease = rel
            }
        }

        if let rel = bestRelease {
            let cleanVer = Self.cleanVersionString(rel.tagName)
            let resolvedAsset = await resolveDownloadAsset(from: rel.assets ?? [], rawTag: rel.tagName, cleanVersion: cleanVer)
            let pageURL = URL(string: rel.htmlURL) ?? Self.releasesPageURL
            let title = (rel.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Rectangle \(rel.tagName)"
            let notes = (rel.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = ResolvedRelease(
                rawTag: rel.tagName,
                cleanVersion: cleanVer,
                title: title,
                releaseNotes: notes,
                pageURL: pageURL,
                downloadURL: resolvedAsset.url,
                assetName: resolvedAsset.name,
                assetSize: resolvedAsset.size,
                assetKind: resolvedAsset.kind
            )
            if let etag = relResult.etag {
                cachedReleasesETag = etag
                cachedResolvedRelease = resolved
            }
            return resolved
        }

        // Only query /tags as a fallback when no published GitHub Release exists yet.
        let tagResult = try await fetchGitHubData(url: Self.tagsListAPIURL, userAgent: userAgent, ifNoneMatch: nil)
        if tagResult.statusCode == 403 || tagResult.statusCode == 429 {
            return await fetchViaHTMLRedirectFallback()
        }
        if relResult.statusCode == 404 && tagResult.statusCode == 404 {
            return nil
        }

        var tags: [GitHubTagDTO] = []
        if (200...299).contains(tagResult.statusCode), let data = tagResult.data {
            tags = (try? JSONDecoder().decode([GitHubTagDTO].self, from: data)) ?? []
        }

        var bestTagName: String?
        for tag in tags {
            guard !Self.cleanVersionString(tag.name).isEmpty else { continue }
            if let existingTag = bestTagName {
                if Self.isRemoteVersionNewer(tag.name, than: existingTag) {
                    bestTagName = tag.name
                }
            } else {
                bestTagName = tag.name
            }
        }

        if let rawTag = bestTagName {
            let cleanVer = Self.cleanVersionString(rawTag)
            let resolvedAsset = await resolveDownloadAsset(from: [], rawTag: rawTag, cleanVersion: cleanVer)
            let pageURL = URL(string: "https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/tag/\(rawTag)") ?? Self.releasesPageURL
            return ResolvedRelease(
                rawTag: rawTag,
                cleanVersion: cleanVer,
                title: "Rectangle \(rawTag)",
                releaseNotes: "",
                pageURL: pageURL,
                downloadURL: resolvedAsset.url,
                assetName: resolvedAsset.name,
                assetSize: resolvedAsset.size,
                assetKind: resolvedAsset.kind
            )
        }

        return nil
    }

    private func fetchGitHubData(
        url: URL,
        userAgent: String,
        ifNoneMatch: String?
    ) async throws -> (statusCode: Int, data: Data?, etag: String?) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            req.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let etag = http?.value(forHTTPHeaderField: "ETag")
        return (code, data, etag)
    }

    private func fetchViaHTMLRedirectFallback() async -> ResolvedRelease? {
        var req = URLRequest(url: Self.latestReleaseRedirectURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let finalURL = response.url else {
            return nil
        }

        let parts = finalURL.pathComponents
        guard let tagIdx = parts.firstIndex(of: "tag"), tagIdx + 1 < parts.count else {
            return nil
        }
        let rawTag = parts[tagIdx + 1]
        let cleanVer = Self.cleanVersionString(rawTag)
        guard !cleanVer.isEmpty else { return nil }

        let resolvedAsset = await resolveDownloadAsset(from: [], rawTag: rawTag, cleanVersion: cleanVer)
        return ResolvedRelease(
            rawTag: rawTag,
            cleanVersion: cleanVer,
            title: "Rectangle \(rawTag)",
            releaseNotes: "",
            pageURL: finalURL,
            downloadURL: resolvedAsset.url,
            assetName: resolvedAsset.name,
            assetSize: resolvedAsset.size,
            assetKind: resolvedAsset.kind
        )
    }

    private func resolveDownloadAsset(
        from assets: [GitHubReleaseAssetDTO],
        rawTag: String,
        cleanVersion: String
    ) async -> (url: URL?, name: String?, size: Int64, kind: AssetKind) {
        if let namedZip = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("rectangle") }),
           let url = URL(string: namedZip.browserDownloadURL) {
            return (url, namedZip.name, namedZip.size ?? 0, .zip)
        }
        if let anyZip = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
           let url = URL(string: anyZip.browserDownloadURL) {
            return (url, anyZip.name, anyZip.size ?? 0, .zip)
        }
        if let anyDmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
           let url = URL(string: anyDmg.browserDownloadURL) {
            return (url, anyDmg.name, anyDmg.size ?? 0, .dmg)
        }

        let cleanRawNoV = rawTag.hasPrefix("v") || rawTag.hasPrefix("V") ? String(rawTag.dropFirst()) : rawTag
        let candidates: [(String, String, AssetKind)] = [
            ("https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/download/\(rawTag)/Rectangle-v\(cleanRawNoV)-macOS.zip", "Rectangle-v\(cleanRawNoV)-macOS.zip", .zip),
            ("https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/download/\(rawTag)/Rectangle-v\(cleanVersion)-macOS.zip", "Rectangle-v\(cleanVersion)-macOS.zip", .zip),
            ("https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/download/\(rawTag)/Rectangle.zip", "Rectangle.zip", .zip),
            ("https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/download/\(rawTag)/Rectangle.dmg", "Rectangle.dmg", .dmg)
        ]

        for (urlStr, fileName, kind) in candidates {
            guard let probeURL = URL(string: urlStr) else { continue }
            var headReq = URLRequest(url: probeURL)
            headReq.httpMethod = "HEAD"
            headReq.timeoutInterval = 6
            if let (_, resp) = try? await URLSession.shared.data(for: headReq),
               let http = resp as? HTTPURLResponse,
               (200...399).contains(http.statusCode) {
                return (probeURL, fileName, resp.expectedContentLength, kind)
            }
        }

        return (nil, nil, 0, .zip)
    }

    // MARK: - Update Window & Alerts

    func showUpdateWindow() {
        guard pendingRelease != nil else { return }

        if let existing = updateWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: GitHubUpdateSheetView(updater: self))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Cập nhật Rectangle qua GitHub"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 540, height: 380))
        win.isReleasedWhenClosed = false
        win.center()
        win.level = .floating

        self.updateWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func dismissUpdateWindow() {
        if isInstallingUpdate {
            activeDownloadTask?.cancel()
            activeDownloadTask = nil
            isInstallingUpdate = false
        }
        updateWindow?.orderOut(nil)
    }

    private func presentUpToDateAlert(localVersion: String, remoteTag: String?, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rectangle đã ở phiên bản mới nhất"
        if let remoteTag {
            alert.informativeText = "Phiên bản hiện tại (v\(localVersion)) khớp với bản phát hành mới nhất trên GitHub (\(Self.githubOwner)/\(Self.githubRepo) • \(remoteTag))."
        } else {
            alert.informativeText = "Bạn đang sử dụng phiên bản v\(localVersion) (\(Self.githubOwner)/\(Self.githubRepo))."
        }
        alert.addButton(withTitle: "Đóng")
        alert.addButton(withTitle: "Xem trên GitHub ↗")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentConnectionErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Không thể kiểm tra cập nhật từ GitHub"
        alert.informativeText = "\(error.localizedDescription)\n\nBạn có thể mở trực tiếp trang GitHub Releases để kiểm tra thủ công."
        alert.addButton(withTitle: "Mở GitHub Releases ↗")
        alert.addButton(withTitle: "Đóng")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPageURL)
        }
    }

    // MARK: - 1-Click Download, Verification & Atomic Replacement

    func startDownloadAndInstall() {
        guard let release = pendingRelease, !isInstallingUpdate else { return }

        guard let assetURL = release.downloadURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        isInstallingUpdate = true
        errorMessage = nil
        downloadProgress = 0.02
        let packageLabel = release.assetName ?? "Rectangle.\(release.assetKind == .dmg ? "dmg" : "zip")"
        statusMessage = "Đang kết nối tải gói \(packageLabel)…"

        let progressHandler = Self.makeProgressHandler(for: self)
        activeDownloadTask = Task { @MainActor [self] in
            let stageRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("rectangle_autoupdate_\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
                let archivePath = stageRoot.appendingPathComponent(packageLabel)

                var req = URLRequest(url: assetURL)
                req.setValue("Rectangle-GitHub-Updater/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 180

                try await Self.downloadArchiveToFile(
                    request: req,
                    destinationURL: archivePath,
                    fallbackExpectedSize: release.assetSize,
                    onProgress: progressHandler
                )

                downloadProgress = 0.90
                statusMessage = "Đang giải nén & xác thực gói ứng dụng…"

                let unpackedDir = stageRoot.appendingPathComponent("unpacked", isDirectory: true)
                try FileManager.default.createDirectory(at: unpackedDir, withIntermediateDirectories: true)

                let extractedApp: URL
                switch release.assetKind {
                case .zip:
                    try await Self.runSubprocess(
                        executable: "/usr/bin/ditto",
                        arguments: ["-x", "-k", archivePath.path, unpackedDir.path]
                    )
                    guard let found = Self.findValidAppBundle(in: unpackedDir) else {
                        throw NSError(domain: "RectangleGitHubUpdater", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "Không tìm thấy gói Rectangle.app hợp lệ bên trong tệp nén."
                        ])
                    }
                    extractedApp = found

                case .dmg:
                    extractedApp = try await Self.extractAppFromDmg(
                        dmgPath: archivePath.path,
                        unpackedDir: unpackedDir,
                        stageRoot: stageRoot
                    )
                }

                _ = try? await Self.runSubprocess(
                    executable: "/usr/bin/xattr",
                    arguments: ["-cr", extractedApp.path]
                )

                try await Self.runSubprocess(
                    executable: "/usr/bin/codesign",
                    arguments: ["--verify", "--deep", extractedApp.path]
                )

                downloadProgress = 0.98
                statusMessage = "Đang thay thế bản mới & tự động khởi động lại…"
                try await Task.sleep(for: .milliseconds(250))

                try launchDetachedInstallerAndQuit(
                    extractedAppURL: extractedApp,
                    stageRootURL: stageRoot
                )
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: stageRoot)
                isInstallingUpdate = false
                downloadProgress = 0
                statusMessage = "Đã huỷ tải bản cập nhật."
            } catch {
                try? FileManager.default.removeItem(at: stageRoot)
                isInstallingUpdate = false
                downloadProgress = 0
                errorMessage = error.localizedDescription
                statusMessage = "Cập nhật thất bại."
            }
        }
    }

    private func updateDownloadProgress(received: Int64, expected: Int64) {
        let recStr = Self.byteFormatter.string(fromByteCount: received)

        if expected > 0 {
            let ratio = min(max(Double(received) / Double(expected), 0.02), 0.88)
            downloadProgress = ratio
            let expStr = Self.byteFormatter.string(fromByteCount: expected)
            let pct = Int((Double(received) / Double(expected)) * 100)
            statusMessage = "Đang tải về… \(min(pct, 100))% (\(recStr) / \(expStr))"
        } else {
            downloadProgress = 0.5
            statusMessage = "Đang tải về… (\(recStr))"
        }
    }

    private func launchDetachedInstallerAndQuit(extractedAppURL: URL, stageRootURL: URL) throws {
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let primaryTargetPath: String
        if currentBundleURL.pathExtension == "app" && !currentBundleURL.path.hasPrefix("/Volumes/") {
            primaryTargetPath = currentBundleURL.path
        } else {
            primaryTargetPath = "/Applications/Rectangle.app"
        }

        let secondaryApplicationsPath: String = {
            let stdApps = "/Applications/Rectangle.app"
            if primaryTargetPath != stdApps && FileManager.default.fileExists(atPath: stdApps) {
                return stdApps
            }
            return ""
        }()

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let script = """
        OLD_PID="$1"
        SRC_APP="$2"
        DST_APP="$3"
        DST_SECONDARY="$4"
        STAGE_DIR="$5"

        i=0
        while kill -0 "$OLD_PID" 2>/dev/null && [ $i -lt 60 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        DST_PARENT="$(dirname "$DST_APP")"
        if [ -w "$DST_PARENT" ] && { [ ! -e "$DST_APP" ] || [ -w "$DST_APP" ]; } && rm -rf "$DST_APP" 2>/dev/null && /usr/bin/ditto --norsrc --noextattr "$SRC_APP" "$DST_APP" 2>/dev/null; then
            /usr/bin/xattr -cr "$DST_APP" 2>/dev/null || true
        else
            /usr/bin/osascript -e "do shell script \\"rm -rf '$DST_APP' && /usr/bin/ditto --norsrc --noextattr '$SRC_APP' '$DST_APP' && /usr/bin/xattr -cr '$DST_APP'\\" with administrator privileges" 2>/dev/null || true
        fi

        if [ -n "$DST_SECONDARY" ] && [ -d "$DST_SECONDARY" ]; then
            rm -rf "$DST_SECONDARY" 2>/dev/null && /usr/bin/ditto --norsrc --noextattr "$SRC_APP" "$DST_SECONDARY" 2>/dev/null || true
            /usr/bin/xattr -cr "$DST_SECONDARY" 2>/dev/null || true
        fi

        /usr/bin/open "$DST_APP"
        rm -rf "$STAGE_DIR"
        """

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        launcher.arguments = [
            "/bin/sh",
            "-c",
            script,
            "rectangle-github-updater",
            "\(currentPID)",
            extractedAppURL.path,
            primaryTargetPath,
            secondaryApplicationsPath,
            stageRootURL.path
        ]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()

        NSApp.terminate(nil)
    }

    // MARK: - Subprocess, Kernel-Buffered Download & Bundle Helpers

    private nonisolated static func downloadArchiveToFile(
        request: URLRequest,
        destinationURL: URL,
        fallbackExpectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let delegate = ArchiveDownloadDelegate(
            destinationURL: destinationURL,
            fallbackExpectedSize: fallbackExpectedSize,
            onProgress: onProgress
        )
        let queue = OperationQueue()
        queue.name = "com.knollsoft.Rectangle.githubDownload"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
        let task = session.downloadTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(task: task, session: session, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    private nonisolated static func extractAppFromDmg(
        dmgPath: String,
        unpackedDir: URL,
        stageRoot: URL
    ) async throws -> URL {
        let mountPoint = stageRoot.appendingPathComponent("dmg_mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try await runSubprocess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", dmgPath, "-mountpoint", mountPoint.path, "-nobrowse", "-readonly", "-quiet"]
        )
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
        }

        guard let mountedApp = findValidAppBundle(in: mountPoint) else {
            throw NSError(domain: "RectangleGitHubUpdater", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Không tìm thấy Rectangle.app hợp lệ bên trong tệp .dmg."
            ])
        }

        let copiedApp = unpackedDir.appendingPathComponent("Rectangle.app", isDirectory: true)
        try await runSubprocess(
            executable: "/usr/bin/ditto",
            arguments: ["--norsrc", "--noextattr", mountedApp.path, copiedApp.path]
        )
        guard isValidAppBundle(copiedApp) else {
            throw NSError(domain: "RectangleGitHubUpdater", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Không thể sao chép Rectangle.app từ bộ cài .dmg."
            ])
        }
        return copiedApp
    }

    private nonisolated static func isValidAppBundle(_ appURL: URL) -> Bool {
        let fm = FileManager.default
        let execPath = appURL.appendingPathComponent("Contents/MacOS/Rectangle").path
        guard fm.isExecutableFile(atPath: execPath) else { return false }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
           let bundleId = dict["CFBundleIdentifier"] as? String {
            return bundleId == expectedBundleId
        }
        return false
    }

    private nonisolated static func findValidAppBundle(in root: URL, maxDepth: Int = 2) -> URL? {
        let direct = root.appendingPathComponent("Rectangle.app")
        if isValidAppBundle(direct) {
            return direct
        }
        guard maxDepth > 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        for entry in entries {
            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }
            if entry.pathExtension.lowercased() == "app" {
                if isValidAppBundle(entry) {
                    return entry
                }
            } else if vals?.isDirectory == true {
                if let nested = findValidAppBundle(in: entry, maxDepth: maxDepth - 1) {
                    return nested
                }
            }
        }
        return nil
    }

    private nonisolated static func runSubprocess(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let errPipe = Pipe()
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(throwing: NSError(
                            domain: "RectangleGitHubUpdater",
                            code: Int(proc.terminationStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey: msg.isEmpty
                                    ? "Lệnh \(executable) thất bại (mã \(proc.terminationStatus))."
                                    : msg
                            ]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Semantic Version Helpers

    nonisolated static func cleanVersionString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        if let dashIndex = s.firstIndex(of: "-") {
            s = String(s[..<dashIndex])
        }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return "" }
        return parts.map(String.init).joined(separator: ".")
    }

    private nonisolated static func makeProgressHandler(
        for updater: GitHubSoftwareUpdater
    ) -> @Sendable (Int64, Int64) -> Void {
        { [weak updater] received, expected in
            Task { @MainActor in
                updater?.updateDownloadProgress(received: received, expected: expected)
            }
        }
    }

    nonisolated static func isRemoteVersionNewer(_ remoteTag: String, than localVersion: String) -> Bool {
        let remoteParts = cleanVersionString(remoteTag).split(separator: ".").compactMap { Int($0) }
        let localParts = cleanVersionString(localVersion).split(separator: ".").compactMap { Int($0) }
        guard !remoteParts.isEmpty else { return false }
        let count = max(remoteParts.count, localParts.count)
        for idx in 0..<count {
            let rVal = idx < remoteParts.count ? remoteParts[idx] : 0
            let lVal = idx < localParts.count ? localParts[idx] : 0
            if rVal != lVal {
                return rVal > lVal
            }
        }
        return false
    }
}

private final class ArchiveDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let fallbackExpectedSize: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var moveError: Error?
    private var didMoveFile = false
    private var lastProgressReportTime: TimeInterval = 0

    init(
        destinationURL: URL,
        fallbackExpectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destinationURL = destinationURL
        self.fallbackExpectedSize = fallbackExpectedSize
        self.onProgress = onProgress
    }

    func start(
        task: URLSessionDownloadTask,
        session: URLSession,
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        self.continuation = continuation
        self.session = session
        lock.unlock()
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldReport = (now - lastProgressReportTime) >= 0.065
        if shouldReport {
            lastProgressReportTime = now
        }
        lock.unlock()

        if shouldReport {
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackExpectedSize
            onProgress(totalBytesWritten, expected)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            lock.lock()
            moveError = NSError(domain: "RectangleGitHubUpdater", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Máy chủ GitHub trả về mã lỗi HTTP \(http.statusCode)."
            ])
            lock.unlock()
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            let finalSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? fallbackExpectedSize
            onProgress(finalSize, max(finalSize, fallbackExpectedSize))
            lock.lock()
            didMoveFile = true
            lock.unlock()
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let storedMoveError = moveError
        let moved = didMoveFile
        let activeSession = self.session
        self.session = nil
        lock.unlock()

        activeSession?.finishTasksAndInvalidate()
        guard let cont else { return }

        if let error {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                cont.resume(throwing: CancellationError())
            } else {
                cont.resume(throwing: error)
            }
            return
        }
        if let storedMoveError {
            cont.resume(throwing: storedMoveError)
            return
        }
        if !moved {
            cont.resume(throwing: NSError(domain: "RectangleGitHubUpdater", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Không nhận được dữ liệu tệp cập nhật từ GitHub."
            ]))
            return
        }
        cont.resume()
    }
}

// MARK: - Native macOS GitHub Update Window View

private struct GitHubUpdateSheetView: View {
    @Bindable var updater: GitHubSoftwareUpdater

    private var releaseTitle: String {
        updater.pendingRelease?.title ?? "Rectangle"
    }

    private var releaseNotes: String {
        let raw = updater.pendingRelease?.releaseNotes ?? ""
        return raw.isEmpty ? "Cải tiến bố cục cửa sổ, bảng Grid nút xanh và hiệu năng tổng thể." : raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Có bản cập nhật mới cho Rectangle!")
                        .font(.system(size: 15, weight: .bold))

                    Text("\(releaseTitle) hiện đã sẵn sàng trên GitHub. Phiên bản đang dùng: v\(updater.currentVersionString).")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Điểm mới trong phiên bản này:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(releaseNotes)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10), lineWidth: 1))
            .frame(minHeight: 150)

            if updater.isInstallingUpdate {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: updater.downloadProgress, total: 1.0)
                        .progressViewStyle(.linear)
                    Text(updater.statusMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else if let err = updater.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Lỗi tự động cập nhật: \(err)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 10) {
                Button("Xem trên GitHub ↗") {
                    if let pageURL = updater.pendingRelease?.pageURL {
                        NSWorkspace.shared.open(pageURL)
                    } else {
                        updater.openReleasesPage()
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)

                Spacer()

                Button(updater.isInstallingUpdate ? "Huỷ" : "Để sau") {
                    updater.dismissUpdateWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    updater.startDownloadAndInstall()
                } label: {
                    Label("Cập nhật & Khởi động lại", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(updater.isInstallingUpdate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: - Settings Window Titlebar GitHub Update Button

struct SettingsGitHubUpdateAccessoryView: View {
    @State private var updater = GitHubSoftwareUpdater.shared

    var body: some View {
        HStack(spacing: 6) {
            if updater.isChecking {
                ProgressView()
                    .controlSize(.small)
            }

            if let newTag = updater.availableReleaseTag {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Cập nhật \(newTag)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Tải và cài đặt bản cập nhật \(newTag) từ GitHub Releases")
            } else {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Cập nhật GitHub", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(updater.isChecking || updater.isInstallingUpdate)
                .help("Kiểm tra & cập nhật phiên bản mới qua GitHub (hungmtuci/Rectangle)")
            }
        }
        .padding(.trailing, 10)
        .frame(height: 28)
    }
}
