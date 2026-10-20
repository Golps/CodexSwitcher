import AppKit
import SwiftUI

/// Owns the menu-bar icon and the panel it opens. The panel is a borderless,
/// fully transparent window, so the only thing drawn is the SwiftUI menu with
/// its own rounded, frosted background: no square system frame behind it.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let settingsPresentation = SettingsPresentation()
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var lastHidden = Date.distantPast
    private var usageTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        statusItem.button?.toolTip = "Codex Switcher"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        panel = StatusPanel(rootView: MenuView(model: model, settingsPresentation: settingsPresentation),
                            settingsView: MenuSettingsView(model: model), presentation: settingsPresentation)
        NotificationCenter.default.addObserver(self, selector: #selector(contentResized),
                                               name: NSWindow.didResizeNotification, object: panel)
    }

    @objc private func toggle() {
        if panel.isVisible { hide(); return }
        // The menu bar can report a click on this icon as a click outside the app,
        // which closes the panel a moment before this runs; don't reopen it then.
        if Date().timeIntervalSince(lastHidden) < 0.3 { return }
        show()
    }

    private func show() {
        model.refresh()
        model.refreshUsage()
        // Keep the numbers live while the menu stays open.
        let model = self.model
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in model.refreshUsage() }
        }
        position()
        // Open without activating the app, like a real menu: activating it would
        // take focus from the app you're in and dim every window behind.
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)

        // Close on a click in another app or on Escape, like a real menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.panel.isKeyWindow == true else { return event }
            self?.hide()
            return nil
        }
    }

    private func hide() {
        lastHidden = Date()
        panel.orderOut(nil)
        usageTimer?.invalidate()
        usageTimer = nil
        statusItem.button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    @objc private func contentResized() {
        position()
        panel.invalidateShadow()
    }

    /// Keeps the panel's top edge just under the menu-bar icon, centred on it
    /// and kept on screen, whatever height the content currently has.
    private func position() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var x = anchor.midX - size.width / 2
        if let screen = buttonWindow.screen?.visibleFrame {
            x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        }
        let origin = NSPoint(x: x, y: anchor.minY - 6 - size.height)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}
