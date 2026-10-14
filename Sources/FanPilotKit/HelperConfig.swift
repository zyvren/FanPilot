import Foundation

/// The root helper's configuration, `/Library/Application Support/FanPilot/helper.json`
/// (docs/SPEC.md 4.2). Root-owned; edited only through the install script or sudo.
///
/// Decoding is tolerant: any missing or malformed key takes its default. The defaults are the
/// restrictive ones (nobody but root may connect), so a damaged file fails closed.
public struct HelperConfig: Codable, Equatable, Sendable {
    public enum AuthMode: String, Codable, Sendable {
        /// Peer uid must be root or in `allowedUIDs`.
        case uid
        /// Additionally the peer's code directory hash must be in `pinnedCdhashes`.
        case pinned
    }

    /// uids allowed to talk to the helper besides root (the install script writes `$SUDO_UID`).
    public var allowedUIDs: [UInt32]
    public var authMode: AuthMode
    /// Hex cdhashes of the installed app and CLI, for `pinned` mode.
    public var pinnedCdhashes: [String]
    /// Temperature at which the helper forces all fans to maximum. Clamped to 85...100.
    public var failsafeTempC: Double
    /// Upper bound for any client lease TTL. Clamped to 5...120.
    public var leaseMaxSeconds: Double
    public var socketPath: String

    public static let defaultSocketPath = Constants.socketPath

    public init(allowedUIDs: [UInt32] = [],
                authMode: AuthMode = .uid,
                pinnedCdhashes: [String] = [],
                failsafeTempC: Double = Constants.defaultFailsafeTempC,
                leaseMaxSeconds: Double = Constants.defaultLeaseMaxSeconds,
                socketPath: String = HelperConfig.defaultSocketPath) {
        self.allowedUIDs = allowedUIDs
        self.authMode = authMode
        self.pinnedCdhashes = pinnedCdhashes
        self.failsafeTempC = failsafeTempC
        self.leaseMaxSeconds = leaseMaxSeconds
        self.socketPath = socketPath
        self = normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case allowedUIDs, authMode, pinnedCdhashes, failsafeTempC, leaseMaxSeconds, socketPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(allowedUIDs: c.value(.allowedUIDs, default: []),
                  authMode: c.value(.authMode, default: .uid),
                  pinnedCdhashes: c.value(.pinnedCdhashes, default: []),
                  failsafeTempC: c.value(.failsafeTempC, default: Constants.defaultFailsafeTempC),
                  leaseMaxSeconds: c.value(.leaseMaxSeconds, default: Constants.defaultLeaseMaxSeconds),
                  socketPath: c.value(.socketPath, default: HelperConfig.defaultSocketPath))
    }

    /// A copy with every value forced into its safe range (the failsafe can never be raised above
    /// 100 C, an empty socket path falls back to the default, cdhashes are lowercased).
    public func normalized() -> HelperConfig {
        var copy = self
        copy.failsafeTempC = sanitized(failsafeTempC,
                                       in: Constants.failsafeTempMinC...Constants.failsafeTempMaxC,
                                       fallback: Constants.defaultFailsafeTempC)
        copy.leaseMaxSeconds = sanitized(leaseMaxSeconds, in: 5...120, fallback: Constants.defaultLeaseMaxSeconds)
        if copy.socketPath.isEmpty { copy.socketPath = Self.defaultSocketPath }
        copy.pinnedCdhashes = copy.pinnedCdhashes.map { $0.lowercased() }
        return copy
    }

    /// True if a peer with this uid may connect (root always may).
    public func isUIDAllowed(_ uid: UInt32) -> Bool {
        uid == 0 || allowedUIDs.contains(uid)
    }

    /// True if `cdhash` (hex) is pinned.
    public func isCdhashPinned(_ cdhash: String) -> Bool {
        pinnedCdhashes.contains(cdhash.lowercased())
    }

    // MARK: Persistence

    /// Decodes a config from JSON data; unreadable data yields the restrictive defaults.
    public static func decode(from data: Data) -> HelperConfig {
        (try? PersistedJSON.makeDecoder().decode(HelperConfig.self, from: data)) ?? HelperConfig()
    }

    /// Loads the config file. A missing or unreadable file yields the restrictive defaults.
    public static func load(from path: String = Constants.helperConfigPath) -> HelperConfig {
        guard let data = FileManager.default.contents(atPath: path) else { return HelperConfig() }
        return decode(from: data)
    }

    public func encoded() throws -> Data {
        try PersistedJSON.makeEncoder().encode(self)
    }
}
