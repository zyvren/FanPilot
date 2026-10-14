import Foundation
import FanPilotKit

/// Result of one curve evaluation.
public struct CurveOutput: Equatable, Sendable {
    /// Percent to demand (0...100) after smoothing and fall hysteresis; nil until a temperature
    /// has ever been seen.
    public var percent: Double?
    /// What the curve says for the smoothed temperature, before the fall hysteresis.
    public var rawPercent: Double?
    public var smoothedTempC: Double?
    /// True while a falling output is being held up by the hysteresis.
    public var isHolding: Bool

    public init(percent: Double? = nil, rawPercent: Double? = nil, smoothedTempC: Double? = nil,
                isHolding: Bool = false) {
        self.percent = percent
        self.rawPercent = rawPercent
        self.smoothedTempC = smoothedTempC
        self.isHolding = isHolding
    }
}

/// Temperature curve (docs/SPEC.md 5.4): linear interpolation between points, flat outside them.
///
/// The input temperature is smoothed with an exponential moving average, one step per new sensor
/// sample. The output rises immediately but falls only once the smoothed temperature is
/// `fallHysteresisC` below the lowest temperature at which the curve reaches the current level.
public struct CurveEngine: Equatable, Sendable {
    public private(set) var smoothedTempC: Double?
    public private(set) var heldPercent: Double?
    private var source: SensorSelector?
    private var lastSampleAt: TimeInterval?

    public init() {}

    public mutating func reset() {
        self = CurveEngine()
    }

    public mutating func evaluate(settings rawSettings: CurveSettings, temps: TemperatureInputs) -> CurveOutput {
        let settings = rawSettings.normalized()
        if source != settings.source {
            reset()                                 // another sensor: old smoothing is meaningless
            source = settings.source
        }

        if let temp = temps.value(for: settings.source), lastSampleAt != temps.sampledAt {
            lastSampleAt = temps.sampledAt
            if let previous = smoothedTempC {
                smoothedTempC = previous + settings.emaAlpha * (temp - previous)
            } else {
                smoothedTempC = temp
            }
        }
        // No temperature yet, or the sensor went dark: hold what we had (nil if nothing).
        guard let smoothed = smoothedTempC else { return CurveOutput() }

        let points = settings.sortedPoints
        let raw = Self.percent(at: smoothed, sortedPoints: points)
        var holding = false
        if let held = heldPercent, raw < held {
            let fallLine = Self.lowestTemperature(reaching: held, sortedPoints: points) - settings.fallHysteresisC
            if smoothed < fallLine {
                heldPercent = raw
            } else {
                holding = true
            }
        } else {
            heldPercent = raw                       // rising, equal, or first sample
        }
        return CurveOutput(percent: heldPercent, rawPercent: raw, smoothedTempC: smoothed, isHolding: holding)
    }

    // MARK: Pure curve math

    /// Interpolated percent at `tempC`. `points` need not be sorted. Flat below the first and
    /// above the last point; at a duplicated temperature the higher point wins.
    public static func percent(at tempC: Double, points: [CurvePoint]) -> Double {
        percent(at: tempC, sortedPoints: CurveSettings(points: points).sortedPoints)
    }

    static func percent(at tempC: Double, sortedPoints points: [CurvePoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if tempC <= first.tempC { return first.percent }
        if tempC >= last.tempC { return last.percent }
        for i in 1..<points.count where tempC <= points[i].tempC {
            let a = points[i - 1], b = points[i]
            let width = b.tempC - a.tempC
            guard width > 0 else { return b.percent }
            return a.percent + (b.percent - a.percent) * (tempC - a.tempC) / width
        }
        return last.percent
    }

    /// Lowest temperature at which the curve reaches `percent` (the knee where a level begins).
    /// Below the first point the curve is flat, so a level at or under the first point's percent
    /// begins at that point.
    static func lowestTemperature(reaching percent: Double, sortedPoints points: [CurvePoint]) -> Double {
        guard let first = points.first else { return 0 }
        if percent <= first.percent { return first.tempC }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if a.percent < percent, b.percent >= percent {
                return a.tempC + (percent - a.percent) / (b.percent - a.percent) * (b.tempC - a.tempC)
            }
        }
        return points.last?.tempC ?? first.tempC
    }
}
