import AppKit
import CryptoKit
import FanPilotKit
import Foundation

/// "Check for Updates…": asks GitHub for the latest release and, when it is newer, downloads the
/// disk image, checks its SHA-256, copies the app out of it and swaps it in place of this one, then
/// relaunches. The only network access FanPilot makes, and only when the user asks.
///
/// shortcut: the checksum comes from the same GitHub release as the image, so it guards against a
/// broken or altered download, not against a compromised repository; signing updates (Sparkle-style
/// EdDSA, or a Developer ID) is the upgrade if that matters.
@MainActor
enum Updater {
    private static var busy = false

    static func checkForUpdates() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let release = try await latestRelease()
                guard AppVersion.isNewer(release.version, than: Credits.version) else {
                    alert("FanPilot is up to date", "Version \(Credits.version) is the latest.")
                    return
                }
                switch offer(release) {
                case .alertFirstButtonReturn: try await install(release)
                case .alertSecondButtonReturn: if let page = release.pageURL { NSWorkspace.shared.open(page) }
                default: break
                }
            } catch {
                alert("Update failed", "\(error.localizedDescription)\n\nYou can download FanPilot from its GitHub releases page.")
            }
        }
    }

    // MARK: Steps

    private static func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: ReleaseInfo.latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FanPilot/\(Credits.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try expectOK(response)
        return try ReleaseInfo.parse(data)
    }

    private static func offer(_ release: ReleaseInfo) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "FanPilot \(release.version) is available"
        let notes = release.notes.count > 900 ? String(release.notes.prefix(900)) + "\u{2026}" : release.notes
        alert.informativeText = "You have \(Credits.version).\n\n\(notes)"
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Release Page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private static func install(_ release: ReleaseInfo) async throws {
        AppModel.shared.postNotice("Downloading FanPilot \(release.version)\u{2026}", dismissAfter: 60)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("FanPilot-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        try expectOK(checksumResponse)
        guard let expected = ReleaseInfo.checksum(fromShasumOutput: String(decoding: checksumData, as: UTF8.self)) else {
            throw UpdateError("The release has no valid checksum.")
        }
        let (downloaded, dmgResponse) = try await URLSession.shared.download(from: release.dmgURL)
        try expectOK(dmgResponse)
        let dmg = work.appendingPathComponent(release.dmgURL.lastPathComponent)
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw UpdateError("The download is damaged (checksum mismatch).") }

        let current = Bundle.main.bundleURL
        let folder = current.deletingLastPathComponent()
        // A copy we cannot replace (read-only volume, translocated, no write access): let Finder do it.
        guard current.pathExtension == "app", !current.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: folder.path),
              FileManager.default.isWritableFile(atPath: current.path) else {
            NSWorkspace.shared.open(dmg)
            alert("Finish the update in Finder", "FanPilot cannot replace itself where it is. Drag the new FanPilot onto Applications, then open it.")
            return
        }

        // Copy the app next to the current one (same volume, so the final swap is a rename).
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        let staged = folder.appendingPathComponent(".FanPilot-\(release.version).app")
        try? FileManager.default.removeItem(at: staged)
        let copied = Result { try run("/usr/bin/ditto", [mount.appendingPathComponent("FanPilot.app").path, staged.path]) }
        _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
        _ = try copied.get()

        // The copy must be FanPilot, of the advertised version, with an intact signature.
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError("The downloaded app is not the expected FanPilot \(release.version).")
        }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) } catch {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError("The downloaded app's signature is invalid.")
        }

        // Swap once this process has exited (quitting releases the fans first), then relaunch.
        // On a failed move the old copy is put back.
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2.old"
        if /bin/mv "$2" "$2.old" && /bin/mv "$3" "$2"; then /bin/rm -rf "$2.old"; else [ -d "$2" ] || /bin/mv "$2.old" "$2"; fi
        /bin/rm -rf "$4"
        /usr/bin/open "$2"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "fanpilot-update", String(getpid()), current.path, staged.path, work.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private struct UpdateError: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static func expectOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError("GitHub answered with an error (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
