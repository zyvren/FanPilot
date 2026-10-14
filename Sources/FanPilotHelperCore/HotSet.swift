import FanPilotKit
import Foundation

/// What the failsafe sees (docs/SPEC.md 3.4, 4.5 #6).
public struct HotSetReading: Equatable, Sendable {
    /// Hottest value over the hot set, or nil if not a single usable temperature could be read.
    /// Values above the normal display range (125 C and more) are kept on purpose: a sensor that
    /// reports 130 C is a reason to cool, not a reason to ignore the sensor.
    public var maxTempC: Double?
    /// Name of the hottest sensor (for the log).
    public var hottest: String?
    /// How many sensors contributed.
    public var sensorCount: Int

    public init(maxTempC: Double?, hottest: String? = nil, sensorCount: Int = 0) {
        self.maxTempC = maxTempC
        self.hottest = hottest
        self.sensorCount = sensorCount
    }

    public static let blind = HotSetReading(maxTempC: nil)
}

/// Source of hot-set temperatures for the failsafe. The daemon reads these itself, independent of
/// the app, so a crashed or malicious client cannot blind it.
public protocol HotSetProvider: AnyObject {
    /// Reads the hot set once.
    func read() -> HotSetReading
    /// Re-discovers sensors (after wake). May be slow (about a second on a 3600 key SMC).
    func refresh()
}

/// Reads the hot set straight from the SMC and the HID event system with a deliberately small and
/// conservative classifier: CPU, GPU and SoC die sensors, never battery, airflow, palm rest,
/// storage or wireless (docs/SPEC.md 3.4). It is kept independent of the full sensor catalog so a
/// classification bug in the app-facing code can not disable the failsafe.
public final class SMCHotSetReader: HotSetProvider {
    /// Key-name prefixes of CPU, GPU and SoC sensors, across Apple Silicon generations and Intel.
    /// `Tm` is memory on M1/M2 and CPU on M5; including it is harmless either way.
    public static let hotPrefixes = ["Tp", "Te", "Tm", "Tg", "TC", "TG", "TVD", "TPD", "TRD", "TUD"]
    /// Keys under a hot prefix that are not die temperatures (charger, power supply).
    public static let excludedKeys: Set<String> = ["TCHP", "TPSP"]
    /// HID product prefix of the real die sensors (`PMU tdie1` ... `PMU tdie14`).
    public static let hidDiePrefix = "PMU tdie"
    /// Anything at or above this is a garbage value, not a temperature.
    public static let garbageCeilingC: Double = 400
    /// Keys read per prefix family. A Mac like the M5 Pro has 40 `Tm` and 42 `Tg` keys that track
    /// each other within a few degrees; reading every one each second costs about 30 ms for no gain,
    /// so large families are sampled evenly (first and last key always included).
    public static let maxKeysPerFamily = 12

    private let smc: SMCClient
    private let includeHID: Bool
    private var keys: [FourCC] = []

    public init(smc: SMCClient, includeHID: Bool = true) {
        self.smc = smc
        self.includeHID = includeHID
    }

    /// True for an SMC key name in the hot set.
    public static func isHotKey(_ name: String) -> Bool {
        guard !excludedKeys.contains(name) else { return false }
        return hotPrefixes.contains { name.hasPrefix($0) }
    }

    /// A reading as a usable temperature, or nil for sentinels (zero, 4.0, -9200) and garbage.
    public static func usableTemperature(_ raw: Double) -> Double? {
        guard raw.isFinite, raw >= Constants.minValidTempC, raw < garbageCeilingC else { return nil }
        return raw
    }

    public var sensorKeys: [FourCC] { keys }

    /// At most `limit` elements spread evenly over `keys`, always including the first and the last.
    static func sampled(_ keys: [FourCC], limit: Int) -> [FourCC] {
        guard keys.count > limit, limit >= 2 else { return keys }
        let sorted = keys.sorted()
        return (0..<limit).map { sorted[$0 * (sorted.count - 1) / (limit - 1)] }
    }

    public func refresh() {
        var families: [String: [FourCC]] = [:]
        var candidates = 0
        do {
            for key in try smc.allKeys() {
                let name = key.string
                guard Self.isHotKey(name), let family = Self.hotPrefixes.first(where: { name.hasPrefix($0) }) else { continue }
                guard let info = try? smc.keyInfo(key) else { continue }
                // `flt ` on Apple Silicon, `sp78` on Intel. Everything else (`ioft`, `si32`, ...) has no
                // trustworthy temperature meaning.
                guard (info.type == .flt && info.size == 4) || (info.type == .sp78 && info.size == 2) else { continue }
                families[family, default: []].append(key)
                candidates += 1
            }
        } catch {
            HelperLog.error("hot-set discovery failed: \(error)")
        }
        keys = families.keys.sorted().flatMap { Self.sampled(families[$0] ?? [], limit: Self.maxKeysPerFamily) }
        HelperLog.info("hot set: \(keys.count) of \(candidates) SMC sensors" + (includeHID ? " plus HID die sensors" : ""))
    }

    public func read() -> HotSetReading {
        var best: Double?
        var bestName: String?
        var count = 0

        func consider(_ value: Double, _ name: String) {
            guard let temp = Self.usableTemperature(value) else { return }
            count += 1
            if best == nil || temp > best! {
                best = temp
                bestName = name
            }
        }

        for key in keys {
            guard let value = try? smc.read(key), let number = value.numericValue else { continue }
            consider(number, key.string)
        }
        if includeHID {
            for entry in HIDThermal.readTemperatures()
            where entry.hasValue && entry.product.hasPrefix(Self.hidDiePrefix) {
                consider(entry.value, entry.product)
            }
        }
        return HotSetReading(maxTempC: best, hottest: bestName, sensorCount: count)
    }
}

/// Combines several providers and reports the hottest value any of them sees. The failsafe uses two
/// independent classifiers (the catalog based one from FanPilotSensors and the prefix scan above),
/// so a classification mistake in either cannot hide a hot sensor. It is blind only if all are.
public final class CompositeHotSetProvider: HotSetProvider {
    private let providers: [HotSetProvider]

    public init(_ providers: [HotSetProvider]) {
        self.providers = providers
    }

    public func read() -> HotSetReading {
        var best = HotSetReading.blind
        for provider in providers {
            let reading = provider.read()
            best.sensorCount += reading.sensorCount
            if let temp = reading.maxTempC, temp > (best.maxTempC ?? -.infinity) {
                best.maxTempC = temp
                best.hottest = reading.hottest
            }
        }
        return best
    }

    public func refresh() {
        providers.forEach { $0.refresh() }
    }
}
