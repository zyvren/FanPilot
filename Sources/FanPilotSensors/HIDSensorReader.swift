import FanPilotKit
import Foundation

/// One cleaned HID temperature: a unique sensor name and its value in degrees Celsius.
public struct HIDSample: Hashable, Sendable {
    public let name: String
    public let value: Double

    public init(name: String, value: Double) {
        self.name = name
        self.value = value
    }
}

/// Reads the private IOHID temperature services and turns the raw service list into one value per
/// named sensor (docs/SPEC.md 3.1).
///
/// The raw list is untidy on Apple Silicon (measured on an M5 Pro MacBook Pro): every `PMU tdie*` and `PMU tdev*`
/// service shows up three times with readings 0.1 to 0.8 C apart, `PMU tdev*` reports about -9200 as
/// a "no data" sentinel, `PMU tcal` is a constant calibration value, and six services are all called
/// `gas gauge battery`.
public enum HIDSensorReader {
    /// Products that are not temperatures. They are dropped unless a model's catalog names them.
    static func isNonTemperatureProduct(_ product: String) -> Bool {
        product.hasPrefix("PMU tdev") || product == "PMU tcal"
    }

    static let gasGaugeProduct = "gas gauge battery"

    /// Cleans a raw service list:
    /// - drops services without a value, non-finite values and empty names;
    /// - drops `PMU tdev*` and `PMU tcal` unless listed in `keeping`;
    /// - merges services with the same (product, LocationID), keeping the HIGHEST reading (failing
    ///   towards "hotter" is the safe direction for a thermal tool);
    /// - renames `gas gauge battery` services `gas gauge battery 0`, `... 1`, ... ordered by
    ///   LocationID, so the names stay stable between reads;
    /// - merges what is left by name (max again), so a name identifies exactly one sensor.
    ///
    /// The result is sorted by name with numbers compared numerically (`PMU tdie2` before `PMU tdie10`).
    public static func normalize(_ raw: [HIDTemperature], keeping: Set<String> = []) -> [HIDSample] {
        struct Slot: Hashable {
            let product: String
            let location: Int64?
        }

        var bySlot: [Slot: Double] = [:]
        for entry in raw where entry.hasValue && entry.value.isFinite && !entry.product.isEmpty {
            if isNonTemperatureProduct(entry.product) && !keeping.contains(entry.product) { continue }
            let slot = Slot(product: entry.product, location: entry.locationID)
            bySlot[slot] = max(bySlot[slot] ?? -.infinity, entry.value)
        }

        var byName: [String: Double] = [:]

        let gauges = bySlot.filter { $0.key.product == gasGaugeProduct }
            .sorted { lhs, rhs in
                switch (lhs.key.location, rhs.key.location) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.value < rhs.value
                }
            }
        for (index, gauge) in gauges.enumerated() {
            byName["\(gasGaugeProduct) \(index)"] = gauge.value
        }

        for (slot, value) in bySlot where slot.product != gasGaugeProduct {
            byName[slot.product] = max(byName[slot.product] ?? -.infinity, value)
        }

        return byName
            .map { HIDSample(name: $0.key, value: $0.value) }
            .sorted { $0.name.compare($1.name, options: .numeric) == .orderedAscending }
    }

    /// Reads the live services once and cleans them. Empty if the private API is unavailable.
    public static func read(keeping: Set<String> = []) -> [HIDSample] {
        normalize(HIDThermal.readTemperatures(), keeping: keeping)
    }
}
