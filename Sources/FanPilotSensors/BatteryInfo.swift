import Foundation
import IOKit
import IOKit.ps

/// Battery facts for the diagnostics row (cycle count, health, condition). Read-only and
/// unprivileged.
public struct BatteryInfo: Equatable, Sendable {
    /// False on Macs without an internal battery.
    public var isPresent: Bool
    public var cycleCount: Int?
    /// Cycle count the pack is rated for (1000 on current MacBooks).
    public var designCycleCount: Int?
    /// Maximum capacity relative to design, 0 to 100 (macOS caps the figure at 100).
    public var healthPercent: Int?
    /// macOS wording: `Normal`, `Service Recommended`, ...
    public var condition: String?
    public var chargePercent: Int?
    public var isCharging: Bool
    public var isPluggedIn: Bool

    public init(isPresent: Bool, cycleCount: Int? = nil, designCycleCount: Int? = nil, healthPercent: Int? = nil,
                condition: String? = nil, chargePercent: Int? = nil, isCharging: Bool = false,
                isPluggedIn: Bool = false) {
        self.isPresent = isPresent
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.healthPercent = healthPercent
        self.condition = condition
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
    }

    public static let absent = BatteryInfo(isPresent: false)

    /// True when the condition is normal and capacity is at least 80 percent of design.
    public var isHealthy: Bool {
        (condition ?? "Normal") == "Normal" && (healthPercent ?? 100) >= 80
    }
}

public enum BatteryReader {
    /// Reads the `AppleSmartBattery` registry entry and the power-source condition. Returns
    /// `.absent` when there is no battery service.
    public static func read() -> BatteryInfo {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .absent }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return .absent }
        return parse(registry: properties, powerSource: powerSourceDescription())
    }

    /// Turns registry properties (and optionally the IOPS description) into `BatteryInfo`. Separate
    /// from `read()` so it can be tested with canned dictionaries.
    static func parse(registry p: [String: Any], powerSource: [String: Any]?) -> BatteryInfo {
        guard (p["BatteryInstalled"] as? Bool) ?? true else { return .absent }

        func int(_ dict: [String: Any], _ key: String) -> Int? {
            (dict[key] as? NSNumber)?.intValue
        }
        let data = p["BatteryData"] as? [String: Any] ?? [:]

        // Apple Silicon keeps capacities in mAh inside `BatteryData`; Intel keeps them at top level.
        let design = int(data, "DesignCapacity") ?? int(p, "DesignCapacity")
        var maximum = int(data, "NominalChargeCapacity") ?? int(p, "NominalChargeCapacity")
            ?? int(p, "AppleRawMaxCapacity")
        if maximum == nil, let legacy = int(p, "MaxCapacity"), legacy > 100 { maximum = legacy }
        var health: Int?
        if let design, design > 0, let maximum, maximum > 0 {
            health = min(100, Int((Double(maximum) / Double(design) * 100).rounded()))
        }

        var condition: String?
        if let powerSource {
            let reported = powerSource["BatteryHealthCondition"] as? String
            let overall = powerSource["BatteryHealth"] as? String
            if let reported, !reported.isEmpty {
                condition = reported
            } else if let overall {
                condition = overall == "Good" ? "Normal" : overall
            }
        }
        if condition == nil, let health {
            condition = health >= 80 ? "Normal" : "Service Recommended"
        }

        // `CurrentCapacity` is a percentage on Apple Silicon (MaxCapacity = 100).
        var charge: Int?
        if let current = int(p, "CurrentCapacity"), let max = int(p, "MaxCapacity"), max > 0 {
            charge = min(100, Int((Double(current) / Double(max) * 100).rounded()))
        }

        return BatteryInfo(isPresent: true,
                           cycleCount: int(p, "CycleCount"),
                           designCycleCount: int(p, "DesignCycleCount9C"),
                           healthPercent: health,
                           condition: condition,
                           chargePercent: charge,
                           isCharging: (p["IsCharging"] as? Bool) ?? false,
                           isPluggedIn: (p["ExternalConnected"] as? Bool) ?? false)
    }

    private static func powerSourceDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            return description
        }
        return nil
    }
}
