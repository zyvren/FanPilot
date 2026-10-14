import FanPilotKit
import XCTest
@testable import FanPilotSensors

final class CatalogTests: XCTestCase {
    func testEveryModelHasWellFormedUniqueRows() {
        XCTAssertGreaterThanOrEqual(SensorCatalog.knownModels.count, 59)
        for model in SensorCatalog.knownModels {
            let rows = SensorCatalog.rows(forModel: model)
            XCTAssertNotNil(rows, model)
            guard let rows, !rows.isEmpty else { XCTFail("\(model) has no rows"); continue }

            XCTAssertEqual(Set(rows.map(\.key)).count, rows.count, "\(model): duplicate key")
            XCTAssertEqual(Set(rows.map(\.name)).count, rows.count, "\(model): duplicate name")
            for row in rows {
                XCTAssertFalse(row.name.isEmpty, "\(model) \(row.key)")
                if row.source == .smc {
                    XCTAssertEqual(row.key.utf8.count, 4, "\(model): SMC key \(row.key) is not four characters")
                    XCTAssertTrue(["T", "f", "s"].contains(String(row.key.prefix(1))), "\(model): \(row.key)")
                } else {
                    XCTAssertGreaterThan(row.key.count, 4, "\(model): HID name \(row.key)")
                }
                XCTAssertFalse(row.name.contains("Cores)"), "\(model): mangled label \(row.name)")
            }
        }
    }

    func testMac17_8MatchesSpecTable() throws {
        let rows = try XCTUnwrap(SensorCatalog.rows(forModel: "Mac17,8"))
        func keys(_ area: SensorArea) -> [String] { rows.filter { $0.area == area }.map(\.key) }

        XCTAssertEqual(keys(.cpu), ["Tp04", "Tp0G", "Tp0R", "Tp0a", "Tp0j", "Tp0u",
                                    "Tm04", "Tm0G", "Tm0R", "Tm0a", "Tm0j", "Tm0u", "Tm1Q", "Tm1c", "Tm1o", "Tm21", "Tm2D", "Tm2P"])
        XCTAssertEqual(rows.filter { $0.name.hasPrefix("Super Core") }.count, 6)
        XCTAssertEqual(rows.filter { $0.name.hasPrefix("Performance Core") }.count, 12)
        XCTAssertEqual(keys(.gpu), ["Tg08", "Tg12", "Tg29", "Tg3B", "Tg43", "Tg50"])
        XCTAssertEqual(keys(.battery), ["TB0T", "TB1T", "TB2T", "gas gauge battery 0"])
        XCTAssertEqual(keys(.airflow), ["TaLP", "TaRF", "TaTP"])
        XCTAssertEqual(keys(.storage), ["TH0a", "NAND CH0 temp"])
        XCTAssertEqual(keys(.power), ["TCHP", "TPSP"])
        XCTAssertEqual(keys(.thunderbolt), ["TaLT", "TaRT"])
        XCTAssertEqual(keys(.palmRest), ["Ts0P", "Ts1P"])
        XCTAssertEqual(keys(.wireless), ["TW0P"])
        XCTAssertEqual(rows.count, 40, "38 SMC keys and 2 HID names")
        XCTAssertEqual(rows.filter { $0.source == .hid }.map(\.key), ["gas gauge battery 0", "NAND CH0 temp"])

        XCTAssertEqual(rows.first { $0.key == "Tp04" }?.name, "Super Core 1")
        XCTAssertEqual(rows.first { $0.key == "Tm2P" }?.name, "Performance Core 12")
        XCTAssertEqual(rows.first { $0.key == "Tm0u" }?.name, "Performance Core 6", "assembled row repaired")
    }

    func testM5ProMaxVariantsShareOneList() {
        let reference = SensorCatalog.rows(forModel: "Mac17,8")
        for model in ["Mac17,6", "Mac17,7", "Mac17,9"] {
            XCTAssertEqual(SensorCatalog.rows(forModel: model), reference, model)
        }
    }

    func testUnknownModelHasNoCatalog() {
        XCTAssertNil(SensorCatalog.rows(forModel: "Mac99,1"))
        XCTAssertFalse(SensorCatalog.isKnown(model: "MacBookPro11,1"), "Intel models are not in the Apple Silicon catalog")
    }

    func testDamagedSourceRowsWereRepaired() throws {
        func keys(_ model: String) throws -> Set<String> {
            Set(try XCTUnwrap(SensorCatalog.rows(forModel: model), model).map(\.key))
        }
        // Keys that the table walker saw as split string pieces.
        XCTAssertTrue(try keys("Mac14,5").isSuperset(of: ["Tp1B", "Tg1h"]))
        XCTAssertTrue(try keys("Mac15,8").contains("ftPb"))
        XCTAssertTrue(try keys("Mac16,5").contains("Tp0e"))
        XCTAssertTrue(try keys("Mac16,7").contains("Tp09"))
        XCTAssertTrue(try keys("Mac13,2").contains("Tp09"))
        // Truncated keys.
        XCTAssertTrue(try keys("Mac16,1").contains("Ts0P"))
        XCTAssertTrue(try keys("Mac15,4").contains("TIOP"))
        // Rows lost entirely are restored for the M1 Pro/Max/Ultra family.
        for model in ["Mac13,1", "Mac13,2", "MacBookPro18,1", "MacBookPro18,4"] {
            XCTAssertTrue(try keys(model).isSuperset(of: ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tm01", "Tm05", "Tm09", "Tm0D"]), model)
        }
        // Models the walker produced nothing for.
        XCTAssertEqual(SensorCatalog.rows(forModel: "Mac14,2"), SensorCatalog.rows(forModel: "Mac14,15"))
        XCTAssertNotNil(SensorCatalog.rows(forModel: "iMac21,2"))
        // Labels were cleaned.
        let gpu = try XCTUnwrap(SensorCatalog.rows(forModel: "Mac14,15")).filter { $0.area == .gpu }
        XCTAssertEqual(gpu.map(\.name), ["GPU Cluster 1", "GPU Cluster 2"])
    }

    func testHIDDieSensorsOfOlderChipsLandInSoCDie() throws {
        let rows = try XCTUnwrap(SensorCatalog.rows(forModel: "MacBookPro17,1"))
        XCTAssertEqual(rows.first { $0.key == "PMU tdie1" }?.area, .soc)
        XCTAssertEqual(rows.first { $0.key == "eACC MTR Temp Sensor0" }?.area, .cpu)
        XCTAssertEqual(rows.first { $0.key == "eACC MTR Temp Sensor0" }?.source, .hid)
        XCTAssertEqual(rows.first { $0.key == "gas gauge battery 0" }?.area, .battery)
    }
}
