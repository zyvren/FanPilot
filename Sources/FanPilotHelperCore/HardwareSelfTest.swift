import FanPilotKit
import Foundation

/// The Phase 0 hardware validation (docs/SPEC.md 2.10): does this Mac honor manual fan control, and
/// does the fan always get back to the system?
///
///     (a) read-only dump of the fan keys and the hot set
///     (b) fan to manual mode with nothing else changed; read back now and after 2 s (does the OS revert?)
///     (c) target = minimum + 10 % of the range; sample the actual RPM every 0.5 s for 15 s
///     (d) release; verify the mode is back to auto and stays there
///
/// It drives the real `FanWriter`, so a pass here validates the same code path the helper uses.
/// Safety: refuses to start above 80 C, aborts and releases if the hot set reaches 90 C, always
/// releases on the way out (also when a step fails or the user interrupts), and leaves all other
/// fans alone.
public final class HardwareSelfTest {
    public struct Settings: Equatable, Sendable {
        public var fan = 0
        public var maxStartTempC: Double = 80
        public var abortTempC: Double = 90
        /// How long manual mode must hold with no target set (step b).
        public var observeModeSeconds: TimeInterval = 2
        public var spinSeconds: TimeInterval = 15
        public var sampleInterval: TimeInterval = 0.5
        /// Target as a fraction of `[Mn, Mx]` above the minimum.
        public var spinFraction = 0.10
        /// The fan counts as responding once its actual speed exceeds this.
        public var spinThresholdRPM: Double = 0
        public init() {}
    }

    public struct Step: Equatable, Sendable {
        public enum Status: String, Sendable { case pass, fail, info, abort }
        public var name: String
        public var status: Status
        public var detail: String
    }

    public struct Report: Equatable, Sendable {
        public var steps: [Step]
        public var passed: Bool
        public var verdict: String
    }

    private let smc: SMCClient
    private let hotSet: HotSetProvider
    private let settings: Settings
    private let sleeper: (TimeInterval) -> Void
    private let shouldAbort: () -> Bool
    private let output: (String) -> Void
    private var steps: [Step] = []

    public init(smc: SMCClient,
                hotSet: HotSetProvider,
                settings: Settings = Settings(),
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                shouldAbort: @escaping () -> Bool = { false },
                output: @escaping (String) -> Void = { print($0) }) {
        self.smc = smc
        self.hotSet = hotSet
        self.settings = settings
        self.sleeper = sleep
        self.shouldAbort = shouldAbort
        self.output = output
    }

    // MARK: Run

    public func run() -> Report {
        steps = []
        let topology = FanTopology.discover(smc: smc)

        // (a) Read-only dump.
        output("== (a) read-only state ==")
        record("topology", .info, describe(topology))
        guard let info = topology.fan(settings.fan) else {
            return finish(false, "fan \(settings.fan) does not exist on this Mac", step: "fan")
        }
        guard info.backend.canControl else {
            let reason = topology.unusableReasons[info.index] ?? "no usable backend"
            return finish(false, "fan \(info.index) cannot be controlled (\(reason)); FanPilot would be monitor-only here", step: "fan")
        }
        record("fan \(info.index)", .info, "\(info.backend.kind) mode key \(info.modeKey ?? "-") limits \(Int(info.minRPM))...\(Int(info.maxRPM)) RPM")
        if let reading = try? FanKeyReader.reading(smc: smc, fan: info) {
            record("current", .info, "actual \(FanKeyReader.rpmText(reading.actualRPM)) RPM, target \(FanKeyReader.rpmText(reading.targetRPM)), \(CLISupport.modeText(reading.mode))")
            if reading.mode != 0 {
                return finish(false, "the fan is already in \(CLISupport.modeText(reading.mode)); another tool or a previous run controls it. Run 'fanpilotctl auto all' first", step: "precondition")
            }
        }

        let hot = hotSet.read()
        record("hot set", .info, "hottest \(CLISupport.tempText(hot.maxTempC)) over \(hot.sensorCount) sensors (\(hot.hottest ?? "-"))")
        guard let startTemp = hot.maxTempC else {
            return finish(false, "no temperature can be read; refusing to touch the fans blind", step: "precondition")
        }
        guard startTemp <= settings.maxStartTempC else {
            return finish(false, "the machine is at \(CLISupport.tempText(startTemp)), above the \(Int(settings.maxStartTempC)) C limit for this test; let it cool down", step: "precondition")
        }

        let writer = FanWriter(smc: smc, topology: topology, sleep: sleeper)
        let report = hardwareSteps(writer: writer, info: info)
        // Whatever happened above, nothing may be left in manual mode.
        writer.releaseAll(reason: "selftest cleanup")
        _ = writer.forceRelease(fan: info.index, reason: "selftest cleanup")
        if let mode = FanKeyReader.mode(smc: smc, fan: info), mode != 0 {
            record("cleanup", .fail, "the fan is STILL in mode \(mode). Run 'sudo fanpilotctl auto all' now")
            return Report(steps: steps, passed: false, verdict: "FAIL: the fan could not be returned to auto")
        }
        return report
    }

    // MARK: Steps b - d

    private func hardwareSteps(writer: FanWriter, info: FanInfo) -> Report {
        // (b) Manual mode alone.
        output("== (b) manual mode ==")
        do {
            try writer.engageManualMode(fan: info.index)
        } catch {
            return finish(false, "the SMC rejected manual mode: \(error)", step: "manual mode")
        }
        let right = FanKeyReader.mode(smc: smc, fan: info)
        record("mode right after the write", right == 1 ? .pass : .fail, "reads \(right.map(String.init) ?? "unreadable")")
        guard right == 1 else {
            return finish(false, "manual mode did not stick", step: "manual mode")
        }
        sleep(settings.observeModeSeconds)
        let later = FanKeyReader.mode(smc: smc, fan: info)
        guard later == 1 else {
            record("mode after \(settings.observeModeSeconds) s", .fail,
                   "reads \(later.map(String.init) ?? "unreadable"): the OS reverted it")
            return finish(false, "RISK R1 confirmed: this macOS/firmware takes manual mode away again (thermalmonitord). Fan control would have to stay monitor-only unless a different unlock is found", step: "manual mode")
        }
        record("mode after \(settings.observeModeSeconds) s", .pass, "still manual: the OS did not revert it")
        if abortRequested() { return abortReport() }

        // (c) Spin the fan.
        output("== (c) spin up ==")
        let target = (info.minRPM + settings.spinFraction * (info.maxRPM - info.minRPM)).rounded()
        let write: FanWrite
        do {
            write = try writer.setTarget(fan: info.index, rpm: target)
        } catch {
            return finish(false, "the SMC rejected the target: \(error)", step: "target")
        }
        record("target", .info, "\(Int(write.applied)) RPM (minimum + \(Int(settings.spinFraction * 100)) % of the range)")

        var peak = 0.0
        var changes = 0
        var elapsed: TimeInterval = 0
        while elapsed <= settings.spinSeconds {
            if abortRequested() { return abortReport() }
            let temp = hotSet.read().maxTempC
            let actual = (try? FanKeyReader.readRPM(smc: smc, fan: info.index, suffix: .actual)) ?? -1
            let tg = (try? FanKeyReader.readRPM(smc: smc, fan: info.index, suffix: .target)) ?? -1
            let mode = FanKeyReader.mode(smc: smc, fan: info).map(Int.init) ?? -1
            output(String(format: "  t=%4.1f s  actual %5.0f RPM  target %5.0f  mode %d  hot set %@",
                          elapsed, actual, tg, mode, CLISupport.tempText(temp)))
            peak = max(peak, actual)
            if mode != 1 || abs(tg - write.applied) > FanWriter.reassertToleranceRPM { changes += 1 }
            guard let temp else {
                record("temperature", .abort, "no temperature readable during the test")
                return finish(false, "aborted: lost sight of the temperatures", step: "spin")
            }
            if temp >= settings.abortTempC {
                record("temperature", .abort, "\(CLISupport.tempText(temp)) reached the abort limit of \(Int(settings.abortTempC)) C")
                return finish(false, "aborted: the machine got too hot during the test", step: "spin")
            }
            if elapsed >= settings.spinSeconds { break }
            sleep(settings.sampleInterval)
            elapsed += settings.sampleInterval
        }
        record("peak actual speed", peak > settings.spinThresholdRPM ? .pass : .fail,
               "\(Int(peak)) RPM against a target of \(Int(write.applied))")
        if changes > 0 {
            record("OS interference", .info, "mode or target was changed behind our back in \(changes) of the samples (the helper's reassertion loop would correct this)")
        }
        guard peak > settings.spinThresholdRPM else {
            return finish(false, "the fan never responded to the target: manual mode is accepted but has no effect (RISK R1/R2)", step: "spin")
        }

        // (d) Release.
        output("== (d) release ==")
        let outcome = writer.release(fan: info.index, reason: "selftest step d")
        let afterRelease = FanKeyReader.mode(smc: smc, fan: info)
        guard outcome == .released, afterRelease == 0 else {
            return finish(false, "release did not return the fan to auto (mode \(afterRelease.map(String.init) ?? "unreadable"))", step: "release")
        }
        record("mode after release", .pass, "reads 0 (auto)")
        sleep(settings.observeModeSeconds)
        let settled = FanKeyReader.mode(smc: smc, fan: info)
        record("mode \(settings.observeModeSeconds) s later", settled == 0 ? .pass : .fail, "reads \(settled.map(String.init) ?? "unreadable")")
        let tail = (try? FanKeyReader.readRPM(smc: smc, fan: info.index, suffix: .actual)) ?? -1
        record("actual speed afterwards", .info, "\(Int(tail)) RPM (the system takes over from here)")
        guard settled == 0 else {
            return finish(false, "the OS put the fan back into manual mode after the release", step: "release")
        }
        return finish(true, "PASS: manual mode holds, the fan follows the target, and release returns it to the system", step: "verdict")
    }

    // MARK: Helpers

    private func sleep(_ seconds: TimeInterval) {
        // Sleep in slices so an interrupt is noticed quickly.
        var remaining = seconds
        while remaining > 0 {
            let slice = min(remaining, 0.25)
            sleeper(slice)
            remaining -= slice
            if shouldAbort() { return }
        }
    }

    private func abortRequested() -> Bool { shouldAbort() }

    private func abortReport() -> Report {
        record("interrupt", .abort, "stopped by the user")
        return finish(false, "aborted by the user; the fan is being returned to auto", step: "abort")
    }

    private func describe(_ topology: FanTopology) -> String {
        var parts = ["FNum \(topology.reportedFanCount)"]
        parts.append("Ftst \(topology.hasFtst ? "present" : "absent")")
        parts.append("DICT \(topology.hasDICT ? "present" : "absent")")
        if let note = topology.discoveryNote { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    private func record(_ name: String, _ status: Step.Status, _ detail: String) {
        steps.append(Step(name: name, status: status, detail: detail))
        let tag: String
        switch status {
        case .pass: tag = "PASS "
        case .fail: tag = "FAIL "
        case .info: tag = "info "
        case .abort: tag = "ABORT"
        }
        output("[\(tag)] \(name): \(detail)")
    }

    private func finish(_ passed: Bool, _ verdict: String, step: String) -> Report {
        record(step, passed ? .pass : .fail, verdict)
        return Report(steps: steps, passed: passed, verdict: verdict)
    }
}
