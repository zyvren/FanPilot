import XCTest
@testable import FanPilotKit

final class SMCCodecTests: XCTestCase {
    // Raw payloads copied from live SMC reads on an M5 Pro MacBook Pro.

    func testFloatDecodesLittleEndianProbeValues() {
        XCTAssertEqual(SMCCodec.decodeFloat([0x00, 0xC0, 0xA8, 0x44]), 1350.0)   // F0Mn
        XCTAssertEqual(SMCCodec.decodeFloat([0x00, 0x28, 0xA7, 0x45]), 5349.0)   // F0Mx
        XCTAssertEqual(SMCCodec.decodeFloat([0x00, 0x88, 0xB4, 0x45]), 5777.0)   // F1Mx
        XCTAssertEqual(SMCCodec.decodeFloat([0, 0, 0, 0]), 0)
    }

    func testFloatEncodeIsLittleEndianAndRoundTrips() {
        XCTAssertEqual(SMCCodec.encodeFloat(1350), [0x00, 0xC0, 0xA8, 0x44])
        for rpm: Float in [0, 1, 1350, 2999.5, 5777, 16383] {
            XCTAssertEqual(SMCCodec.decodeFloat(SMCCodec.encodeFloat(rpm)), rpm)
        }
    }

    func testFloatRejectsWrongLength() {
        XCTAssertNil(SMCCodec.decodeFloat([]))
        XCTAssertNil(SMCCodec.decodeFloat([0, 0, 0]))
        XCTAssertNil(SMCCodec.decodeFloat([0, 0, 0, 0, 0]))
    }

    func testUnsignedIntegersAreBigEndian() {
        XCTAssertEqual(SMCCodec.decodeUInt8([2]), 2)
        XCTAssertEqual(SMCCodec.decodeUInt16([0x12, 0x34]), 0x1234)
        XCTAssertEqual(SMCCodec.decodeUInt32([0x00, 0x00, 0x0E, 0x2A]), 3626)   // #KEY on this Mac
        XCTAssertEqual(SMCCodec.encodeUInt16(0x1234), [0x12, 0x34])
        XCTAssertEqual(SMCCodec.encodeUInt32(3626), [0, 0, 0x0E, 0x2A])
        XCTAssertNil(SMCCodec.decodeUInt8([]))
        XCTAssertNil(SMCCodec.decodeUInt16([1]))
        XCTAssertNil(SMCCodec.decodeUInt32([1, 2, 3]))
    }

    func testSignedIntegers() {
        XCTAssertEqual(SMCCodec.decodeInt8([0xFF]), -1)
        XCTAssertEqual(SMCCodec.decodeInt8([0x7F]), 127)
        XCTAssertEqual(SMCCodec.decodeInt16([0xFF, 0xFE]), -2)
        XCTAssertEqual(SMCCodec.decodeInt16([0x80, 0x00]), Int16.min)
    }

    func testFPE2EncodesRPMTimesFourBigEndian() {
        // fpe2 is (rpm << 2) & 0xffff, big-endian.
        XCTAssertEqual(SMCCodec.encodeFPE2(2000), [0x1F, 0x40])
        XCTAssertEqual(SMCCodec.encodeFPE2(0), [0, 0])
        XCTAssertEqual(SMCCodec.encodeFPE2(1), [0, 4])
        XCTAssertEqual(SMCCodec.decodeFPE2([0x1F, 0x40]), 2000)
        XCTAssertEqual(SMCCodec.decodeFPE2([0x00, 0x01]), 0.25)
        for rpm in stride(from: 0.0, through: 16383.0, by: 137.0) {
            XCTAssertEqual(SMCCodec.decodeFPE2(SMCCodec.encodeFPE2(rpm)!), rpm)
        }
    }

    func testFPE2RefusesWhatItCannotRepresent() {
        XCTAssertEqual(SMCCodec.encodeFPE2(16383.75), [0xFF, 0xFF])
        XCTAssertNil(SMCCodec.encodeFPE2(16384), "(rpm << 2) would silently wrap here")
        XCTAssertNil(SMCCodec.encodeFPE2(-1))
        XCTAssertNil(SMCCodec.encodeFPE2(.nan))
        XCTAssertNil(SMCCodec.encodeFPE2(.infinity))
    }

    func testSP78() {
        XCTAssertEqual(SMCCodec.decodeSP78([0x1E, 0x80]), 30.5)
        XCTAssertEqual(SMCCodec.decodeSP78([0xFF, 0x00]), -1.0)
        XCTAssertEqual(SMCCodec.encodeSP78(30.5), [0x1E, 0x80])
        XCTAssertEqual(SMCCodec.encodeSP78(-1), [0xFF, 0x00])
        XCTAssertNil(SMCCodec.encodeSP78(128))
        XCTAssertNil(SMCCodec.encodeSP78(.nan))
        for t in stride(from: -20.0, through: 120.0, by: 0.5) {
            XCTAssertEqual(SMCCodec.decodeSP78(SMCCodec.encodeSP78(t)!), t)
        }
    }

    func testNumericDispatchByType() {
        XCTAssertEqual(SMCCodec.decodeNumeric(type: .flt, bytes: [0x00, 0x28, 0xA7, 0x45]), 5349)
        XCTAssertEqual(SMCCodec.decodeNumeric(type: .ui8, bytes: [2]), 2)
        XCTAssertEqual(SMCCodec.decodeNumeric(type: .ui32, bytes: [0, 0, 0x0E, 0x2A]), 3626)
        XCTAssertEqual(SMCCodec.decodeNumeric(type: .sp78, bytes: [0x1E, 0x80]), 30.5)
        XCTAssertEqual(SMCCodec.decodeNumeric(type: .fpe2, bytes: [0x1F, 0x40]), 2000)
        XCTAssertEqual(SMCCodec.decodeNumeric(type: .si8, bytes: [0xFE]), -2)
        // Types without a trustworthy numeric meaning, and size mismatches, give nil.
        XCTAssertNil(SMCCodec.decodeNumeric(type: .ioft, bytes: [UInt8](repeating: 1, count: 8)))
        XCTAssertNil(SMCCodec.decodeNumeric(type: .hex, bytes: [0, 0, 0, 0]))
        XCTAssertNil(SMCCodec.decodeNumeric(type: .flt, bytes: [1, 2]))
        XCTAssertNil(SMCCodec.decodeNumeric(type: "ch8*", bytes: [0x41]))
    }

    func testNumericEncodeRespectsTypeRanges() {
        XCTAssertEqual(SMCCodec.encodeNumeric(1350, type: .flt), [0x00, 0xC0, 0xA8, 0x44])
        XCTAssertEqual(SMCCodec.encodeNumeric(1, type: .ui8), [1])
        XCTAssertNil(SMCCodec.encodeNumeric(256, type: .ui8))
        XCTAssertNil(SMCCodec.encodeNumeric(-1, type: .ui8))
        XCTAssertNil(SMCCodec.encodeNumeric(.nan, type: .flt))
        XCTAssertNil(SMCCodec.encodeNumeric(1e39, type: .flt), "overflows float32")
        XCTAssertNil(SMCCodec.encodeNumeric(1, type: .ioft))
    }
}
