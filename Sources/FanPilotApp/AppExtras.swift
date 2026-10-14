import Foundation

/// App-only preferences that `FanPilotKit.AppSettings` has no field for. Stored as a second JSON blob
/// under its own UserDefaults key so the shared settings schema stays untouched. Decoding never
/// fails: a missing or corrupt blob yields the defaults, and each field falls back individually.
struct AppExtras: Codable, Equatable {
    static let defaultsKey = "fanpilot.extras.v1"

    /// Seconds between CSV rows (the log pane's "Log interval").
    var logIntervalSecs: Int = 10
    /// Include the diagnostics columns in the CSV.
    var logDiagnostics: Bool = true
    /// Custom log folder; nil means `~/Library/Logs/FanPilot`.
    var logFolderPath: String?
    /// Area selected in the main window sidebar: a `SensorArea` raw value, or `all`.
    var activeArea: String = "all"
    /// Areas expanded in the menu panel (`SensorArea` raw values).
    var expandedMenuAreas: [String] = []
    /// The user ticked "Do not show again" on the helper-install explanation.
    var skipHelperPrompt: Bool = false
    /// Last Settings pane (`SettingsPane` raw value).
    var settingsPane: String = "general"
    /// List every sensor in the status menu with a divider between areas.
    /// Off: one collapsed summary row per area, expanded on click.
    var listAllMenuSensors: Bool = true
    /// Rules shown on this tab of the Auto Boost editor.
    var rulesTabIsBattery: Bool = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case logIntervalSecs, logDiagnostics, logFolderPath, activeArea, expandedMenuAreas
        case skipHelperPrompt, settingsPane, rulesTabIsBattery, listAllMenuSensors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppExtras()
        logIntervalSecs = (try? c.decodeIfPresent(Int.self, forKey: .logIntervalSecs)) ?? d.logIntervalSecs
        logDiagnostics = (try? c.decodeIfPresent(Bool.self, forKey: .logDiagnostics)) ?? d.logDiagnostics
        logFolderPath = try? c.decodeIfPresent(String.self, forKey: .logFolderPath)
        activeArea = (try? c.decodeIfPresent(String.self, forKey: .activeArea)) ?? d.activeArea
        expandedMenuAreas = (try? c.decodeIfPresent([String].self, forKey: .expandedMenuAreas)) ?? d.expandedMenuAreas
        skipHelperPrompt = (try? c.decodeIfPresent(Bool.self, forKey: .skipHelperPrompt)) ?? d.skipHelperPrompt
        settingsPane = (try? c.decodeIfPresent(String.self, forKey: .settingsPane)) ?? d.settingsPane
        rulesTabIsBattery = (try? c.decodeIfPresent(Bool.self, forKey: .rulesTabIsBattery)) ?? d.rulesTabIsBattery
        listAllMenuSensors = (try? c.decodeIfPresent(Bool.self, forKey: .listAllMenuSensors)) ?? d.listAllMenuSensors
        logIntervalSecs = max(1, min(logIntervalSecs, 3600))
    }

    static func load(from defaults: UserDefaults = .standard) -> AppExtras {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppExtras.self, from: data) else { return AppExtras() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
