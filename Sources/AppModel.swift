import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var currentKey: String?
    @Published private(set) var busy: String?          // what's happening right now, if anything
    @Published var errorMessage: String?
    @Published private(set) var signingIn = false
    @Published private(set) var usesFileStore = true
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    @Published private(set) var usage: [String: UsageState] = [:]

    private var store: AccountStore?
    private var signIn: WebSignIn?
    private var usageTask: Task<Void, Never>?
    private var usageCheckedAt = Date.distantPast

    init() { refresh() }

    /// Picks up the account Codex is signed in to now (saving it if it's new)
    /// and re-reads everything shown in the menu.
    func refresh() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
        do {
            let store = try self.store ?? AccountStore()
            self.store = store
            usesFileStore = CodexConfig.usesFileStore(codexHome: store.codexHome)
            currentKey = try store.syncCurrent()
            accounts = store.accounts
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Usage

    /// Re-reads every account's usage, at most once every 5 seconds unless forced.
    func refreshUsage(force: Bool = false) {
        guard let store, usageTask == nil, force || Date().timeIntervalSince(usageCheckedAt) > 5 else { return }
        usageCheckedAt = Date()
        let current = currentKey
        let jobs = accounts.compactMap { account -> (String, Data, Bool)? in
            let isCurrent = account.key == current
            guard let auth = store.authForUsage(account.key, isCurrent: isCurrent) else { return nil }
            return (account.key, auth, isCurrent)
        }
        for (key, _, _) in jobs where usage[key] == nil { usage[key] = .loading }
        usageTask = Task {
            await withTaskGroup(of: (String, Result<(Usage, Data?), Error>).self) { group in
                for (key, auth, isCurrent) in jobs {
                    // Only Codex refreshes the login it's using; the others are refreshed here.
                    group.addTask {
                        do { return (key, .success(try await UsageClient.fetch(auth: auth, mayRefresh: !isCurrent))) }
                        catch { return (key, .failure(error)) }
                    }
                }
                for await (key, result) in group {
                    switch result {
                    case .success(let (value, refreshed)):
                        usage[key] = .loaded(value)
                        if let refreshed { try? store.saveRefreshed(refreshed, for: key) }
                    case .failure(let error):
                        // Keep showing the last numbers if a later check fails.
                        if case .loaded = usage[key] { continue }
                        usage[key] = .unavailable((error as? UsageError ?? .unavailable).localizedDescription)
                    }
                }
            }
            usageTask = nil
        }
    }

    // MARK: Switching

    func switchTo(_ account: Account) async {
        guard let store, busy == nil, account.key != currentKey else { return }
        errorMessage = nil
        // A usage check may be refreshing this account's saved login; let it finish
        // so the switch uses the newest tokens.
        await usageTask?.value
        let codexWasOpen = CodexApp.isRunning
        do {
            if codexWasOpen {
                busy = "Closing Codex…"
                try await CodexApp.quit()
            }
            // Anything named codex still alive after the app's own helper has had a
            // moment to exit is a terminal or editor session.
            var othersRunning = CodexApp.otherSessionsRunning
            for _ in 0..<10 where othersRunning {
                try await Task.sleep(nanoseconds: 100_000_000)
                othersRunning = CodexApp.otherSessionsRunning
            }
            if othersRunning && !confirm(
                "Codex is still running in a terminal or editor",
                "That session keeps using the old account and could put it back when it refreshes. "
                + "Close it first if you can.",
                ok: "Switch Anyway") {
                busy = nil
                if codexWasOpen { await CodexApp.relaunch() }
                return
            }

            // Swap the file and reopen Codex first; the Keychain write happens while it starts.
            busy = "Switching…"
            try store.activate(account.key)
            if codexWasOpen { Task { await CodexApp.relaunch() } }
            try store.saveChanges()
        } catch {
            errorMessage = error.localizedDescription
            if codexWasOpen && !CodexApp.isRunning { await CodexApp.relaunch() }
        }
        busy = nil
        refresh()
        refreshUsage(force: true)
    }

    // MARK: Adding

    func addAccount() async {
        guard let store, !signingIn else { return }
        errorMessage = nil
        signingIn = true
        let flow = WebSignIn()
        signIn = flow
        defer { signingIn = false; signIn = nil }
        do {
            let account = try store.add(authData: try await flow.run())
            refresh()
            refreshUsage(force: true)
            if account.key == currentKey {
                errorMessage = "That's the account Codex is already using. Add Account again and sign in with a different one."
            }
        } catch is CancellationError {
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelSignIn() { signIn?.cancel() }

    // MARK: Editing

    func rename(_ account: Account, to label: String) {
        do { try store?.rename(account.key, to: label) } catch { errorMessage = error.localizedDescription }
        accounts = store?.accounts ?? []
    }

    func remove(_ account: Account) {
        guard confirm("Remove \(account.label)?",
                      "Its saved login is deleted from your Keychain. You can add it again later by signing in.",
                      ok: "Remove") else { return }
        do { try store?.remove(account.key) } catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func fixCredentialStore() {
        guard let store else { return }
        do {
            try CodexConfig.useFileStore(codexHome: store.codexHome)
        } catch {
            errorMessage = "Couldn't update Codex's config.toml: \(error.localizedDescription)"
        }
        refresh()
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Updates

    @Published private(set) var checkingForUpdates = false

    func checkForUpdates() async {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        do {
            guard let release = try await Updater.check() else {
                inform("You're up to date", "Codex Switcher \(Updater.currentVersion) is the latest version.")
                return
            }
            guard confirm("Codex Switcher \(release.version) is available",
                          "You have \(Updater.currentVersion). Install it now? The old version goes to the Trash and "
                          + "Codex Switcher reopens. macOS will ask for Keychain access again; click Always Allow.",
                          ok: "Install and Relaunch") else { return }
            busy = "Updating…"
            try await Updater.install(release)
        } catch UpdateError.noAccess {
            if Updater.token != nil {
                Keychain.delete(Updater.tokenItem)
                errorMessage = "GitHub didn't accept the saved token. Check for Updates again to enter a new one."
            } else if askForToken() {
                checkingForUpdates = false
                await checkForUpdates()
            }
        } catch {
            busy = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Asks once for a read-only GitHub token, needed only while the repo is private.
    private func askForToken() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "GitHub token needed"
        alert.informativeText = "Codex Switcher's repo is private, so checking for updates needs a GitHub token "
            + "with read-only access to its contents. Create one at github.com → Settings → Developer settings → "
            + "Fine-grained tokens, limited to the CodexSwitcher repo with Contents: Read-only. It's kept in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "github_pat_…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return false }
        do { try Keychain.write(Data(entered.utf8), Updater.tokenItem) } catch {
            errorMessage = error.localizedDescription
            return false
        }
        return true
    }

    private func inform(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private func confirm(_ title: String, _ detail: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
