import XCTest
import FanPilotKit
@testable import FanPilotControl

final class CurveEngineTests: XCTestCase {
    private let points = [CurvePoint(tempC: 50, percent: 0), CurvePoint(tempC: 60, percent: 40),
                          CurvePoint(tempC: 80, percent: 100)]

    private func settings(alpha: Double = 1, fall: Double = 3, points: [CurvePoint]? = nil,
                          source: SensorSelector = .highestCPU) -> CurveSettings {
        CurveSettings(source: source, points: points ?? self.points, emaAlpha: alpha, fallHysteresisC: fall)
    }

    // MARK: Interpolation

    func testInterpolationIsLinearBetweenPoints() {
        XCTAssertEqual(CurveEngine.percent(at: 55, points: points), 20, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.percent(at: 60, points: points), 40, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.percent(at: 70, points: points), 70, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.percent(at: 65, points: points), 55, accuracy: 1e-9)
    }

    func testCurveIsFlatOutsideThePoints() {
        XCTAssertEqual(CurveEngine.percent(at: -20, points: points), 0)
        XCTAssertEqual(CurveEngine.percent(at: 50, points: points), 0)
        XCTAssertEqual(CurveEngine.percent(at: 80, points: points), 100)
        XCTAssertEqual(CurveEngine.percent(at: 120, points: points), 100)
    }

    func testPointsMayBeUnsortedAndSinglePointIsConstant() {
        XCTAssertEqual(CurveEngine.percent(at: 70, points: points.reversed()), 70, accuracy: 1e-9)
        let single = [CurvePoint(tempC: 60, percent: 33)]
        XCTAssertEqual(CurveEngine.percent(at: 10, points: single), 33)
        XCTAssertEqual(CurveEngine.percent(at: 99, points: single), 33)
        XCTAssertEqual(CurveEngine.percent(at: 99, points: []), 0)
    }

    func testDuplicateTemperatureMakesAStep() {
        let step = [CurvePoint(tempC: 50, percent: 20), CurvePoint(tempC: 70, percent: 20),
                    CurvePoint(tempC: 70, percent: 80), CurvePoint(tempC: 90, percent: 80)]
        XCTAssertEqual(CurveEngine.percent(at: 69.9, points: step), 20, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.percent(at: 70, points: step), 20, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.percent(at: 70.1, points: step), 80, accuracy: 1e-9)
    }

    func testKneeLookup() {
        let sorted = CurveSettings(points: points).sortedPoints
        XCTAssertEqual(CurveEngine.lowestTemperature(reaching: 70, sortedPoints: sorted), 70, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.lowestTemperature(reaching: 100, sortedPoints: sorted), 80, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.lowestTemperature(reaching: 40, sortedPoints: sorted), 60, accuracy: 1e-9)
        XCTAssertEqual(CurveEngine.lowestTemperature(reaching: 0, sortedPoints: sorted), 50, accuracy: 1e-9)
    }

    // MARK: Smoothing

    func testFirstSampleSeedsTheAverageThenFollowsAlpha() {
        var engine = CurveEngine()
        let s = settings(alpha: 0.3)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(50, at: 0)).smoothedTempC, 50)
        let second = engine.evaluate(settings: s, temps: temp(80, at: 2))
        XCTAssertEqual(second.smoothedTempC!, 50 + 0.3 * 30, accuracy: 1e-9)          // 59
        let third = engine.evaluate(settings: s, temps: temp(80, at: 4))
        XCTAssertEqual(third.smoothedTempC!, 59 + 0.3 * 21, accuracy: 1e-9)           // 65.3
    }

    func testRepeatedCallsWithTheSameSampleDoNotAdvanceTheAverage() {
        var engine = CurveEngine()
        let s = settings(alpha: 0.3)
        _ = engine.evaluate(settings: s, temps: temp(50, at: 0))
        let a = engine.evaluate(settings: s, temps: temp(80, at: 2))
        let b = engine.evaluate(settings: s, temps: temp(80, at: 2))
        let c = engine.evaluate(settings: s, temps: temp(80, at: 2))
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    // MARK: Output hysteresis

    func testOutputRisesImmediately() {
        var engine = CurveEngine()
        let s = settings()
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(55, at: 0)).percent!, 20, accuracy: 1e-9)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(70, at: 1)).percent!, 70, accuracy: 1e-9)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(71, at: 2)).percent!, 73, accuracy: 1e-9)
    }

    func testOutputFallsOnlyOnceThreeDegreesBelowTheLevel() {
        var engine = CurveEngine()
        let s = settings(fall: 3)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(70, at: 0)).percent!, 70, accuracy: 1e-9)
        let at68 = engine.evaluate(settings: s, temps: temp(68, at: 1))
        XCTAssertEqual(at68.percent!, 70, accuracy: 1e-9)
        XCTAssertTrue(at68.isHolding)
        XCTAssertEqual(at68.rawPercent!, 64, accuracy: 1e-9)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(67.01, at: 2)).percent!, 70, accuracy: 1e-9)
        let at66 = engine.evaluate(settings: s, temps: temp(66.9, at: 3))
        XCTAssertEqual(at66.percent!, 60.7, accuracy: 1e-9)
        XCTAssertFalse(at66.isHolding)
    }

    func testNoFlapWhenTheTemperatureHoversAtOneLevel() {
        var engine = CurveEngine()
        let s = settings(alpha: 0.3, fall: 3)
        var outputs: [Double] = []
        for k in 0..<200 {
            let celsius = 70 + (k.isMultiple(of: 2) ? 1.5 : -1.5)
            outputs.append(engine.evaluate(settings: s, temps: temp(celsius, at: Double(k))).percent!)
        }
        // After the first 10 samples the EMA has settled around 70; the output only ever rises.
        let tail = Array(outputs.dropFirst(10))
        XCTAssertEqual(tail, tail.sorted(), "never falls while the temperature hovers")
        XCTAssertLessThan(tail.last! - tail.first!, 6)
    }

    func testHysteresisIsRelativeToTheKneeOnAPlateau() {
        // Above 80 C the curve is flat at 100%. Falling is judged from the knee at 80, not from
        // the hottest temperature seen.
        var engine = CurveEngine()
        let s = settings(fall: 3)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(95, at: 0)).percent, 100)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(79, at: 1)).percent, 100)          // held
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(77.01, at: 2)).percent, 100)       // held
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(76.9, at: 3)).percent!, 100 - 3.1 * 3, accuracy: 1e-9)
    }

    func testFirstPointAtZeroPercentEndsAtZero() {
        var engine = CurveEngine()
        let s = settings()
        _ = engine.evaluate(settings: s, temps: temp(70, at: 0))
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(40, at: 1)).percent, 0)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(30, at: 2)).percent, 0)
    }

    // MARK: Sources and missing data

    func testChangingTheSourceStartsFresh() {
        var engine = CurveEngine()
        let temps = TemperatureInputs(sampledAt: 0, highest: 90, highestCPU: 50)
        XCTAssertEqual(engine.evaluate(settings: settings(source: .highest), temps: temps).smoothedTempC, 90)
        var later = temps
        later.sampledAt = 1
        XCTAssertEqual(engine.evaluate(settings: settings(source: .highestCPU), temps: later).smoothedTempC, 50)
    }

    func testNoTemperatureYieldsNoOutputThenHoldsTheLastOne() {
        var engine = CurveEngine()
        let s = settings()
        XCTAssertNil(engine.evaluate(settings: s, temps: .none).percent)
        XCTAssertEqual(engine.evaluate(settings: s, temps: temp(70, at: 1)).percent!, 70, accuracy: 1e-9)
        XCTAssertEqual(engine.evaluate(settings: s, temps: .none).percent!, 70, accuracy: 1e-9)
    }

    func testEmptyPointsFallBackToTheDefaultCurve() {
        var engine = CurveEngine()
        let out = engine.evaluate(settings: CurveSettings(points: []), temps: temp(70, at: 0))
        XCTAssertEqual(out.percent!, 65, accuracy: 1e-9)              // default curve: 70 C -> 65%
    }
}
