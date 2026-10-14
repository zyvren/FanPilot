import Foundation

/// A fake SMC for tests: a dictionary of keys that enforces the same write rules as the real
/// client (`SMCWriteGuard`) and records every write. Used by FanPilotKit, HelperCore and Control
/// tests so the fan writer can be exercised without hardware.
///
/// Firmware behavior can be simulated with `onWrite`, which runs after a successful write and may
/// change other keys (for example reverting `F0md` to emulate `thermalmonitord`).
public final class InMemorySMC: SMCClient, @unchecked Sendable {
    public struct WriteRecord: Equatable, Sendable {
        public let key: FourCC
        public let bytes: [UInt8]
    }

    private let lock = NSLock()
    private var values: [FourCC: SMCValue]
    private var order: [FourCC]
    private var writeLog: [WriteRecord] = []
    private var failingWrites: Set<FourCC> = []

    /// Called (outside the lock) after each accepted write.
    public var onWrite: ((InMemorySMC, FourCC, [UInt8]) -> Void)?

    public init(values: [SMCValue] = []) {
        self.values = Dictionary(values.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        self.order = values.map(\.key)
    }

    // MARK: Fixture building

    /// Adds or replaces a key.
    public func set(_ key: FourCC, type: FourCC, attributes: UInt8, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let value = SMCValue(key: key, info: SMCKeyInfo(size: bytes.count, type: type, attributes: attributes), bytes: bytes)
        if values[key] == nil { order.append(key) }
        values[key] = value
    }

    public func setFloat(_ key: FourCC, _ value: Float, attributes: UInt8 = 0x84) {
        set(key, type: .flt, attributes: attributes, bytes: SMCCodec.encodeFloat(value))
    }

    public func setUInt8(_ key: FourCC, _ value: UInt8, attributes: UInt8 = 0x80) {
        set(key, type: .ui8, attributes: attributes, bytes: [value])
    }

    public func remove(_ key: FourCC) {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
        order.removeAll { $0 == key }
    }

    /// Makes writes to `key` fail with an SMC result error, to test error paths.
    public func failWrites(to key: FourCC, _ fail: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        if fail { failingWrites.insert(key) } else { failingWrites.remove(key) }
    }

    /// Two fans laid out exactly like the ones measured on an M5 Pro MacBook Pro: `flt` targets, lowercase
    /// `md` mode keys, no `Ftst`, no `FS! `.
    public static func appleSiliconFixture() -> InMemorySMC {
        let smc = InMemorySMC()
        smc.setUInt8(SMCKeys.fanCount, 2)
        let limits: [(min: Float, max: Float)] = [(1350, 5349), (1350, 5777)]
        for (i, limit) in limits.enumerated() {
            smc.setFloat(SMCKeys.fan(i, .actual)!, 0, attributes: 0x84)
            smc.setFloat(SMCKeys.fan(i, .minimum)!, limit.min, attributes: 0x84)
            smc.setFloat(SMCKeys.fan(i, .maximum)!, limit.max, attributes: 0x85)
            smc.setFloat(SMCKeys.fan(i, .target)!, 0, attributes: 0xD4)
            smc.setUInt8(SMCKeys.fan(i, .modeLower)!, 0, attributes: 0xD0)
            smc.setUInt8(SMCKeys.fan(i, .status)!, 3, attributes: 0x80)
        }
        return smc
    }

    // MARK: Inspection

    public var writes: [WriteRecord] {
        lock.lock(); defer { lock.unlock() }
        return writeLog
    }

    public func clearWriteLog() {
        lock.lock(); defer { lock.unlock() }
        writeLog.removeAll()
    }

    public func bytes(of key: FourCC) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return values[key]?.bytes
    }

    // MARK: SMCClient

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[key] else { throw SMCError.keyNotFound(key) }
        return value.info
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[key] else { throw SMCError.keyNotFound(key) }
        return value
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        lock.lock()
        guard let current = values[key] else {
            lock.unlock()
            throw SMCError.keyNotFound(key)
        }
        do {
            try SMCWriteGuard.validate(key: key, liveInfo: current.info, bytes: bytes)
        } catch {
            lock.unlock()
            throw error
        }
        if failingWrites.contains(key) {
            lock.unlock()
            throw SMCError.smcResult(key: key, command: 6, result: 0x86)
        }
        values[key]?.bytes = bytes
        writeLog.append(WriteRecord(key: key, bytes: bytes))
        let hook = onWrite
        lock.unlock()
        hook?(self, key, bytes)
    }

    public var keyCount: Int {
        get throws {
            lock.lock(); defer { lock.unlock() }
            return order.count
        }
    }

    public func key(at index: Int) throws -> FourCC {
        lock.lock(); defer { lock.unlock() }
        guard order.indices.contains(index) else { throw SMCError.indexOutOfRange(index) }
        return order[index]
    }
}
