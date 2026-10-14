import AppKit
import FanPilotControl
import FanPilotKit
import FanPilotSensors
import Foundation

// Sensor polling, derived data (menu bar item, diagnostics, alerts, CSV log).

extension AppModel {
    // MARK: Monitor

    func startSensors() {
        do {
            let configuration = SensorMonitor.Configuration(interval: Double(settings.updateIntervalSecs),
                                                            callbackQueue: .main)
            let monitor = try SensorMonitor(configuration: configuration)
            monitor.onSnapshot = { snapshot in
                // Delivered on the main queue (callbackQueue above).
                MainActor.assumeIsolated { AppModel.shared.handle(snapshot: snapshot) }
            }
            self.monitor = monitor
            updatePrioritySensors()
            monitor.start()
        } catch {
            sensorProblem = "Could not open the SMC for reading: \(error). Temperatures and fan speeds are unavailable."
            refreshStatusItem()
        }
    }

    /// Sensors the user relies on (menu bar slots, pins, Boost rules, the curve) are polled on every
    /// update even when they belong to a slowly sampled group such as "Other" or the HID sensors.
    func updatePrioritySensors() {
        var ids = Set(settings.pinnedSensorIDs)
        func add(_ selector: SensorSelector) { if case .sensor(let id) = selector { ids.insert(id) } }
        for slot in [settings.menuBar.temp1, settings.menuBar.temp2] where slot.enabled { add(slot.source) }
        for rule in settings.policy.boost.rules where rule.enabled { add(rule.sensor) }
        add(settings.policy.curve.source)
        monitor?.setPriorityIDs(ids)
    }

    func handle(snapshot new: SensorSnapshot) {
        guard !terminating else { return }
        snapshot = new
        // Assigning an unchanged @Published value still notifies every observer; skip the no-ops.
        if !hasSnapshot { hasSnapshot = true }
        if new.readings.isEmpty, new.fans.isEmpty {
            sensorProblem = monitor?.engine.lastErrorDescription ?? "No temperature sensors were found."
        } else if sensorProblem != nil {
            sensorProblem = nil
        }
        lastSampleUptime = ProcessInfo.processInfo.systemUptime

        temps = TemperatureInputs(
            sampledAt: lastSampleUptime,
            computerAverage: new.aggregates.computerAverage,
            highest: new.aggregates.highest,
            averageCPU: new.aggregates.averageCPU,
            highestCPU: new.aggregates.highestCPU,
            hotSetMax: new.aggregates.hotSetMax,
            sensors: Dictionary(uniqueKeysWithValues: new.readings.filter(\.valid).map { ($0.id, $0.value) }))

        // The fan count is known only from the first snapshot on: size the per-fan policy to it.
        if !new.fanInfos.isEmpty, settings.policy.perFan.count != new.fanInfos.count {
            settings.policy = settings.policy.normalized(fanCount: new.fanInfos.count)
        }

        if awaitingFreshSampleAfterWake, wakeDelayElapsed, !new.readings.isEmpty {
            awaitingFreshSampleAfterWake = false
            resumeControlAfterWakeIfReady()
        }
        controlTick()
        refreshStatusItem()
        evaluateAlerts()
        logger.log(snapshot: new, diagnostics: diagnostics)

        snapshotCounter += 1
        if snapshotCounter == 1 || snapshotCounter % 5 == 0 { refreshDiagnostics() }
        if snapshotCounter == 1 { firstSnapshotArrived() }
    }

    private func firstSnapshotArrived() {
        if settings.isFirstLaunch {
            settings.isFirstLaunch = false
            WindowCoordinator.shared.showMainWindow()
        }
        offerHelperInstallIfNeeded()
        scheduleHiddenItemCheck()
    }

    /// Resets the per-sensor session maxima ("Reset Max Temperatures").
    func resetMaxTemperatures() {
        monitor?.resetSessionMax()
        monitor?.refreshNow()
    }

    /// Reads every sensor, including the slow "Other" group (used when that list is opened).
    func refreshFully() {
        monitor?.refreshNow(full: true)
    }

    // MARK: Menu bar item

    func refreshStatusItem() {
        let dark = StatusItemLocator.menuBarIsDark()
        let content = StatusBarContent.make(snapshot: hasSnapshot ? snapshot : nil, settings: settings,
                                            fansMayStop: fansMayStop, overriding: isOverriding)
        let showPlaceholder = !hasSnapshot || (content.lines.isEmpty && !content.showIcon)
        let key = StatusItemKey(content: content, dark: dark, placeholder: showPlaceholder, problem: sensorProblem != nil)
        // Redrawing an identical image would only make SwiftUI re-render the menu bar label.
        guard key != lastStatusKey else { return }
        lastStatusKey = key

        if showPlaceholder {
            // No data yet, or a sensor failure: a symbol so the item stays visible and clickable.
            statusImage = Self.placeholderImage(problem: sensorProblem != nil)
        } else {
            statusImage = StatusItemRenderer.image(for: content, menuBarIsDark: dark)
        }
        StatusItemLocator.setToolTip(content.tooltip)
    }

    private static func placeholderImage(problem: Bool) -> NSImage {
        let name = problem ? "exclamationmark.triangle" : "fan"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FanPilot")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    // MARK: Diagnostics

    func refreshDiagnostics() {
        guard let monitor else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let ages = manualCommandSince.mapValues { now - $0 }
        DispatchQueue.global(qos: .utility).async {
            let report = monitor.diagnostics(manualCommandAge: ages)
            let battery = BatteryReader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    model.diagnostics = report
                    model.battery = battery
                    model.batteryHealthNotification(report)
                }
            }
        }
    }

    private func batteryHealthNotification(_ report: DiagnosticsReport) {
        guard settings.alerts.useLocalNotifications, settings.alerts.batteryHealthEnabled,
              report.battery.status == .warning, !batteryHealthAlertSent else { return }
        batteryHealthAlertSent = true      // once per launch
        notifier.post(key: "battery-health", title: "Battery health",
                      body: report.battery.message, repeatInterval: .infinity, sound: soundName)
        logger.logAlert("Battery health: \(report.battery.message)")
    }

    // MARK: Alerts

    private var soundName: String? {
        settings.alerts.playSound ? (settings.alerts.soundName ?? "") : nil
    }

    func evaluateAlerts() {
        let alerts = settings.alerts
        guard alerts.useLocalNotifications else { return }
        let unit = settings.tempUnit
        let advice = hasFans
            ? "Consider quitting apps that use a lot of CPU, or raising the fan speed."
            : "Consider quitting apps that use a lot of CPU."

        if alerts.anySensorEnabled {
            for reading in snapshot.readings where reading.valid && reading.sensor.area != .other
                && reading.value > alerts.anySensorLimitC.rounded(.towardZero) {
                let title = "\(reading.sensor.name) is \(unit.format(celsius: reading.value))"
                if notifier.post(key: "sensor-\(reading.id)", title: title, body: advice,
                                 repeatInterval: alerts.repeatIntervalSeconds, sound: soundName) {
                    logger.logAlert(title)
                }
            }
        }
        if alerts.highestCPUEnabled, let hottest = snapshot.aggregates.highestCPU,
           hottest > alerts.highestCPULimitC.rounded(.towardZero) {
            let title = "Highest CPU temperature is \(unit.format(celsius: hottest))"
            if notifier.post(key: "cpu-highest", title: title, body: advice,
                             repeatInterval: alerts.repeatIntervalSeconds, sound: soundName) {
                logger.logAlert(title)
            }
        }
    }

    func notifyFailsafe(_ failsafe: FailsafeStatus) {
        guard failsafe.active, settings.alerts.useLocalNotifications else { return }
        if failsafe.isBlind {
            // No temperature is readable: the helper gave the fans back to the system. They are NOT at maximum.
            if notifier.post(key: "failsafe-blind", title: "Fan helper cannot read temperatures",
                             body: "The helper returned the fans to system control until temperatures can be read again.",
                             repeatInterval: 600, sound: soundName) {
                logger.logAlert("Helper blind: fans returned to system control")
            }
            return
        }
        let temp = failsafe.tempC.map { " at \(settings.tempUnit.format(celsius: $0))" } ?? ""
        if notifier.post(key: "failsafe", title: "Fan failsafe engaged",
                         body: "A sensor reached the safety limit\(temp). The helper forced the fans to maximum.",
                         repeatInterval: 600, sound: soundName) {
            logger.logAlert("Failsafe engaged\(temp)")
        }
    }

    func notifyBoostChange(output: ControllerOutput) {
        let active = !output.activeBoostRuleIDs.isEmpty
        defer { lastBoostActive = active }
        guard settings.alerts.useLocalNotifications, settings.alerts.boostChangeEnabled,
              active != lastBoostActive else { return }
        if active {
            let percents = output.directives.compactMap { directive -> Double? in
                guard directive.mode == .boost, let goal = directive.goalRPM,
                      let info = fanInfos.first(where: { $0.index == directive.fanIndex }) else { return nil }
                return RPMMath.percent(forRPM: goal, limits: FanLimits(info))
            }
            let text = percents.max().map { "Fans are being boosted to \(Int($0.rounded()))%." } ?? "Fans are being boosted."
            notifier.post(key: "boost-on", title: "Auto Boost", body: text, repeatInterval: 0, sound: soundName)
        } else {
            notifier.post(key: "boost-off", title: "Auto Boost", body: "Fan speeds are returning to normal.",
                          repeatInterval: 0, sound: soundName)
        }
    }
}

/// What the menu bar image depends on; used to skip redundant redraws.
struct StatusItemKey: Equatable {
    var content: StatusBarContent
    var dark: Bool
    var placeholder: Bool
    var problem: Bool
}
