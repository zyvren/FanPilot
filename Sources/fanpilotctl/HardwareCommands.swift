import FanPilotHelperCore
import FanPilotKit
import FanPilotSensors
import Foundation

/// Commands that write the SMC directly, without the helper. Root only, for Phase 0 and recovery.
enum HardwareCommands {
    // MARK: Direct release (recovery)

    /// Returns fans to auto by writing the mode byte ourselves. This is what `sudo fanpilotctl auto all`
    /// does when the helper is not there to do it, and what the uninstall script falls back on.
    static func releaseDirectly(_ selector: FanSelector) throws -> Int32 {
        try CLI.requireRoot("Releasing the fans directly")
        let smc: IOKitSMC
        do { smc = try IOKitSMC(access: .readWrite) } catch { throw CLIError(message: "cannot open the SMC: \(error)") }
        let topology = FanTopology.discover(smc: smc)
        let writer = FanWriter(smc: smc, topology: topology)

        // Recovery must not depend on discovery: a fan that discovery distrusts (unreadable limits,
        // FBAD) can still be stuck in manual mode, and writing mode 0 is always safe.
        let targets: [Int]
        switch selector {
        case .all: targets = writer.recoveryIndices().filter { writer.canRecover(fan: $0) }
        case .fan(let index):
            guard writer.canRecover(fan: index) else {
                throw CLIError(message: "fan \(index) does not exist or has no mode key to reset")
            }
            targets = [index]
        }
        if targets.isEmpty { print("No fans with a mode key on this Mac; nothing to do.") }

        var failed = false
        for fan in targets {
            switch writer.forceRelease(fan: fan, reason: "fanpilotctl auto") {
            case nil: print("fan \(fan): already under system control")
            case .released?: print("fan \(fan): returned to automatic control")
            case .pending(let detail)?:
                CLI.fail("fan \(fan): the mode would not go back to auto (\(detail))")
                failed = true
            case .notOwned?: break
            }
        }
        writer.releaseStaleState(reason: "fanpilotctl auto")   // also clears a leftover Ftst
        return failed ? ExitCode.failure : ExitCode.ok
    }

    // MARK: selftest

    static func selftest(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let assumeYes = CLISupport.takeFlag("--yes", from: &args)
        var settings = HardwareSelfTest.Settings()
        if let text = try CLISupport.takeOption("--fan", from: &args) {
            guard let fan = Int(text), (0...Constants.maxFanIndex).contains(fan) else {
                throw CLISupport.UsageError("--fan needs a fan number")
            }
            settings.fan = fan
        }
        guard args.isEmpty else { throw CLISupport.UsageError("usage: selftest [--fan N] [--yes]") }
        try CLI.requireRoot("The hardware self-test")

        // The helper writes the same keys; two writers would corrupt the observation.
        if let probe = try? LineSocketConnection.connect(path: Constants.socketPath) {
            probe.close()
            throw CLIError(message: "the FanPilot helper is running and would fight this test. Stop it first: sudo launchctl bootout system/\(Constants.helperLabel)  (restart it afterwards with scripts/install_helper.sh)")
        }

        print("""
        FanPilot hardware self-test (Phase 0)

        This will put fan \(settings.fan) into manual mode on THIS Mac and run it at about 10 % of its range for
        15 seconds, then return it to the system. It refuses to start above \(Int(settings.maxStartTempC)) C, stops and releases at
        \(Int(settings.abortTempC)) C, and always tries to hand the fan back, also on Ctrl-C.
        If anything looks wrong afterwards:  sudo fanpilotctl auto all
        """)
        guard CLI.confirm("Run the test?", assumeYes: assumeYes) else {
            print("Cancelled; nothing was changed.")
            return ExitCode.failure
        }

        let smc: IOKitSMC
        do { smc = try IOKitSMC(access: .readWrite) } catch { throw CLIError(message: "cannot open the SMC: \(error)") }
        let hotSet = CompositeHotSetProvider([SensorsHotSetProvider(smc: smc), SMCHotSetReader(smc: smc, includeHID: false)])
        hotSet.refresh()

        let interrupt = InterruptFlag()
        let test = HardwareSelfTest(smc: smc, hotSet: hotSet, settings: settings,
                                    shouldAbort: { interrupt.isRaised },
                                    output: { print($0); fflush(stdout) })
        let report = test.run()
        print("\nVerdict: \(report.verdict)")
        return report.passed ? ExitCode.ok : ExitCode.failure
    }

    // MARK: smc-write

    static func smcWrite(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let assumeYes = CLISupport.takeFlag("--yes", from: &args)
        guard args.count == 2 else { throw CLISupport.UsageError("usage: smc-write KEY HEX [--yes]") }
        try CLI.requireRoot("Writing an SMC key")

        guard let key = FourCC(args[0]) else { throw CLISupport.UsageError("'\(args[0])' is not a four character SMC key") }
        guard CLISupport.isWritableDebugKey(key) else {
            throw CLIError(message: "refusing to write \(key): only fan target (F<n>Tg), fan mode (F<n>md / F<n>Md), Ftst and FS! can be written by hand", code: ExitCode.usage)
        }
        let bytes = try CLISupport.parseHex(args[1])

        let smc: IOKitSMC
        do { smc = try IOKitSMC(access: .readWrite) } catch { throw CLIError(message: "cannot open the SMC: \(error)") }
        let before: SMCValue
        do { before = try smc.read(key) } catch { throw CLIError(message: "cannot read \(key) first: \(error)") }
        try validateDebugWrite(key: key, bytes: bytes, current: before, smc: smc)

        print("before: \(CLISupport.describe(before))")
        print("write:  \(key) <- \(CLISupport.hex(bytes))")
        guard CLI.confirm("Write this value?", assumeYes: assumeYes) else {
            print("Cancelled; nothing was written.")
            return ExitCode.failure
        }

        do { try smc.write(key, bytes: bytes) } catch { throw CLIError(message: "the write failed: \(error)") }
        let after = try smc.read(key)
        print("after:  \(CLISupport.describe(after))")
        if after.bytes != bytes {
            CLI.fail("the key reads back differently: the firmware or the OS changed or ignored the value")
            return ExitCode.failure
        }
        if key.string.hasSuffix("md") || key.string.hasSuffix("Md") || key.string == "Ftst" || key.string == "FS! " {
            print("A fan may now be in manual mode. Return it with:  sudo fanpilotctl auto all")
        }
        return ExitCode.ok
    }

    /// Hand-written values get the same sanity rules as the helper's: targets inside the live limits,
    /// mode bytes only 0 or 1.
    private static func validateDebugWrite(key: FourCC, bytes: [UInt8], current: SMCValue, smc: SMCClient) throws {
        let name = key.string
        if name.hasSuffix("md") || name.hasSuffix("Md") || name == "Ftst" {
            guard bytes == [0] || bytes == [1] else {
                throw CLIError(message: "mode bytes can only be 00 (auto) or 01 (manual)", code: ExitCode.usage)
            }
        }
        if name.hasSuffix("Tg"), let fan = Int(String(name.dropFirst().prefix(1))) {
            guard let decoded = SMCCodec.decodeNumeric(type: current.info.type, bytes: bytes), decoded.isFinite else {
                throw CLIError(message: "cannot interpret \(CLISupport.hex(bytes)) as a \(current.info.type) value", code: ExitCode.usage)
            }
            let limits = try FanKeyReader.limits(smc: smc, fan: fan)
            guard decoded >= limits.min, decoded <= limits.max else {
                throw CLIError(message: "\(decoded) RPM is outside this fan's limits \(Int(limits.min))...\(Int(limits.max))", code: ExitCode.usage)
            }
        }
    }
}
