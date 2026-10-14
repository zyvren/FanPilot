import XCTest
import FanPilotKit
@testable import FanPilotControl

final class RPMMathTests: XCTestCase {
    private let left = TestFans.leftLimits     // 1350 ... 5349
    private let right = TestFans.rightLimits   // 1350 ... 5777

    func testPercentZeroIsTheMinimumNeverOff() {
        XCTAssertEqual(RPMMath.rpm(forPercent: 0, limits: left), 1350)
        XCTAssertEqual(RPMMath.rpm(forPercent: 0, limits: right), 1350)
    }

    func testPercentHundredIsTheMaximum() {
        XCTAssertEqual(RPMMath.rpm(forPercent: 100, limits: left), 5349)
        XCTAssertEqual(RPMMath.rpm(forPercent: 100, limits: right), 5777)
    }

    func testPercentMapsLinearlyAndRoundsToWholeRPM() {
        XCTAssertEqual(RPMMath.rpm(forPercent: 50, limits: left), 3350)    // 3349.5 rounds up
        XCTAssertEqual(RPMMath.rpm(forPercent: 25, limits: left), 2350)    // 2349.75
        XCTAssertEqual(RPMMath.rpm(forPercent: 65, limits: left), 3949)    // 3949.35
        XCTAssertEqual(RPMMath.rpm(forPercent: 35, limits: left), 2750)    // 2749.65
    }

    func testPercentOutsideRangeAndNaNAreClamped() {
        XCTAssertEqual(RPMMath.rpm(forPercent: -20, limits: left), 1350)
        XCTAssertEqual(RPMMath.rpm(forPercent: 250, limits: left), 5349)
        XCTAssertEqual(RPMMath.rpm(forPercent: .nan, limits: left), 1350)
    }

    func testClampAndValidated() {
        XCTAssertEqual(RPMMath.clamp(100, to: left), 1350)
        XCTAssertEqual(RPMMath.clamp(9999, to: left), 5349)
        XCTAssertEqual(RPMMath.clamp(3000, to: left), 3000)
        XCTAssertEqual(RPMMath.clamp(.nan, to: left), 1350)
        XCTAssertEqual(RPMMath.clamp(.infinity, to: left), 5349)
        XCTAssertEqual(RPMMath.clamp(-.infinity, to: left), 1350)
        XCTAssertEqual(RPMMath.validated(2000.4, limits: left), 2000)
        XCTAssertEqual(RPMMath.validated(2000.5, limits: left), 2001)
        XCTAssertEqual(RPMMath.validated(7000, limits: left), 5349)
    }

    func testPercentOfRPMIsTheInverse() {
        XCTAssertEqual(RPMMath.percent(forRPM: 1350, limits: left), 0, accuracy: 1e-9)
        XCTAssertEqual(RPMMath.percent(forRPM: 5349, limits: left), 100, accuracy: 1e-9)
        XCTAssertEqual(RPMMath.percent(forRPM: 3349.5, limits: left), 50, accuracy: 1e-9)
        XCTAssertEqual(RPMMath.percent(forRPM: 0, limits: left), 0, accuracy: 1e-9)       // below min clamps
        XCTAssertEqual(RPMMath.percent(forRPM: 9000, limits: left), 100, accuracy: 1e-9)  // above max clamps
        for p in stride(from: 0.0, through: 100.0, by: 5.0) {
            let rpm = RPMMath.rpm(forPercent: p, limits: right)
            XCTAssertEqual(RPMMath.percent(forRPM: rpm, limits: right), p, accuracy: 0.02, "percent \(p)")
        }
    }

    // MARK: Link mapping across fans with different ranges

    func testLinkMapsEndpointsToEndpoints() {
        XCTAssertEqual(RPMMath.linkedRPM(1350, from: left, to: right), 1350)
        XCTAssertEqual(RPMMath.linkedRPM(5349, from: left, to: right), 5777)
        XCTAssertEqual(RPMMath.linkedRPM(5777, from: right, to: left), 5349)
        XCTAssertEqual(RPMMath.linkedRPM(1350, from: right, to: left), 1350)
    }

    func testLinkKeepsNormalizedPosition() {
        // Midpoint of 1350...5349 is 3349.5, i.e. the midpoint of 1350...5777 is 3563.5 -> 3564.
        XCTAssertEqual(RPMMath.linkedRPM(3349.5, from: left, to: right), 3564)
        // 2000 is 16.25% of the left range; the same position on the right is 2069.57.
        XCTAssertEqual(RPMMath.linkedRPM(2000, from: left, to: right), 2070)
        // 3000 is 37.27% of the right range; on the left that is 2840.48.
        XCTAssertEqual(RPMMath.linkedRPM(3000, from: right, to: left), 2840)
    }

    func testLinkToSameRangeIsIdentity() {
        for rpm in stride(from: 1350.0, through: 5349.0, by: 111.0) {
            XCTAssertEqual(RPMMath.linkedRPM(rpm, from: left, to: left), rpm)
        }
    }

    func testLinkClampsOutOfRangeInput() {
        XCTAssertEqual(RPMMath.linkedRPM(100, from: left, to: right), 1350)
        XCTAssertEqual(RPMMath.linkedRPM(99999, from: left, to: right), 5777)
        XCTAssertEqual(RPMMath.linkedRPM(.nan, from: left, to: right), 1350)
    }

    func testDegenerateRangesAreSafe() {
        let broken = FanLimits(min: 2000, max: 2000)
        XCTAssertFalse(broken.isUsable)
        XCTAssertEqual(RPMMath.rpm(forPercent: 80, limits: broken), 2000)
        XCTAssertEqual(RPMMath.fraction(forRPM: 2000, limits: broken), 0)
        XCTAssertEqual(RPMMath.linkedRPM(3000, from: broken, to: left), 1350)
        XCTAssertFalse(FanLimits(min: .nan, max: 5000).isUsable)
        XCTAssertFalse(FanLimits(min: 3000, max: 2000).isUsable)
        XCTAssertTrue(left.isUsable)
    }
}
