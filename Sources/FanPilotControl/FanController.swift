import Foundation
import FanPilotKit

/// What to do with one fan this tick.
public struct FanDirective: Equatable, Sendable, Identifiable {
    public var fanIndex: Int
    public var command: FanCommand
    /// The command differs from the last one handed out (a different RPM by at least
    /// `Configuration.minChangeRPM`, or auto <-> rpm). Always true after `markNeedsResend`.
    public var changed: Bool
    /// Send this to the helper now: `changed`, or a speed command that has not been repeated for
    /// `refreshIntervalSeconds` (keeps the helper's lease alive and re-asserts after a lost send).
    public var shouldSend: Bool
    /// The mode that produced the command.
    public var mode: ControlMode
    /// Where the speed is heading: the ramp goal in Boost/Curve, the fixed target in Manual/Max.
    public var goalRPM: Double?
    public var isRamping: Bool

    public var id: Int { fanIndex }
}

/// Everything one `FanController.update` produces.
public struct ControllerOutput: Equatable, Sendable {
    /// One entry per input fan, ordered by fan index.
    public var directives: [FanDirective]
    /// The hot set is within `emergencyMarginC` of the failsafe temperature: ramps are bypassed.
    public var emergency: Bool
    /// No temperature has been readable for `blindTimeoutSeconds`: Boost and Curve fans were
    /// released to auto.
    public var sensorsLost: Bool
    public var activeBoostRuleIDs: [UUID]
    /// Percent the curve currently demands, if any fan uses the curve.
    public var curvePercent: Double?

    public func directive(forFan index: Int) -> FanDirective? {
        directives.first { $0.fanIndex == index }
    }

    /// The directives the caller must act on now.
    public var commandsToSend: [FanDirective] { directives.filter(\.shouldSend) }
}

/// Orchestrates fan control from the user's policy (docs/SPEC.md 5): pure and deterministic. The
/// caller supplies the policy, the fans, the latest temperatures, the power source and the time;
/// it gets back what each fan should do. Nothing here touches the helper or the clock.
///
/// Modes per fan:
/// - auto: `.auto`.
/// - manual: the stored RPM or percent (percent 0 = the fan minimum). With `linkFans`, fans in
///   manual mode follow the lowest-index manual fan by normalized position, so a stale or
///   hand-edited policy cannot drive linked fans apart. See `Policy.applyManualRPM` for the edit
///   side.
/// - max: the fan maximum, immediately.
/// - boost: `BoostEngine` rules, then ramp and release (`DemandFollower`).
/// - curve: `CurveEngine`, then the same ramp and release. A curve value of exactly 0% means "no
///   demand" and is released to auto after the usual delay; the ramp times and release delay
///   come from `policy.boost`.
///
/// Emergency: when the hot set is within `emergencyMarginC` of the failsafe temperature, ramp-ups
/// in Boost/Curve are bypassed. Auto, Manual and Max are not overridden here; the root helper's own
/// failsafe (SPEC 4.5 #6) is the last line of defense.
public struct FanController: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// The helper's failsafe temperature; the emergency threshold is this minus the margin.
        public var failsafeTempC: Double
        public var emergencyMarginC: Double
        /// A speed command is repeated at least this often (SPEC 5.1: 5 s).
        public var refreshIntervalSeconds: TimeInterval
        /// With no readable temperature for this long, Boost/Curve fans go back to auto (the
        /// helper does the same after 10 s of blindness).
        public var blindTimeoutSeconds: TimeInterval
        /// Smallest speed difference that counts as a change (SPEC 5.1: 1 RPM).
        public var minChangeRPM: Double

        public init(failsafeTempC: Double = Constants.defaultFailsafeTempC,
                    emergencyMarginC: Double = 5,
                    refreshIntervalSeconds: TimeInterval = Constants.heartbeatIntervalSeconds,
                    blindTimeoutSeconds: TimeInterval = 10,
                    minChangeRPM: Double = 1) {
            self.failsafeTempC = failsafeTempC
            self.emergencyMarginC = emergencyMarginC
            self.refreshIntervalSeconds = refreshIntervalSeconds
            self.blindTimeoutSeconds = blindTimeoutSeconds
            self.minChangeRPM = minChangeRPM
        }

        public var emergencyThresholdC: Double { failsafeTempC - emergencyMarginC }
    }

    private struct FanState: Sendable {
        var mode: ControlMode?
        var follower = DemandFollower()
        var lastSent: FanCommand = .auto
        var lastSentAt: TimeInterval?
        var forceResend = false
    }

    public var configuration: Configuration
    private var boost = BoostEngine()
    private var curve = CurveEngine()
    private var fanStates: [Int: FanState] = [:]
    private var blindSince: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Forgets all state and assumes every fan is in auto. Call after sleep/wake (the app has sent
    /// `auto all`), after reconnecting to a restarted helper, or when the fan set changes.
    public mutating func reset() {
        boost.reset()
        curve.reset()
        fanStates.removeAll()
        blindSince = nil
    }

    /// The last command may not have reached the helper (send failed, reconnect, helper reports
    /// the fan is no longer owned): the next `update` flags the fan as changed again.
    /// `fan == nil` marks every fan.
    public mutating func markNeedsResend(fan: Int? = nil) {
        for index in fanStates.keys where fan == nil || fan == index {
            fanStates[index]?.forceResend = true
        }
    }

    // MARK: Update

    public mutating func update(policy: Policy, fans fanInputs: [FanInput], temps: TemperatureInputs,
                                powerSource: PowerSource, now: TimeInterval) -> ControllerOutput {
        let parameters = DemandFollower.Parameters(policy.boost.normalized())
        let inputs = Dictionary(fanInputs.map { ($0.index, $0) }, uniquingKeysWith: { _, last in last })
        let order = inputs.keys.sorted()
        fanStates = fanStates.filter { inputs[$0.key] != nil }

        let emergency = temps.emergencyTemperature.map { $0 >= configuration.emergencyThresholdC } ?? false

        if temps.hasData {
            blindSince = nil
        } else if blindSince == nil {
            blindSince = now
        }
        let sensorsLost = blindSince.map { now - $0 >= configuration.blindTimeoutSeconds } ?? false

        // Pass 1: which fans we control and in which mode; per-fan state on mode changes.
        var modes: [Int: ControlMode] = [:]
        for index in order {
            guard let fan = inputs[index], fan.canControl, fan.limits.isUsable else {
                fanStates[index] = nil
                continue
            }
            let mode = policy.fanPolicy(at: index).mode
            modes[index] = mode
            var state = fanStates[index] ?? FanState()
            if state.mode != mode {
                // Boost <-> Curve keeps the follower so the fan keeps its speed and ramps on;
                // anything else starts fresh from where the fan is.
                let staysDemandDriven = Self.isDemandDriven(state.mode) && Self.isDemandDriven(mode)
                if !staysDemandDriven { state.follower.reset() }
                state.mode = mode
            }
            fanStates[index] = state
        }

        let boostFans = order.filter { modes[$0] == .boost }
        let curveFans = order.filter { modes[$0] == .curve }

        var boostEvaluation = BoostEvaluation()
        if boostFans.isEmpty {
            boost.reset()
        } else {
            boostEvaluation = boost.evaluate(settings: policy.boost, powerSource: powerSource, temps: temps,
                                             fanIndices: boostFans, now: now)
        }

        var curveOutput = CurveOutput()
        if curveFans.isEmpty {
            curve.reset()
        } else {
            curveOutput = curve.evaluate(settings: policy.curve, temps: temps)
        }
        // Curve 0% = "nothing wanted": the fan eases to its minimum and is released.
        let curveDemand: Double? = (curveOutput.percent ?? 0) > 0 ? curveOutput.percent : nil

        let manualTargets = Self.manualTargets(policy: policy, inputs: inputs,
                                               manualFans: order.filter { modes[$0] == .manual })

        // Pass 2: commands.
        var directives: [FanDirective] = []
        for index in order {
            guard let fan = inputs[index] else { continue }
            guard let mode = modes[index], var state = fanStates[index] else {
                // Monitor-only or unusable limits: never touched, nothing to send.
                directives.append(FanDirective(fanIndex: index, command: .auto, changed: false, shouldSend: false,
                                               mode: policy.fanPolicy(at: index).mode, goalRPM: nil,
                                               isRamping: false))
                continue
            }

            var command = FanCommand.auto
            var goal: Double?
            switch mode {
            case .auto:
                command = .auto
            case .manual:
                let target = manualTargets[index] ?? fan.limits.min
                command = .rpm(target)
                goal = target
            case .max:
                let target = RPMMath.validated(fan.limits.max, limits: fan.limits)
                command = .rpm(target)
                goal = target
            case .boost, .curve:
                if sensorsLost {
                    state.follower.reset()
                    command = .auto
                } else {
                    let demand = mode == .boost ? boostEvaluation.goals[index]?.percent : curveDemand
                    command = state.follower.update(
                        demandPercent: demand, limits: fan.limits,
                        startRPM: Self.takeoverStartRPM(state: state, fan: fan),
                        parameters: parameters, now: now, snapUp: emergency)
                    goal = state.follower.goalRPM
                }
            }

            let (changed, shouldSend) = decide(command: command, state: &state, now: now)
            fanStates[index] = state
            directives.append(FanDirective(fanIndex: index, command: command, changed: changed,
                                           shouldSend: shouldSend, mode: mode, goalRPM: goal,
                                           isRamping: state.follower.isRamping))
        }

        return ControllerOutput(directives: directives, emergency: emergency, sensorsLost: sensorsLost,
                                activeBoostRuleIDs: boostEvaluation.activeRuleIDs,
                                curvePercent: curveFans.isEmpty ? nil : curveOutput.percent)
    }

    // MARK: Helpers

    private func decide(command: FanCommand, state: inout FanState, now: TimeInterval) -> (changed: Bool, shouldSend: Bool) {
        let changed: Bool
        if state.forceResend {
            changed = true
        } else {
            switch (state.lastSent, command) {
            case (.auto, .auto): changed = false
            case (.rpm(let old), .rpm(let new)): changed = abs(new - old) >= configuration.minChangeRPM
            default: changed = true
            }
        }
        var shouldSend = changed
        if !shouldSend, case .rpm = command, let at = state.lastSentAt,
           now - at >= configuration.refreshIntervalSeconds {
            shouldSend = true
        }
        if shouldSend {
            state.lastSent = command
            state.lastSentAt = now
            state.forceResend = false
        }
        return (changed, shouldSend)
    }

    private static func isDemandDriven(_ mode: ControlMode?) -> Bool {
        mode == .boost || mode == .curve
    }

    /// Where a ramp begins when a fan is taken over: the speed we last commanded if we already
    /// own it (manual -> boost), else the speed it has now but never below its minimum, so a fan
    /// the system is already running fast is not first dropped to the minimum.
    private static func takeoverStartRPM(state: FanState, fan: FanInput) -> Double {
        if case .rpm(let last) = state.lastSent { return last }
        if let actual = fan.actualRPM, actual.isFinite { return Swift.max(fan.limits.min, actual) }
        return fan.limits.min
    }

    /// Manual targets in whole RPM, with linking applied.
    ///
    /// Linked fans follow the lowest-index manual fan. A fan whose own stored value already sits
    /// where the link would put it (within the rounding of the two conversions) keeps its own
    /// value: otherwise dragging the right-hand slider to 3000 would come back as 2999 after the
    /// round trip through the left fan's rounded value.
    private static func manualTargets(policy: Policy, inputs: [Int: FanInput], manualFans: [Int]) -> [Int: Double] {
        var targets: [Int: Double] = [:]
        for index in manualFans {
            guard let fan = inputs[index] else { continue }
            targets[index] = policy.fanPolicy(at: index).manualTargetRPM(limits: fan.limits)
        }
        if policy.linkFans, let leader = manualFans.first, let leaderTarget = targets[leader],
           let leaderInput = inputs[leader] {
            for index in manualFans.dropFirst() {
                guard let fan = inputs[index], let own = targets[index] else { continue }
                let linked = RPMMath.linkedRPM(leaderTarget, from: leaderInput.limits, to: fan.limits)
                let tolerance = 1 + 0.5 * Swift.max(1, fan.limits.span / leaderInput.limits.span)
                targets[index] = abs(own - linked) <= tolerance ? own : linked
            }
        }
        return targets
    }
}
