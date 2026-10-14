import FanPilotKit
import FanPilotSensors
import XCTest
@testable import FanPilotHelperCore

final class FailsafeMonitorTests: XCTestCase {
    /// Feeds `FailsafeMonitor.triggerSamples` consecutive hot samples, one second apart starting at
    /// `start`, and returns the transition the last one produced. Every earlier sample must be silent.
    @discardableResult
    private func overheat(_ m: inout FailsafeMonitor, tempC: Double = 96, from start: TimeInterval = 0,
                          controlling: Bool = true,
                          file: StaticString = #filePath, line: UInt = #line) -> FailsafeMonitor.Transition? {
        var last: FailsafeMonitor.Transition?
        for i in 0..<FailsafeMonitor.triggerSamples {
            last = m.update(now: start + TimeInterval(i), hotMax: tempC, controlling: controlling)
            if i < FailsafeMonitor.triggerSamples - 1 {
                XCTAssertNil(last, "hot sample \(i + 1) of \(FailsafeMonitor.triggerSamples) is not enough", file: file, line: line)
            }
        }
        return last
    }

    func testTriggersAtTheThresholdNotBelow() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 94.9, controlling: true))
        XCTAssertNil(m.update(now: 1, hotMax: 94.9, controlling: true), "below the threshold never counts, however often")
        XCTAssertEqual(m.state, .normal)
        XCTAssertNil(m.update(now: 2, hotMax: 95, controlling: true), "the first sample at the threshold is only a candidate")
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.update(now: 3, hotMax: 95, controlling: true), .enteredHot(tempC: 95))
        XCTAssertEqual(m.state, .hot)
        XCTAssertNil(m.update(now: 4, hotMax: 99, controlling: true), "no second transition while hot")
        XCTAssertEqual(m.lastTempC, 99)
    }

    func testClearsAfterTenSecondsBelowTriggerMinusSeven() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertEqual(overheat(&m), .enteredHot(tempC: 96))      // hot at 0 and 1
        XCTAssertNil(m.update(now: 2, hotMax: 87.9, controlling: true))
        XCTAssertNil(m.update(now: 11.9, hotMax: 80, controlling: true))
        XCTAssertEqual(m.update(now: 12, hotMax: 80, controlling: true), .cleared)
        XCTAssertEqual(m.state, .normal)
    }

    func testHysteresisBandRestartsTheClock() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertEqual(overheat(&m), .enteredHot(tempC: 96))      // hot at 0 and 1
        _ = m.update(now: 2, hotMax: 80, controlling: true)
        _ = m.update(now: 10, hotMax: 88, controlling: true)      // exactly trigger - 7 is not below it
        XCTAssertNil(m.update(now: 13, hotMax: 80, controlling: true))
        XCTAssertEqual(m.update(now: 23, hotMax: 80, controlling: true), .cleared)
    }

    func testReheatingWhileClearingStaysHot() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertEqual(overheat(&m), .enteredHot(tempC: 96))      // hot at 0 and 1
        _ = m.update(now: 2, hotMax: 80, controlling: true)
        XCTAssertNil(m.update(now: 6, hotMax: 96, controlling: true))
        XCTAssertNil(m.update(now: 13, hotMax: 80, controlling: true), "the clock restarted at 13, not 2")
        XCTAssertEqual(m.state, .hot)
    }

    // MARK: Confirmation: one hot sample is not an overheat

    func testASingleHotSpikeFollowedByANormalSampleNeverTrips() {
        // The incident from /var/log/fanpilot.log: TCMb read 99.5 C once while the cores sat near 54 C.
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 54, controlling: true))
        XCTAssertNil(m.update(now: 1, hotMax: 99.5, controlling: true))
        XCTAssertEqual(m.state, .normal)
        XCTAssertNil(m.update(now: 2, hotMax: 54, controlling: true))
        XCTAssertEqual(m.state, .normal)
        XCTAssertFalse(m.status.active)

        // However often it recurs, as long as no two spikes are adjacent.
        for t in stride(from: 3.0, to: 40, by: 2) {
            XCTAssertNil(m.update(now: t, hotMax: 99.5, controlling: true))
            XCTAssertNil(m.update(now: t + 1, hotMax: 54, controlling: true))
        }
        XCTAssertEqual(m.state, .normal)
        XCTAssertFalse(m.status.active)
    }

    func testASpikeFollowedBySampleInTheBandBelowTheTriggerDoesNotCount() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 96, controlling: true))
        XCTAssertNil(m.update(now: 1, hotMax: 90, controlling: true), "below the trigger breaks the streak even inside the hysteresis band")
        XCTAssertNil(m.update(now: 2, hotMax: 96, controlling: true), "so this is a first sample again")
        XCTAssertEqual(m.state, .normal)
    }

    func testTwoConsecutiveHotSamplesTrip() {
        XCTAssertEqual(FailsafeMonitor.triggerSamples, 2)
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 96, controlling: true))
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.update(now: 1, hotMax: 99.5, controlling: true), .enteredHot(tempC: 99.5), "reports the confirming sample")
        XCTAssertEqual(m.state, .hot)
        XCTAssertTrue(m.isHot)
        XCTAssertTrue(m.status.active)
        XCTAssertEqual(m.status.reason, "hot_sensor")
        XCTAssertEqual(m.lastTempC, 99.5)
        XCTAssertNil(m.update(now: 2, hotMax: 99.5, controlling: true), "reported once")
    }

    func testTwoHotSamplesTripWhateverTheFirstOneWasCalledFor() {
        // Not controlling anything yet (an idle client): the failsafe still watches and still needs two.
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 97, controlling: false))
        XCTAssertEqual(m.update(now: 5, hotMax: 97, controlling: false), .enteredHot(tempC: 97), "consecutive samples need not be one second apart")
    }

    func testAMissingSampleBetweenTwoHotSamplesResetsTheStreak() {
        for controlling in [true, false] {
            var m = FailsafeMonitor(triggerC: 95)
            XCTAssertNil(m.update(now: 0, hotMax: 98, controlling: controlling))
            XCTAssertNil(m.update(now: 1, hotMax: nil, controlling: controlling), "a gap is not a hot sample")
            XCTAssertNil(m.update(now: 2, hotMax: 98, controlling: controlling), "...and it forgot the first one")
            XCTAssertEqual(m.state, .normal, "controlling = \(controlling)")
            XCTAssertEqual(m.update(now: 3, hotMax: 98, controlling: controlling), .enteredHot(tempC: 98),
                           "hot, gap, hot, hot: the last two are consecutive")
        }
    }

    func testAGapDoesNotLetAStreakCrossABlindRecovery() {
        var m = FailsafeMonitor(triggerC: 95)
        _ = m.update(now: 0, hotMax: 99, controlling: true)
        _ = m.update(now: 1, hotMax: nil, controlling: true)
        _ = m.update(now: 11, hotMax: nil, controlling: true)       // blind
        XCTAssertEqual(m.state, .blind)
        XCTAssertEqual(m.update(now: 12, hotMax: 99, controlling: true), .recoveredFromBlind, "the sample from before the gap does not count")
        XCTAssertEqual(m.update(now: 13, hotMax: 99, controlling: true), .enteredHot(tempC: 99))
    }

    func testBlindAfterTenSecondsWithoutATemperatureWhileControlling() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: nil, controlling: true))
        XCTAssertNil(m.update(now: 9.9, hotMax: nil, controlling: true))
        XCTAssertEqual(m.update(now: 10, hotMax: nil, controlling: true), .enteredBlind)
        XCTAssertTrue(m.isBlind)
        XCTAssertTrue(m.status.active)
        XCTAssertEqual(m.status.reason, "blind")
        XCTAssertNil(m.update(now: 11, hotMax: nil, controlling: true), "reported once")
        XCTAssertEqual(m.update(now: 12, hotMax: 50, controlling: true), .recoveredFromBlind)
        XCTAssertEqual(m.state, .normal)
    }

    func testNotControllingNeverGoesBlind() {
        var m = FailsafeMonitor(triggerC: 95)
        for t in stride(from: 0.0, through: 60, by: 5) {
            XCTAssertNil(m.update(now: t, hotMax: nil, controlling: false))
        }
        XCTAssertEqual(m.state, .normal)
    }

    func testAGlitchShorterThanTenSecondsIsForgotten() {
        var m = FailsafeMonitor(triggerC: 95)
        _ = m.update(now: 0, hotMax: nil, controlling: true)
        _ = m.update(now: 8, hotMax: nil, controlling: true)
        _ = m.update(now: 9, hotMax: 50, controlling: true)
        XCTAssertNil(m.update(now: 12, hotMax: nil, controlling: true))
        XCTAssertNil(m.update(now: 21, hotMax: nil, controlling: true), "the 10 s clock restarted at 12")
        XCTAssertEqual(m.update(now: 22, hotMax: nil, controlling: true), .enteredBlind)
    }

    func testBlindWhileHotAlsoCounts() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertEqual(overheat(&m, tempC: 99, controlling: false), .enteredHot(tempC: 99))   // hot at 0 and 1
        XCTAssertNil(m.update(now: 2, hotMax: nil, controlling: false))
        XCTAssertEqual(m.update(now: 12, hotMax: nil, controlling: false), .enteredBlind)
    }

    func testBlindWithASingleHotSampleAndNothingHeldIsIgnored() {
        // One unconfirmed hot sample does not make the failsafe "hot", so with no fan held there is
        // nothing at stake while blind.
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 99, controlling: false))
        XCTAssertNil(m.update(now: 1, hotMax: nil, controlling: false))
        XCTAssertNil(m.update(now: 11, hotMax: nil, controlling: false))
        XCTAssertEqual(m.state, .normal)
    }

    func testHotAfterBlindRecoveryTriggersOnTheSecondSample() {
        var m = FailsafeMonitor(triggerC: 95)
        _ = m.update(now: 0, hotMax: nil, controlling: true)
        _ = m.update(now: 10, hotMax: nil, controlling: true)
        XCTAssertEqual(m.update(now: 11, hotMax: 99, controlling: true), .recoveredFromBlind)
        XCTAssertEqual(m.update(now: 12, hotMax: 99, controlling: true), .enteredHot(tempC: 99))
    }

    func testTriggerIsForcedIntoTheSafeRange() {
        XCTAssertEqual(FailsafeMonitor(triggerC: 150).triggerC, 100)
        XCTAssertEqual(FailsafeMonitor(triggerC: 40).triggerC, 85)
        XCTAssertEqual(FailsafeMonitor(triggerC: .nan).triggerC, 95)
        XCTAssertEqual(FailsafeMonitor(triggerC: 90).triggerC, 90)
    }

    func testResetForgetsEverything() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertEqual(overheat(&m, tempC: 99), .enteredHot(tempC: 99))
        m.reset()
        XCTAssertEqual(m.state, .normal)
        XCTAssertNil(m.lastTempC)
        XCTAssertFalse(m.status.active)
    }

    func testHotSamplesCloserTogetherThanTheSpacingAreOneObservation() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 99.5, controlling: false))
        XCTAssertNil(m.update(now: 0, hotMax: 99.5, controlling: false), "the same instant read again")
        XCTAssertNil(m.update(now: 0.2, hotMax: 99.5, controlling: false), "a few milliseconds or tenths later")
        XCTAssertEqual(m.state, .normal)
        XCTAssertTrue(m.isConfirming)
        XCTAssertEqual(m.update(now: 0.5, hotMax: 99.5, controlling: false), .enteredHot(tempC: 99.5),
                       "measured from the last counted sample, not the last one seen")
    }

    func testACloseSampleNeitherExtendsNorBreaksTheStreak() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 99, controlling: true))
        XCTAssertNil(m.update(now: 0.4, hotMax: 99, controlling: true))
        XCTAssertEqual(m.update(now: 0.9, hotMax: 99, controlling: true), .enteredHot(tempC: 99),
                       "0.9 s after the counted sample at 0, even though 0.5 s after the one at 0.4")
    }

    func testACloseCoolSampleStillBreaksTheStreak() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 99, controlling: true))
        XCTAssertNil(m.update(now: 0.1, hotMax: 54, controlling: true))
        XCTAssertFalse(m.isConfirming)
        XCTAssertNil(m.update(now: 1, hotMax: 99, controlling: true), "a first sample again")
    }

    func testAStaleStreakIsForgottenSoTwoIsolatedSpikesNeverPair() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 99.5, controlling: false))
        // Nothing samples for six hours (no client, no timer), then one lone spike on the next look.
        XCTAssertNil(m.update(now: 6 * 3600, hotMax: 99.5, controlling: false), "the old sample is history")
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.update(now: 6 * 3600 + 1, hotMax: 99.5, controlling: false), .enteredHot(tempC: 99.5),
                       "a genuine second sample after the new first one still confirms")
    }

    func testTheConfirmationWindowEndsJustAfterTwoIdlePeriods() {
        var inside = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(inside.update(now: 0, hotMax: 99, controlling: false))
        XCTAssertEqual(inside.update(now: FailsafeMonitor.maxConfirmGapSeconds, hotMax: 99, controlling: false),
                       .enteredHot(tempC: 99), "exactly at the limit still counts")

        var outside = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(outside.update(now: 0, hotMax: 99, controlling: false))
        XCTAssertNil(outside.update(now: FailsafeMonitor.maxConfirmGapSeconds + 0.1, hotMax: 99, controlling: false))
        XCTAssertEqual(outside.state, .normal)
        XCTAssertGreaterThan(FailsafeMonitor.maxConfirmGapSeconds, 2 * HelperEngine.idleTickSeconds - 1,
                             "the idle sampling period (one confirmation per tick) must fit inside the window")
    }

    func testAClockThatWentBackwardsStartsANewStreak() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 100, hotMax: 99, controlling: true))
        XCTAssertNil(m.update(now: 50, hotMax: 99, controlling: true))
        XCTAssertEqual(m.state, .normal)
    }

    func testIsConfirmingOnlyWhileAHotSampleAwaitsItsAnswer() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertFalse(m.isConfirming)
        _ = m.update(now: 0, hotMax: 99, controlling: true)
        XCTAssertTrue(m.isConfirming)
        _ = m.update(now: 1, hotMax: 99, controlling: true)
        XCTAssertEqual(m.state, .hot)
        XCTAssertFalse(m.isConfirming, "answered: it is hot")
        _ = m.update(now: 2, hotMax: 99, controlling: true)
        XCTAssertFalse(m.isConfirming)

        var spike = FailsafeMonitor(triggerC: 95)
        _ = spike.update(now: 0, hotMax: 99, controlling: true)
        _ = spike.update(now: 1, hotMax: 50, controlling: true)
        XCTAssertFalse(spike.isConfirming, "answered: it was a spike")

        var gap = FailsafeMonitor(triggerC: 95)
        _ = gap.update(now: 0, hotMax: 99, controlling: true)
        _ = gap.update(now: 1, hotMax: nil, controlling: true)
        XCTAssertFalse(gap.isConfirming, "a missing sample ends the streak")
    }

    func testForgetPendingConfirmationKeepsTheStateButDropsTheStreak() {
        var m = FailsafeMonitor(triggerC: 95)
        _ = m.update(now: 0, hotMax: 99, controlling: true)
        m.forgetPendingConfirmation()
        XCTAssertFalse(m.isConfirming)
        XCTAssertNil(m.update(now: 1, hotMax: 99, controlling: true))

        var hot = FailsafeMonitor(triggerC: 95)
        XCTAssertEqual(overheat(&hot, tempC: 99), .enteredHot(tempC: 99))
        hot.forgetPendingConfirmation()
        XCTAssertEqual(hot.state, .hot, "a failsafe that is already on stays on")
    }

    func testResetForgetsAHalfBuiltStreak() {
        var m = FailsafeMonitor(triggerC: 95)
        XCTAssertNil(m.update(now: 0, hotMax: 99, controlling: true))
        m.reset()   // a new session (connection open or close) starts from scratch
        XCTAssertNil(m.update(now: 1, hotMax: 99, controlling: true), "the pre-reset sample no longer counts")
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.update(now: 2, hotMax: 99, controlling: true), .enteredHot(tempC: 99))
    }
}

final class HotSetReaderTests: XCTestCase {
    private func smcWithSensors() -> InMemorySMC {
        let smc = InMemorySMC()
        func t(_ key: FourCC, _ v: Float) { smc.setFloat(key, v, attributes: 0x85) }
        t("Tp04", 51)        // CPU core
        t("Tm04", 52)        // CPU / memory cluster
        t("Tg08", 49)        // GPU
        t("TCMb", 48)        // SoC
        t("TVD0", 53)        // SoC rail
        t("TCHP", 99)        // charger: NOT part of the hot set
        t("TB0T", 98)        // battery: not
        t("Ts0P", 97)        // palm rest: not
        t("TH0a", 96)        // SSD: not
        t("Ta00", 95)        // airflow: not
        t("TW0P", 94)        // wireless: not
        t("TVMX", 99)        // limit-like constant (reads 61 on the M5 Pro): not a die temperature
        t("ftRf", 99)        // same
        smc.set("TG0B", type: .ioft, attributes: 0x85, bytes: [UInt8](repeating: 0, count: 8))
        smc.set("TVMD", type: .flt, attributes: 0x85, bytes: SMCCodec.encodeFloat(4.0))     // sentinel
        return smc
    }

    func testClassifierPrefixes() {
        for key in ["Tp04", "Te05", "Tm0G", "Tg08", "TCMb", "TC0P", "TG0P", "TVD0", "TPD0", "TRD1", "TUD2"] {
            XCTAssertTrue(SMCHotSetReader.isHotKey(key), key)
        }
        for key in ["TCHP", "TPSP", "TB0T", "Ts0P", "TH0a", "Ta00", "TW0P", "TN00", "FNum", "F0Tg", "Tf10", "TTPD"] {
            XCTAssertFalse(SMCHotSetReader.isHotKey(key), key)
        }
    }

    func testReadsTheHottestOfTheHotSetOnly() {
        let reader = SMCHotSetReader(smc: smcWithSensors(), includeHID: false)
        reader.refresh()
        let reading = reader.read()
        XCTAssertEqual(reading.maxTempC ?? 0, 53, accuracy: 0.001, "charger, battery, palm rest, SSD ... must not count")
        XCTAssertEqual(reading.hottest, "TVD0")
        XCTAssertEqual(reading.sensorCount, 5)
        XCTAssertEqual(Set(reader.sensorKeys.map(\.string)), ["Tp04", "Tm04", "Tg08", "TCMb", "TVD0"])
    }

    func testOutOfRangeHotReadingsStillCount() {
        let smc = smcWithSensors()
        smc.setFloat("Tp04", 131, attributes: 0x85)
        let reader = SMCHotSetReader(smc: smc, includeHID: false)
        reader.refresh()
        XCTAssertEqual(reader.read().maxTempC ?? 0, 131, accuracy: 0.001)
    }

    func testLargeKeyFamiliesAreSampledEvenly() {
        let keys: [FourCC] = (0..<40).map { FourCC("Tm\(String(format: "%02d", $0))")! }
        let picked = SMCHotSetReader.sampled(keys, limit: 12)
        XCTAssertEqual(picked.count, 12)
        XCTAssertEqual(picked.first, "Tm00")
        XCTAssertEqual(picked.last, "Tm39", "the last key is always included")
        XCTAssertEqual(Set(picked).count, 12)
        XCTAssertEqual(SMCHotSetReader.sampled(Array(keys.prefix(5)), limit: 12), Array(keys.prefix(5)), "small families are read completely")

        let smc = InMemorySMC()
        for key in keys { smc.setFloat(key, 40, attributes: 0x85) }
        let reader = SMCHotSetReader(smc: smc, includeHID: false)
        reader.refresh()
        XCTAssertEqual(reader.sensorKeys.count, 12)
    }

    func testSentinelsAndGarbageAreIgnored() {
        XCTAssertNil(SMCHotSetReader.usableTemperature(4.0))
        XCTAssertNil(SMCHotSetReader.usableTemperature(0))
        XCTAssertNil(SMCHotSetReader.usableTemperature(-9200))
        XCTAssertNil(SMCHotSetReader.usableTemperature(.nan))
        XCTAssertNil(SMCHotSetReader.usableTemperature(.infinity))
        XCTAssertNil(SMCHotSetReader.usableTemperature(3.4e38))
        XCTAssertNotNil(SMCHotSetReader.usableTemperature(10))
        XCTAssertNotNil(SMCHotSetReader.usableTemperature(130))
    }

    func testBlindWhenNothingIsReadable() {
        let reader = SMCHotSetReader(smc: InMemorySMC(), includeHID: false)
        reader.refresh()
        let reading = reader.read()
        XCTAssertNil(reading.maxTempC)
        XCTAssertEqual(reading.sensorCount, 0)
    }

    func testCompositeTakesTheHotterProviderAndIsBlindOnlyIfAllAre() {
        let cool = StubHotSet(50)
        let hot = StubHotSet(70)
        let blind = StubHotSet(nil)
        XCTAssertEqual(CompositeHotSetProvider([cool, hot]).read().maxTempC, 70)
        XCTAssertEqual(CompositeHotSetProvider([cool, blind]).read().maxTempC, 50)
        XCTAssertNil(CompositeHotSetProvider([blind, StubHotSet(nil)]).read().maxTempC)
        let composite = CompositeHotSetProvider([cool, hot])
        composite.refresh()
        XCTAssertEqual(cool.refreshCount, 1)
        XCTAssertEqual(hot.refreshCount, 1)
    }

    func testSensorsBackedProviderOnAFixture() {
        // The FanPilotSensors engine on an in-memory M5-like SMC reports a hot-set maximum.
        let smc = smcWithSensors()
        let provider = SensorsHotSetProvider(smc: smc,
                                             hardware: HardwareInfo(model: "Mac17,8", isAppleSilicon: true,
                                                                    perfLevels: [PerfLevel(name: "Super", physicalCPUs: 6),
                                                                                 PerfLevel(name: "Performance", physicalCPUs: 12)]))
        provider.refresh()
        let reading = provider.read()
        XCTAssertNotNil(reading.maxTempC)
        XCTAssertGreaterThanOrEqual(reading.maxTempC ?? 0, 51, "at least the CPU core sensor is in the hot set")
        XCTAssertLessThan(reading.maxTempC ?? 0, 94, "battery, palm rest, SSD, airflow and wireless are not")
    }
}

final class FailsafeTestModeTests: XCTestCase {
    func testFloorCanBeLoweredOnlyExplicitly() {
        XCTAssertEqual(FailsafeMonitor(triggerC: 60).triggerC, 85, "the default floor protects against a bad config")
        XCTAssertEqual(FailsafeMonitor(triggerC: 60, floorC: 40).triggerC, 60)
        XCTAssertEqual(FailsafeMonitor(triggerC: 20, floorC: 40).triggerC, 40)
        XCTAssertEqual(FailsafeMonitor(triggerC: 500, floorC: 40).triggerC, 100, "never above 100 C")
    }

    func testEngineTestModeTripsEarlyAndOnlyEarlier() {
        let h = EngineHarness(hot: StubHotSet(61), config: HelperConfig(allowedUIDs: [501], failsafeTempC: 95), start: false)
        XCTAssertEqual(h.engine.config.failsafeTempC, 95)

        let lowered = HelperEngine(smc: h.smc, hotSet: h.hot, config: HelperConfig(allowedUIDs: [501], failsafeTempC: 95),
                                   failsafeTestC: 60, clock: { h.clock.now }, sleep: { _ in })
        lowered.start()
        lowered.connectionOpened(1)
        guard case .hello(let hello) = lowered.handle(WireRequest(id: 1, command: .hello(proto: 1, client: "t")), from: 1).reply.body else {
            return XCTFail()
        }
        XCTAssertEqual(hello.failsafeTempC, 60)
        lowered.tick()   // the idle client's first look at the hot set: 61 C, one sample, no trip yet
        XCTAssertFalse(lowered.failsafeStatus.active, "one hot sample is only a candidate")
        h.clock.advance(1)   // the takeover's own look must be a separate sample, not the same instant again
        let reply = lowered.handle(WireRequest(id: 2, command: .set(fan: 0, rpm: 2000, ttl: nil)), from: 1).reply
        XCTAssertEqual(reply.err, .failsafeActive, "61 C trips a 60 C test failsafe on the second sample, before the takeover")
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)

        // A "test" value above the configured one is ignored: the option can only make the failsafe stricter.
        let ignored = HelperEngine(smc: MockSMC.appleSilicon(), hotSet: StubHotSet(50), config: HelperConfig(allowedUIDs: [501], failsafeTempC: 90),
                                   failsafeTestC: 99, clock: { 0 }, sleep: { _ in })
        ignored.connectionOpened(1)
        guard case .hello(let h2) = ignored.handle(WireRequest(id: 1, command: .hello(proto: 1, client: "t")), from: 1).reply.body else {
            return XCTFail()
        }
        XCTAssertEqual(h2.failsafeTempC, 90)
    }

    func testOptionParsing() throws {
        XCTAssertEqual(try HelperOptions.parse(["--failsafe-test", "60"]).failsafeTestC, 60)
        XCTAssertNil(try HelperOptions.parse([]).failsafeTestC)
        for bad in ["39", "101", "abc", "nan"] {
            XCTAssertThrowsError(try HelperOptions.parse(["--failsafe-test", bad]), bad)
        }
    }
}
