import XCTest
import FanPilotKit
@testable import FanPilotControl

final class ManualPolicyEditingTests: XCTestCase {
    func testSliderMoveWithLinkMovesBothFansByNormalizedPosition() {
        var p = Policy(linkFans: true)
        p.applyManualRPM(2000, forFan: 0, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 2000)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 2070)                       // 16.25% of 1350...5777
        XCTAssertEqual(p.fanPolicy(at: 0).manualPercent, 16.25, accuracy: 0.01)
        XCTAssertEqual(p.fanPolicy(at: 1).manualPercent, 16.25, accuracy: 0.02)

        // Moving the other slider moves the first one back.
        p.applyManualRPM(3000, forFan: 1, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 3000)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 2840)
    }

    func testSliderMoveWithoutLinkTouchesOnlyThatFan() {
        var p = Policy(linkFans: false)
        p.applyManualRPM(4000, forFan: 1, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 4000)
        XCTAssertEqual(p.fanPolicy(at: 0), FanPolicy())
    }

    func testPercentEntryStoresTheExactPercentAndTheRPM() {
        var p = Policy(linkFans: true)
        p.applyManualPercent(0, forFan: 0, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 1350, "0% is the minimum")
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 1350)
        p.applyManualPercent(50, forFan: 0, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 3350)
        XCTAssertEqual(p.fanPolicy(at: 0).manualPercent, 50)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 3564)
        p.applyManualPercent(500, forFan: 0, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualPercent, 100)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 5349)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 5777)
    }

    func testOutOfRangeRPMIsClampedAndModesAndUnitsAreUntouched() {
        var p = Policy(perFan: [FanPolicy(mode: .boost, manualUnit: .percent), FanPolicy(mode: .max)], linkFans: true)
        p.applyManualRPM(99_999, forFan: 0, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 5349)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 5777)
        XCTAssertEqual(p.fanPolicy(at: 0).mode, .boost)
        XCTAssertEqual(p.fanPolicy(at: 1).mode, .max)
        XCTAssertEqual(p.fanPolicy(at: 0).manualUnit, .percent)
        p.applyManualRPM(1, forFan: 0, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 1350)
    }

    func testUnknownFanIsIgnored() {
        var p = Policy()
        p.applyManualRPM(3000, forFan: 5, fans: TestFans.both)
        p.applyManualPercent(50, forFan: -1, fans: TestFans.both)
        XCTAssertEqual(p, Policy())
    }

    func testFansWithBrokenLimitsAreSkipped() {
        let broken = FanInfo(index: 1, name: "Fan 2", minRPM: 0, maxRPM: 0, backend: .none)
        var p = Policy(linkFans: true)
        p.applyManualRPM(3000, forFan: 0, fans: [TestFans.left, broken])
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 3000)
        XCTAssertEqual(p.perFan.count, 1)
        var q = Policy()
        q.applyManualRPM(3000, forFan: 1, fans: [TestFans.left, broken])
        XCTAssertEqual(q, Policy())
    }

    func testRelinkSnapsTheOtherFansToTheFirstFan() {
        var p = Policy(perFan: [FanPolicy(mode: .manual, manualRPM: 2000), FanPolicy(mode: .manual, manualRPM: 5000)],
                       linkFans: false)
        p.relinkManualFans(fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 5000, "nothing happens while the link is off")
        p.linkFans = true
        p.relinkManualFans(fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 2000)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 2070)
        // Another leader.
        p.perFan[1].manualRPM = 3000
        p.relinkManualFans(leader: 1, fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualRPM, 2840)
        XCTAssertEqual(p.fanPolicy(at: 1).manualRPM, 3000)
    }

    func testRelinkKeepsAPercentLeaderExact() {
        var p = Policy(perFan: [FanPolicy(mode: .manual, manualPercent: 33.3, manualUnit: .percent), FanPolicy()],
                       linkFans: true)
        p.relinkManualFans(fans: TestFans.both)
        XCTAssertEqual(p.fanPolicy(at: 0).manualPercent, 33.3)
        XCTAssertEqual(p.fanPolicy(at: 1).manualPercent, 33.3, accuracy: 0.02)
    }

    func testManualTargetRPMReadsTheActiveUnit() {
        let l = TestFans.leftLimits
        XCTAssertEqual(FanPolicy(manualRPM: 3000, manualPercent: 99, manualUnit: .rpm).manualTargetRPM(limits: l), 3000)
        XCTAssertEqual(FanPolicy(manualRPM: 3000, manualPercent: 100, manualUnit: .percent).manualTargetRPM(limits: l), 5349)
        XCTAssertEqual(FanPolicy(manualRPM: 0, manualUnit: .rpm).manualTargetRPM(limits: l), 1350)
        XCTAssertEqual(FanPolicy(manualRPM: -50, manualUnit: .rpm).manualTargetRPM(limits: l), 1350)
        XCTAssertEqual(FanPolicy(manualPercent: 0, manualUnit: .percent).manualTargetRPM(limits: l), 1350)
    }
}
