import XCTest
import FanPilotKit
@testable import FanPilotControl

final class TemperatureInputsTests: XCTestCase {
    private func reading(_ key: String, _ area: SensorArea, _ value: Double, valid: Bool = true) -> SensorReading {
        SensorReading(sensor: .smc(key: key, name: key, area: area), value: value, valid: valid)
    }

    func testAggregatesFollowTheSpecDefinitions() {
        let temps = TemperatureInputs(readings: [
            reading("Tp04", .cpu, 60), reading("Tp0G", .cpu, 70), reading("Tm04", .cpu, 80),
            reading("Tg08", .gpu, 50), reading("TB0T", .battery, 30), reading("Ts0P", .palmRest, 28),
        ], sampledAt: 12)
        XCTAssertEqual(temps.sampledAt, 12)
        XCTAssertEqual(temps.highest, 80)
        XCTAssertEqual(temps.highestCPU, 80)
        XCTAssertEqual(temps.averageCPU!, 70, accuracy: 1e-9)
        XCTAssertEqual(temps.computerAverage!, (60 + 70 + 80 + 50 + 30 + 28) / 6, accuracy: 1e-9)
        XCTAssertEqual(temps.hotSetMax, 80)
        XCTAssertEqual(temps.value(for: .sensor("smc:TB0T")), 30)
        XCTAssertNil(temps.value(for: .sensor("smc:NOPE")))
        XCTAssertTrue(temps.hasData)
    }

    func testInvalidReadingsAreIgnored() {
        let temps = TemperatureInputs(readings: [
            reading("Tp04", .cpu, 60), reading("Tp0G", .cpu, 5, valid: true),      // below the valid window
            reading("Tm04", .cpu, .nan, valid: false),
            SensorReading.unavailable(.smc(key: "Tg08", name: "GPU", area: .gpu)),
        ], sampledAt: 0)
        XCTAssertEqual(temps.highest, 60)
        XCTAssertEqual(temps.averageCPU, 60)
        XCTAssertEqual(temps.sensors.count, 1)
    }

    func testEmptyCPUAreaFallsBackToSoCThenOverall() {
        let withSoC = TemperatureInputs(readings: [
            reading("tdie1", .soc, 55), reading("tdie2", .soc, 65), reading("TB0T", .battery, 90),
        ], sampledAt: 0)
        XCTAssertEqual(withSoC.highestCPU, 65)
        XCTAssertEqual(withSoC.averageCPU!, 60, accuracy: 1e-9)

        let neither = TemperatureInputs(readings: [reading("TB0T", .battery, 40), reading("Ts0P", .palmRest, 30)], sampledAt: 0)
        XCTAssertEqual(neither.highestCPU, 40)
        XCTAssertEqual(neither.averageCPU!, 35, accuracy: 1e-9)
        XCTAssertNil(neither.hotSetMax)
        XCTAssertEqual(neither.emergencyTemperature, 40, "no hot set sensor: use the overall maximum")
    }

    func testHotSetExcludesBatteryAndPalmRestButCountsOverRangeHotSensors() {
        let cool = TemperatureInputs(readings: [reading("Tp04", .cpu, 70), reading("TB0T", .battery, 99)], sampledAt: 0)
        XCTAssertEqual(cool.hotSetMax, 70)
        // 130 C on a CPU sensor is invalid for display, yet it must push towards cooling.
        let hot = TemperatureInputs(readings: [reading("Tp04", .cpu, 70), reading("Tp0G", .cpu, 130, valid: false)],
                                    sampledAt: 0)
        XCTAssertEqual(hot.hotSetMax, 130)
        XCTAssertEqual(hot.highest, 70, "but it is not displayed or aggregated")
    }

    func testNoReadingsMeansNoData() {
        let temps = TemperatureInputs(readings: [], sampledAt: 0)
        XCTAssertFalse(temps.hasData)
        XCTAssertNil(temps.value(for: .highest))
        XCTAssertNil(temps.emergencyTemperature)
        XCTAssertFalse(TemperatureInputs.none.hasData)
    }

    func testNonFiniteAggregatesAreDropped() {
        let temps = TemperatureInputs(highest: .nan, highestCPU: .infinity, hotSetMax: -.infinity, sensors: ["a": .nan, "b": 40])
        XCTAssertNil(temps.highest)
        XCTAssertNil(temps.highestCPU)
        XCTAssertNil(temps.hotSetMax)
        XCTAssertEqual(temps.sensors, ["b": 40])
    }
}
