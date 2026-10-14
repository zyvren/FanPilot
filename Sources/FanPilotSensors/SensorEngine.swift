import FanPilotKit
import Foundation

/// How often each part of the sensor set is actually read from hardware.
///
/// Measured on the M5 Pro (docs/SPEC.md 3.5 asked for one SMC and one HID pass per tick): an SMC
/// read costs about 0.17 ms, so the 53 curated sensors and the fans cost about 10 ms; the "Other"
/// group is another 360 keys (60 ms), and one HID pass over the 77 services costs about 80 ms.
/// Reading everything every 2 seconds would keep a core busy about 4% of the time for nothing a user
/// can see, so the slow-moving parts are refreshed less often and the values in between are carried
/// over.
public struct PollingPolicy: Equatable, Sendable {
    /// Minimum seconds between reads of the whole "Other" group. 0 reads it on every refresh.
    public var otherInterval: TimeInterval
    /// Minimum seconds between HID passes. 0 reads HID on every refresh.
    public var hidInterval: TimeInterval
    /// After each full "Other" pass the hottest failsafe-relevant "Other" sensors (TVD0 was the
    /// hottest sensor under load on the M5 Pro) are remembered and polled on EVERY refresh, so the
    /// hot-set maximum stays fresh while the rest of the group is only sampled every `otherInterval`.
    public var watchedOtherCount: Int

    public init(otherInterval: TimeInterval = 10, hidInterval: TimeInterval = 4, watchedOtherCount: Int = 12) {
        self.otherInterval = otherInterval
        self.hidInterval = hidInterval
        self.watchedOtherCount = watchedOtherCount
    }

    /// Everything on every refresh (CLI one-shot reads, tests).
    public static let everyRefresh = PollingPolicy(otherInterval: 0, hidInterval: 0, watchedOtherCount: 0)

    /// Timer jitter allowance: a pass that is due within this many seconds counts as due, so an
    /// `hidInterval` of 4 s with a 2 s tick means every second tick instead of every third.
    static let tolerance: TimeInterval = 0.25

    func isDue(last: Date?, now: Date, every: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) + Self.tolerance >= every
    }
}

/// Synchronous core of the sensor stack: discovery, reads, session maxima.
///
/// `SensorMonitor` wraps this with a timer and a background queue; the CLI and the root helper use
/// it directly when they just want a reading. All methods are safe to call from any thread (they
/// take one recursive lock), but a slow call (`reenumerate()` can take a second) holds it, so a
/// caller that polls on a timer should do all engine work on one queue.
///
/// The engine only reads. It is built on `SMCClient`, so tests drive it with `InMemorySMC`.
public final class SensorEngine: @unchecked Sendable {
    public typealias HIDProvider = @Sendable (_ keeping: Set<String>) -> [HIDSample]

    public let hardware: HardwareInfo

    private let hidProvider: HIDProvider
    private let smcReader: SMCSensorReader
    private let fanReader: FanReader
    private let lock = NSRecursiveLock()

    private var plan = SensorPlan(sensors: [], catalogModel: nil)
    private var prepared = false
    private var sessionMax: [String: Double] = [:]
    private var sequence = 0
    private var lastError: String?
    private var policy: PollingPolicy

    // Carried-over state between refreshes (see `PollingPolicy`).
    private var lastHIDPass: Date?
    private var hidValues: [String: Double] = [:]
    private var lastOtherPass: Date?
    private var watchedOther: Set<String> = []
    private var smcValueCache: [String: Double] = [:]
    /// Sensors the user depends on (menu bar slots, pins, Boost rules, the curve). They are read on
    /// every refresh whatever group they are in, so a value shown or acted on is never older than the
    /// update interval.
    private var priorityIDs: Set<String> = []

    public init(smc: SMCClient,
                hardware: HardwareInfo = .current(),
                policy: PollingPolicy = PollingPolicy(),
                hidProvider: @escaping HIDProvider = { HIDSensorReader.read(keeping: $0) }) {
        self.hardware = hardware
        self.policy = policy
        self.hidProvider = hidProvider
        self.smcReader = SMCSensorReader(smc: smc)
        self.fanReader = FanReader(smc: smc, model: hardware.model)
    }

    /// Opens a READ-ONLY connection to the real SMC. Use `init(smc:)` to supply another one.
    public convenience init(hardware: HardwareInfo = .current(), policy: PollingPolicy = PollingPolicy()) throws {
        self.init(smc: try IOKitSMC(access: .readOnly), hardware: hardware, policy: policy)
    }

    // MARK: State

    /// The sensors being polled, in display order. Empty before `prepare()`.
    public var sensors: [Sensor] {
        lock.lock(); defer { lock.unlock() }
        return plan.sensors
    }

    public var currentPlan: SensorPlan {
        lock.lock(); defer { lock.unlock() }
        return plan
    }

    public var fanDiscovery: FanDiscovery { fanReader.current }

    public var pollingPolicy: PollingPolicy {
        get { lock.lock(); defer { lock.unlock() }; return policy }
        set { lock.lock(); policy = newValue; lock.unlock() }
    }

    /// Replaces the set of sensors that are always read fresh (see `priorityIDs`).
    public func setPriorityIDs(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        priorityIDs = ids
    }

    /// Description of the last failure that made a refresh return less than everything, if any.
    public var lastErrorDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    // MARK: Preparation

    /// Enumerates SMC keys, reads the HID services once, builds the sensor plan and discovers fans.
    /// Called implicitly by the first `refresh()`.
    public func prepare() throws {
        lock.lock(); defer { lock.unlock() }
        try smcReader.enumerate()
        _ = try? fanReader.discover()
        rebuildPlan(sticky: [])
        prepared = true
        lastError = nil
    }

    /// Full re-enumeration: for wake from sleep, or when the SMC key count changed. Keeps the sensors
    /// that were shown (sticky) so the UI list does not shrink while a sensor is briefly N/A.
    public func reenumerate() throws {
        lock.lock(); defer { lock.unlock() }
        HIDThermal.reset()
        try smcReader.enumerate()
        _ = try? fanReader.discover()
        rebuildPlan(sticky: Set(plan.sensors.map(\.id)))
        prepared = true
        lastError = nil
    }

    /// Cheap periodic re-validation (SPEC 3.1: every 10 minutes): re-reads the cached candidates and
    /// adds sensors that have become valid. Falls back to a full enumeration if `#KEY` changed.
    public func revalidate() {
        lock.lock(); defer { lock.unlock() }
        guard prepared else { return }
        if smcReader.needsReenumeration() {
            try? reenumerate()
            return
        }
        rebuildPlan(sticky: Set(plan.sensors.map(\.id)))
    }

    private func rebuildPlan(sticky: Set<String>) {
        let smcValues = smcReader.readCandidates()
        // Catalog entries may name HID products the generic cleanup would drop (`PMU tdev5` on M1).
        let wanted = Set((SensorCatalog.rows(forModel: hardware.model) ?? []).filter { $0.source == .hid }.map(\.key))
        let hid = hidProvider(wanted)
        plan = SensorPlanner.plan(hardware: hardware, smc: smcValues, hid: hid, sticky: sticky)
        // Force the next refresh to read everything fresh.
        lastHIDPass = nil
        lastOtherPass = nil
        watchedOther = []
        smcValueCache = [:]
    }

    // MARK: Polling

    /// Reads sensors and fans and returns the snapshot, preparing first if needed. Never throws: a
    /// failed preparation yields an empty snapshot and sets `lastErrorDescription`.
    ///
    /// Which sensors are read from hardware this time follows `pollingPolicy`; pass `full: true` to
    /// read everything (for example when the "show all" list is opened).
    public func refresh(now: Date = Date(), full: Bool = false) -> SensorSnapshot {
        lock.lock(); defer { lock.unlock() }
        if !prepared {
            do { try prepare() } catch { lastError = "\(error)" }
        }

        let hasHID = plan.sensors.contains { $0.source == .hid }
        let priorityHID = !priorityIDs.isEmpty && plan.sensors.contains { $0.source == .hid && priorityIDs.contains($0.id) }
        if hasHID, full || priorityHID || policy.isDue(last: lastHIDPass, now: now, every: policy.hidInterval) {
            let wanted = Set(plan.hidNames)
            var latest: [String: Double] = [:]
            for sample in hidProvider(wanted) where wanted.contains(sample.name) { latest[sample.name] = sample.value }
            hidValues = latest
            lastHIDPass = now
        }

        // SMC: curated sensors every time; "Other" per policy, except the watched hot ones.
        let otherDue = full || policy.isDue(last: lastOtherPass, now: now, every: policy.otherInterval)
        var toRead: [FourCC] = []
        for sensor in plan.sensors where sensor.source == .smc {
            let carried = sensor.area == .other && !otherDue && !watchedOther.contains(sensor.id)
                && !priorityIDs.contains(sensor.id) && smcValueCache[sensor.key] != nil
            if !carried, let key = FourCC(sensor.key) { toRead.append(key) }
        }
        let fresh = smcReader.readValues(toRead)
        for key in toRead { smcValueCache[key.string] = fresh[key] }

        var readings: [SensorReading] = []
        readings.reserveCapacity(plan.sensors.count)
        for sensor in plan.sensors {
            let raw: Double?
            switch sensor.source {
            case .smc: raw = smcValueCache[sensor.key]
            case .hid: raw = hidValues[sensor.key]
            }
            guard let raw else {
                readings.append(.unavailable(sensor))
                continue
            }
            // `value` keeps the raw number even when invalid so out-of-range hot readings stay
            // visible to the failsafe; `valid` is what display code must check.
            let valid = Constants.isValidTemperature(raw)
            readings.append(SensorReading(sensor: sensor, value: raw, valid: valid))
            if valid { sessionMax[sensor.id] = max(sessionMax[sensor.id] ?? -.infinity, raw) }
        }

        if otherDue {
            lastOtherPass = now
            watchedOther = hottestOtherSensors(in: readings)
        }

        let fanReadings = fanReader.readAll()
        sequence += 1
        return SensorSnapshot(sequence: sequence,
                              timestamp: now,
                              readings: readings,
                              aggregates: SensorAggregates.compute(from: readings),
                              fanInfos: fanReader.fans,
                              fans: fanReadings,
                              sessionMax: sessionMax,
                              catalogModel: plan.catalogModel)
    }

    /// The ids of the `watchedOtherCount` hottest failsafe-relevant sensors in the "Other" group.
    private func hottestOtherSensors(in readings: [SensorReading]) -> Set<String> {
        guard policy.watchedOtherCount > 0 else { return [] }
        let candidates = readings.filter {
            $0.sensor.area == .other && $0.sensor.source == .smc && HotSet.contains($0.sensor) && $0.value.isFinite
        }
        let hottest = candidates.sorted { $0.value > $1.value }.prefix(policy.watchedOtherCount)
        return Set(hottest.map(\.sensor.id))
    }

    /// Forgets the per-sensor session maxima ("Reset Max Temperatures").
    public func resetSessionMax() {
        lock.lock(); defer { lock.unlock() }
        sessionMax.removeAll()
    }

    // MARK: Diagnostics inputs

    /// `FBAD` bad-fan bitmask, nil if unavailable.
    public func badFanMask() -> UInt32? { fanReader.readBadFanMask() }

    /// `DICT` override flag, nil if the key does not exist.
    public func overrideFlag() -> Bool? { fanReader.readOverrideFlag() }
}
