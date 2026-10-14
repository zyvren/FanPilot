import FanPilotKit
import Foundation

/// One row of a per-model sensor list: an SMC key or a HID product name with its display name and area.
///
/// The lists are data (see `CatalogData.swift`, maintained by hand). A row says
/// what a sensor IS on that model; whether it exists on this particular unit (core-count variants
/// of the same model identifier) is decided by `SensorPlanner` against the live SMC.
public struct CatalogRow: Hashable, Sendable {
    /// SMC key (`Tp04`) or HID product (`gas gauge battery 0`).
    public let key: String
    public let name: String
    public let area: SensorArea
    public let source: SensorSource

    init(key: String, name: String, area: SensorArea, source: SensorSource) {
        self.key = key
        self.name = name
        self.area = area
        self.source = source
    }

    static func smc(_ key: String, _ name: String, _ area: SensorArea) -> CatalogRow {
        CatalogRow(key: key, name: name, area: area, source: .smc)
    }

    static func hid(_ key: String, _ name: String, _ area: SensorArea) -> CatalogRow {
        CatalogRow(key: key, name: name, area: area, source: .hid)
    }

    public var sensor: Sensor {
        Sensor(id: Sensor.makeID(source: source, key: key), key: key, name: name, area: area, source: source)
    }
}

/// Exact per-model sensor tables for Apple Silicon Macs (docs/SPEC.md 3.3, step 1).
///
/// Models that are not listed fall back to `SensorClassifier`, which works from key prefixes and
/// the CPU topology.
public enum SensorCatalog {
    /// Model identifiers with an exact list, sorted.
    public static var knownModels: [String] {
        CatalogData.modelLists.keys.sorted()
    }

    public static func isKnown(model: String) -> Bool {
        CatalogData.modelLists[model] != nil
    }

    /// The exact list for `model`, in display order, or nil if the model is not in the catalog.
    /// Every returned key is a CANDIDATE: some may not exist on a given unit.
    public static func rows(forModel model: String) -> [CatalogRow]? {
        guard let index = CatalogData.modelLists[model], CatalogData.lists.indices.contains(index) else {
            return nil
        }
        return CatalogData.lists[index]
    }

    /// Same as `rows(forModel:)` as `Sensor` values.
    public static func sensors(forModel model: String) -> [Sensor]? {
        rows(forModel: model)?.map(\.sensor)
    }
}
