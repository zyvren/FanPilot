import Foundation

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `defaultValue` when the key is missing, null, or holds a
    /// value of the wrong type. Settings and config blobs are edited by hand, written by older
    /// versions and sometimes corrupted; none of that may stop the app from launching, so every
    /// persisted model decodes through this.
    func value<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) -> T {
        if let decoded = try? decodeIfPresent(T.self, forKey: key) {
            return decoded
        }
        return defaultValue()
    }
}

/// JSON coders configured for persisted models (stable, diff-friendly output).
enum PersistedJSON {
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// Clamps `value` into `range`; non-finite input yields `fallback`.
func sanitized(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}
