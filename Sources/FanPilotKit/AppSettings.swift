import Foundation

// App preferences (docs/SPEC.md 6). Persisted as one JSON blob under
// `Constants.settingsDefaultsKey`; decoding never fails (see `AppSettings.decode`).

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius
    case fahrenheit

    /// Suffix shown after a value: `°C` / `°F`.
    public var symbol: String { self == .celsius ? "°C" : "°F" }

    /// Converts a Celsius value to this unit (Fahrenheit = C * 1.8 + 32).
    public func convert(fromCelsius c: Double) -> Double {
        self == .celsius ? c : c * 1.8 + 32
    }

    public func toCelsius(_ value: Double) -> Double {
        self == .celsius ? value : (value - 32) / 1.8
    }

    /// `"%.0f"` plus the unit symbol, or `"N/A"` for a missing/invalid value (never a fabricated number).
    public func format(celsius: Double?, includeUnit: Bool = true) -> String {
        guard let celsius, celsius.isFinite else { return "N/A" }
        let text = String(format: "%.0f", convert(fromCelsius: celsius))
        return includeUnit ? text + symbol : text
    }
}

public enum MenuBarStackOrder: String, Codable, CaseIterable, Sendable {
    /// Two lines (the default).
    case vertical
    case horizontal
}

/// A temperature slot in the menu bar label.
public struct MenuBarTempSlot: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var source: SensorSelector

    public init(enabled: Bool = true, source: SensorSelector) {
        self.enabled = enabled
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case enabled, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: c.value(.enabled, default: true), source: c.value(.source, default: .highest))
    }
}

/// What the fan slot of the menu bar label shows. Stored as `average` or `fan:<index>`.
public enum MenuBarFanSource: Hashable, Sendable, Codable {
    case average
    case fan(Int)

    public init(from decoder: Decoder) throws {
        let text = (try? decoder.singleValueContainer().decode(String.self)) ?? "average"
        if text.hasPrefix("fan:"), let index = Int(text.dropFirst(4)), index >= 0 {
            self = .fan(index)
        } else {
            self = .average
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .average: try c.encode("average")
        case .fan(let i): try c.encode("fan:\(i)")
        }
    }
}

public struct MenuBarFanSlot: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var source: MenuBarFanSource

    public init(enabled: Bool = true, source: MenuBarFanSource = .average) {
        self.enabled = enabled
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case enabled, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: c.value(.enabled, default: true), source: c.value(.source, default: .average))
    }
}

public struct MenuBarSettings: Codable, Equatable, Hashable, Sendable {
    /// Defaults: Highest, then Average CPU, then Average RPM.
    public var temp1: MenuBarTempSlot
    public var temp2: MenuBarTempSlot
    public var fan: MenuBarFanSlot
    public var stackOrder: MenuBarStackOrder
    /// Smaller font in horizontal layout.
    public var useSmallerFont: Bool
    /// `35 2000` instead of `35°C 2000 RPM`.
    public var useShorterTitles: Bool
    /// Orange/red text at the warning/critical thresholds.
    public var useColors: Bool
    public var useColorForOverrideSymbol: Bool
    public var showAppIcon: Bool
    /// Warn at launch if the menu bar item is hidden (notch/overflow).
    public var showHiddenAlert: Bool
    /// Menu layout: fan controls above (true) or below the temperatures.
    public var fanControlsAtTop: Bool
    /// "Show window / Settings" block above (true) or below the temperatures.
    public var commonSectionAtTop: Bool

    public init(temp1: MenuBarTempSlot = MenuBarTempSlot(source: .highest),
                temp2: MenuBarTempSlot = MenuBarTempSlot(source: .averageCPU),
                fan: MenuBarFanSlot = MenuBarFanSlot(),
                stackOrder: MenuBarStackOrder = .vertical,
                useSmallerFont: Bool = true,
                useShorterTitles: Bool = false,
                useColors: Bool = true,
                useColorForOverrideSymbol: Bool = true,
                showAppIcon: Bool = false,
                showHiddenAlert: Bool = true,
                fanControlsAtTop: Bool = true,
                commonSectionAtTop: Bool = false) {
        self.temp1 = temp1
        self.temp2 = temp2
        self.fan = fan
        self.stackOrder = stackOrder
        self.useSmallerFont = useSmallerFont
        self.useShorterTitles = useShorterTitles
        self.useColors = useColors
        self.useColorForOverrideSymbol = useColorForOverrideSymbol
        self.showAppIcon = showAppIcon
        self.showHiddenAlert = showHiddenAlert
        self.fanControlsAtTop = fanControlsAtTop
        self.commonSectionAtTop = commonSectionAtTop
    }

    private enum CodingKeys: String, CodingKey {
        case temp1, temp2, fan, stackOrder, useSmallerFont, useShorterTitles, useColors
        case useColorForOverrideSymbol, showAppIcon, showHiddenAlert, fanControlsAtTop, commonSectionAtTop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(temp1: c.value(.temp1, default: MenuBarTempSlot(source: .highest)),
                  temp2: c.value(.temp2, default: MenuBarTempSlot(source: .averageCPU)),
                  fan: c.value(.fan, default: MenuBarFanSlot()),
                  stackOrder: c.value(.stackOrder, default: .vertical),
                  useSmallerFont: c.value(.useSmallerFont, default: true),
                  useShorterTitles: c.value(.useShorterTitles, default: false),
                  useColors: c.value(.useColors, default: true),
                  useColorForOverrideSymbol: c.value(.useColorForOverrideSymbol, default: true),
                  showAppIcon: c.value(.showAppIcon, default: false),
                  showHiddenAlert: c.value(.showHiddenAlert, default: true),
                  fanControlsAtTop: c.value(.fanControlsAtTop, default: true),
                  commonSectionAtTop: c.value(.commonSectionAtTop, default: false))
    }

    /// True if the label would show something: at least one slot or the icon.
    public var hasVisibleContent: Bool {
        temp1.enabled || temp2.enabled || fan.enabled || showAppIcon
    }

    public func normalized() -> MenuBarSettings {
        var copy = self
        if !copy.hasVisibleContent { copy.temp1.enabled = true }     // never leave an unclickable item
        return copy
    }
}

public struct AlertSettings: Codable, Equatable, Hashable, Sendable {
    /// Text turns orange at or above this temperature (default 90 C).
    public var warningTempC: Double
    /// Text turns red at or above this temperature (default 100 C).
    public var criticalTempC: Double
    public var useLocalNotifications: Bool
    /// Notify when any sensor exceeds `anySensorLimitC`.
    public var anySensorEnabled: Bool
    public var anySensorLimitC: Double
    public var highestCPUEnabled: Bool
    public var highestCPULimitC: Double
    /// Notify when Auto Boost starts/stops boosting.
    public var boostChangeEnabled: Bool
    /// A limit notification is not repeated within this many seconds (default 600).
    public var repeatIntervalSeconds: Double
    public var playSound: Bool
    public var soundName: String?
    public var lastShutdownEnabled: Bool
    public var batteryHealthEnabled: Bool

    public init(warningTempC: Double = 90, criticalTempC: Double = 100,
                useLocalNotifications: Bool = true,
                anySensorEnabled: Bool = true, anySensorLimitC: Double = 100,
                highestCPUEnabled: Bool = false, highestCPULimitC: Double = 100,
                boostChangeEnabled: Bool = false, repeatIntervalSeconds: Double = 600,
                playSound: Bool = false, soundName: String? = nil,
                lastShutdownEnabled: Bool = true, batteryHealthEnabled: Bool = true) {
        self.warningTempC = warningTempC
        self.criticalTempC = criticalTempC
        self.useLocalNotifications = useLocalNotifications
        self.anySensorEnabled = anySensorEnabled
        self.anySensorLimitC = anySensorLimitC
        self.highestCPUEnabled = highestCPUEnabled
        self.highestCPULimitC = highestCPULimitC
        self.boostChangeEnabled = boostChangeEnabled
        self.repeatIntervalSeconds = repeatIntervalSeconds
        self.playSound = playSound
        self.soundName = soundName
        self.lastShutdownEnabled = lastShutdownEnabled
        self.batteryHealthEnabled = batteryHealthEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case warningTempC, criticalTempC, useLocalNotifications, anySensorEnabled, anySensorLimitC
        case highestCPUEnabled, highestCPULimitC, boostChangeEnabled, repeatIntervalSeconds
        case playSound, soundName, lastShutdownEnabled, batteryHealthEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(warningTempC: c.value(.warningTempC, default: 90),
                  criticalTempC: c.value(.criticalTempC, default: 100),
                  useLocalNotifications: c.value(.useLocalNotifications, default: true),
                  anySensorEnabled: c.value(.anySensorEnabled, default: true),
                  anySensorLimitC: c.value(.anySensorLimitC, default: 100),
                  highestCPUEnabled: c.value(.highestCPUEnabled, default: false),
                  highestCPULimitC: c.value(.highestCPULimitC, default: 100),
                  boostChangeEnabled: c.value(.boostChangeEnabled, default: false),
                  repeatIntervalSeconds: c.value(.repeatIntervalSeconds, default: 600),
                  playSound: c.value(.playSound, default: false),
                  soundName: try? c.decodeIfPresent(String.self, forKey: .soundName),
                  lastShutdownEnabled: c.value(.lastShutdownEnabled, default: true),
                  batteryHealthEnabled: c.value(.batteryHealthEnabled, default: true))
    }

    public func normalized() -> AlertSettings {
        var copy = self
        copy.warningTempC = sanitized(copy.warningTempC, in: 40...120, fallback: 90)
        copy.criticalTempC = sanitized(copy.criticalTempC, in: 40...130, fallback: 100)
        if copy.criticalTempC < copy.warningTempC { copy.criticalTempC = copy.warningTempC }
        copy.anySensorLimitC = sanitized(copy.anySensorLimitC, in: 40...105, fallback: 100)
        copy.highestCPULimitC = sanitized(copy.highestCPULimitC, in: 40...105, fallback: 100)
        copy.repeatIntervalSeconds = sanitized(copy.repeatIntervalSeconds, in: 30...86_400, fallback: 600)
        return copy
    }
}

public struct LogSettings: Codable, Equatable, Hashable, Sendable {
    public enum NewFileMode: String, Codable, CaseIterable, Sendable {
        case never
        case onStartup
        case daily
    }

    public var logToFile: Bool
    public var logTemperatures: Bool
    public var logFanSpeeds: Bool
    public var logAlerts: Bool
    public var useISO8601Dates: Bool
    public var newFileMode: NewFileMode

    public init(logToFile: Bool = false, logTemperatures: Bool = true, logFanSpeeds: Bool = true,
                logAlerts: Bool = true, useISO8601Dates: Bool = true, newFileMode: NewFileMode = .onStartup) {
        self.logToFile = logToFile
        self.logTemperatures = logTemperatures
        self.logFanSpeeds = logFanSpeeds
        self.logAlerts = logAlerts
        self.useISO8601Dates = useISO8601Dates
        self.newFileMode = newFileMode
    }

    private enum CodingKeys: String, CodingKey {
        case logToFile, logTemperatures, logFanSpeeds, logAlerts, useISO8601Dates, newFileMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(logToFile: c.value(.logToFile, default: false),
                  logTemperatures: c.value(.logTemperatures, default: true),
                  logFanSpeeds: c.value(.logFanSpeeds, default: true),
                  logAlerts: c.value(.logAlerts, default: true),
                  useISO8601Dates: c.value(.useISO8601Dates, default: true),
                  newFileMode: c.value(.newFileMode, default: .onStartup))
    }
}

/// All persisted app preferences.
public struct AppSettings: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Seconds between sensor passes. Default 2; allowed 1...60.
    public var updateIntervalSecs: Int
    public var tempUnit: TemperatureUnit
    public var menuBar: MenuBarSettings
    /// Control policy, including `linkFans` (default true).
    public var policy: Policy
    /// Release the fans when the Mac sleeps and restore afterwards (default true).
    public var turnOffFanControlForSleep: Bool
    /// Re-apply the last mode at launch. Off by default: FanPilot starts in Auto (SPEC 4.6).
    public var resumeOnLaunch: Bool
    /// The mode that was active at quit, offered by "Resume last mode".
    public var lastMode: ControlMode
    public var alerts: AlertSettings
    public var log: LogSettings
    public var launchAtLogin: Bool
    /// Show a Dock icon. Default is menu bar only.
    public var showDockIcon: Bool
    public var enableShowWindowHotKey: Bool
    public var enableToggleMenuHotKey: Bool
    /// Sensors pinned for quick access in the menu bar / menu (`Sensor.id`).
    public var pinnedSensorIDs: [String]
    /// Sensors window: include the "Other" area.
    public var showOtherSensors: Bool
    public var isFirstLaunch: Bool

    public var linkFans: Bool {
        get { policy.linkFans }
        set { policy.linkFans = newValue }
    }

    public init(updateIntervalSecs: Int = 2,
                tempUnit: TemperatureUnit = .celsius,
                menuBar: MenuBarSettings = MenuBarSettings(),
                policy: Policy = Policy(),
                turnOffFanControlForSleep: Bool = true,
                resumeOnLaunch: Bool = false,
                lastMode: ControlMode = .auto,
                alerts: AlertSettings = AlertSettings(),
                log: LogSettings = LogSettings(),
                launchAtLogin: Bool = false,
                showDockIcon: Bool = false,
                enableShowWindowHotKey: Bool = true,
                enableToggleMenuHotKey: Bool = true,
                pinnedSensorIDs: [String] = [],
                showOtherSensors: Bool = false,
                isFirstLaunch: Bool = true) {
        self.schemaVersion = Self.currentSchemaVersion
        self.updateIntervalSecs = updateIntervalSecs
        self.tempUnit = tempUnit
        self.menuBar = menuBar
        self.policy = policy
        self.turnOffFanControlForSleep = turnOffFanControlForSleep
        self.resumeOnLaunch = resumeOnLaunch
        self.lastMode = lastMode
        self.alerts = alerts
        self.log = log
        self.launchAtLogin = launchAtLogin
        self.showDockIcon = showDockIcon
        self.enableShowWindowHotKey = enableShowWindowHotKey
        self.enableToggleMenuHotKey = enableToggleMenuHotKey
        self.pinnedSensorIDs = pinnedSensorIDs
        self.showOtherSensors = showOtherSensors
        self.isFirstLaunch = isFirstLaunch
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updateIntervalSecs, tempUnit, menuBar, policy, turnOffFanControlForSleep
        case resumeOnLaunch, lastMode, alerts, log, launchAtLogin, showDockIcon, enableShowWindowHotKey
        case enableToggleMenuHotKey, pinnedSensorIDs, showOtherSensors, isFirstLaunch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(updateIntervalSecs: c.value(.updateIntervalSecs, default: 2),
                  tempUnit: c.value(.tempUnit, default: .celsius),
                  menuBar: c.value(.menuBar, default: MenuBarSettings()),
                  policy: c.value(.policy, default: Policy()),
                  turnOffFanControlForSleep: c.value(.turnOffFanControlForSleep, default: true),
                  resumeOnLaunch: c.value(.resumeOnLaunch, default: false),
                  lastMode: c.value(.lastMode, default: .auto),
                  alerts: c.value(.alerts, default: AlertSettings()),
                  log: c.value(.log, default: LogSettings()),
                  launchAtLogin: c.value(.launchAtLogin, default: false),
                  showDockIcon: c.value(.showDockIcon, default: false),
                  enableShowWindowHotKey: c.value(.enableShowWindowHotKey, default: true),
                  enableToggleMenuHotKey: c.value(.enableToggleMenuHotKey, default: true),
                  pinnedSensorIDs: c.value(.pinnedSensorIDs, default: []),
                  showOtherSensors: c.value(.showOtherSensors, default: false),
                  isFirstLaunch: c.value(.isFirstLaunch, default: true))
        // Always stamp the current version: the blob is rewritten in the current schema on next save.
        self.schemaVersion = Self.currentSchemaVersion
    }

    /// A copy with every value forced into its supported range.
    public func normalized(fanCount: Int? = nil) -> AppSettings {
        var copy = self
        copy.updateIntervalSecs = max(1, min(copy.updateIntervalSecs, 60))
        copy.menuBar = copy.menuBar.normalized()
        copy.policy = copy.policy.normalized(fanCount: fanCount)
        copy.alerts = copy.alerts.normalized()
        return copy
    }

    // MARK: Persistence

    /// Decodes a settings blob. Never fails: nil, empty, corrupt or foreign data yields the defaults,
    /// and individual bad values are replaced by their defaults.
    public static func decode(from data: Data?) -> AppSettings {
        guard let data, !data.isEmpty,
              let settings = try? PersistedJSON.makeDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings.normalized()
    }

    public func encoded() throws -> Data {
        try PersistedJSON.makeEncoder().encode(self)
    }
}
