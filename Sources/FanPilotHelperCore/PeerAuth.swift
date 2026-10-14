import Darwin
import FanPilotKit
import Foundation
import Security

// Peer authorization (docs/SPEC.md 4.3). The socket file is world-writable (0666) so any local user
// can connect; this decides, per connection and from kernel-supplied credentials, who may talk.

/// The verdict for one connection, with what the log needs.
public struct PeerDecision: Equatable, Sendable {
    public var allowed: Bool
    public var uid: UInt32?
    public var pid: Int32?
    public var processPath: String?
    /// Why the peer was accepted or refused.
    public var reason: String

    public init(allowed: Bool, uid: UInt32? = nil, pid: Int32? = nil, processPath: String? = nil, reason: String) {
        self.allowed = allowed
        self.uid = uid
        self.pid = pid
        self.processPath = processPath
        self.reason = reason
    }

    /// One line for the log.
    public var summary: String {
        let who = "uid \(uid.map(String.init) ?? "?") pid \(pid.map(String.init) ?? "?") \(processPath ?? "?")"
        return "\(allowed ? "accepted" : "REFUSED") \(who): \(reason)"
    }
}

public protocol PeerAuthorizer: AnyObject {
    func authorize(_ connection: LineSocketConnection) -> PeerDecision
}

/// uid allow-list from `helper.json`, optionally with a pinned code-directory hash.
public final class ConfigPeerAuthorizer: PeerAuthorizer {
    public let config: HelperConfig
    /// Returns the hex cdhash of the peer. Injectable for tests; the default asks the Security
    /// framework about the peer's audit token.
    private let cdhashOfPeer: (LineSocketConnection) -> String?

    public init(config: HelperConfig,
                cdhashOfPeer: @escaping (LineSocketConnection) -> String? = { connection in
                    connection.peerAuditTokenData().flatMap { CodeSignature.cdhash(auditToken: $0) }
                }) {
        self.config = config
        self.cdhashOfPeer = cdhashOfPeer
    }

    public func authorize(_ connection: LineSocketConnection) -> PeerDecision {
        guard let credentials = connection.peerCredentials() else {
            return PeerDecision(allowed: false, reason: "peer credentials unavailable")
        }
        let uid = UInt32(credentials.uid)
        let pid = Int32(credentials.pid)
        // No process path here: proc_pidpath is a syscall per connection, and any local user can open
        // connections at will. The server looks it up only for the log lines it actually writes.
        let path: String? = nil

        guard config.isUIDAllowed(uid) else {
            return PeerDecision(allowed: false, uid: uid, pid: pid, processPath: path,
                                reason: "uid \(uid) is not root and not in allowedUIDs")
        }
        guard config.authMode == .pinned, uid != 0 else {
            // Root can bypass any check by writing the SMC itself, so pinning adds nothing for it.
            return PeerDecision(allowed: true, uid: uid, pid: pid, processPath: path,
                                reason: uid == 0 ? "root" : "uid allowed")
        }

        guard let hash = cdhashOfPeer(connection) else {
            return PeerDecision(allowed: false, uid: uid, pid: pid, processPath: path,
                                reason: "pinned mode: cannot determine the peer's code signature")
        }
        guard config.isCdhashPinned(hash) else {
            return PeerDecision(allowed: false, uid: uid, pid: pid, processPath: path,
                                reason: "pinned mode: cdhash \(hash) is not in pinnedCdhashes")
        }
        return PeerDecision(allowed: true, uid: uid, pid: pid, processPath: path,
                            reason: "uid allowed, cdhash \(hash) pinned")
    }

    public static func processPath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }
}

/// Accepts everyone. For tests and for `--allow-any-uid` development runs only.
public final class AllowAllPeerAuthorizer: PeerAuthorizer {
    public init() {}
    public func authorize(_ connection: LineSocketConnection) -> PeerDecision {
        PeerDecision(allowed: true, uid: connection.peerCredentials().map { UInt32($0.uid) }, reason: "allow-all")
    }
}

/// Code signature lookups through the Security framework.
public enum CodeSignature {
    /// Hex code-directory hash of the process identified by a raw `audit_token_t` (32 bytes).
    /// Nil if the code cannot be identified or does not pass the dynamic validity check.
    public static func cdhash(auditToken: Data) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        // The running process must still match its signature (no page tampering since launch).
        guard SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { return nil }
        return cdhash(of: code)
    }

    /// Hex cdhash of the current process, for tests and diagnostics.
    public static func cdhashOfCurrentProcess() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        return cdhash(of: code)
    }

    /// Hex cdhash of a file on disk (an app bundle or a Mach-O).
    public static func cdhash(ofFileAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return cdhash(ofStatic: staticCode)
    }

    private static func cdhash(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return cdhash(ofStatic: staticCode)
    }

    private static func cdhash(ofStatic staticCode: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}

/// Loads `helper.json` only if it cannot have been tampered with.
public enum TrustedConfig {
    public struct Result: Sendable {
        public var config: HelperConfig
        /// Set when the file was refused or missing; `config` is then the restrictive default
        /// (nobody but root may connect).
        public var warning: String?
    }

    /// - Parameter trustedUID: the uid that must own the file and its directory (root in production).
    public static func load(path: String, trustedUID: uid_t = 0) -> Result {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return Result(config: HelperConfig(), warning: "\(path) does not exist; only root may connect")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return Result(config: HelperConfig(), warning: "\(path) is not a regular file; ignoring it")
        }
        guard info.st_uid == trustedUID, info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return Result(config: HelperConfig(),
                          warning: "\(path) must be owned by uid \(trustedUID) and not writable by group or others; ignoring it")
        }

        let directory = (path as NSString).deletingLastPathComponent
        var dirInfo = stat()
        guard stat(directory, &dirInfo) == 0, dirInfo.st_uid == trustedUID,
              dirInfo.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return Result(config: HelperConfig(),
                          warning: "\(directory) must be owned by uid \(trustedUID) and not writable by group or others; ignoring \(path)")
        }
        return Result(config: HelperConfig.load(from: path), warning: nil)
    }
}
