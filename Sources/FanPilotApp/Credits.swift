import AppKit
import SwiftUI

/// Who made FanPilot, and where to find them. One place, so the About panel, the Settings "About"
/// pane, the menu panel footer and the README never disagree.
enum Credits {
    static let author = "zyvren"
    static let githubURL = URL(string: "https://github.com/zyvren")!
    static let xURL = URL(string: "https://x.com/zyvre_ic")!
    static let githubLabel = "github.com/zyvren"
    static let xLabel = "@zyvre_ic"

    static var appName: String { "FanPilot" }

    /// The marketing version from Info.plist; a bare `swift run` binary has no bundle, hence the fallback.
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// "1.0 (42)" when the build number is known, "1.0" otherwise.
    static var versionDescription: String {
        if let build, !build.isEmpty { return "\(version) (\(build))" }
        return version
    }

    static var copyright: String {
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String)
            ?? "\u{00A9} 2026 \(author). All rights reserved."
    }

    /// The text under the version in the standard About panel: centered, small, `labelColor` so it
    /// reads in light and dark appearance, with the two links clickable.
    static func creditsText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 3
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        func link(_ label: String, _ url: URL) -> NSAttributedString {
            var attributes = plain
            attributes[.link] = url
            return NSAttributedString(string: label, attributes: attributes)
        }

        let text = NSMutableAttributedString()
        var bold = plain
        bold[.font] = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        text.append(NSAttributedString(string: "Created by \(author)\n", attributes: bold))
        text.append(NSAttributedString(string: "GitHub: ", attributes: plain))
        text.append(link(githubLabel, githubURL))
        text.append(NSAttributedString(string: "\n", attributes: plain))
        text.append(NSAttributedString(string: "X: ", attributes: plain))
        text.append(link(xLabel, xURL))
        return text
    }

    /// Brings up the standard About panel with the credits filled in.
    @MainActor
    static func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .applicationVersion: version,
            .credits: creditsText(),
        ]
        if let build, !build.isEmpty { options[.version] = build }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

/// Settings > About: icon, name, version, the author and two link buttons.
struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(Credits.appName).font(.system(size: 24, weight: .semibold))
                Text("Version \(Credits.versionDescription)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("Fan control and temperature monitor for Apple Silicon Macs.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Text("Created by \(Credits.author)").font(.system(size: 15, weight: .medium))
                HStack(spacing: 10) {
                    Link(destination: Credits.githubURL) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .frame(minWidth: 96)
                    }
                    Link(destination: Credits.xURL) {
                        Label("X", systemImage: "at")
                            .frame(minWidth: 96)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                VStack(spacing: 2) {
                    Text(Credits.githubLabel)
                    Text(Credits.xLabel)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(.top, 8)

            Spacer()
            Text(Credits.copyright).font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
