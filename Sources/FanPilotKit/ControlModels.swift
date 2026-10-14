import Foundation

// Control policy models (docs/SPEC.md 5.1, 5.3, 5.4). Pure data: the engines that interpret them
// live in FanPilotControl. Everything decodes tolerantly (missing or malformed keys take defaults).

/// What the user wants the fans to do.
public enum ControlMode: String, Codable, CaseIterable, Sendable {
    /// System control: the fans are released to macOS.
    case auto
    /// A fixed speed chosen with the slider.
    case manual
    /// Full speed.
    case max
    /// Temperature rules (Auto Boost).
    case boost
    /// Temperature curve.
    case curve

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        case .max: return "Max"
        case .boost: return "Boost"
        case .curve: return "Curve"
        }
    }

    /// True for modes where FanPilot writes a target (everything except `auto`).
    public var takesControl: Bool { self != .auto }
}

/// Which battery/AC rule set is active.
public enum PowerSource: String, Codable, CaseIterable, Sendable {
    case adapter
    case battery
}

/// Unit the manual slider is shown and stored in.
public enum ManualUnit: String, Codable, CaseIterable, Sendable {
    case rpm
    case percent
}

/// Per-fan control choice.
public struct FanPolicy: Codable, Equatable, Hashable, Sendable {
    public var mode: ControlMode
    /// Manual target in RPM; used when `manualUnit == .rpm`. 0 means "not set yet": use the fan minimum.
    public var manualRPM: Int
    /// Manual target as 0...100 percent of the fan's `[min, max]` range; used when `manualUnit == .percent`.
    public var manualPercent: Double
    public var manualUnit: ManualUnit

    public init(mode: ControlMode = .auto, manualRPM: Int = 0, manualPercent: Double = 0,
                manualUnit: ManualUnit = .rpm) {
        self.mode = mode
        self.manualRPM = manualRPM
        self.manualPercent = manualPercent
        self.manualUnit = manualUnit
    }

    private enum CodingKeys: String, CodingKey { case mode, manualRPM, manualPercent, manualUnit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: c.value(.mode, default: .auto),
                  manualRPM: c.value(.manualRPM, default: 0),
                  manualPercent: c.value(.manualPercent, default: 0),
                  manualUnit: c.value(.manualUnit, default: .rpm))
    }

    public func normalized() -> FanPolicy {
        var copy = self
        copy.manualRPM = max(0, min(copy.manualRPM, Int(Constants.rpmSanityCeiling)))
        copy.manualPercent = sanitized(copy.manualPercent, in: 0...100, fallback: 0)
        return copy
    }
}

/// One Auto Boost rule: "boost fans to `percent` when `sensor` is above `limitC`".
public struct BoostRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var sensor: SensorSelector
    /// Trigger threshold in Celsius; the rule fires strictly above it.
    public var limitC: Double
    /// 0...100; fan speed as a fraction of `[min, max]`. Ignored (treated as 100) when
    /// `BoostSettings.usePercent` is false.
    public var percent: Int
    /// 0-based fan the rule applies to; nil applies it to every fan. (SPEC 5.3 writes "0 = all";
    /// an optional avoids colliding with fan number 0.)
    public var fanIndex: Int?
    public var powerSource: PowerSource

    public init(id: UUID = UUID(), enabled: Bool = true, sensor: SensorSelector = .highestCPU,
                limitC: Double = 70, percent: Int = 100, fanIndex: Int? = nil,
                powerSource: PowerSource = .adapter) {
        self.id = id
        self.enabled = enabled
        self.sensor = sensor
        self.limitC = limitC
        self.percent = percent
        self.fanIndex = fanIndex
        self.powerSource = powerSource
    }

    private enum CodingKeys: String, CodingKey { case id, enabled, sensor, limitC, percent, fanIndex, powerSource }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.value(.id, default: UUID()),
                  enabled: c.value(.enabled, default: true),
                  sensor: c.value(.sensor, default: .highestCPU),
                  limitC: c.value(.limitC, default: 70),
                  percent: c.value(.percent, default: 100),
                  fanIndex: try? c.decodeIfPresent(Int.self, forKey: .fanIndex),
                  powerSource: c.value(.powerSource, default: .adapter))
    }

    public func normalized() -> BoostRule {
        var copy = self
        copy.limitC = sanitized(copy.limitC, in: 0...130, fallback: 70)
        copy.percent = max(0, min(copy.percent, 100))
        if let fan = copy.fanIndex, !(0...Constants.maxFanIndex).contains(fan) { copy.fanIndex = nil }
        return copy
    }
}

/// Auto Boost configuration: the rules plus the engine tuning (SPEC 5.3).
public struct BoostSettings: Codable, Equatable, Hashable, Sendable {
    /// Rules of both power sources; `rules(for:)` filters by `powerSource`.
    public var rules: [BoostRule]
    /// A fired rule stays active while temperature is above `limit - hysteresisC`.
    public var hysteresisC: Double
    /// ... and for at least this long after it fired.
    public var minHoldSeconds: Double
    /// Ramp duration when the goal speed rises.
    public var rampUpSeconds: Double
    /// Ramp duration when the goal speed falls.
    public var rampDownSeconds: Double
    /// After the ramp reaches the minimum and no rule is active for this long, fans return to auto.
    public var releaseDelaySeconds: Double
    /// True: rules use their percent ("Auto Boost"). False: any firing rule means 100% ("Auto Max").
    public var usePercent: Bool

    public init(rules: [BoostRule] = BoostSettings.defaultRules,
                hysteresisC: Double = 3, minHoldSeconds: Double = 15,
                rampUpSeconds: Double = 6, rampDownSeconds: Double = 20,
                releaseDelaySeconds: Double = 10, usePercent: Bool = true) {
        self.rules = rules
        self.hysteresisC = hysteresisC
        self.minHoldSeconds = minHoldSeconds
        self.rampUpSeconds = rampUpSeconds
        self.rampDownSeconds = rampDownSeconds
        self.releaseDelaySeconds = releaseDelaySeconds
        self.usePercent = usePercent
    }

    /// Rules for the given power source, in order (order breaks ties between equal percents).
    public func rules(for source: PowerSource) -> [BoostRule] {
        rules.filter { $0.powerSource == source }
    }

    /// FanPilot's defaults for Highest CPU: 35% at 58 C, 65% at 70 C, 100% at 82 C, for both power
    /// sources. Tuned for the M5 Pro where the system keeps fans off up to about 70 C (SPEC 5.3);
    /// to be refined on hardware. Ids are fixed so default settings compare equal across launches.
    public static let defaultRules: [BoostRule] = {
        let steps: [(limit: Double, percent: Int)] = [(58, 35), (70, 65), (82, 100)]
        var rules: [BoostRule] = []
        for (source, tag) in [(PowerSource.adapter, "A"), (PowerSource.battery, "B")] {
            for (i, step) in steps.enumerated() {
                rules.append(BoostRule(
                    id: UUID(uuidString: "FA11F170-0000-4000-8000-0000000000\(tag)\(i + 1)")!,
                    sensor: .highestCPU, limitC: step.limit, percent: step.percent,
                    fanIndex: nil, powerSource: source))
            }
        }
        return rules
    }()

    private enum CodingKeys: String, CodingKey {
        case rules, hysteresisC, minHoldSeconds, rampUpSeconds, rampDownSeconds, releaseDelaySeconds, usePercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode rules one by one so a single corrupt rule does not discard the rest.
        var rules: [BoostRule]
        if var list = try? c.nestedUnkeyedContainer(forKey: .rules) {
            rules = []
            while !list.isAtEnd {
                if let rule = try? list.decode(BoostRule.self) {
                    rules.append(rule)
                } else {
                    _ = try? list.decode(DiscardedValue.self)    // advance past the bad element
                }
            }
        } else {
            rules = BoostSettings.defaultRules
        }
        self.init(rules: rules,
                  hysteresisC: c.value(.hysteresisC, default: 3),
                  minHoldSeconds: c.value(.minHoldSeconds, default: 15),
                  rampUpSeconds: c.value(.rampUpSeconds, default: 6),
                  rampDownSeconds: c.value(.rampDownSeconds, default: 20),
                  releaseDelaySeconds: c.value(.releaseDelaySeconds, default: 10),
                  usePercent: c.value(.usePercent, default: true))
    }

    public func normalized() -> BoostSettings {
        var copy = self
        copy.rules = copy.rules.map { $0.normalized() }
        copy.hysteresisC = sanitized(copy.hysteresisC, in: 0...20, fallback: 3)
        copy.minHoldSeconds = sanitized(copy.minHoldSeconds, in: 0...300, fallback: 15)
        copy.rampUpSeconds = sanitized(copy.rampUpSeconds, in: 1...120, fallback: 6)
        copy.rampDownSeconds = sanitized(copy.rampDownSeconds, in: 1...120, fallback: 20)
        copy.releaseDelaySeconds = sanitized(copy.releaseDelaySeconds, in: 0...300, fallback: 10)
        return copy
    }
}

/// Accepts and ignores any JSON value; used to step over a corrupt array element.
private struct DiscardedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

/// One point of the fan curve.
public struct CurvePoint: Codable, Equatable, Hashable, Sendable {
    public var tempC: Double
    /// 0...100, fraction of the fan's `[min, max]` range.
    public var percent: Double

    public init(tempC: Double, percent: Double) {
        self.tempC = tempC
        self.percent = percent
    }

    private enum CodingKeys: String, CodingKey { case tempC, percent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tempC: try c.decode(Double.self, forKey: .tempC),
                  percent: try c.decode(Double.self, forKey: .percent))
    }
}

/// Curve mode configuration (SPEC 5.4).
public struct CurveSettings: Codable, Equatable, Hashable, Sendable {
    public var source: SensorSelector
    /// Points; interpreted sorted by temperature, linear between points, flat outside.
    public var points: [CurvePoint]
    /// Exponential moving average factor applied to the input temperature (0 < alpha <= 1).
    public var emaAlpha: Double
    /// Output falls only once the temperature is this far below the temperature of the current level.
    public var fallHysteresisC: Double

    public static let defaultPoints: [CurvePoint] = [
        CurvePoint(tempC: 45, percent: 0),
        CurvePoint(tempC: 58, percent: 35),
        CurvePoint(tempC: 70, percent: 65),
        CurvePoint(tempC: 82, percent: 100),
    ]

    public init(source: SensorSelector = .highestCPU, points: [CurvePoint] = CurveSettings.defaultPoints,
                emaAlpha: Double = 0.3, fallHysteresisC: Double = 3) {
        self.source = source
        self.points = points
        self.emaAlpha = emaAlpha
        self.fallHysteresisC = fallHysteresisC
    }

    private enum CodingKeys: String, CodingKey { case source, points, emaAlpha, fallHysteresisC }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: c.value(.source, default: .highestCPU),
                  points: c.value(.points, default: CurveSettings.defaultPoints),
                  emaAlpha: c.value(.emaAlpha, default: 0.3),
                  fallHysteresisC: c.value(.fallHysteresisC, default: 3))
    }

    /// Points sorted by temperature (stable for equal temperatures).
    public var sortedPoints: [CurvePoint] {
        points.enumerated().sorted { ($0.element.tempC, $0.offset) < ($1.element.tempC, $1.offset) }.map(\.element)
    }

    public func normalized() -> CurveSettings {
        var copy = self
        copy.points = copy.points
            .filter { $0.tempC.isFinite && $0.percent.isFinite }
            .map { CurvePoint(tempC: min(max($0.tempC, 0), 130), percent: min(max($0.percent, 0), 100)) }
        if copy.points.isEmpty { copy.points = Self.defaultPoints }
        copy.points = CurveSettings(points: copy.points).sortedPoints
        copy.emaAlpha = sanitized(copy.emaAlpha, in: 0.05...1, fallback: 0.3)
        copy.fallHysteresisC = sanitized(copy.fallHysteresisC, in: 0...20, fallback: 3)
        return copy
    }
}

/// The complete control intent: per-fan modes plus the shared rule and curve configuration.
public struct Policy: Codable, Equatable, Hashable, Sendable {
    /// One entry per fan, by fan index. May be shorter than the fan count (missing entries behave
    /// as default `FanPolicy()`, i.e. auto); use `fanPolicy(at:)`.
    public var perFan: [FanPolicy]
    /// When true, moving one slider moves the others by normalized position (SPEC 5.2).
    public var linkFans: Bool
    public var boost: BoostSettings
    public var curve: CurveSettings

    public init(perFan: [FanPolicy] = [], linkFans: Bool = true,
                boost: BoostSettings = BoostSettings(), curve: CurveSettings = CurveSettings()) {
        self.perFan = perFan
        self.linkFans = linkFans
        self.boost = boost
        self.curve = curve
    }

    private enum CodingKeys: String, CodingKey { case perFan, linkFans, boost, curve }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var fans: [FanPolicy] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .perFan) {
            while !list.isAtEnd {
                if let fan = try? list.decode(FanPolicy.self) {
                    fans.append(fan)
                } else {
                    // Keep positions aligned with fan indices: a bad entry becomes the default.
                    _ = try? list.decode(DiscardedValue.self)
                    fans.append(FanPolicy())
                }
            }
        }
        self.init(perFan: fans,
                  linkFans: c.value(.linkFans, default: true),
                  boost: c.value(.boost, default: BoostSettings()),
                  curve: c.value(.curve, default: CurveSettings()))
    }

    /// Policy of fan `index`; the default (auto) if none is stored.
    public func fanPolicy(at index: Int) -> FanPolicy {
        perFan.indices.contains(index) ? perFan[index] : FanPolicy()
    }

    /// Stores `policy` for fan `index`, padding with defaults as needed.
    public mutating func setFanPolicy(_ policy: FanPolicy, at index: Int) {
        guard index >= 0, index <= Constants.maxFanIndex else { return }
        while perFan.count <= index { perFan.append(FanPolicy()) }
        perFan[index] = policy
    }

    /// Sets the mode of every fan (the global segmented control).
    public mutating func setMode(_ mode: ControlMode, fanCount: Int) {
        let count = max(0, min(fanCount, Constants.maxFanIndex + 1))
        while perFan.count < count { perFan.append(FanPolicy()) }
        for i in perFan.indices { perFan[i].mode = mode }
    }

    /// The mode shared by all of the first `fanCount` fans, or nil when they differ.
    public func uniformMode(fanCount: Int) -> ControlMode? {
        guard fanCount > 0 else { return nil }
        let modes = (0..<fanCount).map { fanPolicy(at: $0).mode }
        return modes.allSatisfy { $0 == modes[0] } ? modes[0] : nil
    }

    /// Resizes `perFan` to exactly `fanCount` entries.
    public func normalized(fanCount: Int? = nil) -> Policy {
        var copy = self
        copy.perFan = copy.perFan.prefix(Constants.maxFanIndex + 1).map { $0.normalized() }
        if let fanCount {
            let count = max(0, min(fanCount, Constants.maxFanIndex + 1))
            if copy.perFan.count > count { copy.perFan.removeLast(copy.perFan.count - count) }
            while copy.perFan.count < count { copy.perFan.append(FanPolicy()) }
        }
        copy.boost = copy.boost.normalized()
        copy.curve = copy.curve.normalized()
        return copy
    }
}
