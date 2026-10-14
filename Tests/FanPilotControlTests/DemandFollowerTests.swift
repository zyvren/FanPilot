import XCTest
import FanPilotKit
@testable import FanPilotControl

final class DemandFollowerTests: XCTestCase {
    private let limits = TestFans.leftLimits                          // 1350 ... 5349
    private let params = DemandFollower.Parameters(rampUpSeconds: 6, rampDownSeconds: 20, releaseDelaySeconds: 10)

    private func rpm(_ f: inout DemandFollower, demand: Double?, start: Double = 1350, at t: TimeInterval,
                     snap: Bool = false) -> FanCommand {
        f.update(demandPercent: demand, limits: limits, startRPM: start, parameters: params, now: t, snapUp: snap)
    }

    func testStaysAutoWithoutDemand() {
        var f = DemandFollower()
        for t in 0..<30 { XCTAssertEqual(rpm(&f, demand: nil, at: Double(t)), .auto) }
        XCTAssertEqual(f.phase, .released)
    }

    func testTakeoverStartsAtTheGivenSpeedAndRampsToTheExactGoal() {
        var f = DemandFollower()
        XCTAssertEqual(rpm(&f, demand: 100, start: 1350, at: 0), .rpm(1350))
        XCTAssertTrue(f.isRamping)
        var last = 1350.0
        for t in 1...6 {
            let value = rpm(&f, demand: 100, at: Double(t)).rpm!
            XCTAssertGreaterThan(value, last)
            XCTAssertLessThanOrEqual(value, 5349)
            last = value
        }
        XCTAssertEqual(last, 5349)
        XCTAssertFalse(f.isRamping)
        XCTAssertEqual(f.goalRPM, 5349)
    }

    func testTakeoverStartIsClampedIntoTheRange() {
        var f = DemandFollower()
        XCTAssertEqual(rpm(&f, demand: 100, start: 100, at: 0), .rpm(1350))
        var g = DemandFollower()
        XCTAssertEqual(rpm(&g, demand: 0, start: 99_999, at: 0), .rpm(5349))     // ramps down from max
        XCTAssertEqual(rpm(&g, demand: 0, at: 20), .rpm(1350))
    }

    func testReleasesToAutoAfterReachingTheMinimumAndTheIdleDelay() {
        var f = DemandFollower()
        _ = rpm(&f, demand: 100, at: 0)
        _ = rpm(&f, demand: 100, at: 6)                                           // at 5349
        // Demand disappears at t = 100: ramp down takes 20 s, then 10 s idle.
        XCTAssertEqual(rpm(&f, demand: nil, at: 100), .rpm(5349))
        XCTAssertTrue(f.isRamping)
        var commands: [FanCommand] = []
        for t in 101...130 { commands.append(rpm(&f, demand: nil, at: Double(t))) }
        XCTAssertEqual(commands[18], .rpm(RPMMath.validated(5349 - 3999.0 * 19 / 20, limits: limits)))  // t = 119
        XCTAssertEqual(commands[19], .rpm(1350))                                  // t = 120: minimum reached
        for t in 120..<130 { XCTAssertEqual(commands[t - 101], .rpm(1350), "t = \(t) still holding the minimum") }
        XCTAssertEqual(commands[29], .auto)                                       // t = 130: 10 s after reaching it
        XCTAssertEqual(f.phase, .released)
        // And it stays released.
        XCTAssertEqual(rpm(&f, demand: nil, at: 200), .auto)
    }

    func testIdleDelayIsMeasuredFromTheMomentTheMinimumIsReached() {
        // The ramp-down alone never releases the fan even if the demand vanished long ago.
        var f = DemandFollower()
        _ = rpm(&f, demand: 100, start: 5349, at: 0)
        XCTAssertEqual(rpm(&f, demand: nil, at: 1), .rpm(5349))
        XCTAssertNotEqual(rpm(&f, demand: nil, at: 20), .auto)                    // 19 s into a 20 s ramp
        XCTAssertEqual(rpm(&f, demand: nil, at: 21), .rpm(1350))                  // ramp done at 21
        XCTAssertEqual(rpm(&f, demand: nil, at: 30.9), .rpm(1350))
        XCTAssertEqual(rpm(&f, demand: nil, at: 31), .auto)
    }

    func testAtTheMinimumAlreadyTheDelayAloneApplies() {
        var f = DemandFollower()
        XCTAssertEqual(rpm(&f, demand: 0, at: 0), .rpm(1350))                     // 0% = hold the minimum
        for t in 1..<100 { XCTAssertEqual(rpm(&f, demand: 0, at: Double(t)), .rpm(1350), "0% never releases") }
        XCTAssertEqual(rpm(&f, demand: nil, at: 100), .rpm(1350))
        XCTAssertEqual(rpm(&f, demand: nil, at: 109.9), .rpm(1350))
        XCTAssertEqual(rpm(&f, demand: nil, at: 110), .auto)
    }

    func testDemandReturningDuringTheIdleDelayCancelsTheRelease() {
        var f = DemandFollower()
        _ = rpm(&f, demand: 0, at: 0)
        XCTAssertEqual(rpm(&f, demand: nil, at: 10), .rpm(1350))
        XCTAssertEqual(rpm(&f, demand: nil, at: 19), .rpm(1350))
        XCTAssertNotEqual(rpm(&f, demand: 50, at: 19.5), .auto)                   // wanted again
        // The delay restarts from scratch: nothing released within 10 s of losing the demand again.
        var g = DemandFollower()
        _ = rpm(&g, demand: 0, at: 0)
        _ = rpm(&g, demand: nil, at: 5)
        _ = rpm(&g, demand: 0, at: 9)                                             // wanted again at the minimum
        XCTAssertEqual(rpm(&g, demand: nil, at: 10), .rpm(1350))
        XCTAssertEqual(rpm(&g, demand: nil, at: 19.9), .rpm(1350))
        XCTAssertEqual(rpm(&g, demand: nil, at: 20), .auto)
    }

    func testDemandReturningMidRampDownReversesFromTheCurrentSpeed() {
        var f = DemandFollower()
        _ = rpm(&f, demand: 100, start: 5349, at: 0)
        _ = rpm(&f, demand: nil, at: 1)
        let mid = rpm(&f, demand: nil, at: 11).rpm!                               // halfway down
        XCTAssertEqual(mid, RPMMath.validated(5349 - 3999.0 / 2, limits: limits))
        let next = rpm(&f, demand: 100, at: 11).rpm!
        XCTAssertEqual(next, mid, "no jump when the goal reverses")
        var last = next
        for t in 12...17 {
            let value = rpm(&f, demand: 100, at: Double(t)).rpm!
            XCTAssertGreaterThanOrEqual(value, last)
            last = value
        }
        XCTAssertEqual(last, 5349)
    }

    func testSnapUpReachesTheGoalAtOnceButNeverSnapsDown() {
        var f = DemandFollower()
        XCTAssertEqual(rpm(&f, demand: 100, start: 1350, at: 0, snap: true), .rpm(5349))
        XCTAssertEqual(rpm(&f, demand: 0, at: 1, snap: true), .rpm(5349))          // falls via the ramp
        XCTAssertTrue(f.isRamping)
    }

    func testUnusableLimitsReleaseTheFan() {
        var f = DemandFollower()
        _ = rpm(&f, demand: 100, at: 0)
        let command = f.update(demandPercent: 100, limits: FanLimits(min: 0, max: 0), startRPM: 0,
                               parameters: params, now: 1)
        XCTAssertEqual(command, .auto)
        XCTAssertEqual(f.phase, .released)
    }

    func testResetDropsOwnershipImmediately() {
        var f = DemandFollower()
        _ = rpm(&f, demand: 100, at: 0)
        f.reset()
        XCTAssertEqual(f.phase, .released)
        XCTAssertEqual(rpm(&f, demand: nil, at: 1), .auto)
    }
}
