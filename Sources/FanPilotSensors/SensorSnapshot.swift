import FanPilotKit
import Foundation

/// The readings of one area, in display order.
public struct SensorGroup: Equatable, Sendable, Identifiable {
    public var area: SensorArea
    public var readings: [SensorReading]

    public var id: SensorArea { area }

    public init(area: SensorArea, readings: [SensorReading]) {
        self.area = area
        self.readings = readings
    }
}

/// Everything one poll produced.
public struct SensorSnapshot: Equatable, Sendable {
    /// Increases by one per refresh of an engine; lets a UI skip identical frames.
    public var sequence: Int
    public var timestamp: Date
    /// All readings in display order (area order, then catalog order).
    public var readings: [SensorReading]
    /// The same readings grouped by area, in area order. Areas without sensors are absent.
    public var groups: [SensorGroup]
    public var aggregates: SensorAggregates
    public var fanInfos: [FanInfo]
    public var fans: [FanReading]
    /// Highest valid value seen per sensor id since the monitor started (or the last reset).
    public var sessionMax: [String: Double]
    /// The catalog model in use, nil when heuristics classified the sensors.
    public var catalogModel: String?

    public init(sequence: Int = 0, timestamp: Date = Date(), readings: [SensorReading] = [],
                aggregates: SensorAggregates = SensorAggregates(), fanInfos: [FanInfo] = [],
                fans: [FanReading] = [], sessionMax: [String: Double] = [:], catalogModel: String? = nil) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.readings = readings
        self.groups = Self.group(readings)
        self.aggregates = aggregates
        self.fanInfos = fanInfos
        self.fans = fans
        self.sessionMax = sessionMax
        self.catalogModel = catalogModel
    }

    public func reading(id: String) -> SensorReading? {
        readings.first { $0.id == id }
    }

    /// The current value for a menu bar slot, rule or curve source; nil if it has no valid input.
    public func value(for selector: SensorSelector) -> Double? {
        if case .sensor(let id) = selector {
            guard let reading = reading(id: id), reading.valid else { return nil }
            return reading.value
        }
        return aggregates.value(for: selector)
    }

    /// Mean of the fans' actual speeds, nil if there are no readings (the "Average RPM" slot).
    public var averageFanRPM: Double? {
        fans.isEmpty ? nil : fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
    }

    static func group(_ readings: [SensorReading]) -> [SensorGroup] {
        var order: [SensorArea] = []
        var buckets: [SensorArea: [SensorReading]] = [:]
        for reading in readings {
            if buckets[reading.sensor.area] == nil { order.append(reading.sensor.area) }
            buckets[reading.sensor.area, default: []].append(reading)
        }
        return order.sorted().map { SensorGroup(area: $0, readings: buckets[$0] ?? []) }
    }
}
