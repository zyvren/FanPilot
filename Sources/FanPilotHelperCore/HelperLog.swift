import FanPilotKit
import Foundation
import os

/// Logging for the root helper: `os_log` (subsystem `com.fanpilot.helper`) plus one line per event
/// on stderr, which launchd redirects to `/var/log/fanpilot.log` (docs/SPEC.md 4.5 #9).
///
/// Every takeover and release is logged with its reason, because after a thermal incident this log
/// is the only record of what the root process did to the fans.
public enum HelperLog {
    public enum Level: String, Sendable {
        case debug, info, warning, error, critical
    }

    public typealias Sink = @Sendable (Level, String) -> Void

    private static let lock = NSLock()
    private static var customSink: Sink?
    private static var verbose = false
    private static let osLogger = Logger(subsystem: Constants.helperLogSubsystem, category: "helper")
    /// Milliseconds matter: whole seconds cannot show how long one fan write takes.
    /// ISO8601DateFormatter is thread-safe, so one shared instance serves every caller.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Replaces the output (tests capture messages with this). Pass nil to restore the default.
    public static func setSink(_ sink: Sink?) {
        lock.lock(); defer { lock.unlock() }
        customSink = sink
    }

    /// Enables `debug` lines in the default sink.
    public static func setVerbose(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        verbose = on
    }

    public static func log(_ level: Level, _ message: @autoclosure () -> String) {
        lock.lock()
        let sink = customSink
        let showDebug = verbose
        lock.unlock()

        let text = sanitized(message())
        if let sink {
            sink(level, text)
            return
        }
        if level == .debug && !showDebug { return }

        switch level {
        case .debug: osLogger.debug("\(text, privacy: .public)")
        case .info: osLogger.info("\(text, privacy: .public)")
        case .warning: osLogger.warning("\(text, privacy: .public)")
        case .error: osLogger.error("\(text, privacy: .public)")
        case .critical: osLogger.critical("\(text, privacy: .public)")
        }
        let stamp = timestampFormatter.string(from: Date())
        keepLogFileBounded()
        StandardError.write("\(stamp) [\(level.rawValue.uppercased())] \(text)\n")
    }

    /// One log record is exactly one line. Peer-controlled strings (a client's process path can
    /// contain newlines) must not be able to forge a record, so control characters are shown as
    /// `\xNN` instead of being written raw.
    public static func sanitized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) else { return text }
        var out = ""
        for scalar in text.unicodeScalars {
            if (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F {
                out += String(format: "\\x%02X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The log lives on the system volume and launchd keeps stderr open on it, so newsyslog-style
    /// rotation would leave this process writing to an unlinked file. Instead the daemon bounds the
    /// file itself: past `maxLogBytes` it starts over, so logging can never fill the disk.
    public static let maxLogBytes: Int64 = 8 * 1024 * 1024
    private static var writesSinceCheck = 0

    private static func keepLogFileBounded() {
        lock.lock()
        writesSinceCheck += 1
        let due = writesSinceCheck >= 32
        if due { writesSinceCheck = 0 }
        lock.unlock()
        guard due else { return }
        var info = stat()
        guard fstat(STDERR_FILENO, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > maxLogBytes else { return }
        if ftruncate(STDERR_FILENO, 0) == 0 {
            StandardError.write("\(timestampFormatter.string(from: Date())) [WARNING] log file passed \(maxLogBytes / 1024 / 1024) MiB and was truncated\n")
        }
    }

    public static func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public static func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public static func error(_ message: @autoclosure () -> String) { log(.error, message()) }
    public static func critical(_ message: @autoclosure () -> String) { log(.critical, message()) }
}
