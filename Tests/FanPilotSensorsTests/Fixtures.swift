import FanPilotKit
import Foundation
@testable import FanPilotSensors

/// Test doubles that look like a measured M5 Pro MacBook Pro, built from the catalog itself so the
/// fixture cannot drift from the data under test.
enum Fixtures {
    static let m5Pro = HardwareInfo(
        model: "Mac17,8", isAppleSilicon: true,
        perfLevels: [PerfLevel(name: "Super", physicalCPUs: 6), PerfLevel(name: "Performance", physicalCPUs: 12)],
        memoryBytes: 48 << 30)

    static let m2Pro = HardwareInfo(
        model: "Mac99,1", isAppleSilicon: true,
        perfLevels: [PerfLevel(name: "Performance", physicalCPUs: 8), PerfLevel(name: "Efficiency", physicalCPUs: 4)])

    static let intel = HardwareInfo(model: "MacBookPro11,1", isAppleSilicon: false)

    /// Idle-ish value for a catalog row by area (degrees C).
    static func idleValue(for area: SensorArea, index: Int) -> Double {
        switch area {
        case .cpu, .gpu, .soc: return 41 + Double(index % 5) * 0.5
        case .battery: return 32.8
        case .storage: return 37
        case .airflow: return 40.8
        case .power: return 45
        case .thunderbolt: return 41
        case .palmRest: return 31
        case .wireless: return 41.6
        case .memory, .display, .other: return 38
        }
    }

    static func setTemp(_ smc: InMemorySMC, _ key: String, _ value: Float) {
        smc.set(FourCC(key)!, type: .flt, attributes: 0x85, bytes: SMCCodec.encodeFloat(value))
    }

    /// An SMC that has everything the Mac17,8 catalog lists (except `Tg50`, absent on the real unit),
    /// the leftovers of the real machine and a set of decoys that must never become sensors.
    static func m5ProSMC() -> InMemorySMC {
        let smc = InMemorySMC.appleSiliconFixture()

        for (index, row) in (SensorCatalog.rows(forModel: "Mac17,8") ?? []).enumerated()
        where row.source == .smc && row.key != "Tg50" {
            setTemp(smc, row.key, Float(idleValue(for: row.area, index: index)))
        }

        // Real leftovers that belong to "Other".
        for (key, value) in [("Tp00", 43.7), ("Tp08", 44.05), ("Ts00", 42.97), ("Tm00", 42.41), ("Tg05", 42.0),
                             ("TCMb", 53.0), ("TVD0", 53.0), ("TPD0", 41.0), ("TRD0", 40.5), ("TUD0", 41.2),
                             ("Ta00", 43.39), ("TN00", 36.0), ("TAOL", 30.5), ("Tf00", 40.1),
                             ("sd00", 51.875), ("ftVV", 42.65), ("ftD0", 52.4)] {
            setTemp(smc, key, Float(value))
        }

        // Decoys (measured on an M5 Pro MacBook Pro): wrong type, constants, zeros, garbage, non-temperature floats.
        smc.set("TG0B", type: .ioft, attributes: 0x85, bytes: [UInt8](repeating: 0, count: 8))
        smc.set("TV0i", type: .si32, attributes: 0x85, bytes: [0, 0, 0, 40])
        setTemp(smc, "TTPD", 3.0e38)
        setTemp(smc, "TVMD", 4.0)
        setTemp(smc, "TVmS", 40.0)
        setTemp(smc, "Tz11", 0)
        setTemp(smc, "TfCB", 0)
        for (key, value) in [("fRof", 100.0), ("fuFa", 97.0), ("fcB0", 80.0), ("f000", 30.4)] {
            setTemp(smc, key, Float(value))
        }
        // A key outside the T/f/s families with a plausible float.
        setTemp(smc, "PSTR", 50)
        return smc
    }

    /// HID services as the cleaned reader would return them on the M5 Pro.
    static func m5ProHID() -> [HIDSample] {
        var samples: [HIDSample] = (1...14).map { HIDSample(name: "PMU tdie\($0)", value: 40.5 + Double($0) * 0.1) }
        samples.append(HIDSample(name: "NAND CH0 temp", value: 37))
        for index in 0..<6 {
            samples.append(HIDSample(name: "gas gauge battery \(index)", value: index % 2 == 0 ? 32.0 : 32.8))
        }
        return samples
    }

    static func engine(smc: SMCClient = m5ProSMC(), hid: [HIDSample] = m5ProHID(),
                       hardware: HardwareInfo = m5Pro, policy: PollingPolicy = .everyRefresh) -> SensorEngine {
        SensorEngine(smc: smc, hardware: hardware, policy: policy, hidProvider: { _ in hid })
    }
}

/// Wraps an SMC and counts reads per key, to verify what a poll actually touches.
final class CountingSMC: SMCClient, @unchecked Sendable {
    private let base: SMCClient
    private let lock = NSLock()
    private var counts: [FourCC: Int] = [:]

    init(_ base: SMCClient) { self.base = base }

    func reads(of key: FourCC) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key] ?? 0
    }

    var totalReads: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }

    func resetCounts() {
        lock.lock(); counts = [:]; lock.unlock()
    }

    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo { try base.keyInfo(key) }

    func read(_ key: FourCC) throws -> SMCValue {
        lock.lock(); counts[key, default: 0] += 1; lock.unlock()
        return try base.read(key)
    }

    func write(_ key: FourCC, bytes: [UInt8]) throws { try base.write(key, bytes: bytes) }
    var keyCount: Int { get throws { try base.keyCount } }
    func key(at index: Int) throws -> FourCC { try base.key(at: index) }
}
