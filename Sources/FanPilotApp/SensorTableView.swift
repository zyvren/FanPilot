import AppKit
import FanPilotKit
import FanPilotSensors
import SwiftUI

/// The sensor table of the main window: Sensor Name, Temp, Level, plus optional
/// detail columns, a search field, the "Other" switch and a CSV export (SPEC 6).
struct SensorTable: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var showDetails = false

    private var rows: [(area: SensorArea, readings: [SensorReading])] {
        let selected = model.effectiveArea
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.visibleGroups.compactMap { group in
            guard selected == "all" || selected == group.area.rawValue else { return nil }
            let readings = query.isEmpty ? group.readings
                : group.readings.filter { $0.sensor.name.lowercased().contains(query) || $0.sensor.key.lowercased().contains(query) }
            return readings.isEmpty ? nil : (group.area, readings)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.hasSnapshot {
                Spacer()
                Text(model.sensorProblem ?? "Reading sensors\u{2026}").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        let showHeaders = model.effectiveArea == "all"
                        ForEach(rows, id: \.area) { group in
                            if showHeaders {
                                Text(group.area.displayName.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                            }
                            ForEach(group.readings) { reading in
                                SensorTableRow(reading: reading, showDetails: showDetails)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sensor Name").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            if showDetails {
                Text("Key").frame(width: 80, alignment: .leading)
                Text("Source").frame(width: 46, alignment: .leading)
                Text("Max").frame(width: 56, alignment: .trailing)
            }
            Text("Temp").frame(width: 56, alignment: .trailing)
            Text("Level").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 22)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Filter sensors", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12)).frame(maxWidth: 160)
            Spacer()
            Toggle("Show all sensors", isOn: Binding(
                get: { model.settings.showOtherSensors },
                set: {
                    model.settings.showOtherSensors = $0
                    if $0 { model.refreshFully() }
                    else if model.extras.activeArea == SensorArea.other.rawValue { model.extras.activeArea = "all" }
                }))
                .toggleStyle(.checkbox).controlSize(.small)
                .help("Also list the many extra readings that are not part of the curated sensor list")
            Toggle("Details", isOn: $showDetails).toggleStyle(.checkbox).controlSize(.small)
            Button { copyCSV() } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Copy the listed sensors as CSV")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func copyCSV() {
        var lines = ["Area,Sensor,Key,Source,Temperature (\(model.temperatureUnit.symbol)),Session Max"]
        for group in rows {
            for r in group.readings {
                let value = r.valid ? String(format: "%.1f", model.temperatureUnit.convert(fromCelsius: r.value)) : ""
                let max = model.snapshot.sessionMax[r.id].map { String(format: "%.1f", model.temperatureUnit.convert(fromCelsius: $0)) } ?? ""
                lines.append([group.area.displayName, r.sensor.name, r.sensor.key, r.sensor.source.rawValue, value, max]
                    .map(CSVLogger.csvEscape).joined(separator: ","))
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }
}

private struct SensorTableRow: View {
    @EnvironmentObject var model: AppModel
    let reading: SensorReading
    let showDetails: Bool

    var body: some View {
        let max = model.snapshot.sessionMax[reading.id]
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if model.settings.pinnedSensorIDs.contains(reading.id) {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(reading.sensor.name).lineLimit(1)
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(reading.valid ? .primary : .secondary)
            if showDetails {
                Text(reading.sensor.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(reading.sensor.source.rawValue.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
                Text(Fmt.temperature(max, unit: model.temperatureUnit)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            Text(Fmt.temperature(reading.valid ? reading.value : nil, unit: model.temperatureUnit))
                .monospacedDigit().frame(width: 56, alignment: .trailing)
                .foregroundStyle(reading.valid ? .primary : .secondary)
            LevelBar.temperature(reading.valid ? reading.value : nil, alerts: model.settings.alerts, sessionMax: max)
                .frame(minWidth: 120, maxWidth: .infinity)
                .help(max.map { "Maximum Recorded Temperature: \(Fmt.temperature($0, unit: model.temperatureUnit))" } ?? "")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .contextMenu {
            let pinned = model.settings.pinnedSensorIDs.contains(reading.id)
            Button(pinned ? "Unpin from Menu" : "Pin to Top of Menu") {
                var ids = model.settings.pinnedSensorIDs
                if let at = ids.firstIndex(of: reading.id) { ids.remove(at: at) } else { ids.append(reading.id) }
                model.settings.pinnedSensorIDs = ids
            }
            Button("Show in Menu Bar (Temperature 1)") { model.settings.menuBar.temp1 = MenuBarTempSlot(enabled: true, source: .sensor(reading.id)) }
            Button("Show in Menu Bar (Temperature 2)") { model.settings.menuBar.temp2 = MenuBarTempSlot(enabled: true, source: .sensor(reading.id)) }
            Divider()
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Fmt.temperature(reading.valid ? reading.value : nil, unit: model.temperatureUnit),
                                               forType: .string)
            }
        }
    }
}
