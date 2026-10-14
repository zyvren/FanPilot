import FanPilotKit
import XCTest
@testable import FanPilotSensors

/// Read-only smoke test against the real machine. Skips where the SMC is unavailable (CI, VMs).
/// The connection is opened `.readOnly`, which cannot send a write command at all.
final class LiveSensorsTests: XCTestCase {
    private func liveEngine() throws -> SensorEngine {
        do {
            return try SensorEngine()
        } catch {
            throw XCTSkip("AppleSMC unavailable: \(error)")
        }
    }

    func testLiveSnapshotIsPlausible() throws {
        let engine = try liveEngine()
        let started = Date()
        try engine.prepare()
        let prepareTime = Date().timeIntervalSince(started)

        let tick = Date()
        let snapshot = engine.refresh()
        let tickTime = Date().timeIntervalSince(tick)

        // Steady state under the default polling policy: curated sensors and fans only.
        var steady: [TimeInterval] = []
        for i in 1...4 {
            let begin = Date()
            _ = engine.refresh(now: Date().addingTimeInterval(Double(i) * 2))
            steady.append(Date().timeIntervalSince(begin))
        }
        print(String(format: "[live] first poll %.1f ms; following polls %@ ms", tickTime * 1000,
                     steady.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")))

        print("[live] model \(engine.hardware.model), arm \(engine.hardware.isAppleSilicon), "
            + "levels \(engine.hardware.perfLevels.map { "\($0.name)=\($0.physicalCPUs)" }), catalog \(snapshot.catalogModel ?? "heuristics")")
        print(String(format: "[live] prepare %.2f s (key walk + HID + plan), %d sensors",
                     prepareTime, snapshot.readings.count))

        for group in snapshot.groups {
            let shown = group.area == .other ? Array(group.readings.prefix(8)) : group.readings
            print("[live] -- \(group.area.displayName) (\(group.readings.count))")
            for r in shown {
                let value = r.valid ? String(format: "%6.2f C", r.value) : "   N/A  "
                print("[live]    \(value)  \(r.sensor.name)  [\(r.sensor.source.rawValue):\(r.sensor.key)]")
            }
            if group.area == .other, group.readings.count > shown.count {
                print("[live]    ... \(group.readings.count - shown.count) more")
            }
        }
        let a = snapshot.aggregates
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "n/a" }
        print("[live] aggregates: average \(f(a.computerAverage)), highest \(f(a.highest)) (\(a.highestSensorID ?? "-")), "
            + "avg CPU \(f(a.averageCPU)), highest CPU \(f(a.highestCPU)), hot-set max \(f(a.hotSetMax)) "
            + "(\(a.hotSetMaxSensorID ?? "-"), \(a.hotSetValidCount) valid)")
        for (info, fan) in zip(snapshot.fanInfos, snapshot.fans) {
            print("[live] fan \(info.index) \(info.name): \(fan.actualRPM) RPM, target \(fan.targetRPM), mode \(fan.mode), "
                + "range \(fan.minRPM)...\(fan.maxRPM), backend \(info.backend.kind)")
        }

        XCTAssertGreaterThan(snapshot.readings.count, 5)
        XCTAssertNotNil(a.computerAverage)
        let cpu = snapshot.readings.filter { $0.sensor.area == .cpu && $0.valid }
        XCTAssertFalse(cpu.isEmpty, "a Mac has CPU temperature sensors")
        for r in cpu {
            XCTAssertGreaterThan(r.value, 20, "\(r.sensor.name)")
            XCTAssertLessThan(r.value, 100, "\(r.sensor.name) is implausibly hot")
        }
        XCTAssertLessThan(tickTime, 1.0, "a full poll must still be cheap")
        XCTAssertLessThan(steady.max() ?? 0, 0.5, "a steady-state poll reads the curated sensors only (an HID pass costs about 80 ms)")
        XCTAssertEqual(snapshot.fans.count, snapshot.fanInfos.count)
        for fan in snapshot.fans {
            XCTAssertGreaterThanOrEqual(fan.actualRPM, 0)
            XCTAssertLessThan(fan.actualRPM, 15_000)
            XCTAssertGreaterThan(fan.maxRPM, fan.minRPM)
        }
    }

    func testLiveMac17_8Layout() throws {
        let engine = try liveEngine()
        guard engine.hardware.model == "Mac17,8" else { throw XCTSkip("layout assertions are for the Mac17,8") }
        let snapshot = engine.refresh()

        func names(_ area: SensorArea) -> [String] { snapshot.readings.filter { $0.sensor.area == area }.map { $0.sensor.name } }
        XCTAssertEqual(names(.cpu).filter { $0.hasPrefix("Super Core") }.count, 6)
        XCTAssertEqual(names(.cpu).filter { $0.hasPrefix("Performance Core") }.count, 12)
        XCTAssertGreaterThanOrEqual(names(.gpu).count, 4)
        XCTAssertTrue(names(.battery).contains("Battery Gas Gauge"))
        XCTAssertEqual(names(.airflow), ["Airflow Left", "Airflow Right", "Airflow Top"])
        XCTAssertEqual(names(.storage), ["SSD", "SSD (NAND I/O)"])
        XCTAssertEqual(names(.power), ["Charger Proximity", "Power Supply Proximity"])
        XCTAssertEqual(names(.palmRest), ["Trackpad", "Trackpad Actuator"])
        XCTAssertEqual(names(.wireless), ["Wireless Proximity"])
        XCTAssertEqual(snapshot.fanInfos.map(\.name), ["Left Side", "Right Side"])
        XCTAssertGreaterThan(names(.other).count, 20, "the leftovers of the 285 T keys")
        XCTAssertFalse(snapshot.readings.contains { ["TTPD", "TVMD", "TG0B", "TfCB"].contains($0.sensor.key) })
    }

    func testLiveDiagnosticsRun() throws {
        let engine = try liveEngine()
        let snapshot = engine.refresh()
        let fans = FanDiagnostics.evaluate(infos: snapshot.fanInfos, readings: snapshot.fans, hardware: engine.hardware,
                                           badFanMask: engine.badFanMask())
        let sensors = SensorDiagnostics.evaluate(readings: snapshot.readings)
        let battery = BatteryReader.read()
        print("[live] diagnostics fans: \(fans.status) \(fans.message)")
        print("[live] diagnostics sensors: \(sensors.status) \(sensors.message)")
        print("[live] battery: \(battery) -> \(BatteryDiagnostics.evaluate(battery).message)")
        XCTAssertNotEqual(sensors.message, "")
    }
}
