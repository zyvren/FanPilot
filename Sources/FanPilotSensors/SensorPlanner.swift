import FanPilotKit
import Foundation

/// The sensors to poll on this machine, in display order.
public struct SensorPlan: Equatable, Sendable {
    public var sensors: [Sensor]
    /// The catalog model used, or nil when the heuristics classified everything.
    public var catalogModel: String?

    public init(sensors: [Sensor], catalogModel: String?) {
        self.sensors = sensors
        self.catalogModel = catalogModel
    }

    public var smcKeys: [String] { sensors.filter { $0.source == .smc }.map(\.key) }
    public var hidNames: [String] { sensors.filter { $0.source == .hid }.map(\.key) }
}

/// Decides which sensors exist on this machine and what they are called (docs/SPEC.md 3.1 to 3.3).
///
/// Pure function of its inputs: no hardware access, so every rule is unit-testable.
///
/// Rules:
/// - **Exact model**: each catalog row is shown if its key was read and the value is valid
///   (SPEC 2.4 #4); rows for keys the unit does not have (core-count variants of one model
///   identifier) vanish. Every other eligible key goes to "Other" (a list that is evidently
///   incomplete lets the heuristics classify the areas it does not mention); `PMU tdie*` goes to
///   "SoC Die".
/// - **Unknown model**: `SensorClassifier` assigns areas by prefix and CPU topology.
/// - Invalid readings are not added to a new plan (so a dead key does not clutter the list), but a
///   sensor in `sticky` stays so a sensor that is momentarily N/A does not jump in and out of the UI.
public enum SensorPlanner {
    public static func plan(hardware: HardwareInfo,
                            smc: [String: Double],
                            hid: [HIDSample],
                            sticky: Set<String> = []) -> SensorPlan {
        let hidByName = Dictionary(hid.map { ($0.name, $0.value) }, uniquingKeysWith: max)

        func eligible(_ id: String, _ value: Double?) -> Bool {
            guard let value else { return false }
            return Constants.isValidTemperature(value) || sticky.contains(id)
        }

        let catalog = hardware.isAppleSilicon ? SensorCatalog.rows(forModel: hardware.model) : nil

        var listed: [Sensor] = []
        var used = Set<String>()
        if let catalog {
            for row in catalog {
                let value = row.source == .smc ? smc[row.key] : hidByName[row.key]
                guard eligible(row.sensor.id, value) else { continue }
                listed.append(row.sensor)
                used.insert(row.sensor.id)
            }
        }

        // Everything else that is eligible. For an exact model these are "extras"; for an unknown
        // model they are the whole list.
        var extraSMCKeys: [String] = []
        for (key, value) in smc where SensorRules.isEligibleForOther(key) {
            let id = Sensor.makeID(source: .smc, key: key)
            if !used.contains(id), eligible(id, value) { extraSMCKeys.append(key) }
        }
        var extraHID: [String] = []
        for (name, value) in hidByName {
            let id = Sensor.makeID(source: .hid, key: name)
            if !used.contains(id), eligible(id, value) { extraHID.append(name) }
        }

        // Classification of the extras. An unknown model uses the heuristics for everything. An exact
        // model trusts its list: leftovers stay in "Other" (SPEC 3.2). The one exception is a list the
        // recovered source tables evidently cut short (Mac14,13 lost everything after the CPU rows;
        // every real Mac has an SSD, so a list without a storage row is incomplete). There the areas
        // the list does not mention at all fall back to the heuristics.
        var adopted = extraSMCKeys
        if let catalog {
            adopted = []
            if !catalog.contains(where: { $0.area == .storage }) {
                let covered = Set(catalog.map(\.area))
                let guesses = SensorClassifier.classify(smcKeys: extraSMCKeys, hardware: hardware)
                adopted = extraSMCKeys.filter { key in
                    guard let area = guesses[key]?.area else { return false }
                    return area != .other && !covered.contains(area)
                }
            }
        }
        // Numbering ("GPU Cluster 2") must count only the keys that were adopted.
        let classes = SensorClassifier.classify(smcKeys: adopted, hardware: hardware)

        var extras: [Sensor] = []
        for key in extraSMCKeys.sorted(by: naturalOrder) {
            let c = classes[key] ?? SensorClassification(name: key, area: .other)
            extras.append(.smc(key: key, name: c.name, area: c.area))
        }
        for name in extraHID.sorted(by: naturalOrder) {
            let c = SensorClassifier.classify(hidName: name)
            extras.append(.hid(key: name, name: c.name, area: c.area))
        }

        // Stable sort by area: catalog order first inside an area, then the extras by key.
        let ordered = (listed + extras).enumerated().sorted { lhs, rhs in
            if lhs.element.area != rhs.element.area { return lhs.element.area < rhs.element.area }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return SensorPlan(sensors: ordered, catalogModel: catalog == nil ? nil : hardware.model)
    }

    private static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}

/// Which sensors count for the thermal failsafe (docs/SPEC.md 3.4): the CPU, GPU and SoC die, plus
/// the SoC rails that land in "Other". Battery, airflow, palm rest, wireless and storage are
/// excluded: they are slow, cool, or both, and a hot battery cannot be fixed by spinning the fans
/// faster.
public enum HotSet {
    /// Key prefixes in the "Other" group that are die- or rail-level silicon sensors on Apple
    /// Silicon: leftover core and cluster keys, plus `TV*` `TCM*` `TPD*` `TRD*` `TUD*` (the sensors
    /// that were hottest under an all-core load, measured on an M5 Pro MacBook Pro).
    static let otherSoCPrefixes = ["Tp", "Tm", "Tg", "Te", "Ts", "ftE", "ftP", "ftG", "TV", "TCM", "TPD", "TRD", "TUD"]

    public static func contains(_ sensor: Sensor) -> Bool {
        switch sensor.area {
        case .cpu, .gpu, .soc:
            return true
        case .other:
            return sensor.source == .smc && otherSoCPrefixes.contains { sensor.key.hasPrefix($0) }
        default:
            return false
        }
    }
}
