import AppKit
import CryptoKit
import Foundation
import Security

/// Checks GitHub for a newer MouseLite and replaces this copy with it.
///
/// A download is only installed if its code signature is valid and comes from the same team as this copy's, so a
/// swapped release asset can't get in. GitHub's sha256 digest is checked too. The new copy takes this one's place and
/// opens once this one has quit.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(percent: Int)
        case installing
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    /// A newer build in the chosen channel, found by the last check.
    @Published private(set) var available: Release?
    @Published private(set) var preferences = UpdatePreferences.load()

    let build = BuildInfo.current
    private let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
    private let team = UpdateInstaller.signingTeam()
    private var timer: Timer?
    /// Stops a check that was overtaken (by another check, or an install) from reporting.
    private var generation = 0

    /// Snapshots are published with every push to main, and a menu bar app can run for weeks.
    private static let checkInterval: TimeInterval = 6 * 3600
    /// A new build in the channel is announced at most this often.
    private static let announceInterval: TimeInterval = 20 * 3600

    var channel: UpdateChannel { preferences.channel ?? (build.isPrerelease ? .prerelease : .release) }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        case .idle, .upToDate, .failed: return false
        }
    }

    var isInstalling: Bool {
        switch phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    /// Why this copy doesn't look for updates at all.
    var unavailableReason: String? {
        guard build.code > 0, build.repository != nil, appURL.pathExtension == "app" else {
            return "此版本不是從正式發佈包執行，無法檢查更新。"
        }
        return nil
    }

    var menuTitle: String {
        switch phase {
        case .checking: return "正在檢查更新…"
        case .downloading(let percent): return "正在下載更新 \(percent)%…"
        case .installing: return "正在安裝更新…"
        default: return "檢查更新…"
        }
    }

    private var userAgent: String { "MouseLite/\(build.label)" }

    func start() {
        guard unavailableReason == nil else { return }
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Every launch checks once the app has settled.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.checkIfDue(atLaunch: true)
        }
    }

    private func checkIfDue(atLaunch: Bool = false) {
        guard preferences.checksAutomatically, !isBusy else { return }
        if !atLaunch, let last = preferences.lastCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// Looks for a newer build. One the user didn't ask about is announced at most once per build every 20 hours.
    func check(userInitiated: Bool = true) {
        guard unavailableReason == nil, !isInstalling, let repository = build.repository else { return }
        generation += 1
        let generation = generation
        let channel = channel
        let userAgent = userAgent
        phase = .checking
        Task {
            do {
                let releases = try await UpdateInstaller.releases(repository: repository, channel: channel, userAgent: userAgent)
                guard generation == self.generation else { return }
                change { $0.lastCheck = Date() }
                available = UpdateCheck.update(in: releases, channel: channel, current: build.code)
                phase = available == nil ? .upToDate : .idle
                if let release = available {
                    if userInitiated { announce(release) } else { announceIfNew(release) }
                } else if userInitiated {
                    present("已是最新版本", "MouseLite \(build.label) 是這個通道的最新版本。", buttons: ["好"])
                }
            } catch {
                guard generation == self.generation else { return }
                let failure = UpdateFailure(error)
                phase = .failed(failure.message)
                if userInitiated { fail(failure, release: available) }
            }
        }
    }

    func setChecksAutomatically(_ on: Bool) {
        change { $0.checksAutomatically = on }
        if on { checkIfDue() }
    }

    func setReceivesPrereleases(_ on: Bool) {
        change { $0.channel = on ? .prerelease : .release }
        available = nil
        check()
    }

    func openReleasePage() {
        if let available { NSWorkspace.shared.open(available.htmlURL) }
    }

    /// Downloads the available update, checks it, puts it in this copy's place and relaunches.
    func install() {
        guard let release = available, let code = release.code, let archive = release.archive, !isInstalling else { return }
        guard let team else { return fail(.unsigned, release: release) }
        let folder = appURL.deletingLastPathComponent()
        if appURL.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: folder.path) {
            return fail(.notWritable, release: release)
        }
        generation += 1
        phase = .downloading(percent: 0)
        let appURL = appURL
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let userAgent = userAgent
        Task {
            do {
                let update = try await UpdateInstaller.download(
                    archive, code: code, bundleIdentifier: identifier, team: team, beside: appURL, userAgent: userAgent
                ) { percent in
                    Task { @MainActor in
                        guard case .downloading(let shown) = self.phase, percent > shown else { return }
                        self.phase = .downloading(percent: percent)
                    }
                }
                phase = .installing
                try UpdateInstaller.replace(appURL, with: update)
                try UpdateInstaller.relaunch(appURL)
                NSApp.terminate(nil)
            } catch {
                fail(UpdateFailure(error), release: release)
            }
        }
    }

    private func announceIfNew(_ release: Release) {
        guard let code = release.code, code > preferences.announcedCode else { return }
        if let last = preferences.lastAnnouncement, Date().timeIntervalSince(last) < Self.announceInterval { return }
        change {
            $0.announcedCode = code
            $0.lastAnnouncement = Date()
        }
        announce(release)
    }

    private func announce(_ release: Release) {
        let response = present("有新的 MouseLite \(release.label)",
                               "目前版本是 \(build.label)。要現在下載並安裝嗎？安裝完成後 MouseLite 會自動重新開啟。",
                               buttons: ["安裝", "查看版本", "稍後"])
        switch response {
        case .alertFirstButtonReturn: install()
        case .alertSecondButtonReturn: openReleasePage()
        default: break
        }
    }

    private func fail(_ failure: UpdateFailure, release: Release?) {
        phase = .failed(failure.message)
        let response = present("無法更新 MouseLite", failure.message, buttons: ["好", "手動下載"])
        if response == .alertSecondButtonReturn, let release {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    @discardableResult
    private func present(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = text
        for button in buttons { alert.addButton(withTitle: button) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func change(_ edit: (inout UpdatePreferences) -> Void) {
        edit(&preferences)
        preferences.save()
    }
}

enum UpdateFailure: Error, Equatable {
    case offline
    case notFound
    case rateLimited
    case server(Int)
    case damaged
    case untrusted
    case unsigned
    case notWritable
    case other(String)

    init(_ error: any Error) {
        self = switch error {
        case let failure as UpdateFailure: failure
        case is URLError: .offline
        default: .other(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .offline: return "無法連上網路，請稍後再試。"
        case .notFound: return "找不到發佈資訊。"
        case .rateLimited: return "GitHub 暫時限制存取，請稍後再試。"
        case .server(let status): return "伺服器回應錯誤（HTTP \(status)）。"
        case .damaged: return "下載的更新檔不完整或已損壞。"
        case .untrusted: return "更新的簽章與目前版本不同，已停止安裝。"
        case .unsigned: return "目前版本沒有 Developer ID 簽章，無法自動更新。請手動下載。"
        case .notWritable: return "MouseLite 所在的資料夾無法寫入。請把它移到「應用程式」資料夾後再試。"
        case .other(let message): return message
        }
    }
}

/// A checked update, still in the temporary folder it was unpacked in.
struct StagedUpdate: Sendable {
    let app: URL
    let folder: URL
}

enum UpdateInstaller {
    #if DEBUG
    /// Lets a debug build update from a local copy of the API.
    private static let api = ProcessInfo.processInfo.environment["MOUSELITE_UPDATE_API"] ?? "https://api.github.com"
    #else
    private static let api = "https://api.github.com"
    #endif

    /// The repository's releases, newest first.
    static func releases(repository: String, channel: UpdateChannel, userAgent: String) async throws -> [Release] {
        var releases = try await get("repos/\(repository)/releases?per_page=100", as: [Release].self, userAgent: userAgent)
        // A page of snapshots can push the newest release off the list.
        if channel == .release, releases.count == 100, !releases.contains(where: { !$0.prerelease && !$0.draft }) {
            releases += [try await get("repos/\(repository)/releases/latest", as: Release.self, userAgent: userAgent)]
        }
        return releases
    }

    private static func get<T: Decodable>(_ path: String, as type: T.Type, userAgent: String) async throws -> T {
        guard let url = URL(string: "\(api)/\(path)") else { throw UpdateFailure.notFound }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONDecoder().decode(type, from: data)
        // Also what a private repository answers.
        case 404: throw UpdateFailure.notFound
        case 403, 429: throw UpdateFailure.rateLimited
        case let status: throw UpdateFailure.server(status)
        }
    }

    /// Downloads and unpacks `asset` next to the installed app, and checks it's the build it claims to be.
    static func download(
        _ asset: Release.Asset, code: Int, bundleIdentifier: String, team: String, beside installed: URL,
        userAgent: String, progress: @escaping @Sendable (Int) -> Void
    ) async throws -> StagedUpdate {
        let fileManager = FileManager.default
        // On the app's volume, so putting it in place is a rename.
        let folder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        do {
            var request = URLRequest(url: asset.downloadURL, timeoutInterval: 60)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (file, response) = try await URLSession.shared.download(for: request, delegate: DownloadProgress(report: progress))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateFailure.server(status) }
            let archive = folder.appendingPathComponent("MouseLite.zip")
            try fileManager.moveItem(at: file, to: archive)
            try checkDigest(of: archive, against: asset)
            let app = try unpack(archive, into: folder.appendingPathComponent("unpacked"))
            try verify(app, code: code, bundleIdentifier: bundleIdentifier, team: team)
            return StagedUpdate(app: app, folder: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    static func checkDigest(of file: URL, against asset: Release.Asset) throws {
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size else { throw UpdateFailure.damaged }
        // Files uploaded before GitHub computed digests have none; the signature check still applies to them.
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == "sha256:" + hex else { throw UpdateFailure.damaged }
    }

    static func unpack(_ archive: URL, into folder: URL) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateFailure.damaged }
        let apps = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateFailure.damaged }
        return apps[0]
    }

    /// The app must be signed by `team`, sealed, and be the build the release says it is.
    static func verify(_ app: URL, code: Int, bundleIdentifier: String, team: String) throws {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateFailure.untrusted }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else { throw UpdateFailure.untrusted }
        // Sealed by the signature just checked.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              info?["CFBundleVersion"] as? String == String(code) else { throw UpdateFailure.damaged }
    }

    static func replace(_ installed: URL, with update: StagedUpdate) throws {
        defer { try? FileManager.default.removeItem(at: update.folder) }
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: update.app)
        } catch {
            throw UpdateFailure.notWritable
        }
    }

    /// Opens `app` once this process has quit, so two copies never run at once.
    static func relaunch(_ app: URL) throws {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$0\"",
            app.path, String(ProcessInfo.processInfo.processIdentifier),
        ]
        try waiter.run()
    }

    /// The team that signed this copy; nil for an ad hoc signature, which leaves nothing to check an update against.
    static func signingTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var last = -1

    init(report: @escaping @Sendable (Int) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        lock.lock()
        let isNew = percent > last
        if isNew { last = percent }
        lock.unlock()
        if isNew { report(percent) }
    }

    // The download call itself hands over the file.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
