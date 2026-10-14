import CSMC
import Foundation

/// One temperature service from the private IOHID event system.
public struct HIDTemperature: Equatable, Sendable {
    /// The service's `Product` property, e.g. `PMU tdie3`, `gas gauge battery`, `NAND CH0 temp`.
    public var product: String
    /// `LocationID`; several services can share a product name and differ here.
    public var locationID: Int64?
    /// Degrees Celsius. Meaningless when `hasValue` is false. Sentinels such as about -9200
    /// (`PMU tdev*`) are NOT filtered here.
    public var value: Double
    /// False if the service delivered no temperature event (for example `als-temp`).
    public var hasValue: Bool

    public init(product: String, locationID: Int64?, value: Double, hasValue: Bool) {
        self.product = product
        self.locationID = locationID
        self.value = value
        self.hasValue = hasValue
    }
}

/// Access to HID temperature sensors (docs/SPEC.md 3.1). All needed functions are private IOKit
/// symbols resolved at runtime; if any is missing everything here degrades to "no sensors".
public enum HIDThermal {
    /// Upper bound on services read in one pass (77 on the M5 Pro).
    private static let capacity = 512

    /// True when all private symbols resolved. This does not guarantee any service exists.
    public static var isAvailable: Bool {
        fp_hid_available() != 0
    }

    /// Reads all temperature services once. Returns an empty array when the API is unavailable.
    /// Duplicates (the same product and location reported by several services) are preserved.
    public static func readTemperatures() -> [HIDTemperature] {
        var buffer = [fp_hid_temp_t](repeating: fp_hid_temp_t(), count: capacity)
        var total = 0
        let count = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            fp_hid_read_temperatures(ptr.baseAddress, capacity, &total)
        }
        guard count > 0 else { return [] }

        return buffer.prefix(Int(count)).map { entry in
            var raw = entry.product
            let product = withUnsafePointer(to: &raw) { tuplePtr -> String in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(FP_HID_NAME_MAX)) { String(cString: $0) }
            }
            return HIDTemperature(product: product,
                                  locationID: entry.location_id >= 0 ? entry.location_id : nil,
                                  value: entry.value,
                                  hasValue: entry.has_value != 0)
        }
    }

    /// Drops the cached HID client; the next read creates a fresh one. Call after wake.
    public static func reset() {
        fp_hid_shutdown()
    }
}
