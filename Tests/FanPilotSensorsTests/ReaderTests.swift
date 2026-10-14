import FanPilotKit
import XCTest
@testable import FanPilotSensors

final class SMCSensorReaderTests: XCTestCase {
    func testEnumerationKeepsOnlyTemperatureTypedCandidates() throws {
        let smc = Fixtures.m5ProSMC()
        let reader = SMCSensorReader(smc: smc)
        XCTAssertTrue(reader.needsReenumeration())
        let candidates = try reader.enumerate()
        let names = Set(candidates.map(\.name))

        XCTAssertTrue(names.isSuperset(of: ["Tp04", "TB0T", "TTPD", "fRof", "Tz11"]), "type is the only filter at this stage")
        XCTAssertFalse(names.contains("TG0B"), "ioft is not a temperature type")
        XCTAssertFalse(names.contains("TV0i"), "si32 is not a temperature type")
        XCTAssertFalse(names.contains("F0Ac"), "only T, f and s prefixes are scanned")
        XCTAssertFalse(names.contains("PSTR"))
        XCTAssertTrue(candidates.allSatisfy { $0.type == .flt || $0.type == .sp78 })
        XCTAssertFalse(reader.needsReenumeration())

        smc.set("Tz99", type: .flt, attributes: 0x85, bytes: SMCCodec.encodeFloat(30))
        XCTAssertTrue(reader.needsReenumeration(), "a changed key count is detected cheaply")
    }

    func testReadValuesDecodeFloatAndSP78AndKeepOutOfRangeNumbers() throws {
        let smc = InMemorySMC()
        Fixtures.setTemp(smc, "Tp04", 43.7)
        Fixtures.setTemp(smc, "TVD0", 140)
        smc.set("TC0P", type: .sp78, attributes: 0x85, bytes: [0x2B, 0x80]) // 43.5
        smc.set("TB0T", type: .ui8, attributes: 0x85, bytes: [33])
        let reader = SMCSensorReader(smc: smc)
        try reader.enumerate()

        XCTAssertEqual(reader.readValue("Tp04") ?? 0, 43.7, accuracy: 0.001)
        XCTAssertEqual(reader.readValue("TC0P"), 43.5)
        XCTAssertEqual(reader.readValue("TVD0"), 140, "no range filter in the reader: the failsafe needs the raw number")
        XCTAssertNil(reader.readValue("TB0T"), "not a temperature type")
        XCTAssertNil(reader.readValue("ZZZZ"), "missing key")
        XCTAssertEqual(reader.readCandidates().count, 3)
    }

    func testNonFiniteFloatIsNotAValue() throws {
        let smc = InMemorySMC()
        smc.set("TTPD", type: .flt, attributes: 0x85, bytes: SMCCodec.encodeFloat(.nan))
        let reader = SMCSensorReader(smc: smc)
        try reader.enumerate()
        XCTAssertNil(reader.readValue("TTPD"))
    }

    func testSensorRules() {
        XCTAssertTrue(SensorRules.isEligibleForOther("TCMb"))
        XCTAssertTrue(SensorRules.isEligibleForOther("ftP3"))
        XCTAssertTrue(SensorRules.isEligibleForOther("sd43"))
        XCTAssertFalse(SensorRules.isEligibleForOther("fRof"))
        XCTAssertFalse(SensorRules.isEligibleForOther("fuFa"))
        XCTAssertFalse(SensorRules.isEligibleForOther("TTPD"))
        XCTAssertFalse(SensorRules.isEligibleForOther("Tz1j"))
        XCTAssertFalse(SensorRules.isEligibleForOther("TfCB"))
    }
}

final class HIDSensorReaderTests: XCTestCase {
    private func raw(_ product: String, _ loc: Int64?, _ value: Double, hasValue: Bool = true) -> HIDTemperature {
        HIDTemperature(product: product, locationID: loc, value: value, hasValue: hasValue)
    }

    func testDedupeKeepsHighestPerLocation() {
        let samples = HIDSensorReader.normalize([
            raw("PMU tdie1", 100, 40.6), raw("PMU tdie1", 100, 41.17), raw("PMU tdie1", 100, 41.0),
            raw("PMU tdie2", 200, 40.1),
        ])
        XCTAssertEqual(samples, [HIDSample(name: "PMU tdie1", value: 41.17), HIDSample(name: "PMU tdie2", value: 40.1)])
    }

    func testSentinelsAndCalibrationAreDropped() {
        let input = [raw("PMU tdev1", 1, -9201.1), raw("PMU tdev8", 2, -9202.8), raw("PMU tcal", 3, 51.82),
                     raw("als-temp", 0, 0, hasValue: false), raw("PMU tdie1", 4, 40), raw("", 5, 30),
                     raw("bad", 6, .nan), raw("inf", 7, .infinity)]
        XCTAssertEqual(HIDSensorReader.normalize(input).map(\.name), ["PMU tdie1"])
        // A catalog may name them explicitly (M1 tables list PMU tdev5/7/8): then they stay.
        XCTAssertEqual(Set(HIDSensorReader.normalize(input, keeping: ["PMU tdev1"]).map(\.name)), ["PMU tdie1", "PMU tdev1"])
    }

    func testGasGaugesAreNumberedByLocation() {
        let samples = HIDSensorReader.normalize([
            raw("gas gauge battery", 1413951810, 32.8), raw("gas gauge battery", 1413951554, 32.0),
            raw("gas gauge battery", 1413951560, 32.4), raw("gas gauge battery", 1413951554, 31.9),
        ])
        XCTAssertEqual(samples.map(\.name), ["gas gauge battery 0", "gas gauge battery 1", "gas gauge battery 2"])
        XCTAssertEqual(samples.map(\.value), [32.0, 32.4, 32.8], "ordered by LocationID, not by service order")
    }

    func testNamesSortNumerically() {
        let names = HIDSensorReader.normalize((1...12).reversed().map { raw("PMU tdie\($0)", Int64($0), 40) }).map(\.name)
        XCTAssertEqual(names.first, "PMU tdie1")
        XCTAssertEqual(names.last, "PMU tdie12")
        XCTAssertEqual(names[1], "PMU tdie2")
    }

    func testSameNameAtTwoLocationsMerges() {
        let samples = HIDSensorReader.normalize([raw("NAND CH0 temp", 1, 36), raw("NAND CH0 temp", 2, 38)])
        XCTAssertEqual(samples, [HIDSample(name: "NAND CH0 temp", value: 38)])
    }
}

final class AggregatesTests: XCTestCase {
    private func reading(_ key: String, _ area: SensorArea, _ value: Double, valid: Bool? = nil,
                         source: SensorSource = .smc) -> SensorReading {
        let sensor = Sensor(id: Sensor.makeID(source: source, key: key), key: key, name: key, area: area, source: source)
        return SensorReading(sensor: sensor, value: value, valid: valid ?? Constants.isValidTemperature(value))
    }

    func testDefinitions() {
        let a = SensorAggregates.compute(from: [
            reading("Tp04", .cpu, 50), reading("Tp0G", .cpu, 70), reading("Tg08", .gpu, 60),
            reading("TB0T", .battery, 30), reading("TCMb", .other, 99), reading("Tp0R", .cpu, 5, valid: false),
        ])
        XCTAssertEqual(a.computerAverage ?? 0, (50 + 70 + 60 + 30) / 4.0, accuracy: 1e-9, "Other and N/A are excluded")
        XCTAssertEqual(a.highest, 70)
        XCTAssertEqual(a.highestSensorID, "smc:Tp0G")
        XCTAssertEqual(a.averageCPU, 60)
        XCTAssertEqual(a.highestCPU, 70)
        XCTAssertEqual(a.highestCPUSensorID, "smc:Tp0G")
    }

    func testCPUFallsBackToSoCDieThenToEverything() {
        let withSoC = SensorAggregates.compute(from: [
            reading("PMU tdie1", .soc, 44, source: .hid), reading("PMU tdie2", .soc, 48, source: .hid), reading("TB0T", .battery, 30),
        ])
        XCTAssertEqual(withSoC.averageCPU, 46)
        XCTAssertEqual(withSoC.highestCPU, 48)

        let batteryOnly = SensorAggregates.compute(from: [reading("TB0T", .battery, 30), reading("TH0a", .storage, 40)])
        XCTAssertEqual(batteryOnly.averageCPU, 35)
        XCTAssertEqual(batteryOnly.highestCPU, 40)

        let none = SensorAggregates.compute(from: [])
        XCTAssertNil(none.computerAverage)
        XCTAssertNil(none.highest)
        XCTAssertNil(none.averageCPU)
        XCTAssertNil(none.hotSetMax)
        XCTAssertEqual(none.hotSetValidCount, 0)
    }

    func testHotSetIncludesHotOtherSensorsAndRunawayValues() {
        let normal = SensorAggregates.compute(from: [
            reading("Tp04", .cpu, 60), reading("TVD0", .other, 69), reading("TB0T", .battery, 95), reading("Ta00", .other, 99),
        ])
        XCTAssertEqual(normal.hotSetMax, 69, "battery and non-SoC Other sensors are not in the hot set")
        XCTAssertEqual(normal.hotSetMaxSensorID, "smc:TVD0")
        XCTAssertEqual(normal.hotSetValidCount, 2)
        XCTAssertEqual(normal.highest, 95, "Other (TVD0, Ta00) stays out of the user-facing highest")

        // 130 C is N/A for display but must reach the failsafe.
        let runaway = SensorAggregates.compute(from: [reading("Tp04", .cpu, 60), reading("Tm04", .cpu, 130)])
        XCTAssertEqual(runaway.hotSetMax, 130)
        XCTAssertEqual(runaway.hotSetValidCount, 1)
        XCTAssertEqual(runaway.highestCPU, 60, "display aggregates ignore the invalid reading")

        // A -9200 style sentinel or an unreadable sensor is not a hot reading.
        let sentinel = SensorAggregates.compute(from: [
            reading("Tp04", .cpu, 60), reading("PMU tdev1", .soc, -9201, source: .hid), SensorReading.unavailable(
                Sensor.smc(key: "Tp0G", name: "x", area: .cpu)),
        ])
        XCTAssertEqual(sentinel.hotSetMax, 60)
    }

    func testBlindHotSetHasNoMaxAndZeroValidCount() {
        let blind = SensorAggregates.compute(from: [reading("Tp04", .cpu, 5, valid: false), reading("TB0T", .battery, 30)])
        XCTAssertNil(blind.hotSetMax)
        XCTAssertEqual(blind.hotSetValidCount, 0)
    }

    func testSelectorLookup() {
        let readings = [reading("Tp04", .cpu, 50), reading("Tg08", .gpu, 70)]
        let snapshot = SensorSnapshot(readings: readings, aggregates: SensorAggregates.compute(from: readings))
        XCTAssertEqual(snapshot.value(for: .highest), 70)
        XCTAssertEqual(snapshot.value(for: .averageCPU), 50)
        XCTAssertEqual(snapshot.value(for: .computerAverage), 60)
        XCTAssertEqual(snapshot.value(for: .sensor("smc:Tg08")), 70)
        XCTAssertNil(snapshot.value(for: .sensor("smc:nope")))
    }
}
