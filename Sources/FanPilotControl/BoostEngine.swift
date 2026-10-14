import Foundation
import FanPilotKit

/// Result of one rule evaluation.
public struct BoostEvaluation: Equatable, Sendable {
    public struct Goal: Equatable, Sendable {
        /// Effective fan percent (0...100) of the winning rule.
        public var percent: Double
        public var ruleID: UUID

        public init(percent: Double, ruleID: UUID) {
            self.percent = percent
            self.ruleID = ruleID
        }
    }

    /// Winning goal per fan index. A fan without an entry has no active rule.
    public var goals: [Int: Goal]
    /// Rules that are currently active, in rule order.
    public var activeRuleIDs: [UUID]

    public init(goals: [Int: Goal] = [:], activeRuleIDs: [UUID] = []) {
        self.goals = goals
        self.activeRuleIDs = activeRuleIDs
    }
}

/// Auto Boost rule engine (docs/SPEC.md 5.3).
///
/// Per rule: fires when the sensor is strictly above `limitC` (compared as floating point,
/// not truncated to integers). Once fired a rule stays active while `temp > limitC - hysteresisC`
/// and for at least `minHoldSeconds` since it fired, so a temperature hovering around a threshold
/// does not make the fans pump.
///
/// Per fan: the active rule with the highest percent wins; on equal percent the earlier rule in
/// the array wins. With `usePercent == false` ("Auto Max") every active rule means 100%.
///
/// Only the rule set of the current power source is evaluated. Switching sources does NOT clear
/// anything fan-related (resetting every rule would restart all ramps): the new set is simply
/// evaluated against the same temperatures and the ramp follower carries on from the current
/// speed. Activation state of rules that are not in the evaluated set is dropped, so a rule
/// that comes back later starts from a clean "not fired" state.
///
/// The engine decides *what* to demand; ramping and release to auto are the `DemandFollower`'s job.
public struct BoostEngine: Equatable, Sendable {
    /// Rule id -> time it fired.
    private var activeSince: [UUID: TimeInterval] = [:]
    /// Rule id -> time its sensor stopped reporting while other sensors still did.
    private var unreadableSince: [UUID: TimeInterval] = [:]
    /// A rule bound to one sensor releases after that sensor has been silent this long. With every
    /// sensor dark the state is frozen instead: `FanController` handles total blindness itself.
    public static let sensorSilenceLimitSeconds: TimeInterval = 10

    public init() {}

    public func isActive(_ ruleID: UUID) -> Bool { activeSince[ruleID] != nil }

    public mutating func reset() {
        activeSince.removeAll()
        unreadableSince.removeAll()
    }

    /// Evaluates the rules and returns the winning goal for each fan in `fanIndices`.
    public mutating func evaluate(settings rawSettings: BoostSettings, powerSource: PowerSource,
                                  temps: TemperatureInputs, fanIndices: [Int],
                                  now: TimeInterval) -> BoostEvaluation {
        let settings = rawSettings.normalized()
        let rules = settings.rules(for: powerSource).filter(\.enabled)

        var next: [UUID: TimeInterval] = [:]
        var silent: [UUID: TimeInterval] = [:]
        for rule in rules {
            let since = activeSince[rule.id]
            guard let temp = temps.value(for: rule.sensor) else {
                // Sensor unreadable. If everything is dark keep the state we had: a rule that was
                // holding the fans up keeps doing so (FanController releases to auto after its blind
                // timeout), and one that was quiet stays quiet. If only THIS sensor went missing
                // (a HID dropout, an invalid reading) its rule must not hold the fans up forever
                // on a reading nobody can see any more: release it after a short silence.
                if let since {
                    if temps.hasData {
                        let silentSince = unreadableSince[rule.id] ?? now
                        silent[rule.id] = silentSince
                        if now - silentSince < Self.sensorSilenceLimitSeconds { next[rule.id] = since }
                    } else {
                        next[rule.id] = since
                        if let earlier = unreadableSince[rule.id] { silent[rule.id] = earlier }
                    }
                }
                continue
            }
            if let since {
                let aboveReleaseLine = temp > rule.limitC - settings.hysteresisC
                let holding = now - since < settings.minHoldSeconds
                if aboveReleaseLine || holding { next[rule.id] = since }
            } else if temp > rule.limitC {
                next[rule.id] = now
            }
        }
        activeSince = next
        unreadableSince = silent

        var goals: [Int: BoostEvaluation.Goal] = [:]
        for fan in fanIndices {
            var best: BoostEvaluation.Goal?
            for rule in rules where next[rule.id] != nil {
                guard rule.fanIndex == nil || rule.fanIndex == fan else { continue }
                let percent = settings.usePercent ? Double(rule.percent) : 100
                if best == nil || percent > best!.percent {    // strict: ties keep the earlier rule
                    best = BoostEvaluation.Goal(percent: percent, ruleID: rule.id)
                }
            }
            if let best { goals[fan] = best }
        }
        return BoostEvaluation(goals: goals, activeRuleIDs: rules.filter { next[$0.id] != nil }.map(\.id))
    }
}
