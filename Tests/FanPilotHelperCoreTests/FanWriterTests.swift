import FanPilotKit
import XCTest
@testable import FanPilotHelperCore

final class FanWriterTests: XCTestCase {
    private var logs: LogCapture!

    override func setUp() {
        super.setUp()
        logs = LogCapture()
    }

    override func tearDown() {
        logs = nil
        super.tearDown()
    }

    private func makeWriter(_ smc: MockSMC) -> (FanWriter, SleepRecorder) {
        let sleeper = SleepRecorder()
        let writer = FanWriter(smc: smc, topology: FanTopology.discover(smc: smc),
                               sleep: { sleeper.record($0) })
        return (writer, sleeper)
    }

    // MARK: Discovery

    func testDiscoveryOnM5Layout() {
        let topology = FanTopology.discover(smc: MockSMC.appleSilicon())
        XCTAssertEqual(topology.fans.count, 2)
        XCTAssertEqual(topology.fans[0].backend, .appleSiliconMd(modeKey: "F0md"))
        XCTAssertEqual(topology.fans[1].backend, .appleSiliconMd(modeKey: "F1md"))
        XCTAssertEqual(topology.fans[0].minRPM, 1350)
        XCTAssertEqual(topology.fans[0].maxRPM, 5349)
        XCTAssertEqual(topology.fans[1].maxRPM, 5777)
        XCTAssertFalse(topology.hasFtst)
        XCTAssertTrue(topology.hasDICT)
        XCTAssertFalse(topology.isMonitorOnly)
        XCTAssertNil(topology.monitorReason)
    }

    func testDiscoveryFallsBackToUppercaseModeKey() {
        let smc = MockSMC.appleSilicon(fans: 1)
        smc.remove("F0md")
        smc.setUInt8("F0Md", 0, attributes: 0xD0)
        XCTAssertEqual(FanTopology.discover(smc: smc).fans[0].backend, .appleSiliconMd(modeKey: "F0Md"))
    }

    func testDiscoveryPrefersLowercaseWhenBothExist() {
        let smc = MockSMC.appleSilicon(fans: 1)
        smc.setUInt8("F0Md", 0, attributes: 0xD0)
        XCTAssertEqual(FanTopology.discover(smc: smc).fans[0].backend, .appleSiliconMd(modeKey: "F0md"))
    }

    func testDiscoveryIsMonitorOnlyWithoutAWritableModeKey() {
        let smc = MockSMC.appleSilicon(fans: 1)
        smc.setUInt8("F0md", 0, attributes: 0x80)   // present but read-only
        let topology = FanTopology.discover(smc: smc)
        XCTAssertEqual(topology.fans[0].backend, FanBackend.none)
        XCTAssertTrue(topology.isMonitorOnly)
        XCTAssertTrue(topology.monitorReason?.contains("mode key") == true, topology.monitorReason ?? "")
    }

    func testDiscoveryRefusesReadOnlyTarget() {
        let smc = MockSMC.appleSilicon(fans: 1)
        smc.setFloat("F0Tg", 0, attributes: 0x84)
        let topology = FanTopology.discover(smc: smc)
        XCTAssertTrue(topology.isMonitorOnly)
        XCTAssertTrue(topology.monitorReason?.contains("not writable") == true)
    }

    func testDiscoveryMarksFaultyFanAsMonitorOnly() {
        let smc = MockSMC.appleSilicon()
        smc.set("FBAD", type: .hex, attributes: 0xD0, bytes: [0b01])   // fan 0 is bad
        let topology = FanTopology.discover(smc: smc)
        XCTAssertEqual(topology.fans[0].backend, FanBackend.none)
        XCTAssertEqual(topology.fans[1].backend, .appleSiliconMd(modeKey: "F1md"))
        XCTAssertEqual(topology.controllableFans.map(\.index), [1])
    }

    func testDiscoveryRejectsFansWithoutUsableLimits() {
        let smc = MockSMC.appleSilicon(fans: 1)
        smc.remove("F0Mx")
        XCTAssertTrue(FanTopology.discover(smc: smc).isMonitorOnly)

        let zero = MockSMC.appleSilicon(fans: 1)
        zero.setFloat("F0Mn", 0)
        XCTAssertTrue(FanTopology.discover(smc: zero).isMonitorOnly, "Mn = 0 would allow a stopped fan in manual mode")
    }

    func testDiscoveryWithoutFNum() {
        let smc = MockSMC()
        let topology = FanTopology.discover(smc: smc)
        XCTAssertTrue(topology.fans.isEmpty)
        XCTAssertTrue(topology.isMonitorOnly)
        XCTAssertNotNil(topology.monitorReason)
    }

    func testDiscoveryIntelUsesForceBits() {
        let topology = FanTopology.discover(smc: MockSMC.intel())
        XCTAssertEqual(topology.fans.map(\.backend), [.intelForced, .intelForced])
    }

    func testDiscoveryDetectsFtst() {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("Ftst", 0, attributes: 0xD0)
        let topology = FanTopology.discover(smc: smc)
        XCTAssertTrue(topology.hasFtst)
        XCTAssertTrue(topology.fans.allSatisfy(\.hasFtst))
    }

    // MARK: Takeover order and encoding

    func testTakeoverSwitchesModeBeforeWritingTheTarget() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)

        let result = try writer.takeover(fan: 0, rpm: 3000)

        XCTAssertEqual(smc.writtenKeys, ["F0md", "F0Tg"], "md must be written first, then Tg")
        XCTAssertEqual(smc.writes(to: "F0md"), [[1]])
        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(3000)])
        XCTAssertEqual(result.applied, 3000)
        XCTAssertFalse(result.clamped)
        XCTAssertEqual(smc.byte("F0md"), 1)
        XCTAssertEqual(smc.float("F0Tg"), 3000)
        XCTAssertTrue(writer.isOwned(0))
        XCTAssertEqual(writer.ownership(of: 0)?.appliedRPM, 3000)
    }

    func testTakeoverCapturesOriginalValuesOnce() throws {
        let smc = MockSMC.appleSilicon()
        smc.setFloat("F0Tg", 1800, attributes: 0xD4)
        let (writer, _) = makeWriter(smc)

        try writer.takeover(fan: 0, rpm: 3000)
        try writer.takeover(fan: 0, rpm: 4000)

        let record = try XCTUnwrap(writer.ownership(of: 0))
        XCTAssertEqual(record.originalMode, 0)
        XCTAssertEqual(record.originalTarget, f(1800), "the originals are captured at first takeover, not overwritten")
    }

    func testTakeoverClampsToLiveLimits() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)

        let high = try writer.takeover(fan: 0, rpm: 99_999)
        XCTAssertEqual(high.applied, 5349)
        XCTAssertTrue(high.clamped)
        XCTAssertEqual(smc.float("F0Tg"), 5349)

        let low = try writer.takeover(fan: 0, rpm: 10)
        XCTAssertEqual(low.applied, 1350)
        XCTAssertTrue(low.clamped)
        XCTAssertEqual(smc.float("F0Tg"), 1350)

        // Fan 1 has its own, higher maximum.
        XCTAssertEqual(try writer.takeover(fan: 1, rpm: 99_999).applied, 5777)
    }

    func testLimitsAreReadLiveEveryTime() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 5000)
        smc.setFloat("F0Mx", 4000, attributes: 0x85)   // firmware lowered the maximum
        XCTAssertEqual(try writer.takeover(fan: 0, rpm: 5000).applied, 4000)
    }

    func testRoundingToWholeRPMIsNotClamping() throws {
        let (writer, _) = makeWriter(.appleSilicon())
        let result = try writer.takeover(fan: 0, rpm: 3000.4)
        XCTAssertEqual(result.applied, 3000)
        XCTAssertFalse(result.clamped)
    }

    func testInvalidRPMNeverReachesTheHardware() {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        for bad in [Double.nan, .infinity, -1, -5000] {
            XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: bad)) { error in
                guard case FanWriterError.invalidRPM? = error as? FanWriterError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testUnknownAndMonitorOnlyFansAreRefused() {
        let smc = MockSMC.appleSilicon()
        smc.setFloat("F1Tg", 0, attributes: 0x84)   // fan 1 not writable
        let (writer, _) = makeWriter(smc)
        XCTAssertThrowsError(try writer.takeover(fan: 7, rpm: 3000)) {
            XCTAssertEqual($0 as? FanWriterError, .noSuchFan(7))
        }
        XCTAssertThrowsError(try writer.takeover(fan: 1, rpm: 3000)) {
            guard case FanWriterError.notControllable? = $0 as? FanWriterError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testLimitKeysAreNeverWritten() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        try writer.takeover(fan: 1, rpm: 99_999)
        try writer.setTarget(fan: 0, rpm: 10)
        _ = writer.reassertAll(now: 0)
        writer.releaseAll(reason: "test")

        let forbidden: Set<FourCC> = ["F0Mn", "F0Mx", "F1Mn", "F1Mx", "F0Ac", "F1Ac", "F0St", "FNum"]
        XCTAssertTrue(Set(smc.writtenKeys).isDisjoint(with: forbidden), "wrote \(smc.writtenKeys)")
        XCTAssertTrue(Set(smc.writtenKeys).isSubset(of: ["F0md", "F0Tg", "F1md", "F1Tg"]))
    }

    func testModeBytesAreOnlyZeroOrOne() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        writer.releaseAll(reason: "test")
        for bytes in smc.writes(to: "F0md") { XCTAssertTrue(bytes == [0] || bytes == [1], "\(bytes)") }
    }

    func testTakeoverIsIdempotentAndSkipsTheModeWrite() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        try writer.takeover(fan: 0, rpm: 3500)
        XCTAssertEqual(smc.writes(to: "F0md"), [[1]], "mode written once")
        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(3000), f(3500)])
    }

    // MARK: Re-sending an unchanged target (the app's lease refresh)

    /// Info lines the takeover logs for a fan: one per real write, none for a refresh.
    private func takeoverLogLines(fan: Int = 0) -> Int {
        logs.lines.filter { $0.0 == .info && $0.1.hasPrefix("fan \(fan): target ") }.count
    }

    func testResendingTheSameTargetToAnOwnedFanWritesNothingAndReturnsThePlan() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        let first = try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()
        XCTAssertEqual(takeoverLogLines(), 1)

        for _ in 0..<10 {   // ten heartbeats' worth
            let again = try writer.takeover(fan: 0, rpm: 3000)
            XCTAssertEqual(again, first, "the plan is returned as usual")
            XCTAssertEqual(again.applied, 3000)
            XCTAssertFalse(again.clamped)
        }

        XCTAssertTrue(smc.writes.isEmpty, "no SMC write for a target already in place: \(smc.writtenKeys)")
        XCTAssertEqual(smc.byte("F0md"), 1)
        XCTAssertEqual(smc.float("F0Tg"), 3000)
        XCTAssertEqual(takeoverLogLines(), 1, "and no INFO line per refresh")
        XCTAssertTrue(logs.contains(.debug, "already in place"), "it is only a debug line")
        XCTAssertEqual(writer.ownership(of: 0)?.appliedRPM, 3000)
        XCTAssertTrue(writer.isOwned(0))
    }

    func testResendingAClampedTargetIsAlsoAnUnchangedTarget() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        XCTAssertEqual(try writer.takeover(fan: 0, rpm: 99_999).applied, 5349)
        smc.clearWrites()

        // What counts is the clamped value: 99_999 and 8_000 both mean 5349 on this fan.
        let again = try writer.takeover(fan: 0, rpm: 8000)

        XCTAssertEqual(again.requested, 8000)
        XCTAssertEqual(again.applied, 5349)
        XCTAssertTrue(again.clamped, "the caller is still told its request was clamped")
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testResendingTheSameTargetThroughSetTargetWritesNothing() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()
        XCTAssertEqual(try writer.setTarget(fan: 0, rpm: 3000).applied, 3000)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testResendingTheSameTargetOnIntelWritesNothingEither() throws {
        let smc = MockSMC.intel()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()

        XCTAssertEqual(try writer.takeover(fan: 0, rpm: 3000).applied, 3000)
        XCTAssertTrue(smc.writes.isEmpty, "fpe2 target and FS! bit already match: \(smc.writtenKeys)")
    }

    func testResendingTheSameTargetAfterTheModeRevertedToAutoRewritesIt() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.setUInt8("F0md", 0, attributes: 0xD0)   // the OS flipped the fan back to auto; Tg still reads 3000
        smc.clearWrites()

        let again = try writer.takeover(fan: 0, rpm: 3000)

        XCTAssertEqual(again.applied, 3000)
        XCTAssertEqual(smc.writtenKeys, ["F0md", "F0Tg"], "mode first, then the target again")
        XCTAssertEqual(smc.byte("F0md"), 1)
        XCTAssertEqual(smc.float("F0Tg"), 3000)
        XCTAssertEqual(takeoverLogLines(), 2, "a real write is logged again")
    }

    func testResendingTheSameTargetAfterTheTargetDriftedRewritesIt() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.setFloat("F0Tg", 1500, attributes: 0xD4)   // the OS changed Tg, mode is still manual
        smc.clearWrites()

        XCTAssertEqual(try writer.takeover(fan: 0, rpm: 3000).applied, 3000)

        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(3000)])
        XCTAssertTrue(smc.writes(to: "F0md").isEmpty, "the mode was still manual: only the target is repaired")
        XCTAssertEqual(smc.float("F0Tg"), 3000)
        XCTAssertEqual(smc.byte("F0md"), 1)
    }

    func testResendingTheSameTargetOnIntelAfterTheForceBitWasClearedRewritesIt() throws {
        let smc = MockSMC.intel()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.set("FS! ", type: .ui16, attributes: 0xD0, bytes: [0, 0])   // the firmware took the fan back
        smc.clearWrites()

        XCTAssertEqual(try writer.takeover(fan: 0, rpm: 3000).applied, 3000)

        XCTAssertEqual(smc.bytes("FS! "), [0, 1])
        XCTAssertEqual(smc.bytes("F0Tg"), SMCCodec.encodeFPE2(3000))
        XCTAssertEqual(smc.writtenKeys, ["FS! ", "F0Tg"])
    }

    func testResendTreatsATargetWithinTheReadbackToleranceAsInPlaceAndOneBeyondItAsDrift() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)

        smc.setFloat("F0Tg", 3000.5, attributes: 0xD4)
        smc.clearWrites()
        try writer.takeover(fan: 0, rpm: 3000)
        XCTAssertTrue(smc.writes.isEmpty, "0.5 RPM off reads back as the same target (docs/SPEC.md 2.7 step 4: 1 RPM)")

        smc.setFloat("F0Tg", 3002, attributes: 0xD4)
        try writer.takeover(fan: 0, rpm: 3000)
        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(3000)], "2 RPM off is drift")
        XCTAssertEqual(smc.float("F0Tg"), 3000)
    }

    func testResendingToAFanThatIsNotOwnedStillTakesItOver() throws {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("F0md", 1, attributes: 0xD0)         // someone else left the fan in manual...
        smc.setFloat("F0Tg", 3000, attributes: 0xD4)      // ...at exactly the target we are about to ask for
        let (writer, _) = makeWriter(smc)

        XCTAssertEqual(try writer.takeover(fan: 0, rpm: 3000).applied, 3000)

        XCTAssertTrue(writer.isOwned(0), "ownership is recorded even though the hardware already looks right")
        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(3000)], "a fan we do not own is never skipped")
        XCTAssertEqual(writer.ownership(of: 0)?.appliedRPM, 3000)
        XCTAssertEqual(writer.ownership(of: 0)?.originalMode, 1)
    }

    func testADifferentTargetRewritesTheTargetOnly() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()

        let next = try writer.takeover(fan: 0, rpm: 3500)

        XCTAssertEqual(next.applied, 3500)
        XCTAssertEqual(smc.writtenKeys, ["F0Tg"], "the mode is already manual")
        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(3500)])
        XCTAssertEqual(smc.float("F0Tg"), 3500)
        XCTAssertEqual(writer.ownership(of: 0)?.appliedRPM, 3500)
        XCTAssertEqual(takeoverLogLines(), 2)
    }

    func testATargetOneRPMAwayIsStillADifferentTarget() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()

        // The hardware reads 3000, within the 1 RPM tolerance of 3001, but the client changed its mind.
        XCTAssertEqual(try writer.takeover(fan: 0, rpm: 3001).applied, 3001)

        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(3001)])
        XCTAssertEqual(smc.float("F0Tg"), 3001)
        XCTAssertEqual(writer.ownership(of: 0)?.appliedRPM, 3001)
    }

    func testRetargetingBackAndForthAlwaysWrites() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        for rpm in [2000.0, 4000, 2000, 4000] {
            smc.clearWrites()
            try writer.takeover(fan: 0, rpm: rpm)
            XCTAssertEqual(smc.writes(to: "F0Tg"), [f(rpm)])
        }
    }

    func testSetTargetRequiresOwnership() {
        let (writer, _) = makeWriter(.appleSilicon())
        XCTAssertThrowsError(try writer.setTarget(fan: 0, rpm: 3000)) {
            XCTAssertEqual($0 as? FanWriterError, .notOwned(fan: 0))
        }
    }

    func testSetTargetRepairsAModeTheOSReverted() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.setUInt8("F0md", 0, attributes: 0xD0)   // the OS flipped it back
        try writer.setTarget(fan: 0, rpm: 3500)
        XCTAssertEqual(smc.byte("F0md"), 1)
        XCTAssertEqual(smc.float("F0Tg"), 3500)
    }

    // MARK: Read-back verification and retries

    func testModeIsRetriedUntilItSticks() throws {
        let smc = MockSMC.appleSilicon()
        smc.behavior = { key, bytes, index in key == "F0md" && bytes == [1] && index < 3 ? .ignore : .apply }
        let (writer, sleeper) = makeWriter(smc)

        try writer.takeover(fan: 0, rpm: 3000)

        XCTAssertEqual(smc.writes(to: "F0md").count, 4, "three ignored writes, then success")
        XCTAssertEqual(sleeper.values, [0.25, 0.25, 0.25])
        XCTAssertEqual(smc.byte("F0md"), 1)
        XCTAssertEqual(smc.float("F0Tg"), 3000)
    }

    func testModeRejectedAfterEightAttemptsGoesBackToAuto() {
        let smc = MockSMC.appleSilicon()
        smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [1] ? .ignore : .apply }
        let (writer, sleeper) = makeWriter(smc)

        XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: 3000)) { error in
            guard case FanWriterError.modeRejected(let fan, let detail)? = error as? FanWriterError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(fan, 0)
            XCTAssertTrue(detail.contains("mode reads 0"), detail)
        }
        XCTAssertEqual(smc.writes(to: "F0md").filter { $0 == [1] }.count, 8)
        XCTAssertEqual(sleeper.values.filter { $0 == 0.25 }.count, 7)
        XCTAssertEqual(smc.byte("F0md"), 0, "the failed takeover ends in auto")
        XCTAssertFalse(smc.writes(to: "F0md").contains([0]), "the mode already read auto, so there was nothing to write back")
        XCTAssertFalse(writer.isOwned(0))
        XCTAssertFalse(smc.writes(to: "F0Tg").contains(f(3000)), "the target is never written without manual mode")
    }

    func testModeRejectionReportsTheSMCResultByte() {
        let smc = MockSMC.appleSilicon()
        smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [1] ? .fail(0x86) : .apply }
        let (writer, _) = makeWriter(smc)
        XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: 3000)) { error in
            guard case FanWriterError.modeRejected(_, let detail)? = error as? FanWriterError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(detail.contains("0x86"), detail)
        }
        XCTAssertEqual(smc.byte("F0md"), 0)
    }

    func testTargetThatDoesNotReadBackIsRejectedAndTheFanReleased() {
        let smc = MockSMC.appleSilicon()
        smc.behavior = { key, bytes, _ in key == "F0Tg" && bytes == f(3000) ? .ignore : .apply }
        let (writer, sleeper) = makeWriter(smc)

        XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: 3000)) { error in
            guard case FanWriterError.targetRejected? = error as? FanWriterError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(smc.writes(to: "F0Tg").filter { $0 == f(3000) }.count, 3, "three attempts")
        XCTAssertEqual(sleeper.values.filter { $0 == 0.1 }.count, 2)
        XCTAssertEqual(smc.byte("F0md"), 0, "manual mode with the wrong target would stop the fan")
        XCTAssertFalse(writer.isOwned(0))
    }

    func testTargetWithinOneRPMCounts() throws {
        let smc = MockSMC.appleSilicon()
        // The firmware stores the target with a small rounding difference.
        smc.afterWrite = { smc, key, bytes in
            if key == "F0Tg", let v = SMCCodec.decodeFloat(bytes), v > 0 {
                smc.setFloat("F0Tg", v + 0.9, attributes: 0xD4)
            }
        }
        let (writer, _) = makeWriter(smc)
        XCTAssertNoThrow(try writer.takeover(fan: 0, rpm: 3000))
    }

    func testWriteToAKeyWithTheWrongSizeIsRefused() {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)          // discovery saw a 1 byte mode key ...
        smc.set("F0md", type: .ui8, attributes: 0xD0, bytes: [0, 0])   // ... the hardware now says 2 bytes

        XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: 3000)) { error in
            guard case FanWriterError.modeRejected(_, let detail)? = error as? FanWriterError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(detail.contains("refusing write"), detail)
        }
        XCTAssertTrue(smc.writes.isEmpty, "a size mismatch must never reach the hardware")
    }

    func testTargetOfTheWrongSizeIsRefused() {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        smc.set("F0Tg", type: .flt, attributes: 0xD4, bytes: [0, 0])   // 2 bytes where a float needs 4

        XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: 3000)) { error in
            guard case FanWriterError.targetRejected? = error as? FanWriterError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(smc.writes(to: "F0Tg").contains(f(3000)))
        XCTAssertEqual(smc.byte("F0md"), 0)
    }

    func testNonWritableModeKeyIsRefusedAtWriteTime() {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        smc.setUInt8("F0md", 0, attributes: 0x80)   // became read-only after discovery
        XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: 3000))
        XCTAssertTrue(smc.writes.isEmpty)
    }

    // MARK: Release

    func testReleaseWritesModeToAutoFirst() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()

        XCTAssertEqual(writer.release(fan: 0, reason: "test"), .released)

        XCTAssertEqual(smc.writtenKeys, ["F0md", "F0Tg"], "md = 0 FIRST, then the best-effort target restore")
        XCTAssertEqual(smc.writes(to: "F0md"), [[0]])
        XCTAssertEqual(smc.writes(to: "F0Tg"), [f(0)], "original target restored")
        XCTAssertFalse(writer.isOwned(0))
        XCTAssertEqual(smc.byte("F0md"), 0)
    }

    func testReleaseOfAnUnownedFanDoesNothing() {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        XCTAssertEqual(writer.release(fan: 0, reason: "test"), .notOwned)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testReleaseRetriesAndStaysPendingUntilTheModeSticks() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, sleeper) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [0] ? .ignore : .apply }
        sleeper.reset()

        let outcome = writer.release(fan: 0, reason: "test")

        guard case .pending = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(smc.writes(to: "F0md").filter { $0 == [0] }.count, 5, "five attempts")
        XCTAssertEqual(sleeper.values, [0.2, 0.2, 0.2, 0.2])
        XCTAssertTrue(writer.isOwned(0), "still tracked so it can be retried")
        XCTAssertEqual(writer.pendingReleases, [0])
        XCTAssertTrue(logs.contains(.critical, "cannot return to auto"))

        // Later the key accepts writes again; the periodic retry finishes the job.
        smc.behavior = nil
        XCTAssertEqual(writer.retryPendingReleases(), [0: .released])
        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertFalse(writer.isOwned(0))
        XCTAssertTrue(writer.pendingReleases.isEmpty)
    }

    func testReleaseAllContinuesAfterAFailure() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        try writer.takeover(fan: 1, rpm: 3000)
        smc.behavior = { key, _, _ in key == "F0md" ? .fail(0x86) : .apply }

        let outcomes = writer.releaseAll(reason: "test")

        guard case .pending? = outcomes[0] else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(outcomes[1], .released)
        XCTAssertEqual(smc.byte("F1md"), 0)
    }

    func testPendingFanCannotBeTakenAgainUntilItIsReleased() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.behavior = { key, bytes, _ in key == "F0md" && bytes == [0] ? .ignore : .apply }
        _ = writer.release(fan: 0, reason: "test")

        XCTAssertThrowsError(try writer.takeover(fan: 0, rpm: 3000)) {
            guard case FanWriterError.modeRejected? = $0 as? FanWriterError else { return XCTFail("\($0)") }
        }
    }

    func testForceReleaseHandlesFansWeHaveNoRecordOf() {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("F1md", 1, attributes: 0xD0)   // left behind by a crashed run
        let (writer, _) = makeWriter(smc)

        XCTAssertNil(writer.forceRelease(fan: 0, reason: "recovery"), "already auto: nothing written")
        XCTAssertEqual(writer.forceRelease(fan: 1, reason: "recovery"), .released)
        XCTAssertEqual(smc.byte("F1md"), 0)
        XCTAssertEqual(smc.writtenKeys, ["F1md"], "only the stuck fan is written, and without touching its target")
    }

    func testReleaseStaleStateAtStartup() {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("Ftst", 1, attributes: 0xD0)
        smc.setUInt8("F0md", 1, attributes: 0xD0)
        smc.setUInt8("F1md", 1, attributes: 0xD0)
        let (writer, _) = makeWriter(smc)

        XCTAssertEqual(writer.releaseStaleState(reason: "startup"), [0, 1])

        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertEqual(smc.byte("F1md"), 0)
        XCTAssertEqual(smc.byte("Ftst"), 0, "a leftover unlock is cleared too")
        XCTAssertEqual(smc.writtenKeys.first, "F0md", "modes first")
    }

    func testReleaseStaleStateWritesNothingWhenAlreadyAuto() {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        XCTAssertEqual(writer.releaseStaleState(reason: "startup"), [])
        XCTAssertTrue(smc.writes.isEmpty)
    }

    // MARK: Ftst (older M-series)

    func testFtstIsUnlockedBeforeTheModeAndResetAfterTheLastRelease() throws {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("Ftst", 0, attributes: 0xD0)
        let (writer, _) = makeWriter(smc)

        try writer.takeover(fan: 0, rpm: 3000)
        XCTAssertEqual(smc.writtenKeys, ["Ftst", "F0md", "F0Tg"])
        XCTAssertEqual(smc.byte("Ftst"), 1)

        try writer.takeover(fan: 1, rpm: 3000)
        smc.clearWrites()
        writer.release(fan: 0, reason: "test")
        XCTAssertEqual(smc.byte("Ftst"), 1, "fan 1 is still ours, so Ftst stays set")

        writer.release(fan: 1, reason: "test")
        XCTAssertEqual(smc.byte("Ftst"), 0)
        XCTAssertEqual(smc.writtenKeys.last, "Ftst", "Ftst = 0 comes last")
    }

    func testFtstIsRewrittenOnModeRetries() throws {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("Ftst", 0, attributes: 0xD0)
        smc.behavior = { key, bytes, index in key == "F0md" && bytes == [1] && index < 2 ? .ignore : .apply }
        let (writer, _) = makeWriter(smc)

        try writer.takeover(fan: 0, rpm: 3000)

        XCTAssertEqual(smc.writes(to: "Ftst").count, 3, "once up front and once before each of the two retries")
        XCTAssertEqual(smc.byte("F0md"), 1)
    }

    // MARK: Intel (Backend B, untested on hardware)

    func testIntelBackendFlipsTheForceBitAndEncodesFPE2() throws {
        let smc = MockSMC.intel()
        let (writer, _) = makeWriter(smc)

        try writer.takeover(fan: 0, rpm: 3000)
        XCTAssertEqual(smc.bytes("FS! "), [0, 1])
        XCTAssertEqual(smc.bytes("F0Tg"), [0x2E, 0xE0], "3000 * 4 = 0x2EE0, big-endian")
        XCTAssertEqual(smc.writtenKeys, ["FS! ", "F0Tg"])

        try writer.takeover(fan: 1, rpm: 99_999)
        XCTAssertEqual(smc.bytes("FS! "), [0, 3], "other bits are preserved")
        XCTAssertEqual(smc.bytes("F1Tg"), SMCCodec.encodeFPE2(6000))

        writer.release(fan: 0, reason: "test")
        XCTAssertEqual(smc.bytes("FS! "), [0, 2], "only fan 0's bit is cleared")
        writer.release(fan: 1, reason: "test")
        XCTAssertEqual(smc.bytes("FS! "), [0, 0])
    }

    // MARK: Reassertion and anti-fight

    func testReassertRewritesATargetTheOSChanged() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)

        XCTAssertEqual(writer.reassert(fan: 0, now: 0), .ok)
        smc.setFloat("F0Tg", 1500, attributes: 0xD4)
        guard case .corrected = writer.reassert(fan: 0, now: 1) else { return XCTFail() }
        XCTAssertEqual(smc.float("F0Tg"), 3000)
    }

    func testReassertRepairsAModeTheOSReverted() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.setUInt8("F0md", 0, attributes: 0xD0)

        guard case .corrected = writer.reassert(fan: 0, now: 0) else { return XCTFail() }
        XCTAssertEqual(smc.byte("F0md"), 1)
        XCTAssertEqual(smc.float("F0Tg"), 3000)
    }

    func testReassertToleratesTwoRPM() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()
        smc.setFloat("F0Tg", 3001.5, attributes: 0xD4)
        XCTAssertEqual(writer.reassert(fan: 0, now: 0), .ok)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testReassertBacksOffWhileDICTIsSet() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.clearWrites()
        smc.setFloat("F0Tg", 1000, attributes: 0xD4)
        smc.set("DICT", type: "flag", attributes: 0xC0, bytes: [1])

        XCTAssertEqual(writer.reassertAll(now: 0), [0: .skippedDICT])
        XCTAssertTrue(smc.writes.isEmpty, "no fighting while the OS is ducking the fans")
        XCTAssertEqual(logs.lines.filter { $0.1.contains("DICT is set") }.count, 1)
        _ = writer.reassertAll(now: 1)
        XCTAssertEqual(logs.lines.filter { $0.1.contains("DICT is set") }.count, 1, "logged once")

        smc.set("DICT", type: "flag", attributes: 0xC0, bytes: [0])
        guard case .corrected? = writer.reassertAll(now: 2)[0] else { return XCTFail() }
        XCTAssertEqual(smc.float("F0Tg"), 3000)
    }

    func testAntiFightReleasesAfterTenCorrectionsInAMinute() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)

        var outcomes: [ReassertOutcome] = []
        for second in 0..<10 {
            smc.setFloat("F0Tg", 0, attributes: 0xD4)       // the OS reverts us every second
            smc.setUInt8("F0md", 0, attributes: 0xD0)
            outcomes.append(writer.reassert(fan: 0, now: Double(second)))
        }

        for outcome in outcomes.prefix(9) {
            guard case .corrected = outcome else { return XCTFail("\(outcomes)") }
        }
        XCTAssertEqual(outcomes[9], .overrideDetected(corrections: 10))
        XCTAssertFalse(writer.isOwned(0), "we stop fighting the OS")
        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertTrue(logs.contains(.error, "keeps overriding"))
    }

    func testSlowDriftIsNotAFight() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        for step in 0..<20 {
            smc.setFloat("F0Tg", 0, attributes: 0xD4)
            guard case .corrected = writer.reassert(fan: 0, now: Double(step) * 10) else { return XCTFail("step \(step)") }
        }
        XCTAssertTrue(writer.isOwned(0), "one correction every 10 s never reaches 10 within 60 s")
    }

    func testFailsafeHoldsNeverGiveUp() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 5349)
        for second in 0..<30 {
            smc.setFloat("F0Tg", 0, attributes: 0xD4)
            let outcome = writer.reassert(fan: 0, now: Double(second), allowOverrideRelease: false)
            guard case .corrected = outcome else { return XCTFail("\(outcome)") }
        }
        XCTAssertTrue(writer.isOwned(0))
    }

    func testReassertReportsUnreadableState() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)
        smc.remove("F0Tg")
        guard case .readFailed = writer.reassert(fan: 0, now: 0) else { return XCTFail() }
        XCTAssertTrue(writer.isOwned(0))
    }

    // MARK: Recovery independent of discovery

    func testReleaseStaleStateReachesFansDiscoveryDistrusts() {
        let smc = MockSMC.appleSilicon()
        smc.setUInt8("F0md", 1, attributes: 0xD0)
        smc.setUInt8("F1md", 1, attributes: 0xD0)
        smc.setFloat("F0Mx", 0, attributes: 0x85)   // transiently unreadable limits
        smc.set("FBAD", type: .hex, attributes: 0xD0, bytes: [2])   // fan 1 flagged faulty
        let (writer, _) = makeWriter(smc)
        XCTAssertEqual(writer.topology.controllableFans.count, 0, "premise: discovery distrusts both fans")

        XCTAssertEqual(writer.releaseStaleState(reason: "startup"), [0, 1])
        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertEqual(smc.byte("F1md"), 0)
        XCTAssertEqual(smc.writtenKeys, ["F0md", "F1md"], "only the mode bytes are written")
    }

    func testRecoveryDoesNotWriteAnythingForFansThatDoNotExist() {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        XCTAssertEqual(writer.releaseStaleState(reason: "startup"), [])
        XCTAssertTrue(smc.writes.isEmpty)
        XCTAssertFalse(writer.canRecover(fan: 5))
        XCTAssertTrue(writer.canRecover(fan: 1))
    }

    func testRecoveryScansEveryFanSlotWhenFNumIsUnreadable() {
        let smc = MockSMC.appleSilicon()
        smc.remove("FNum")
        smc.setUInt8("F1md", 1, attributes: 0xD0)
        let (writer, _) = makeWriter(smc)
        XCTAssertEqual(writer.releaseStaleState(reason: "startup"), [1])
        XCTAssertEqual(smc.byte("F1md"), 0)
    }

    func testAnOwnedFanThatBecomesMonitorOnlyIsStillReleased() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)

        smc.setFloat("F0Mx", 0, attributes: 0x85)   // a re-discovery now marks the fan unusable
        writer.updateTopology(FanTopology.discover(smc: smc))
        XCTAssertFalse(writer.topology.fan(0)!.backend.canControl)

        XCTAssertEqual(writer.release(fan: 0, reason: "test"), .released)
        XCTAssertEqual(smc.byte("F0md"), 0)
        XCTAssertFalse(writer.isOwned(0))
    }

    // MARK: Garbage targets

    func testReassertSurvivesAHugeTargetAndWritesTheRightOneBack() throws {
        let smc = MockSMC.appleSilicon()
        let (writer, _) = makeWriter(smc)
        try writer.takeover(fan: 0, rpm: 3000)

        for garbage: Float in [1e30, -1e30, 3.4e38, .infinity, .nan] {
            smc.setFloat("F0Tg", garbage, attributes: 0xD0)
            let outcome = writer.reassert(fan: 0, now: 1000)
            guard case .corrected = outcome else { XCTFail("\(garbage): \(outcome)"); continue }
            XCTAssertEqual(smc.float("F0Tg"), 3000)
        }
    }

    func testRPMValuesOutsideTheSanityRangeAreRejected() {
        let smc = MockSMC.appleSilicon()
        smc.setFloat("F0Ac", 1e30)
        XCTAssertThrowsError(try FanKeyReader.readRPM(smc: smc, fan: 0, suffix: .actual))
        smc.setFloat("F0Ac", -5)
        XCTAssertThrowsError(try FanKeyReader.readRPM(smc: smc, fan: 0, suffix: .actual))
        XCTAssertEqual(FanKeyReader.rpmText(1e30), "1000000000000000019884624838656")
        XCTAssertEqual(FanKeyReader.rpmText(.nan), "invalid")
    }
}
