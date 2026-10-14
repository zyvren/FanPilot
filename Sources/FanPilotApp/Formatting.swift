import FanPilotKit
import FanPilotSensors
import Foundation

/// Text formatting shared by the menu bar item, the menu and the windows.
extension TemperatureUnit {
    /// A temperature DIFFERENCE (hysteresis, margins) in this unit: scale only, no +32 offset.
    func delta(fromCelsius c: Double) -> Double { self == .celsius ? c : c * 1.8 }

    func deltaToCelsius(_ value: Double) -> Double { self == .celsius ? value : value / 1.8 }

    /// `3 °C` / `5 °F`: a difference as whole degrees of this unit.
    func formatDelta(celsius c: Double) -> String {
        String(format: "%.0f ", delta(fromCelsius: c)) + symbol
    }
}

enum Fmt {
    /// `47°C`, or `N/A` for a missing value (never a fabricated number).
    static func temperature(_ celsius: Double?, unit: TemperatureUnit, includeUnit: Bool = true) -> String {
        unit.format(celsius: celsius, includeUnit: includeUnit)
    }

    /// `2350 RPM`, `N/A` if unknown.
    static func rpm(_ value: Double?, includeUnit: Bool = true) -> String {
        guard let value, value.isFinite else { return "N/A" }
        let text = String(format: "%.0f", value)
        return includeUnit ? text + " RPM" : text
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// `Right Side` -> `Right Side`; used where a fan name is missing.
    static func fanName(_ info: FanInfo?, index: Int) -> String {
        info?.name ?? "Fan \(index + 1)"
    }

    static func modeName(_ mode: ControlMode, usePercent: Bool) -> String {
        switch mode {
        case .auto: return "System"
        case .manual: return "Manual"
        case .max: return "Max"
        case .boost: return usePercent ? "Auto Boost" : "Auto Max"
        case .curve: return "Curve"
        }
    }

    /// Shorter label for the segmented control.
    static func segmentName(_ mode: ControlMode, usePercent: Bool) -> String {
        switch mode {
        case .boost: return usePercent ? "Boost" : "Auto Max"
        default: return modeName(mode, usePercent: usePercent)
        }
    }
}

extension SensorSelector {
    /// Name for pickers and tooltips given the current snapshot.
    func displayName(in snapshot: SensorSnapshot) -> String {
        switch self {
        case .computerAverage: return "Computer Average"
        case .highest: return "Highest"
        case .averageCPU: return "Average CPU"
        case .highestCPU: return "Highest CPU"
        case .sensor(let id):
            return snapshot.reading(id: id)?.sensor.name ?? "Unavailable sensor"
        }
    }
}

extension SensorArea {
    /// SF Symbol for the area list (Apple's own symbols only).
    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .soc: return "memorychip"
        case .memory: return "rectangle.stack"
        case .battery: return "battery.50"
        case .storage: return "internaldrive"
        case .airflow: return "gearshape.2"
        case .power: return "power"
        case .thunderbolt: return "bolt"
        case .palmRest: return "hand.raised"
        case .wireless: return "wifi"
        case .display: return "display"
        case .other: return "ellipsis.circle"
        }
    }
}

extension DiagnosticStatus {
    var light: LightStatus {
        switch self {
        case .ok: return .good
        case .warning: return .problem
        case .notApplicable: return .notApplicable
        }
    }
}
