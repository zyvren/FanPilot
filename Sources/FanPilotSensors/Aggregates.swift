import FanPilotKit
import Foundation

/// The summary temperatures behind the menu bar slots, Auto Boost rules and the failsafe
/// (docs/SPEC.md 3.4). Values stay floating point.
///
/// Scope: the "Other" group is left out of the four user-facing aggregates. It is our own addition
/// (hundreds of rails and duplicates on a Mac like the M5 Pro) and including it would make
/// "Computer Average" mean something different from the curated sensor list the user sees. The
/// failsafe does not have that luxury: `hotSetMax` includes the hot "Other" sensors.
public struct SensorAggregates: Equatable, Sendable {
    /// Mean of valid sensors.
    public var computerAverage: Double?
    /// Maximum of valid sensors, and the sensor that holds it.
    public var highest: Double?
    public var highestSensorID: String?
    /// Mean and maximum over the CPU area. Fall back to SoC Die and then to the overall value when
    /// the CPU area has no valid reading.
    public var averageCPU: Double?
    public var highestCPU: Double?
    public var highestCPUSensorID: String?

    /// Hottest reading in the failsafe hot set, or nil if no hot-set sensor produced a usable
    /// number. Readings at or above the validity ceiling count here even though they are N/A for
    /// display: a runaway value must push the fans up, never be ignored (SPEC 2.4 #4).
    public var hotSetMax: Double?
    public var hotSetMaxSensorID: String?
    /// Number of hot-set sensors with a VALID reading. Zero means "blind": the helper must not keep
    /// fans in manual mode without being able to see temperatures (SPEC 4.5 #6).
    public var hotSetValidCount: Int

    public init(computerAverage: Double? = nil, highest: Double? = nil, highestSensorID: String? = nil,
                averageCPU: Double? = nil, highestCPU: Double? = nil, highestCPUSensorID: String? = nil,
                hotSetMax: Double? = nil, hotSetMaxSensorID: String? = nil, hotSetValidCount: Int = 0) {
        self.computerAverage = computerAverage
        self.highest = highest
        self.highestSensorID = highestSensorID
        self.averageCPU = averageCPU
        self.highestCPU = highestCPU
        self.highestCPUSensorID = highestCPUSensorID
        self.hotSetMax = hotSetMax
        self.hotSetMaxSensorID = hotSetMaxSensorID
        self.hotSetValidCount = hotSetValidCount
    }

    /// Computes all aggregates from one pass of readings.
    public static func compute(from readings: [SensorReading]) -> SensorAggregates {
        var result = SensorAggregates()

        let curated = readings.filter { $0.valid && $0.sensor.area != .other }
        if !curated.isEmpty {
            result.computerAverage = curated.map(\.value).reduce(0, +) / Double(curated.count)
            if let top = curated.max(by: { $0.value < $1.value }) {
                result.highest = top.value
                result.highestSensorID = top.sensor.id
            }
        }

        let cpu = curated.filter { $0.sensor.area == .cpu }
        let soc = curated.filter { $0.sensor.area == .soc }
        // CPU, else SoC die, else everything (SPEC 3.4).
        let cpuSource = !cpu.isEmpty ? cpu : (!soc.isEmpty ? soc : curated)
        if !cpuSource.isEmpty {
            result.averageCPU = cpuSource.map(\.value).reduce(0, +) / Double(cpuSource.count)
            if let top = cpuSource.max(by: { $0.value < $1.value }) {
                result.highestCPU = top.value
                result.highestCPUSensorID = top.sensor.id
            }
        }

        for reading in readings where HotSet.contains(reading.sensor) {
            let usable = reading.valid || (reading.value.isFinite && reading.value >= Constants.maxValidTempC)
            guard usable else { continue }
            if reading.valid { result.hotSetValidCount += 1 }
            if result.hotSetMax == nil || reading.value > result.hotSetMax! {
                result.hotSetMax = reading.value
                result.hotSetMaxSensorID = reading.sensor.id
            }
        }
        return result
    }

    /// The value a selector refers to, or nil when it has no valid input. `.sensor` needs the
    /// readings, so it is resolved by `SensorSnapshot.value(for:)`.
    public func value(for selector: SensorSelector) -> Double? {
        switch selector {
        case .computerAverage: return computerAverage
        case .highest: return highest
        case .averageCPU: return averageCPU
        case .highestCPU: return highestCPU
        case .sensor: return nil
        }
    }
}
