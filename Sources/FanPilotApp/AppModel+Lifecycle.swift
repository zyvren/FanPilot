import AppKit
import FanPilotControl
import FanPilotKit
import FanPilotSensors
import Foundation

// Start-up, sleep and wake, power source, quitting, and the helper install flow.

extension AppModel {
    // MARK: Start

    func start() {
        guard !started else { return }
        started = true

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "FanPilot reads temperatures and keeps fan control leases alive")
        applyActivationPolicy()
        configureLogger()
        powerSource = PowerMonitor.currentPowerSource()
        battery = BatteryReader.read()
        if !battery.isPresent { powerSource = .adapter }

        power.onWillSleep = { [weak self] in self?.systemWillSleep() }
        power.onDidWake = { [weak self] in self?.systemDidWake() }
        power.onWillPowerOff = { [weak self] in self?.systemWillPowerOff() }
        power.onPowerSourceChange = { [weak self] source in self?.powerSourceChanged(source) }
        power.start()

        startHelper()
        startSensors()
        startControlTimer()
        applyHotKeys()
        syncLoginItemState()
        refreshStatusItem()
        refreshNotificationStatus()
    }

    /// Adopt the real login item state at launch (the user may have changed it in System Settings).
    private func syncLoginItemState() {
        let actual = LoginItem.state == .enabled
        if actual != settings.launchAtLogin {
            suppressLoginSync = true
            settings.launchAtLogin = actual
            suppressLoginSync = false
        }
        if LoginItem.state == .requiresApproval {
            loginItemMessage = "Allow FanPilot in System Settings > General > Login Items to finish."
        }
    }

    // MARK: Power

    func powerSourceChanged(_ source: PowerSource) {
        // Macs without a battery only ever have the adapter.
        let effective: PowerSource = battery.isPresent ? source : .adapter
        guard effective != powerSource else { return }
        powerSource = effective
        // The controller keeps its rule state: switching sets does not restart a ramp (SPEC 4.6).
        requestControlTick(immediate: true)
        battery = BatteryReader.read()
    }

    func systemWillSleep() {
        guard settings.turnOffFanControlForSleep else { return }
        // Hand the fans back before the Mac sleeps (the helper does the same on its side).
        controlSuspended = true
        resetController(releasingFans: true)
    }

    func systemDidWake() {
        // The SMC is unreliable right after wake: leave the sensors and the fans alone for 5 s
        // (SPEC 3.5, 4.6), then re-enumerate sensors and re-apply the policy.
        monitor?.noteDidWake()
        controlSuspended = true
        resetController(releasingFans: false)   // the helper released everything when the Mac went to sleep
        clearCommandFailures()
        // The last sample is from before the sleep. Sample age is measured in system uptime, which does
        // not advance while asleep, so an hours-old 85 C reading would still look a few seconds old and
        // could ramp the fans to full speed for a moment. Discard it and wait for a fresh one.
        temps = .none
        lastSampleUptime = 0
        wakeDelayElapsed = false
        awaitingFreshSampleAfterWake = true
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeDelayElapsed = true
            self.client.retryNow()
            self.client.refreshHello()      // the helper re-discovers its fans a few seconds after wake
            self.battery = BatteryReader.read()
            self.powerSource = self.battery.isPresent ? PowerMonitor.currentPowerSource() : .adapter
            self.refreshDiagnostics()
            self.resumeControlAfterWakeIfReady()
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Fan control restarts once the settling time is over AND a temperature sample taken after it has
    /// arrived (called from the wake timer and from `handle(snapshot:)`).
    func resumeControlAfterWakeIfReady() {
        guard controlSuspended, wakeDelayElapsed, !awaitingFreshSampleAfterWake else { return }
        controlSuspended = false
        requestControlTick(immediate: true)
    }

    func systemWillPowerOff() {
        controlSuspended = true
        client.releaseAll()
        saveNow()
    }

    // MARK: Quit

    /// Called from `applicationShouldTerminate`. Gives every fan back to the system and waits (at most
    /// two seconds) for the helper to confirm, so the request cannot be lost the way a fire and forget
    /// message could be. It blocks the main thread on purpose: `terminateLater` would need the main
    /// queue to run while `terminate` is on the stack, which libdispatch does not allow when quitting
    /// is triggered from a queue block (a signal handler, a Task).
    func prepareForTermination() {
        guard !terminating else { return }
        terminating = true
        controlTimer?.invalidate()
        pendingTick?.cancel()
        wakeWork?.cancel()
        saveNow()
        monitor?.stop()
        power.stop()
        hotKeys.configure(showWindow: nil, toggleMenu: nil)
        client.releaseAllAndStop(timeout: 2)
    }

    // MARK: Helper install flow

    /// Explains the helper and offers to install it: only when the Mac has fans and
    /// the helper is not installed, once per launch, and not if the user said "do not show again".
    func offerHelperInstallIfNeeded() {
        guard !helperPromptShown, !extras.skipHelperPrompt, hasFans else { return }
        // Give the first connection attempt a moment so we do not nag when the helper is merely slow.
        runLater(after: 2) { [weak self] in
            guard let self, !self.helperPromptShown, self.helper.availability == .notInstalled else { return }
            self.helperPromptShown = true
            self.confirmAndInstallHelper(fromStartup: true)
        }
    }

    /// Shows the explanation and runs the install if the user agrees.
    func confirmAndInstallHelper(fromStartup: Bool = false) {
        guard !installInProgress else { return }
        guard HelperInstaller.isPayloadAvailable else {
            presentAlert(title: "The fan helper is not part of this build",
                         message: "FanPilot could not find its helper files inside the app. Build the app with scripts/build_app.sh, or install the helper from a terminal with scripts/install_helper.sh.",
                         style: .warning)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = HelperInstaller.isInstalledOnDisk ? "Reinstall the fan helper?" : "Enable fan control?"
        alert.informativeText = """
            Changing fan speeds needs a small background program that runs with administrator rights. It is the only part of FanPilot that can write to the fans, and it limits every request to the safe range of your fans.

            macOS will ask for your password. The helper is installed as a launch daemon (com.fanpilot.helper) and can be removed at any time from Settings > Helper.

            Without it FanPilot still shows temperatures and fan speeds.

            It will install the helper files from:
            \(HelperInstaller.payloadDirectory()?.path ?? "this app")
            Only continue if you trust this copy of FanPilot.
            """
        alert.addButton(withTitle: "Install Helper…")
        alert.addButton(withTitle: fromStartup ? "Skip" : "Cancel")
        if fromStartup {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not show this again"
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if fromStartup, alert.suppressionButton?.state == .on { extras.skipHelperPrompt = true }
        guard response == .alertFirstButtonReturn else { return }
        runHelperAction(.install)
    }

    func confirmAndUninstallHelper() {
        guard !installInProgress else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the fan helper?"
        alert.informativeText = "Fan control stops working until it is installed again. Every fan is returned to system control first. macOS will ask for your password."
        alert.addButton(withTitle: "Remove Helper…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runHelperAction(.uninstall(purge: false))
    }

    private func runHelperAction(_ action: HelperInstaller.Action) {
        installInProgress = true
        installOutput = nil
        // Our own fans go back to the system before the helper is replaced or removed.
        controlSuspended = true
        client.releaseAll()
        HelperInstaller.run(action) { outcome in
            MainActor.assumeIsolated { AppModel.shared.helperActionFinished(action, outcome: outcome) }
        }
    }

    private func helperActionFinished(_ action: HelperInstaller.Action, outcome: HelperInstaller.Outcome) {
        controlSuspended = false
        switch outcome {
        case .cancelled:
            installInProgress = false
            postNotice("Cancelled. Nothing was changed.", kind: .info)
        case .failure(let message):
            installInProgress = false
            installOutput = message
            presentAlert(title: "The helper could not be changed", message: Self.tail(message), style: .warning)
        case .success(let output):
            installOutput = output
            switch action {
            case .install:
                // Stay "in progress" until the socket answers; handle(helperUpdate:) clears it.
                client.retryNow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, self.installInProgress else { return }
                    self.installInProgress = false
                    if !self.helper.isConnected {
                        self.postNotice("The installer finished, but the helper is not answering yet. See Settings > Helper.",
                                        kind: .warning)
                    }
                }
            case .uninstall:
                installInProgress = false
                client.retryNow()
                postNotice("The fan helper was removed. FanPilot is now monitor only.", kind: .info)
            }
        }
    }

    private static func tail(_ text: String, lines: Int = 12) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(lines).joined(separator: "\n")
    }

    // MARK: Alerts

    func presentAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        runLater(after: 0) {
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Runs `work` from a run loop timer. Alerts must start there and not from a `DispatchQueue.main`
    /// block: a modal loop started inside a main-queue block would keep every other main-queue block
    /// (sensor snapshots, helper updates) waiting until the alert is dismissed.
    func runLater(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Warns when the menu bar item has no room (notch or too many items).
    func scheduleHiddenItemCheck() {
        guard settings.menuBar.showHiddenAlert, !hiddenAlertChecked else { return }
        hiddenAlertChecked = true
        runLater(after: 4) { [weak self] in
            guard let self, self.settings.menuBar.showHiddenAlert else { return }
            guard StatusItemLocator.isVisibleOnScreen() == false else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "FanPilot's menu bar item is hidden"
            alert.informativeText = "There is no room for it in the menu bar, maybe because of the notch or other menu bar items. Show less in the menu bar item, or quit menu bar apps you do not need."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Menu Bar Settings")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                WindowCoordinator.shared.showSettings(pane: .menuBar)
            }
        }
    }
}
