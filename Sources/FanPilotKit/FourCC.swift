import Foundation

/// A four character code as used by the SMC for key names (`F0Tg`) and data types (`flt `).
///
/// `rawValue` is the big-endian packing the SMC struct uses: the first character sits in the most
/// significant byte, so `'F' << 24 | '0' << 16 | 'T' << 8 | 'g'` for `F0Tg`.
///
/// Characters are limited to Latin-1 (one byte each). Trailing spaces are significant: the types
/// `ui8 ` and `flt ` and the key `FS! ` all contain one.
public struct FourCC: Hashable, Comparable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Creates a code from exactly four Latin-1 characters; returns nil for any other input.
    public init?(_ string: String) {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.value <= 0xFF }) else { return nil }
        self.rawValue = scalars.reduce(UInt32(0)) { ($0 << 8) | $1.value }
    }

    /// Literal support: `let key: FourCC = "F0Tg"`. A literal that is not four Latin-1 characters
    /// is a programming error and traps.
    public init(stringLiteral value: String) {
        guard let code = FourCC(value) else {
            preconditionFailure("FourCC literal must be exactly four Latin-1 characters: \"\(value)\"")
        }
        self = code
    }

    /// The four bytes, first character first (the order they appear on the wire).
    public var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: rawValue >> 24), UInt8(truncatingIfNeeded: rawValue >> 16),
         UInt8(truncatingIfNeeded: rawValue >> 8), UInt8(truncatingIfNeeded: rawValue)]
    }

    /// The code as a string. Bytes that are not printable ASCII are shown as `?` so that logging a
    /// garbage key from the SMC cannot produce control characters.
    public var string: String {
        String(bytes.map { b -> Character in
            (0x20...0x7E).contains(b) ? Character(UnicodeScalar(b)) : "?"
        })
    }

    public var description: String { string }

    public static func < (lhs: FourCC, rhs: FourCC) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: Codable (as the plain string)

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let code = FourCC(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not a four character code: \"\(text)\""))
        }
        self = code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

// MARK: - Well-known SMC data types

extension FourCC {
    /// IEEE-754 float32, little-endian (all `T*` and `F*Ac/Mn/Mx/Tg` keys on Apple Silicon).
    public static let flt: FourCC = "flt "
    public static let ui8: FourCC = "ui8 "
    public static let ui16: FourCC = "ui16"
    public static let ui32: FourCC = "ui32"
    public static let si8: FourCC = "si8 "
    public static let si16: FourCC = "si16"
    public static let si32: FourCC = "si32"
    /// Signed 8.8 fixed point, big-endian (Intel temperatures).
    public static let sp78: FourCC = "sp78"
    /// Unsigned 14.2 fixed point, big-endian (Intel fan RPM).
    public static let fpe2: FourCC = "fpe2"
    public static let flag: FourCC = "flag"
    public static let hex: FourCC = "hex_"
    public static let ioft: FourCC = "ioft"
}

// MARK: - Well-known SMC keys

/// Keys FanPilot reads or writes by name (docs/SPEC.md 2.3).
public enum SMCKeys {
    /// Number of keys in the SMC (`ui32`, big-endian).
    public static let keyCount: FourCC = "#KEY"
    /// Number of fans (`ui8`).
    public static let fanCount: FourCC = "FNum"
    /// Legacy "test mode" unlock on older M-series; absent on M5.
    public static let fanTest: FourCC = "Ftst"
    /// Intel forced-mode bitmask (`ui16`, big-endian).
    public static let fanForceBits: FourCC = "FS! "
    /// "Fans are being ducked" flag; when 1 the OS is overriding and we back off (SPEC 2.9).
    public static let dict: FourCC = "DICT"
    /// Bad fan bitmask.
    public static let badFans: FourCC = "FBAD"

    /// Per-fan key suffixes.
    public enum FanSuffix: String, Sendable {
        case actual = "Ac"
        case minimum = "Mn"
        case maximum = "Mx"
        case target = "Tg"
        /// Lowercase `md` is the mode key on Apple Silicon M-series (0 auto, 1 manual).
        case modeLower = "md"
        /// Uppercase `Md` is the T2 / older firmware spelling.
        case modeUpper = "Md"
        case status = "St"
    }

    /// Builds `F<i><suffix>`. Fan numbers above 9 are unsupported because the SMC key has a single
    /// digit slot; returns nil rather than aliasing another fan.
    public static func fan(_ index: Int, _ suffix: FanSuffix) -> FourCC? {
        guard (0...9).contains(index) else { return nil }
        return FourCC("F\(index)\(suffix.rawValue)")
    }
}
