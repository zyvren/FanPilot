import AppKit
import SwiftUI

/// Settings panes in toolbar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, menuBar, notifications, log, fan, helper, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .notifications: return "Notifications"
        case .log: return "Log"
        case .fan: return "Fans"
        case .helper: return "Helper"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .notifications: return "bubble.middle.bottom"
        case .log: return "doc.plaintext"
        case .fan: return "fan"
        case .helper: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    /// Content size of the pane; the window animates to it when the pane changes.
    var size: NSSize {
        switch self {
        case .general: return NSSize(width: 560, height: 720)
        case .menuBar: return NSSize(width: 620, height: 800)
        case .notifications: return NSSize(width: 600, height: 700)
        case .log: return NSSize(width: 600, height: 620)
        case .fan: return NSSize(width: 860, height: 780)
        case .helper: return NSSize(width: 620, height: 760)
        case .about: return NSSize(width: 600, height: 440)
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane

    init() {
        pane = SettingsPane(rawValue: AppModel.shared.extras.settingsPane) ?? .general
    }
}

/// Owns the two windows and shows them on demand.
///
/// SwiftUI `Window` scenes open at launch and are awkward to raise from a menu bar app without a Dock
/// icon, so both windows are plain `NSWindow`s hosting SwiftUI content. That also allows the
/// toolbar-style pane switcher of the Settings window.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = WindowCoordinator()

    let mainNavigation = MainNavigation()
    private lazy var settingsNavigation = SettingsNavigation()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsToolbarHasFans = true
    private var quickPanel: QuickPanel?
    private var quickPanelObserver: NSObjectProtocol?

    // MARK: Main window

    func showMainWindow(page: MainPage? = nil) {
        if let page { mainNavigation.page = page }
        if mainWindow == nil { mainWindow = makeMainWindow() }
        present(mainWindow)
    }

    private func makeMainWindow() -> NSWindow {
        let root = MainWindowView()
            .environmentObject(AppModel.shared)
            .environmentObject(mainNavigation)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "FanPilot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // The Overview stacks fixed-height blocks (page picker, Fans, Diagnostics, about 365 pt); the sensor
        // table gets what is left, so the minimum must leave it room for a few rows plus a banner.
        window.contentMinSize = NSSize(width: 600, height: AppWindowMetrics.minContentHeight)
        window.setContentSize(NSSize(width: 900, height: 700))
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("FanPilotMainWindow")
        if !window.setFrameUsingName("FanPilotMainWindow") { window.center() }
        window.setFrameAutosaveName("FanPilotMainWindow")
        return window
    }

    // MARK: Settings window

    func showSettings(pane: SettingsPane? = nil) {
        if let pane { settingsNavigation.pane = pane }
        let hasFans = AppModel.shared.hasFans
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        } else if hasFans != settingsToolbarHasFans {
            rebuildToolbar(hasFans: hasFans)
        }
        // The Fan pane exists only on Macs with fans.
        if settingsNavigation.pane == .fan, !hasFans { settingsNavigation.pane = .general }
        apply(pane: settingsNavigation.pane, animated: false)
        present(settingsWindow)
    }

    private func makeSettingsWindow() -> NSWindow {
        let root = SettingsRootView()
            .environmentObject(AppModel.shared)
            .environmentObject(settingsNavigation)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: settingsNavigation.pane.size),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "FanPilot Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("FanPilotSettingsWindow")

        settingsToolbarHasFans = AppModel.shared.hasFans
        let toolbar = NSToolbar(identifier: "FanPilotSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.center()
        return window
    }

    private func visiblePanes(hasFans: Bool) -> [SettingsPane] {
        SettingsPane.allCases.filter { hasFans || $0 != .fan }
    }

    private func rebuildToolbar(hasFans: Bool) {
        guard let toolbar = settingsWindow?.toolbar else { return }
        settingsToolbarHasFans = hasFans
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for pane in visiblePanes(hasFans: hasFans) {
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(pane.rawValue), at: toolbar.items.count)
        }
    }

    @objc private func paneItemClicked(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        settingsNavigation.pane = pane
        apply(pane: pane, animated: true)
    }

    /// Selects the toolbar item and resizes the window to the pane, keeping the top-left corner.
    func apply(pane: SettingsPane, animated: Bool) {
        guard let window = settingsWindow else { return }
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        AppModel.shared.extras.settingsPane = pane.rawValue
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.size))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        if let screen = window.screen ?? NSScreen.main {
            // Keep the window on screen when a tall pane opens near the bottom.
            let visible = screen.visibleFrame
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        }
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        visiblePanes(hasFans: settingsToolbarHasFans).map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(paneItemClicked(_:))
        return item
    }

    // MARK: Quick panel (keyboard shortcut)

    /// The menu panel for the "open the menu" shortcut. SwiftUI offers no way to open a MenuBarExtra
    /// panel from code (neither `performClick` nor posted mouse events reach it), so the shortcut shows
    /// the same content in a panel of our own, placed under the menu bar item.
    func toggleQuickPanel() {
        if let panel = quickPanel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let panel = quickPanel ?? makeQuickPanel()
        quickPanel = panel
        guard let host = panel.contentView?.subviews.compactMap({ $0 as? NSHostingView<AnyView> }).first else { return }
        let size = NSSize(width: Theme.panelWidth, height: min(max(host.fittingSize.height, 120), 760))
        panel.setContentSize(size)
        var origin = NSPoint(x: 0, y: 0)
        if let item = StatusItemLocator.button()?.window?.frame, let screen = NSScreen.screens.first(where: { $0.frame.intersects(item) }) ?? NSScreen.main {
            origin = NSPoint(x: item.midX - size.width / 2, y: item.minY - size.height - 2)
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeQuickPanel() -> QuickPanel {
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        let content = AnyView(MenuContentView().environmentObject(AppModel.shared))
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        quickPanelObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak panel] _ in
            panel?.orderOut(nil)
        }
        return panel
    }

    // MARK: Showing

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    var isMainWindowVisible: Bool { mainWindow?.isVisible ?? false }

    // For UISnapshotter.
    var mainWindowForSnapshot: NSWindow? { mainWindow }
    var settingsWindowForSnapshot: NSWindow? { settingsWindow }
}

/// A borderless panel that can take the keyboard focus, so it closes when the user clicks elsewhere.
private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Sizes the main window's minimum is derived from.
enum AppWindowMetrics {
    /// The sensor list (sidebar + table with its header and footer) never gets smaller than this:
    /// about five rows between the 22 pt header and the 28 pt footer.
    static let minSensorAreaHeight: CGFloat = 170
    static let minContentHeight: CGFloat = 580
}
