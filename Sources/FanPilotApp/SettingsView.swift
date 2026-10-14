import AppKit
import FanPilotKit
import FanPilotSensors
import SwiftUI
import UserNotifications

/// Content of the Settings window; the toolbar (owned by `WindowCoordinator`) picks the pane.
struct SettingsRootView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        Group {
            switch nav.pane {
            case .general: GeneralPane()
            case .menuBar: MenuBarPane()
            case .notifications: NotificationsPane()
            case .log: LogPane()
            case .fan: FanPane()
            case .helper: HelperPane()
            case .about: AboutPane()
            }
        }
        .frame(width: nav.pane.size.width, height: nav.pane.size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A labeled slider with a trailing value, used by several panes.
struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var suffix: String = ""
    var enabled = true
    /// Overrides the default `Int(value) + suffix` text (for values that depend on the temperature unit).
    var display: ((Double) -> String)?

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 130, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range).disabled(!enabled)
            Text(display?(value) ?? "\(Int(value))\(suffix)").monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch FanPilot at login", isOn: $model.settings.launchAtLogin)
                if let message = model.loginItemMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Button("Open Login Items Settings") { LoginItem.openSystemSettings() }.controlSize(.small)
                        }
                    }
                }
                Toggle(isOn: $model.settings.showDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Dock icon")
                        Text("Off: only the menu bar item is visible.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Update Frequency") {
                LabeledContent("Read sensors every") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.settings.updateIntervalSecs) },
                                              set: { model.settings.updateIntervalSecs = Int($0.rounded()) }),
                               in: 1...60)
                            .frame(width: 220)
                        Text("\(model.settings.updateIntervalSecs) sec").monospacedDigit().frame(width: 52, alignment: .leading)
                    }
                }
                Text("Faster updates use a little more power. Fan ramps always run once a second.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Temperature Unit") {
                Picker("Unit", selection: $model.settings.tempUnit) {
                    Text("Celsius (\u{00B0}C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (\u{00B0}F)").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Button("Reset Max Temperatures") { model.resetMaxTemperatures() }
                    .help("Clears the highest temperature remembered for each sensor")
            }

            Section("Keyboard Shortcuts") {
                Toggle(isOn: $model.settings.enableShowWindowHotKey) {
                    HStack { Text("Show main window"); Spacer(); Text(HotKeyManager.showWindowDescription).foregroundStyle(.secondary) }
                }
                Toggle(isOn: $model.settings.enableToggleMenuHotKey) {
                    HStack { Text("Open or close the menu panel"); Spacer(); Text(HotKeyManager.toggleMenuDescription).foregroundStyle(.secondary) }
                }
            }

            Section("Reset") {
                Button("Reset FanPilot to Defaults\u{2026}", role: .destructive) { resetToDefaults() }
                Text("Restores every setting, including Auto Boost rules and the fan curve. The helper is not touched.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func resetToDefaults() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset FanPilot to defaults?"
        alert.informativeText = "All settings return to their defaults. This also removes the Auto Boost rules and curve you created. Fans are returned to system control."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.resetToDefaults()
    }
}

extension AppModel {
    func resetToDefaults() {
        var fresh = AppSettings()
        fresh.isFirstLaunch = false
        fresh.launchAtLogin = settings.launchAtLogin    // the login item is the system's to change
        settings = fresh.normalized(fanCount: fanCount)
        extras = AppExtras()
        // The alert promises "Fans are returned to system control". The new Auto policy alone does not
        // send anything when the fresh controller already believes the fans are in auto, so release
        // explicitly (ordered before any command that follows).
        resetController(releasingFans: true)
        clearCommandFailures()
        requestControlTick(immediate: true)
    }
}

// MARK: - Menu Bar

struct MenuBarPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Preview") {
                HStack {
                    Spacer()
                    Image(nsImage: model.statusImage)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    Spacer()
                }
                Text("Hover over the real menu bar item to see which sensor each number is.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Menu Bar Content") {
                slotRow("Temperature", enabled: tempEnabled(\.temp1), source: tempSource(\.temp1))
                slotRow("Second temperature", enabled: tempEnabled(\.temp2), source: tempSource(\.temp2))
                if model.hasFans {
                    HStack {
                        Toggle("Fan RPM", isOn: guarded(get: { model.settings.menuBar.fan.enabled },
                                                         set: { model.settings.menuBar.fan.enabled = $0 }))
                            .frame(width: 180, alignment: .leading)
                        Picker("Fan", selection: Binding(get: { model.settings.menuBar.fan.source },
                                                         set: { model.settings.menuBar.fan.source = $0 })) {
                            Text("Average RPM").tag(MenuBarFanSource.average)
                            Divider()
                            ForEach(model.fanInfos) { Text($0.name).tag(MenuBarFanSource.fan($0.index)) }
                        }
                        .labelsHidden()
                        .disabled(!model.settings.menuBar.fan.enabled)
                    }
                }
            }

            Section("Text Order") {
                Picker("Layout", selection: $model.settings.menuBar.stackOrder) {
                    Text("Horizontal").tag(MenuBarStackOrder.horizontal)
                    Text("Vertical").tag(MenuBarStackOrder.vertical)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }

            Section("Options") {
                Toggle(isOn: $model.settings.menuBar.useSmallerFont) {
                    HStack {
                        Text("Use smaller font")
                        if model.settings.menuBar.stackOrder == .vertical {
                            Text("(only for Horizontal)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(model.settings.menuBar.stackOrder == .vertical)
                Toggle("Use shorter titles (35 2000 instead of 35\u{00B0}C 2000 RPM)", isOn: $model.settings.menuBar.useShorterTitles)
                Toggle("Use orange and red for high temperatures", isOn: $model.settings.menuBar.useColors)
                Toggle("Use color for the override symbol", isOn: $model.settings.menuBar.useColorForOverrideSymbol)
                Toggle("List every sensor in the menu", isOn: $model.extras.listAllMenuSensors)
                Toggle("Show application icon", isOn: iconBinding)
                Toggle("Warn at launch if the menu bar item is hidden", isOn: $model.settings.menuBar.showHiddenAlert)
            }

            Section("Menu Layout") {
                Picker("Fan controls", selection: $model.settings.menuBar.fanControlsAtTop) {
                    Text("Above").tag(true)
                    Text("Below").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 300)
                .disabled(!model.hasFans)
                Picker("Show Main Window & Settings", selection: $model.settings.menuBar.commonSectionAtTop) {
                    Text("Above").tag(true)
                    Text("Below").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 380)
                Text("Above or below the temperatures.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func slotRow(_ title: String, enabled: Binding<Bool>, source: Binding<SensorSelector>) -> some View {
        HStack {
            Toggle(title, isOn: enabled).frame(width: 180, alignment: .leading)
            SensorSelectorPicker(selection: source).disabled(!enabled.wrappedValue)
        }
    }

    private func tempEnabled(_ keyPath: WritableKeyPath<MenuBarSettings, MenuBarTempSlot>) -> Binding<Bool> {
        guarded(get: { model.settings.menuBar[keyPath: keyPath].enabled },
                set: { model.settings.menuBar[keyPath: keyPath].enabled = $0 })
    }

    private func tempSource(_ keyPath: WritableKeyPath<MenuBarSettings, MenuBarTempSlot>) -> Binding<SensorSelector> {
        Binding(get: { model.settings.menuBar[keyPath: keyPath].source },
                set: { model.settings.menuBar[keyPath: keyPath].source = $0 })
    }

    /// Refuses to turn off the last visible thing: an empty item could not be clicked.
    private func guarded(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { value in
            if !value, get(), visibleCount() <= 1, !model.settings.menuBar.showAppIcon {
                warnLastItem()
                return
            }
            set(value)
        })
    }

    private var iconBinding: Binding<Bool> {
        Binding(get: { model.settings.menuBar.showAppIcon }, set: { value in
            if !value, visibleCount() == 0 { warnLastItem(); return }
            model.settings.menuBar.showAppIcon = value
        })
    }

    private func visibleCount() -> Int {
        let bar = model.settings.menuBar
        return [bar.temp1.enabled, bar.temp2.enabled, bar.fan.enabled && model.hasFans].filter { $0 }.count
    }

    private func warnLastItem() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Keep something visible"
        alert.informativeText = "The menu bar item needs at least one temperature, the fan speed, or the application icon. Otherwise there would be nothing to click."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Send Using") {
                Toggle("Notification Center", isOn: $model.settings.alerts.useLocalNotifications)
                if !Notifier.isAvailable {
                    Label("Notifications need the FanPilot app bundle. They are unavailable when it runs from a build folder.",
                          systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if model.notificationsBlocked, model.settings.alerts.useLocalNotifications {
                    HStack {
                        Label("Notifications are turned off for FanPilot in System Settings.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }.controlSize(.small)
                    }
                }
            }

            Section("Notify When the Temperature Is Above the Limit") {
                limitRow("Any sensor", enabled: $model.settings.alerts.anySensorEnabled, value: $model.settings.alerts.anySensorLimitC)
                limitRow("Highest CPU", enabled: $model.settings.alerts.highestCPUEnabled, value: $model.settings.alerts.highestCPULimitC)
                Text("The same notification is not repeated within \(Int(model.settings.alerts.repeatIntervalSeconds / 60)) minutes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Also Notify When") {
                if model.hasFans {
                    Toggle("Fan Auto Boost turns on or off", isOn: $model.settings.alerts.boostChangeEnabled)
                }
                Toggle("Battery health is not normal", isOn: $model.settings.alerts.batteryHealthEnabled)
                    .disabled(!model.battery.isPresent)
                Text("A notification is also sent if the helper's safety failsafe takes over the fans.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Colors") {
                LabeledSlider(title: "Orange from", value: warningBinding, range: 40...105,
                              display: { Fmt.temperature($0, unit: model.temperatureUnit) })
                LabeledSlider(title: "Red from", value: criticalBinding, range: 40...110,
                              display: { Fmt.temperature($0, unit: model.temperatureUnit) })
                Text("Used for the menu bar text and the level bars.").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Options") {
                Toggle("Play sound", isOn: $model.settings.alerts.playSound)
                Picker("Sound", selection: Binding(get: { model.settings.alerts.soundName ?? "" },
                                                   set: { model.settings.alerts.soundName = $0.isEmpty ? nil : $0 })) {
                    Text("Default").tag("")
                    ForEach(Notifier.systemSoundNames(), id: \.self) { Text($0).tag($0) }
                }
                .disabled(!model.settings.alerts.playSound)
                Button("Send Test Notification") { sendTest() }
                    .disabled(!Notifier.isAvailable || !model.settings.alerts.useLocalNotifications)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshNotificationStatus() }
    }

    private func limitRow(_ title: String, enabled: Binding<Bool>, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: enabled).frame(width: 130, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: 40...105)
                .disabled(!enabled.wrappedValue)
            Text(Fmt.temperature(value.wrappedValue, unit: model.temperatureUnit)).monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var warningBinding: Binding<Double> {
        Binding(get: { model.settings.alerts.warningTempC }, set: {
            model.settings.alerts.warningTempC = $0
            if model.settings.alerts.criticalTempC < $0 { model.settings.alerts.criticalTempC = $0 }
        })
    }

    private var criticalBinding: Binding<Double> {
        Binding(get: { model.settings.alerts.criticalTempC }, set: {
            model.settings.alerts.criticalTempC = max($0, model.settings.alerts.warningTempC)
        })
    }

    private func sendTest() {
        Task { @MainActor in
            let allowed = await model.notifier.requestAuthorization()
            model.notificationsBlocked = !allowed
            guard allowed else { return }
            model.notifier.post(key: "test", title: "FanPilot test notification",
                                body: "Notifications work. High temperatures will show up like this.",
                                repeatInterval: 0,
                                sound: model.settings.alerts.playSound ? (model.settings.alerts.soundName ?? "") : nil)
        }
    }
}

// MARK: - Log

struct LogPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Log File") {
                Toggle("Write a CSV log of temperatures and fan speeds", isOn: $model.settings.log.logToFile)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(folderPath).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .help(folderPath)
                HStack {
                    Button("Open") { NSWorkspace.shared.open(model.logFileURL) }
                        .disabled(!model.settings.log.logToFile || !FileManager.default.fileExists(atPath: model.logFileURL.path))
                    Button("Reveal in Finder") { reveal() }
                    Button("Choose Folder\u{2026}") { chooseFolder() }
                    if model.extras.logFolderPath != nil {
                        Button("Use Default") { model.extras.logFolderPath = nil }
                    }
                }
            }

            Section("Logging Options") {
                Picker("Write a row every", selection: $model.extras.logIntervalSecs) {
                    ForEach([1, 2, 5, 10, 30, 60, 300, 600], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min").tag(seconds)
                    }
                }
                .frame(width: 260)
                Toggle("Log temperatures", isOn: $model.settings.log.logTemperatures)
                Toggle("Log fan speeds", isOn: $model.settings.log.logFanSpeeds)
                Toggle("Log notifications", isOn: $model.settings.log.logAlerts)
                Toggle("Log diagnostics", isOn: $model.extras.logDiagnostics)
                Toggle("Use ISO 8601 dates (YYYY-MM-DD)", isOn: $model.settings.log.useISO8601Dates)
            }

            Section("Create a New Log File") {
                Picker("Create", selection: $model.settings.log.newFileMode) {
                    Text("Never").tag(LogSettings.NewFileMode.never)
                    Text("On app startup").tag(LogSettings.NewFileMode.onStartup)
                    Text("Every day at midnight").tag(LogSettings.NewFileMode.daily)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if model.settings.log.newFileMode == .never {
                    Text("A single file can grow very large over time.")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var folderPath: String {
        model.extras.logFolderPath ?? CSVLogger.defaultFolder.path
    }

    private func reveal() {
        let url = model.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder for FanPilot's log files."
        if panel.runModal() == .OK, let url = panel.url { model.extras.logFolderPath = url.path }
    }
}
