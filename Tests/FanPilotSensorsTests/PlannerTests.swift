import FanPilotKit
import XCTest
@testable import FanPilotSensors

final class PlannerTests: XCTestCase {
    private func smcValues(_ smc: InMemorySMC) -> [String: Double] {
        let reader = SMCSensorReader(smc: smc)
        _ = try? reader.enumerate()
        return reader.readCandidates()
    }

    private func m5Plan(sticky: Set<String> = [], mutate: (inout [String: Double]) -> Void = { _ in }) -> SensorPlan {
        var values = smcValues(Fixtures.m5ProSMC())
        mutate(&values)
        return SensorPlanner.plan(hardware: Fixtures.m5Pro, smc: values, hid: Fixtures.m5ProHID(), sticky: sticky)
    }

    // MARK: Exact model (Mac17,8)

    func testMac17_8PlanMatchesSpecGroups() throws {
        let plan = m5Plan()
        XCTAssertEqual(plan.catalogModel, "Mac17,8")

        func names(_ area: SensorArea) -> [String] { plan.sensors.filter { $0.area == area }.map(\.name) }
        XCTAssertEqual(names(.cpu).filter { $0.hasPrefix("Super Core") }.count, 6)
        XCTAssertEqual(names(.cpu).filter { $0.hasPrefix("Performance Core") }.count, 12)
        XCTAssertEqual(names(.gpu), ["GPU Region 1", "GPU Region 2", "GPU Region 3", "GPU Region 4", "GPU Region 5"],
                       "Tg50 is absent on the real unit, Tg43 present")
        XCTAssertEqual(names(.battery), ["Battery", "Battery Management Unit", "Battery Proximity", "Battery Gas Gauge"])
        XCTAssertEqual(names(.airflow), ["Airflow Left", "Airflow Right", "Airflow Top"])
        XCTAssertEqual(names(.storage), ["SSD", "SSD (NAND I/O)"])
        XCTAssertEqual(names(.power), ["Charger Proximity", "Power Supply Proximity"])
        XCTAssertEqual(names(.thunderbolt), ["Left Thunderbolt Ports Proximity", "Right Thunderbolt Ports Proximity"])
        XCTAssertEqual(names(.palmRest), ["Trackpad", "Trackpad Actuator"])
        XCTAssertEqual(names(.wireless), ["Wireless Proximity"])
        XCTAssertEqual(names(.soc), (1...14).map { "SoC Die \($0)" })
    }

    func testAreasAreOrderedAndSensorIDsUnique() {
        let plan = m5Plan()
        let areas = plan.sensors.map(\.area)
        XCTAssertEqual(areas, areas.sorted(), "plan is sorted by area")
        XCTAssertEqual(Set(plan.sensors.map(\.id)).count, plan.sensors.count)
        XCTAssertEqual(plan.sensors.first?.id, "smc:Tp04")
    }

    func testRemainingValidKeysGoToOther() {
        let plan = m5Plan()
        let other = Dictionary(uniqueKeysWithValues: plan.sensors.filter { $0.area == .other }.map { ($0.key, $0) })
        for key in ["Tp00", "Tp08", "Ts00", "Tm00", "Tg05", "TCMb", "TVD0", "TPD0", "TRD0", "TUD0", "Ta00", "TN00", "TAOL",
                    "Tf00", "sd00", "ftVV", "ftD0"] {
            XCTAssertNotNil(other[key], "\(key) should be listed under Other")
            XCTAssertEqual(other[key]?.name, key)
        }
        // Extra HID gas gauges are Other too, named after their index.
        XCTAssertEqual(other["gas gauge battery 1"]?.name, "Battery Gas Gauge 2")
    }

    func testDecoysNeverBecomeSensors() {
        let keys = Set(m5Plan().sensors.map(\.key))
        for decoy in ["TG0B", "TV0i", "TTPD", "TVMD", "TVmS", "Tz11", "TfCB", "fRof", "fuFa", "fcB0", "f000", "PSTR", "Tg50"] {
            XCTAssertFalse(keys.contains(decoy), "\(decoy) must not be a sensor")
        }
    }

    func testInvalidCatalogValueIsOmittedUnlessSticky() {
        let broken: (inout [String: Double]) -> Void = { $0["Tp04"] = 5.0; $0["Tm0G"] = 130.0 }
        let fresh = m5Plan(mutate: broken)
        XCTAssertFalse(fresh.sensors.contains { $0.key == "Tp04" })
        XCTAssertFalse(fresh.sensors.contains { $0.key == "Tm0G" })

        let sticky = m5Plan(sticky: ["smc:Tp04", "smc:Tm0G"], mutate: broken)
        XCTAssertTrue(sticky.sensors.contains { $0.key == "Tp04" }, "a shown sensor stays while it is N/A")
        XCTAssertTrue(sticky.sensors.contains { $0.key == "Tm0G" })
    }

    func testMissingHIDDegradesToSMCOnly() {
        let plan = SensorPlanner.plan(hardware: Fixtures.m5Pro, smc: smcValues(Fixtures.m5ProSMC()), hid: [])
        XCTAssertTrue(plan.sensors.allSatisfy { $0.source == .smc })
        XCTAssertTrue(plan.sensors.contains { $0.key == "Tp04" })
    }

    // MARK: Unknown model heuristics (SPEC 3.3)

    func testUnknownSuperGenerationModel() {
        let hardware = HardwareInfo(model: "Mac99,9", isAppleSilicon: true,
                                    perfLevels: [PerfLevel(name: "Super", physicalCPUs: 4), PerfLevel(name: "Performance", physicalCPUs: 8)])
        let smc: [String: Double] = ["Tp00": 41, "Tp01": 42, "Tm00": 40, "Tm01": 41, "Tg0K": 40, "TB0T": 32, "TaLP": 40,
                                     "TaLT": 41, "TH0a": 37, "TCHP": 45, "Ts0P": 31, "TW0P": 41, "TVD0": 53, "TCMb": 52]
        let plan = SensorPlanner.plan(hardware: hardware, smc: smc, hid: [])
        XCTAssertNil(plan.catalogModel)
        let byKey = Dictionary(uniqueKeysWithValues: plan.sensors.map { ($0.key, $0) })

        XCTAssertEqual(byKey["Tp00"]?.name, "Super Core 1")
        XCTAssertEqual(byKey["Tp01"]?.name, "Super Core 2")
        XCTAssertEqual(byKey["Tm00"]?.area, .cpu, "Tm is a performance core when the CPU levels are Super/Performance")
        XCTAssertEqual(byKey["Tm00"]?.name, "Performance Core 1")
        XCTAssertEqual(byKey["Tg0K"]?.area, .gpu)
        XCTAssertEqual(byKey["Tg0K"]?.name, "GPU Region 1")
        XCTAssertEqual(byKey["TB0T"]?.area, .battery)
        XCTAssertEqual(byKey["TaLP"]?.area, .airflow)
        XCTAssertEqual(byKey["TaLT"]?.area, .thunderbolt, "Ta + L + T is a Thunderbolt sensor despite the Ta prefix")
        XCTAssertEqual(byKey["TH0a"]?.area, .storage)
        XCTAssertEqual(byKey["TCHP"]?.area, .power)
        XCTAssertEqual(byKey["Ts0P"]?.area, .palmRest)
        XCTAssertEqual(byKey["TW0P"]?.area, .wireless)
        XCTAssertEqual(byKey["TVD0"]?.area, .other)
        XCTAssertEqual(byKey["TCMb"]?.area, .other)
    }

    func testSurplusKeysOfAnUnlistedMacDoNotBecomeNumberedCores() {
        // The real M5 Pro key set, but under a model the catalog does not know.
        let unknown = HardwareInfo(model: "Mac99,9", isAppleSilicon: true, perfLevels: Fixtures.m5Pro.perfLevels)
        var smc: [String: Double] = [:]
        for index in 0..<30 { smc[String(format: "Tp%02X", index)] = 50 }
        for index in 0..<40 { smc[String(format: "Tm%02X", index)] = 50 }
        for index in 0..<60 { smc[String(format: "sd%02X", index)] = 65.28 }   // no efficiency cores on a Super/Performance Mac
        for index in 0..<40 { smc[String(format: "Tg%02X", index)] = 45 }
        smc["TS0P"] = 44
        smc["Ts0P"] = 31

        let plan = SensorPlanner.plan(hardware: unknown, smc: smc, hid: [])
        let cpu = plan.sensors.filter { $0.area == .cpu }
        XCTAssertEqual(cpu.filter { $0.name.hasPrefix("Super Core") }.count, 6)
        XCTAssertEqual(cpu.filter { $0.name.hasPrefix("Performance Core") }.count, 12)
        XCTAssertEqual(cpu.count, 18, "the CPU group matches the 6 + 12 cores, not 130 keys")
        XCTAssertEqual(plan.sensors.filter { $0.area == .gpu }.count, 16)
        XCTAssertTrue(plan.sensors.filter { $0.key.hasPrefix("sd") }.allSatisfy { $0.area == .other })
        XCTAssertEqual(plan.sensors.filter { $0.name == "Trackpad" }.count, 1, "TS0P no longer shares Ts0P's name")
    }

    func testTmMeansMemoryWithoutSuperCores() {
        let plan = SensorPlanner.plan(hardware: Fixtures.m2Pro,
                                      smc: ["Tm01": 40, "Tm05": 41, "Tp01": 44, "Tp05": 45, "Te05": 38, "Tg0f": 39], hid: [])
        let byKey = Dictionary(uniqueKeysWithValues: plan.sensors.map { ($0.key, $0) })
        XCTAssertEqual(byKey["Tm01"]?.area, .memory, "Tm flips meaning between generations (SPEC 3.3)")
        XCTAssertEqual(byKey["Tm01"]?.name, "Memory Bank 1")
        XCTAssertEqual(byKey["Tp01"]?.area, .cpu)
        XCTAssertEqual(byKey["Tp01"]?.name, "CPU Core 1")
        XCTAssertEqual(byKey["Te05"]?.name, "Efficiency Core 1")
        XCTAssertEqual(byKey["Tg0f"]?.name, "GPU Cluster 1")
    }

    func testHeuristicsDoNotApplyToCatalogModels() {
        // Same keys on a catalog model: leftovers stay in Other instead of being classified by prefix.
        let smc: [String: Double] = ["Tp04": 41, "Tp00": 42, "Tm00": 40]
        let plan = SensorPlanner.plan(hardware: Fixtures.m5Pro, smc: smc, hid: [])
        XCTAssertEqual(plan.sensors.first { $0.key == "Tp04" }?.area, .cpu)
        XCTAssertEqual(plan.sensors.first { $0.key == "Tp00" }?.area, .other)
        XCTAssertEqual(plan.sensors.first { $0.key == "Tm00" }?.area, .other)
    }

    func testAreasTheCatalogIsSilentAboutFallBackToHeuristics() throws {
        // Mac14,13's recovered list stops after the CPU rows.
        let hardware = HardwareInfo(model: "Mac14,13", isAppleSilicon: true,
                                    perfLevels: [PerfLevel(name: "Performance", physicalCPUs: 8), PerfLevel(name: "Efficiency", physicalCPUs: 4)])
        XCTAssertEqual(Set(try XCTUnwrap(SensorCatalog.rows(forModel: "Mac14,13")).map(\.area)), [.cpu])
        let smc: [String: Double] = ["Tp05": 41, "Tp0X": 42, "Tp99": 43, "Tg0D": 40, "Tg0L": 41, "TB0T": 32, "TH0a": 36,
                                     "TaLP": 39, "TCMb": 50]
        let plan = SensorPlanner.plan(hardware: hardware, smc: smc, hid: [])
        let byKey = Dictionary(uniqueKeysWithValues: plan.sensors.map { ($0.key, $0) })
        XCTAssertEqual(plan.catalogModel, "Mac14,13")
        XCTAssertEqual(byKey["Tp05"]?.name, "Efficiency Core 1", "listed sensors keep their catalog names")
        XCTAssertEqual(byKey["Tp99"]?.area, .other, "the list is the authority for CPU sensors")
        XCTAssertEqual(byKey["Tg0D"]?.area, .gpu)
        XCTAssertEqual(byKey["Tg0D"]?.name, "GPU Cluster 1")
        XCTAssertEqual(byKey["Tg0L"]?.name, "GPU Cluster 2")
        XCTAssertEqual(byKey["TB0T"]?.area, .battery)
        XCTAssertEqual(byKey["TH0a"]?.area, .storage)
        XCTAssertEqual(byKey["TaLP"]?.area, .airflow)
        XCTAssertEqual(byKey["TCMb"]?.area, .other)
    }

    func testHeuristicHIDNames() {
        XCTAssertEqual(SensorClassifier.classify(hidName: "PMU tdie7"), SensorClassification(name: "SoC Die 7", area: .soc))
        XCTAssertEqual(SensorClassifier.classify(hidName: "NAND CH0 temp").area, .storage)
        XCTAssertEqual(SensorClassifier.classify(hidName: "gas gauge battery 0").area, .battery)
        XCTAssertEqual(SensorClassifier.classify(hidName: "gas gauge battery 3").area, .other)
        XCTAssertEqual(SensorClassifier.classify(hidName: "mystery").area, .other)
    }

    func testIntelHeuristics() {
        let smc: [String: Double] = ["TC0P": 55, "TC1C": 60, "TC2C": 61, "TCXC": 62, "TG0D": 50, "TB0T": 30, "TH0a": 35,
                                     "TA0P": 28, "TW0P": 40, "Ts0P": 29, "TM0P": 45]
        let plan = SensorPlanner.plan(hardware: Fixtures.intel, smc: smc, hid: [])
        let byKey = Dictionary(uniqueKeysWithValues: plan.sensors.map { ($0.key, $0) })
        XCTAssertEqual(byKey["TC1C"]?.area, .cpu)
        XCTAssertEqual(byKey["TC1C"]?.name, "CPU Core 1")
        XCTAssertEqual(byKey["TC2C"]?.name, "CPU Core 2")
        XCTAssertEqual(byKey["TC0P"]?.area, .cpu)
        XCTAssertEqual(byKey["TCXC"]?.area, .cpu)
        XCTAssertEqual(byKey["TG0D"]?.area, .gpu)
        XCTAssertEqual(byKey["TB0T"]?.area, .battery)
        XCTAssertEqual(byKey["TH0a"]?.area, .storage)
        XCTAssertEqual(byKey["TA0P"]?.area, .airflow)
        XCTAssertEqual(byKey["TW0P"]?.area, .wireless)
        XCTAssertEqual(byKey["Ts0P"]?.area, .palmRest)
        XCTAssertEqual(byKey["TM0P"]?.area, .memory)
        XCTAssertNil(plan.catalogModel)
    }

    // MARK: Hot set

    func testHotSetMembership() {
        func sensor(_ key: String, _ area: SensorArea, _ source: SensorSource = .smc) -> Sensor {
            Sensor(id: Sensor.makeID(source: source, key: key), key: key, name: key, area: area, source: source)
        }
        XCTAssertTrue(HotSet.contains(sensor("Tp04", .cpu)))
        XCTAssertTrue(HotSet.contains(sensor("Tg08", .gpu)))
        XCTAssertTrue(HotSet.contains(sensor("PMU tdie1", .soc, .hid)))
        XCTAssertTrue(HotSet.contains(sensor("TVD0", .other)))
        XCTAssertTrue(HotSet.contains(sensor("TCMb", .other)))
        XCTAssertTrue(HotSet.contains(sensor("Tp00", .other)))
        XCTAssertFalse(HotSet.contains(sensor("Ta00", .other)))
        XCTAssertFalse(HotSet.contains(sensor("TN00", .other)))
        XCTAssertFalse(HotSet.contains(sensor("TB0T", .battery)))
        XCTAssertFalse(HotSet.contains(sensor("TaLP", .airflow)))
        XCTAssertFalse(HotSet.contains(sensor("Ts0P", .palmRest)))
        XCTAssertFalse(HotSet.contains(sensor("TW0P", .wireless)))
        XCTAssertFalse(HotSet.contains(sensor("TH0a", .storage)))
        XCTAssertFalse(HotSet.contains(sensor("gas gauge battery 2", .other, .hid)))
    }
}
