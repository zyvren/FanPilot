import FanPilotControl
import FanPilotKit
import FanPilotSensors
import Foundation

// Fan control: running the controller, talking to the helper, and the edits the UI makes to the policy.

extension AppModel {
    // MARK: Helper connection

    func startHelper() {
        client.onUpdate = { update in
            // HelperClient delivers on the main queue.
            MainActor.assumeIsolated { AppModel.shared.handle(helperUpdate: update) }
        }
        client.start()
    }

    func handle(helperUpdate update: HelperUpdate) {
        guard !terminating else { return }
        switch update {
        case .availability(let availability, let hello):
            let wasConnected = helper.isConnected
            helper.availability = availability
            helper.hello = hello
            if !availability.isConnected { helper.status = nil }
            // A new connection starts from scratch on both sides: the helper holds no fans for us,
            // so the controller must not assume it does.
            resetController(releasingFans: false)
            clearCommandFailures()
            if let hello {
                controller.configuration.failsafeTempC = hello.failsafeTempC
                controller.configuration.refreshIntervalSeconds = HelperClient.heartbeatInterval(leaseMax: hello.leaseMaxS)
                helper.lastCommandError = nil
                if !wasConnected { requestControlTick(immediate: true) }
            }
            if installInProgress, availability.isConnected {
                installInProgress = false
                postNotice("The fan helper is installed and running.", kind: .info)
            }
            refreshStatusItem()

        case .status(let status):
            let wasActive = helper.failsafe.active
            helper.status = status
            if status.failsafe.active, !wasActive {
                if status.failsafe.isBlind {
                    postNotice("The helper cannot read any temperature, so it returned the fans to system control. FanPilot resumes when readings are back.",
                               kind: .warning, dismissAfter: 20)
                } else {
                    postNotice("Safety failsafe: the helper forced the fans to maximum because a sensor got too hot. Manual control resumes when it cools down.",
                               kind: .warning, dismissAfter: 20)
                }
                notifyFailsafe(status.failsafe)
            }
            if wasActive, !status.failsafe.active {
                // Speed commands were held back meanwhile; send the current intent again.
                controller.markNeedsResend()
                requestControlTick(immediate: true)
            }
            reconcile(with: status)

        case .helloRefreshed(let hello):
            helper.hello = hello

        case .lostOwnership(let fans):
            for fan in fans {
                controller.markNeedsResend(fan: fan)
                manualCommandSince[fan] = nil
                claimedFans.remove(fan)
            }
            let reason = helper.status?.lastError.map { " (\($0))" } ?? ""
            postNotice("The helper released fan control (sleep, a safety event, or the system took the fans back)\(reason). FanPilot will take over again.",
                       kind: .warning)
            requestControlTick(immediate: true)

        case .commandFailed(let fan, let code, let message, _):
            handleRefusedCommand(fan: fan, code: code, message: message)
        }
    }

    // MARK: Refused commands

    /// A refused speed command must not turn into a request every second: each retry of a refused
    /// takeover can cost the helper about two seconds of root SMC writes. Retries back off
    /// (2, 4, 8 ... 60 s); refusals that cannot succeed on retry wait for a new session or a new
    /// choice by the user; and the banner appears once per distinct refusal, not once per attempt.
    private func handleRefusedCommand(fan: Int?, code: WireErrorCode, message: String) {
        // While the failsafe is active the helper refuses everything by design and the failsafe has
        // its own banner. Without an active failsafe the same code means something else (no readable
        // temperature before the first takeover), and the user needs to hear about it.
        if code == .failsafeActive, helper.failsafe.active { return }

        let text = message.isEmpty ? code.rawValue : message
        helper.lastCommandError = text
        let key = "\(fan.map(String.init) ?? "-"):\(code.rawValue)"
        if postedFailureKeys.insert(key).inserted {
            postNotice("Fan command refused: \(text)", kind: .error)
        }
        guard let fan else { return }
        refusedFans.insert(fan)
        claimedFans.remove(fan)

        switch code {
        case .monitorOnly, .noSuchFan, .badRequest:
            // Retrying cannot help. The helper may have re-discovered its fans (wake); ask once.
            if code != .badRequest { client.refreshHello() }
        default:
            let failures = (commandFailures[fan] ?? 0) + 1
            commandFailures[fan] = failures
            let delay = min(60, 2 * pow(2, Double(failures - 1)))
            retryWork[fan]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.retryWork[fan] = nil
                self.controller.markNeedsResend(fan: fan)
                self.requestControlTick()
            }
            retryWork[fan] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Forgets refusals: the user made a new choice, the helper reconnected, or a command worked.
    func clearCommandFailures(fan: Int? = nil) {
        if let fan {
            commandFailures[fan] = nil
            retryWork[fan]?.cancel()
            retryWork[fan] = nil
            refusedFans.remove(fan)
            postedFailureKeys = postedFailureKeys.filter { !$0.hasPrefix("\(fan):") }
        } else {
            commandFailures.removeAll()
            retryWork.values.forEach { $0.cancel() }
            retryWork.removeAll()
            refusedFans.removeAll()
            postedFailureKeys.removeAll()
        }
    }

    // MARK: Status reconciliation (SPEC 5.5)

    /// Compares what the helper says with what the controller intends. Only fans we have commanded
    /// ourselves are considered: another client (a `fanpilotctl set --hold`) may legitimately hold others.
    private func reconcile(with status: StatusReply) {
        guard !controlSuspended, !status.failsafe.active, let output = lastOutput else { return }
        var releases: [(fan: Int, command: FanCommand)] = []
        for fan in status.fans where claimedFans.contains(fan.index) {
            if !fan.owned {
                claimedFans.remove(fan.index)
                if commandFailures[fan.index] == nil { refusedFans.remove(fan.index) }
                continue
            }
            clearCommandFailures(fan: fan.index)
            guard helper.controllableFans.contains(fan.index), let directive = output.directive(forFan: fan.index) else { continue }
            switch directive.command {
            case .auto:
                // We still hold a fan that we intend to leave to the system: a release that never
                // arrived, or a claim that survived a failsafe or a reconnect.
                releases.append((fan.index, .auto))
            case .rpm(let wanted):
                // The helper's target is not what we last asked for; ask again.
                if abs(fan.targetRPM - wanted) > Self.targetDriftToleranceRPM { controller.markNeedsResend(fan: fan.index) }
            }
        }
        if !releases.isEmpty { client.apply(releases) }
    }

    /// Targets differ transiently while a ramp moves; only a real gap triggers a resend.
    private static let targetDriftToleranceRPM = 40.0

    /// Forgets the controller's state. A fresh controller assumes every fan is in system control, so
    /// whenever commands may be in force at the helper they must be released first (`auto all` is
    /// ordered before any later command on the client's queue). A new connection needs no release:
    /// the helper holds nothing for a client it has not met.
    func resetController(releasingFans: Bool) {
        if releasingFans { client.releaseAll() }
        controller.reset()
        manualCommandSince.removeAll()
        claimedFans.removeAll()
    }

    // MARK: Controller

    func startControlTimer() {
        // One second keeps ramps smooth (SPEC 5.3); it is also the retry cadence for sends. When every
        // fan is in system control the tick is a cheap no-op.
        controlTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.controlTick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        controlTimer = timer
    }

    /// Coalesces bursts (a dragged slider) into one tick per 100 ms; the first change goes out at once.
    func requestControlTick(immediate: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if immediate || now - lastControlTickAt >= 0.1 {
            pendingTick?.cancel()
            controlTick()
            return
        }
        guard pendingTick == nil || pendingTick?.isCancelled == true else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingTick = nil
            self?.controlTick()
        }
        pendingTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    func controlTick() {
        guard started, !terminating, !controlSuspended else { return }
        let infos = snapshot.fanInfos
        guard !infos.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastControlTickAt = now

        let controllable = helper.controllableFans
        let inputs = infos.map { info -> FanInput in
            var input = FanInput(info: info, reading: fanReading(info.index))
            input.canControl = controllable.contains(info.index)
            return input
        }

        // Temperatures older than a few polls cannot be trusted. Treat them as missing: the controller
        // then releases Boost and Curve fans to system control after its blind timeout.
        let staleAfter = max(15, Double(settings.updateIntervalSecs) * 3 + 5)
        let inputsTemps = (now - lastSampleUptime > staleAfter) ? TemperatureInputs.none : temps

        let output = controller.update(policy: settings.policy, fans: inputs, temps: inputsTemps,
                                       powerSource: powerSource, now: now)

        // While the helper's failsafe is active it refuses speed commands, so none are sent. The
        // controller keeps running on purpose: if it were wiped instead, a claim the helper still holds
        // for us (Manual 2000 RPM) could never be dropped when the user then picks Auto, and would be
        // restored the moment the failsafe clears. `auto` is still sent (the helper accepts it and only
        // drops our claim), and held-back speed commands are re-flagged to go out when it clears.
        var directives = output.commandsToSend
        if helper.failsafe.active {
            for directive in directives {
                if case .rpm = directive.command { controller.markNeedsResend(fan: directive.fanIndex) }
            }
            directives = directives.filter { $0.command == .auto }
        }

        let commands = directives.map { (fan: $0.fanIndex, command: $0.command) }
        for directive in directives {
            switch directive.command {
            case .rpm:
                if manualCommandSince[directive.fanIndex] == nil { manualCommandSince[directive.fanIndex] = now }
                claimedFans.insert(directive.fanIndex)
            case .auto:
                manualCommandSince[directive.fanIndex] = nil
            }
        }
        if !commands.isEmpty { client.apply(commands) }

        if output != lastOutput {
            let overridingBefore = isOverriding
            lastOutput = output
            notifyBoostChange(output: output)
            if overridingBefore != isOverriding { refreshStatusItem() }
        }
    }

    func policyDidChange(from old: Policy) {
        // A new choice by the user deserves a fresh attempt, whatever was refused before.
        clearCommandFailures()
        // Remember the mode for "Resume last mode".
        if let mode = settings.policy.uniformMode(fanCount: max(fanCount, settings.policy.perFan.count)),
           mode != .auto, settings.lastMode != mode {
            settings.lastMode = mode
        }
        requestControlTick()
        refreshStatusItem()
    }

    // MARK: Edits from the UI

    /// The global mode control.
    func setMode(_ mode: ControlMode) {
        guard hasFans else { return }
        if mode != .auto, !canControlFans {
            postNotice("Fan control is not available right now. \(HelperDescription.summary(self))", kind: .warning)
            return
        }
        var policy = settings.policy
        if mode == .manual { seedManualTargets(&policy) }
        policy.setMode(mode, fanCount: max(fanCount, 1))
        settings.policy = policy
    }

    func setFanMode(_ mode: ControlMode, fan: Int) {
        if mode != .auto, !canControlFans {
            postNotice("Fan control is not available right now. \(HelperDescription.summary(self))", kind: .warning)
            return
        }
        var policy = settings.policy
        if mode == .manual { seedManualTargets(&policy, onlyFan: fan) }
        var fanPolicy = policy.fanPolicy(at: fan)
        fanPolicy.mode = mode
        policy.setFanPolicy(fanPolicy, at: fan)
        settings.policy = policy
    }

    func resumeLastMode() {
        guard settings.lastMode != .auto else { return }
        setMode(settings.lastMode)
    }

    /// Entering Manual for the first time starts at the speed the fan has now (never below its
    /// minimum), so switching to Manual does not make the fans drop to their idle speed.
    private func seedManualTargets(_ policy: inout Policy, onlyFan: Int? = nil) {
        for info in fanInfos where onlyFan == nil || onlyFan == info.index {
            var fanPolicy = policy.fanPolicy(at: info.index)
            guard fanPolicy.manualRPM <= 0 else { continue }
            let limits = FanLimits(info)
            guard limits.isUsable else { continue }
            let actual = fanReading(info.index)?.actualRPM ?? info.minRPM
            let rpm = RPMMath.validated(max(actual, info.minRPM), limits: limits)
            fanPolicy.manualRPM = Int(rpm)
            fanPolicy.manualPercent = RPMMath.percent(forRPM: rpm, limits: limits)
            policy.setFanPolicy(fanPolicy, at: info.index)
        }
        if policy.linkFans, fanInfos.count > 1 { policy.relinkManualFans(fans: fanInfos) }
    }

    func setManualRPM(_ rpm: Double, fan: Int) {
        var policy = settings.policy
        policy.applyManualRPM(rpm, forFan: fan, fans: fanInfos)
        settings.policy = policy
    }

    func setManualPercent(_ percent: Double, fan: Int) {
        var policy = settings.policy
        policy.applyManualPercent(percent, forFan: fan, fans: fanInfos)
        settings.policy = policy
    }

    func setManualUnit(_ unit: ManualUnit) {
        var policy = settings.policy
        for index in 0..<max(fanCount, policy.perFan.count) {
            var fanPolicy = policy.fanPolicy(at: index)
            fanPolicy.manualUnit = unit
            policy.setFanPolicy(fanPolicy, at: index)
        }
        settings.policy = policy
    }

    var manualUnit: ManualUnit { settings.policy.fanPolicy(at: 0).manualUnit }

    func setLinkFans(_ linked: Bool) {
        var policy = settings.policy
        policy.linkFans = linked
        if linked { policy.relinkManualFans(fans: fanInfos) }
        settings.policy = policy
    }

    /// Current manual target of a fan in RPM, for the slider.
    func manualTargetRPM(fan: Int) -> Double? {
        guard let info = fanInfos.first(where: { $0.index == fan }) else { return nil }
        let limits = FanLimits(info)
        guard limits.isUsable else { return nil }
        return settings.policy.fanPolicy(at: fan).manualTargetRPM(limits: limits)
    }

    // MARK: Rules and curve

    func updateBoost(_ change: (inout BoostSettings) -> Void) {
        var policy = settings.policy
        change(&policy.boost)
        settings.policy = policy
    }

    func updateCurve(_ change: (inout CurveSettings) -> Void) {
        var policy = settings.policy
        change(&policy.curve)
        settings.policy = policy
    }
}
