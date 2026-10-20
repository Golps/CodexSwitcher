import AppKit
import Foundation

/// Checks GitHub Releases for a newer Codex Switcher and installs it in place:
/// download the disk image, copy the new app out of it, move the running copy
/// to the Trash, put the new one where it was, and relaunch.
enum Updater {
    private static let repo = "Golps/CodexSwitcher"
    private static let assetName = "CodexSwitcher.dmg"
    /// Optional read-only GitHub token, for when the repo is private.
    static let tokenItem = "github-token"

    struct Release {
        let version: String
        let assetURL: URL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var token: String? {
        (try? Keychain.read(tokenItem)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The newest release if it's newer than this copy, otherwise nil.
    static func check() async throws -> Release? {
        let request = authorized(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
                                 accept: "application/vnd.github+json")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 401 { throw UpdateError.noAccess }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let api = (asset["url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.badResponse }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: currentVersion) else { return nil }
        return Release(version: version, assetURL: api)
    }

    /// Downloads and installs `release`, then relaunches. Only returns on failure.
    static func install(_ release: Release) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("CodexSwitcherUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download the disk image.
        let (download, response) = try await URLSession.shared.download(
            for: authorized(release.assetURL, accept: "application/octet-stream"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        let dmg = work.appendingPathComponent(assetName)
        try fm.moveItem(at: download, to: dmg)

        // 2. Mount it privately and copy the new app next to the running one.
        let mount = work.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let current = Bundle.main.bundleURL
        let fresh = mount.appendingPathComponent("Codex Switcher.app")
        guard fm.fileExists(atPath: fresh.path) else { throw UpdateError.badResponse }
        let staged = current.deletingLastPathComponent()
            .appendingPathComponent(".Codex Switcher \(release.version).app")
        try? fm.removeItem(at: staged)
        do { try fm.copyItem(at: fresh, to: staged) } catch { throw UpdateError.cantWrite(current.deletingLastPathComponent().path) }

        // 3. Old copy to the Trash, new copy into its place.
        var trashed: NSURL?
        do {
            try fm.trashItem(at: current, resultingItemURL: &trashed)
            try fm.moveItem(at: staged, to: current)
        } catch {
            // Put the old copy back if it already went to the Trash.
            if let trashed = trashed as URL?, !fm.fileExists(atPath: current.path) {
                try? fm.moveItem(at: trashed, to: current)
            }
            try? fm.removeItem(at: staged)
            throw UpdateError.cantWrite(current.deletingLastPathComponent().path)
        }

        // 4. Start the new copy once this one has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", current.path]
        try relaunch.run()
        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func authorized(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("CodexSwitcher/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Compares dotted version numbers, so 1.0.10 is newer than 1.0.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.badResponse }
        return process.terminationStatus
    }
}

enum UpdateError: LocalizedError {
    case noAccess
    case badResponse
    case cantWrite(String)

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "Couldn't reach Codex Switcher's releases. The repo is private, so the app needs a GitHub token to check for updates."
        case .badResponse:
            return "Couldn't download the update. Try again later, or download it from the releases page."
        case .cantWrite(let folder):
            return "Couldn't replace the app in \(folder). Download the update from the releases page and drag it into Applications."
        }
    }
}
