import FanPilotKit
import Foundation

/// Traffic-light state of one diagnostics row (green / yellow / grey).
public enum DiagnosticStatus: String, Codable, Sendable {
    case ok
    case warning
    case notApplicable
}

public struct DiagnosticResult: Equatable, Sendable {
    public var status: DiagnosticStatus
    public var message: String
    /// Names of the fans or sensors the message is about.
    public var subjects: [String]

    public init(status: DiagnosticStatus, message: String, subjects: [String] = []) {
        self.status = status
        self.message = message
        self.subjects = subjects
    }
}

/// The diagnostics section of the main window: fans, sensors, battery.
public struct DiagnosticsReport: Equatable, Sendable {
    public var fans: DiagnosticResult
    public var sensors: DiagnosticResult
    public var battery: DiagnosticResult

    public init(fans: DiagnosticResult, sensors: DiagnosticResult, battery: DiagnosticResult) {
        self.fans = fans
        self.sensors = sensors
        self.battery = battery
    }
}

public enum FanDiagnostics {
    /// Intel Macs known to switch their fans off when cool. Every Apple Silicon Mac may do so.
    static let intelModelsThatCanStop: Set<String> = [
        "MacBookPro12,1", "MacBookPro13,1", "MacBookPro13,2", "MacBookPro14,1", "MacBookPro14,2",
        "MacBookPro15,2", "MacBookPro16,2", "MacBookPro16,3", "MacBookAir8,1",
    ]

    /// Judges the fans from one snapshot.
    ///
    /// - A fan at 0 RPM in automatic mode is NORMAL on Apple Silicon (the OS keeps fans off when
    ///   cool; Mac17,x idle at 0 RPM). On Intel it is only normal for models that can stop.
    /// - A fan commanded manually to at least its minimum that still reads 0 RPM is a problem, but
    ///   only judged when `manualCommandAge[fan]` says the command is older than `spinUpGrace`
    ///   (a fan needs a few seconds to spin up). Without that information manual fans are skipped.
    /// - `badFanMask` is the hardware's `FBAD` bitmask, bit n for fan n.
    public static func evaluate(infos: [FanInfo],
                                readings: [FanReading],
                                hardware: HardwareInfo,
                                badFanMask: UInt32? = nil,
                                manualCommandAge: [Int: TimeInterval] = [:],
                                spinUpGrace: TimeInterval = 15) -> DiagnosticResult {
        guard !infos.isEmpty else {
            return DiagnosticResult(status: .notApplicable, message: "No fans detected on this Mac.")
        }
        let readingByIndex = Dictionary(readings.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })

        let unreadable = infos.filter { readingByIndex[$0.index] == nil }.map(\.name)
        if !unreadable.isEmpty {
            return DiagnosticResult(status: .warning,
                                    message: "Could not read fan speed: \(unreadable.joined(separator: ", ")).",
                                    subjects: unreadable)
        }

        if let badFanMask {
            let flagged = infos.filter { badFanMask & (1 << UInt32($0.index)) != 0 }.map(\.name)
            if !flagged.isEmpty {
                return DiagnosticResult(status: .warning,
                                        message: "The hardware reports a problem with: \(flagged.joined(separator: ", ")).",
                                        subjects: flagged)
            }
        }

        var stalled: [String] = []
        for info in infos {
            guard let reading = readingByIndex[info.index], reading.actualRPM < 1 else { continue }
            if reading.isManual {
                if let age = manualCommandAge[info.index], age >= spinUpGrace, reading.targetRPM >= reading.minRPM {
                    stalled.append(info.name)
                }
            } else if !hardware.isAppleSilicon && !intelModelsThatCanStop.contains(hardware.model) {
                stalled.append(info.name)
            }
        }
        if !stalled.isEmpty {
            return DiagnosticResult(status: .warning,
                                    message: "Not spinning although it should be: \(stalled.joined(separator: ", ")).",
                                    subjects: stalled)
        }

        return DiagnosticResult(status: .ok,
                                message: infos.count == 1 ? "The fan is working normally." : "Fans are working normally.")
    }
}

public enum SensorDiagnostics {
    /// Judges the temperature sensors: every sensor outside "Other" should have a valid reading.
    public static func evaluate(readings: [SensorReading]) -> DiagnosticResult {
        let shown = readings.filter { $0.sensor.area != .other }
        guard !shown.isEmpty else {
            return DiagnosticResult(status: .warning, message: "No temperature sensors found. Resetting the SMC may help.")
        }
        let invalid = shown.filter { !$0.valid }.map { $0.sensor.name }
        guard invalid.isEmpty else {
            let preview = invalid.prefix(5).joined(separator: ", ")
            let more = invalid.count > 5 ? " and \(invalid.count - 5) more" : ""
            return DiagnosticResult(status: .warning,
                                    message: "No valid reading from: \(preview)\(more).",
                                    subjects: invalid)
        }
        return DiagnosticResult(status: .ok, message: "All \(shown.count) temperature sensors are reporting.")
    }
}

public enum BatteryDiagnostics {
    public static func evaluate(_ info: BatteryInfo) -> DiagnosticResult {
        guard info.isPresent else {
            return DiagnosticResult(status: .notApplicable, message: "This Mac does not have an internal battery.")
        }
        var parts: [String] = []
        if let condition = info.condition { parts.append("Condition: \(condition)") }
        if let health = info.healthPercent { parts.append("Maximum capacity: \(health)%") }
        if let cycles = info.cycleCount { parts.append("Cycle count: \(cycles)") }
        let text = parts.isEmpty ? "Battery present." : parts.joined(separator: ", ")
        return DiagnosticResult(status: info.isHealthy ? .ok : .warning, message: text)
    }
}
