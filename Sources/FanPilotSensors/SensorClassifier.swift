import FanPilotKit
import Foundation

/// Display name and area for a sensor the catalog does not list.
public struct SensorClassification: Hashable, Sendable {
    public var name: String
    public var area: SensorArea

    public init(name: String, area: SensorArea) {
        self.name = name
        self.area = area
    }
}

/// Prefix-and-topology heuristics for Macs that have no exact catalog entry (docs/SPEC.md 3.3,
/// step 2).
///
/// Key prefixes do NOT keep their meaning across generations: `Tm` is memory on M1/M2 and a
/// performance core on the M5 Pro/Max, `Tp` mixes efficiency and performance cores on M1 to M4 and
/// are "Super" cores on M5. So the CPU cluster names from `hw.perflevel*` decide those families,
/// and nothing here assumes more than the prefix families we have actually seen.
///
/// Anything not recognized is `.other`, named by its key.
public enum SensorClassifier {
    // MARK: SMC

    /// Classifies a set of SMC keys together, because the numbering ("Super Core 3") depends on the
    /// whole set. Keys are processed in sorted order, which also makes the numbering stable.
    public static func classify(smcKeys: [String], hardware: HardwareInfo) -> [String: SensorClassification] {
        let rules = hardware.isAppleSilicon ? appleSiliconRule : intelRule
        var rulings: [(key: String, rule: Rule)] = []
        for key in Set(smcKeys).sorted() {
            rulings.append((key, rules(Array(key.utf8), key, hardware)))
        }

        // Count family members first so ".ifMultiple" can decide whether a number is needed.
        var totals: [FamilyID: Int] = [:]
        for (_, rule) in rulings { totals[rule.family, default: 0] += 1 }

        var next: [FamilyID: Int] = [:]
        var result: [String: SensorClassification] = [:]
        for (key, rule) in rulings {
            let ordinal = (next[rule.family] ?? 0) + 1
            next[rule.family] = ordinal
            // More keys of a core family than the CPU has cores are not core sensors (the M5 Pro
            // exposes 23 `Tp`, 40 `Tm` and 111 `sd` keys for 18 cores): the surplus is "Other".
            if let limit = memberLimit(for: rule, hardware: hardware), ordinal > limit {
                result[key] = SensorClassification(name: key, area: .other)
                continue
            }
            let name: String
            switch rule.numbering {
            case .never: name = rule.name
            case .always: name = "\(rule.name) \(ordinal)"
            case .ifMultiple: name = totals[rule.family, default: 1] > 1 ? "\(rule.name) \(ordinal)" : rule.name
            }
            result[key] = SensorClassification(name: name, area: rule.area)
        }
        return result
    }

    /// The most numbered sensors a family may have on this machine, from the CPU topology. Nil means
    /// no bound (unknown topology, or a family with no way to tell).
    private static func memberLimit(for rule: Rule, hardware: HardwareInfo) -> Int? {
        guard rule.numbering == .always, !hardware.perfLevels.isEmpty else { return nil }
        func cores(_ level: String) -> Int {
            hardware.perfLevels.first { $0.name.caseInsensitiveCompare(level) == .orderedSame }?.physicalCPUs ?? 0
        }
        switch (rule.area, rule.name) {
        case (.cpu, "Super Core"): return cores("Super")
        case (.cpu, "Performance Core"): return cores("Performance")
        case (.cpu, "Efficiency Core"): return cores("Efficiency")
        case (.cpu, "CPU Core"): return hardware.totalPhysicalCPUs
        // No core count to compare with; the M5 Pro SMC exposes 40 `Tg` keys, far more than the handful
        // of GPU regions worth listing, so a generous fixed bound keeps the list readable.
        case (.gpu, _), (.memory, _): return 16
        default: return nil
        }
    }

    // MARK: HID

    public static func classify(hidName: String) -> SensorClassification {
        if hidName.hasPrefix("gas gauge battery"), let index = trailingNumber(of: hidName) {
            // Index 0 is the gauge the exact catalogs use; the other five services of the M5 Pro
            // report the same pack and only clutter the Battery group.
            return index == 0
                ? SensorClassification(name: "Battery Gas Gauge", area: .battery)
                : SensorClassification(name: "Battery Gas Gauge \(index + 1)", area: .other)
        }
        if hidName == "NAND CH0 temp" {
            return SensorClassification(name: "SSD (NAND I/O)", area: .storage)
        }
        if hidName.hasPrefix("PMU tdie"), let die = trailingNumber(of: hidName) {
            return SensorClassification(name: "SoC Die \(die)", area: .soc)
        }
        return SensorClassification(name: hidName, area: .other)
    }

    // MARK: Rule plumbing

    private enum Numbering { case never, ifMultiple, always }

    private struct FamilyID: Hashable {
        let area: SensorArea
        let name: String
    }

    private struct Rule {
        let name: String
        let area: SensorArea
        let numbering: Numbering
        var family: FamilyID { FamilyID(area: area, name: name) }

        static func fixed(_ name: String, _ area: SensorArea) -> Rule {
            Rule(name: name, area: area, numbering: .never)
        }

        static func numbered(_ name: String, _ area: SensorArea) -> Rule {
            Rule(name: name, area: area, numbering: .always)
        }

        static func numberedIfMultiple(_ name: String, _ area: SensorArea) -> Rule {
            Rule(name: name, area: area, numbering: .ifMultiple)
        }

        static func other(_ key: String) -> Rule {
            Rule(name: key, area: .other, numbering: .never)
        }
    }

    private static func trailingNumber(of text: String) -> Int? {
        let digits = text.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }

    // MARK: Apple Silicon

    /// Names that are stable across generations (taken from the exact catalogs).
    private static let knownAppleSiliconNames: [String: Rule] = [
        "TB0T": .fixed("Battery", .battery),
        "TB1T": .fixed("Battery Management Unit", .battery),
        "TB2T": .fixed("Battery Proximity", .battery),
        "TCHP": .fixed("Charger Proximity", .power),
        "TPSP": .fixed("Power Supply Proximity", .power),
        "TPSp": .fixed("Power Supply Proximity", .power),
        "TPSD": .fixed("Power Supply", .power),
        "TaLP": .fixed("Airflow Left", .airflow),
        "TaRF": .fixed("Airflow Right", .airflow),
        "TaTP": .fixed("Airflow Top", .airflow),
        "TaLW": .fixed("Airflow Left Side", .airflow),
        "TaRW": .fixed("Airflow Right Side", .airflow),
        "TaFL": .fixed("Airflow Front Left", .airflow),
        "TaFR": .fixed("Airflow Front Right", .airflow),
        "TaRL": .fixed("Airflow Rear Left", .airflow),
        "TaRR": .fixed("Airflow Rear Right", .airflow),
        // `Ta` + L/R + T is a Thunderbolt port sensor, not airflow, despite the prefix.
        "TaLT": .fixed("Left Thunderbolt Ports Proximity", .thunderbolt),
        "TaRT": .fixed("Right Thunderbolt Ports Proximity", .thunderbolt),
        "TIOP": .fixed("Thunderbolt Proximity", .thunderbolt),
        // Only the lowercase spelling: on the M5 Pro `TS0P` is a different sensor (40-48 C against
        // ~31 C for `Ts0P`), and two rows called "Trackpad" cannot be told apart. Macs whose catalog
        // really lists `TS0P` get that name from the exact catalog, not from here.
        "Ts0P": .fixed("Trackpad", .palmRest),
        "Ts1P": .fixed("Trackpad Actuator", .palmRest),
        "TW0P": .fixed("Wireless Proximity", .wireless),
        "TW0p": .fixed("Wireless Proximity", .wireless),
        "TMVR": .fixed("Memory Voltage Regulator", .memory),
        "Tb0P": .fixed("Backlight Controller Proximity", .display),
    ]

    private static func appleSiliconRule(_ c: [UInt8], _ key: String, _ hw: HardwareInfo) -> Rule {
        if let known = knownAppleSiliconNames[key] { return known }
        guard c.count == 4 else { return .other(key) }
        let super_ = hw.hasSuperCores

        switch (c[0], c[1]) {
        case (ascii("T"), ascii("p")):
            return .numbered(super_ ? "Super Core" : "CPU Core", .cpu)
        case (ascii("T"), ascii("e")):
            return .numbered("Efficiency Core", .cpu)
        case (ascii("T"), ascii("m")):
            // The one family whose meaning flips: Performance cores on M5 Pro/Max, memory before.
            return super_ ? .numbered("Performance Core", .cpu) : .numbered("Memory Bank", .memory)
        case (ascii("T"), ascii("g")):
            return .numbered(super_ ? "GPU Region" : "GPU Cluster", .gpu)
        case (ascii("f"), ascii("t")):
            switch c[2] {
            case ascii("E"): return .numbered("Efficiency Core", .cpu)
            case ascii("P"): return .numbered("Performance Core", .cpu)
            case ascii("G"): return .numbered(super_ ? "GPU Region" : "GPU Cluster", .gpu)
            default: return .other(key)
            }
        case (ascii("s"), ascii("d")):
            return .numbered("Efficiency Core", .cpu)
        case (ascii("T"), ascii("H")):
            return .numberedIfMultiple("SSD", .storage)
        case (ascii("T"), ascii("N")):
            return .numbered("SSD NAND", .storage)
        case (ascii("T"), ascii("T")) where c[3] == ascii("D"):
            return .numbered("Thunderbolt Port", .thunderbolt)
        case (ascii("T"), ascii("L")) where c[3] == ascii("P"):
            return .numbered("LCD Panel", .display)
        case (ascii("T"), ascii("a")) where isUpper(c[2]):
            return .numbered("Airflow Sensor", .airflow)
        case (ascii("T"), ascii("W")):
            return .numberedIfMultiple("Wireless Proximity", .wireless)
        default:
            // `TC*`, `TP*`, `TV*`, `TR*`, `TU*`, `TD*`: SoC rails and die arrays on Apple Silicon
            // (TCMb, TPD*, TVD0 ...). SPEC 3.3 lists them as "SoC / Other"; they stay Other and the
            // failsafe hot set picks them up by prefix (see `HotSet`).
            return .other(key)
        }
    }

    // MARK: Intel (secondary, untested on hardware)

    private static func intelRule(_ c: [UInt8], _ key: String, _ hw: HardwareInfo) -> Rule {
        guard c.count == 4 else { return .other(key) }
        let hexDigits = Set("0123456789ABCDEFabcdef".utf8)

        switch (c[0], c[1]) {
        case (ascii("T"), ascii("C")):
            // TC0P, TC1C ...: hex digit then D/P/H/C/F; TCXC and TCSA are PECI and system agent.
            if c[2] == ascii("X") { return .fixed("CPU PECI", .cpu) }
            if c[2] == ascii("S") { return .fixed("CPU System Agent", .cpu) }
            if c[2] == ascii("G") { return .fixed("CPU Integrated Graphics", .gpu) }
            guard hexDigits.contains(c[2]) else {
                return key == "TCHP" ? .fixed("Charger Proximity", .power) : .other(key)
            }
            switch c[3] {
            case ascii("C"), ascii("c"): return .numbered("CPU Core", .cpu)
            case ascii("P"), ascii("p"): return .numberedIfMultiple("CPU Proximity", .cpu)
            case ascii("D"), ascii("d"): return .numberedIfMultiple("CPU Die", .cpu)
            case ascii("H"), ascii("h"): return .numberedIfMultiple("CPU Heatsink", .cpu)
            case ascii("F"), ascii("f"): return .numberedIfMultiple("CPU Die (PECI)", .cpu)
            default: return .other(key)
            }
        case (ascii("T"), ascii("G")):
            switch c[3] {
            case ascii("D"), ascii("P"), ascii("H"), ascii("T"), ascii("d"), ascii("p"), ascii("h"), ascii("t"):
                return .numbered("GPU", .gpu)
            default: return .other(key)
            }
        case (ascii("T"), ascii("M")), (ascii("T"), ascii("m")):
            return .numbered("Memory Proximity", .memory)
        case (ascii("T"), ascii("L")) where c[3] == ascii("P"):
            return .numbered("LCD Panel", .display)
        case (ascii("T"), ascii("B")) where c[3] == ascii("T"):
            return knownAppleSiliconNames[key] ?? .numbered("Battery", .battery)
        case (ascii("T"), ascii("H")):
            return .numberedIfMultiple("SSD", .storage)
        case (ascii("T"), ascii("A")), (ascii("T"), ascii("a")):
            return .numbered("Airflow Sensor", .airflow)
        case (ascii("T"), ascii("W")):
            return .numberedIfMultiple("Wireless Proximity", .wireless)
        case (ascii("T"), ascii("s")), (ascii("T"), ascii("S")):
            return c[3] == ascii("P") ? .numberedIfMultiple("Trackpad", .palmRest) : .other(key)
        case (ascii("T"), ascii("I")), (ascii("T"), ascii("T")):
            return .numbered("Thunderbolt Sensor", .thunderbolt)
        case (ascii("T"), ascii("P")) where c[2] == ascii("S"):
            return .numberedIfMultiple("Power Supply", .power)
        default:
            return .other(key)
        }
    }

    private static func ascii(_ s: Unicode.Scalar) -> UInt8 {
        UInt8(ascii: s)
    }

    private static func isUpper(_ b: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
    }
}
