import AppKit
import FanPilotKit
import SwiftUI

/// FanPilot: a menu bar app that shows temperatures and fan speeds and, with the root helper
/// installed, controls the fans. The only SwiftUI scene is the menu bar item; the main and settings
/// windows are managed by `WindowCoordinator` (see there for why).
@main
struct FanPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        // Development aid: print the exact privileged script the installer or uninstaller would run
        // (--print-install-command, --print-uninstall-command), then exit.
        // Nothing is executed and no password is requested.
        if CommandLine.arguments.contains("--print-install-command") {
            Self.printInstallCommandAndExit(.install)
        }
        if CommandLine.arguments.contains("--print-uninstall-command") {
            Self.printInstallCommandAndExit(.uninstall(purge: false))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // Only visible when the Dock icon is on and FanPilot has a menu bar of its own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { WindowCoordinator.shared.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("Show Main Window") { WindowCoordinator.shared.showMainWindow() }
                    .keyboardShortcut("0")
            }
        }
    }

    private static func printInstallCommandAndExit(_ action: HelperInstaller.Action) -> Never {
        guard let payload = HelperInstaller.payloadDirectory() else {
            StandardError.write("FanPilot: no helper payload directory\n")
            exit(1)
        }
        do {
            print(try HelperInstaller.privilegedScript(for: action, payload: payload, uid: getuid()))
            exit(0)
        } catch {
            StandardError.write("FanPilot: \(error)\n")
            exit(1)
        }
    }
}

/// The menu bar item's label: the drawn image from the model.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Image(nsImage: model.statusImage)
            .renderingMode(model.statusImage.isTemplate ? .template : .original)
            .accessibilityLabel("FanPilot")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            Self.installTerminationSignalHandlers()
            if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-ui"), CommandLine.arguments.count > flag + 1 {
                UISnapshotter.run(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true))
            }
        }
    }

    /// Quit with the fans released: a normal quit goes through here; SIGTERM (logout scripts, `kill`)
    /// is routed to the same path.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.prepareForTermination() }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the app in Finder or the Dock while it runs shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowCoordinator.shared.showMainWindow() }
        return false
    }

    @MainActor
    private static var signalSources: [DispatchSourceSignal] = []

    @MainActor
    private static func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
