import FanPilotKit
import XCTest
@testable import FanPilotSensors

final class DiagnosticsTests: XCTestCase {
    private let twoFans = [
        FanInfo(index: 0, name: "Left Side", minRPM: 1350, maxRPM: 5349, backend: .appleSiliconMd(modeKey: "F0md")),
        FanInfo(index: 1, name: "Right Side", minRPM: 1350, maxRPM: 5777, backend: .appleSiliconMd(modeKey: "F1md")),
    ]

    private func reading(_ i: Int, rpm: Double, target: Double = 0, mode: Int = 0) -> FanReading {
        FanReading(index: i, actualRPM: rpm, targetRPM: target, mode: mode, minRPM: 1350, maxRPM: 5349)
    }

    func testZeroRPMInAutoIsNormalOnAppleSilicon() {
        let result = FanDiagnostics.evaluate(infos: twoFans, readings: [reading(0, rpm: 0), reading(1, rpm: 0)],
                                             hardware: Fixtures.m5Pro, badFanMask: 0)
        XCTAssertEqual(result.status, .ok)
    }

    func testZeroRPMInAutoIsAProblemOnIntelThatCannotStop() {
        let intel = HardwareInfo(model: "iMac18,3", isAppleSilicon: false)
        let result = FanDiagnostics.evaluate(infos: [twoFans[0]], readings: [reading(0, rpm: 0)], hardware: intel)
        XCTAssertEqual(result.status, .warning)
        XCTAssertEqual(result.subjects, ["Left Side"])

        let canStop = HardwareInfo(model: "MacBookPro16,2", isAppleSilicon: false)
        XCTAssertEqual(FanDiagnostics.evaluate(infos: [twoFans[0]], readings: [reading(0, rpm: 0)], hardware: canStop).status, .ok)
    }

    func testManualFanThatDoesNotSpinIsFlaggedOnlyAfterSpinUp() {
        let readings = [reading(0, rpm: 0, target: 3000, mode: 1), reading(1, rpm: 3000, target: 3000, mode: 1)]
        let unknownAge = FanDiagnostics.evaluate(infos: twoFans, readings: readings, hardware: Fixtures.m5Pro)
        XCTAssertEqual(unknownAge.status, .ok, "without a command age the check is skipped")

        let young = FanDiagnostics.evaluate(infos: twoFans, readings: readings, hardware: Fixtures.m5Pro,
                                            manualCommandAge: [0: 3, 1: 3])
        XCTAssertEqual(young.status, .ok, "still spinning up")

        let old = FanDiagnostics.evaluate(infos: twoFans, readings: readings, hardware: Fixtures.m5Pro,
                                          manualCommandAge: [0: 30, 1: 30])
        XCTAssertEqual(old.status, .warning)
        XCTAssertEqual(old.subjects, ["Left Side"])
    }

    func testBadFanMaskUnreadableAndNoFans() {
        let flagged = FanDiagnostics.evaluate(infos: twoFans, readings: [reading(0, rpm: 2000), reading(1, rpm: 2000)],
                                              hardware: Fixtures.m5Pro, badFanMask: 0b10)
        XCTAssertEqual(flagged.status, .warning)
        XCTAssertEqual(flagged.subjects, ["Right Side"])

        let unreadable = FanDiagnostics.evaluate(infos: twoFans, readings: [reading(0, rpm: 2000)], hardware: Fixtures.m5Pro)
        XCTAssertEqual(unreadable.status, .warning)
        XCTAssertEqual(unreadable.subjects, ["Right Side"])

        XCTAssertEqual(FanDiagnostics.evaluate(infos: [], readings: [], hardware: Fixtures.m5Pro).status, .notApplicable)
        let single = FanDiagnostics.evaluate(infos: [twoFans[0]], readings: [reading(0, rpm: 2000)], hardware: Fixtures.m5Pro)
        XCTAssertEqual(single.message, "The fan is working normally.")
    }

    func testSensorDiagnostics() {
        func r(_ key: String, _ area: SensorArea, _ v: Double, valid: Bool) -> SensorReading {
            SensorReading(sensor: .smc(key: key, name: key, area: area), value: v, valid: valid)
        }
        XCTAssertEqual(SensorDiagnostics.evaluate(readings: []).status, .warning)
        XCTAssertEqual(SensorDiagnostics.evaluate(readings: [r("TB0T", .battery, 30, valid: true)]).status, .ok)

        let bad = SensorDiagnostics.evaluate(readings: [r("TB0T", .battery, 30, valid: true), r("Tg08", .gpu, 0, valid: false),
                                                        r("TVD0", .other, 0, valid: false)])
        XCTAssertEqual(bad.status, .warning)
        XCTAssertEqual(bad.subjects, ["Tg08"], "Other sensors are not judged")
    }

    func testBatteryParsingAppleSilicon() {
        let registry: [String: Any] = [
            "BatteryInstalled": true, "CycleCount": 7, "DesignCycleCount9C": 1000, "CurrentCapacity": 80, "MaxCapacity": 100,
            "IsCharging": false, "ExternalConnected": true,
            "BatteryData": ["DesignCapacity": 8579, "NominalChargeCapacity": 8926, "FullChargeCapacity": 8682],
        ]
        let info = BatteryReader.parse(registry: registry, powerSource: ["BatteryHealth": "Good"])
        XCTAssertTrue(info.isPresent)
        XCTAssertEqual(info.cycleCount, 7)
        XCTAssertEqual(info.designCycleCount, 1000)
        XCTAssertEqual(info.healthPercent, 100, "capped at 100 like System Settings")
        XCTAssertEqual(info.condition, "Normal")
        XCTAssertEqual(info.chargePercent, 80)
        XCTAssertTrue(info.isPluggedIn)
        XCTAssertFalse(info.isCharging)
        XCTAssertTrue(info.isHealthy)
        XCTAssertEqual(BatteryDiagnostics.evaluate(info).status, .ok)
    }

    func testBatteryWornAndAbsent() {
        let worn = BatteryReader.parse(registry: ["BatteryInstalled": true, "CycleCount": 900, "DesignCapacity": 5000,
                                                  "AppleRawMaxCapacity": 3800], powerSource: nil)
        XCTAssertEqual(worn.healthPercent, 76)
        XCTAssertEqual(worn.condition, "Service Recommended")
        XCTAssertEqual(BatteryDiagnostics.evaluate(worn).status, .warning)

        let reported = BatteryReader.parse(registry: ["BatteryInstalled": true, "CycleCount": 10],
                                           powerSource: ["BatteryHealth": "Poor", "BatteryHealthCondition": "Check Battery"])
        XCTAssertEqual(reported.condition, "Check Battery")
        XCTAssertFalse(reported.isHealthy)

        XCTAssertEqual(BatteryReader.parse(registry: ["BatteryInstalled": false], powerSource: nil), .absent)
        XCTAssertEqual(BatteryDiagnostics.evaluate(.absent).status, .notApplicable)
    }
}
