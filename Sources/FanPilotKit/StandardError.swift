import Foundation

/// Writes a line of diagnostics to stderr without any way to take the process down.
///
/// `FileHandle.standardError.write(_:)` raises an Objective-C exception (uncatchable from Swift) on
/// ENOSPC or EBADF, which aborts the process. For the root helper that means a full disk or a closed
/// stderr would crash-loop it. `fputs` just reports the error through its return value, which is
/// deliberately ignored: a log line that cannot be written is not worth dying for.
public enum StandardError {
    public static func write(_ text: String) {
        _ = fputs(text, stderr)
    }
}
