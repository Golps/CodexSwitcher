import AppKit
import Combine
import SwiftUI

/// The account content and inline settings each have a full-size hosting view.
/// AppKit animates only the surrounding window. Neither host is squeezed or
/// remeasured on animation frames, and closing keeps settings drawn until done.
@MainActor
final class StatusPanel: NSPanel {
    static let cornerRadius: CGFloat = 12
    static let resizeDuration: TimeInterval = 0.18
    private let presentation: SettingsPresentation
    private let reducesMotion: () -> Bool
    private var subscriptions = Set<AnyCancellable>()
    private var measureMain: (() -> NSSize)!
    private var measureSettings: ((CGFloat) -> NSSize)!
    private var mainView: NSView!
    private var settingsView: NSView!
    private var layoutPending = false
    private var animatePending = false
    private var contentLayoutDeferred = false
    private var generation = 0
    private(set) var targetContentSize = NSSize.zero
    private(set) var isResizing = false
    var inlineSettingsVisible: Bool { !settingsView.isHidden }
    var accountContentFrame: NSRect { mainView.frame }
    var settingsContentFrame: NSRect { settingsView.frame }

    init<Main: View, Settings: View>(rootView: Main, settingsView: Settings,
                                    presentation: SettingsPresentation,
                                    reducesMotion: @escaping () -> Bool = {
                                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                    }) {
        self.presentation = presentation
        self.reducesMotion = reducesMotion
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let background = InlinePanelMaterial()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.autoresizesSubviews = false
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.masksToBounds = true
        let container = NSViewController()
        container.view = background
        contentViewController = container

        let main = NSHostingController(rootView: rootView)
        let settings = NSHostingController(rootView: settingsView)
        main.sizingOptions = []
        settings.sizingOptions = []
        container.addChild(main)
        container.addChild(settings)
        mainView = main.view
        self.settingsView = settings.view
        for view in [main.view, settings.view] {
            view.autoresizingMask = []
            background.addSubview(view)
        }
        settings.view.isHidden = true
        measureMain = { [weak main] in main?.sizeThatFits(in: .zero) ?? .zero }
        measureSettings = { [weak settings] width in
            settings?.sizeThatFits(in: NSSize(width: width, height: 0)) ?? .zero
        }
        presentation.$isExpanded.dropFirst().sink { [weak self] _ in
            self?.scheduleLayout(animated: true)
        }.store(in: &subscriptions)
        presentation.layoutInvalidated.sink { [weak self] in
            self?.scheduleLayout(animated: false)
        }.store(in: &subscriptions)
        updateLayout(animated: false)
    }

    private func scheduleLayout(animated: Bool) {
        if isResizing && !animated {
            contentLayoutDeferred = true
            return
        }
        animatePending = animatePending || animated
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutPending = false
            let animated = self.animatePending
            self.animatePending = false
            self.updateLayout(animated: animated)
        }
    }

    private func updateLayout(animated: Bool) {
        let main = measureMain()
        guard main.width > 0, main.height > 0 else { return }
        let settings = measureSettings(main.width)
        let expanded = presentation.isExpanded
        let size = NSSize(width: ceil(main.width),
                          height: ceil(main.height + (expanded ? settings.height : 0)))
        mainView.frame = NSRect(origin: .zero, size: main)
        settingsView.frame = NSRect(x: 0, y: main.height, width: main.width, height: settings.height)
        // Leave closing content visible behind the clipping edge until finished.
        if expanded { settingsView.isHidden = false }
        targetContentSize = size
        generation += 1
        let currentGeneration = generation
        let target = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                            width: size.width, height: size.height)
        guard animated, isVisible, !reducesMotion(), target != frame else {
            setFrame(target, display: true)
            settingsView.isHidden = !expanded
            isResizing = false
            invalidateShadow()
            return
        }
        isResizing = true
        // NSWindow owns the resize animation and its display scheduling. Keep
        // both hosts unchanged while its clipping boundary moves.
        setFrame(target, display: true, animate: true)
        guard generation == currentGeneration else { return }
        settingsView.isHidden = !presentation.isExpanded
        isResizing = false
        invalidateShadow()
        if contentLayoutDeferred {
            contentLayoutDeferred = false
            scheduleLayout(animated: false)
        }
    }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        Self.resizeDuration
    }

    override func orderOut(_ sender: Any?) {
        generation += 1
        presentation.isExpanded = false
        updateLayout(animated: false)
        super.orderOut(sender)
    }

    override var canBecomeKey: Bool { true }
}

private final class InlinePanelMaterial: NSVisualEffectView {
    override var isFlipped: Bool { true }
}
