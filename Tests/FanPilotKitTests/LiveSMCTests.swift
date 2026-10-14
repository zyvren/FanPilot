import CSMC
import XCTest
@testable import FanPilotKit

/// Read-only sanity checks against the real AppleSMC and IOHID. They skip themselves where the
/// hardware is unavailable. Nothing here can write: connections are opened `.readOnly` and the
/// write counter of the C layer is asserted to stay at zero.
final class LiveSMCTests: XCTestCase {
    private func openSMC() throws -> IOKitSMC {
        do {
            return try IOKitSMC(access: .readOnly)
        } catch {
            throw XCTSkip("AppleSMC unavailable: \(error)")
        }
    }

    func testLiveFanAndTemperatureReads() throws {
        let smc = try openSMC()
        let writesBefore = fp_smc_stat_writes()

        let fanCount = try smc.readUInt8(SMCKeys.fanCount)
        print("[live] FNum = \(fanCount)")
        XCTAssertLessThanOrEqual(fanCount, 10)

        if fanCount > 0 {
            let info = try smc.keyInfo("F0Mx")
            let max = try smc.readFloat("F0Mx")
            let min = try smc.readFloat("F0Mn")
            let actual = try smc.readFloat("F0Ac")
            let target = try smc.keyInfo("F0Tg")
            print("[live] F0Mx = \(max) RPM (type \(info.type), size \(info.size), attr 0x\(String(info.attributes, radix: 16)))")
            print("[live] F0Mn = \(min) RPM, F0Ac = \(actual) RPM, F0Tg info: type \(target.type) attr 0x\(String(target.attributes, radix: 16))")
            XCTAssertGreaterThan(max, min)
            XCTAssertGreaterThan(min, 0)
            XCTAssertLessThan(max, 20_000)
            XCTAssertGreaterThanOrEqual(actual, 0)
        }

        let keyCount = try smc.keyCount
        print("[live] #KEY = \(keyCount)")
        XCTAssertGreaterThan(keyCount, 100)

        // First plausible float temperature key, by SMC enumeration order.
        var found: (FourCC, Float)?
        for index in 0..<keyCount {
            let key = try smc.key(at: index)
            guard key.string.hasPrefix("T"), let value = try? smc.read(key),
                  let t = value.floatValue, Constants.isValidTemperature(Double(t)) else { continue }
            found = (key, t)
            break
        }
        let (tempKey, temp) = try XCTUnwrap(found, "no valid T* key found")
        print("[live] first valid temperature key: \(tempKey) = \(temp) C")

        XCTAssertFalse(try smc.exists("ZZZZ"), "a missing key is reported as missing, not as an error")
        XCTAssertEqual(fp_smc_stat_writes(), writesBefore, "read-only sanity test must not write")
    }

    func testReadOnlyConnectionRefusesWritesBeforeTouchingHardware() throws {
        let smc = try openSMC()
        let writesBefore = fp_smc_stat_writes()
        // F0Tg is writable by attribute on this Mac; the connection mode is what protects it.
        XCTAssertThrowsError(try smc.write("F0Tg", bytes: SMCCodec.encodeFloat(0))) {
            XCTAssertEqual($0 as? SMCError, .writeNotPermitted("F0Tg"))
        }
        XCTAssertThrowsError(try smc.write("NoSK", bytes: [0]))
        XCTAssertEqual(fp_smc_stat_writes(), writesBefore)
    }

    func testKeyEnumerationIsConsistentAndMatchesCount() throws {
        let smc = try openSMC()
        let keys = try smc.allKeys()
        XCTAssertEqual(keys.count, try smc.keyCount)
        XCTAssertEqual(Set(keys).count, keys.count, "SMC key names are unique")
        XCTAssertTrue(keys.contains(SMCKeys.keyCount))
    }

    func testConcurrentReadsAreSerialized() throws {
        let smc = try openSMC()
        let done = expectation(description: "all readers finished")
        done.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global().async {
                for _ in 0..<50 { _ = try? smc.read(SMCKeys.fanCount) }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try smc.readUInt8(SMCKeys.fanCount), try smc.readUInt8(SMCKeys.fanCount))
    }

    func testClosedConnectionThrows() throws {
        let smc = try openSMC()
        smc.close()
        XCTAssertThrowsError(try smc.read(SMCKeys.fanCount)) { XCTAssertEqual($0 as? SMCError, .closed) }
    }

    func testLiveHIDTemperatures() throws {
        guard HIDThermal.isAvailable else { throw XCTSkip("private IOHID symbols not available") }
        let readings = HIDThermal.readTemperatures()
        print("[live] HID services: \(readings.count)")
        for r in readings.prefix(3) {
            print("[live]   \(r.product) loc=\(r.locationID.map(String.init) ?? "-") value=\(r.hasValue ? String(format: "%.2f", r.value) : "n/a")")
        }
        if readings.isEmpty { throw XCTSkip("no HID temperature services on this machine") }
        XCTAssertTrue(readings.contains { $0.hasValue && Constants.isValidTemperature($0.value) },
                      "at least one HID sensor should report a plausible temperature")
        XCTAssertFalse(readings.contains { $0.product.isEmpty && $0.hasValue })
        // A second pass reuses the cached client.
        XCTAssertEqual(HIDThermal.readTemperatures().count, readings.count)
        HIDThermal.reset()
        XCTAssertEqual(HIDThermal.readTemperatures().count, readings.count)
    }
}
