import FanPilotControl
import FanPilotKit
import FanPilotSensors
import SwiftUI

/// The drop-down panel of the menu bar item: a fan block, a temperature
/// block and the common items, in the order the Menu Bar settings ask for.
struct MenuContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner(compact: true)
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if index > 0 { InsetDivider() }
                switch block {
                case .fans: MenuFansBlock()
                case .temperatures: MenuTemperaturesBlock()
                case .common: MenuCommonBlock()
                }
            }
            InsetDivider()
            MenuTailBlock()
        }
        .padding(.vertical, 6)
        .frame(width: Theme.panelWidth)
        .onAppear { model.monitor?.refreshNow() }
    }

    private enum Block { case fans, temperatures, common }

    /// The four placements of the fan block, temperature block and common items.
    private var blocks: [Block] {
        let bar = model.settings.menuBar
        let fans: [Block] = model.hasFans ? [.fans] : []
        switch (bar.fanControlsAtTop, bar.commonSectionAtTop) {
        case (true, false): return fans + [.temperatures, .common]
        case (true, true): return [.common] + fans + [.temperatures]
        case (false, true): return [.common, .temperatures] + fans
        case (false, false): return [.temperatures] + fans + [.common]
        }
    }
}

// MARK: - Building blocks

/// A short hairline inset from both sides, between blocks.
struct InsetDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 4)
    }
}

/// Header line of a block: symbol, title, optional trailing content.
struct BlockHeader<Trailing: View>: View {
    var symbol: String
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

/// A clickable row that highlights like a menu item.
struct MenuItemButton: View {
    var title: String
    var symbol: String?
    var shortcut: String?
    var key: KeyEquivalent?
    var enabled = true
    /// Subtle secondary text after the title (for example the author credit on About).
    var trailingNote: String?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).frame(width: 18).foregroundStyle(hovering && enabled ? Color.white : Color.secondary)
                } else {
                    Color.clear.frame(width: 18, height: 1)
                }
                Text(title)
                Spacer()
                if let trailingNote {
                    Text(trailingNote).font(.system(size: 11))
                        .foregroundStyle(hovering && enabled ? Color.white.opacity(0.8) : Color.secondary)
                }
                if let shortcut {
                    Text(shortcut).font(.system(size: 11)).foregroundStyle(hovering && enabled ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering && enabled ? Color.white : (enabled ? Color.primary : Color.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering && enabled ? Theme.rowHighlight : Color.clear))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .modifier(OptionalShortcut(key: key))
    }
}

private struct OptionalShortcut: ViewModifier {
    var key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}

// MARK: - Fans

struct MenuFansBlock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BlockHeader(symbol: "fan", title: "Fans") {
                HelperChip()
                LinkFansToggle()
            }
            FanModeControl()
                .padding(.horizontal, 14)
            if model.settings.lastMode != .auto, model.controlMode == .auto, model.canControlFans {
                MenuItemButton(title: "Resume \(Fmt.modeName(model.settings.lastMode, usePercent: model.usePercent))",
                               symbol: "arrow.clockwise") { model.resumeLastMode() }
            }
            ForEach(model.fanInfos) { info in
                MenuFanRow(info: info)
            }
            if model.fanInfos.count > 0, allFansStopped {
                Text(model.fanInfos.count > 1 ? "Fans turned off by the system" : "Fan turned off by the system")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
    }

    /// Every fan reads 0 RPM while the system is in charge: the Mac decided it is cool enough.
    private var allFansStopped: Bool {
        model.fansMayStop && model.controlMode == .auto
            && !model.snapshot.fans.isEmpty && model.snapshot.fans.allSatisfy { $0.actualRPM < 1 }
    }
}

// MARK: - Temperatures

struct MenuTemperaturesBlock: View {
    @EnvironmentObject var model: AppModel
    @State private var contentHeight: CGFloat = 0
    private let maxHeight: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            BlockHeader(symbol: "thermometer.medium", title: "Temperatures") {
                if model.hasSnapshot, let top = model.snapshot.aggregates.highest {
                    Text("Highest \(Fmt.temperature(top, unit: model.temperatureUnit))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !model.hasSnapshot {
                Text(model.sensorProblem ?? "Reading sensors\u{2026}")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pinned
                        let groups = model.snapshot.groups.filter { $0.area != .other }
                        if model.extras.listAllMenuSensors {
                            // Every sensor, with a short divider where the area changes.
                            ForEach(Array(groups.enumerated()), id: \.element.id) { position, group in
                                if position > 0 { Divider().padding(.horizontal, 14).padding(.vertical, 3) }
                                ForEach(group.readings) { reading in
                                    SensorMenuRow(reading: reading, indent: 12, pinned: false)
                                }
                            }
                        } else {
                            ForEach(groups) { group in
                                AreaSummaryRow(group: group)
                            }
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                    })
                }
                .scrollIndicators(.automatic)
                .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight)
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            }
        }
    }

    @ViewBuilder
    private var pinned: some View {
        let readings = model.settings.pinnedSensorIDs.compactMap { model.snapshot.reading(id: $0) }
        if !readings.isEmpty {
            ForEach(readings) { reading in
                SensorMenuRow(reading: reading, indent: 12, pinned: true)
            }
            Divider().padding(.horizontal, 14).padding(.vertical, 3)
        }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One area: its highest reading with a colored bar. Click to show the individual sensors.
struct AreaSummaryRow: View {
    @EnvironmentObject var model: AppModel
    let group: SensorGroup
    @State private var hovering = false

    private var expanded: Bool { model.extras.expandedMenuAreas.contains(group.area.rawValue) }

    var body: some View {
        let valid = group.readings.filter(\.valid)
        let hottest = valid.max { $0.value < $1.value }
        VStack(spacing: 0) {
            Button {
                var list = model.extras.expandedMenuAreas
                if expanded { list.removeAll { $0 == group.area.rawValue } } else { list.append(group.area.rawValue) }
                model.extras.expandedMenuAreas = list
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                    Text(group.area.displayName).font(.system(size: 13)).lineLimit(1)
                        .frame(width: 92, alignment: .leading)
                    LevelBar.temperature(hottest?.value, alerts: model.settings.alerts,
                                         sessionMax: nil, height: 6)
                    TemperatureText(celsius: hottest?.value, bold: true)
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(hottest.map { "Hottest: \($0.sensor.name)" } ?? "No valid readings")

            if expanded {
                ForEach(group.readings) { reading in
                    SensorMenuRow(reading: reading, indent: 28, pinned: false)
                }
            }
        }
    }
}

/// Name, small bar and value of one sensor.
struct SensorMenuRow: View {
    @EnvironmentObject var model: AppModel
    let reading: SensorReading
    var indent: CGFloat
    var pinned: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(reading.sensor.name).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(reading.valid ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            LevelBar.temperature(reading.valid ? reading.value : nil, alerts: model.settings.alerts,
                                 sessionMax: model.snapshot.sessionMax[reading.id], height: 5)
                .frame(width: 80)
            TemperatureText(celsius: reading.valid ? reading.value : nil, bold: false)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.leading, indent).padding(.trailing, 16).padding(.vertical, 1.5)
        .contextMenu {
            Button(model.settings.pinnedSensorIDs.contains(reading.id) ? "Unpin from Menu" : "Pin to Top of Menu") {
                var ids = model.settings.pinnedSensorIDs
                if let at = ids.firstIndex(of: reading.id) { ids.remove(at: at) } else { ids.append(reading.id) }
                model.settings.pinnedSensorIDs = ids
            }
            Button("Show in Menu Bar (Temperature 1)") { model.settings.menuBar.temp1 = MenuBarTempSlot(enabled: true, source: .sensor(reading.id)) }
            Button("Show in Menu Bar (Temperature 2)") { model.settings.menuBar.temp2 = MenuBarTempSlot(enabled: true, source: .sensor(reading.id)) }
        }
    }
}

/// A temperature in the user's unit, orange or red at the thresholds (if colors are on).
struct TemperatureText: View {
    @EnvironmentObject var model: AppModel
    var celsius: Double?
    var bold: Bool

    var body: some View {
        let zone = (celsius != nil && model.settings.menuBar.useColors)
            ? TemperatureZone(celsius: celsius!, alerts: model.settings.alerts) : .normal
        Text(Fmt.temperature(celsius, unit: model.temperatureUnit))
            .font(.system(size: 12, weight: bold ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(zone.textColor ?? (celsius == nil ? Color.secondary : Color.primary))
    }
}

// MARK: - Common block and tail

struct MenuCommonBlock: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuItemButton(title: "Show Main Window", symbol: "macwindow",
                           shortcut: AppModel.shared.settings.enableShowWindowHotKey ? HotKeyManager.showWindowDescription : nil) {
                WindowCoordinator.shared.showMainWindow()
            }
            MenuItemButton(title: "Settings\u{2026}", symbol: "gearshape", shortcut: "\u{2318},", key: ",") {
                WindowCoordinator.shared.showSettings()
            }
        }
    }
}

struct MenuTailBlock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.helper.availability != .connected, model.hasFans {
                MenuItemButton(title: helperActionTitle, symbol: "wrench.and.screwdriver") {
                    model.confirmAndInstallHelper()
                }
            }
            MenuItemButton(title: "About FanPilot", symbol: "info.circle", trailingNote: "by \(Credits.author)") {
                Credits.showAboutPanel()
            }
            MenuItemButton(title: "Quit FanPilot", symbol: "power", shortcut: "\u{2318}Q", key: "q") {
                NSApp.terminate(nil)
            }
        }
    }

    private var helperActionTitle: String {
        HelperInstaller.isInstalledOnDisk ? "Reinstall Fan Helper\u{2026}" : "Install Fan Helper\u{2026}"
    }
}

/// A small dot and word for the helper state in the Fans header.
struct HelperChip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .help(HelperDescription.summary(model))
    }

    private var label: String {
        if model.installInProgress { return "Installing" }
        if model.helper.failsafe.active { return model.helper.failsafe.isBlind ? "No temperatures" : "Failsafe" }
        switch model.helper.availability {
        case .connected: return model.helper.monitorOnly ? "Monitor only" : "Helper"
        case .connecting: return "Connecting"
        case .notInstalled: return "No helper"
        case .notRunning, .unauthorized, .incompatible: return "Helper offline"
        }
    }

    private var color: Color {
        if model.helper.failsafe.active { return model.helper.failsafe.isBlind ? .orange : .red }
        if model.helper.isConnected && !model.helper.monitorOnly { return Color(nsColor: .systemGreen) }
        return model.helper.availability == .connecting ? Color(nsColor: .systemGray) : Color(nsColor: .systemOrange)
    }
}

// MARK: - Banner

/// Explains why fan control is unavailable, or that the failsafe is active, with the way out.
struct StatusBanner: View {
    @EnvironmentObject var model: AppModel
    var compact: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let notice = model.notice {
                banner(symbol: notice.kind == .error ? "exclamationmark.octagon.fill" : (notice.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"),
                       tint: notice.kind == .error ? .red : (notice.kind == .warning ? .orange : .blue),
                       text: notice.text, action: ("Dismiss", { model.dismissNotice() }))
            }
            if model.helper.failsafe.active {
                if model.helper.failsafe.isBlind {
                    banner(symbol: "eye.slash.fill", tint: .orange,
                           text: "The helper cannot read temperatures, so the fans are back under system control.", action: nil)
                } else {
                    banner(symbol: "flame.fill", tint: .red,
                           text: "Failsafe: a sensor got too hot, so the helper holds the fans at maximum.", action: nil)
                }
            } else if let info = helperBanner {
                banner(symbol: info.symbol, tint: info.tint, text: info.text,
                       action: info.action.map { title in (title, { info.run() }) })
            }
            if let problem = model.sensorProblem, !model.hasSnapshot || model.snapshot.readings.isEmpty {
                banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: problem, action: nil)
            }
        }
        .padding(.horizontal, compact ? 8 : 0)
        .padding(.bottom, bannerVisible ? 6 : 0)
    }

    private var bannerVisible: Bool {
        model.notice != nil || model.helper.failsafe.active || helperBanner != nil || model.sensorProblem != nil
    }

    private struct HelperBannerInfo {
        var symbol: String
        var tint: Color
        var text: String
        var action: String?
        var run: () -> Void
    }

    private var helperBanner: HelperBannerInfo? {
        guard model.hasSnapshot else { return nil }
        if model.installInProgress {
            return HelperBannerInfo(symbol: "hourglass", tint: .blue, text: "Installing the fan helper\u{2026}", action: nil, run: {})
        }
        switch model.helper.availability {
        case .connected:
            if model.helper.monitorOnly {
                let why = model.helper.hello?.monitorReason ?? "no fan can be controlled safely"
                return HelperBannerInfo(symbol: "eye", tint: .orange, text: "Monitor only: \(why).", action: nil, run: {})
            }
            return nil
        case .connecting:
            return nil
        case .notInstalled:
            guard model.hasFans else { return nil }
            return HelperBannerInfo(symbol: "lock.shield", tint: .orange,
                                    text: "Monitor only. Install the fan helper to change fan speeds.",
                                    action: "Install\u{2026}", run: { model.confirmAndInstallHelper() })
        case .notRunning(let why):
            return HelperBannerInfo(symbol: "bolt.slash", tint: .orange,
                                    text: "Fan helper not running: monitor only. \(why)",
                                    action: "Reinstall\u{2026}", run: { model.confirmAndInstallHelper() })
        case .unauthorized(let why):
            return HelperBannerInfo(symbol: "person.crop.circle.badge.exclamationmark", tint: .orange,
                                    text: "The helper does not allow this user: \(why)",
                                    action: "Reinstall\u{2026}", run: { model.confirmAndInstallHelper() })
        case .incompatible(let why):
            return HelperBannerInfo(symbol: "exclamationmark.triangle", tint: .orange, text: why,
                                    action: "Reinstall\u{2026}", run: { model.confirmAndInstallHelper() })
        }
    }

    private func banner(symbol: String, tint: Color, text: String, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 13)).padding(.top, 1)
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}
