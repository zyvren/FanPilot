import Foundation
import FanPilotKit

/// The temperatures the control engines look at, already aggregated (docs/SPEC.md 3.4).
///
/// FanPilotControl deliberately does not depend on the sensor module: the app builds one of
/// these per sensor tick, either from its own aggregates (memberwise init) or from raw readings
/// (`init(readings:sampledAt:)`).
public struct TemperatureInputs: Equatable, Sendable {
    /// When this sample was taken (same clock as `now`). The curve smoothing advances only when
    /// this changes, so calling the controller more often than the sensors tick is harmless.
    public var sampledAt: TimeInterval
    public var computerAverage: Double?
    public var highest: Double?
    public var averageCPU: Double?
    public var highestCPU: Double?
    /// Hottest of the failsafe hot set (CPU, GPU, SoC die). Used for the emergency ramp bypass;
    /// falls back to `highest` when nil.
    public var hotSetMax: Double?
    /// Valid readings by `Sensor.id`, for rules and curves bound to a single sensor.
    public var sensors: [String: Double]

    public init(sampledAt: TimeInterval = 0,
                computerAverage: Double? = nil, highest: Double? = nil,
                averageCPU: Double? = nil, highestCPU: Double? = nil,
                hotSetMax: Double? = nil, sensors: [String: Double] = [:]) {
        self.sampledAt = sampledAt
        self.computerAverage = Self.finite(computerAverage)
        self.highest = Self.finite(highest)
        self.averageCPU = Self.finite(averageCPU)
        self.highestCPU = Self.finite(highestCPU)
        self.hotSetMax = Self.finite(hotSetMax)
        self.sensors = sensors.filter { $0.value.isFinite }
    }

    /// Every aggregate equal to `celsius`. Convenient for tests and single-sensor callers.
    public static func uniform(_ celsius: Double, sampledAt: TimeInterval = 0) -> TemperatureInputs {
        TemperatureInputs(sampledAt: sampledAt, computerAverage: celsius, highest: celsius,
                          averageCPU: celsius, highestCPU: celsius, hotSetMax: celsius)
    }

    /// No data at all (every sensor unreadable).
    public static let none = TemperatureInputs()

    /// Aggregates are the mean / max of the valid readings, kept as floats.
    /// An empty CPU area falls back to the SoC die sensors, then to the overall figures.
    public init(readings: [SensorReading], sampledAt: TimeInterval) {
        var all: [Double] = []
        var cpu: [Double] = []
        var soc: [Double] = []
        var byID: [String: Double] = [:]
        var hot: Double?

        for reading in readings {
            // An over-range value on a hot-set sensor is invalid for display but must still push
            // towards cooling: fail towards more airflow, never less.
            if reading.value.isFinite, reading.value >= Constants.maxValidTempC,
               Self.hotSetAreas.contains(reading.sensor.area) {
                hot = Swift.max(hot ?? -.infinity, reading.value)
            }
            guard reading.valid, Constants.isValidTemperature(reading.value) else { continue }
            let value = reading.value
            all.append(value)
            byID[reading.sensor.id] = value
            switch reading.sensor.area {
            case .cpu: cpu.append(value)
            case .soc: soc.append(value)
            default: break
            }
            if Self.hotSetAreas.contains(reading.sensor.area) {
                hot = Swift.max(hot ?? -.infinity, value)
            }
        }

        let highest = all.max()
        let cpuGroup = !cpu.isEmpty ? cpu : soc
        self.init(sampledAt: sampledAt,
                  computerAverage: Self.mean(all),
                  highest: highest,
                  averageCPU: Self.mean(cpuGroup) ?? Self.mean(all),
                  highestCPU: cpuGroup.max() ?? highest,
                  hotSetMax: hot,
                  sensors: byID)
    }

    /// Value a rule, curve or menu slot bound to `selector` should look at; nil if unavailable.
    /// A single-sensor selector whose sensor is gone yields nil rather than silently turning into
    /// "highest": a rule on the SSD should not start spinning fans because some unrelated sensor
    /// is warm. The helper's failsafe covers real emergencies.
    public func value(for selector: SensorSelector) -> Double? {
        switch selector {
        case .computerAverage: return computerAverage
        case .highest: return highest
        case .averageCPU: return averageCPU
        case .highestCPU: return highestCPU
        case .sensor(let id): return sensors[id]
        }
    }

    /// Temperature the emergency check uses: the hot set, else the overall maximum.
    public var emergencyTemperature: Double? { hotSetMax ?? highest }

    /// True if at least one usable temperature is present.
    public var hasData: Bool {
        highest != nil || hotSetMax != nil || highestCPU != nil || computerAverage != nil
            || averageCPU != nil || !sensors.isEmpty
    }

    private static let hotSetAreas: Set<SensorArea> = [.cpu, .gpu, .soc]

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
