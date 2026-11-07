import Foundation
import FanPilotKit

/// Target mode: a PI controller that finds the least fan speed holding the hot set (hottest CPU,
/// GPU or SoC die sensor) at the target temperature.
///
/// The proportional part reacts at once to a temperature above the target; the integral part
/// slowly settles on the speed the current load needs, then holds it. Below the target both parts
/// drain to 0%, which the follower treats as "no demand" and hands the fans back to the system.
/// The integral only advances on a new sensor sample (like the curve smoothing) and stops growing
/// while the output is saturated, so a long stay at 0% or 100% does not wind it up.
public struct TargetEngine: Equatable, Sendable {
    /// Percent of the fan range per degree above the target.
    public static let proportionalGain: Double = 8
    /// Percent per degree-second above the target.
    public static let integralGain: Double = 0.3
    /// A longer gap between samples (sleep, a stalled poll) counts as this many seconds.
    public static let maxStepSeconds: TimeInterval = 5
    /// Moving-average factor on the input (as the curve's default): the hottest sensor jitters by
    /// 1-2 C between reads, which the proportional gain would otherwise turn into fan hunting.
    public static let emaAlpha: Double = 0.3

    public private(set) var integral: Double = 0
    public private(set) var percent: Double?
    public private(set) var smoothedTempC: Double?
    private var lastSampleAt: TimeInterval?

    public init() {}

    public mutating func reset() {
        self = TargetEngine()
    }

    /// Percent to demand (0...100), or nil until a temperature has been seen. With no readable
    /// temperature the last output is held; `FanController` releases the fans after its blind timeout.
    public mutating func evaluate(targetC: Double, temps: TemperatureInputs) -> Double? {
        guard let temp = temps.emergencyTemperature, lastSampleAt != temps.sampledAt else { return percent }
        let dt = lastSampleAt.map { Swift.min(Swift.max(temps.sampledAt - $0, 0), Self.maxStepSeconds) } ?? 0
        lastSampleAt = temps.sampledAt
        let smoothed = smoothedTempC.map { $0 + Self.emaAlpha * (temp - $0) } ?? temp
        smoothedTempC = smoothed

        let error = smoothed - targetC
        let p = Self.proportionalGain * error
        // Anti-windup: no more integral while the output is already pinned at 100% and still too hot.
        // Below the target it always drains (clamped at 0), so the fans come back down.
        if !(p + integral >= 100 && error > 0) {
            integral = Swift.min(Swift.max(integral + Self.integralGain * error * dt, 0), 100)
        }

        let out = Swift.min(Swift.max(p + integral, 0), 100)
        percent = out
        return out
    }
}
