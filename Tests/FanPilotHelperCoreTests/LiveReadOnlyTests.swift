import FanPilotKit
import XCTest
@testable import FanPilotHelperCore

/// Checks against the real SMC of the machine running the tests. Everything here uses a READ-ONLY
/// connection (`IOKitSMC(access: .readOnly)`): the Kit refuses to send a write on it, so these tests
/// cannot change a fan. They skip themselves on machines without an AppleSMC.
final class LiveReadOnlyTests: XCTestCase {
    private func openSMC() throws -> IOKitSMC {
        do { return try IOKitSMC(access: .readOnly) } catch { throw XCTSkip("no AppleSMC here: \(error)") }
    }

    func testLiveDiscoveryAndReadings() throws {
        let smc = try openSMC()
        let topology = FanTopology.discover(smc: smc)
        print("[live] fans: \(topology.fans.map { "\($0.index) \($0.backend.kind) \(Int($0.minRPM))-\(Int($0.maxRPM))" }), Ftst \(topology.hasFtst), DICT \(topology.hasDICT), monitorOnly \(topology.isMonitorOnly)")
        for fan in topology.fans {
            let reading = try FanKeyReader.reading(smc: smc, fan: fan)
            XCTAssertGreaterThanOrEqual(reading.actualRPM, 0)
            XCTAssertLessThan(reading.minRPM, reading.maxRPM)
        }
    }

    func testLiveHotSetIsReadableAndPlausible() throws {
        let smc = try openSMC()
        let reader = SMCHotSetReader(smc: smc, includeHID: true)
        reader.refresh()
        let started = Date()
        let reading = reader.read()
        let elapsed = Date().timeIntervalSince(started)
        print("[live] SMC hot set: \(reading.maxTempC.map { String(format: "%.1f", $0) } ?? "nil") C from \(reading.sensorCount) sensors (\(reading.hottest ?? "-")), one pass took \(Int(elapsed * 1000)) ms")

        let max = try XCTUnwrap(reading.maxTempC, "a Mac must have at least one readable die temperature")
        XCTAssertGreaterThan(max, 15)
        XCTAssertLessThan(max, 110, "a healthy idle test machine")
        XCTAssertGreaterThan(reading.sensorCount, 3)
        XCTAssertLessThan(elapsed, 0.5, "the failsafe samples this every second")
    }

    func testLiveCompositeHotSetAsTheDaemonBuildsIt() throws {
        let smc = try openSMC()
        let provider = CompositeHotSetProvider([SensorsHotSetProvider(smc: smc), SMCHotSetReader(smc: smc, includeHID: false)])
        provider.refresh()
        let reading = provider.read()
        print("[live] composite hot set: \(reading.maxTempC.map { String(format: "%.1f", $0) } ?? "nil") C (\(reading.hottest ?? "-")), \(reading.sensorCount) sensors")
        let max = try XCTUnwrap(reading.maxTempC)
        XCTAssertLessThan(max, 95, "limit-like constants must not trip the failsafe on an idle machine")
    }

    func testTakeoverOnAReadOnlyConnectionIsRefusedBeforeTheHardware() throws {
        let smc = try openSMC()
        let topology = FanTopology.discover(smc: smc)
        guard let fan = topology.controllableFans.first else { throw XCTSkip("no controllable fan on this Mac") }
        let before = FanKeyReader.mode(smc: smc, fan: fan)

        let writer = FanWriter(smc: smc, topology: topology, sleep: { _ in })
        XCTAssertThrowsError(try writer.takeover(fan: fan.index, rpm: 3000)) { error in
            guard case FanWriterError.modeRejected(_, let detail)? = error as? FanWriterError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("read-only"), detail)
        }
        XCTAssertEqual(FanKeyReader.mode(smc: smc, fan: fan), before, "the fan's mode did not change")
    }

    func testEngineStartAndStatusOnTheRealSMCNeverWrites() throws {
        let smc = try openSMC()
        let engine = HelperEngine(smc: smc, hotSet: SMCHotSetReader(smc: smc, includeHID: false),
                                  config: HelperConfig(allowedUIDs: [UInt32(getuid())]),
                                  sleep: { _ in })
        engine.start()    // would call release-all; on a read-only connection any write attempt would throw
        engine.connectionOpened(1)
        let hello = engine.handle(WireRequest(id: 1, command: .hello(proto: 1, client: "live")), from: 1).reply
        XCTAssertTrue(hello.ok)
        let status = engine.handle(WireRequest(id: 2, command: .status), from: 1).reply
        XCTAssertTrue(status.ok, status.msg ?? "")
        if let fans = status.statusReply?.fans {
            print("[live] status: \(fans.map { "fan \($0.index) \(Int($0.actualRPM)) RPM \(CLISupport.modeText($0.mode))" })")
            XCTAssertTrue(fans.allSatisfy { !$0.owned })
        }
        engine.connectionClosed(1)
    }
}
