import FanPilotKit
import XCTest
@testable import FanPilotHelperCore

final class HardwareSelfTestTests: XCTestCase {
    private var logs: LogCapture!
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        logs = LogCapture()
        lines = []
    }

    override func tearDown() {
        logs = nil
        super.tearDown()
    }

    /// A fan that follows its target while in manual mode, like real hardware should.
    private func respondingFan() -> MockSMC {
        let smc = MockSMC.appleSilicon()
        smc.afterWrite = { smc, key, bytes in
            guard key == "F0Tg", smc.byte("F0md") == 1, let rpm = SMCCodec.decodeFloat(bytes) else { return }
            smc.setFloat("F0Ac", rpm)
        }
        return smc
    }

    private func run(_ smc: MockSMC,
                     hot: StubHotSet = StubHotSet(45),
                     onSleep: ((Int) -> Void)? = nil,
                     abortAfter: Int? = nil) -> HardwareSelfTest.Report {
        var sleeps = 0
        let test = HardwareSelfTest(smc: smc, hotSet: hot,
                                    sleep: { _ in sleeps += 1; onSleep?(sleeps) },
                                    shouldAbort: { abortAfter.map { sleeps >= $0 } ?? false },
                                    output: { self.lines.append($0) })
        return test.run()
    }

    func testPassesOnAFanThatBehaves() {
        let smc = respondingFan()
        let report = run(smc)

        XCTAssertTrue(report.passed, report.verdict)
        XCTAssertTrue(report.verdict.hasPrefix("PASS"))
        XCTAssertEqual(smc.byte("F0md"), 0, "the fan ends in auto")
        XCTAssertEqual(smc.byte("F1md"), 0)
        XCTAssertEqual(smc.writtenKeys.first, "F0md", "manual mode alone comes first")
        XCTAssertFalse(smc.writtenKeys.contains { $0.string.hasPrefix("F1") }, "other fans are never touched")
        XCTAssertTrue(lines.contains { $0.contains("== (a)") })
        XCTAssertTrue(lines.contains { $0.contains("== (d)") })
        // `FANPILOT_PRINT_SELFTEST=1 swift test --filter testPassesOnAFanThatBehaves` shows the transcript
        // used as the "expected output" in docs/PHASE0.md.
        if ProcessInfo.processInfo.environment["FANPILOT_PRINT_SELFTEST"] != nil {
            lines.forEach { print($0) }
        }
    }

    func testTargetIsMinimumPlusTenPercent() {
        let smc = respondingFan()
        _ = run(smc)
        // 1350 + 10 % of (5349 - 1350) = 1749.9 -> 1750
        XCTAssertEqual(smc.writes(to: "F0Tg").first, f(1750))
    }

    func testRefusesWhenTheMachineIsAlreadyHot() {
        let smc = respondingFan()
        let report = run(smc, hot: StubHotSet(85))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("cool down"))
        XCTAssertTrue(smc.writes.isEmpty, "nothing is written when the precondition fails")
    }

    func testRefusesWithoutAnyTemperature() {
        let smc = respondingFan()
        let report = run(smc, hot: StubHotSet(nil))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testRefusesIfSomethingElseAlreadyControlsTheFan() {
        let smc = respondingFan()
        smc.setUInt8("F0md", 1, attributes: 0xD0)
        let report = run(smc)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("already"))
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testRefusesAMonitorOnlyFan() {
        let smc = respondingFan()
        smc.setUInt8("F0md", 0, attributes: 0x80)
        let report = run(smc)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("monitor-only"))
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testReportsAnOSThatRevertsManualMode() {
        let smc = respondingFan()
        let report = run(smc, onSleep: { count in
            if count == 1 { smc.setUInt8("F0md", 0, attributes: 0xD0) }   // thermalmonitord takes it back
        })
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("RISK R1"), report.verdict)
        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertFalse(smc.writes(to: "F0Tg").contains { $0 != f(0) }, "no target is written once manual mode is refused")
    }

    func testReportsAModeTheSMCRejects() {
        let smc = respondingFan()
        smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [1] ? .ignore : .apply }
        let report = run(smc)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("rejected"))
        XCTAssertEqual(smc.byte("F0md"), 0)
    }

    func testReportsAFanThatDoesNotSpin() {
        let smc = MockSMC.appleSilicon()   // Ac never changes
        let report = run(smc)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("never responded"), report.verdict)
        XCTAssertEqual(smc.byte("F0md"), 0, "released even though the test failed")
    }

    func testAbortsAndReleasesWhenTheMachineGetsHot() {
        let smc = respondingFan()
        let hot = StubHotSet(45)
        let report = run(smc, hot: hot, onSleep: { count in
            if count == 12 { hot.set(91) }
        })
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("too hot"), report.verdict)
        XCTAssertTrue(report.steps.contains { $0.status == .abort })
        XCTAssertEqual(smc.byte("F0md"), 0)
    }

    func testAbortsWhenTemperaturesDisappear() {
        let smc = respondingFan()
        let hot = StubHotSet(45)
        let report = run(smc, hot: hot, onSleep: { count in
            if count == 12 { hot.set(nil) }
        })
        XCTAssertFalse(report.passed)
        XCTAssertEqual(smc.byte("F0md"), 0)
    }

    func testAnInterruptReturnsTheFanToAuto() {
        for abortAfter in [1, 5, 12, 25] {
            let smc = respondingFan()
            let report = run(smc, abortAfter: abortAfter)
            XCTAssertFalse(report.passed, "abort after \(abortAfter) sleeps")
            XCTAssertEqual(smc.byte("F0md"), 0, "abort after \(abortAfter) sleeps")
            XCTAssertEqual(smc.byte("F1md"), 0)
        }
    }

    func testStuckReleaseIsReportedLoudly() {
        let smc = respondingFan()
        smc.behavior = { key, bytes, index in key == "F0md" && bytes == [0] ? .ignore : .apply }
        let report = run(smc)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.verdict.contains("could not be returned") || report.verdict.contains("did not return"), report.verdict)
        XCTAssertTrue(lines.joined().contains("auto all") || report.verdict.contains("auto"), "tells the user how to recover")
    }
}

final class CLISupportTests: XCTestCase {
    func testSpeedParsing() throws {
        XCTAssertEqual(try CLISupport.SpeedSpec.parse("3000"), .rpm(3000))
        XCTAssertEqual(try CLISupport.SpeedSpec.parse("3000rpm"), .rpm(3000))
        XCTAssertEqual(try CLISupport.SpeedSpec.parse("50%"), .percent(50))
        XCTAssertEqual(try CLISupport.SpeedSpec.parse("0%"), .percent(0))
        XCTAssertEqual(try CLISupport.SpeedSpec.parse("100%"), .percent(100))
        for bad in ["", "abc", "-5", "101%", "-1%", "nan", "inf", "1e9", "50 %%", "%"] {
            XCTAssertThrowsError(try CLISupport.SpeedSpec.parse(bad), bad)
        }
    }

    func testPercentMapsOntoTheFansOwnRange() {
        XCTAssertEqual(CLISupport.SpeedSpec.percent(0).rpm(min: 1350, max: 5349), 1350, "0 % is the minimum, not a stopped fan")
        XCTAssertEqual(CLISupport.SpeedSpec.percent(100).rpm(min: 1350, max: 5777), 5777)
        XCTAssertEqual(CLISupport.SpeedSpec.percent(50).rpm(min: 1350, max: 5349), 3350)
        XCTAssertEqual(CLISupport.SpeedSpec.rpm(2500).rpm(min: 1350, max: 5349), 2500)
    }

    func testFanSelector() throws {
        XCTAssertEqual(try CLISupport.parseFanSelector("all"), .all)
        XCTAssertEqual(try CLISupport.parseFanSelector("ALL"), .all)
        XCTAssertEqual(try CLISupport.parseFanSelector("1"), .fan(1))
        for bad in ["", "-1", "10", "x", "1.5"] {
            XCTAssertThrowsError(try CLISupport.parseFanSelector(bad), bad)
        }
    }

    func testOptionExtraction() throws {
        var args = ["0", "3000", "--hold", "30", "--yes"]
        XCTAssertEqual(try CLISupport.takeOption("--hold", from: &args), "30")
        XCTAssertEqual(args, ["0", "3000", "--yes"])
        XCTAssertTrue(CLISupport.takeFlag("--yes", from: &args))
        XCTAssertFalse(CLISupport.takeFlag("--yes", from: &args))
        XCTAssertEqual(args, ["0", "3000"])
        XCTAssertNil(try CLISupport.takeOption("--hold", from: &args))
        var dangling = ["--hold"]
        XCTAssertThrowsError(try CLISupport.takeOption("--hold", from: &dangling))
    }

    func testHoldParsing() throws {
        XCTAssertEqual(try CLISupport.parseHold("30"), 30)
        for bad in ["0", "-3", "abc", "nan", "100000"] {
            XCTAssertThrowsError(try CLISupport.parseHold(bad), bad)
        }
    }

    func testHex() throws {
        XCTAssertEqual(try CLISupport.parseHex("01"), [1])
        XCTAssertEqual(try CLISupport.parseHex("0x00c0a844"), [0x00, 0xC0, 0xA8, 0x44])
        XCTAssertEqual(try CLISupport.parseHex("00 C0 a8 44"), [0x00, 0xC0, 0xA8, 0x44])
        for bad in ["", "0", "123", "zz", "0x", String(repeating: "00", count: 33)] {
            XCTAssertThrowsError(try CLISupport.parseHex(bad), bad)
        }
        XCTAssertEqual(CLISupport.hex([0, 0xC0, 0xA8]), "00c0a8")
    }

    func testSMCWriteIsLimitedToFanControlKeys() {
        for key: FourCC in ["F0Tg", "F1Tg", "F0md", "F1Md", "F9Tg", "Ftst", "FS! "] {
            XCTAssertTrue(CLISupport.isWritableDebugKey(key), key.string)
        }
        for key: FourCC in ["F0Mn", "F0Mx", "F0Ac", "F0St", "FNum", "F0Dc", "TC0P", "Tp04", "#KEY", "BATP", "MSXA", "FBAD", "DICT", "FaTg", "F00g"] {
            XCTAssertFalse(CLISupport.isWritableDebugKey(key), key.string)
        }
    }

    func testRowFormatting() {
        XCTAssertEqual(CLISupport.row(["a", "bb", "c"], widths: [3, 4, 2]), "a   bb   c")
        XCTAssertEqual(CLISupport.tempText(nil), "N/A")
        XCTAssertEqual(CLISupport.tempText(51.234), "51.2 C")
        XCTAssertEqual(CLISupport.modeText(0), "auto")
        XCTAssertEqual(CLISupport.modeText(1), "manual")
        XCTAssertEqual(CLISupport.modeText(3), "mode 3")
    }

    func testDescribeSMCValue() {
        let value = SMCValue(key: "F0Tg", info: SMCKeyInfo(size: 4, type: .flt, attributes: 0xD4), bytes: f(1750))
        let text = CLISupport.describe(value)
        XCTAssertTrue(text.contains("F0Tg"))
        XCTAssertTrue(text.contains("flt"))
        XCTAssertTrue(text.contains("0xd4 RW"))
        XCTAssertTrue(text.contains("1750"))
    }
}

final class DaemonClientTests: XCTestCase {
    private var logs: LogCapture!
    private var servers: [HelperServer] = []

    override func setUp() {
        super.setUp()
        logs = LogCapture()
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        logs = nil
        super.tearDown()
    }

    private func serve() throws -> (EngineHarness, String) {
        let h = EngineHarness(config: HelperConfig(allowedUIDs: [501], leaseMaxSeconds: 120))
        let path = "/tmp/fp-test-\(UUID().uuidString.prefix(8)).sock"
        let server = HelperServer(engine: h.engine, authorizer: AllowAllPeerAuthorizer(), socketPath: path)
        try server.start()
        servers.append(server)
        return (h, path)
    }

    func testUnreachableHelperGivesAHelpfulError() {
        XCTAssertThrowsError(try DaemonClient(path: "/tmp/fp-no-such-socket.sock")) { error in
            guard case DaemonClientError.unreachable? = error as? DaemonClientError else { return XCTFail("\(error)") }
            XCTAssertTrue("\(error)".contains("install_helper.sh"))
        }
    }

    func testClientHandshakeAndRequests() throws {
        let (h, path) = try serve()
        let client = try DaemonClient(path: path)
        XCTAssertEqual(client.hello?.fans.count, 2)

        let status = try client.status()
        XCTAssertEqual(status.fans.count, 2)

        guard case .set(let reply) = try client.request(.set(fan: 0, rpm: 3000, ttl: 15)) else { return XCTFail() }
        XCTAssertEqual(reply.applied, 3000)
        XCTAssertEqual(h.smc.byte("F0md"), 1)

        XCTAssertThrowsError(try client.request(.set(fan: 9, rpm: 3000, ttl: nil))) { error in
            guard case DaemonClientError.refused(let code, _, _)? = error as? DaemonClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, .noSuchFan)
        }

        client.sayGoodbye()
        XCTAssertTrue(eventually { h.smc.byte("F0md") == 0 })
    }

    func testHoldSessionHeartbeatsThenReturnsToAuto() throws {
        let (h, path) = try serve()
        let client = try DaemonClient(path: path)
        var fakeNow = 0.0
        var messages: [String] = []

        let result = try HoldSession.run(client: client, targets: [0: 3000, 1: 99_999], duration: 12, heartbeat: 5,
                                         sleep: { fakeNow += $0 }, now: { fakeNow },
                                         shouldStop: { false }, report: { messages.append($0) })

        XCTAssertEqual(result.ending, .timeUp)
        XCTAssertEqual(result.applied[0]?.applied, 3000)
        XCTAssertEqual(result.applied[1], SetReply(applied: 5777, clamped: true))
        XCTAssertTrue(messages.contains { $0.contains("clamped") })
        XCTAssertTrue(eventually { h.smc.byte("F0md") == 0 && h.smc.byte("F1md") == 0 }, "released at the end")
    }

    func testHoldSessionStopsOnRequest() throws {
        let (h, path) = try serve()
        let client = try DaemonClient(path: path)
        var fakeNow = 0.0
        var polls = 0
        let result = try HoldSession.run(client: client, targets: [0: 3000], duration: nil,
                                         sleep: { fakeNow += $0 }, now: { fakeNow },
                                         shouldStop: { polls += 1; return polls > 8 }, report: { _ in })
        XCTAssertEqual(result.ending, .stopped)
        XCTAssertTrue(eventually { h.smc.byte("F0md") == 0 })
    }

    func testHoldSessionNoticesWhenAnotherClientTakesTheFan() throws {
        let (h, path) = try serve()
        let client = try DaemonClient(path: path)
        let thief = try DaemonClient(path: path, clientName: "thief")
        var fakeNow = 0.0
        var stolen = false

        let result = try HoldSession.run(client: client, targets: [0: 3000], duration: 60, heartbeat: 5,
                                         sleep: { seconds in
                                             fakeNow += seconds
                                             if fakeNow >= 3, !stolen {
                                                 stolen = true
                                                 _ = try? thief.request(.set(fan: 0, rpm: 4000, ttl: 100))
                                             }
                                         },
                                         now: { fakeNow }, shouldStop: { false }, report: { _ in })

        XCTAssertEqual(result.ending, .lostControl([0]))
        XCTAssertEqual(h.smc.byte("F0md"), 1, "the new owner keeps the fan; the old client's bye does not release it")
        XCTAssertEqual(h.smc.float("F0Tg"), 4000)
    }

    func testHoldSessionReportsARefusedSetAndCleansUp() throws {
        let (h, path) = try serve()
        let client = try DaemonClient(path: path)
        XCTAssertThrowsError(try HoldSession.run(client: client, targets: [0: 3000, 7: 3000], duration: 5,
                                                 shouldStop: { false }, report: { _ in }))
        XCTAssertTrue(eventually { h.smc.byte("F0md") == 0 }, "fan 0 was set before fan 7 failed and must be released")
    }
}
