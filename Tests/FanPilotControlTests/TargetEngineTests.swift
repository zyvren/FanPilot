import XCTest
import FanPilotKit
@testable import FanPilotControl

final class TargetEngineTests: XCTestCase {
    func testBelowTargetAsksForNothing() {
        var engine = TargetEngine()
        XCTAssertNil(engine.evaluate(targetC: 80, temps: .none), "no temperature seen yet")
        XCTAssertEqual(engine.evaluate(targetC: 80, temps: .uniform(70, sampledAt: 1)), 0)
    }

    func testProportionalReactsAtOnceAndIntegralBuildsUp() {
        var engine = TargetEngine()
        let first = engine.evaluate(targetC: 80, temps: .uniform(83, sampledAt: 0))!
        XCTAssertEqual(first, 3 * TargetEngine.proportionalGain, accuracy: 1e-9)
        let later = engine.evaluate(targetC: 80, temps: .uniform(83, sampledAt: 4))!
        XCTAssertEqual(later, first + 3 * TargetEngine.integralGain * 4, accuracy: 1e-9, "steady input: no smoothing lag")
        // Same sample again: nothing advances.
        XCTAssertEqual(engine.evaluate(targetC: 80, temps: .uniform(83, sampledAt: 4)), later)
    }

    /// Closed loop on a first-order thermal model where 37.5% holds 80 C: the engine settles on
    /// that speed instead of running the fans at maximum.
    func testSettlesOnTheSpeedThatHoldsTheTarget() {
        var engine = TargetEngine()
        var temp = 60.0
        var percent = 0.0
        for second in 0..<900 {
            percent = engine.evaluate(targetC: 80, temps: .uniform(temp, sampledAt: Double(second))) ?? 0
            let equilibrium = 95 - 0.4 * percent        // 0% -> 95 C, 100% -> 55 C
            temp += (equilibrium - temp) / 20             // 20 s time constant
        }
        XCTAssertEqual(percent, 37.5, accuracy: 2)
        XCTAssertEqual(temp, 80, accuracy: 0.5)
    }

    /// Same plant with +-1.5 C read noise: the demand stays steady instead of hunting.
    func testNoisyInputDoesNotMakeTheFansHunt() {
        var engine = TargetEngine()
        var temp = 80.0
        var outputs: [Double] = []
        for second in 0..<900 {
            let noise = second % 2 == 0 ? 1.5 : -1.5
            let percent = engine.evaluate(targetC: 80, temps: .uniform(temp + noise, sampledAt: Double(second))) ?? 0
            if second >= 600 { outputs.append(percent) }
            temp += (95 - 0.4 * percent - temp) / 20
        }
        let swing = outputs.max()! - outputs.min()!
        XCTAssertLessThan(swing, 12, "raw P on the noise alone would swing 24%")
        XCTAssertEqual(outputs.reduce(0, +) / Double(outputs.count), 37.5, accuracy: 3)
    }

    func testNoWindupWhileSaturated() {
        var engine = TargetEngine()
        for second in 0..<300 { _ = engine.evaluate(targetC: 80, temps: .uniform(100, sampledAt: Double(second))) }
        XCTAssertEqual(engine.percent, 100)
        // Back under the target: the fans come down within seconds instead of draining a huge integral.
        var out = 100.0
        for second in 300..<306 { out = engine.evaluate(targetC: 80, temps: .uniform(70, sampledAt: Double(second))) ?? 0 }
        XCTAssertEqual(out, 0)
    }

    func testControllerReleasesBelowTargetAndDrivesAboveIt() {
        var p = policy(mode: .target, boost: makeBoost([], up: 1, down: 1, release: 5))
        p.targetTempC = 80
        var h = Harness(policy: p, fans: TestFans.inputs(actual: 0))
        XCTAssertEqual(h.step(to: 0, temp: 70).directives.map(\.command), [.auto, .auto])
        for t in 1...9 { _ = h.step(to: Double(t), temp: 85) }    // the smoothed input catches up
        let out = h.step(to: 10, temp: 85)
        guard case .rpm(let rpm)? = out.directive(forFan: 0)?.command else { return XCTFail("expected a speed") }
        XCTAssertGreaterThan(rpm, 1350)
        XCTAssertLessThan(rpm, 5349)
    }

    func testTargetTemperatureDecodesWithDefaultAndClamps() throws {
        let old = try JSONDecoder().decode(Policy.self, from: Data("{}".utf8))
        XCTAssertEqual(old.targetTempC, Policy.defaultTargetTempC)
        var p = Policy(targetTempC: 200)
        p = p.normalized()
        XCTAssertEqual(p.targetTempC, Policy.targetTempRange.upperBound)
    }
}
