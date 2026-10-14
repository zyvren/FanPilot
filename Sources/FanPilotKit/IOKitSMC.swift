import CSMC
import Foundation

/// The real AppleSMC connection.
///
/// Safety properties:
/// - Calls are serialized on one private queue; the cache and the connection are only touched there.
/// - Every call checks the IOReturn AND the SMC `result` byte.
/// - A connection opened `.readOnly` (the default) can never send command 6: `write` throws
///   before touching the hardware, and the C layer's read entry point refuses command 6 too.
/// - Even on a `.readWrite` connection, command 6 is only ever sent from `write(_:bytes:)`, after
///   re-reading the key's live info (never the cache) and passing `SMCWriteGuard`.
///
/// Writes need root; an unprivileged `.readWrite` connection simply gets an IOReturn error from
/// the kernel. Only the helper daemon should open `.readWrite`.
public final class IOKitSMC: SMCClient, @unchecked Sendable {
    public enum Access: Sendable {
        case readOnly
        case readWrite
    }

    public let access: Access

    private let queue = DispatchQueue(label: "com.fanpilot.smc")
    private var connection: fp_smc_conn_t
    private var infoCache: [FourCC: SMCKeyInfo] = [:]

    /// Opens the AppleSMC user client.
    public init(access: Access = .readOnly) throws {
        var conn: fp_smc_conn_t = 0
        let kr = fp_smc_open(&conn)
        if kr == kIOReturnNotFound { throw SMCError.serviceNotFound }
        guard kr == KERN_SUCCESS, conn != 0 else { throw SMCError.openFailed(ioReturn: kr) }
        self.connection = conn
        self.access = access
    }

    deinit {
        fp_smc_close(connection)
    }

    /// Closes the connection. Later calls throw `SMCError.closed`.
    public func close() {
        queue.sync {
            fp_smc_close(connection)
            connection = 0
            infoCache.removeAll()
        }
    }

    // MARK: SMCClient

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        try queue.sync { try keyInfoLocked(key, useCache: true) }
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        try queue.sync { try readLocked(key) }
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        try queue.sync {
            guard access == .readWrite else { throw SMCError.writeNotPermitted(key) }
            // Fresh key info on every write: the size guard must reflect the hardware right now.
            let info = try keyInfoLocked(key, useCache: false)
            try SMCWriteGuard.validate(key: key, liveInfo: info, bytes: bytes)

            var input = SMCKeyData_t()
            input.key = key.rawValue
            input.data8 = UInt8(FP_SMC_CMD_WRITE)
            input.keyInfo.dataSize = UInt32(info.size)
            // dataType is deliberately left zero in write requests.
            fp_smc_set_bytes(&input, bytes, bytes.count)
            _ = try call(&input, key: key, write: true)
        }
    }

    public var keyCount: Int {
        get throws {
            try queue.sync {
                let value = try readLocked(SMCKeys.keyCount)
                // `#KEY` is the one integer whose byte order is verified: big-endian.
                guard let count = SMCCodec.decodeUInt32(value.bytes) else {
                    throw SMCError.invalidValue(key: SMCKeys.keyCount, reason: "expected 4 bytes")
                }
                return Int(count)
            }
        }
    }

    public func key(at index: Int) throws -> FourCC {
        try queue.sync {
            guard index >= 0, index <= Int(UInt32.max) else { throw SMCError.indexOutOfRange(index) }
            var input = SMCKeyData_t()
            input.data8 = UInt8(FP_SMC_CMD_READ_INDEX)
            input.data32 = UInt32(index)
            let output = try call(&input, key: SMCKeys.keyCount, write: false)
            return FourCC(rawValue: output.key)
        }
    }

    // MARK: Internals (all run on `queue`)

    private func keyInfoLocked(_ key: FourCC, useCache: Bool) throws -> SMCKeyInfo {
        if useCache, let cached = infoCache[key] { return cached }

        var input = SMCKeyData_t()
        input.key = key.rawValue
        input.data8 = UInt8(FP_SMC_CMD_KEY_INFO)
        let output = try call(&input, key: key, write: false)

        let size = Int(output.keyInfo.dataSize)
        // A missing key can come back as "success, size 0"; treat that as not found as well.
        guard size > 0 else { throw SMCError.keyNotFound(key) }
        guard size <= Int(FP_SMC_PAYLOAD_MAX) else {
            throw SMCError.payloadTooLarge(key: key, count: size)
        }
        let info = SMCKeyInfo(size: size,
                              type: FourCC(rawValue: output.keyInfo.dataType),
                              attributes: output.keyInfo.dataAttributes)
        infoCache[key] = info
        return info
    }

    private func readLocked(_ key: FourCC) throws -> SMCValue {
        let info = try keyInfoLocked(key, useCache: true)
        var input = SMCKeyData_t()
        input.key = key.rawValue
        input.data8 = UInt8(FP_SMC_CMD_READ)
        input.keyInfo.dataSize = UInt32(info.size)
        let output = try call(&input, key: key, write: false)

        var bytes = [UInt8](repeating: 0, count: info.size)
        var out = output
        fp_smc_get_bytes(&out, &bytes, info.size)
        return SMCValue(key: key, info: info, bytes: bytes)
    }

    /// Sends one command and validates both the IOReturn and the SMC result byte.
    private func call(_ input: inout SMCKeyData_t, key: FourCC, write: Bool) throws -> SMCKeyData_t {
        guard connection != 0 else { throw SMCError.closed }
        var output = SMCKeyData_t()
        let command = input.data8
        let kr = write
            ? fp_smc_call_write(connection, &input, &output)
            : fp_smc_call_read(connection, &input, &output)
        guard kr == KERN_SUCCESS else {
            throw SMCError.callFailed(key: key, command: command, ioReturn: kr)
        }
        switch output.result {
        case UInt8(FP_SMC_RESULT_OK):
            return output
        case UInt8(FP_SMC_RESULT_NOT_FOUND):
            throw SMCError.keyNotFound(key)
        default:
            throw SMCError.smcResult(key: key, command: command, result: output.result)
        }
    }
}
