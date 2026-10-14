import Foundation
import FanPilotKit

// Small value types shared by the control engines. Everything in this module is pure and
// deterministic: no IO, no clocks. Callers inject `now` as monotonic seconds (any epoch, for
// example `ProcessInfo.processInfo.systemUptime`).

/// What the app wants a fan to do right now. Maps onto the wire ops `auto` and `set`.
public enum FanCommand: Equatable, Sendable {
    /// Hand the fan back to the system.
    case auto
    /// Hold the fan at this speed. Always a whole number of RPM, inside the fan's `[min, max]`.
    case rpm(Double)

    public var rpm: Double? {
        if case .rpm(let value) = self { return value }
        return nil
    }

    public var isAuto: Bool { self == .auto }
}

/// The speed range of one fan (`F<n>Mn` ... `F<n>Mx`), read live from the SMC.
public struct FanLimits: Equatable, Hashable, Sendable {
    public var min: Double
    public var max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    public init(_ info: FanInfo) {
        self.init(min: info.minRPM, max: info.maxRPM)
    }

    public var span: Double { max - min }

    /// False for a range we cannot map percentages onto (unreadable limits, `max <= min`). Such a
    /// fan is never controlled: it stays in auto.
    public var isUsable: Bool {
        min.isFinite && max.isFinite && min >= 0 && max > min
    }
}

/// One fan as seen by the controller on a given tick.
public struct FanInput: Equatable, Sendable {
    public var index: Int
    public var limits: FanLimits
    /// Current speed (`F<n>Ac`) if known. Used to start a ramp where the fan really is when we
    /// take it over, instead of dropping it to the minimum first.
    public var actualRPM: Double?
    /// False when no backend can drive this fan (monitor-only mode).
    public var canControl: Bool

    public init(index: Int, limits: FanLimits, actualRPM: Double? = nil, canControl: Bool = true) {
        self.index = index
        self.limits = limits
        self.actualRPM = actualRPM
        self.canControl = canControl
    }

    public init(info: FanInfo, actualRPM: Double? = nil) {
        self.init(index: info.index, limits: FanLimits(info), actualRPM: actualRPM,
                  canControl: info.backend.canControl)
    }

    public init(info: FanInfo, reading: FanReading?) {
        self.init(info: info, actualRPM: reading?.actualRPM)
    }
}
