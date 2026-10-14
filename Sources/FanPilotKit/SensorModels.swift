import Foundation

/// Where a sensor value comes from.
public enum SensorSource: String, Codable, Sendable, CaseIterable {
    case smc
    case hid
}

/// Display grouping of sensors into areas (docs/SPEC.md 3.2).
public enum SensorArea: String, Codable, Sendable, CaseIterable, Comparable {
    case cpu
    case gpu
    /// PMU die sensors (`PMU tdie*`) and other SoC-level readings. Part of the failsafe hot set.
    case soc
    case memory
    case battery
    case storage
    /// Logic board / airflow sensors (shown as the group "Logic Board").
    case airflow
    /// Charger and power supply.
    case power
    case thunderbolt
    case palmRest
    case wireless
    case display
    /// Everything valid that has no better home. Hidden in the UI unless "show all" is on.
    case other

    /// Name for section headers.
    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .soc: return "SoC Die"
        case .memory: return "Memory"
        case .battery: return "Battery"
        case .storage: return "Storage"
        case .airflow: return "Logic Board"
        case .power: return "Power"
        case .thunderbolt: return "Thunderbolt"
        case .palmRest: return "Palm Rest"
        case .wireless: return "Wireless"
        case .display: return "Display"
        case .other: return "Other"
        }
    }

    /// Position in lists: the declaration order (CPU first, Other last).
    public var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    public static func < (lhs: SensorArea, rhs: SensorArea) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// One temperature sensor.
public struct Sensor: Hashable, Codable, Sendable, Identifiable {
    /// Stable identifier, `"smc:Tp04"` or `"hid:NAND CH0 temp"`. Persist this, never an index.
    public var id: String
    /// SMC key (`Tp04`) or HID product name (`gas gauge battery 0`).
    public var key: String
    /// Human readable name (`Super Core 1`).
    public var name: String
    public var area: SensorArea
    public var source: SensorSource

    public init(id: String, key: String, name: String, area: SensorArea, source: SensorSource) {
        self.id = id
        self.key = key
        self.name = name
        self.area = area
        self.source = source
    }

    /// Builds the canonical id for a source and key.
    public static func makeID(source: SensorSource, key: String) -> String {
        "\(source.rawValue):\(key)"
    }

    public static func smc(key: String, name: String, area: SensorArea) -> Sensor {
        Sensor(id: makeID(source: .smc, key: key), key: key, name: name, area: area, source: .smc)
    }

    public static func hid(key: String, name: String, area: SensorArea) -> Sensor {
        Sensor(id: makeID(source: .hid, key: key), key: key, name: name, area: area, source: .hid)
    }
}

/// A sensor with its current value. `valid` is false for N/A readings (out of range, unreadable);
/// `value` is then meaningless and must not be displayed or aggregated.
public struct SensorReading: Hashable, Codable, Sendable, Identifiable {
    public var sensor: Sensor
    /// Degrees Celsius.
    public var value: Double
    public var valid: Bool

    public var id: String { sensor.id }

    public init(sensor: Sensor, value: Double, valid: Bool) {
        self.sensor = sensor
        self.value = value
        self.valid = valid
    }

    /// An N/A reading for `sensor`.
    public static func unavailable(_ sensor: Sensor) -> SensorReading {
        SensorReading(sensor: sensor, value: .nan, valid: false)
    }
}

/// Which temperature a menu bar slot, Auto Boost rule or curve looks at.
///
/// Persisted as a short string: `average`, `highest`, `avgCPU`, `highestCPU` or `sensor:<sensor id>`.
/// Unknown strings decode to `.highest` so an old or edited settings blob never fails to load.
public enum SensorSelector: Hashable, Sendable, Codable {
    /// Mean of all valid sensors.
    case computerAverage
    /// Maximum of all valid sensors.
    case highest
    case averageCPU
    case highestCPU
    /// A single sensor by `Sensor.id`.
    case sensor(String)

    public var storageString: String {
        switch self {
        case .computerAverage: return "average"
        case .highest: return "highest"
        case .averageCPU: return "avgCPU"
        case .highestCPU: return "highestCPU"
        case .sensor(let id): return "sensor:\(id)"
        }
    }

    public init(storageString string: String) {
        switch string {
        case "average": self = .computerAverage
        case "highest": self = .highest
        case "avgCPU": self = .averageCPU
        case "highestCPU": self = .highestCPU
        default:
            if string.hasPrefix("sensor:"), string.count > "sensor:".count {
                self = .sensor(String(string.dropFirst("sensor:".count)))
            } else {
                self = .highest
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(storageString: (try? container.decode(String.self)) ?? "highest")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageString)
    }
}
