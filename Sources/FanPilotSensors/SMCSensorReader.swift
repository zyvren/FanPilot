import FanPilotKit
import Foundation

/// Which SMC keys can be temperature sensors at all, and which of them FanPilot never shows
/// (docs/SPEC.md 2.4 #4, 2.5).
public enum SensorRules {
    /// Keys that carry a plausible-looking number but are not temperatures (measured on an M5 Pro MacBook Pro):
    /// `TTPD` is garbage, `TVMD` reads 4.0, `TVmS` is a constant 40.0, `TfCB` is zero.
    public static let excludedKeys: Set<String> = ["TTPD", "TVMD", "TVmS", "TfCB"]

    /// True for keys that must never become a sensor.
    public static func isExcluded(_ key: String) -> Bool {
        // `Tz11` .. `Tz1j` read zero on the M5 Pro.
        excludedKeys.contains(key) || key.hasPrefix("Tz")
    }

    /// First characters of keys worth looking at: `T` and `f`. The M5 generation also has `sd??` core
    /// keys, so `s` is included.
    static let candidatePrefixes: Set<Character> = ["T", "f", "s"]

    /// True for keys that may appear in the "Other" group when they are not in a model's list.
    ///
    /// All `T*` keys qualify. Of the `f*` and `s*` families only `ft??` and `sd??` do: the others
    /// hold constants and limits (`fRof` = 100.0, `fuFa` = 97.0, `fcB0` = 80.0 on the M5 Pro) that
    /// look like temperatures but would only add noise, or worse, trigger the failsafe.
    public static func isEligibleForOther(_ key: String) -> Bool {
        guard !isExcluded(key), key.utf8.count == 4 else { return false }
        if key.hasPrefix("T") { return true }
        return key.hasPrefix("ft") || key.hasPrefix("sd")
    }
}

/// An SMC key that is a numeric temperature type (`flt ` or `sp78`) and so can be read as a sensor.
public struct SMCCandidate: Hashable, Sendable {
    public let key: FourCC
    public let type: FourCC

    public init(key: FourCC, type: FourCC) {
        self.key = key
        self.type = type
    }

    public var name: String { key.string }
}

/// Enumerates temperature-capable SMC keys once and reads values in one pass.
///
/// Enumeration costs one SMC call per key in the machine (3626 on the M5 Pro, about one second), so
/// the result is cached; `needsReenumeration()` tells whether `#KEY` changed. A cheap re-read of the
/// cached candidates (`readCandidates()`) is what periodic re-validation uses.
///
/// Thread-safe: state is guarded by a lock, and the underlying `SMCClient` serializes its own calls.
public final class SMCSensorReader: @unchecked Sendable {
    private let smc: SMCClient
    private let lock = NSLock()
    private var cachedCandidates: [SMCCandidate] = []
    private var enumeratedKeyCount: Int?

    public init(smc: SMCClient) {
        self.smc = smc
    }

    /// Candidates from the last `enumerate()`; empty before the first call.
    public var candidates: [SMCCandidate] {
        lock.lock(); defer { lock.unlock() }
        return cachedCandidates
    }

    /// Walks every SMC key (`#KEY` plus command 8) and keeps `T*`, `f*` and `s*` keys whose type is
    /// `flt ` (size 4) or `sp78` (size 2). Individual failures skip that key only.
    @discardableResult
    public func enumerate() throws -> [SMCCandidate] {
        let count = try smc.keyCount
        var found: [SMCCandidate] = []
        for index in 0..<count {
            guard let key = try? smc.key(at: index), Self.hasCandidatePrefix(key) else { continue }
            guard let info = try? smc.keyInfo(key) else { continue }
            switch (info.type, info.size) {
            case (.flt, 4), (.sp78, 2):
                found.append(SMCCandidate(key: key, type: info.type))
            default:
                continue
            }
        }
        lock.lock()
        cachedCandidates = found
        enumeratedKeyCount = count
        lock.unlock()
        return found
    }

    /// True if no enumeration happened yet or the SMC now reports a different number of keys.
    public func needsReenumeration() -> Bool {
        lock.lock()
        let known = enumeratedKeyCount
        lock.unlock()
        guard let known else { return true }
        guard let now = try? smc.keyCount else { return false }
        return now != known
    }

    /// Reads one key as degrees Celsius exactly as the SMC reports it: no range check, so values
    /// of 125 and above stay visible to the failsafe. Nil if the key is unreadable or not numeric.
    public func readValue(_ key: FourCC) -> Double? {
        guard let value = try? smc.read(key), value.info.type == .flt || value.info.type == .sp78,
              let number = value.numericValue, number.isFinite else { return nil }
        return number
    }

    /// Reads many keys in one pass. Unreadable keys are absent from the result.
    public func readValues(_ keys: [FourCC]) -> [FourCC: Double] {
        var result: [FourCC: Double] = [:]
        result.reserveCapacity(keys.count)
        for key in keys {
            if let value = readValue(key) { result[key] = value }
        }
        return result
    }

    /// Reads every cached candidate: `key string -> value`.
    public func readCandidates() -> [String: Double] {
        var result: [String: Double] = [:]
        for candidate in candidates {
            if let value = readValue(candidate.key) { result[candidate.name] = value }
        }
        return result
    }

    private static func hasCandidatePrefix(_ key: FourCC) -> Bool {
        let first = Character(UnicodeScalar(UInt8(truncatingIfNeeded: key.rawValue >> 24)))
        return SensorRules.candidatePrefixes.contains(first)
    }
}
