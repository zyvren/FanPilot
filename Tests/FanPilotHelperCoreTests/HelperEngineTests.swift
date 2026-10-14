import FanPilotKit
import XCTest
@testable import FanPilotHelperCore

/// Protocol, ownership, lease and release rules of the engine, driven without sockets or root.
final class HelperEngineTests: XCTestCase {
    private var logs: LogCapture!

    override func setUp() {
        super.setUp()
        logs = LogCapture()
    }

    override func tearDown() {
        logs = nil
        super.tearDown()
    }

    /// Default config with a long lease cap so tests control expiry through `ttl`.
    private func longLeases(failsafe: Double = 95) -> HelperConfig {
        HelperConfig(allowedUIDs: [501], failsafeTempC: failsafe, leaseMaxSeconds: 120)
    }

    // MARK: Handshake

    func testHelloDescribesTheMachine() throws {
        let h = EngineHarness()
        h.engine.connectionOpened(1)
        let reply = h.send(.hello(proto: 1, client: "test")).reply
        guard case .hello(let hello) = reply.body else { return XCTFail("\(reply)") }
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(hello.proto, 1)
        XCTAssertEqual(hello.fans.count, 2)
        XCTAssertEqual(hello.fans[0].maxRPM, 5349)
        XCTAssertEqual(hello.fans[0].modeKey, "F0md")
        XCTAssertEqual(hello.failsafeTempC, 95)
        XCTAssertEqual(hello.leaseMaxS, 30)
        XCTAssertFalse(hello.monitorOnly)
    }

    func testHelloUsesTheAppsFanNamesWhenTheModelIsKnown() {
        func names(model: String?) -> [String] {
            let h = EngineHarness(model: model)
            h.engine.connectionOpened(1)
            guard case .hello(let hello) = h.send(.hello(proto: 1, client: "test")).reply.body else { return [] }
            return hello.fans.map(\.name)
        }
        XCTAssertEqual(names(model: "Mac17,8"), ["Left Side", "Right Side"])
        XCTAssertEqual(names(model: "Macmini9,1"), ["Fan 1", "Fan 2"])
        XCTAssertEqual(names(model: nil), ["Fan 1", "Fan 2"])
    }

    func testAnythingBeforeHelloIsRefusedAndClosesTheConnection() {
        let h = EngineHarness()
        h.engine.connectionOpened(1)
        let outcome = h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        XCTAssertEqual(outcome.reply.err, .badRequest)
        XCTAssertTrue(outcome.closeConnection)
        XCTAssertTrue(h.smc.writes.isEmpty)
    }

    func testUnsupportedProtocolVersionIsRefused() {
        let h = EngineHarness()
        h.engine.connectionOpened(1)
        let outcome = h.send(.hello(proto: 2, client: "from the future"))
        XCTAssertEqual(outcome.reply.err, .badRequest)
        XCTAssertTrue(outcome.closeConnection)
    }

    func testEveryRequestGetsAReplyWithItsID() {
        let h = EngineHarness()
        h.connect()
        let request = WireRequest(id: 4242, command: .status)
        let outcome = h.engine.handle(request, from: 1)
        XCTAssertEqual(outcome.reply.id, 4242)
        XCTAssertEqual(outcome.reply.op, .status)
    }

    func testMonitorOnlyMachineRefusesControl() {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("F0md", 0, attributes: 0x80)
        smc.setUInt8("F1md", 0, attributes: 0x80)
        let h = EngineHarness(smc: smc)
        h.engine.connectionOpened(1)
        guard case .hello(let hello) = h.send(.hello(proto: 1, client: "t")).reply.body else { return XCTFail() }
        XCTAssertTrue(hello.monitorOnly)
        XCTAssertNotNil(hello.monitorReason)

        let reply = h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply
        XCTAssertEqual(reply.err, .monitorOnly)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    // MARK: set

    func testSetTakesOverAndReportsClamping() {
        let h = EngineHarness()
        h.connect()

        let normal = h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply
        XCTAssertEqual(normal.setReply, SetReply(applied: 3000, clamped: false))
        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.float("F0Tg"), 3000)

        let over = h.send(.set(fan: 0, rpm: 99_999, ttl: nil)).reply
        XCTAssertEqual(over.setReply, SetReply(applied: 5349, clamped: true))

        let under = h.send(.set(fan: 0, rpm: 5, ttl: nil)).reply
        XCTAssertEqual(under.setReply, SetReply(applied: 1350, clamped: true))
    }

    func testSetRejectsNonsenseWithoutTouchingHardware() {
        let h = EngineHarness()
        h.connect()
        XCTAssertEqual(h.send(.set(fan: 0, rpm: -1, ttl: nil)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: .nan, ttl: nil)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: .infinity, ttl: nil)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 1e9, ttl: nil)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: -1, rpm: 3000, ttl: nil)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: 10, rpm: 3000, ttl: nil)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: 0)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: .nan)).reply.err, .badRequest)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: 100_000)).reply.err, .badRequest)
        XCTAssertTrue(h.smc.writes.isEmpty)
    }

    func testSetOfAFanThatDoesNotExist() {
        let h = EngineHarness()
        h.connect()
        XCTAssertEqual(h.send(.set(fan: 5, rpm: 3000, ttl: nil)).reply.err, .noSuchFan)
        XCTAssertTrue(h.smc.writes.isEmpty)
    }

    func testModeRejectionIsReportedWithItsCode() {
        let smc = MockSMC.appleSilicon()
        smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [1] ? .ignore : .apply }
        let h = EngineHarness(smc: smc)
        h.connect()
        let reply = h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.err, .modeRejected)
        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertTrue(h.engine.holdList.isEmpty)
        XCTAssertEqual(h.engine.fanWriter.ownedFans, [])
        XCTAssertNotNil(h.send(.status).reply.statusReply?.lastError)
    }

    func testTargetRejectionIsReportedAndReleases() {
        let smc = MockSMC.appleSilicon()
        smc.behavior = { key, bytes, _ in key == "F0Tg" && bytes == f(3000) ? .ignore : .apply }
        let h = EngineHarness(smc: smc)
        h.connect()
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply.err, .targetRejected)
        XCTAssertEqual(smc.byte("F0md"), 0)
    }

    func testSetAllAppliesEachEntryAndSkipsNulls() {
        let h = EngineHarness()
        h.connect()
        let reply = h.send(.setAll(rpms: [nil, 4000], ttl: nil)).reply
        guard case .setAll(let results) = reply.body else { return XCTFail("\(reply)") }
        XCTAssertEqual(results.count, 2)
        XCTAssertNil(results[0])
        XCTAssertEqual(results[1], SetReply(applied: 4000, clamped: false))
        XCTAssertEqual(h.smc.byte("F0md"), 0, "fan 0 untouched")
        XCTAssertEqual(h.smc.byte("F1md"), 1)
    }

    func testSetAllChecksEveryFanBeforeWritingAnything() {
        let h = EngineHarness()
        h.connect()
        let reply = h.send(.setAll(rpms: [3000, nil, 3000], ttl: nil)).reply   // this Mac has two fans
        XCTAssertEqual(reply.err, .noSuchFan)
        XCTAssertTrue(h.smc.writes.isEmpty, "all-or-nothing for the mistakes that can be seen up front")
    }

    // MARK: Leases

    func testDefaultLeaseIsFifteenSecondsAndExpiryReturnsTheFanToAuto() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        XCTAssertEqual(h.send(.status).reply.statusReply?.fans[0].leaseRemainS, 15)

        h.run(14)
        XCTAssertEqual(h.smc.byte("F0md"), 1, "still held at 14 s")
        h.run(2)
        XCTAssertEqual(h.smc.byte("F0md"), 0, "lease expired: back to auto")
        XCTAssertTrue(h.engine.holdList.isEmpty)
        XCTAssertFalse(h.engine.fanWriter.isOwned(0))
        XCTAssertTrue(logs.contains(.warning, "lease expired"))
        XCTAssertEqual(h.smc.writtenKeys.suffix(2).first, "F0md", "release writes the mode first")
    }

    func testLeaseIsCappedByTheConfiguredMaximum() {
        let h = EngineHarness(config: HelperConfig(allowedUIDs: [501], leaseMaxSeconds: 20))
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 3600))
        XCTAssertEqual(h.send(.status).reply.statusReply?.fans[0].leaseRemainS, 20)
        h.run(21)
        XCTAssertEqual(h.smc.byte("F0md"), 0)
    }

    func testHeartbeatRenewsTheLease() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 10))
        for _ in 0..<5 {
            h.run(8)
            XCTAssertEqual(h.send(.heartbeat(ttl: 10)).reply.heartbeatOwned, [0])
        }
        XCTAssertEqual(h.smc.byte("F0md"), 1, "40 s later, still held thanks to heartbeats")
        h.run(11)
        XCTAssertEqual(h.smc.byte("F0md"), 0, "heartbeats stopped")
    }

    func testResendingTheSameTargetRenewsTheLeaseWithoutTouchingTheSMC() {
        // The app re-sends its unchanged target every ~5 s: that must keep the lease alive without
        // rewriting F0Tg or logging a takeover line each time.
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 10))
        h.smc.clearWrites()
        let takeoverLines = { self.logs.lines.filter { $0.0 == .info && $0.1.contains("fan 0: target") }.count }
        let linesAfterFirstSet = takeoverLines()
        XCTAssertEqual(linesAfterFirstSet, 1)

        for _ in 0..<6 {
            h.run(5)
            let reply = h.send(.set(fan: 0, rpm: 3000, ttl: 10)).reply
            XCTAssertEqual(reply.setReply?.applied, 3000)
            XCTAssertEqual(reply.setReply?.clamped, false)
        }

        XCTAssertTrue(h.smc.writes.isEmpty, "no SMC write for an unchanged target: \(h.smc.writtenKeys)")
        XCTAssertEqual(takeoverLines(), linesAfterFirstSet, "no log line per refresh")
        XCTAssertEqual(h.smc.byte("F0md"), 1, "30 s later, still held: every re-send renewed the lease")
        XCTAssertEqual(h.send(.status).reply.statusReply?.fans[0].leaseRemainS, 10)
        XCTAssertEqual(h.engine.holdList.first { $0.fan == 0 }?.owner, 1)
    }

    func testResendingTheSameTargetAfterTheOSRevertedItStillRewritesIt() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 100))
        h.smc.setUInt8("F0md", 0, attributes: 0xD0)   // the OS flipped the mode back
        h.smc.clearWrites()

        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: 100)).reply.setReply?.applied, 3000)

        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.float("F0Tg"), 3000)
        XCTAssertEqual(h.smc.writtenKeys, ["F0md", "F0Tg"])
    }

    func testHeartbeatTellsTheClientWhichFansItStillOwns() {
        let h = EngineHarness()
        h.connect()
        XCTAssertEqual(h.send(.heartbeat(ttl: nil)).reply.heartbeatOwned, [])
        h.send(.set(fan: 1, rpm: 3000, ttl: nil))
        XCTAssertEqual(h.send(.heartbeat(ttl: nil)).reply.heartbeatOwned, [1])
        h.send(.auto(.fan(1)))
        XCTAssertEqual(h.send(.heartbeat(ttl: nil)).reply.heartbeatOwned, [])
    }

    // MARK: Connections

    func testDisconnectReleasesWhatTheConnectionOwned() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        h.send(.set(fan: 1, rpm: 3000, ttl: nil))

        h.engine.connectionClosed(1)

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.smc.byte("F1md"), 0)
        XCTAssertTrue(h.engine.holdList.isEmpty)
        XCTAssertEqual(h.engine.connectionCount, 0)
    }

    func testDisconnectOnlyAffectsTheFansThatConnectionOwned() {
        let h = EngineHarness()
        h.connect(1)
        h.connect(2)
        h.send(.set(fan: 0, rpm: 3000, ttl: nil), from: 1)
        h.send(.set(fan: 1, rpm: 3000, ttl: nil), from: 2)

        h.engine.connectionClosed(1)

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.smc.byte("F1md"), 1)
        XCTAssertEqual(h.send(.heartbeat(ttl: nil), from: 2).reply.heartbeatOwned, [1])
    }

    func testControlMovesToTheLatestClient() {
        let h = EngineHarness()
        h.connect(1)
        h.connect(2)
        h.send(.set(fan: 0, rpm: 3000, ttl: nil), from: 1)
        h.send(.set(fan: 0, rpm: 4000, ttl: nil), from: 2)

        XCTAssertEqual(h.send(.heartbeat(ttl: nil), from: 1).reply.heartbeatOwned, [], "the first client learns it lost the fan")
        XCTAssertEqual(h.send(.heartbeat(ttl: nil), from: 2).reply.heartbeatOwned, [0])

        h.engine.connectionClosed(1)
        XCTAssertEqual(h.smc.byte("F0md"), 1, "the old owner leaving does not release the new owner's fan")
        XCTAssertEqual(h.smc.float("F0Tg"), 4000)

        h.engine.connectionClosed(2)
        XCTAssertEqual(h.smc.byte("F0md"), 0)
    }

    func testByeReleasesAndClosesTheConnection() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        let outcome = h.send(.bye)
        XCTAssertTrue(outcome.reply.ok)
        XCTAssertTrue(outcome.closeConnection)
        XCTAssertEqual(h.smc.byte("F0md"), 0)
    }

    // MARK: auto

    func testAutoReleasesOneFanOrAll() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        h.send(.set(fan: 1, rpm: 3000, ttl: nil))

        XCTAssertEqual(h.send(.auto(.fan(0))).reply.autoReleased, [0])
        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.smc.byte("F1md"), 1)

        XCTAssertEqual(h.send(.auto(.all)).reply.autoReleased, [1])
        XCTAssertEqual(h.smc.byte("F1md"), 0)
        XCTAssertEqual(h.send(.auto(.all)).reply.autoReleased, [], "nothing left to release")
    }

    func testAutoFromAnotherConnectionIsAllowedAndSafe() {
        let h = EngineHarness()
        h.connect(1)
        h.connect(2)
        h.send(.set(fan: 0, rpm: 3000, ttl: nil), from: 1)
        XCTAssertEqual(h.send(.auto(.all), from: 2).reply.autoReleased, [0])
        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.send(.heartbeat(ttl: nil), from: 1).reply.heartbeatOwned, [])
    }

    func testAutoAllRecoversAFanLeftInManualMode() {
        let h = EngineHarness(start: false)
        h.smc.setUInt8("F1md", 1, attributes: 0xD0)
        h.engine.start()   // startup already fixes it; make a second stuck fan appear later
        h.smc.setUInt8("F0md", 1, attributes: 0xD0)
        h.connect()

        XCTAssertEqual(h.send(.auto(.all)).reply.autoReleased, [0])
        XCTAssertEqual(h.smc.byte("F0md"), 0)
    }

    func testAutoReportsAFanThatWillNotGoBackAndKeepsTrying() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        h.smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [0] ? .ignore : .apply }

        let reply = h.send(.auto(.fan(0))).reply
        XCTAssertEqual(reply.err, .ioError)
        XCTAssertTrue(reply.msg?.contains("retrying") == true)
        XCTAssertEqual(h.engine.desiredTickInterval, 1, "the timer must keep running until the release sticks")

        h.smc.behavior = nil
        h.tick()
        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.engine.fanWriter.pendingReleases, [])
    }

    // MARK: Status

    func testStatusReportsOwnershipTargetsAndLimits() throws {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 30))
        h.smc.setFloat("F1Ac", 1500)
        h.smc.set("DICT", type: "flag", attributes: 0xC0, bytes: [1])

        let status = try XCTUnwrap(h.send(.status).reply.statusReply)

        XCTAssertEqual(status.fans.count, 2)
        let fan0 = status.fans[0]
        XCTAssertTrue(fan0.owned)
        XCTAssertEqual(fan0.targetRPM, 3000)
        XCTAssertEqual(fan0.mode, 1)
        XCTAssertEqual(fan0.minRPM, 1350)
        XCTAssertEqual(fan0.maxRPM, 5349)
        XCTAssertEqual(fan0.leaseRemainS, 30)
        let fan1 = status.fans[1]
        XCTAssertFalse(fan1.owned)
        XCTAssertEqual(fan1.actualRPM, 1500)
        XCTAssertEqual(fan1.mode, 0)
        XCTAssertEqual(fan1.leaseRemainS, 0)
        XCTAssertEqual(status.dict, 1)
        XCTAssertFalse(status.failsafe.active)
    }

    // MARK: Lifecycle

    func testStartupReturnsLeftoverManualFansToAuto() {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("F0md", 1, attributes: 0xD0)
        smc.setUInt8("F1md", 1, attributes: 0xD0)
        let h = EngineHarness(smc: smc)   // starts the engine
        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertEqual(smc.byte("F1md"), 0)
        XCTAssertTrue(logs.contains(.warning, "startup: returned fans"))
        XCTAssertEqual(h.hot.refreshCount, 1)
    }

    func testStartupOnACleanMachineWritesNothing() {
        let h = EngineHarness()
        XCTAssertTrue(h.smc.writes.isEmpty)
    }

    func testSleepReleasesEverything() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        h.send(.set(fan: 1, rpm: 3000, ttl: nil))

        h.engine.systemWillSleep()

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.smc.byte("F1md"), 0)
        XCTAssertTrue(h.engine.holdList.isEmpty)
        XCTAssertEqual(h.send(.heartbeat(ttl: nil)).reply.heartbeatOwned, [], "the client sees it lost the fans")
    }

    func testWakeRediscoversAndTheClientCanTakeControlAgain() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        h.engine.systemWillSleep()
        h.smc.setUInt8("F1md", 1, attributes: 0xD0)   // firmware left a fan in manual over the sleep

        h.engine.systemDidWake()

        XCTAssertEqual(h.hot.refreshCount, 2, "sensors re-enumerated")
        XCTAssertEqual(h.smc.byte("F1md"), 0, "a manual flag that survived sleep is cleared")
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply.setReply?.applied, 3000)
    }

    func testShutdownReleasesEverythingAndRefusesFurtherControl() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))

        h.engine.shutdown(reason: "SIGTERM")

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply.err, .ioError)
        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertNil(h.engine.desiredTickInterval)
    }

    func testIdleMeansNoTimerAtAll() {
        let h = EngineHarness()
        XCTAssertNil(h.engine.desiredTickInterval, "no connections, no fans: no timers")

        h.connect()
        XCTAssertEqual(h.engine.desiredTickInterval, 5, "a connected client without fans: slow readiness sampling")

        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        XCTAssertEqual(h.engine.desiredTickInterval, 1)

        h.send(.auto(.all))
        XCTAssertEqual(h.engine.desiredTickInterval, 5)

        h.engine.connectionClosed(1)
        XCTAssertNil(h.engine.desiredTickInterval)
    }

    // MARK: Reassertion through the tick

    func testTickReassertsATargetTheOSChanged() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 100))
        h.smc.setFloat("F0Tg", 0, attributes: 0xD4)
        h.tick()
        XCTAssertEqual(h.smc.float("F0Tg"), 3000)
    }

    func testTickDoesNotFightWhileDICTIsSet() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 100))
        h.smc.setFloat("F0Tg", 0, attributes: 0xD4)
        h.smc.set("DICT", type: "flag", attributes: 0xC0, bytes: [1])
        h.smc.clearWrites()
        h.run(3)
        XCTAssertTrue(h.smc.writes.isEmpty)
    }

    func testAntiFightGivesUpAndCoolsDown() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 3000, ttl: 100))

        for _ in 0..<10 {
            h.smc.setFloat("F0Tg", 0, attributes: 0xD4)   // the OS reverts us every second
            h.smc.setUInt8("F0md", 0, attributes: 0xD0)
            h.tick()
        }

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertTrue(h.engine.holdList.isEmpty)
        XCTAssertEqual(h.send(.heartbeat(ttl: nil)).reply.heartbeatOwned, [], "the client is told it lost the fan")
        let status = h.send(.status).reply.statusReply
        XCTAssertTrue(status?.lastError?.contains("os_override") == true, status?.lastError ?? "nil")

        // Immediately asking again would restart the fight: refused for a minute.
        let refused = h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply
        XCTAssertEqual(refused.err, .modeRejected)
        XCTAssertTrue(refused.msg?.contains("os_override") == true)
        XCTAssertEqual(h.send(.set(fan: 1, rpm: 3000, ttl: nil)).reply.setReply?.applied, 3000, "other fans are unaffected")

        h.tick(61)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply.setReply?.applied, 3000)
    }

    // MARK: Failsafe

    func testFirstTakeoverLooksAtTheHotSet() {
        let h = EngineHarness()
        h.connect()
        XCTAssertEqual(h.hot.readCount, 0)
        h.send(.set(fan: 0, rpm: 3000, ttl: nil))
        XCTAssertEqual(h.hot.readCount, 1)
        h.send(.set(fan: 0, rpm: 3500, ttl: nil))
        XCTAssertEqual(h.hot.readCount, 1, "no extra sampling while a session is running")
    }

    func testRefusesToControlFansBlind() {
        let h = EngineHarness(hot: StubHotSet(nil))
        h.connect()
        let reply = h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply
        XCTAssertEqual(reply.err, .failsafeActive)
        XCTAssertTrue(h.smc.writes.isEmpty, "no temperature to watch, no control")
    }

    func testAlreadyTooHotAtTakeoverForcesMaximumInstead() {
        let h = EngineHarness(hot: StubHotSet(97))
        h.connect()
        h.tick(5)   // the idle client's periodic look at the hot set: the first hot sample
        XCTAssertFalse(h.engine.failsafeStatus.active, "one hot sample is not an overheat yet")
        h.clock.advance(1)   // a request in the same instant would re-read the same value, not confirm it
        let reply = h.send(.set(fan: 0, rpm: 2000, ttl: nil)).reply   // the takeover's own look: the second

        XCTAssertEqual(reply.err, .failsafeActive)
        XCTAssertEqual(reply.forcedRPM, 5349)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
        XCTAssertEqual(h.smc.float("F1Tg"), 5777)
        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.byte("F1md"), 1)
    }

    func testOneHotSampleAtTakeoverIsNotEnoughButTheNextTickConfirmsIt() {
        let h = EngineHarness(hot: StubHotSet(97), config: longLeases())
        h.connect()
        let reply = h.send(.set(fan: 0, rpm: 2000, ttl: 100)).reply
        XCTAssertNil(reply.err, "a lone hot sample (it may be a sensor spike) does not refuse the client")
        XCTAssertEqual(reply.setReply?.applied, 2000)
        XCTAssertFalse(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 2000)

        h.tick()   // still 97 C one second later: confirmed, both fans to maximum
        XCTAssertTrue(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
        XCTAssertEqual(h.smc.float("F1Tg"), 5777)
        XCTAssertEqual(h.smc.byte("F1md"), 1)
    }

    func testASingleHotSpikeWhileHoldingFansNeverForcesMaximum() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2000, ttl: 100))
        h.smc.clearWrites()

        for _ in 0..<5 {
            h.hot.set(99.5)   // TCMb read 99.5 C once while the cores were near 54 C
            h.tick()
            h.hot.set(54)
            h.tick()
        }

        XCTAssertFalse(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 2000, "the client's target is untouched")
        XCTAssertEqual(h.smc.byte("F1md"), 0, "the fan nobody asked for stays with the OS")
        XCTAssertTrue(h.smc.writes.isEmpty)
        XCTAssertFalse(logs.contains(.critical, "FAILSAFE"))
    }

    func testAGapBetweenTwoHotSamplesInTheEngineResetsTheStreak() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2000, ttl: 100))
        h.hot.set(97); h.tick()
        h.hot.set(nil); h.tick()     // an unreadable second
        h.hot.set(97); h.tick()
        XCTAssertFalse(h.engine.failsafeStatus.active, "hot, gap, hot is not two in a row")
        h.tick()
        XCTAssertTrue(h.engine.failsafeStatus.active)
    }

    func testAnIdleSpikeDoesNotPairWithAFreshOneAfterTheLastClientLeft() {
        let h = EngineHarness()
        h.connect()
        h.hot.set(99.5)
        h.tick(5)                         // the idle client's look: a spike, streak of one
        XCTAssertFalse(h.engine.failsafeStatus.active)
        h.hot.set(54)
        h.engine.connectionClosed(1)      // the last client goes: no timer, nothing samples any more
        XCTAssertNil(h.engine.desiredTickInterval)

        h.clock.advance(6 * 3600)         // six hours later another client arrives and sets a fan
        h.connect(2)
        h.hot.set(99.5)                   // ...and meets one more lone spike
        let reply = h.send(.set(fan: 0, rpm: 3000, ttl: nil), from: 2).reply
        XCTAssertNil(reply.err, "one fresh spike is one sample")
        XCTAssertFalse(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 3000)
        XCTAssertFalse(logs.contains(.critical, "FAILSAFE"))
    }

    func testSetAllSamplesTheHotSetOncePerRequest() {
        let h = EngineHarness(hot: StubHotSet(99.5))
        h.connect()
        let reply = h.send(.setAll(rpms: [3000, 3000], ttl: nil)).reply
        XCTAssertNil(reply.err, "a lone spike must not refuse (or trip) a setAll")
        XCTAssertEqual(h.hot.readCount, 1, "every gate of one request sees the same instant: one read")
        XCTAssertFalse(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 3000)
        XCTAssertEqual(h.smc.float("F1Tg"), 3000)
        XCTAssertFalse(logs.contains(.critical, "FAILSAFE"))

        h.tick()   // a second later it is still 99.5 C: now it is confirmed
        XCTAssertTrue(h.engine.failsafeStatus.active)
    }

    func testSetAllForOneFanSamplesOnceToo() {
        let h = EngineHarness(hot: StubHotSet(99.5))
        h.connect()
        let reply = h.send(.setAll(rpms: [3000, nil], ttl: nil)).reply
        XCTAssertNil(reply.err)
        XCTAssertEqual(h.hot.readCount, 1)
        XCTAssertFalse(h.engine.failsafeStatus.active)
    }

    func testBackToBackSetsOnAFreshSessionDoNotConfirmASpike() {
        // The app sends fan 0 then fan 1. When fan 0's takeover fails no hold exists yet, so fan 1's
        // request samples the hot set again a few milliseconds later: the same spike, not a second one.
        let smc = MockSMC.appleSilicon()
        smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [1] ? .ignore : .apply }
        let h = EngineHarness(smc: smc, hot: StubHotSet(99.5))
        h.connect()
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: nil)).reply.err, .modeRejected)
        let second = h.send(.set(fan: 1, rpm: 3000, ttl: nil)).reply
        XCTAssertNil(second.err, "the second request is not an independent confirmation")
        XCTAssertEqual(h.hot.readCount, 2)
        XCTAssertFalse(h.engine.failsafeStatus.active)

        h.tick()   // but a spike that is still there a second later is real
        XCTAssertTrue(h.engine.failsafeStatus.active)
    }

    func testAPendingHotSampleSpeedsUpTheTickEvenWithNoFanHeld() {
        let h = EngineHarness()
        h.connect()
        XCTAssertEqual(h.engine.desiredTickInterval, 5)
        h.hot.set(99.5)
        h.tick(5)                          // the first hot sample, found by the slow idle look
        XCTAssertFalse(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.engine.desiredTickInterval, 1, "confirm it within a second, not after another 5 s")

        h.tick(1)                          // still hot: confirmed one second later
        XCTAssertTrue(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
        XCTAssertEqual(h.smc.float("F1Tg"), 5777)
    }

    func testARefutedHotSampleReturnsToTheSlowTick() {
        let h = EngineHarness()
        h.connect()
        h.hot.set(99.5)
        h.tick(5)
        XCTAssertEqual(h.engine.desiredTickInterval, 1)
        h.hot.set(54)
        h.tick(1)                          // fast tick samples even though no fan is held
        XCTAssertEqual(h.hot.readCount, 2)
        XCTAssertEqual(h.engine.desiredTickInterval, 5)
        XCTAssertFalse(h.engine.failsafeStatus.active)
    }

    func testTheLastClientLeavingWithAPendingHotSampleStopsTheTimer() {
        let h = EngineHarness()
        h.connect()
        h.hot.set(99.5)
        h.tick(5)
        XCTAssertEqual(h.engine.desiredTickInterval, 1)
        h.engine.connectionClosed(1)
        XCTAssertNil(h.engine.desiredTickInterval, "nobody left to answer: idle means no timer at all")
    }

    func testFailsafeForcesEveryFanToMaximumAndRejectsClientTargets() throws {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2000, ttl: 100))
        XCTAssertEqual(h.smc.byte("F1md"), 0)

        h.hot.set(96)
        h.tick()
        XCTAssertFalse(h.engine.failsafeStatus.active, "the first hot sample only arms the failsafe")
        XCTAssertEqual(h.smc.float("F0Tg"), 2000)
        h.tick()

        XCTAssertEqual(h.smc.float("F0Tg"), 5349, "the client's fan goes to maximum")
        XCTAssertEqual(h.smc.float("F1Tg"), 5777, "so does the fan nobody asked for")
        XCTAssertEqual(h.smc.byte("F1md"), 1)
        XCTAssertTrue(logs.contains(.critical, "FAILSAFE"))

        let status = try XCTUnwrap(h.send(.status).reply.statusReply)
        XCTAssertTrue(status.failsafe.active)
        XCTAssertEqual(status.failsafe.reason, "hot_sensor")
        XCTAssertEqual(status.failsafe.tempC, 96)

        let refused = h.send(.set(fan: 0, rpm: 2000, ttl: nil)).reply
        XCTAssertEqual(refused.err, .failsafeActive)
        XCTAssertEqual(refused.forcedRPM, 5349)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349, "the refused request changed nothing")
    }

    func testFailsafeTriggersWithOnlyAnIdleClientConnected() {
        let h = EngineHarness()
        h.connect()
        XCTAssertEqual(h.engine.desiredTickInterval, 5)
        h.hot.set(98)
        h.tick(5)
        XCTAssertFalse(h.engine.failsafeStatus.active, "one hot sample is not enough")
        XCTAssertEqual(h.smc.byte("F0md"), 0)
        h.tick(5)
        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
        XCTAssertEqual(h.engine.desiredTickInterval, 1)
    }

    func testFailsafeClearsOnlyAfterTenSecondsBelowTheHysteresis() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2000, ttl: 100))
        h.overheat(96)
        XCTAssertTrue(h.engine.failsafeStatus.active)

        // 90 C is below the trigger but not below trigger - 7: stays active however long it lasts.
        h.hot.set(90)
        h.run(60)
        XCTAssertTrue(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)

        // Below 88 C: needs 10 continuous seconds.
        h.hot.set(80)
        h.run(10)
        XCTAssertTrue(h.engine.failsafeStatus.active, "9 s of cooling is not enough")
        h.tick()
        XCTAssertFalse(h.engine.failsafeStatus.active)
        XCTAssertTrue(logs.contains(.warning, "failsafe cleared"))
    }

    func testCoolingTimerRestartsIfTheTemperatureBounces() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2000, ttl: 100))
        h.overheat(96)
        h.hot.set(80)
        h.run(8)
        h.hot.set(92)   // back inside the band
        h.tick()
        h.hot.set(80)
        h.run(9)
        XCTAssertTrue(h.engine.failsafeStatus.active)
        h.run(2)
        XCTAssertFalse(h.engine.failsafeStatus.active)
    }

    func testAfterTheFailsafeTheClientTargetIsRestoredAndNobodyElsesFanIsHeld() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2500, ttl: 100))
        h.overheat(96)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
        XCTAssertEqual(h.smc.byte("F1md"), 1)

        h.hot.set(60)
        h.run(11)

        XCTAssertFalse(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 2500, "back to what the client asked for")
        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.byte("F1md"), 0, "the fan only the failsafe was holding returns to auto")
        XCTAssertEqual(h.send(.heartbeat(ttl: nil)).reply.heartbeatOwned, [0])
    }

    func testFailsafeKeepsFansWhenTheClientLeavesOrItsLeaseExpires() {
        let h = EngineHarness(config: longLeases())
        h.connect(1)
        h.connect(2)
        h.send(.set(fan: 0, rpm: 2500, ttl: 5), from: 1)
        h.send(.set(fan: 1, rpm: 2500, ttl: 100), from: 2)
        h.overheat(96)
        XCTAssertTrue(h.engine.failsafeStatus.active)

        h.engine.connectionClosed(2)    // client 2 leaves
        h.run(6)                        // client 1's lease runs out

        XCTAssertEqual(h.smc.byte("F0md"), 1, "still hot: the failsafe holds on")
        XCTAssertEqual(h.smc.byte("F1md"), 1)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
        XCTAssertEqual(h.send(.heartbeat(ttl: nil), from: 1).reply.heartbeatOwned, [])

        h.hot.set(50)
        h.run(11)
        XCTAssertEqual(h.smc.byte("F0md"), 0, "cool again and nobody wants the fans: auto")
        XCTAssertEqual(h.smc.byte("F1md"), 0)
        XCTAssertTrue(h.engine.holdList.isEmpty)
    }

    func testAutoDuringFailsafeOnlyDropsTheClientsClaim() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2500, ttl: 100))
        h.overheat(96)

        let reply = h.send(.auto(.all)).reply
        XCTAssertEqual(reply.autoReleased, [0])
        XCTAssertTrue(reply.msg?.contains("failsafe") == true)
        XCTAssertEqual(h.smc.byte("F0md"), 1, "the failsafe keeps the fans at maximum")
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
    }

    func testDisconnectDuringFailsafeDoesNotReleaseTheFans() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2500, ttl: 100))
        h.overheat(96)
        h.engine.connectionClosed(1)
        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
    }

    func testBlindForTenSecondsReturnsFansToAuto() throws {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2500, ttl: 100))

        h.hot.set(nil)
        h.run(10)
        XCTAssertEqual(h.smc.byte("F0md"), 1, "ten seconds of grace")
        h.tick()

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertTrue(h.engine.holdList.isEmpty)
        let status = try XCTUnwrap(h.send(.status).reply.statusReply)
        XCTAssertEqual(status.failsafe.reason, "blind")
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 2500, ttl: nil)).reply.err, .failsafeActive)

        h.hot.set(50)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 2500, ttl: nil)).reply.setReply?.applied, 2500, "temperatures are back")
    }

    func testABriefSensorGlitchDoesNotReleaseTheFans() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2500, ttl: 100))
        h.hot.set(nil)
        h.run(5)
        h.hot.set(50)
        h.run(30)
        XCTAssertEqual(h.smc.byte("F0md"), 1)
    }

    func testBlindWhileTheFailsafeIsForcingHandsBackToTheOS() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 2500, ttl: 100))
        h.overheat(97)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
        h.hot.set(nil)
        h.run(11)
        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.smc.byte("F1md"), 0)
    }

    func testTheFailsafeTemperatureCanNeverBeRaisedAboveOneHundred() {
        let h = EngineHarness(config: HelperConfig(allowedUIDs: [501], failsafeTempC: 250))
        h.connect()
        guard case .hello(let hello) = h.send(.hello(proto: 1, client: "t")).reply.body else { return XCTFail() }
        XCTAssertEqual(hello.failsafeTempC, 100)
        h.send(.set(fan: 0, rpm: 2500, ttl: nil))
        h.overheat(100.5)
        XCTAssertTrue(h.engine.failsafeStatus.active)
    }

    func testReadingsAboveTheDisplayRangeStillTriggerTheFailsafe() {
        let h = EngineHarness()
        h.connect()
        h.send(.set(fan: 0, rpm: 2500, ttl: nil))
        h.overheat(140)   // a runaway sensor value, sustained: fail towards cooling
        XCTAssertTrue(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349)
    }

    // MARK: Failsafe fallbacks and recovery that does not depend on discovery

    func testFailsafeHandsAClientHeldFanBackToAutoWhenMaximumCannotBeWritten() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 1350, ttl: 100)).reply.setReply?.applied, 1350)
        XCTAssertEqual(h.smc.byte("F0md"), 1)

        h.smc.behavior = { key, _, _ in key == "F0Tg" ? .fail(0x86) : .apply }   // F0Tg stops accepting writes
        h.overheat(98)
        h.tick()

        XCTAssertTrue(h.engine.failsafeStatus.active)
        XCTAssertEqual(h.smc.byte("F0md"), 0, "a stale low manual target must not survive the failsafe: the OS curve takes over")
        XCTAssertEqual(h.smc.float("F1Tg"), 5777, "the fan that can be driven still goes to maximum")
        XCTAssertEqual(h.smc.byte("F1md"), 1)
        XCTAssertNil(h.engine.holdList.first { $0.fan == 0 }, "the client's claim on the fan is dropped")
        XCTAssertEqual(h.send(.heartbeat(ttl: nil)).reply.heartbeatOwned, [], "the client learns it lost the fan")
    }

    func testFailsafeHandsTheFanBackToAutoWhenItsLimitsCannotBeRead() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 1500, ttl: 100))

        h.smc.setFloat("F0Mx", 0, attributes: 0x85)   // clamp() now throws before any write
        h.overheat(98)
        h.tick()

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertEqual(h.smc.float("F1Tg"), 5777)
    }

    func testFailsafeRetriesAFanItHadToReleaseOnceTheKeyWorksAgain() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.send(.set(fan: 0, rpm: 1350, ttl: 100))
        h.smc.behavior = { key, _, _ in key == "F0Tg" ? .fail(0x86) : .apply }
        h.overheat(98)
        XCTAssertEqual(h.smc.byte("F0md"), 0)

        h.smc.behavior = nil
        h.tick()
        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.float("F0Tg"), 5349, "maximum as soon as the fan accepts it")
    }

    func testAutoAllReleasesAFanThatDiscoveryDistrusts() {
        let smc = MockSMC.appleSilicon()
        smc.setFloat("F0Mx", 0, attributes: 0x85)         // limits unreadable: discovery marks fan 0 monitor-only
        smc.setUInt8("F0md", 1, attributes: 0xD0)         // ...but a crashed run left it in manual mode
        let h = EngineHarness(smc: smc)
        XCTAssertEqual(h.smc.byte("F0md"), 0, "the startup release does not depend on discovery")

        smc.setUInt8("F0md", 1, attributes: 0xD0)
        h.connect()
        let reply = h.send(.auto(.all)).reply
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(smc.byte("F0md"), 0, "`auto all` is the recovery command: it reaches the distrusted fan too")
        XCTAssertEqual(reply.autoReleased, [0])
    }

    func testStartupReleasesBeforeAnySensorEnumeration() {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("F1md", 1, attributes: 0xD0)
        var releasedWhenRefreshing: Bool?
        final class Spy: HotSetProvider, @unchecked Sendable {
            var onRefresh: () -> Void = {}
            func read() -> HotSetReading { HotSetReading(maxTempC: 45, hottest: "spy", sensorCount: 1) }
            func refresh() { onRefresh() }
        }
        let spy = Spy()
        spy.onRefresh = { releasedWhenRefreshing = smc.byte("F1md") == 0 }
        let engine = HelperEngine(smc: smc, hotSet: spy, config: HelperConfig(allowedUIDs: [501]), sleep: { _ in })
        engine.start()
        XCTAssertEqual(releasedWhenRefreshing, true, "a crash inside sensor enumeration must not leave the fan in manual")
    }

    // MARK: Wake

    func testWakeKeepsAFanThatLooksUnusableForAMoment() {
        let h = EngineHarness(config: longLeases())
        h.connect()
        h.engine.systemWillSleep()
        h.smc.setFloat("F0Mx", 0, attributes: 0x85)   // the SMC answers nonsense right after wake

        h.engine.systemDidWake()
        h.run(6)   // the delayed re-discovery runs and sees the bad read

        XCTAssertEqual(h.engine.topology.controllableFans.map(\.index), [0, 1], "a transient failed read does not end manual control")
        XCTAssertTrue(logs.contains(.warning, "looked unusable after wake"))

        h.smc.setFloat("F0Mx", 5349, attributes: 0x85)
        XCTAssertEqual(h.send(.set(fan: 0, rpm: 3000, ttl: 100)).reply.setReply?.applied, 3000)
        h.run(30)
        XCTAssertEqual(h.engine.topology.controllableFans.map(\.index), [0, 1])
    }

    func testWakeAcceptsTheNewTopologyWhenAFanStaysBroken() {
        let h = EngineHarness(config: longLeases())
        h.engine.systemWillSleep()
        h.smc.setFloat("F0Mx", 0, attributes: 0x85)

        h.engine.systemDidWake()
        h.run(60)

        XCTAssertEqual(h.engine.topology.controllableFans.map(\.index), [1], "a fan that stays unusable is eventually given up on")
        XCTAssertNil(h.engine.desiredTickInterval, "and the retry timer stops")
    }

    func testWakeDoesNotTouchDiscoveryUntilTheSMCHasSettled() {
        let h = EngineHarness()
        h.engine.systemWillSleep()
        h.smc.setFloat("F0Mx", 4000, attributes: 0x85)   // visible only to a new discovery
        h.engine.systemDidWake()
        XCTAssertEqual(h.engine.topology.fan(0)?.maxRPM, 5349, "no re-discovery at HasPoweredOn")
        h.run(5)
        XCTAssertEqual(h.engine.topology.fan(0)?.maxRPM, 4000)
    }
}
