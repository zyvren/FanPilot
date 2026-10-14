import Foundation

/// Static description of an SMC key as returned by the key-info command.
public struct SMCKeyInfo: Hashable, Sendable, Codable {
    /// Payload size in bytes (at most 32).
    public var size: Int
    public var type: FourCC
    /// Raw `dataAttributes` byte.
    public var attributes: UInt8

    public init(size: Int, type: FourCC, attributes: UInt8) {
        self.size = size
        self.type = type
        self.attributes = attributes
    }

    /// 0x80 marks a readable key (observed on an M5 Pro MacBook Pro). Some keys that carry
    /// the bit still fail to read at runtime, so a read can fail even when this is true.
    public static let readableMask: UInt8 = 0x80
    /// 0x40 marks a writable key (`F0Tg` 0xd4, `F0md` 0xd0; read-only keys such as `F0Mn` 0x84 lack it).
    public static let writableMask: UInt8 = 0x40

    public var isReadable: Bool { attributes & Self.readableMask != 0 }
    public var isWritable: Bool { attributes & Self.writableMask != 0 }
}

/// A key read from the SMC: its info plus exactly `info.size` payload bytes.
public struct SMCValue: Hashable, Sendable {
    public var key: FourCC
    public var info: SMCKeyInfo
    public var bytes: [UInt8]

    public init(key: FourCC, info: SMCKeyInfo, bytes: [UInt8]) {
        self.key = key
        self.info = info
        self.bytes = bytes
    }

    /// Numeric view by SMC type; nil for types without a trustworthy numeric meaning.
    public var numericValue: Double? {
        SMCCodec.decodeNumeric(type: info.type, bytes: bytes)
    }

    /// The payload as float32 if (and only if) the key is a `flt ` key.
    public var floatValue: Float? {
        info.type == .flt ? SMCCodec.decodeFloat(bytes) : nil
    }
}

/// Everything that can go wrong talking to the SMC.
public enum SMCError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No `AppleSMC` IOService (virtual machine, unsupported hardware).
    case serviceNotFound
    /// `IOServiceOpen` failed (IOReturn).
    case openFailed(ioReturn: Int32)
    /// The connection was closed.
    case closed
    /// `IOConnectCallStructMethod` itself failed.
    case callFailed(key: FourCC, command: UInt8, ioReturn: Int32)
    /// The call succeeded but the SMC reported an error in the `result` byte.
    case smcResult(key: FourCC, command: UInt8, result: UInt8)
    case keyNotFound(FourCC)
    case notReadable(FourCC)
    case notWritable(FourCC)
    /// A write was refused because the payload size differs from the key's live size.
    case sizeMismatch(key: FourCC, expected: Int, actual: Int)
    /// More than 32 bytes.
    case payloadTooLarge(key: FourCC, count: Int)
    /// A write was attempted on a connection opened read-only.
    case writeNotPermitted(FourCC)
    /// A value could not be encoded or decoded for its type.
    case invalidValue(key: FourCC, reason: String)
    case indexOutOfRange(Int)
    /// A write was accepted but the key reads back differently (the firmware or OS changed it).
    case readbackMismatch(key: FourCC, expected: [UInt8], actual: [UInt8])

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found"
        case .openFailed(let r):
            return "IOServiceOpen(AppleSMC) failed: \(Self.hex(r))"
        case .closed:
            return "SMC connection is closed"
        case .callFailed(let key, let cmd, let r):
            return "SMC call failed for \(key) (cmd \(cmd)): IOReturn \(Self.hex(r))"
        case .smcResult(let key, let cmd, let res):
            return "SMC reported error 0x\(String(res, radix: 16)) for \(key) (cmd \(cmd))"
        case .keyNotFound(let k):
            return "SMC key \(k) not found"
        case .notReadable(let k):
            return "SMC key \(k) is not readable"
        case .notWritable(let k):
            return "SMC key \(k) is not writable"
        case .sizeMismatch(let k, let expected, let actual):
            return "refusing write to \(k): payload is \(actual) bytes but the key is \(expected) bytes"
        case .payloadTooLarge(let k, let n):
            return "payload for \(k) is \(n) bytes (max 32)"
        case .writeNotPermitted(let k):
            return "refusing write to \(k): this SMC connection was opened read-only (use IOKitSMC(access: .readWrite))"
        case .invalidValue(let k, let why):
            return "invalid value for \(k): \(why)"
        case .indexOutOfRange(let i):
            return "SMC key index \(i) out of range"
        case .readbackMismatch(let k, let expected, let actual):
            return "\(k) reads back \(Self.hexBytes(actual)) after writing \(Self.hexBytes(expected))"
        }
    }

    private static func hexBytes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ value: Int32) -> String {
        "0x" + String(UInt32(bitPattern: value), radix: 16)
    }
}

/// Access to the SMC. Implemented by `IOKitSMC` (real hardware) and `InMemorySMC` (tests).
///
/// Implementations must be safe to call from any thread. A conforming `write` MUST refuse a
/// payload whose size differs from the key's live size and a key that is not writable; use
/// `SMCWriteGuard` to get identical behavior everywhere.
public protocol SMCClient: AnyObject {
    /// Size, type and attributes of `key`. Throws `SMCError.keyNotFound` if the key does not exist.
    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo
    func read(_ key: FourCC) throws -> SMCValue
    /// Writes `bytes` to `key`. Throws instead of silently doing nothing: a helper that ignores the SMC
    /// result byte would do nothing on a mismatch, and the caller needs to know.
    func write(_ key: FourCC, bytes: [UInt8]) throws
    /// Number of keys in the SMC (`#KEY`).
    var keyCount: Int { get throws }
    /// The key at position `index` in `0..<keyCount`.
    func key(at index: Int) throws -> FourCC
}

/// The shared pre-flight checks every write must pass (docs/SPEC.md 2.1).
public enum SMCWriteGuard {
    public static let maxPayload = 32

    /// Throws if writing `bytes` to a key described by `liveInfo` must be refused.
    public static func validate(key: FourCC, liveInfo: SMCKeyInfo, bytes: [UInt8]) throws {
        guard bytes.count <= maxPayload else {
            throw SMCError.payloadTooLarge(key: key, count: bytes.count)
        }
        guard liveInfo.isWritable else {
            throw SMCError.notWritable(key)
        }
        guard liveInfo.size == bytes.count else {
            throw SMCError.sizeMismatch(key: key, expected: liveInfo.size, actual: bytes.count)
        }
    }
}

// MARK: - Conveniences

extension SMCClient {
    /// True if the key exists. Other SMC failures propagate.
    public func exists(_ key: FourCC) throws -> Bool {
        do {
            _ = try keyInfo(key)
            return true
        } catch SMCError.keyNotFound {
            return false
        }
    }

    /// Reads a key as a number according to its SMC type, or nil if the key is missing or has no
    /// numeric meaning. Read errors other than "missing" propagate.
    public func readNumber(_ key: FourCC) throws -> Double? {
        do {
            return try read(key).numericValue
        } catch SMCError.keyNotFound {
            return nil
        }
    }

    /// Reads a `ui8 ` key.
    public func readUInt8(_ key: FourCC) throws -> UInt8 {
        let value = try read(key)
        guard value.info.type == .ui8, let v = SMCCodec.decodeUInt8(value.bytes) else {
            throw SMCError.invalidValue(key: key, reason: "expected ui8, found \(value.info.type) size \(value.info.size)")
        }
        return v
    }

    /// Reads a `flt ` key.
    public func readFloat(_ key: FourCC) throws -> Float {
        let value = try read(key)
        guard let v = value.floatValue else {
            throw SMCError.invalidValue(key: key, reason: "expected flt, found \(value.info.type) size \(value.info.size)")
        }
        return v
    }

    /// Writes `bytes` and reads the key back immediately, so a write that the SMC ignored or that
    /// was reverted does not go unnoticed (docs/SPEC.md 2.1).
    /// Throws `SMCError.readbackMismatch` if the stored bytes differ, e.g. because the OS reverted
    /// the value. Whether a given key should be compared byte for byte is the caller's decision
    /// (a float target may legitimately read back rounded): use `write` plus a tolerant check then.
    public func writeVerified(_ key: FourCC, bytes: [UInt8]) throws {
        try write(key, bytes: bytes)
        let actual = try read(key).bytes
        guard actual == bytes else {
            throw SMCError.readbackMismatch(key: key, expected: bytes, actual: actual)
        }
    }

    /// Enumerates every key name (`#KEY` calls to command 8; about 0.9 s for 3626 keys).
    public func allKeys() throws -> [FourCC] {
        let count = try keyCount
        var keys: [FourCC] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            keys.append(try key(at: index))
        }
        return keys
    }
}
