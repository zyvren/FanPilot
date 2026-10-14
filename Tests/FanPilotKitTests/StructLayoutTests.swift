import CSMC
import XCTest

/// The kernel interface is positional; these are the Swift-side mirror of the C _Static_asserts,
/// so a header edit that Swift imports differently is caught too.
final class StructLayoutTests: XCTestCase {
    func testSizeAndOffsets() {
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.key), 0)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.vers), 4)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.pLimitData), 12)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo.dataSize), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo.dataType), 32)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo.dataAttributes), 36)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.status), 41)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.bytes), 48)
    }

    func testPayloadHelpersRoundTripAndClamp() {
        var data = SMCKeyData_t()
        let payload: [UInt8] = [1, 2, 3, 4]
        fp_smc_set_bytes(&data, payload, payload.count)
        var out = [UInt8](repeating: 0xEE, count: 6)
        fp_smc_get_bytes(&data, &out, 6)
        XCTAssertEqual(out, [1, 2, 3, 4, 0, 0])

        // Oversized requests are clamped to the 32 byte payload instead of overrunning.
        let big = [UInt8](repeating: 7, count: 100)
        fp_smc_set_bytes(&data, big, big.count)
        var all = [UInt8](repeating: 0, count: 100)
        fp_smc_get_bytes(&data, &all, 100)
        XCTAssertEqual(Array(all[0..<32]), [UInt8](repeating: 7, count: 32))
        XCTAssertEqual(Array(all[32...]), [UInt8](repeating: 0, count: 68))
    }

    func testReadEntryPointRefusesWriteCommand() {
        let writesBefore = fp_smc_stat_writes()
        var input = SMCKeyData_t()
        input.data8 = UInt8(FP_SMC_CMD_WRITE)
        var output = SMCKeyData_t()
        let kr = fp_smc_call_read(0, &input, &output)
        XCTAssertNotEqual(kr, 0)
        XCTAssertEqual(fp_smc_stat_writes(), writesBefore)
    }

    func testWriteEntryPointRefusesNonWriteCommands() {
        for cmd in [FP_SMC_CMD_READ, FP_SMC_CMD_READ_INDEX, FP_SMC_CMD_KEY_INFO, 0, 7, 255] {
            var input = SMCKeyData_t()
            input.data8 = UInt8(cmd)
            var output = SMCKeyData_t()
            XCTAssertNotEqual(fp_smc_call_write(0, &input, &output), 0, "cmd \(cmd)")
        }
        XCTAssertEqual(fp_smc_stat_writes(), 0)
    }

    func testReadEntryPointRefusesUnknownCommands() {
        for cmd in [0, 1, 4, 7, 10, 255] {
            var input = SMCKeyData_t()
            input.data8 = UInt8(cmd)
            var output = SMCKeyData_t()
            XCTAssertNotEqual(fp_smc_call_read(0, &input, &output), 0, "cmd \(cmd)")
        }
    }
}
