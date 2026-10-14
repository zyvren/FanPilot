import Foundation

/// Paths, identifiers and protocol limits shared by the app, the CLI and the root helper.
public enum Constants {
    // MARK: Identity

    /// Reverse-DNS prefix for everything FanPilot owns.
    public static let bundleIDPrefix = "com.fanpilot"
    public static let appBundleID = "com.fanpilot.app"
    /// launchd label of the root helper (also the installed binary's file name).
    public static let helperLabel = "com.fanpilot.helper"
    /// Version reported in `hello` replies.
    public static let helperVersion = "1.0.0"
    /// Wire protocol version (docs/SPEC.md 4.4).
    public static let protocolVersion = 1

    // MARK: Install layout (docs/SPEC.md 4.2; all root-owned)

    public static let socketPath = "/var/run/fanpilot.sock"
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/com.fanpilot.helper"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.fanpilot.helper.plist"
    public static let supportDirectory = "/Library/Application Support/FanPilot"
    public static let helperConfigPath = "/Library/Application Support/FanPilot/helper.json"
    public static let helperLogPath = "/var/log/fanpilot.log"
    /// os_log subsystem used by the helper.
    public static let helperLogSubsystem = "com.fanpilot.helper"

    // MARK: App persistence

    /// UserDefaults key holding the single JSON blob of `AppSettings`.
    public static let settingsDefaultsKey = "fanpilot.settings.v1"

    // MARK: Wire limits and timing (SPEC 4.3, 4.4, 4.5)

    /// Longest allowed NDJSON line, in bytes, newline excluded.
    public static let maxLineBytes = 64 * 1024
    /// A new connection must send `hello` within this many seconds or it is closed.
    public static let helloTimeoutSeconds: TimeInterval = 2
    public static let maxConnections = 4
    /// Lease TTL used when a request omits `ttl`.
    public static let defaultLeaseSeconds: TimeInterval = 15
    /// How often the app sends `heartbeat`.
    public static let heartbeatIntervalSeconds: TimeInterval = 5
    /// Send timeout on sockets so a client that stops reading cannot stall the helper.
    public static let socketSendTimeoutSeconds: TimeInterval = 5

    // MARK: Safety limits

    /// Highest failsafe temperature the helper accepts from its config (SPEC 4.5 #6).
    public static let failsafeTempMaxC: Double = 100
    public static let failsafeTempMinC: Double = 85
    public static let defaultFailsafeTempC: Double = 95
    public static let defaultLeaseMaxSeconds: TimeInterval = 30
    /// Highest fan number addressable with the single digit in the SMC key.
    public static let maxFanIndex = 9
    /// Sanity cap on any RPM value accepted from a client; the helper then clamps to the live
    /// `[Mn, Mx]` of the fan.
    public static let rpmSanityCeiling: Double = 100_000

    // MARK: Sensor validity (SPEC 2.4 #4)

    /// A temperature reading counts as valid in `[minValidTempC, maxValidTempC)`.
    public static let minValidTempC: Double = 10
    public static let maxValidTempC: Double = 125

    /// True if `celsius` is a plausible live temperature (finite and in the valid window).
    public static func isValidTemperature(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius >= minValidTempC && celsius < maxValidTempC
    }
}
