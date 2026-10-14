import FanPilotKit
import Foundation

/// Parsing and formatting helpers for `fanpilotctl`, kept here so they are unit-tested.
public enum CLISupport {
    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    // MARK: Arguments

    /// A fan speed as typed: `3000` RPM or `50%` of the fan's range.
    public enum SpeedSpec: Equatable, Sendable {
        case rpm(Double)
        case percent(Double)

        public static func parse(_ text: String) throws -> SpeedSpec {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("%") {
                guard let value = Double(trimmed.dropLast()), value.isFinite, (0...100).contains(value) else {
                    throw UsageError("'\(text)' is not a percentage between 0 and 100")
                }
                return .percent(value)
            }
            let digits = trimmed.lowercased().hasSuffix("rpm") ? String(trimmed.dropLast(3)) : trimmed
            guard let value = Double(digits), value.isFinite, value >= 0, value <= Constants.rpmSanityCeiling else {
                throw UsageError("'\(text)' is not a valid RPM value (expected e.g. 3000 or 50%)")
            }
            return .rpm(value)
        }

        /// The RPM for a fan with these limits: percent 0 is the minimum (manual never stops a fan,
        /// only auto can), 100 the maximum. The helper clamps again.
        public func rpm(min lower: Double, max upper: Double) -> Double {
            switch self {
            case .rpm(let value): return value
            case .percent(let p): return (lower + p / 100 * (upper - lower)).rounded()
            }
        }
    }

    /// `all` or a fan number.
    public static func parseFanSelector(_ text: String) throws -> FanSelector {
        if text.lowercased() == "all" { return .all }
        guard let index = Int(text), (0...Constants.maxFanIndex).contains(index) else {
            throw UsageError("'\(text)' is not a fan number (0-\(Constants.maxFanIndex)) or 'all'")
        }
        return .fan(index)
    }

    /// Removes `--name VALUE` from `arguments` and returns the value.
    public static func takeOption(_ name: String, from arguments: inout [String]) throws -> String? {
        guard let position = arguments.firstIndex(of: name) else { return nil }
        guard position + 1 < arguments.count else { throw UsageError("\(name) needs a value") }
        let value = arguments[position + 1]
        arguments.removeSubrange(position...(position + 1))
        return value
    }

    /// Removes a boolean flag from `arguments`; true if it was present.
    public static func takeFlag(_ name: String, from arguments: inout [String]) -> Bool {
        let before = arguments.count
        arguments.removeAll { $0 == name }
        return arguments.count != before
    }

    /// Parses a `--hold SECONDS` value (1...86400).
    public static func parseHold(_ text: String) throws -> TimeInterval {
        guard let seconds = Double(text), seconds.isFinite, seconds >= 1, seconds <= 86_400 else {
            throw UsageError("--hold needs a number of seconds between 1 and 86400")
        }
        return seconds
    }

    // MARK: SMC keys

    /// Parses `1A2B3C`, `1a 2b`, `0x1A2B` into bytes (at most 32).
    public static func parseHex(_ text: String) throws -> [UInt8] {
        var digits = text.replacingOccurrences(of: " ", with: "")
        if digits.lowercased().hasPrefix("0x") { digits.removeFirst(2) }
        guard !digits.isEmpty, digits.count % 2 == 0, digits.count <= 64 else {
            throw UsageError("'\(text)' is not an even number of hex digits (1 to 32 bytes)")
        }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                throw UsageError("'\(text)' contains a character that is not a hex digit")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The only keys `smc-write` accepts (Phase 0 debugging): a fan's target and mode, the legacy
    /// unlock and the Intel force bits. Never limits, never actual speed, never anything outside F*.
    public static func isWritableDebugKey(_ key: FourCC) -> Bool {
        let name = key.string
        if name == "Ftst" || name == "FS! " { return true }
        let chars = Array(name)
        guard chars.count == 4, chars[0] == "F", chars[1].isNumber else { return false }
        return ["Tg", "md", "Md"].contains(String(chars[2...3]))
    }

    // MARK: Formatting

    /// Left-aligns `cells` into columns of the given widths (last column unpadded).
    public static func row(_ cells: [String], widths: [Int]) -> String {
        var line = ""
        for (i, cell) in cells.enumerated() {
            if i == cells.count - 1 || i >= widths.count {
                line += cell
            } else {
                line += cell.padding(toLength: max(widths[i], cell.count), withPad: " ", startingAt: 0) + " "
            }
        }
        return line
    }

    public static func rpmText(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    public static func tempText(_ value: Double?) -> String {
        value.map { String(format: "%.1f C", $0) } ?? "N/A"
    }

    /// Mode byte as a word.
    public static func modeText(_ mode: Int) -> String {
        switch mode {
        case 0: return "auto"
        case 1: return "manual"
        default: return "mode \(mode)"
        }
    }

    /// Human description of a SMC value for `smc-read`.
    public static func describe(_ value: SMCValue) -> String {
        var line = "\(value.key)  type \(value.info.type) (\(value.info.type.bytes.map { String(format: "%02x", $0) }.joined()))  size \(value.info.size)  attr 0x\(String(format: "%02x", value.info.attributes))"
        line += value.info.isReadable ? " R" : " -"
        line += value.info.isWritable ? "W" : "-"
        line += "  raw \(hex(value.bytes))"
        if let number = value.numericValue {
            line += "  = \(number)"
        } else if value.info.type == "flag", value.bytes.count == 1 {
            line += "  = \(value.bytes[0] != 0)"
        }
        return line
    }
}
