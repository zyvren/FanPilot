import AppKit
import FanPilotControl
import FanPilotKit
import FanPilotSensors
import SwiftUI

enum MainPage: String, CaseIterable, Identifiable {
    case overview, boost, curve

    var id: String { rawValue }

    func title(usePercent: Bool) -> String {
        switch self {
        case .overview: return "Overview"
        case .boost: return usePercent ? "Auto Boost" : "Auto Max"
        case .curve: return "Curve"
        }
    }
}

@MainActor
final class MainNavigation: ObservableObject {
    @Published var page: MainPage = .overview
}

/// The main window: temperatures, fans and diagnostics in one column, with
/// the rule and curve editors on two extra pages.
struct MainWindowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: MainNavigation

    var body: some View {
        VStack(spacing: 0) {
            // The title bar is transparent; keep the content clear of the window buttons.
            HStack {
                Spacer()
                Picker("Page", selection: $nav.page) {
                    ForEach(MainPage.allCases) { page in
                        Text(page.title(usePercent: model.usePercent)).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(height: 44)

            StatusBanner(compact: false).padding(.horizontal, 16)

            Group {
                switch nav.page {
                case .overview: OverviewPage()
                case .boost: BoostPage()
                case .curve: CurvePage()
                }
            }
        }
        .frame(minWidth: 600, minHeight: AppWindowMetrics.minContentHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TemperaturesSection()
                .frame(maxHeight: .infinity)
            if model.hasFans {
                Divider()
                FansSection()
            }
            Divider()
            DiagnosticsSection()
        }
    }
}

struct TemperaturesSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                SectionHeader(symbol: "thermometer.medium", title: "Temperatures")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Average Computer:").foregroundStyle(.secondary)
                        Text(Fmt.temperature(model.snapshot.aggregates.computerAverage, unit: model.temperatureUnit)).monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Text("CPU:").foregroundStyle(.secondary)
                        Text(Fmt.temperature(model.snapshot.aggregates.averageCPU, unit: model.temperatureUnit)).monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                Menu {
                    Button("Temperature Settings\u{2026}") { WindowCoordinator.shared.showSettings(pane: .general) }
                    Divider()
                    Button("Reset Max Temperatures") { model.resetMaxTemperatures() }
                } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("Temperature options")
            }
            .padding(.horizontal, 16)
            .frame(height: 42)

            Divider()
            HStack(spacing: 0) {
                AreaSidebar().frame(width: 165)
                Divider()
                SensorTable()
            }
            .frame(minHeight: AppWindowMetrics.minSensorAreaHeight)
        }
    }
}

private struct AreaSidebar: View {
    @EnvironmentObject var model: AppModel

    private struct Entry: Identifiable { var id: String; var title: String; var symbol: String; var count: Int }

    private var entries: [Entry] {
        var list = [Entry(id: "all", title: "All", symbol: "square.grid.2x2",
                          count: model.visibleGroups.reduce(0) { $0 + $1.readings.count })]
        for group in model.visibleGroups {
            list.append(Entry(id: group.area.rawValue, title: group.area.displayName,
                              symbol: group.area.symbolName, count: group.readings.count))
        }
        return list
    }

    var body: some View {
        let selection = Binding<String?>(
            get: { model.effectiveArea },
            set: { if let id = $0 { model.extras.activeArea = id } })
        List(selection: selection) {
            ForEach(entries) { entry in
                Label(entry.title, systemImage: entry.symbol)
                    .font(.system(size: 13))
                    .tag(Optional(entry.id))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Fans

struct FansSection: View {
    @EnvironmentObject var model: AppModel
    @State private var showOverrideInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectionHeader(symbol: "fan", title: "Fans")
                if model.isOverriding {
                    Button { showOverrideInfo.toggle() } label: {
                        Text("\u{25C6}").foregroundStyle(Color(nsColor: .systemRed))
                    }
                    .buttonStyle(.plain)
                    .help("FanPilot is controlling the fans")
                    .popover(isPresented: $showOverrideInfo, arrowEdge: .bottom) { OverrideInfoView() }
                }
                if let text = hardwareStatusText {
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.controlMode == .manual {
                    Picker("Unit", selection: Binding(get: { model.manualUnit }, set: { model.setManualUnit($0) })) {
                        Text("RPM").tag(ManualUnit.rpm)
                        Text("%").tag(ManualUnit.percent)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 80)
                    .help("Show manual targets in RPM or percent")
                }
                FanModeControl(controlSize: .regular).frame(maxWidth: 330)
                LinkFansToggle()
                Button { WindowCoordinator.shared.showSettings(pane: .fan) } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Fan settings")
            }
            .padding(.horizontal, 16)
            .frame(height: 39)

            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 8)], alignment: .leading, spacing: 4) {
                    ForEach(model.fanInfos) { MainFanCard(info: $0) }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: model.fanCount > 2 ? 150 : 96)
        }
    }

    private var hardwareStatusText: String? {
        guard model.fansMayStop, model.controlMode == .auto, !model.snapshot.fans.isEmpty,
              model.snapshot.fans.allSatisfy({ $0.actualRPM < 1 }) else { return nil }
        return model.fanCount > 1 ? "Fans are off: the system keeps them stopped while the Mac is cool"
                                  : "Fan is off: the system keeps it stopped while the Mac is cool"
    }
}

private struct OverrideInfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FanPilot is in charge of the fans").font(.headline)
            Text("While a mode other than System is active:")
            VStack(alignment: .leading, spacing: 4) {
                Text("\u{2022} FanPilot sets the fan speeds. macOS will not raise them when the Mac heats up.")
                Text("\u{2022} A safety limit in the helper still forces full speed if a sensor gets too hot.")
                Text("\u{2022} Choose System to give the fans back to macOS at any time.")
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - Diagnostics

struct DiagnosticsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(symbol: "waveform.path.ecg", title: "Diagnostics")
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 38)

            VStack(spacing: 5) {
                if model.hasFans {
                    DiagnosticRow(label: "Fans", status: model.diagnostics?.fans.status.light ?? .notApplicable,
                                  text: model.diagnostics?.fans.message ?? "Checking\u{2026}")
                }
                DiagnosticRow(label: "Temperature Sensors", status: model.diagnostics?.sensors.status.light ?? .notApplicable,
                              text: model.diagnostics?.sensors.message ?? "Checking\u{2026}")
                DiagnosticRow(label: "Battery Health", status: model.diagnostics?.battery.status.light ?? .notApplicable,
                              text: model.diagnostics?.battery.message ?? "Checking\u{2026}")
                if model.hasFans {
                    DiagnosticRow(label: "Fan Helper", status: helperLight, text: helperText) {
                        if !model.helper.isConnected, !model.installInProgress {
                            Button(HelperInstaller.isInstalledOnDisk ? "Reinstall\u{2026}" : "Install\u{2026}") {
                                model.confirmAndInstallHelper()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var helperLight: LightStatus {
        if model.helper.failsafe.active { return .problem }
        return model.helper.isConnected && !model.helper.monitorOnly ? .good : .problem
    }

    private var helperText: String { HelperDescription.summary(model) }
}

/// One-line explanations of the helper state, shared by diagnostics, the menu and the Helper pane.
enum HelperDescription {
    @MainActor
    static func summary(_ model: AppModel) -> String {
        if model.installInProgress { return "Installing\u{2026}" }
        if model.helper.failsafe.active, model.helper.failsafe.isBlind {
            return "The helper cannot read any temperature and returned the fans to system control."
        }
        if model.helper.failsafe.active {
            let temp = model.helper.failsafe.tempC.map { " at \(model.settings.tempUnit.format(celsius: $0))" } ?? ""
            return "Failsafe active\(temp): fans held at maximum."
        }
        switch model.helper.availability {
        case .connected:
            if model.helper.monitorOnly {
                return "Connected, but no fan can be controlled: \(model.helper.hello?.monitorReason ?? "unsupported hardware")."
            }
            let limit = model.helper.hello.map { " Failsafe at \(model.settings.tempUnit.format(celsius: $0.failsafeTempC))." } ?? ""
            return "Running (version \(model.helper.hello?.version ?? "?")).\(limit)"
        case .connecting: return "Connecting\u{2026}"
        case .notInstalled: return "Not installed. FanPilot is monitor only."
        case .notRunning(let why): return "Not running. \(why)"
        case .unauthorized(let why): return "Refused this user. \(why)"
        case .incompatible(let why): return why
        }
    }
}

private struct DiagnosticRow<Trailing: View>: View {
    var label: String
    var status: LightStatus
    var text: String
    @ViewBuilder var trailing: Trailing

    init(label: String, status: LightStatus, text: String, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.status = status
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusLight(status: status)
            Text(label).font(.system(size: 11, weight: .bold))
                .frame(width: 140, alignment: .trailing)
            Text(text).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                .help(text)
            Spacer(minLength: 4)
            trailing
        }
    }
}

extension DiagnosticRow where Trailing == EmptyView {
    init(label: String, status: LightStatus, text: String) {
        self.init(label: label, status: status, text: text) { EmptyView() }
    }
}
