import AppKit
import SwiftUI

/// A plain AppKit app with no windows of its own: everything visible lives in
/// the menu-bar panel (see StatusPanel.swift).
@main
enum CodexSwitcherApp {
    @MainActor private static let controller = StatusItemController()

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        app.run()
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @State private var renaming: String?
    @State private var draftLabel = ""
    @ObservedObject var settingsPresentation: SettingsPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex Accounts").font(.headline)

            if !model.usesFileStore { credentialStoreWarning }
            if let message = model.errorMessage { errorBanner(message) }

            if model.accounts.isEmpty && !model.signingIn {
                Text("Add each ChatGPT account once. After that, switching is one click.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(model.accounts) { account in row(account) }
            }

            if let busy = model.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).font(.callout) }
            }

            if model.signingIn { signInPanel }
            SettingsFooter(isExpanded: $settingsPresentation.isExpanded) {
                if !model.signingIn {
                    Button { Task { await model.addAccount() } } label: {
                        Label("Add Account…", systemImage: "plus")
                            .frame(width: Self.wideButtonWidth)
                    }
                    .font(.callout)
                    .disabled(model.busy != nil)
                }
            }
        }
        .padding(14)
        .frame(width: panelWidth)
        .onReceive(model.objectWillChange) { _ in
            settingsPresentation.layoutInvalidated.send()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ account: Account) -> some View {
        let isCurrent = account.key == model.currentKey
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if renaming == account.key {
                        TextField("Name", text: $draftLabel)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                model.rename(account, to: draftLabel)
                                renaming = nil
                            }
                    } else {
                        Text(account.label).lineLimit(1).truncationMode(.middle)
                    }
                    Text(subtitle(account)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if isCurrent {
                    Text("Active").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Switch") { Task { await model.switchTo(account) } }
                        .disabled(model.busy != nil || model.signingIn)
                        .help("Codex restarts on this account if it's open.")
                }
                Menu {
                    Button("Rename") { draftLabel = account.label; renaming = account.key }
                    Button("Remove…", role: .destructive) { model.remove(account) }
                        .disabled(isCurrent)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            usageView(model.usage[account.key])
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func usageView(_ state: UsageState?) -> some View {
        switch state {
        case .loaded(let usage) where !usage.windows.isEmpty:
            // Redraws each minute so a limit that resets while the menu is open shows 100% left.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                    ForEach(usage.windows, id: \.seconds) { window in
                        // Shown as what's left, the way Codex shows it.
                        let left = 100 - window.percent(at: context.date)
                        GridRow {
                            Text(window.name).foregroundStyle(.secondary)
                            UsageBar(fractionLeft: left / 100)
                                .frame(width: 90, height: 5)
                            Text("\(Int(left.rounded()))% left").monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            if left >= 100 {
                                // An unused limit's clock only starts with the first Codex message.
                                Label("not started", systemImage: "play.circle")
                                    .foregroundStyle(.secondary)
                                    .help("This limit's timer hasn't started. It begins with your first Codex message on this account.")
                            } else {
                                Text(resetText(window.resetsAt, now: context.date)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .loaded:
            Text("No usage limits reported").font(.caption2).foregroundStyle(.secondary)
        case .loading:
            Text("Checking usage…").font(.caption2).foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(reason).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private func resetText(_ date: Date, now: Date) -> String {
        if date <= now { return "reset" }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return "resets \(date.formatted(style))"
    }

    /// Wide enough that every name and email fits on one line, beside the
    /// checkmark, Switch button and ⋯ menu.
    private var panelWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = model.accounts.flatMap { [$0.label, subtitle($0)] }
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // Usage has its own full-width line, clear of the account controls.
        return min(max(450, ceil(widest) + 210), 720)
    }

    /// Add Account and Check for Updates share one width so they line up.
    private static let wideButtonWidth: CGFloat = 140

    private func subtitle(_ account: Account) -> String {
        let plan = account.plan.isEmpty ? "" : account.plan.capitalized
        if account.label == account.email { return plan.isEmpty ? "ChatGPT" : "ChatGPT \(plan)" }
        return [account.email, plan].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Panels

    private var signInPanel: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Sign in with the account you want to add in the window that opened.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel") { model.cancelSignIn() }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var credentialStoreWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex keeps its login in the Keychain, so switching can't take effect. "
                 + "Store it in a file instead? You may need to sign in to Codex once afterwards.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use File Login") { model.fixCredentialStore() }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top) {
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
    }
}

/// A thin meter of what's left, turning orange, then red, as it runs low.
struct UsageBar: View {
    let fractionLeft: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: max(geo.size.width * min(max(fractionLeft, 0), 1), fractionLeft > 0 ? 3 : 0))
            }
        }
    }

    private var color: Color {
        fractionLeft <= 0.1 ? .red : fractionLeft <= 0.3 ? .orange : .green
    }
}

struct MenuSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Button { Task { await model.checkForUpdates() } } label: {
                    Text(model.checkingForUpdates ? "Checking…" : "Check for Updates…")
                        .frame(width: 140)
                }
                .disabled(model.checkingForUpdates || model.busy != nil)
                Spacer()
                Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin },
                                                      set: { model.setOpensAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .help("Quit Codex Switcher")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

}
