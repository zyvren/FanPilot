import AppKit
import Combine
import FanPilotControl
import FanPilotKit
import FanPilotSensors
import Foundation
import SwiftUI

/// A short message shown in a banner (errors from the helper, install results, ...).
struct Notice: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    let id = UUID()
    var text: String
    var kind: Kind
}

extension FailsafeStatus {
    /// The helper could not read any temperature and gave the fans back to the system. Unlike the
    /// hot-sensor failsafe the fans are NOT at maximum.
    var isBlind: Bool { reason == "blind" }
}

/// What the app knows about the root helper right now.
struct HelperState: Equatable {
    var availability: HelperAvailability = .connecting
    var hello: HelloReply?
    var status: StatusReply?
    /// Last refusal of a fan command, kept until the next successful connection.
    var lastCommandError: String?

    var isConnected: Bool { availability.isConnected }
    var monitorOnly: Bool { hello?.monitorOnly ?? true }
    var failsafe: FailsafeStatus { status?.failsafe ?? .inactive }

    /// Fans the helper is able to drive.
    var controllableFans: Set<Int> {
        guard isConnected, let hello, !hello.monitorOnly else { return [] }
        return Set(hello.fans.filter { $0.backend.canControl }.map(\.index))
    }

    var canControl: Bool { !controllableFans.isEmpty }
}

/// The single source of truth for the UI: sensors, fans, helper, control policy and preferences.
///
/// Responsibilities (split over the `AppModel+*.swift` files):
/// - polls sensors through `SensorMonitor` and publishes the snapshot (+Sensors),
/// - runs `FanController` on every snapshot and once per second, and hands its commands to the
///   helper (+Control),
/// - follows sleep/wake and the power source, and shuts down cleanly (+Lifecycle),
/// - persists `AppSettings` (Kit) and `AppExtras` (app-only) to UserDefaults.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: Preferences

    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published var extras: AppExtras {
        didSet { if extras != oldValue { extras.save(to: Self.defaults); extrasDidChange(from: oldValue) } }
    }

    // MARK: Live state

    @Published var snapshot = SensorSnapshot()
    @Published var hasSnapshot = false
    @Published var sensorProblem: String?
    @Published var helper = HelperState()
    @Published var powerSource: PowerSource = .adapter
    @Published var lastOutput: ControllerOutput?
    @Published var diagnostics: DiagnosticsReport?
    @Published var battery: BatteryInfo = .absent
    @Published var notice: Notice?
    @Published var statusImage: NSImage = NSImage(size: NSSize(width: 1, height: 1))
    @Published var notificationsBlocked = false
    @Published var loginItemMessage: String?
    @Published var installInProgress = false
    @Published var installOutput: String?
    /// Set while fan control is paused for a sleep/wake cycle.
    @Published var controlSuspended = false
    /// Fans whose latest speed command the helper refused (cleared when a later command works).
    @Published var refusedFans: Set<Int> = []

    let hardware: HardwareInfo

    // MARK: Services

    var monitor: SensorMonitor?
    let client = HelperClient(socketPath: ProcessInfo.processInfo.environment["FANPILOT_SOCKET"] ?? Constants.socketPath)
    let power = PowerMonitor()
    let notifier = Notifier()
    let logger = CSVLogger()
    let hotKeys = HotKeyManager()

    // MARK: Control state

    var controller = FanController()
    var temps = TemperatureInputs.none
    var lastSampleUptime: TimeInterval = 0
    var manualCommandSince: [Int: TimeInterval] = [:]
    var lastControlTickAt: TimeInterval = 0
    var pendingTick: DispatchWorkItem?
    var controlTimer: Timer?
    var wakeWork: DispatchWorkItem?
    var lastBoostActive = false
    /// Fans we have sent a speed command to and not yet seen released; the status reconciliation
    /// (SPEC 5.5) only touches these, so it never cancels a hold that belongs to `fanpilotctl`.
    var claimedFans: Set<Int> = []
    /// Consecutive refusals per fan, for the retry backoff.
    var commandFailures: [Int: Int] = [:]
    var retryWork: [Int: DispatchWorkItem] = [:]
    var postedFailureKeys: Set<String> = []
    /// After wake the pre-sleep temperatures are discarded; control resumes only once a sample taken
    /// after the SMC settled has arrived (see `systemDidWake`).
    var wakeDelayElapsed = true
    var awaitingFreshSampleAfterWake = false
    var lastStatusKey: StatusItemKey?

    // MARK: Bookkeeping

    var started = false
    /// Keeps App Nap away: a napping menu bar app would delay the heartbeat past the helper's lease
    /// and stall fan ramps. The system may still idle-sleep.
    var activity: NSObjectProtocol?
    var snapshotCounter = 0
    var saveWork: DispatchWorkItem?
    var noticeWork: DispatchWorkItem?
    var suppressLoginSync = false
    var batteryHealthAlertSent = false
    var helperPromptShown = false
    var hiddenAlertChecked = false
    var terminating = false

    // MARK: Init

    /// Where preferences live. `FANPILOT_DEFAULTS_SUITE` points a development run at a scratch domain so
    /// tests never touch the real settings; `FANPILOT_SOCKET` likewise redirects the helper socket.
    static let defaults: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["FANPILOT_DEFAULTS_SUITE"], !suite.isEmpty,
           let custom = UserDefaults(suiteName: suite) { return custom }
        return .standard
    }()

    private init() {
        hardware = HardwareInfo.current()
        let defaults = Self.defaults
        var loaded = AppSettings.decode(from: defaults.data(forKey: Constants.settingsDefaultsKey))
        let extras = AppExtras.load(from: defaults)

        // Safe start (SPEC 4.6): fans begin in system control. The mode used last time is kept
        // for "Resume last mode", and applied right away only if the user asked for that.
        if !loaded.resumeOnLaunch {
            let fanCount = loaded.policy.perFan.count
            if let mode = loaded.policy.uniformMode(fanCount: fanCount), mode != .auto {
                loaded.lastMode = mode
            }
            loaded.policy.setMode(.auto, fanCount: fanCount)
        }
        settings = loaded
        self.extras = extras
    }

    // MARK: Derived values for views

    var fanInfos: [FanInfo] { snapshot.fanInfos }
    var hasFans: Bool { !snapshot.fanInfos.isEmpty || !(helper.hello?.fans.isEmpty ?? true) }
    var fanCount: Int { snapshot.fanInfos.count }

    func fanReading(_ index: Int) -> FanReading? { snapshot.fans.first { $0.index == index } }

    /// The mode shared by all fans, nil when they differ (or there are no fans).
    var controlMode: ControlMode? { settings.policy.uniformMode(fanCount: fanCount) }

    var usePercent: Bool { settings.policy.boost.usePercent }

    /// True when FanPilot can actually change fan speeds right now.
    var canControlFans: Bool { helper.canControl && !helper.failsafe.active }

    /// Any fan is currently being driven by FanPilot (a speed command is in force).
    var isOverriding: Bool {
        lastOutput?.directives.contains { $0.command != .auto } ?? false
    }

    func directive(forFan index: Int) -> FanDirective? { lastOutput?.directive(forFan: index) }

    var temperatureUnit: TemperatureUnit { settings.tempUnit }

    /// Areas that have sensors, in display order; "Other" only when the user asked for it.
    var visibleGroups: [SensorGroup] {
        snapshot.groups.filter { $0.area != .other || settings.showOtherSensors }
    }

    /// The sidebar selection that is really in effect: the stored one, unless that area is not in the
    /// visible list any more ("Other" after "Show all sensors" was turned off, an area a sensor change
    /// removed). The stored value survives relaunches, so every consumer must go through this.
    var effectiveArea: String {
        let stored = extras.activeArea
        return stored == "all" || visibleGroups.contains { $0.area.rawValue == stored } ? stored : "all"
    }

    /// Sensors a picker may offer (the curated list; "Other" only when shown).
    var pickerGroups: [SensorGroup] { visibleGroups }

    /// True when this Mac fans may sit at 0 RPM legitimately.
    var fansMayStop: Bool { hardware.isAppleSilicon }

    // MARK: Notices

    func postNotice(_ text: String, kind: Notice.Kind = .info, dismissAfter seconds: TimeInterval = 8) {
        notice = Notice(text: text, kind: kind)
        noticeWork?.cancel()
        let id = notice?.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.notice?.id == id else { return }
            self.notice = nil
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismissNotice() {
        noticeWork?.cancel()
        notice = nil
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        do {
            let data = try settings.encoded()
            Self.defaults.set(data, forKey: Constants.settingsDefaultsKey)
        } catch {
            // A failed save must never take the app down; the next change tries again.
            NSLog("FanPilot: could not save settings: \(error)")
        }
        extras.save(to: Self.defaults)
    }

    // MARK: Settings side effects

    private func settingsDidChange(from old: AppSettings) {
        guard started else { return }
        scheduleSave()

        if settings.updateIntervalSecs != old.updateIntervalSecs {
            monitor?.setInterval(Double(settings.updateIntervalSecs))
        }
        if settings.showDockIcon != old.showDockIcon { applyActivationPolicy() }
        if settings.launchAtLogin != old.launchAtLogin, !suppressLoginSync { applyLaunchAtLogin() }
        if settings.log != old.log || settings.tempUnit != old.tempUnit { configureLogger() }
        if settings.menuBar != old.menuBar || settings.tempUnit != old.tempUnit || settings.alerts != old.alerts {
            refreshStatusItem()
        }
        if settings.policy != old.policy { policyDidChange(from: old.policy) }
        if settings.policy.boost.rules != old.policy.boost.rules || settings.policy.curve.source != old.policy.curve.source
            || settings.menuBar != old.menuBar || settings.pinnedSensorIDs != old.pinnedSensorIDs {
            updatePrioritySensors()
        }
        if settings.enableShowWindowHotKey != old.enableShowWindowHotKey
            || settings.enableToggleMenuHotKey != old.enableToggleMenuHotKey {
            applyHotKeys()
        }
        if settings.alerts.useLocalNotifications, !old.alerts.useLocalNotifications {
            requestNotificationAuthorization()
        }
    }

    private func extrasDidChange(from old: AppExtras) {
        guard started else { return }
        if extras.logIntervalSecs != old.logIntervalSecs || extras.logFolderPath != old.logFolderPath
            || extras.logDiagnostics != old.logDiagnostics {
            configureLogger()
        }
    }

    func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = settings.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
            if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func applyLaunchAtLogin() {
        do {
            try LoginItem.set(enabled: settings.launchAtLogin)
            loginItemMessage = LoginItem.state == .requiresApproval
                ? "Allow FanPilot in System Settings > General > Login Items to finish."
                : nil
        } catch {
            loginItemMessage = LoginItem.explain(error)
        }
        // Show what macOS really has, not what the checkbox asked for.
        let actual = LoginItem.state == .enabled || LoginItem.state == .requiresApproval
        if actual != settings.launchAtLogin {
            suppressLoginSync = true
            settings.launchAtLogin = actual
            suppressLoginSync = false
        }
    }

    func configureLogger() {
        let folder = extras.logFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? CSVLogger.defaultFolder
        logger.configure(CSVLogger.Options(settings: settings.log, intervalSeconds: extras.logIntervalSecs,
                                           includeDiagnostics: extras.logDiagnostics, folder: folder,
                                           unit: settings.tempUnit))
    }

    var logFileURL: URL {
        let folder = extras.logFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? CSVLogger.defaultFolder
        return logger.currentFileURL(options: CSVLogger.Options(settings: settings.log, intervalSeconds: extras.logIntervalSecs,
                                                                includeDiagnostics: extras.logDiagnostics, folder: folder,
                                                                unit: settings.tempUnit))
    }

    // MARK: Notifications permission

    func requestNotificationAuthorization() {
        Task { @MainActor in
            let granted = await notifier.requestAuthorization()
            notificationsBlocked = Notifier.isAvailable && !granted
            if notificationsBlocked {
                postNotice("Notifications are turned off for FanPilot. Allow them in System Settings > Notifications.",
                           kind: .warning)
            }
        }
    }

    func refreshNotificationStatus() {
        Task { @MainActor in
            if let status = await notifier.authorizationStatus() {
                notificationsBlocked = status == .denied
            }
        }
    }

    // MARK: Hot keys

    func applyHotKeys() {
        hotKeys.configure(showWindow: settings.enableShowWindowHotKey ? { WindowCoordinator.shared.showMainWindow() } : nil,
                          toggleMenu: settings.enableToggleMenuHotKey ? { WindowCoordinator.shared.toggleQuickPanel() } : nil)
    }
}
