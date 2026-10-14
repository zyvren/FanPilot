import CryptoKit
import FanPilotKit
import Foundation

/// Installs and removes the root helper by running the bundled scripts with administrator rights
/// (`osascript` + `do shell script ... with administrator privileges`). The app never does this
/// silently: every call here follows an explicit confirmation from the user (docs/SPEC.md 4.6).
///
/// Trust model, plainly: there is no Developer ID, so nothing can prove to macOS that the bundled
/// helper is ours, and the payload sits in a bundle the current user can usually write. Anything that
/// can already run as this user and edit the app bundle before the install is clicked gets its edit
/// run as root; the hashes below are taken from the very files being installed, so they do NOT
/// defend against that. Do not install from a bundle you do not trust, or use the terminal route
/// (`sudo scripts/install_helper.sh`) from a source tree you have reviewed.
///
/// What the hashes do buy: the app hashes the payload right before asking for the password, and the
/// privileged command copies it into a fresh root-owned directory, refuses symbolic links, verifies
/// the copy against those hashes and runs the scripts from the copy. A process that rewrites files
/// inside the app bundle (or retargets a link) while the password dialog is open gains nothing.
enum HelperInstaller {
    enum Action {
        case install
        case uninstall(purge: Bool)
    }

    enum Outcome: Equatable {
        case success(output: String)
        case cancelled
        case failure(String)
    }

    enum InstallerError: Error, CustomStringConvertible {
        case payloadMissing(String)

        var description: String {
            switch self {
            case .payloadMissing(let what): return what
            }
        }
    }

    /// Files that make up the payload, in the order they are listed in messages.
    static let payloadFiles = [
        "fanpilotd", "fanpilotctl", "install_helper.sh", "uninstall_helper.sh", "com.fanpilot.helper.plist.template",
    ]

    /// `FanPilot.app/Contents/Resources/helper`. Debug builds also honor `FANPILOT_HELPER_PAYLOAD`
    /// for development; a release build must never take root-run files from an environment variable.
    static func payloadDirectory() -> URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["FANPILOT_HELPER_PAYLOAD"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return Bundle.main.resourceURL?.appendingPathComponent("helper", isDirectory: true)
    }

    /// True when every payload file is present in the bundle.
    static var isPayloadAvailable: Bool {
        guard let dir = payloadDirectory() else { return false }
        return payloadFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// True if files of a previous install exist on disk.
    static var isInstalledOnDisk: Bool {
        FileManager.default.fileExists(atPath: Constants.helperInstallPath)
            || FileManager.default.fileExists(atPath: Constants.launchDaemonPlistPath)
    }

    // MARK: Building the command

    /// The `/bin/sh` script that runs as root. Pure and deterministic so it can be inspected
    /// (`FanPilot --print-install-command`).
    static func privilegedScript(for action: Action, payload: URL, uid: uid_t) throws -> String {
        var hashes: [(name: String, sha: String)] = []
        for name in payloadFiles {
            let url = payload.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                throw InstallerError.payloadMissing("The helper payload is incomplete: \(name) is missing from \(payload.path). Rebuild the app with scripts/build_app.sh.")
            }
            hashes.append((name, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }

        let command: String
        switch action {
        case .install:
            command = "/bin/bash ./install_helper.sh --daemon \"$PWD/fanpilotd\" --ctl \"$PWD/fanpilotctl\" --uid \(uid)"
        case .uninstall(let purge):
            command = "/bin/bash ./uninstall_helper.sh" + (purge ? " --purge" : "")
        }

        var lines: [String] = [
            "set -e",
            "STAGE=$(/usr/bin/mktemp -d /private/var/tmp/fanpilot-stage.XXXXXX)",
            "trap '/bin/rm -rf \"$STAGE\"' EXIT",
            "/usr/bin/ditto \(shellQuote(payload.path)) \"$STAGE/payload\"",
            "/usr/sbin/chown -R root:wheel \"$STAGE\"",
            "/bin/chmod -R go-w \"$STAGE\"",
            // ditto keeps symbolic links as links, and the install scripts would follow them again
            // later (after the hash check) to files this user can rewrite. Only plain files and
            // directories are acceptable in the copy.
            "if [ -n \"$(/usr/bin/find \"$STAGE/payload\" ! -type f ! -type d -print -quit)\" ]; then echo \"FanPilot: the helper payload contains links or special files; nothing was installed.\" >&2; exit 1; fi",
            "cd \"$STAGE/payload\"",
            "check() { [ -f \"$1\" ] && [ ! -L \"$1\" ] && [ \"$(/usr/bin/shasum -a 256 \"$1\" | /usr/bin/awk '{print $1}')\" = \"$2\" ] || { echo \"FanPilot: $1 changed after it was approved; nothing was installed.\" >&2; exit 1; }; }",
        ]
        lines += hashes.map { "check \($0.name) \($0.sha)" }
        lines.append("\(command) 2>&1")
        return lines.joined(separator: "\n")
    }

    /// Single-quotes `text` for `/bin/sh`.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `text` for use inside an AppleScript string literal.
    static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Running

    /// Asks macOS for the administrator password and runs the action. `completion` is called on the
    /// main queue. Safe to call from the main thread: the password dialog and the script run in a
    /// separate process.
    static func run(_ action: Action, completion: @escaping @Sendable (Outcome) -> Void) {
        let script: String
        do {
            guard let payload = payloadDirectory() else {
                throw InstallerError.payloadMissing("FanPilot cannot find its helper files (it is not running from an app bundle).")
            }
            script = try privilegedScript(for: action, payload: payload, uid: getuid())
        } catch {
            completion(.failure("\(error)"))
            return
        }

        let appleScript = "do shell script \"\(appleScriptEscape(script))\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = runOSAScript(appleScript)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func runOSAScript(_ source: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failure("Could not start osascript: \(error.localizedDescription)")
        }
        // Read before waiting so a chatty script cannot fill the pipe and stall.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 { return .success(output: stdout) }
        if stderr.contains("(-128)") || stderr.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }
        // AppleScript wraps the script's output in "execution error: <output> (<code>)".
        return .failure(stderr.isEmpty ? "The installer exited with status \(process.terminationStatus)." : stderr)
    }
}
