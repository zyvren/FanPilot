import XCTest
import FanPilotKit
@testable import FanPilotControl

final class BoostEngineTests: XCTestCase {
    private func evaluate(_ engine: inout BoostEngine, _ settings: BoostSettings, temp celsius: Double,
                          at now: TimeInterval, source: PowerSource = .adapter,
                          fans: [Int] = [0, 1]) -> BoostEvaluation {
        engine.evaluate(settings: settings, powerSource: source, temps: temp(celsius, at: now),
                        fanIndices: fans, now: now)
    }

    // MARK: Trigger

    func testRuleFiresOnlyStrictlyAboveTheLimit() {
        var engine = BoostEngine()
        let settings = makeBoost([makeRule(70, 100)])
        XCTAssertTrue(evaluate(&engine, settings, temp: 69.99, at: 0).goals.isEmpty)
        XCTAssertTrue(evaluate(&engine, settings, temp: 70.0, at: 1).goals.isEmpty, "equal is not above")
        let fired = evaluate(&engine, settings, temp: 70.01, at: 2)
        XCTAssertEqual(fired.goals[0]?.percent, 100)
        XCTAssertEqual(fired.goals[1]?.percent, 100)
    }

    func testFloatsAreNotTruncatedToIntegers() {
        // 70.9 would truncate to 70 and not fire; the fraction is kept.
        var engine = BoostEngine()
        XCTAssertNotNil(evaluate(&engine, makeBoost([makeRule(70, 100)]), temp: 70.9, at: 0).goals[0])
    }

    // MARK: Hysteresis and hold

    func testRuleStaysActiveInsideTheHysteresisBand() {
        var engine = BoostEngine()
        let settings = makeBoost([makeRule(70, 65)], hysteresis: 3, hold: 0)
        XCTAssertNotNil(evaluate(&engine, settings, temp: 71, at: 0).goals[0])
        XCTAssertNotNil(evaluate(&engine, settings, temp: 69, at: 2).goals[0])
        XCTAssertNotNil(evaluate(&engine, settings, temp: 67.01, at: 4).goals[0])
        XCTAssertNil(evaluate(&engine, settings, temp: 67.0, at: 6).goals[0], "release needs strictly > limit - hysteresis")
        XCTAssertNil(evaluate(&engine, settings, temp: 69, at: 8).goals[0], "re-arming needs the limit again")
        XCTAssertNotNil(evaluate(&engine, settings, temp: 70.5, at: 10).goals[0])
    }

    func testMinimumHoldKeepsTheRuleEvenWhenCold() {
        var engine = BoostEngine()
        let settings = makeBoost([makeRule(70, 65)], hysteresis: 3, hold: 15)
        XCTAssertNotNil(evaluate(&engine, settings, temp: 71, at: 100).goals[0])
        XCTAssertNotNil(evaluate(&engine, settings, temp: 30, at: 105).goals[0])
        XCTAssertNotNil(evaluate(&engine, settings, temp: 30, at: 114.9).goals[0])
        XCTAssertNil(evaluate(&engine, settings, temp: 30, at: 115).goals[0], "hold is over after exactly 15 s")
    }

    func testHoldIsMeasuredFromActivationNotFromTheLastHotSample() {
        var engine = BoostEngine()
        let settings = makeBoost([makeRule(70, 65)], hysteresis: 3, hold: 15)
        _ = evaluate(&engine, settings, temp: 71, at: 0)
        _ = evaluate(&engine, settings, temp: 75, at: 10)               // hotter later does not extend the hold
        XCTAssertNil(evaluate(&engine, settings, temp: 40, at: 15).goals[0], "hold ran out 15 s after the FIRST hot sample")
    }

    func testOscillationAroundTheThresholdDoesNotFlap() {
        var engine = BoostEngine()
        let settings = makeBoost([makeRule(70, 65)], hysteresis: 3, hold: 15)
        var transitions = 0
        var wasActive = false
        for k in 0..<200 {                                              // 400 s of 2 s ticks
            let celsius = k.isMultiple(of: 2) ? 71.0 : 69.0              // straddles the 70 C limit
            let active = evaluate(&engine, settings, temp: celsius, at: Double(k) * 2).goals[0] != nil
            if active != wasActive { transitions += 1 }
            wasActive = active
        }
        XCTAssertEqual(transitions, 1, "fires once and stays on")

        // The same input without hysteresis and hold chatters on and off: the test is sensitive.
        var naive = BoostEngine()
        let bare = makeBoost([makeRule(70, 65)], hysteresis: 0, hold: 0)
        var naiveTransitions = 0
        wasActive = false
        for k in 0..<200 {
            let celsius = k.isMultiple(of: 2) ? 71.0 : 69.0
            let active = evaluate(&naive, bare, temp: celsius, at: Double(k) * 2).goals[0] != nil
            if active != wasActive { naiveTransitions += 1 }
            wasActive = active
        }
        XCTAssertGreaterThan(naiveTransitions, 100)
    }

    func testOscillatingAcrossSeveralDefaultRulesKeepsOneStableWinner() {
        var engine = BoostEngine()
        let settings = BoostSettings()                                  // 58/35, 70/65, 82/100
        var percents: [Double] = []
        for k in 0..<100 {
            let celsius = k.isMultiple(of: 2) ? 70.6 : 69.4
            let eval = evaluate(&engine, settings, temp: celsius, at: Double(k))
            percents.append(eval.goals[0]?.percent ?? -1)
        }
        // First sample (70.6) fires both the 58 and 70 rules; the winner never changes after.
        XCTAssertEqual(Set(percents), [65])
    }

    func testStaircaseDownThroughTheDefaultRules() {
        var engine = BoostEngine()
        let settings = BoostSettings()
        XCTAssertEqual(evaluate(&engine, settings, temp: 57, at: 0).goals[0]?.percent, nil)
        XCTAssertEqual(evaluate(&engine, settings, temp: 59, at: 1).goals[0]?.percent, 35)
        XCTAssertEqual(evaluate(&engine, settings, temp: 71, at: 2).goals[0]?.percent, 65)
        XCTAssertEqual(evaluate(&engine, settings, temp: 83, at: 3).goals[0]?.percent, 100)
        // Cools to 78: the 100% rule releases once its 15 s hold is over (below 82 - 3 = 79).
        XCTAssertEqual(evaluate(&engine, settings, temp: 78, at: 10).goals[0]?.percent, 100, "still inside the hold")
        XCTAssertEqual(evaluate(&engine, settings, temp: 78, at: 19).goals[0]?.percent, 65)
        XCTAssertEqual(evaluate(&engine, settings, temp: 50, at: 40).goals[0]?.percent, nil)
    }

    // MARK: Winner selection

    func testHighestPercentWinsRegardlessOfRuleOrder() {
        var engine = BoostEngine()
        let low = makeRule(60, 40), high = makeRule(60, 80), mid = makeRule(60, 60)
        let eval = evaluate(&engine, makeBoost([mid, high, low]), temp: 65, at: 0)
        XCTAssertEqual(eval.goals[0]?.percent, 80)
        XCTAssertEqual(eval.goals[0]?.ruleID, high.id)
        XCTAssertEqual(eval.activeRuleIDs, [mid.id, high.id, low.id])
    }

    func testTiesKeepTheEarlierRuleInArrayOrder() {
        let a = makeRule(60, 50), b = makeRule(55, 50)
        var engine = BoostEngine()
        XCTAssertEqual(evaluate(&engine, makeBoost([a, b]), temp: 65, at: 0).goals[0]?.ruleID, a.id)
        var swapped = BoostEngine()
        XCTAssertEqual(evaluate(&swapped, makeBoost([b, a]), temp: 65, at: 0).goals[0]?.ruleID, b.id)
    }

    func testTieDoesNotMoveWhenTheEarlierRuleStopsAndRestarts() {
        // Only the order in the array matters, not who fired first.
        let a = makeRule(70, 50), b = makeRule(60, 50)
        var engine = BoostEngine()
        let settings = makeBoost([a, b], hysteresis: 0, hold: 0)
        XCTAssertEqual(evaluate(&engine, settings, temp: 65, at: 0).goals[0]?.ruleID, b.id)   // only b fires
        XCTAssertEqual(evaluate(&engine, settings, temp: 75, at: 1).goals[0]?.ruleID, a.id)   // both: a is first
    }

    func testFanSpecificRulesOnlyApplyToTheirFan() {
        var engine = BoostEngine()
        let all = makeRule(60, 30)
        let onlyFan1 = makeRule(60, 90, fan: 1)
        let eval = evaluate(&engine, makeBoost([all, onlyFan1]), temp: 65, at: 0)
        XCTAssertEqual(eval.goals[0]?.percent, 30)
        XCTAssertEqual(eval.goals[1]?.percent, 90)

        var engine2 = BoostEngine()
        let eval2 = evaluate(&engine2, makeBoost([onlyFan1]), temp: 65, at: 0)
        XCTAssertNil(eval2.goals[0])
        XCTAssertNotNil(eval2.goals[1])
        // A rule for a fan that does not exist is harmless.
        var engine3 = BoostEngine()
        XCTAssertTrue(evaluate(&engine3, makeBoost([makeRule(60, 90, fan: 7)]), temp: 65, at: 0).goals.isEmpty)
    }

    func testAutoMaxIgnoresThePercent() {
        var engine = BoostEngine()
        let a = makeRule(60, 35), b = makeRule(50, 50)
        let eval = evaluate(&engine, makeBoost([a, b], usePercent: false), temp: 65, at: 0)
        XCTAssertEqual(eval.goals[0]?.percent, 100)
        XCTAssertEqual(eval.goals[0]?.ruleID, a.id, "all 100%: the first rule keeps the tie")
        var quiet = BoostEngine()
        XCTAssertTrue(evaluate(&quiet, makeBoost([a], usePercent: false), temp: 40, at: 0).goals.isEmpty)
    }

    // MARK: Power source

    func testOnlyTheRulesOfTheCurrentPowerSourceAreEvaluated() {
        var engine = BoostEngine()
        let mains = makeRule(60, 40, source: .adapter), battery = makeRule(60, 80, source: .battery)
        let settings = makeBoost([mains, battery])
        XCTAssertEqual(evaluate(&engine, settings, temp: 65, at: 0, source: .adapter).goals[0]?.ruleID, mains.id)
        XCTAssertEqual(evaluate(&engine, settings, temp: 65, at: 1, source: .battery).goals[0]?.ruleID, battery.id)
        let batteryOnly = makeBoost([battery])
        var other = BoostEngine()
        XCTAssertTrue(evaluate(&other, batteryOnly, temp: 99, at: 0, source: .adapter).goals.isEmpty)
    }

    func testRulesOutsideTheCurrentSetStartCleanWhenTheyReturn() {
        var engine = BoostEngine()
        let mains = makeRule(70, 60, source: .adapter)
        let settings = makeBoost([mains], hysteresis: 3, hold: 0)
        XCTAssertNotNil(evaluate(&engine, settings, temp: 75, at: 0, source: .adapter).goals[0])
        XCTAssertTrue(evaluate(&engine, settings, temp: 75, at: 1, source: .battery).goals.isEmpty)
        XCTAssertFalse(engine.isActive(mains.id))
        // 68 would have kept an active rule alive (inside the band) but the rule is no longer active.
        XCTAssertNil(evaluate(&engine, settings, temp: 68, at: 2, source: .adapter).goals[0])
    }

    // MARK: Sensors and disabled rules

    func testDisabledRulesNeverFire() {
        var engine = BoostEngine()
        XCTAssertTrue(evaluate(&engine, makeBoost([makeRule(10, 100, enabled: false)]), temp: 90, at: 0).goals.isEmpty)
    }

    func testRulesLookAtTheirOwnSensorSelector() {
        let temps = TemperatureInputs(sampledAt: 0, computerAverage: 50, highest: 80, averageCPU: 60,
                                      highestCPU: 72, sensors: ["smc:Ts0P": 45, "smc:TH0a": 38])
        func fires(_ selector: SensorSelector, limit: Double) -> Bool {
            var engine = BoostEngine()
            let rule = makeRule(limit, 50, sensor: selector)
            return !engine.evaluate(settings: makeBoost([rule]), powerSource: .adapter, temps: temps,
                                    fanIndices: [0], now: 0).goals.isEmpty
        }
        XCTAssertTrue(fires(.highest, limit: 75))
        XCTAssertFalse(fires(.highest, limit: 85))
        XCTAssertFalse(fires(.averageCPU, limit: 65))
        XCTAssertTrue(fires(.averageCPU, limit: 55))
        XCTAssertTrue(fires(.highestCPU, limit: 70))
        XCTAssertFalse(fires(.computerAverage, limit: 55))
        XCTAssertTrue(fires(.sensor("smc:Ts0P"), limit: 40))
        XCTAssertFalse(fires(.sensor("smc:TH0a"), limit: 40))
        XCTAssertFalse(fires(.sensor("smc:Gone"), limit: 0), "a missing sensor never triggers a rule")
    }

    func testUnreadableTemperatureFreezesRuleState() {
        var engine = BoostEngine()
        let rule = makeRule(70, 65)
        let settings = makeBoost([rule, makeRule(90, 100)], hysteresis: 3, hold: 5)
        XCTAssertNotNil(evaluate(&engine, settings, temp: 75, at: 0).goals[0])
        // Everything goes dark for a long time: the active rule stays, the quiet one stays quiet.
        for t in stride(from: 10.0, through: 200, by: 10) {
            let eval = engine.evaluate(settings: settings, powerSource: .adapter, temps: .none,
                                       fanIndices: [0], now: t)
            XCTAssertEqual(eval.goals[0]?.ruleID, rule.id)
            XCTAssertEqual(eval.goals[0]?.percent, 65)
        }
        // Readings return and it is cold: now it releases.
        XCTAssertNil(evaluate(&engine, settings, temp: 40, at: 210).goals[0])
    }

    func testRuleReleasesWhenOnlyItsOwnSensorGoesSilent() {
        var engine = BoostEngine()
        let rule = BoostRule(sensor: .sensor("smc:TB0T"), limitC: 70, percent: 100)
        let settings = makeBoost([rule], hysteresis: 3, hold: 5)
        func temps(_ sensor: Double?) -> TemperatureInputs {
            // Other sensors keep reporting (highest = 50); only the rule's own sensor can vanish.
            TemperatureInputs(highest: 50, sensors: sensor.map { ["smc:TB0T": $0] } ?? [:])
        }
        XCTAssertNotNil(engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(80),
                                        fanIndices: [0], now: 0).goals[0])
        // The sensor vanishes: still held for a few seconds, then released.
        XCTAssertNotNil(engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(nil),
                                        fanIndices: [0], now: 5).goals[0])
        XCTAssertNotNil(engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(nil),
                                        fanIndices: [0], now: 14).goals[0])
        XCTAssertNil(engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(nil),
                                     fanIndices: [0], now: 16).goals[0], "silent for more than 10 s")
        XCTAssertFalse(engine.isActive(rule.id))
    }

    func testASensorThatComesBackBeforeTheLimitKeepsItsRule() {
        var engine = BoostEngine()
        let rule = BoostRule(sensor: .sensor("smc:TB0T"), limitC: 70, percent: 100)
        let settings = makeBoost([rule], hysteresis: 3, hold: 5)
        func temps(_ sensor: Double?) -> TemperatureInputs {
            TemperatureInputs(highest: 50, sensors: sensor.map { ["smc:TB0T": $0] } ?? [:])
        }
        _ = engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(80), fanIndices: [0], now: 0)
        _ = engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(nil), fanIndices: [0], now: 8)
        _ = engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(80), fanIndices: [0], now: 9)
        XCTAssertNotNil(engine.evaluate(settings: settings, powerSource: .adapter, temps: temps(nil),
                                        fanIndices: [0], now: 18).goals[0], "the silence timer restarted when the sensor returned")
    }

    func testResetClearsEverything() {
        var engine = BoostEngine()
        let rule = makeRule(70, 65)
        _ = evaluate(&engine, makeBoost([rule]), temp: 80, at: 0)
        XCTAssertTrue(engine.isActive(rule.id))
        engine.reset()
        XCTAssertFalse(engine.isActive(rule.id))
    }

    func testCorruptSettingsAreNormalized() {
        var engine = BoostEngine()
        var rule = makeRule(70, 500)                                    // percent out of range
        rule.limitC = .nan
        let settings = makeBoost([rule, makeRule(60, 80)], hysteresis: .nan, hold: -5)
        let eval = evaluate(&engine, settings, temp: 65, at: 0)
        XCTAssertEqual(eval.goals[0]?.percent, 80)
    }
}
