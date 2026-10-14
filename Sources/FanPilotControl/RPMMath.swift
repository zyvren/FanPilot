import Foundation

/// Percent <-> RPM conversions, clamping and fan linking (docs/SPEC.md 5.2).
///
/// The app and the helper both clamp to the live `[Mn, Mx]`; this is the app-side half, so that
/// the UI and the wire never carry a value the helper would have to correct.
public enum RPMMath {
    /// Whole RPM, halves away from zero (fan targets are sent as whole numbers).
    public static func rounded(_ rpm: Double) -> Double {
        rpm.rounded(.toNearestOrAwayFromZero)
    }

    /// Clamps into `[min, max]`. NaN maps to the minimum: a fan is never sent somewhere unknown.
    public static func clamp(_ rpm: Double, to limits: FanLimits) -> Double {
        guard !rpm.isNaN else { return limits.min }
        return Swift.min(Swift.max(rpm, limits.min), limits.max)
    }

    /// `clamp(round(rpm))`: the value that actually goes on the wire.
    public static func validated(_ rpm: Double, limits: FanLimits) -> Double {
        clamp(rounded(rpm), to: limits)
    }

    /// Position of `rpm` inside the range, 0 at the minimum and 1 at the maximum (clamped).
    /// A degenerate range yields 0.
    public static func fraction(forRPM rpm: Double, limits: FanLimits) -> Double {
        guard limits.span > 0 else { return 0 }
        return (clamp(rpm, to: limits) - limits.min) / limits.span
    }

    /// 0...100 percent of the range for `rpm`.
    public static func percent(forRPM rpm: Double, limits: FanLimits) -> Double {
        fraction(forRPM: rpm, limits: limits) * 100
    }

    /// `round(min + f * (max - min))` with `f` clamped to 0...1. Fraction 0 is the minimum, never
    /// "off": only Auto can stop a fan.
    public static func rpm(forFraction fraction: Double, limits: FanLimits) -> Double {
        let f = fraction.isNaN ? 0 : Swift.min(Swift.max(fraction, 0), 1)
        return validated(limits.min + f * limits.span, limits: limits)
    }

    /// `rpm(forFraction:)` for a 0...100 percentage.
    public static func rpm(forPercent percent: Double, limits: FanLimits) -> Double {
        rpm(forFraction: percent / 100, limits: limits)
    }

    /// Link mapping: the speed on `target` that sits at the same normalized position as `rpm` does
    /// on `source`. `other = min_j + (rpm - min_i) / (max_i - min_i) * (max_j - min_j)`.
    public static func linkedRPM(_ value: Double, from source: FanLimits, to target: FanLimits) -> Double {
        rpm(forFraction: fraction(forRPM: value, limits: source), limits: target)
    }
}
