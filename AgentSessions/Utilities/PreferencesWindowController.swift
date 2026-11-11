import SwiftUI
import AppKit

@MainActor final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var hostingView: AppearanceHostingView?
    private var distributedObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppAppearanceRaw: String = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
    private weak var indexer: SessionIndexer?
    private weak var updaterController: UpdaterController?
    private var initialTab: PreferencesTab = .general

    func show(indexer: SessionIndexer,
              updaterController: UpdaterController,
              initialTab: PreferencesTab = .general) {
        self.indexer = indexer
        self.updaterController = updaterController
        self.initialTab = initialTab
        let wrapped = makeRootView()

        if let win = window, let hv = hostingView {
            hv.rootView = wrapped
            applyAppearance(forceRedraw: true)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hv = AppearanceHostingView(rootView: wrapped)
        // The pane title (navigationTitle) and the split view's toolbar come from SwiftUI.
        hv.sceneBridgingOptions = [.toolbars, .title]
        hv.onAppearanceChanged = { [weak self] in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // System Settings layout: the sidebar runs the full window height under the
        // traffic lights, and the pane title sits in a unified toolbar over the detail.
        win.toolbarStyle = .unified
        win.contentView = hv
        win.title = String(localized: "Settings", comment: "Title of the Settings window.")
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("PreferencesWindow")
        win.setContentSize(NSSize(width: 800, height: 640))
        win.contentMinSize = NSSize(width: 800, height: 520)
        win.delegate = self
        self.window = win
        hostingView = hv
        applyAppearance(forceRedraw: false)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Don't open with the first path field focused, as System Settings doesn't.
        DispatchQueue.main.async { win.makeFirstResponder(nil) }

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppearancePreferenceChange()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Keep controller but drop the window so it can be rebuilt later
        if let win = notification.object as? NSWindow, win == window {
            window = nil
            hostingView = nil
            if let o = distributedObserver { DistributedNotificationCenter.default().removeObserver(o) }
            distributedObserver = nil
            if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
            defaultsObserver = nil
        }
    }
}

private struct PreferencesWindowRoot: View {
    let initialTab: PreferencesTab
    let indexer: SessionIndexer
    let updaterController: UpdaterController
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        // `.id(initialTab)` so reopening the already-open window at a different
        // tab actually switches: without it SwiftUI preserves PreferencesView's
        // @State selection across the rootView swap and stays on the last pane.
        let content = PreferencesView(initialTab: initialTab)
            .id(initialTab)
            .environmentObject(indexer)
            .environmentObject(indexer.columnVisibility)
            .environmentObject(updaterController)

        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: content.preferredColorScheme(.light)
            case .dark: content.preferredColorScheme(.dark)
            case .system: content
            }
        }
    }
}

private extension PreferencesWindowController {
    func makeRootView() -> AnyView {
        guard let indexer, let updaterController else {
            return AnyView(EmptyView())
        }
        return AnyView(
            PreferencesWindowRoot(
                initialTab: initialTab,
                indexer: indexer,
                updaterController: updaterController
            )
        )
    }

    func handleEffectiveAppearanceChange() {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        guard appAppearance == .system else { return }
        applyAppearance(forceRedraw: true)
    }

    func handleAppearancePreferenceChange() {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        guard raw != lastAppAppearanceRaw else { return }
        lastAppAppearanceRaw = raw
        applyAppearance(forceRedraw: true)
    }

    func applyAppearance(forceRedraw: Bool) {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        switch appAppearance {
        case .system:
            window?.appearance = nil
        case .light:
            window?.appearance = NSAppearance(named: .aqua)
        case .dark:
            window?.appearance = NSAppearance(named: .darkAqua)
        }
        guard forceRedraw, let hv = hostingView else { return }
        hv.needsLayout = true
        hv.setNeedsDisplay(hv.bounds)
        hv.displayIfNeeded()
    }
}
