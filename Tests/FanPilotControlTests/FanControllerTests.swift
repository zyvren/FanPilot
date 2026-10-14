import XCTest
import FanPilotKit
@testable import FanPilotControl

final class FanControllerTests: XCTestCase {
    // MARK: Auto

    func testAutoModeNeverSendsAnything() {
        var h = Harness(policy: Policy())
        for t in 0..<20 {
            let out = h.step(to: Double(t), temp: 95)
            XCTAssertEqual(out.directives.map(\.command), [.auto, .auto])
            XCTAssertTrue(out.commandsToSend.isEmpty, "t = \(t)")
        }
    }

    func testBoostWithACoolMachineLeavesTheFansToTheSystem() {
        var h = Harness(policy: policy(mode: .boost))
        for t in 0..<30 {
            let out = h.step(to: Double(t), temp: 45)
            XCTAssertEqual(out.directives.map(\.command), [.auto, .auto])
            XCTAssertTrue(out.commandsToSend.isEmpty)
        }
    }

    // MARK: Manual

    func testManualRPMIsClampedToTheFanRange() {
        var p = policy(mode: .manual, linkFans: false)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 9999), at: 0)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 100), at: 1)
        var h = Harness(policy: p)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(5349))
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(1350))
    }

    func testManualPercentZeroIsTheMinimumNotOff() {
        var p = policy(mode: .manual, linkFans: false)
        p.setFanPolicy(FanPolicy(mode: .manual, manualPercent: 0, manualUnit: .percent), at: 0)
        p.setFanPolicy(FanPolicy(mode: .manual, manualPercent: 100, manualUnit: .percent), at: 1)
        var h = Harness(policy: p)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(1350))
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(5777))
        XCTAssertTrue(out.directive(forFan: 0)?.changed ?? false, "taking over at the minimum is still a change from auto")
    }

    func testManualUnsetRPMMeansTheMinimumAndPercentUsesEachFansOwnRange() {
        var p = policy(mode: .manual, linkFans: false)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 0, manualUnit: .rpm), at: 0)
        p.setFanPolicy(FanPolicy(mode: .manual, manualPercent: 50, manualUnit: .percent), at: 1)
        var h = Harness(policy: p)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(1350))
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(3564))
    }

    func testManualUnitToggleKeepsTheSameSpeed() {
        var p = policy(mode: .manual, linkFans: false)
        p.applyManualRPM(3000, forFan: 0, fans: TestFans.both)
        var asRPM = Harness(policy: p)
        let rpmCommand = asRPM.step(to: 0, temp: 40).directive(forFan: 0)?.command
        p.perFan[0].manualUnit = .percent
        var asPercent = Harness(policy: p)
        XCTAssertEqual(asPercent.step(to: 0, temp: 40).directive(forFan: 0)?.command, rpmCommand)
    }

    // MARK: Link

    func testLinkedManualFansFollowTheLeaderByNormalizedPosition() {
        var p = policy(mode: .manual, linkFans: true)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 2000), at: 0)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 0), at: 1)               // stale value
        var h = Harness(policy: p)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(2000))
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(2070))
    }

    func testUnlinkedFansKeepTheirOwnValues() {
        var p = policy(mode: .manual, linkFans: false)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 2000), at: 0)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 4000), at: 1)
        var h = Harness(policy: p)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(2000))
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(4000))
    }

    func testLinkOnlyAffectsFansInManualMode() {
        var p = policy(mode: .manual, linkFans: true)
        p.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 2000), at: 0)
        p.setFanPolicy(FanPolicy(mode: .max), at: 1)
        var h = Harness(policy: p)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(2000))
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(5777))
    }

    func testSliderEditThenControllerRoundTrip() {
        var p = policy(mode: .manual, linkFans: true)
        p.applyManualRPM(3000, forFan: 1, fans: TestFans.both)              // user drags the RIGHT slider
        var h = Harness(policy: p)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(3000))
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(2840))
    }

    // MARK: Max

    func testMaxIsImmediateAndPerFan() {
        var h = Harness(policy: policy(mode: .max))
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directives.map(\.command), [.rpm(5349), .rpm(5777)])
        XCTAssertEqual(out.commandsToSend.count, 2)
        XCTAssertFalse(out.directives.contains { $0.isRamping })
    }

    // MARK: Boost end to end

    func testBoostTakesOverRampsToTheExactGoalAndReleasesAfterCooling() {
        var h = Harness(policy: policy(mode: .boost), fans: TestFans.inputs(actual: 0))
        // Cool: nothing happens.
        for t in 0..<10 { XCTAssertTrue(h.step(to: Double(t), temp: 45).commandsToSend.isEmpty) }

        // 72 C at t = 10 fires the 58 C (35%) and 70 C (65%) rules: goal 65% = 3949 on fan 0.
        let first = h.step(to: 10, temp: 72)
        let d0 = first.directive(forFan: 0)!
        XCTAssertEqual(d0.command, .rpm(1350), "a fan at 0 RPM is taken over at its minimum and ramped from there")
        XCTAssertTrue(d0.changed && d0.shouldSend)
        XCTAssertEqual(d0.goalRPM, 3949)
        XCTAssertTrue(d0.isRamping)

        var sent: [Double] = [1350]
        for t in 11...16 {
            let d = h.step(to: Double(t), temp: 72).directive(forFan: 0)!
            sent.append(d.command.rpm!)
            XCTAssertEqual(d.shouldSend, d.changed)
        }
        XCTAssertEqual(sent.last, 3949, "the final exact goal is always written")
        XCTAssertEqual(sent, sent.sorted())
        XCTAssertLessThanOrEqual(sent.max()!, 3949, "no overshoot")
        // Stays at the goal, no sends except the 5 s refresh.
        let sends = (17...40).filter { h.step(to: Double($0), temp: 72).directive(forFan: 0)!.shouldSend }
        XCTAssertEqual(sends, [21, 26, 31, 36], "refreshed every 5 s only")

        // Cools to 50 C at t = 41 (rules fired at t = 10: the 15 s hold is long over).
        // Ramp down takes 20 s (to t = 61), then 10 s idle (release at t = 71).
        var timeline: [Int: FanCommand] = [:]
        for t in 41...75 { timeline[t] = h.step(to: Double(t), temp: 50).directive(forFan: 0)!.command }
        XCTAssertEqual(timeline[41], .rpm(3949))
        XCTAssertEqual(timeline[60], .rpm(RPMMath.validated(3949 - (3949 - 1350) * 19.0 / 20, limits: TestFans.leftLimits)))
        XCTAssertEqual(timeline[61], .rpm(1350))
        XCTAssertEqual(timeline[70], .rpm(1350))
        XCTAssertEqual(timeline[71], .auto)
        XCTAssertEqual(timeline[75], .auto)
    }

    func testReleaseIsReportedAsAChange() {
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost([makeRule(60, 0)], hold: 0, release: 5)),
                        fans: TestFans.inputs(actual: 0))
        _ = h.step(to: 0, temp: 70)                                  // 0% rule: hold the minimum
        _ = h.step(to: 1, temp: 70)
        let lost = h.step(to: 2, temp: 40)                           // demand gone, already at the minimum
        XCTAssertEqual(lost.directive(forFan: 0)?.command, .rpm(1350))
        XCTAssertFalse(lost.directive(forFan: 0)!.changed)
        let released = h.step(to: 7, temp: 40).directive(forFan: 0)!
        XCTAssertEqual(released.command, .auto)
        XCTAssertTrue(released.changed && released.shouldSend)
        XCTAssertFalse(h.step(to: 8, temp: 40).directive(forFan: 0)!.shouldSend, "auto is sent once")
    }

    func testBoostStartsFromTheSpeedTheSystemAlreadyRuns() {
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost([makeRule(60, 100)])),
                        fans: TestFans.inputs(actual: 3000))
        XCTAssertEqual(h.step(to: 0, temp: 70).directive(forFan: 0)?.command, .rpm(3000), "no drop to the minimum first")
        // A system speed above the goal is not cut abruptly either.
        var hot = Harness(policy: policy(mode: .boost, boost: makeBoost([makeRule(60, 35)])),
                          fans: TestFans.inputs(actual: 4500))
        XCTAssertEqual(hot.step(to: 0, temp: 70).directive(forFan: 0)?.command, .rpm(4500))
        let later = hot.step(to: 10, temp: 70).directive(forFan: 0)!
        XCTAssertEqual(later.command, .rpm(RPMMath.validated(4500 - (4500 - 2750) * 10.0 / 20, limits: TestFans.leftLimits)))
    }

    func testPerFanRulesAndLimitsAreHonoured() {
        let rules = [makeRule(60, 50, fan: 0), makeRule(60, 100, fan: 1)]
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost(rules, up: 1)))
        _ = h.step(to: 0, temp: 70)
        let out = h.step(to: 1, temp: 70)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(3350))          // 50% of 1350...5349
        XCTAssertEqual(out.directive(forFan: 1)?.command, .rpm(5777))          // 100% of 1350...5777
    }

    func testAutoMaxJumpsToTheMaximumWhateverThePercent() {
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost([makeRule(60, 35)], usePercent: false, up: 1)))
        _ = h.step(to: 0, temp: 70)
        let out = h.step(to: 1, temp: 70)
        XCTAssertEqual(out.directives.map(\.command), [.rpm(5349), .rpm(5777)])
    }

    func testHysteresisKeepsTheFansSteadyWhileTheTemperatureHoversAroundTheLimit() {
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost([makeRule(70, 100)])), fans: TestFans.inputs(actual: 0))
        var transitionsToAuto = 0
        var wasAuto = true
        var sentAutoAfterStart = 0
        for k in 0..<300 {
            let celsius = k.isMultiple(of: 2) ? 71.0 : 69.0
            let out = h.step(to: Double(k * 2), temp: celsius)
            let isAuto = out.directive(forFan: 0)!.command == .auto
            if isAuto && !wasAuto { transitionsToAuto += 1 }
            wasAuto = isAuto
            if k > 0, out.directive(forFan: 0)!.command == .auto, out.directive(forFan: 0)!.shouldSend { sentAutoAfterStart += 1 }
        }
        XCTAssertEqual(transitionsToAuto, 0)
        XCTAssertEqual(sentAutoAfterStart, 0)
    }

    // MARK: Emergency

    func testEmergencyBypassesTheRampUp() {
        let rules = [makeRule(60, 100)]
        // 92 C on the hot set is within 5 C of the 95 C failsafe: jump straight to the goal.
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost(rules)), fans: TestFans.inputs(actual: 1350))
        let hot = h.step(to: 0, temp: 92)
        XCTAssertTrue(hot.emergency)
        XCTAssertEqual(hot.directives.map(\.command), [.rpm(5349), .rpm(5777)])

        // 85 C is hot but not an emergency: ramped.
        var c = Harness(policy: policy(mode: .boost, boost: makeBoost(rules)), fans: TestFans.inputs(actual: 1350))
        let warm = c.step(to: 0, temp: 85)
        XCTAssertFalse(warm.emergency)
        XCTAssertEqual(warm.directive(forFan: 0)?.command, .rpm(1350))
    }

    func testEmergencyUsesTheHotSetNotTheHighestSensor() {
        let rules = [makeRule(60, 100)]
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost(rules)), fans: TestFans.inputs(actual: 1350))
        // A hot battery sensor alone is not an emergency for the ramp.
        let temps = TemperatureInputs(sampledAt: 0, highest: 96, highestCPU: 70, hotSetMax: 70)
        XCTAssertFalse(h.step(to: 0, temps: temps).emergency)
        var c = Harness(policy: policy(mode: .boost, boost: makeBoost(rules)), fans: TestFans.inputs(actual: 1350))
        XCTAssertTrue(c.step(to: 0, temps: TemperatureInputs(sampledAt: 0, highest: 90, highestCPU: 70, hotSetMax: 90)).emergency)
    }

    func testEmergencyNeverSnapsDownAndLeavesManualAlone() {
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost([makeRule(60, 100)])), fans: TestFans.inputs(actual: 1350))
        _ = h.step(to: 0, temp: 92)                                    // at max
        // Still emergency but the demand disappeared (rule off): falls via the ramp, never snaps.
        h.policy.boost.rules = [makeRule(99, 100)]
        let out = h.step(to: 1, temp: 92)
        XCTAssertEqual(out.directive(forFan: 0)?.command, .rpm(5349))
        XCTAssertTrue(out.directive(forFan: 0)!.isRamping)

        var manual = Harness(policy: { var p = policy(mode: .manual, linkFans: false); p.perFan[0].manualRPM = 2000; return p }())
        XCTAssertEqual(manual.step(to: 0, temp: 94).directive(forFan: 0)?.command, .rpm(2000))
    }

    // MARK: Curve

    func testCurveFollowsTheTemperatureThroughTheRamp() {
        var p = policy(mode: .curve, boost: makeBoost([], up: 2, down: 2, release: 5))
        p.curve = CurveSettings(points: [CurvePoint(tempC: 50, percent: 0), CurvePoint(tempC: 80, percent: 100)],
                                emaAlpha: 1, fallHysteresisC: 3)
        var h = Harness(policy: p, fans: TestFans.inputs(actual: 0))
        XCTAssertEqual(h.step(to: 0, temp: 45).directives.map(\.command), [.auto, .auto], "0% = nothing wanted")
        let start = h.step(to: 1, temp: 65)                           // 50% -> 3350 / 3564
        XCTAssertEqual(start.directive(forFan: 0)?.command, .rpm(1350))
        XCTAssertEqual(start.curvePercent!, 50, accuracy: 1e-9)
        _ = h.step(to: 2, temp: 65)
        let settled = h.step(to: 3, temp: 65)
        XCTAssertEqual(settled.directives.map(\.command), [.rpm(3350), .rpm(3564)])
        // Cools below the curve: falls only after the 3 C hysteresis, then releases to auto.
        XCTAssertEqual(h.step(to: 4, temp: 64).directive(forFan: 0)?.goalRPM, 3350)
        _ = h.step(to: 5, temp: 40)
        _ = h.step(to: 6, temp: 40)
        let low = h.step(to: 7, temp: 40)
        XCTAssertEqual(low.directive(forFan: 0)?.command, .rpm(1350))
        XCTAssertEqual(h.step(to: 11.9, temp: 40).directive(forFan: 0)?.command, .rpm(1350))
        XCTAssertEqual(h.step(to: 12, temp: 40).directive(forFan: 0)?.command, .auto)
    }

    func testCurveAndBoostCanRunOnDifferentFans() {
        var p = Policy(linkFans: false, boost: makeBoost([makeRule(60, 100)], up: 1))
        p.setFanPolicy(FanPolicy(mode: .boost), at: 0)
        p.setFanPolicy(FanPolicy(mode: .curve), at: 1)
        p.curve = CurveSettings(points: [CurvePoint(tempC: 0, percent: 100)], emaAlpha: 1)
        var h = Harness(policy: p, fans: TestFans.inputs(actual: 1350))
        _ = h.step(to: 0, temp: 70)
        let out = h.step(to: 1, temp: 70)
        XCTAssertEqual(out.directives.map(\.command), [.rpm(5349), .rpm(5777)])
    }

    func testSwitchingBoostToCurveKeepsRampingInsteadOfDroppingToAuto() {
        var p = policy(mode: .boost, boost: makeBoost([makeRule(60, 100)], up: 1))
        var h = Harness(policy: p, fans: TestFans.inputs(actual: 1350))
        _ = h.step(to: 0, temp: 70)
        XCTAssertEqual(h.step(to: 1, temp: 70).directive(forFan: 0)?.command, .rpm(5349))
        // Switch to a curve that asks for nothing at this temperature.
        p.setMode(.curve, fanCount: 2)
        p.curve = CurveSettings(points: [CurvePoint(tempC: 0, percent: 0)], emaAlpha: 1)
        h.policy = p
        let out = h.step(to: 2, temp: 70).directive(forFan: 0)!
        XCTAssertEqual(out.command, .rpm(5349))                       // still there, easing down from max
        XCTAssertTrue(out.isRamping)
    }

    // MARK: Mode changes

    func testManualToBoostContinuesFromTheLastCommandedSpeed() {
        var p = policy(mode: .manual, linkFans: false)
        p.perFan[0].manualRPM = 3000
        var h = Harness(policy: p, fans: TestFans.inputs(actual: 0))
        XCTAssertEqual(h.step(to: 0, temp: 70).directive(forFan: 0)?.command, .rpm(3000))
        var b = p
        b.boost = makeBoost([makeRule(60, 35)])
        b.setMode(.boost, fanCount: 2)
        h.policy = b
        XCTAssertEqual(h.step(to: 1, temp: 70).directive(forFan: 0)?.command, .rpm(3000), "no jump to the minimum")
    }

    func testManualToAutoSendsAutoOnceAndBoostToManualResetsTheRamp() {
        var p = policy(mode: .manual, linkFans: false)
        p.perFan[0].manualRPM = 3000
        var h = Harness(policy: p)
        _ = h.step(to: 0, temp: 50)
        h.policy.setMode(.auto, fanCount: 2)
        let auto = h.step(to: 1, temp: 50).directive(forFan: 0)!
        XCTAssertEqual(auto.command, .auto)
        XCTAssertTrue(auto.changed && auto.shouldSend)
        XCTAssertFalse(h.step(to: 2, temp: 50).directive(forFan: 0)!.shouldSend)
    }

    func testMaxToAutoToMaxResendsEachTime() {
        var h = Harness(policy: policy(mode: .max))
        XCTAssertEqual(h.step(to: 0, temp: 50).commandsToSend.count, 2)
        h.policy.setMode(.auto, fanCount: 2)
        XCTAssertEqual(h.step(to: 1, temp: 50).commandsToSend.count, 2)
        h.policy.setMode(.max, fanCount: 2)
        XCTAssertEqual(h.step(to: 2, temp: 50).commandsToSend.count, 2)
    }

    // MARK: Power source

    func testSwitchingPowerSourceDoesNotRestartTheRamp() {
        let adapter = [makeRule(60, 100, source: .adapter)]
        let battery = [makeRule(60, 100, source: .battery)]
        let settings = makeBoost(adapter + battery)
        func run(switchAt: Int?) -> [FanCommand] {
            var h = Harness(policy: policy(mode: .boost, boost: settings), fans: TestFans.inputs(actual: 1350))
            var commands: [FanCommand] = []
            for t in 0...12 {
                if t == switchAt { h.powerSource = .battery }
                commands.append(h.step(to: Double(t), temp: 70).directive(forFan: 0)!.command)
            }
            return commands
        }
        XCTAssertEqual(run(switchAt: 3), run(switchAt: nil), "same goal under the new rule set: the ramp carries on")
        XCTAssertEqual(run(switchAt: 3).last, .rpm(5349))
    }

    func testSwitchingToARuleSetWithANewGoalRedirectsFromTheCurrentSpeed() {
        let settings = makeBoost([makeRule(60, 100, source: .adapter), makeRule(60, 35, source: .battery)])
        var h = Harness(policy: policy(mode: .boost, boost: settings), fans: TestFans.inputs(actual: 1350))
        for t in 0...6 { _ = h.step(to: Double(t), temp: 70) }
        XCTAssertEqual(h.step(to: 7, temp: 70).directive(forFan: 0)?.command, .rpm(5349))
        h.powerSource = .battery
        let out = h.step(to: 8, temp: 70).directive(forFan: 0)!
        XCTAssertEqual(out.command, .rpm(5349), "continues from the current speed, no reset to the minimum")
        XCTAssertEqual(out.goalRPM, 2750)
    }

    // MARK: Send flags

    func testSpeedCommandsAreRefreshedEveryFiveSeconds() {
        var p = policy(mode: .manual, linkFans: false)
        p.perFan[0].manualRPM = 3000
        var h = Harness(policy: p)
        var sendTimes: [Int] = []
        for t in 0...16 where h.step(to: Double(t), temp: 40).directive(forFan: 0)!.shouldSend { sendTimes.append(t) }
        XCTAssertEqual(sendTimes, [0, 5, 10, 15])
        let refresh = h.step(to: 20, temp: 40).directive(forFan: 0)!
        XCTAssertTrue(refresh.shouldSend)
        XCTAssertFalse(refresh.changed)
    }

    func testChangedMeansAtLeastOneRPM() {
        var p = policy(mode: .manual, linkFans: false)
        p.perFan[0].manualRPM = 3000
        var h = Harness(policy: p)
        _ = h.step(to: 0, temp: 40)
        h.policy.perFan[0].manualRPM = 3001
        let out = h.step(to: 1, temp: 40).directive(forFan: 0)!
        XCTAssertTrue(out.changed)
        XCTAssertEqual(out.command, .rpm(3001))
    }

    func testMarkNeedsResendFlagsEverythingOnce() {
        var h = Harness(policy: policy(mode: .max))
        _ = h.step(to: 0, temp: 40)
        XCTAssertTrue(h.step(to: 1, temp: 40).commandsToSend.isEmpty)
        h.controller.markNeedsResend()
        let again = h.step(to: 2, temp: 40)
        XCTAssertEqual(again.commandsToSend.count, 2)
        XCTAssertTrue(again.directives.allSatisfy(\.changed))
        XCTAssertTrue(h.step(to: 3, temp: 40).commandsToSend.isEmpty)

        h.controller.markNeedsResend(fan: 1)
        let one = h.step(to: 4, temp: 40)
        XCTAssertEqual(one.commandsToSend.map(\.fanIndex), [1])
    }

    func testMarkNeedsResendAlsoCoversAnAutoFan() {
        var h = Harness(policy: Policy())
        _ = h.step(to: 0, temp: 40)
        h.controller.markNeedsResend()
        _ = h.step(to: 1, temp: 40)            // fan states exist after the first update
        h.controller.markNeedsResend()
        XCTAssertEqual(h.step(to: 2, temp: 40).commandsToSend.map(\.command), [.auto, .auto])
    }

    func testResetAssumesEveryFanIsInAuto() {
        var h = Harness(policy: policy(mode: .max))
        _ = h.step(to: 0, temp: 40)
        h.controller.reset()                    // e.g. after wake: the app sent `auto all`
        let out = h.step(to: 1, temp: 40)
        XCTAssertEqual(out.commandsToSend.count, 2, "max is sent again from scratch")
    }

    // MARK: Fans that cannot be controlled

    func testMonitorOnlyFansAreNeverCommanded() {
        let dead = FanInfo(index: 0, name: "Fan 1", minRPM: 1350, maxRPM: 5349, backend: .none)
        var h = Harness(policy: policy(mode: .max, fanCount: 1), fans: [FanInput(info: dead, actualRPM: 1000)])
        for t in 0..<10 {
            let out = h.step(to: Double(t), temp: 99)
            XCTAssertEqual(out.directives.map(\.command), [.auto])
            XCTAssertTrue(out.commandsToSend.isEmpty)
        }
    }

    func testFansWithBrokenLimitsAreLeftAlone() {
        let fans = [FanInput(index: 0, limits: FanLimits(min: .nan, max: 5000)),
                    FanInput(index: 1, limits: TestFans.rightLimits)]
        var h = Harness(policy: policy(mode: .max), fans: fans)
        let out = h.step(to: 0, temp: 40)
        XCTAssertEqual(out.directives.map(\.command), [.auto, .rpm(5777)])
    }

    func testNoFansAndDuplicateFanIndices() {
        var h = Harness(policy: policy(mode: .max), fans: [])
        XCTAssertTrue(h.step(to: 0, temp: 40).directives.isEmpty)
        var d = Harness(policy: policy(mode: .max), fans: [FanInput(info: TestFans.left), FanInput(info: TestFans.left)])
        XCTAssertEqual(d.step(to: 0, temp: 40).directives.count, 1)
    }

    func testFansThatDisappearLoseTheirState() {
        var h = Harness(policy: policy(mode: .max))
        _ = h.step(to: 0, temp: 40)
        h.fans = [TestFans.inputs()[1]]
        XCTAssertEqual(h.step(to: 1, temp: 40).directives.map(\.fanIndex), [1])
        h.fans = TestFans.inputs()
        let back = h.step(to: 2, temp: 40)
        XCTAssertEqual(back.commandsToSend.map(\.fanIndex), [0], "fan 0 returns as new and is commanded again")
    }

    // MARK: Lost sensors

    func testBoostFansGoBackToAutoWhenAllSensorsStayDarkTooLong() {
        var h = Harness(policy: policy(mode: .boost, boost: makeBoost([makeRule(60, 100)], up: 1)),
                        fans: TestFans.inputs(actual: 1350))
        _ = h.step(to: 0, temp: 80)
        XCTAssertEqual(h.step(to: 1, temp: 80).directive(forFan: 0)?.command, .rpm(5349))
        // Dark, but not for long: keep what we had.
        XCTAssertEqual(h.step(to: 5, temp: nil).directive(forFan: 0)?.command, .rpm(5349))
        XCTAssertFalse(h.step(to: 10.9, temp: nil).sensorsLost)
        let lost = h.step(to: 15, temp: nil)
        XCTAssertTrue(lost.sensorsLost)
        XCTAssertEqual(lost.directive(forFan: 0)?.command, .auto)
        XCTAssertTrue(lost.directive(forFan: 0)!.changed)
        // Stays released while dark (no flip-flopping).
        for t in 16...30 { XCTAssertEqual(h.step(to: Double(t), temp: nil).directive(forFan: 0)?.command, .auto) }
        // Data returns and it is still hot: control resumes.
        let back = h.step(to: 31, temp: 80)
        XCTAssertFalse(back.sensorsLost)
        XCTAssertNotEqual(back.directive(forFan: 0)?.command, .auto)
    }

    func testManualAndMaxIgnoreMissingSensors() {
        var h = Harness(policy: policy(mode: .max))
        for t in 0..<30 {
            let out = h.step(to: Double(t), temp: nil)
            XCTAssertEqual(out.directives.map(\.command), [.rpm(5349), .rpm(5777)])
        }
    }

    // MARK: Robustness

    func testGarbagePolicyValuesCannotProduceUnsafeSpeeds() {
        var p = policy(mode: .boost, boost: BoostSettings(rules: [makeRule(.nan, 9999), makeRule(-50, -5)],
                                                           hysteresisC: .nan, minHoldSeconds: .infinity,
                                                           rampUpSeconds: .nan, rampDownSeconds: -1,
                                                           releaseDelaySeconds: .nan))
        p.curve = CurveSettings(points: [CurvePoint(tempC: .nan, percent: .infinity)], emaAlpha: .nan, fallHysteresisC: .nan)
        var h = Harness(policy: p, fans: TestFans.inputs(actual: .nan))
        for t in 0..<30 {
            let out = h.step(to: Double(t), temp: 50 + Double(t))
            for d in out.directives { assertSafe(d) }
        }
    }

    /// Random policies, temperatures (including gaps) and power-source flips for a simulated hour.
    /// Invariants: every speed is a finite whole number inside the fan's range, an unchanged
    /// command is never flagged as changed, and the controller never traps.
    func testFuzzedOperationAlwaysStaysInsideTheFanRange() {
        var rng = SeededRNG(seed: 2026)
        for _ in 0..<60 {
            var p = Policy(linkFans: Bool.random(using: &rng))
            for fan in 0..<2 {
                var fp = FanPolicy(mode: ControlMode.allCases.randomElement(using: &rng)!,
                                   manualRPM: Int.random(in: -500...9000, using: &rng),
                                   manualPercent: Double.random(in: -20...130, using: &rng),
                                   manualUnit: Bool.random(using: &rng) ? .rpm : .percent)
                if Bool.random(using: &rng) { fp.manualRPM = 0 }
                p.setFanPolicy(fp, at: fan)
            }
            p.boost = makeBoost((0..<Int.random(in: 0...4, using: &rng)).map { _ in
                makeRule(Double.random(in: 30...95, using: &rng), Int.random(in: 0...100, using: &rng),
                         fan: [nil, 0, 1].randomElement(using: &rng)!,
                         source: Bool.random(using: &rng) ? .adapter : .battery)
            }, hysteresis: Double.random(in: 0...6, using: &rng), hold: Double.random(in: 0...30, using: &rng),
                usePercent: Bool.random(using: &rng), up: Double.random(in: 1...15, using: &rng),
                down: Double.random(in: 1...40, using: &rng), release: Double.random(in: 0...20, using: &rng))
            var h = Harness(policy: p, fans: TestFans.inputs(actual: Double.random(in: 0...6000, using: &rng)))
            var celsius = Double.random(in: 30...90, using: &rng)
            var t = 0.0
            for _ in 0..<600 {
                t += Double.random(in: 0.5...3, using: &rng)
                celsius = Swift.min(Swift.max(celsius + Double.random(in: -4...4, using: &rng), 20), 110)
                if Int.random(in: 0..<40, using: &rng) == 0 { h.powerSource = h.powerSource == .adapter ? .battery : .adapter }
                if Int.random(in: 0..<80, using: &rng) == 0 {
                    h.policy.setMode(ControlMode.allCases.randomElement(using: &rng)!, fanCount: 2)
                }
                let dark = Int.random(in: 0..<15, using: &rng) == 0
                let out = h.step(to: t, temp: dark ? nil : celsius)
                for d in out.directives {
                    assertSafe(d)
                    if d.shouldSend == false { XCTAssertFalse(d.changed) }
                }
            }
        }
    }

    private func assertSafe(_ d: FanDirective, file: StaticString = #filePath, line: UInt = #line) {
        guard case .rpm(let value) = d.command else { return }
        let limits = d.fanIndex == 0 ? TestFans.leftLimits : TestFans.rightLimits
        XCTAssertTrue(value.isFinite, "fan \(d.fanIndex) rpm \(value)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(value, limits.min, file: file, line: line)
        XCTAssertLessThanOrEqual(value, limits.max, file: file, line: line)
        XCTAssertEqual(value, value.rounded(), "whole RPM only", file: file, line: line)
    }
}
