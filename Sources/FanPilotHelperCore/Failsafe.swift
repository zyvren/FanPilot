import FanPilotKit
import Foundation

/// The thermal failsafe state machine (docs/SPEC.md 4.5 #6). Pure: it is fed the clock and the
/// latest hot-set reading and reports transitions; the engine acts on them.
///
///     normal --(hot >= trigger on 2 samples in a row)--> hot --(hot < trigger - 7 for 10 s)--> normal
///     normal/hot --(no readable hot-set temperature for 10 s while controlling)--> blind
///     blind --(a temperature is readable again)--> normal
///
/// Why "blind" exists: with no temperature to look at, holding a user-chosen fan speed is gambling.
/// The engine hands the fans back to the OS (which has its own sensors) and refuses new control
/// until a hot-set temperature can be read again.
public struct FailsafeMonitor: Sendable {
    public enum State: Equatable, Sendable {
        case normal
        case hot
        case blind
    }

    public enum Transition: Equatable, Sendable {
        case enteredHot(tempC: Double)
        case cleared
        case enteredBlind
        case recoveredFromBlind
    }

    /// Hysteresis below the trigger temperature that the hot set must stay under to clear.
    public static let clearMarginC: Double = 7
    /// How long the hot set must stay below the clear threshold.
    public static let clearHoldSeconds: TimeInterval = 10
    /// How long the hot set may be unreadable, while we control fans, before we give up.
    public static let blindSeconds: TimeInterval = 10
    /// Consecutive samples at or above the trigger needed to enter `hot`. A single sensor can spike
    /// for one sample (TCMb read 99.5 C once on this Mac while the CPU cores sat near 54 C) and one
    /// sample alone should not blast both fans to maximum. While a streak is pending the engine
    /// samples every second (`isConfirming`), so confirming a real overheat costs about a second.
    public static let triggerSamples = 2
    /// Hot samples closer together than this are one observation, not two: reads a few milliseconds
    /// apart (several gates inside one request, a request right after a tick) usually return the same
    /// SMC value, so they are no independent confirmation. They neither extend nor break a streak.
    public static let minConfirmSpacingSeconds: TimeInterval = 0.5
    /// A pending streak older than this is forgotten: two spikes minutes or hours apart (an idle gap
    /// with no sampling in between) are not consecutive. Twice the idle sampling period plus slack.
    public static let maxConfirmGapSeconds: TimeInterval = 11

    public let triggerC: Double
    public private(set) var state: State = .normal
    /// Latest usable hot-set temperature, if any.
    public private(set) var lastTempC: Double?

    private var coolSince: TimeInterval?
    private var blindSince: TimeInterval?
    private var hotStreak = 0
    private var lastHotAt: TimeInterval?

    /// - Parameters:
    ///   - triggerC: forced into `floorC...100` C, whatever the caller passes (a client or a damaged
    ///     config can never raise the failsafe above 100 C).
    ///   - floorC: lowest accepted trigger; 85 C normally. Only the `--failsafe-test` option of
    ///     `fanpilotd` lowers it, to provoke the failsafe on real hardware (a lower trigger is
    ///     always the safe direction).
    public init(triggerC: Double, floorC: Double = Constants.failsafeTempMinC) {
        if triggerC.isFinite {
            self.triggerC = min(max(triggerC, floorC), Constants.failsafeTempMaxC)
        } else {
            self.triggerC = Constants.defaultFailsafeTempC
        }
    }

    public var isHot: Bool { state == .hot }
    public var isBlind: Bool { state == .blind }
    public var isActive: Bool { state != .normal }

    public var clearBelowC: Double { triggerC - Self.clearMarginC }

    /// A hot sample was seen and not yet confirmed or refuted. The engine samples every second while
    /// this is true so the answer comes quickly even when no fan is held.
    public var isConfirming: Bool { state != .hot && hotStreak > 0 }

    /// The wire view (`status` reply).
    public var status: FailsafeStatus {
        switch state {
        case .normal: return .inactive
        case .hot: return FailsafeStatus(active: true, reason: "hot_sensor", tempC: lastTempC)
        case .blind: return FailsafeStatus(active: true, reason: "blind", tempC: lastTempC)
        }
    }

    /// Back to `normal` with all timers cleared (after sleep, when everything was released anyway).
    public mutating func reset() {
        state = .normal
        lastTempC = nil
        coolSince = nil
        blindSince = nil
        forgetPendingConfirmation()
    }

    /// Drops a half-built streak of hot samples (the last client left: nobody is waiting on the
    /// answer and the next sample, whenever it comes, starts afresh). Leaves `state` alone.
    public mutating func forgetPendingConfirmation() {
        hotStreak = 0
        lastHotAt = nil
    }

    /// Feeds one hot-set sample.
    /// - Parameters:
    ///   - hotMax: hottest usable hot-set temperature, nil if none could be read.
    ///   - controlling: true while the helper holds any fan.
    /// - Returns: the transition this sample caused, if any.
    public mutating func update(now: TimeInterval, hotMax: Double?, controlling: Bool) -> Transition? {
        guard let temp = hotMax else {
            coolSince = nil   // cooling cannot be judged without data
            forgetPendingConfirmation()   // nor can a streak of hot samples continue across a gap
            guard controlling || state == .hot else {
                blindSince = nil   // nothing at stake: not holding fans, not forcing them
                return nil
            }
            if blindSince == nil { blindSince = now }
            if state != .blind, now - (blindSince ?? now) >= Self.blindSeconds {
                state = .blind
                return .enteredBlind
            }
            return nil
        }

        lastTempC = temp
        blindSince = nil
        var transition: Transition?
        if state == .blind {
            state = .normal
            transition = .recoveredFromBlind
        }

        if temp >= triggerC {
            coolSince = nil
            if let last = lastHotAt, hotStreak > 0 {
                let gap = now - last
                if gap < 0 || gap > Self.maxConfirmGapSeconds {
                    hotStreak = 0   // stale (or the clock went backwards): this sample starts a new streak
                } else if gap < Self.minConfirmSpacingSeconds {
                    return transition   // the same observation read twice
                }
            }
            lastHotAt = now
            hotStreak += 1
            if state != .hot, hotStreak >= Self.triggerSamples {
                state = .hot
                return .enteredHot(tempC: temp)
            }
            return transition
        }
        forgetPendingConfirmation()

        if state == .hot {
            if temp < clearBelowC {
                if coolSince == nil { coolSince = now }
                if now - (coolSince ?? now) >= Self.clearHoldSeconds {
                    state = .normal
                    coolSince = nil
                    return .cleared
                }
            } else {
                coolSince = nil   // inside the hysteresis band: the clock restarts
            }
        }
        return transition
    }
}
