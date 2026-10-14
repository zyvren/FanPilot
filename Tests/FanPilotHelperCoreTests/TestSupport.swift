import FanPilotKit
import Foundation
import XCTest
@testable import FanPilotHelperCore

// MARK: - MockSMC

/// A scriptable SMC for the writer and engine tests. Like the real one it enforces the shared write
/// guard (writable bit, exact size), and it records every write in order so tests can assert the
/// safety-critical sequences. Behaviors emulate what the firmware might do to us.
final class MockSMC: SMCClient, @unchecked Sendable {
    struct Write: Equatable {
        let key: FourCC
        let bytes: [UInt8]
    }

    enum Disposition {
        /// Store the value (default).
        case apply
        /// Report success but keep the old value (the firmware ignored us).
        case ignore
        /// Fail the call with an SMC result byte.
        case fail(UInt8)
    }

    private let lock = NSLock()
    private var values: [FourCC: SMCValue] = [:]
    private var order: [FourCC] = []
    private(set) var writes: [Write] = []
    private(set) var readCount = 0

    /// Decides what happens to each write. `index` counts accepted calls to that key, from 0.
    var behavior: ((_ key: FourCC, _ bytes: [UInt8], _ index: Int) -> Disposition)?
    /// Runs after a stored write, outside the lock; may change other keys (an OS that reverts).
    var afterWrite: ((MockSMC, FourCC, [UInt8]) -> Void)?
    private var writeIndex: [FourCC: Int] = [:]

    // MARK: Fixture

    func set(_ key: FourCC, type: FourCC, attributes: UInt8, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        if values[key] == nil { order.append(key) }
        values[key] = SMCValue(key: key, info: SMCKeyInfo(size: bytes.count, type: type, attributes: attributes), bytes: bytes)
    }

    func setFloat(_ key: FourCC, _ v: Float, attributes: UInt8 = 0x84) {
        set(key, type: .flt, attributes: attributes, bytes: SMCCodec.encodeFloat(v))
    }

    func setUInt8(_ key: FourCC, _ v: UInt8, attributes: UInt8 = 0x80, type: FourCC = .ui8) {
        set(key, type: type, attributes: attributes, bytes: [v])
    }

    func remove(_ key: FourCC) {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
        order.removeAll { $0 == key }
    }

    /// The M5 Pro layout (measured on an M5 Pro MacBook Pro): two fans, `flt` targets, lowercase `md`, no Ftst, DICT present.
    static func appleSilicon(fans: Int = 2) -> MockSMC {
        let smc = MockSMC()
        smc.setUInt8("FNum", UInt8(fans))
        let limits: [(Float, Float)] = [(1350, 5349), (1350, 5777)]
        for i in 0..<fans {
            smc.setFloat(key(i, "Ac"), 0)
            smc.setFloat(key(i, "Mn"), limits[i].0, attributes: 0x84)
            smc.setFloat(key(i, "Mx"), limits[i].1, attributes: 0x85)
            smc.setFloat(key(i, "Tg"), 0, attributes: 0xD4)
            smc.setUInt8(key(i, "md"), 0, attributes: 0xD0)
            smc.setUInt8(key(i, "St"), 3)
        }
        smc.set("DICT", type: "flag", attributes: 0xC0, bytes: [0])
        smc.set("FBAD", type: .hex, attributes: 0xD0, bytes: [0])
        return smc
    }

    /// Intel without T2: fpe2 targets and the `FS! ` bitmask.
    static func intel(fans: Int = 2) -> MockSMC {
        let smc = MockSMC()
        smc.setUInt8("FNum", UInt8(fans))
        for i in 0..<fans {
            smc.set(key(i, "Ac"), type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(0)!)
            smc.set(key(i, "Mn"), type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(1200)!)
            smc.set(key(i, "Mx"), type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(6000)!)
            smc.set(key(i, "Tg"), type: .fpe2, attributes: 0xD0, bytes: SMCCodec.encodeFPE2(0)!)
        }
        smc.set("FS! ", type: .ui16, attributes: 0xD0, bytes: [0, 0])
        return smc
    }

    static func key(_ fan: Int, _ suffix: String) -> FourCC { FourCC("F\(fan)\(suffix)")! }

    // MARK: Inspection

    func bytes(_ key: FourCC) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return values[key]?.bytes
    }

    func float(_ key: FourCC) -> Float? { bytes(key).flatMap(SMCCodec.decodeFloat) }
    func byte(_ key: FourCC) -> UInt8? { bytes(key)?.first }

    func writes(to key: FourCC) -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return writes.filter { $0.key == key }.map(\.bytes)
    }

    /// Keys written, in order.
    var writtenKeys: [FourCC] {
        lock.lock(); defer { lock.unlock() }
        return writes.map(\.key)
    }

    func clearWrites() {
        lock.lock(); defer { lock.unlock() }
        writes.removeAll()
    }

    // MARK: SMCClient

    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        guard let v = values[key] else { throw SMCError.keyNotFound(key) }
        return v.info
    }

    func read(_ key: FourCC) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        guard let v = values[key] else { throw SMCError.keyNotFound(key) }
        return v
    }

    func write(_ key: FourCC, bytes: [UInt8]) throws {
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
        let index = writeIndex[key, default: 0]
        writeIndex[key] = index + 1
        writes.append(Write(key: key, bytes: bytes))   // attempts are recorded, whatever happens next
        switch behavior?(key, bytes, index) ?? .apply {
        case .apply:
            values[key]?.bytes = bytes
        case .ignore:
            lock.unlock()
            return
        case .fail(let result):
            lock.unlock()
            throw SMCError.smcResult(key: key, command: 6, result: result)
        }
        let hook = afterWrite
        lock.unlock()
        hook?(self, key, bytes)
    }

    var keyCount: Int {
        get throws {
            lock.lock(); defer { lock.unlock() }
            return order.count
        }
    }

    func key(at index: Int) throws -> FourCC {
        lock.lock(); defer { lock.unlock() }
        guard order.indices.contains(index) else { throw SMCError.indexOutOfRange(index) }
        return order[index]
    }
}

// MARK: - Other doubles

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1000
    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }
}

/// A hot set whose temperature the test controls.
final class StubHotSet: HotSetProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var temp: Double?
    private(set) var refreshCount = 0
    private(set) var readCount = 0

    init(_ temp: Double? = 45) { self.temp = temp }

    func set(_ temp: Double?) {
        lock.lock(); self.temp = temp; lock.unlock()
    }

    func read() -> HotSetReading {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return HotSetReading(maxTempC: temp, hottest: temp == nil ? nil : "stub", sensorCount: temp == nil ? 0 : 1)
    }

    func refresh() {
        lock.lock(); refreshCount += 1; lock.unlock()
    }
}

/// Captures log lines so tests can assert that critical events were logged.
final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [(HelperLog.Level, String)] = []

    init() {
        HelperLog.setSink { [weak self] level, text in
            guard let self else { return }
            self.lock.lock(); self.lines.append((level, text)); self.lock.unlock()
        }
    }

    deinit { HelperLog.setSink(nil) }

    func contains(_ level: HelperLog.Level, _ fragment: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lines.contains { $0.0 == level && $0.1.contains(fragment) }
    }
}

// MARK: - Harness

final class SleepRecorder: @unchecked Sendable {
    private(set) var values: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { values.append(seconds) }
    func reset() { values.removeAll() }
}

/// An engine on a mock SMC with a fake clock and no real sleeping.
final class EngineHarness {
    let smc: MockSMC
    let hot: StubHotSet
    let clock = FakeClock()
    let engine: HelperEngine
    let sleeper = SleepRecorder()
    private var nextRequestID = 1

    init(smc: MockSMC = .appleSilicon(),
         hot: StubHotSet = StubHotSet(45),
         config: HelperConfig = HelperConfig(allowedUIDs: [501], failsafeTempC: 95, leaseMaxSeconds: 30),
         model: String? = nil,
         start: Bool = true) {
        self.smc = smc
        self.hot = hot
        let clock = self.clock
        let sleeper = self.sleeper
        engine = HelperEngine(smc: smc, hotSet: hot, config: config, model: model,
                              clock: { clock.now },
                              sleep: { sleeper.record($0) })
        if start { engine.start() }
    }

    /// Opens a connection and says hello.
    @discardableResult
    func connect(_ id: Int = 1) -> Int {
        engine.connectionOpened(id)
        let reply = send(.hello(proto: 1, client: "test"), from: id).reply
        XCTAssertTrue(reply.ok, "hello failed: \(reply.msg ?? "")")
        return id
    }

    @discardableResult
    func send(_ command: WireCommand, from connection: Int = 1) -> HelperEngine.Outcome {
        defer { nextRequestID += 1 }
        return engine.handle(WireRequest(id: nextRequestID, command: command), from: connection)
    }

    func tick(_ seconds: TimeInterval = 1) {
        clock.advance(seconds)
        engine.tick()
    }

    /// Ticks once per second for `seconds`.
    func run(_ seconds: Int) {
        for _ in 0..<seconds { tick(1) }
    }
}

extension EngineHarness {
    /// Holds the hot set at `tempC` for as many 1 s ticks as the failsafe needs to confirm a real
    /// overheat (`FailsafeMonitor.triggerSamples` consecutive samples), then returns.
    func overheat(_ tempC: Double) {
        hot.set(tempC)
        run(FailsafeMonitor.triggerSamples)
    }
}

extension WireReply {
    var setReply: SetReply? {
        if case .set(let s) = body { return s }
        return nil
    }
    var statusReply: StatusReply? {
        if case .status(let s) = body { return s }
        return nil
    }
    var heartbeatOwned: [Int]? {
        if case .heartbeat(let o) = body { return o }
        return nil
    }
    var autoReleased: [Int]? {
        if case .auto(let r) = body { return r }
        return nil
    }
}

func f(_ value: Double) -> [UInt8] { SMCCodec.encodeFloat(Float(value)) }
