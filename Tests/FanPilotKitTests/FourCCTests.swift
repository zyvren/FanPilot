import XCTest
@testable import FanPilotKit

final class FourCCTests: XCTestCase {
    /// `FourCC("ABCD")` with a literal argument resolves to the (trapping) literal initializer, so
    /// anything that must go through the failable `init?(_:)` is passed via a variable.
    private func parse(_ text: String) -> FourCC? { FourCC(text) }

    func testPackingIsBigEndian() {
        let key: FourCC = "F0Tg"
        XCTAssertEqual(key.rawValue, UInt32(0x46) << 24 | UInt32(0x30) << 16 | UInt32(0x54) << 8 | UInt32(0x67))
        XCTAssertEqual(key.bytes, [0x46, 0x30, 0x54, 0x67])
        XCTAssertEqual(key.string, "F0Tg")
    }

    func testTrailingSpaceIsSignificant() {
        XCTAssertEqual(FourCC.flt.string, "flt ")
        XCTAssertEqual(FourCC.flt.bytes, [0x66, 0x6C, 0x74, 0x20])
        XCTAssertEqual(SMCKeys.fanForceBits.string, "FS! ")
        XCTAssertNil(parse("flt"))   // three characters are not a code
    }

    func testFailableInit() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("abc"))
        XCTAssertNil(parse("abcde"))
        XCTAssertNil(parse("ab€d"))
        XCTAssertEqual(parse("#KEY"), SMCKeys.keyCount)
        XCTAssertEqual(parse("é123")?.bytes.first, 0xE9, "Latin-1 range is accepted")
    }

    func testNonPrintableBytesAreMasked() {
        let weird = FourCC(rawValue: 0x00415A07)
        XCTAssertEqual(weird.string, "?AZ?")
    }

    func testFanKeyBuilder() {
        XCTAssertEqual(SMCKeys.fan(0, .target), "F0Tg")
        XCTAssertEqual(SMCKeys.fan(1, .modeLower), "F1md")
        XCTAssertEqual(SMCKeys.fan(9, .maximum), "F9Mx")
        XCTAssertNil(SMCKeys.fan(10, .target), "two-digit fan numbers would alias another fan")
        XCTAssertNil(SMCKeys.fan(-1, .target))
    }

    func testCodableUsesPlainString() throws {
        let data = try JSONEncoder().encode(["k": FourCC("F0md")])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"k":"F0md"}"#)
        let back = try JSONDecoder().decode([String: FourCC].self, from: data)
        XCTAssertEqual(back["k"], "F0md")
        XCTAssertThrowsError(try JSONDecoder().decode([String: FourCC].self, from: Data(#"{"k":"toolong"}"#.utf8)))
    }

    func testOrderingFollowsRawValue() {
        XCTAssertLessThan(FourCC("F0Ac"), FourCC("F0Tg"))
        XCTAssertEqual(["F1md", "F0Tg", "F0Ac"].map { parse($0)! }.sorted().map(\.string), ["F0Ac", "F0Tg", "F1md"])
    }
}
