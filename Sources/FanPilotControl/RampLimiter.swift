import Foundation

/// Walks a fan speed to a goal in equal one-second steps and lands on the goal exactly
/// (docs/SPEC.md 5.3 step 4).
///
/// Integer steps biased by one RPM, without a final correction, would overshoot or stop short.
/// Instead every ramp is a straight line from the starting speed to the goal split into `round(T)`
/// steps; each step closes `1 / stepsLeft` of the remaining distance, which is the same as
/// `start + (goal - start) * k / n`. The last step assigns the goal itself, never an accumulated
/// value, and every intermediate value is clamped between start and goal so rounding can never
/// overshoot.
///
/// Time is injected. `update` may be called at any cadence (1 s, 2 s sensor ticks, or late after
/// a stall): all steps that have come due since the last call are applied at once.
public struct RampLimiter: Equatable, Sendable {
    /// Seconds per step.
    public static let stepSeconds: TimeInterval = 1

    /// Goals closer than this (in RPM) are the same goal. Callers pass whole RPM, so this only
    /// absorbs floating-point noise.
    public static let goalTolerance: Double = 0.5

    /// Current value, nil until the first `update` or `reset`.
    public private(set) var current: Double?
    /// Where the current ramp is heading (or stopped).
    public private(set) var goal: Double?
    /// When the current value was (or will be) final: the scheduled end of the ramp, or the time of
    /// an immediate set. Meaningful while `isRamping` is false.
    public private(set) var settledAt: TimeInterval?

    private var start: Double = 0
    private var startTime: TimeInterval = 0
    private var totalSteps: Int = 0
    private var stepsDone: Int = 0

    public init() {}

    public var isRamping: Bool { totalSteps > stepsDone }

    /// Forgets everything.
    public mutating func clear() {
        self = RampLimiter()
    }

    /// Sets the current value without ramping (for example the speed a fan has when we take it
    /// over). The goal becomes `value` as well.
    public mutating func reset(to value: Double, now: TimeInterval) {
        current = value
        goal = value
        settledAt = now
        totalSteps = 0
        stepsDone = 0
    }

    /// Moves towards `newGoal` and returns the value to apply at `now`.
    ///
    /// - Parameters:
    ///   - upSeconds: ramp duration when the goal is above the current value.
    ///   - downSeconds: ramp duration when it is below.
    ///   - snapUp: when true a goal above the current value is reached at once (emergency
    ///     bypass). Falling is never bypassed: dropping a fan abruptly cools nothing.
    @discardableResult
    public mutating func update(goal newGoal: Double, upSeconds: Double, downSeconds: Double,
                                now: TimeInterval, snapUp: Bool = false) -> Double {
        guard newGoal.isFinite else { return current ?? 0 }
        guard current != nil else {
            reset(to: newGoal, now: now)
            return newGoal
        }

        advance(to: now)
        let value = current ?? newGoal

        let isNewGoal = goal.map { abs(newGoal - $0) >= Self.goalTolerance } ?? true
        if isNewGoal {
            goal = newGoal
            if abs(newGoal - value) < Self.goalTolerance || (snapUp && newGoal > value) {
                finish(at: newGoal, now: now)
            } else {
                // Restart from wherever we are now (never from the old start).
                let seconds = newGoal > value ? upSeconds : downSeconds
                start = value
                startTime = now
                stepsDone = 0
                totalSteps = Self.stepCount(forSeconds: seconds)
                settledAt = now + Double(totalSteps) * Self.stepSeconds
            }
        } else if snapUp, let goal, goal > value {
            finish(at: goal, now: now)
        }
        return current ?? newGoal
    }

    // MARK: Internals

    private mutating func finish(at value: Double, now: TimeInterval) {
        current = value
        goal = value
        totalSteps = 0
        stepsDone = 0
        settledAt = now
    }

    /// Applies every whole step that has come due by `now`.
    private mutating func advance(to now: TimeInterval) {
        guard isRamping, let goal else { return }
        let elapsed = (now - startTime) / Self.stepSeconds
        guard elapsed.isFinite else { return }
        // The epsilon keeps a step due when `now` is, say, 2.9999999999 s after a 1 s grid.
        let due = Int(Swift.min(Double(totalSteps), (elapsed + 1e-9).rounded(.down)))
        guard due > stepsDone else { return }
        stepsDone = due
        if stepsDone >= totalSteps {
            current = goal                      // the exact goal, not an accumulated value
        } else {
            let fraction = Double(stepsDone) / Double(totalSteps)
            let value = start + (goal - start) * fraction
            current = Swift.min(Swift.max(value, Swift.min(start, goal)), Swift.max(start, goal))
        }
    }

    private static func stepCount(forSeconds seconds: Double) -> Int {
        let safe = seconds.isFinite ? seconds : 1
        return Int(Swift.min(Swift.max(safe.rounded(), 1), 3600))
    }
}
