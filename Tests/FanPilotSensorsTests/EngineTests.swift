import FanPilotKit
import XCTest
@testable import FanPilotSensors

final class SensorEngineTests: XCTestCase {
    func testFirstRefreshPreparesAndGroupsByArea() throws {
        let engine = Fixtures.engine()
        let snapshot = engine.refresh()

        XCTAssertEqual(snapshot.sequence, 1)
        XCTAssertEqual(snapshot.catalogModel, "Mac17,8")
        XCTAssertEqual(snapshot.groups.map(\.area), [.cpu, .gpu, .soc, .battery, .storage, .airflow, .power,
                                                    .thunderbolt, .palmRest, .wireless, .other])
        XCTAssertEqual(snapshot.groups.first?.readings.count, 18)
        XCTAssertTrue(snapshot.readings.filter { $0.sensor.area != .other }.allSatisfy(\.valid))
        XCTAssertEqual(snapshot.fans.count, 2)
        XCTAssertEqual(snapshot.fanInfos.map(\.name), ["Left Side", "Right Side"])
        XCTAssertEqual(snapshot.readings.map(\.id), engine.sensors.map(\.id), "readings follow the plan order")

        let agg = snapshot.aggregates
        XCTAssertNotNil(agg.computerAverage)
        XCTAssertGreaterThanOrEqual(agg.highestCPU ?? 0, agg.averageCPU ?? 100)
        XCTAssertGreaterThan(agg.hotSetValidCount, 30)
        XCTAssertEqual(snapshot.value(for: .highestCPU), agg.highestCPU)
    }

    func testSessionMaxTracksPeaksAndResets() {
        let smc = Fixtures.m5ProSMC()
        let engine = Fixtures.engine(smc: smc)
        _ = engine.refresh()
        Fixtures.setTemp(smc, "Tp04", 80)
        var snapshot = engine.refresh()
        XCTAssertEqual(snapshot.sessionMax["smc:Tp04"] ?? 0, 80, accuracy: 0.001)

        Fixtures.setTemp(smc, "Tp04", 45)
        snapshot = engine.refresh()
        XCTAssertEqual(snapshot.reading(id: "smc:Tp04")?.value ?? 0, 45, accuracy: 0.001)
        XCTAssertEqual(snapshot.sessionMax["smc:Tp04"] ?? 0, 80, accuracy: 0.001, "max keeps the peak")

        engine.resetSessionMax()
        snapshot = engine.refresh()
        XCTAssertEqual(snapshot.sessionMax["smc:Tp04"] ?? 0, 45, accuracy: 0.001)
    }

    func testInvalidReadingIsNAButKeepsRawValueForTheFailsafe() {
        let smc = Fixtures.m5ProSMC()
        let engine = Fixtures.engine(smc: smc)
        _ = engine.refresh()
        Fixtures.setTemp(smc, "Tm0G", 131)
        Fixtures.setTemp(smc, "Tp0G", 0)
        let snapshot = engine.refresh()

        let hot = snapshot.reading(id: "smc:Tm0G")
        XCTAssertEqual(hot?.valid, false)
        XCTAssertEqual(hot?.value, 131)
        XCTAssertEqual(snapshot.reading(id: "smc:Tp0G")?.valid, false)
        XCTAssertEqual(snapshot.aggregates.hotSetMax, 131)
        XCTAssertLessThan(snapshot.aggregates.highestCPU ?? 999, 100, "display aggregates ignore N/A readings")
        XCTAssertLessThan(snapshot.sessionMax["smc:Tm0G"] ?? 0, 100, "an invalid reading never raises the session max")
    }

    func testSensorThatDisappearsBecomesUnavailableNotRemoved() {
        let smc = Fixtures.m5ProSMC()
        let engine = Fixtures.engine(smc: smc)
        let before = engine.refresh().readings.count
        smc.remove("TB1T")
        let snapshot = engine.refresh()
        XCTAssertEqual(snapshot.readings.count, before)
        XCTAssertEqual(snapshot.reading(id: "smc:TB1T")?.valid, false)
    }

    func testRevalidateAddsNewlyValidSensorsAndKeepsShownOnes() throws {
        let smc = Fixtures.m5ProSMC()
        Fixtures.setTemp(smc, "Tm0G", 0)               // invalid at the start
        let engine = Fixtures.engine(smc: smc)
        try engine.prepare()
        XCTAssertFalse(engine.sensors.contains { $0.key == "Tm0G" })

        Fixtures.setTemp(smc, "Tm0G", 44)
        Fixtures.setTemp(smc, "Tp04", 0)               // goes bad later
        engine.revalidate()
        XCTAssertTrue(engine.sensors.contains { $0.key == "Tm0G" }, "now valid, so it appears")
        XCTAssertTrue(engine.sensors.contains { $0.key == "Tp04" }, "shown sensors stay while N/A")
    }

    func testReenumerateFindsNewKeys() throws {
        let smc = Fixtures.m5ProSMC()
        let engine = Fixtures.engine(smc: smc)
        try engine.prepare()
        XCTAssertFalse(engine.sensors.contains { $0.key == "TVD9" })
        Fixtures.setTemp(smc, "TVD9", 52)
        try engine.reenumerate()
        XCTAssertTrue(engine.sensors.contains { $0.key == "TVD9" })
    }

    // MARK: Polling policy

    func testDefaultPolicyCarriesOtherAndHIDBetweenRefreshes() {
        let smc = CountingSMC(Fixtures.m5ProSMC())
        final class HIDCalls: @unchecked Sendable { var count = 0 }
        let hidCalls = HIDCalls()
        let engine = SensorEngine(smc: smc, hardware: Fixtures.m5Pro, policy: PollingPolicy(), hidProvider: { _ in
            hidCalls.count += 1
            return Fixtures.m5ProHID()
        })
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let first = engine.refresh(now: t0)
        let sensorCount = first.readings.filter { $0.sensor.source == .smc }.count
        XCTAssertGreaterThan(sensorCount, 40)
        let afterFirst = hidCalls.count

        smc.resetCounts()
        let second = engine.refresh(now: t0.addingTimeInterval(2))
        XCTAssertEqual(hidCalls.count, afterFirst, "HID was read by the first refresh; 2 s later it is not due yet")
        XCTAssertEqual(smc.reads(of: "Tp04"), 1, "curated sensors are read on every refresh")
        XCTAssertEqual(smc.reads(of: "Ta00"), 0, "an unwatched Other sensor is carried over")
        XCTAssertLessThan(smc.totalReads, 90, "a quiet refresh touches the curated sensors, the watch list and the fans only")
        XCTAssertEqual(second.readings.map(\.id), first.readings.map(\.id))
        XCTAssertEqual(second.reading(id: "smc:Ta00")?.value, first.reading(id: "smc:Ta00")?.value)

        _ = engine.refresh(now: t0.addingTimeInterval(4))
        XCTAssertEqual(hidCalls.count, afterFirst + 1, "HID is due every 4 s")

        smc.resetCounts()
        _ = engine.refresh(now: t0.addingTimeInterval(10.1))
        XCTAssertEqual(smc.reads(of: "Ta00"), 1, "the Other group is re-read every 10 s")

        smc.resetCounts()
        _ = engine.refresh(now: t0.addingTimeInterval(11), full: true)
        XCTAssertEqual(smc.reads(of: "Ta00"), 1, "full: true reads everything")
    }

    func testPrioritySensorsAreReadOnEveryRefreshWhateverTheirGroup() {
        let smc = CountingSMC(Fixtures.m5ProSMC())
        final class HIDCalls: @unchecked Sendable { var count = 0 }
        let hidCalls = HIDCalls()
        let engine = SensorEngine(smc: smc, hardware: Fixtures.m5Pro, policy: PollingPolicy(), hidProvider: { _ in
            hidCalls.count += 1
            return Fixtures.m5ProHID()
        })
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let first = engine.refresh(now: t0)
        let hidSensor = first.readings.first { $0.sensor.source == .hid }!.id
        engine.setPriorityIDs(["smc:Ta00", hidSensor])

        smc.resetCounts()
        let calls = hidCalls.count
        _ = engine.refresh(now: t0.addingTimeInterval(2))
        XCTAssertEqual(smc.reads(of: "Ta00"), 1, "a chosen Other sensor follows the update interval, not the 10 s Other pass")
        XCTAssertEqual(hidCalls.count, calls + 1, "a chosen HID sensor forces an HID pass every refresh")

        engine.setPriorityIDs([])
        smc.resetCounts()
        _ = engine.refresh(now: t0.addingTimeInterval(4.5))
        XCTAssertEqual(smc.reads(of: "Ta00"), 0, "without priority it is carried over again")
    }

    func testHottestOtherSensorsAreWatchedEveryRefresh() {
        let backing = Fixtures.m5ProSMC()
        let smc = CountingSMC(backing)
        let engine = Fixtures.engine(smc: smc, policy: PollingPolicy(otherInterval: 60, hidInterval: 60, watchedOtherCount: 3))
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        Fixtures.setTemp(backing, "TVD0", 69)
        Fixtures.setTemp(backing, "TCMb", 64)
        Fixtures.setTemp(backing, "TPD0", 63)
        _ = engine.refresh(now: t0)

        smc.resetCounts()
        Fixtures.setTemp(backing, "TVD0", 91)
        let snapshot = engine.refresh(now: t0.addingTimeInterval(2))
        XCTAssertEqual(smc.reads(of: "TVD0"), 1)
        XCTAssertEqual(smc.reads(of: "TCMb"), 1)
        XCTAssertEqual(smc.reads(of: "TPD0"), 1)
        XCTAssertEqual(smc.reads(of: "Ta00"), 0)
        XCTAssertEqual(snapshot.aggregates.hotSetMax ?? 0, 91, accuracy: 0.001, "the hottest Other sensor stays live for the failsafe")
        XCTAssertEqual(snapshot.aggregates.hotSetMaxSensorID, "smc:TVD0")
    }

    func testEngineNeverWrites() {
        let smc = Fixtures.m5ProSMC()
        let engine = Fixtures.engine(smc: smc)
        for _ in 0..<3 { _ = engine.refresh() }
        try? engine.reenumerate()
        engine.revalidate()
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testEmptySMCGivesEmptySnapshot() {
        let engine = SensorEngine(smc: InMemorySMC(), hardware: Fixtures.m5Pro, hidProvider: { _ in [] })
        let snapshot = engine.refresh()
        XCTAssertTrue(snapshot.readings.isEmpty)
        XCTAssertTrue(snapshot.fans.isEmpty)
        XCTAssertNil(snapshot.aggregates.highest)
        XCTAssertEqual(snapshot.averageFanRPM, nil)
    }

    func testHIDProviderReceivesCatalogHIDNames() {
        final class Box: @unchecked Sendable { var wanted: Set<String> = [] }
        let box = Box()
        let hardware = HardwareInfo(model: "MacBookPro17,1", isAppleSilicon: true,
                                    perfLevels: [PerfLevel(name: "Performance", physicalCPUs: 4)])
        let engine = SensorEngine(smc: InMemorySMC(), hardware: hardware, hidProvider: { wanted in
            box.wanted = wanted
            return [HIDSample(name: "PMU tdev7", value: 45)]
        })
        _ = engine.refresh()
        XCTAssertTrue(box.wanted.contains("PMU tdev7"), "catalog-listed HID names are protected from the generic drop rules")
        XCTAssertTrue(engine.sensors.contains { $0.key == "PMU tdev7" })
    }
}

final class SensorMonitorTests: XCTestCase {
    private func makeMonitor(smc: InMemorySMC = Fixtures.m5ProSMC(), wakePause: TimeInterval = 0.2) -> SensorMonitor {
        SensorMonitor(engine: Fixtures.engine(smc: smc),
                      configuration: .init(interval: 1, revalidateInterval: 600, wakePause: wakePause, callbackQueue: nil))
    }

    func testDeliversSnapshotsPeriodicallyAndStops() {
        let monitor = makeMonitor()
        let received = expectation(description: "two snapshots")
        received.expectedFulfillmentCount = 2
        monitor.onSnapshot = { _ in received.fulfill() }
        XCTAssertNil(monitor.latest)
        monitor.start()
        wait(for: [received], timeout: 5)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertNotNil(monitor.latest)
        XCTAssertGreaterThanOrEqual(monitor.latest?.sequence ?? 0, 2)

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        Thread.sleep(forTimeInterval: 0.3) // let a poll that was already running finish
        let sequence = monitor.latest?.sequence
        Thread.sleep(forTimeInterval: 1.3)
        XCTAssertEqual(monitor.latest?.sequence, sequence, "no polling after stop")
    }

    func testStopFromInsideTheCallbackDoesNotDeadlock() {
        let monitor = makeMonitor()
        let stopped = expectation(description: "stopped from callback")
        stopped.assertForOverFulfill = false
        monitor.onSnapshot = { [unowned monitor] _ in
            monitor.stop() // callbackQueue is nil here, so this runs on the monitor's own queue
            stopped.fulfill()
        }
        monitor.start()
        wait(for: [stopped], timeout: 5)
        XCTAssertFalse(monitor.isRunning)
    }

    func testIntervalIsClamped() {
        let monitor = makeMonitor()
        monitor.setInterval(0.01)
        XCTAssertEqual(monitor.currentInterval, 1)
        monitor.setInterval(500)
        XCTAssertEqual(monitor.currentInterval, 60)
        monitor.setInterval(.nan)
        XCTAssertEqual(monitor.currentInterval, 1)
        monitor.setInterval(5)
        XCTAssertEqual(monitor.currentInterval, 5)
    }

    func testRefreshNowPollsOffSchedule() {
        let monitor = makeMonitor()
        let first = expectation(description: "snapshot")
        first.assertForOverFulfill = false
        monitor.onSnapshot = { _ in first.fulfill() }
        monitor.refreshNow()
        wait(for: [first], timeout: 5)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(monitor.latest?.sequence, 1)
    }

    func testWakePausesThenReenumerates() {
        let smc = Fixtures.m5ProSMC()
        let monitor = makeMonitor(smc: smc, wakePause: 0.6)
        let first = expectation(description: "first")
        first.assertForOverFulfill = false
        monitor.onSnapshot = { _ in first.fulfill() }
        monitor.refreshNow()
        wait(for: [first], timeout: 5)
        let before = monitor.latest?.sequence ?? 0

        Fixtures.setTemp(smc, "TVD9", 52)          // appears while "asleep"
        monitor.noteDidWake()
        monitor.refreshNow()                        // inside the pause window: skipped
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(monitor.latest?.sequence, before, "no reads during the wake pause")

        Thread.sleep(forTimeInterval: 0.5)
        let after = expectation(description: "after pause")
        after.assertForOverFulfill = false
        monitor.onSnapshot = { _ in after.fulfill() }
        monitor.refreshNow()
        wait(for: [after], timeout: 5)
        XCTAssertTrue(monitor.latest?.readings.contains { $0.sensor.key == "TVD9" } ?? false, "re-enumerated after wake")
    }
}
