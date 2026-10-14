import AppKit
import Foundation
import SwiftUI

/// Development aid: `FanPilot --snapshot-ui DIR` waits for the first sensor snapshot, opens each
/// window, pane and the menu panel, writes them as PNG files into DIR and quits. It draws the views
/// in-process, so it needs no screen recording permission, and it never touches the fans.
@MainActor
enum UISnapshotter {
    static func run(into directory: URL) {
        Task { @MainActor in
            let model = AppModel.shared
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // Wait for data (the first poll takes about a second).
            for _ in 0..<60 where !model.hasSnapshot { try? await Task.sleep(nanoseconds: 250_000_000) }
            try? await Task.sleep(nanoseconds: 2_500_000_000)

            for page in MainPage.allCases {
                WindowCoordinator.shared.showMainWindow(page: page)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                save(window: WindowCoordinator.shared.mainWindowForSnapshot, name: "main-\(page.rawValue)", in: directory)
            }
            for pane in SettingsPane.allCases {
                WindowCoordinator.shared.showSettings(pane: pane)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                save(window: WindowCoordinator.shared.settingsWindowForSnapshot, name: "settings-\(pane.rawValue)", in: directory)
            }

            await saveAboutVariants(in: directory)

            saveStatusItem(model: model, in: directory)

            // The real MenuBarExtra panel cannot be opened without a user click, so render the same view
            // in an off-screen window.
            await savePanel(model: model, in: directory)

            fputs("snapshots written to \(directory.path)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    /// The credits in both appearances: the Settings "About" pane (the plain `settings-about` shot
    /// follows the system appearance) and the standard About panel with its clickable credits text.
    private static func saveAboutVariants(in directory: URL) async {
        WindowCoordinator.shared.showSettings(pane: .about)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let window = WindowCoordinator.shared.settingsWindowForSnapshot {
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: name)
                try? await Task.sleep(nanoseconds: 800_000_000)
                save(window: window, name: "settings-about-\(suffix)", in: directory)
            }
            window.appearance = nil
        }

        // The standard panel is a singleton that AppKit does not expose: it is the window that
        // appears when it is first shown, and the same window again afterwards.
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        Credits.showAboutPanel()
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let panel = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.isVisible }) else {
            print("no About panel window")
            return
        }
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            panel.appearance = NSAppearance(named: name)
            // The panel's background is drawn by the window frame, outside the content view, so the
            // content view alone renders on transparent white and the dark appearance's light text
            // would vanish. Give the content view the window background for the snapshot.
            var background = NSColor.windowBackgroundColor.cgColor
            panel.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.backgroundColor = background
            try? await Task.sleep(nanoseconds: 800_000_000)
            save(window: panel, name: "about-panel-\(suffix)", in: directory)
        }
        panel.close()
    }

    private static func savePanel(model: AppModel, in directory: URL) async {
        let host = NSHostingView(rootView: MenuContentView().environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let fitting = host.fittingSize
        window.setContentSize(NSSize(width: Theme.panelWidth, height: max(fitting.height, 100)))
        try? await Task.sleep(nanoseconds: 800_000_000)
        save(window: window, name: "menu-panel", in: directory)
        window.close()
    }

    private static func save(window: NSWindow?, name: String, in directory: URL) {
        guard let window, let view = window.contentView else {
            print("no window for \(name)")
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// The menu bar image on a mid-gray backdrop, scaled up, in both menu bar tints.
    private static func saveStatusItem(model: AppModel, in directory: URL) {
        let image = model.statusImage
        let scale: CGFloat = 4
        for (name, dark) in [("light", false), ("dark", true)] {
            let size = NSSize(width: (image.size.width + 20) * scale, height: image.size.height * scale)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let tint: NSColor = dark ? .white : .black
            if image.isTemplate {
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: 10 * scale, y: 0, width: image.size.width * scale, height: size.height))
            } else {
                image.draw(in: NSRect(x: 10 * scale, y: 0, width: image.size.width * scale, height: size.height))
            }
            canvas.unlockFocus()
            if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("statusitem-\(name).png"))
            }
        }
    }
}
