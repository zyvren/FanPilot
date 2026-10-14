import XCTest
@testable import FanPilotControl

final class RampLimiterTests: XCTestCase {
    /// Samples a ramp once per second after a goal was set at t = 0.
    private func samples(_ limiter: inout RampLimiter, goal: Double, up: Double = 6, down: Double = 20,
                         from t0: TimeInterval = 0, seconds: Int) -> [Double] {
        (0...seconds).map { limiter.update(goal: goal, upSeconds: up, downSeconds: down, now: t0 + Double($0)) }
    }

    func testFirstUpdateJumpsToTheGoal() {
        var limiter = RampLimiter()
        XCTAssertNil(limiter.current)
        XCTAssertEqual(limiter.update(goal: 3000, upSeconds: 6, downSeconds: 20, now: 0), 3000)
        XCTAssertFalse(limiter.isRamping)
    }

    func testRampUpReachesTheExactGoalInSixSteps() {
        var limiter = RampLimiter()
        limiter.reset(to: 1350, now: 0)
        let values = samples(&limiter, goal: 5349, seconds: 8)
        XCTAssertEqual(values[0], 1350)
        for k in 1...6 {
            XCTAssertEqual(values[k], 1350 + 3999 * Double(k) / 6, accuracy: 1e-9, "step \(k)")
        }
        XCTAssertEqual(values[6], 5349)           // exact, not accumulated
        XCTAssertEqual(values[7], 5349)
        XCTAssertEqual(values[8], 5349)
        XCTAssertFalse(limiter.isRamping)
    }

    func testRampDownTakesTwentySteps() {
        var limiter = RampLimiter()
        limiter.reset(to: 5349, now: 0)
        let values = samples(&limiter, goal: 1350, seconds: 22)
        XCTAssertEqual(values[19], 5349 - 3999.0 * 19 / 20, accuracy: 1e-9)
        XCTAssertGreaterThan(values[19], 1350)
        XCTAssertEqual(values[20], 1350)
        XCTAssertEqual(values[21], 1350)
        XCTAssertEqual(limiter.settledAt, 20)
    }

    func testNeverOvershootsAndIsMonotonic() {
        // Awkward numbers on purpose: the step does not divide the distance evenly.
        var limiter = RampLimiter()
        limiter.reset(to: 1351, now: 0)
        let up = samples(&limiter, goal: 5347, seconds: 10)
        XCTAssertEqual(up.max(), 5347)
        XCTAssertEqual(up.last, 5347)
        XCTAssertEqual(up, up.sorted())
        XCTAssertEqual(up.filter { $0 == 5347 }.count, 5)     // t = 6...10

        var down = RampLimiter()
        down.reset(to: 5347, now: 0)
        let falling = samples(&down, goal: 1351, seconds: 25)
        XCTAssertEqual(falling.min(), 1351)
        XCTAssertEqual(falling.last, 1351)
        XCTAssertEqual(falling, falling.sorted(by: >))
    }

    func testCoarseTicksStillLandOnTheGoal() {
        // Sensor ticks every 2 s: two steps are applied per call.
        var limiter = RampLimiter()
        limiter.reset(to: 1350, now: 0)
        var last = 0.0
        for t in stride(from: 0.0, through: 8, by: 2) {
            last = limiter.update(goal: 5349, upSeconds: 6, downSeconds: 20, now: t)
        }
        XCTAssertEqual(last, 5349)
    }

    func testALateCallFinishesTheRampInOneJump() {
        var limiter = RampLimiter()
        limiter.reset(to: 1350, now: 0)
        _ = limiter.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: 0)
        XCTAssertEqual(limiter.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: 100_000), 4000)
        XCTAssertEqual(limiter.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: 1e300), 4000)
    }

    func testPartialSecondsDoNotAdvanceTheRamp() {
        var limiter = RampLimiter()
        limiter.reset(to: 1000, now: 0)
        _ = limiter.update(goal: 1600, upSeconds: 6, downSeconds: 20, now: 0)     // 100 RPM per step
        XCTAssertEqual(limiter.update(goal: 1600, upSeconds: 6, downSeconds: 20, now: 0.99), 1000)
        XCTAssertEqual(limiter.update(goal: 1600, upSeconds: 6, downSeconds: 20, now: 1.0), 1100)
        XCTAssertEqual(limiter.update(goal: 1600, upSeconds: 6, downSeconds: 20, now: 1.99), 1100)
        XCTAssertEqual(limiter.update(goal: 1600, upSeconds: 6, downSeconds: 20, now: 3.0), 1300)
    }

    func testGoalChangeMidRampRestartsFromTheCurrentValue() {
        var limiter = RampLimiter()
        limiter.reset(to: 1000, now: 0)
        _ = limiter.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: 0)
        let mid = limiter.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: 3)    // 2500
        XCTAssertEqual(mid, 2500)

        // New, lower goal: ramp DOWN from 2500 over 20 s, never touching the old start of 1000.
        var path: [Double] = [limiter.update(goal: 2000, upSeconds: 6, downSeconds: 20, now: 3)]
        XCTAssertEqual(path[0], 2500)
        for k in 1...20 { path.append(limiter.update(goal: 2000, upSeconds: 6, downSeconds: 20, now: 3 + Double(k))) }
        XCTAssertEqual(path.last, 2000)
        XCTAssertEqual(path, path.sorted(by: >))
        XCTAssertGreaterThanOrEqual(path.min()!, 2000)
        XCTAssertLessThanOrEqual(path.max()!, 2500)

        // Reversal while going down: back up from wherever it is, no overshoot past the new goal.
        var limiter2 = RampLimiter()
        limiter2.reset(to: 5000, now: 0)
        _ = limiter2.update(goal: 1350, upSeconds: 6, downSeconds: 20, now: 0)
        let low = limiter2.update(goal: 1350, upSeconds: 6, downSeconds: 20, now: 10)   // halfway
        XCTAssertEqual(low, 5000 - 3650 * 10 / 20.0, accuracy: 1e-9)
        var up: [Double] = []
        for k in 0...6 { up.append(limiter2.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: 10 + Double(k))) }
        XCTAssertEqual(up.first, low)
        XCTAssertEqual(up.last, 4000)
        XCTAssertEqual(up, up.sorted())
    }

    func testRepeatingTheSameGoalDoesNotRestartTheRamp() {
        var limiter = RampLimiter()
        limiter.reset(to: 1000, now: 0)
        for t in 0...6 {
            _ = limiter.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: Double(t))
        }
        XCTAssertEqual(limiter.current, 4000)
        // Re-sending the goal (even with float noise) mid-ramp keeps the schedule.
        var noisy = RampLimiter()
        noisy.reset(to: 1000, now: 0)
        _ = noisy.update(goal: 4000, upSeconds: 6, downSeconds: 20, now: 0)
        _ = noisy.update(goal: 4000.2, upSeconds: 6, downSeconds: 20, now: 2)
        XCTAssertEqual(noisy.update(goal: 3999.9, upSeconds: 6, downSeconds: 20, now: 6), 4000)
    }

    func testGoalWithinToleranceIsTheSameGoal() {
        var limiter = RampLimiter()
        limiter.reset(to: 2000, now: 0)
        XCTAssertEqual(limiter.update(goal: 2000.3, upSeconds: 6, downSeconds: 20, now: 1), 2000)
        XCTAssertFalse(limiter.isRamping)
    }

    func testNewGoalAlreadyUnderFootSnapsExactly() {
        var limiter = RampLimiter()
        limiter.reset(to: 2000, now: 0)
        _ = limiter.update(goal: 2600, upSeconds: 6, downSeconds: 20, now: 0)
        XCTAssertEqual(limiter.update(goal: 2600, upSeconds: 6, downSeconds: 20, now: 3), 2300)
        // The ramp is redirected to a goal 0.4 RPM away from where it is: land on it exactly, no ramp.
        XCTAssertEqual(limiter.update(goal: 2300.4, upSeconds: 6, downSeconds: 20, now: 3), 2300.4)
        XCTAssertFalse(limiter.isRamping)
    }

    func testSnapUpBypassesOnlyIncreases() {
        var limiter = RampLimiter()
        limiter.reset(to: 2000, now: 0)
        XCTAssertEqual(limiter.update(goal: 5000, upSeconds: 6, downSeconds: 20, now: 0, snapUp: true), 5000)
        XCTAssertFalse(limiter.isRamping)
        // Falling is never snapped.
        let down = limiter.update(goal: 1350, upSeconds: 6, downSeconds: 20, now: 1, snapUp: true)
        XCTAssertEqual(down, 5000)
        XCTAssertTrue(limiter.isRamping)
        // A ramp already running upward is finished immediately once the bypass turns on.
        var slow = RampLimiter()
        slow.reset(to: 2000, now: 0)
        _ = slow.update(goal: 5000, upSeconds: 6, downSeconds: 20, now: 0)
        XCTAssertEqual(slow.update(goal: 5000, upSeconds: 6, downSeconds: 20, now: 1, snapUp: true), 5000)
    }

    func testDurationsAreBoundedAndNeverZeroSteps() {
        var limiter = RampLimiter()
        limiter.reset(to: 1000, now: 0)
        _ = limiter.update(goal: 2000, upSeconds: 0, downSeconds: 0, now: 0)
        XCTAssertEqual(limiter.update(goal: 2000, upSeconds: 0, downSeconds: 0, now: 1), 2000)
        var nan = RampLimiter()
        nan.reset(to: 1000, now: 0)
        _ = nan.update(goal: 2000, upSeconds: .nan, downSeconds: .infinity, now: 0)
        XCTAssertEqual(nan.update(goal: 2000, upSeconds: .nan, downSeconds: .infinity, now: 1), 2000)
    }

    func testNonFiniteGoalIsIgnored() {
        var limiter = RampLimiter()
        limiter.reset(to: 1500, now: 0)
        XCTAssertEqual(limiter.update(goal: .nan, upSeconds: 6, downSeconds: 20, now: 1), 1500)
        XCTAssertEqual(limiter.update(goal: .infinity, upSeconds: 6, downSeconds: 20, now: 1), 1500)
    }

    /// Random goal changes at random times: after the last change the limiter must end on the
    /// exact last goal, and every output must stay between the extremes seen so far.
    func testFuzzAlwaysEndsOnTheExactFinalGoal() {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<300 {
            var limiter = RampLimiter()
            var now = 0.0
            var goal = Double(Int.random(in: 1350...5777, using: &rng))
            limiter.reset(to: Double(Int.random(in: 1350...5777, using: &rng)), now: now)
            var lo = Swift.min(limiter.current!, goal), hi = Swift.max(limiter.current!, goal)
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                goal = Double(Int.random(in: 1350...5777, using: &rng))
                lo = Swift.min(lo, goal); hi = Swift.max(hi, goal)
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    now += Double.random(in: 0...5, using: &rng)
                    let value = limiter.update(goal: goal, upSeconds: Double(Int.random(in: 1...10, using: &rng)),
                                               downSeconds: Double(Int.random(in: 1...30, using: &rng)), now: now)
                    XCTAssertTrue(value >= lo && value <= hi, "\(value) outside \(lo)...\(hi)")
                }
            }
            now += 10_000
            XCTAssertEqual(limiter.update(goal: goal, upSeconds: 10, downSeconds: 30, now: now), goal)
            XCTAssertFalse(limiter.isRamping)
        }
    }
}
