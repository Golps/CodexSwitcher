import Foundation

/// Switching works by swapping ~/.codex/auth.json, which only matters when Codex
/// keeps its login in that file. That's Codex's default; this checks that
/// ~/.codex/config.toml hasn't moved the login into the Keychain instead.
enum CodexConfig {
    private static let key = "cli_auth_credentials_store"

    static func url(codexHome: URL) -> URL { codexHome.appendingPathComponent("config.toml") }

    /// The store Codex is set to use, or nil when config.toml doesn't set one (file).
    static func credentialStore(codexHome: URL) -> String? {
        guard let text = try? String(contentsOf: url(codexHome: codexHome), encoding: .utf8) else { return nil }
        for line in topLevelLines(text) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func usesFileStore(codexHome: URL) -> Bool {
        (credentialStore(codexHome: codexHome) ?? "file") == "file"
    }

    /// Sets `cli_auth_credentials_store = "file"` at the top of config.toml,
    /// replacing an existing top-level setting if there is one.
    static func useFileStore(codexHome: URL) throws {
        let file = url(codexHome: codexHome)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let setting = "\(key) = \"file\""
        var lines = text.components(separatedBy: "\n")
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        if let existing = lines[..<firstTable].firstIndex(where: {
            $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key
        }) {
            lines[existing] = setting
        } else {
            lines.insert(setting, at: 0)
        }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Lines before the first [table] header, which is where top-level keys live.
    private static func topLevelLines(_ text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") { result.append(trimmed) }
        }
        return result
    }
}
