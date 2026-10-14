import XCTest
@testable import FanPilotKit

final class SMCClientTests: XCTestCase {
    func testFixtureMirrorsProbeFanKeys() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        XCTAssertEqual(try smc.readUInt8(SMCKeys.fanCount), 2)
        XCTAssertEqual(try smc.readFloat("F0Mn"), 1350)
        XCTAssertEqual(try smc.readFloat("F0Mx"), 5349)
        XCTAssertEqual(try smc.readFloat("F1Mx"), 5777)
        XCTAssertEqual(try smc.keyInfo("F0Tg"), SMCKeyInfo(size: 4, type: .flt, attributes: 0xD4))
        XCTAssertEqual(try smc.keyInfo("F0md"), SMCKeyInfo(size: 1, type: .ui8, attributes: 0xD0))
        XCTAssertFalse(try smc.exists("Ftst"))
        XCTAssertFalse(try smc.exists("FS! "))
        XCTAssertFalse(try smc.exists("F0Md"))
    }

    func testKeyInfoFlags() {
        XCTAssertTrue(SMCKeyInfo(size: 4, type: .flt, attributes: 0xD4).isWritable)
        XCTAssertTrue(SMCKeyInfo(size: 4, type: .flt, attributes: 0xD4).isReadable)
        XCTAssertFalse(SMCKeyInfo(size: 4, type: .flt, attributes: 0x84).isWritable)
        XCTAssertTrue(SMCKeyInfo(size: 4, type: .flt, attributes: 0x85).isReadable)
        XCTAssertFalse(SMCKeyInfo(size: 1, type: .ui8, attributes: 0x00).isReadable)
    }

    func testWriteUpdatesValueAndIsLogged() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        try smc.write("F0md", bytes: [1])
        try smc.write("F0Tg", bytes: SMCCodec.encodeFloat(3000))
        XCTAssertEqual(try smc.readUInt8("F0md"), 1)
        XCTAssertEqual(try smc.readFloat("F0Tg"), 3000)
        XCTAssertEqual(smc.writes.map(\.key), ["F0md", "F0Tg"])
    }

    func testWriteRefusesSizeMismatchWithoutChangingAnything() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        // A 2-byte fpe2 payload for a 4-byte flt key is the classic silent no-op when the SMC result byte is ignored.
        XCTAssertThrowsError(try smc.write("F0Tg", bytes: [0x1F, 0x40])) { error in
            XCTAssertEqual(error as? SMCError, .sizeMismatch(key: "F0Tg", expected: 4, actual: 2))
        }
        XCTAssertThrowsError(try smc.write("F0md", bytes: [])) { error in
            XCTAssertEqual(error as? SMCError, .sizeMismatch(key: "F0md", expected: 1, actual: 0))
        }
        XCTAssertTrue(smc.writes.isEmpty)
        XCTAssertEqual(try smc.readFloat("F0Tg"), 0)
    }

    func testWriteRefusesReadOnlyAndMissingKeys() {
        let smc = InMemorySMC.appleSiliconFixture()
        XCTAssertThrowsError(try smc.write("F0Mn", bytes: SMCCodec.encodeFloat(100))) { error in
            XCTAssertEqual(error as? SMCError, .notWritable("F0Mn"))
        }
        XCTAssertThrowsError(try smc.write("Ftst", bytes: [1])) { error in
            XCTAssertEqual(error as? SMCError, .keyNotFound("Ftst"))
        }
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testWriteGuardRejectsOversizedPayload() {
        let info = SMCKeyInfo(size: 32, type: "ch8*", attributes: 0xC0)
        XCTAssertThrowsError(try SMCWriteGuard.validate(key: "ABCD", liveInfo: info, bytes: [UInt8](repeating: 0, count: 33))) {
            XCTAssertEqual($0 as? SMCError, .payloadTooLarge(key: "ABCD", count: 33))
        }
    }

    func testFirmwareRevertCanBeSimulated() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        smc.onWrite = { smc, key, _ in
            if key == "F0md" { smc.setUInt8("F0md", 0, attributes: 0xD0) }   // OS takes the fan back
        }
        try smc.write("F0md", bytes: [1])
        XCTAssertEqual(try smc.readUInt8("F0md"), 0)
    }

    func testWriteVerifiedDetectsAnOsRevert() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        try smc.writeVerified("F0md", bytes: [1])
        XCTAssertEqual(try smc.readUInt8("F0md"), 1)

        smc.onWrite = { smc, key, _ in
            if key == "F0md" { smc.setUInt8("F0md", 0, attributes: 0xD0) }
        }
        XCTAssertThrowsError(try smc.writeVerified("F0md", bytes: [1])) {
            XCTAssertEqual($0 as? SMCError, .readbackMismatch(key: "F0md", expected: [1], actual: [0]))
            XCTAssertTrue(($0 as? SMCError)?.description.contains("reads back 00 after writing 01") ?? false)
        }
    }

    func testFailingWriteSurfacesSMCResult() {
        let smc = InMemorySMC.appleSiliconFixture()
        smc.failWrites(to: "F0md")
        XCTAssertThrowsError(try smc.write("F0md", bytes: [1])) {
            XCTAssertEqual($0 as? SMCError, .smcResult(key: "F0md", command: 6, result: 0x86))
        }
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testEnumeration() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        let keys = try smc.allKeys()
        XCTAssertEqual(keys.count, try smc.keyCount)
        XCTAssertEqual(keys.first, "FNum")
        XCTAssertTrue(keys.contains("F1Mx"))
        XCTAssertThrowsError(try smc.key(at: keys.count)) { XCTAssertEqual($0 as? SMCError, .indexOutOfRange(keys.count)) }
    }

    func testReadNumberHandlesMissingAndNonNumeric() throws {
        let smc = InMemorySMC.appleSiliconFixture()
        smc.set("TG0B", type: .ioft, attributes: 0x85, bytes: [UInt8](repeating: 1, count: 8))
        XCTAssertEqual(try smc.readNumber("F1Mx"), 5777)
        XCTAssertNil(try smc.readNumber("Nope"))
        XCTAssertNil(try smc.readNumber("TG0B"))
    }

    func testErrorDescriptionsAreInformative() {
        XCTAssertTrue(SMCError.writeNotPermitted("F0Tg").description.contains("read-only"))
        XCTAssertTrue(SMCError.sizeMismatch(key: "F0Tg", expected: 4, actual: 2).description.contains("F0Tg"))
        XCTAssertTrue(SMCError.smcResult(key: "F0Tg", command: 5, result: 0x85).description.contains("0x85"))
    }
}
