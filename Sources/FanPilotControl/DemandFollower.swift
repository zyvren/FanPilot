import Foundation
import FanPilotKit

/// Turns a fan-speed *demand* (a percent, or none) into commands: take the fan over, ramp it,
/// and give it back to the system when nobody wants it any more.
///
/// Shared by Boost and Curve. Lifecycle (docs/SPEC.md 5.3 step 3):
/// 1. `released`: the fan belongs to the system. The first demand takes it over, starting the ramp
///    at the speed it currently has.
/// 2. `following`: the goal is `min + pct * (max - min)`. With no demand the goal is the minimum.
/// 3. Once the ramp has reached the minimum AND `releaseDelaySeconds` have passed since the
///    demand disappeared (and since the ramp finished), the fan is released: `.auto`.
public struct DemandFollower: Equatable, Sendable {
    public struct Parameters: Equatable, Sendable {
        public var rampUpSeconds: Double
        public var rampDownSeconds: Double
        public var releaseDelaySeconds: Double

        public init(rampUpSeconds: Double = 6, rampDownSeconds: Double = 20, releaseDelaySeconds: Double = 10) {
            self.rampUpSeconds = rampUpSeconds
            self.rampDownSeconds = rampDownSeconds
            self.releaseDelaySeconds = releaseDelaySeconds
        }

        public init(_ boost: BoostSettings) {
            self.init(rampUpSeconds: boost.rampUpSeconds, rampDownSeconds: boost.rampDownSeconds,
                      releaseDelaySeconds: boost.releaseDelaySeconds)
        }
    }

    public enum Phase: Equatable, Sendable {
        case released
        case following
    }

    public private(set) var phase: Phase = .released
    /// Speed the ramp is heading to while following.
    public private(set) var goalRPM: Double?
    private var limiter = RampLimiter()
    private var noDemandSince: TimeInterval?

    public init() {}

    public var isFollowing: Bool { phase == .following }
    public var isRamping: Bool { phase == .following && limiter.isRamping }

    /// Gives up ownership without any ramp (mode change, lost sensors, wake from sleep).
    public mutating func reset() {
        self = DemandFollower()
    }

    /// - Parameters:
    ///   - demandPercent: 0...100 of the fan's range, or nil when nothing wants the fan faster.
    ///     A demand of 0 holds the fan at its minimum; only nil can lead back to auto.
    ///   - startRPM: speed to start the ramp from when taking the fan over.
    ///   - snapUp: emergency bypass, a higher goal is reached immediately.
    public mutating func update(demandPercent: Double?, limits: FanLimits, startRPM: Double,
                                parameters: Parameters, now: TimeInterval, snapUp: Bool = false) -> FanCommand {
        guard limits.isUsable else {
            reset()
            return .auto
        }

        if phase == .released {
            guard demandPercent != nil else { return .auto }
            limiter.reset(to: RPMMath.clamp(startRPM, to: limits), now: now)
            phase = .following
            noDemandSince = nil
        }

        let goal: Double
        if let demandPercent {
            goal = RPMMath.rpm(forPercent: demandPercent, limits: limits)
            noDemandSince = nil
        } else {
            goal = limits.min
            if noDemandSince == nil { noDemandSince = now }
        }
        goalRPM = goal

        let current = limiter.update(goal: goal, upSeconds: parameters.rampUpSeconds,
                                     downSeconds: parameters.rampDownSeconds, now: now, snapUp: snapUp)

        if demandPercent == nil, !limiter.isRamping, current <= limits.min {
            let idleSince = Swift.max(noDemandSince ?? now, limiter.settledAt ?? now)
            if now - idleSince >= parameters.releaseDelaySeconds {
                reset()
                return .auto
            }
        }
        return .rpm(RPMMath.validated(current, limits: limits))
    }
}
