import Foundation
import FanPilotKit

/// Slider edits for manual mode, including fan linking (docs/SPEC.md 5.2).
///
/// With `linkFans` on, moving one fan's slider moves every other fan to the same normalized
/// position of its own `[min, max]` range (1350-5349 and 1350-5777 stay proportional). The moved
/// value is stored in both units so toggling RPM/% in the UI never loses the setting. Modes and
/// units of the fans are untouched.
public extension FanPolicy {
    /// The speed this fan's manual setting asks for: the stored RPM or percent according to
    /// `manualUnit`, validated against `limits`. An unset RPM (0) and percent 0 both mean the fan
    /// minimum: manual never stops a fan, only Auto can.
    func manualTargetRPM(limits: FanLimits) -> Double {
        switch manualUnit {
        case .rpm:
            return manualRPM <= 0
                ? RPMMath.validated(limits.min, limits: limits)
                : RPMMath.validated(Double(manualRPM), limits: limits)
        case .percent:
            return RPMMath.rpm(forPercent: manualPercent, limits: limits)
        }
    }
}

public extension Policy {
    /// Call when the user turns "link fans" on (after setting `linkFans`): snaps every other fan's
    /// manual setting to the normalized position of `leader` (default: the lowest-numbered fan),
    /// which is also what the controller does with stale values. Does nothing while `linkFans`
    /// is off.
    mutating func relinkManualFans(leader: Int? = nil, fans: [FanInfo]) {
        guard linkFans else { return }
        let usable = fans.filter { FanLimits($0).isUsable }.sorted { $0.index < $1.index }
        guard let source = usable.first(where: { $0.index == leader }) ?? usable.first else { return }
        let current = fanPolicy(at: source.index)
        if current.manualUnit == .percent {
            applyManualPercent(current.manualPercent, forFan: source.index, fans: usable)
        } else {
            applyManualRPM(current.manualTargetRPM(limits: FanLimits(source)), forFan: source.index, fans: usable)
        }
    }

    /// The user dragged the slider of `fan` to `rpm`.
    mutating func applyManualRPM(_ rpm: Double, forFan fan: Int, fans: [FanInfo]) {
        guard let moved = fans.first(where: { $0.index == fan }) else { return }
        let limits = FanLimits(moved)
        guard limits.isUsable else { return }
        applyManual(rpm: RPMMath.validated(rpm, limits: limits), percent: nil, movedFan: moved, fans: fans)
    }

    /// The user entered `percent` (0...100 of the range) for `fan`. 0 means the fan minimum.
    mutating func applyManualPercent(_ percent: Double, forFan fan: Int, fans: [FanInfo]) {
        guard let moved = fans.first(where: { $0.index == fan }) else { return }
        let limits = FanLimits(moved)
        guard limits.isUsable else { return }
        let clamped = percent.isNaN ? 0 : Swift.min(Swift.max(percent, 0), 100)
        applyManual(rpm: RPMMath.rpm(forPercent: clamped, limits: limits), percent: clamped,
                    movedFan: moved, fans: fans)
    }

    private mutating func applyManual(rpm: Double, percent: Double?, movedFan: FanInfo, fans: [FanInfo]) {
        let source = FanLimits(movedFan)
        for info in fans where info.index >= 0 && info.index <= Constants.maxFanIndex {
            let limits = FanLimits(info)
            guard limits.isUsable else { continue }
            let value: Double
            let valuePercent: Double
            if info.index == movedFan.index {
                value = rpm
                valuePercent = percent ?? RPMMath.percent(forRPM: rpm, limits: limits)
            } else if self.linkFans {
                value = RPMMath.linkedRPM(rpm, from: source, to: limits)
                valuePercent = RPMMath.percent(forRPM: value, limits: limits)
            } else {
                continue
            }
            var fanPolicy = self.fanPolicy(at: info.index)
            fanPolicy.manualRPM = Int(value)
            fanPolicy.manualPercent = valuePercent
            setFanPolicy(fanPolicy, at: info.index)
        }
    }
}
