import Foundation
import XCTest
import FanPilotKit
@testable import FanPilotControl

/// The two fans of a Mac17,8 (measured on an M5 Pro MacBook Pro): different maxima on purpose, so every mapping
/// test exercises the normalized-position logic.
enum TestFans {
    static let left = FanInfo(index: 0, name: "Left Side", minRPM: 1350, maxRPM: 5349,
                              backend: .appleSiliconMd(modeKey: "F0md"))
    static let right = FanInfo(index: 1, name: "Right Side", minRPM: 1350, maxRPM: 5777,
                               backend: .appleSiliconMd(modeKey: "F1md"))
    static let both = [left, right]

    static var leftLimits: FanLimits { FanLimits(left) }
    static var rightLimits: FanLimits { FanLimits(right) }

    static func inputs(actual: Double? = nil) -> [FanInput] {
        both.map { FanInput(info: $0, actualRPM: actual) }
    }
}

/// Deterministic pseudo-random numbers (SplitMix64) so fuzz failures reproduce.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func makeRule(_ limit: Double, _ percent: Int, fan: Int? = nil, source: PowerSource = .adapter,
              sensor: SensorSelector = .highestCPU, enabled: Bool = true, id: UUID = UUID()) -> BoostRule {
    BoostRule(id: id, enabled: enabled, sensor: sensor, limitC: limit, percent: percent,
              fanIndex: fan, powerSource: source)
}

func makeBoost(_ rules: [BoostRule], hysteresis: Double = 3, hold: Double = 15, usePercent: Bool = true,
               up: Double = 6, down: Double = 20, release: Double = 10) -> BoostSettings {
    BoostSettings(rules: rules, hysteresisC: hysteresis, minHoldSeconds: hold, rampUpSeconds: up,
                  rampDownSeconds: down, releaseDelaySeconds: release, usePercent: usePercent)
}

func temp(_ celsius: Double, at time: TimeInterval = 0) -> TemperatureInputs {
    .uniform(celsius, sampledAt: time)
}

/// Runs a controller tick by tick with one-second resolution.
struct Harness {
    var controller = FanController()
    var policy: Policy
    var fans: [FanInput]
    var powerSource = PowerSource.adapter
    var now: TimeInterval = 0

    init(policy: Policy, fans: [FanInput] = TestFans.inputs()) {
        self.policy = policy
        self.fans = fans
    }

    /// Advances to absolute time `t` and updates with a temperature that is sampled at `t`.
    @discardableResult
    mutating func step(to t: TimeInterval, temp celsius: Double?) -> ControllerOutput {
        now = t
        let temps = celsius.map { TemperatureInputs.uniform($0, sampledAt: t) } ?? .none
        return controller.update(policy: policy, fans: fans, temps: temps, powerSource: powerSource, now: t)
    }

    @discardableResult
    mutating func step(to t: TimeInterval, temps: TemperatureInputs) -> ControllerOutput {
        now = t
        return controller.update(policy: policy, fans: fans, temps: temps, powerSource: powerSource, now: t)
    }
}

func policy(mode: ControlMode, boost: BoostSettings = BoostSettings(), fanCount: Int = 2,
            linkFans: Bool = true) -> Policy {
    var p = Policy(linkFans: linkFans, boost: boost)
    p.setMode(mode, fanCount: fanCount)
    return p
}
