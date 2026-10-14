import FanPilotKit
import XCTest
@testable import FanPilotSensors

final class FanReaderTests: XCTestCase {
    func testDiscoversTheM5ProFans() throws {
        let reader = FanReader(smc: InMemorySMC.appleSiliconFixture(), model: "Mac17,8")
        let found = try reader.discover()

        XCTAssertEqual(found.fans.count, 2)
        XCTAssertEqual(found.fans.map(\.name), ["Left Side", "Right Side"])
        XCTAssertEqual(found.fans.map(\.minRPM), [1350, 1350])
        XCTAssertEqual(found.fans.map(\.maxRPM), [5349, 5777])
        XCTAssertEqual(found.fans[0].backend, .appleSiliconMd(modeKey: "F0md"))
        XCTAssertEqual(found.fans[1].modeKey, "F1md")
        XCTAssertFalse(found.hasFtst)
        XCTAssertFalse(found.hasDICT)
        XCTAssertFalse(found.hasForceBits)
        XCTAssertEqual(reader.fans, found.fans)
    }

    func testLiveReadings() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        let reader = FanReader(smc: smc, model: "Mac17,8")
        try reader.discover()

        var readings = reader.readAll()
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].actualRPM, 0, "0 RPM in auto is legitimate on Mac17,x")
        XCTAssertEqual(readings[0].mode, 0)
        XCTAssertEqual(readings[1].maxRPM, 5777)

        smc.setFloat("F0Ac", 3210.5)
        smc.setFloat("F0Tg", 3200)
        smc.setUInt8("F0md", 1, attributes: 0xd0)
        readings = reader.readAll()
        XCTAssertEqual(readings[0].actualRPM, 3210.5)
        XCTAssertEqual(readings[0].targetRPM, 3200)
        XCTAssertEqual(readings[0].mode, 1)
        XCTAssertTrue(readings[0].isManual)
        XCTAssertTrue(smc.writes.isEmpty, "reading never writes")
    }

    func testFanNames() {
        XCTAssertEqual(FanNaming.names(count: 1, model: "Mac17,8"), ["Main Fan"])
        XCTAssertEqual(FanNaming.names(count: 2, model: "Mac17,8"), ["Left Side", "Right Side"])
        XCTAssertEqual(FanNaming.names(count: 2, model: "Macmini9,1"), ["Fan 1", "Fan 2"])
        XCTAssertEqual(FanNaming.names(count: 3, model: "Mac17,8"), ["Fan 1", "Fan 2", "Fan 3"])
        XCTAssertEqual(FanNaming.names(count: 2, model: "X", ids: ["Exhaust", nil]), ["Exhaust", "Fan 2"])
        XCTAssertEqual(FanNaming.names(count: 0, model: "Mac17,8"), [])
    }

    func testNoFansMeansEmptyDiscovery() throws {
        let reader = FanReader(smc: InMemorySMC(), model: "Mac15,13")
        XCTAssertEqual(try reader.discover().fans, [])
        XCTAssertEqual(reader.readAll(), [])
    }

    func testFtstAndDictAreReported() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        smc.setUInt8("Ftst", 0, attributes: 0xd0)
        smc.set("DICT", type: .flag, attributes: 0x80, bytes: [0])
        smc.set("FBAD", type: .hex, attributes: 0xd0, bytes: [0])
        let reader = FanReader(smc: smc, model: "Mac16,6")
        let found = try reader.discover()
        XCTAssertTrue(found.hasFtst)
        XCTAssertTrue(found.fans.allSatisfy(\.hasFtst))
        XCTAssertTrue(found.hasDICT)
        XCTAssertTrue(found.hasBadFanMask)
        XCTAssertEqual(reader.readOverrideFlag(), false)
        smc.set("DICT", type: .flag, attributes: 0x80, bytes: [1])
        XCTAssertEqual(reader.readOverrideFlag(), true)
        XCTAssertEqual(reader.readBadFanMask(), 0)
        smc.set("FBAD", type: .hex, attributes: 0xd0, bytes: [2])
        XCTAssertEqual(reader.readBadFanMask(), 2)
    }

    func testT2StyleUppercaseModeKeyWithFPE2Target() throws {
        let smc = InMemorySMC()
        smc.setUInt8("FNum", 1)
        smc.set("F0Ac", type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(1800)!)
        smc.set("F0Mn", type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(1200)!)
        smc.set("F0Mx", type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(6000)!)
        smc.set("F0Tg", type: .fpe2, attributes: 0xd0, bytes: SMCCodec.encodeFPE2(1800)!)
        smc.setUInt8("F0Md", 0, attributes: 0xd0)
        let reader = FanReader(smc: smc, model: "MacBookPro16,1")
        let fan = try XCTUnwrap(try reader.discover().fans.first)
        XCTAssertEqual(fan.backend, .appleSiliconMd(modeKey: "F0Md"))
        XCTAssertEqual(fan.name, "Main Fan")
        XCTAssertEqual(fan.maxRPM, 6000)
        XCTAssertEqual(reader.readAll().first?.actualRPM, 1800)
    }

    func testIntelForcedBackendAndBitReading() throws {
        let smc = InMemorySMC()
        smc.setUInt8("FNum", 2)
        for i in 0..<2 {
            smc.set(SMCKeys.fan(i, .actual)!, type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(2000)!)
            smc.set(SMCKeys.fan(i, .minimum)!, type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(1000)!)
            smc.set(SMCKeys.fan(i, .maximum)!, type: .fpe2, attributes: 0x80, bytes: SMCCodec.encodeFPE2(5000)!)
            smc.set(SMCKeys.fan(i, .target)!, type: .fpe2, attributes: 0xd0, bytes: SMCCodec.encodeFPE2(2000)!)
        }
        smc.set("FS! ", type: .ui16, attributes: 0xd0, bytes: [0, 2]) // fan 1 forced
        let reader = FanReader(smc: smc, model: "iMac18,3")
        let found = try reader.discover()
        XCTAssertEqual(found.fans.map(\.backend), [.intelForced, .intelForced])
        XCTAssertTrue(found.hasForceBits)
        XCTAssertEqual(reader.readAll().map(\.mode), [0, 1])
    }

    func testFanWithoutWritableTargetOrSaneLimitsIsMonitorOnly() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        smc.setFloat("F0Tg", 0, attributes: 0x84)     // not writable
        smc.setFloat("F1Mx", 1000, attributes: 0x85)  // max below min
        let found = try FanReader(smc: smc, model: "Mac17,8").discover()
        XCTAssertEqual(found.fans[0].backend, .none)
        XCTAssertNil(found.fans[0].modeKey)
        XCTAssertEqual(found.fans[1].backend, .none)
    }

    func testUnreadableFanIsSkippedNotZero() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        let reader = FanReader(smc: smc, model: "Mac17,8")
        try reader.discover()
        smc.remove("F1Ac")
        XCTAssertEqual(reader.readAll().map(\.index), [0])
    }
}
