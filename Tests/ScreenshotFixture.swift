import AppKit
import SwiftUI

// Compiled only by capture-screenshots.sh, never into the application.
// The fixture deliberately has no account-store, network, or sign-in code.
struct Account: Identifiable {
    let key: String
    let label: String
    let email: String
    let plan: String
    var id: String { key }
}

enum Updater {
    static let currentVersion = ProcessInfo.processInfo.environment["SWITCHER_DEMO_VERSION"] ?? "Demo"
}

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts = [
        Account(key: "demo-personal", label: "Personal", email: "personal@example.com", plan: "plus"),
        Account(key: "demo-work", label: "Work", email: "work@example.com", plan: "pro"),
        Account(key: "demo-sandbox", label: "Sandbox", email: "sandbox@example.com", plan: "plus"),
    ]
    @Published var currentKey: String? = "demo-personal"
    @Published var busy: String?
    @Published var errorMessage: String?
    @Published var signingIn = false
    @Published var usesFileStore = true
    @Published var opensAtLogin = false
    @Published var checkingForUpdates = false
    @Published var usage: [String: UsageState] = [:]

    init() {
        let now = Date()
        func sample(_ short: Double, _ weekly: Double) -> UsageState {
            .loaded(Usage(windows: [
                .init(percent: short, seconds: 18_000, resetsAt: now.addingTimeInterval(7_200)),
                .init(percent: weekly, seconds: 604_800, resetsAt: now.addingTimeInterval(172_800)),
            ], limitReached: false))
        }
        usage = ["demo-personal": sample(16, 38), "demo-work": sample(54, 82),
                 "demo-sandbox": sample(0, 0)]
    }

    func switchTo(_ account: Account) async {}
    func addAccount() async {}
    func cancelSignIn() {}
    func rename(_ account: Account, to label: String) {}
    func remove(_ account: Account) {}
    func fixCredentialStore() {}
    func setOpensAtLogin(_ value: Bool) {}
    func checkForUpdates() async {}
}

@main
enum ScreenshotFixture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 2 else { fatalError("Pass an output directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let model = AppModel()
            let state = SettingsPresentation()
            let panel = StatusPanel(rootView: MenuView(model: model, settingsPresentation: state),
                                    settingsView: MenuSettingsView(model: model), presentation: state,
                                    reducesMotion: { true })
            panel.appearance = NSAppearance(named: appearance)
            // Render only this synthetic view. No desktop/window screenshot is taken.
            let material = panel.contentView as! NSVisualEffectView
            material.blendingMode = .withinWindow
            panel.backgroundColor = name == "dark"
                ? NSColor(calibratedWhite: 0.13, alpha: 1)
                : NSColor(calibratedWhite: 0.97, alpha: 1)
            state.isExpanded = true
            panel.orderFrontRegardless()
            let deadline = Date().addingTimeInterval(0.5)
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
            } while Date() < deadline
            guard let view = panel.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fatalError("Could not render fixture")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Could not encode fixture")
            }
            try data.write(to: output.appendingPathComponent("menu-\(name).png"))
            panel.orderOut(nil)
        }
        print("Rendered light/dark menus using synthetic example.com accounts only")
    }
}
