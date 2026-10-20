import Foundation
import Security

struct Account: Codable, Identifiable, Equatable {
    let key: String
    var label: String
    var email: String
    var plan: String
    var id: String { key }
}

/// Saved logins live in one item in your login Keychain ("Codex Switcher" /
/// "accounts"), so they're encrypted at rest and locked with your Mac.
/// The only plain file involved is ~/.codex/auth.json, which Codex itself needs.
final class AccountStore {
    let codexHome: URL
    var activeAuthURL: URL { codexHome.appendingPathComponent("auth.json") }
    var accounts: [Account] { vault.accounts.map(\.account) }

    private struct Saved: Codable {
        var account: Account
        var auth: Data
    }
    private struct Vault: Codable {
        var accounts: [Saved] = []
        /// The last ~/.codex/auth.json this app replaced, in case it wasn't saved anywhere else.
        var previousAuth: Data?
    }
    private var vault = Vault()
    private var unsaved = false

    init() throws {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            codexHome = URL(fileURLWithPath: custom)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        if let data = try Keychain.read() { vault = try JSONDecoder().decode(Vault.self, from: data) }
    }

    // MARK: Current login

    /// Reads ~/.codex/auth.json, saves it (Codex refreshes tokens in place, so
    /// this keeps the stored copy current) and returns its account key.
    /// Returns nil when nobody is signed in or the login isn't a ChatGPT one.
    @discardableResult
    func syncCurrent() throws -> String? {
        guard let data = try? Data(contentsOf: activeAuthURL),
              let identity = try? AuthFile.identity(of: data) else { return nil }
        try save(authData: data, identity: identity)
        return identity.key
    }

    /// Replaces ~/.codex/auth.json with the saved login for `key`, and keeps the
    /// outgoing login (with whatever tokens Codex last refreshed) in memory.
    /// Only the file is written here, so Codex can be reopened straight away;
    /// call `saveChanges()` afterwards to write the Keychain.
    func activate(_ key: String) throws {
        guard let saved = vault.accounts.first(where: { $0.account.key == key }) else { return }
        let previous = try? Data(contentsOf: activeAuthURL)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.writePrivate(saved.auth, to: activeAuthURL)

        guard let previous else { return }
        vault.previousAuth = previous
        if let identity = try? AuthFile.identity(of: previous),
           let index = vault.accounts.firstIndex(where: { $0.account.key == identity.key }) {
            vault.accounts[index].auth = previous
        }
        unsaved = true
    }

    /// Writes changes from `activate` to the Keychain.
    func saveChanges() throws {
        guard unsaved else { return }
        try persist()
    }

    // MARK: Usage

    /// The login to read usage with: auth.json for the account Codex is using
    /// (Codex keeps that one fresh), the saved copy for every other account.
    func authForUsage(_ key: String, isCurrent: Bool) -> Data? {
        if isCurrent { return try? Data(contentsOf: activeAuthURL) }
        return vault.accounts.first(where: { $0.account.key == key })?.auth
    }

    /// Saves tokens refreshed while reading usage for an account that isn't
    /// in use, so its next switch starts with a working login.
    func saveRefreshed(_ auth: Data, for key: String) throws {
        guard (try? AuthFile.identity(of: auth))?.key == key,
              let index = vault.accounts.firstIndex(where: { $0.account.key == key }) else { return }
        vault.accounts[index].auth = auth
        try persist()
    }

    // MARK: Editing

    @discardableResult
    func add(authData: Data) throws -> Account {
        try save(authData: authData, identity: try AuthFile.identity(of: authData))
    }

    func rename(_ key: String, to label: String) throws {
        guard let index = vault.accounts.firstIndex(where: { $0.account.key == key }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        vault.accounts[index].account.label = trimmed.isEmpty ? vault.accounts[index].account.email : trimmed
        try persist()
    }

    func remove(_ key: String) throws {
        vault.accounts.removeAll { $0.account.key == key }
        try persist()
    }

    // MARK: Private

    @discardableResult
    private func save(authData: Data, identity: AuthIdentity) throws -> Account {
        if let index = vault.accounts.firstIndex(where: { $0.account.key == identity.key }) {
            var saved = vault.accounts[index]
            saved.auth = authData
            if !identity.email.isEmpty { saved.account.email = identity.email }
            if !identity.plan.isEmpty { saved.account.plan = identity.plan }
            if saved.auth != vault.accounts[index].auth || saved.account != vault.accounts[index].account {
                vault.accounts[index] = saved
                try persist()
            }
            return saved.account
        }
        let label = identity.email.isEmpty ? "Account \(vault.accounts.count + 1)" : identity.email
        let account = Account(key: identity.key, label: label, email: identity.email, plan: identity.plan)
        vault.accounts.append(Saved(account: account, auth: authData))
        try persist()
        return account
    }

    private func persist() throws {
        try Keychain.write(try JSONEncoder().encode(vault))
        unsaved = false
    }

    /// Writes a 0600 temp file next to the target, then renames it into place
    /// so Codex never sees a half-written file.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        if Darwin.rename(temp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

/// Generic-password items in the login Keychain, under the service "Codex Switcher".
enum Keychain {
    private static let service = "Codex Switcher"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String = "accounts") throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    static func write(_ data: Data, _ account: String = "accounts") throws {
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Codex Switcher"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Couldn't use the Keychain: \(reason)"
    }
}
