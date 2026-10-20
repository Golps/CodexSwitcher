import AppKit
import SwiftUI

struct AccountsFixture: View {
    @ObservedObject var presentation: SettingsPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex Accounts").font(.headline)
            Text("Demo account").padding(8)
            SettingsFooter(isExpanded: $presentation.isExpanded) {
                Button("Add Account…") {}
            }
        }
        .padding(14)
        .frame(width: 450)
    }
}

struct SettingsFixture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack { Button("Check for Updates…") {}; Spacer(); Text("Version 1.0") }
            HStack { Toggle("Open at Login", isOn: .constant(false)); Spacer(); Button("Quit") {} }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

@main
struct SettingsLayoutCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let state = SettingsPresentation()
        let panel = StatusPanel(rootView: AccountsFixture(presentation: state),
                                settingsView: SettingsFixture(), presentation: state,
                                reducesMotion: { false })
        func pump() {
            panel.contentView?.layoutSubtreeIfNeeded()
            app.updateWindows()
            panel.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        func waitFor(_ message: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            repeat { pump() } while !condition() && Date() < deadline
            if !condition() { print("DETAIL", panel.frame, panel.targetContentSize, panel.isResizing, panel.settingsContentFrame, state.isExpanded); fflush(stdout) }
            precondition(condition(), message)
        }
        func capture(_ name: String) {
            guard let dir = ProcessInfo.processInfo.environment["SWITCHER_CAPTURE_DIR"],
                  let view = panel.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        waitFor("Initial content must fit") { panel.frame.height > 50 }
        panel.setFrameOrigin(NSPoint(x: 200, y: 400))
        panel.orderFrontRegardless()
        panel.makeKey()
        let collapsed = panel.frame
        let accountFrame = panel.accountContentFrame
        let settingsFrame = panel.settingsContentFrame
        let visibleWindows = app.windows.filter(\.isVisible).count
        var resizeSamples = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                             object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                resizeSamples += 1
                precondition(panel.accountContentFrame == accountFrame, "Account content must remain fixed during resize")
                precondition(panel.settingsContentFrame == settingsFrame, "Settings must remain full-size during resize")
                if panel.isResizing {
                    precondition(panel.inlineSettingsVisible, "Settings must remain drawn throughout native animation")
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer); panel.orderOut(nil) }
        capture("settings-collapsed")
        for cycle in 0..<5 {
            state.isExpanded = true
            waitFor("Settings must expand inline") {
                !panel.isResizing && panel.frame.height > collapsed.height + 30
            }
            precondition(panel.inlineSettingsVisible, "Inline settings must be visible")
            precondition(panel.accountContentFrame == accountFrame, "Account content must not shift or squeeze")
            precondition(panel.settingsContentFrame == settingsFrame, "Settings content must not squeeze")
            precondition(abs(panel.frame.maxY - collapsed.maxY) < 1, "Top edge must remain fixed")
            precondition(app.windows.filter(\.isVisible).count == visibleWindows, "Settings must not create another window")
            if cycle == 0 { capture("settings-expanded") }
            state.isExpanded = false
            waitFor("Closing must start") { panel.isResizing || !panel.inlineSettingsVisible }
            if panel.isResizing {
                precondition(panel.inlineSettingsVisible, "Closing must retain settings until animation completes")
                precondition(panel.settingsContentFrame == settingsFrame, "Closing content must stay full size")
            }
            waitFor("Settings must finish collapsing") {
                !panel.isResizing && abs(panel.frame.height - collapsed.height) < 1 && !panel.inlineSettingsVisible
            }
        }
        precondition(resizeSamples >= 10, "Repeated open/close resizes must be exercised")
        state.isExpanded = true
        pump()
        state.isExpanded = false
        pump()
        state.isExpanded = true
        waitFor("Rapid toggles must end expanded") {
            !panel.isResizing && panel.inlineSettingsVisible && panel.frame.height > collapsed.height + 30
        }
        panel.orderOut(nil)
        waitFor("Hiding must reset inline settings") { !state.isExpanded && !panel.inlineSettingsVisible }
        let reduced = SettingsPresentation()
        let reducedPanel = StatusPanel(rootView: AccountsFixture(presentation: reduced),
                                       settingsView: SettingsFixture(), presentation: reduced,
                                       reducesMotion: { true })
        reducedPanel.orderFrontRegardless()
        let reducedHeight = reducedPanel.frame.height
        reduced.isExpanded = true
        waitFor("Reduce Motion must reveal inline settings") {
            !reducedPanel.isResizing && reducedPanel.inlineSettingsVisible && reducedPanel.frame.height > reducedHeight + 30
        }
        reducedPanel.orderOut(nil)
        print("PASS: inline native animation preserves full-size content, panel top edge, and one-window presentation")
    }
}
