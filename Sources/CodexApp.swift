import AppKit
import Foundation

/// Quitting and reopening the Codex desktop app.
enum CodexApp {
    static let bundleID = "com.openai.codex"

    static var isRunning: Bool { !runningPIDs.isEmpty }

    /// Process ids of Codex that are actually alive. AppKit's own list can lag
    /// behind a force-quit, so each pid is checked directly.
    private static var runningPIDs: [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier).filter(isAlive)
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Force-quits Codex and its `codex` helper straight away, for the fastest
    /// switch. A switch interrupts any running task anyway, and Codex writes
    /// refreshed tokens to auth.json when it refreshes them, not at quit, so
    /// nothing the switch needs is lost.
    static func quit() async throws {
        let pids = runningPIDs
        guard !pids.isEmpty else { return }
        // Helpers first, so they can't outlive the app and look like a terminal session.
        stopHelpers(parents: pids.map(String.init).joined(separator: ","))
        pids.forEach { kill($0, SIGKILL) }
        for _ in 0..<100 {   // 20 ms checks, up to 2 s
            if !pids.contains(where: isAlive) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw SwitchError.codexWouldNotQuit
    }

    private static func stopHelpers(parents: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", parents, "-x", "codex"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    static func launch() {
        guard let url = appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Opens Codex again right after `quit()`. macOS can take a moment to notice
    /// a force-quit app is gone, and an open request in that window is ignored,
    /// so this waits for macOS to catch up and retries until Codex is running.
    static func relaunch() async {
        for _ in 0..<50 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<5 {
            launch()
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if isRunning { return }
            }
        }
    }

    /// True when a `codex` process is still alive after the desktop app has quit,
    /// which means a terminal or editor session is using the login.
    static var otherSessionsRunning: Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "codex"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run() } catch { return false }
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }
}

enum SwitchError: LocalizedError {
    case codexWouldNotQuit

    var errorDescription: String? {
        switch self {
        case .codexWouldNotQuit:
            return "Codex didn't quit. Quit it from its menu, then try again. Nothing was changed."
        }
    }
}
