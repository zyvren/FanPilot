import AppKit
import FanPilotKit
import SwiftUI

// Colors, thresholds and the level bar used all over the UI.

/// Where a temperature sits relative to the warning and critical thresholds.
enum TemperatureZone {
    case normal, warning, critical

    /// `>= critical` is red, `>= warning` orange, otherwise normal. The comparison
    /// uses the whole-degree value that is displayed (`%.0f` rounds to nearest, ties to even), so "90"
    /// is never shown in the normal color. Truncating instead would show "90" in the
    /// normal color for 89.6; the rounded text and the color agreeing is the better behavior.
    init(celsius: Double, alerts: AlertSettings) {
        let shown = celsius.rounded(.toNearestOrEven)
        if shown >= alerts.criticalTempC { self = .critical }
        else if shown >= alerts.warningTempC { self = .warning }
        else { self = .normal }
    }

    /// Text color: nil keeps the normal (adaptive) text color.
    var textColor: Color? {
        switch self {
        case .normal: return nil
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    var nsTextColor: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Level bar fill: green, yellow, red (what a continuous NSLevelIndicator draws).
    var barColor: Color {
        switch self {
        case .normal: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }
}

enum Theme {
    /// Level bars for temperatures run from 0 to 110 C.
    static let temperatureBarRange: ClosedRange<Double> = 0...110

    static let panelWidth: CGFloat = 320

    static let rowHighlight = Color(nsColor: .selectedContentBackgroundColor)
    static let subtle = Color(nsColor: .secondaryLabelColor)
}

/// A horizontal level indicator with warning and critical zones and an optional marker (the
/// session maximum of a sensor, or the target speed of a fan).
struct LevelBar: View {
    var value: Double
    var range: ClosedRange<Double>
    var warning: Double
    var critical: Double
    var marker: Double?
    var markerColor: Color = .primary
    var height: CGFloat = 8

    private func fraction(_ v: Double) -> Double {
        guard range.upperBound > range.lowerBound, v.isFinite else { return 0 }
        return min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private var fillColor: Color {
        // Same rounding as the number printed next to the bar, so bar and text never disagree.
        let shown = value.rounded(.toNearestOrEven)
        if shown >= critical { return TemperatureZone.critical.barColor }
        if shown >= warning { return TemperatureZone.warning.barColor }
        return TemperatureZone.normal.barColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(height, geo.size.width * fraction(value)))
                    .opacity(value.isFinite ? 1 : 0)
                if let marker, marker.isFinite {
                    Rectangle()
                        .fill(markerColor.opacity(0.8))
                        .frame(width: 2, height: height + 4)
                        .offset(x: max(0, min(geo.size.width - 2, geo.size.width * fraction(marker) - 1)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 4)
        // No implicit animation here: with dozens of bars on screen it made every poll render
        // several frames and kept the app at ~5% CPU while the window was open.
    }
}

extension LevelBar {
    /// Temperature bar: 0...110 C, warning and critical from the alert settings.
    static func temperature(_ celsius: Double?, alerts: AlertSettings, sessionMax: Double? = nil,
                            height: CGFloat = 8) -> LevelBar {
        LevelBar(value: celsius ?? .nan, range: Theme.temperatureBarRange,
                 warning: alerts.warningTempC, critical: alerts.criticalTempC,
                 marker: sessionMax, height: height)
    }

    /// Fan bar: `[min, max]` RPM, warning at 75% and critical at 90% of the maximum.
    static func fan(actual: Double?, info: FanLimitsLike, target: Double? = nil, height: CGFloat = 8) -> LevelBar {
        LevelBar(value: actual ?? .nan, range: info.minRPM...max(info.maxRPM, info.minRPM + 1),
                 warning: 0.75 * info.maxRPM, critical: 0.9 * info.maxRPM,
                 marker: target, markerColor: Color.accentColor, height: height)
    }
}

/// The two numbers a fan bar needs; `FanInfo` and `FanReading` both provide them.
protocol FanLimitsLike {
    var minRPM: Double { get }
    var maxRPM: Double { get }
}
extension FanInfo: FanLimitsLike {}
extension FanReading: FanLimitsLike {}

/// A subtle rounded card used by the main window sections.
struct SectionHeader: View {
    var symbol: String
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
    }
}

/// Round status light for the diagnostics rows.
struct StatusLight: View {
    var status: LightStatus

    var body: some View {
        Circle()
            .fill(status.color.gradient)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
            .frame(width: 14, height: 14)
            .accessibilityLabel(status.accessibilityLabel)
    }
}

enum LightStatus {
    case good, problem, notApplicable

    var color: Color {
        switch self {
        case .good: return Color(nsColor: .systemGreen)
        case .problem: return Color(nsColor: .systemYellow)
        case .notApplicable: return Color(nsColor: .systemGray)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .good: return "OK"
        case .problem: return "Needs attention"
        case .notApplicable: return "Not applicable"
        }
    }
}
