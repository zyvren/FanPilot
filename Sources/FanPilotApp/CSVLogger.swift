import FanPilotKit
import FanPilotSensors
import Foundation

/// Writes temperatures and fan speeds to a CSV file.
///
/// Default folder `~/Library/Logs/FanPilot`. Columns: `Date,Time`, one per sensor outside the
/// "Other" group, `CPU Average`, `Computer Average`, one per fan plus `Fan Average`, and optionally
/// the diagnostics. If the set of columns changes between sessions the old file is renamed and a new
/// one with the new header begins, so a CSV never mixes layouts. All file work happens on a private
/// queue; `log` is cheap to call from the main thread.
final class CSVLogger: @unchecked Sendable {
    struct Options: Equatable {
        var settings: LogSettings
        var intervalSeconds: Int
        var includeDiagnostics: Bool
        var folder: URL
        var unit: TemperatureUnit
    }

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FanPilot", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "com.fanpilot.csv-log", qos: .utility)
    private var options: Options?
    private var handle: FileHandle?
    private var currentPath: String?
    private var currentHeader: String?
    private var lastRow: Date?
    private var sessionStamp: String
    private var lastErrorText: String?

    init() {
        sessionStamp = Self.stamp(Date())
    }

    deinit { try? handle?.close() }

    /// The file the next row goes to (for "Open" and "Reveal in Finder").
    func currentFileURL(options: Options, now: Date = Date()) -> URL {
        options.folder.appendingPathComponent(fileName(options: options, now: now))
    }

    func configure(_ options: Options) {
        queue.async { [self] in
            let wasEnabled = self.options?.settings.logToFile ?? false
            if self.options?.folder != options.folder || !options.settings.logToFile {
                closeFile()
            }
            if !wasEnabled && options.settings.logToFile {
                // Turning logging on counts as a start: "new file on startup" begins a fresh file.
                sessionStamp = Self.stamp(Date())
                closeFile()
            }
            self.options = options
        }
    }

    /// Appends one sample if logging is on and the interval has elapsed.
    func log(snapshot: SensorSnapshot, diagnostics: DiagnosticsReport?, now: Date = Date()) {
        queue.async { [self] in
            guard let options, options.settings.logToFile else { return }
            if let last = lastRow, now.timeIntervalSince(last) < Double(options.intervalSeconds) - 0.25 { return }
            lastRow = now
            write(snapshot: snapshot, diagnostics: diagnostics, options: options, now: now)
        }
    }

    /// Appends an alert row (the value column of the alert is marked with an `ALERT` prefix).
    func logAlert(_ text: String, now: Date = Date()) {
        queue.async { [self] in
            guard let options, options.settings.logToFile, options.settings.logAlerts, let header = currentHeader else { return }
            let columns = header.split(separator: ",", omittingEmptySubsequences: false).count
            var fields = [Self.dateString(now, iso: options.settings.useISO8601Dates), Self.timeString(now), "ALERT: \(text)"]
            while fields.count < columns { fields.append("") }
            append(line: fields.map(Self.csvEscape).joined(separator: ","), options: options, now: now)
        }
    }

    // MARK: Queue-confined

    private func write(snapshot: SensorSnapshot, diagnostics: DiagnosticsReport?, options: Options, now: Date) {
        var names: [String] = []
        var values: [String] = []
        let unit = options.unit

        if options.settings.logTemperatures {
            for reading in snapshot.readings where reading.sensor.area != .other {
                names.append("\(reading.sensor.name) (\(unit.symbol))")
                values.append(reading.valid ? String(format: "%.1f", unit.convert(fromCelsius: reading.value)) : "")
            }
            names.append("CPU Average (\(unit.symbol))")
            values.append(snapshot.aggregates.averageCPU.map { String(format: "%.1f", unit.convert(fromCelsius: $0)) } ?? "")
            names.append("Computer Average (\(unit.symbol))")
            values.append(snapshot.aggregates.computerAverage.map { String(format: "%.1f", unit.convert(fromCelsius: $0)) } ?? "")
        }
        if options.settings.logFanSpeeds {
            for reading in snapshot.fans {
                let name = snapshot.fanInfos.first { $0.index == reading.index }?.name ?? "Fan \(reading.index + 1)"
                names.append("\(name) (RPM)")
                values.append(String(format: "%.0f", reading.actualRPM))
            }
            names.append("Fan Average (RPM)")
            values.append(snapshot.averageFanRPM.map { String(format: "%.0f", $0) } ?? "")
        }
        if options.includeDiagnostics {
            // The columns are always present so the header does not change when the first diagnostics
            // arrive a few seconds after the first row.
            names += ["Fan Diagnostics", "Sensor Diagnostics", "Battery Health"]
            values += [diagnostics?.fans.message ?? "", diagnostics?.sensors.message ?? "", diagnostics?.battery.message ?? ""]
        }
        guard !names.isEmpty else { return }

        let header = (["Date", "Time"] + names).map(Self.csvEscape).joined(separator: ",")
        let row = ([Self.dateString(now, iso: options.settings.useISO8601Dates), Self.timeString(now)] + values)
            .map(Self.csvEscape).joined(separator: ",")

        if currentHeader != header { closeFile() }
        currentHeader = header
        append(line: row, options: options, now: now)
    }

    private func append(line: String, options: Options, now: Date) {
        do {
            let path = options.folder.appendingPathComponent(fileName(options: options, now: now)).path
            if handle == nil || currentPath != path {
                try openFile(path: path, folder: options.folder, header: currentHeader)
            }
            try handle?.write(contentsOf: Data((line + "\n").utf8))
            lastErrorText = nil
        } catch {
            // Never crash or spam: remember the problem, drop the handle, try again next row.
            lastErrorText = "\(error)"
            closeFile()
        }
    }

    private func openFile(path: String, folder: URL, header: String?) throws {
        closeFile()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: path), let header {
            let first = try firstLine(of: path)
            if first != header {
                // The columns changed since this file was written: keep it, start a new one.
                let stamp = Self.stamp(Date())
                let renamed = (path as NSString).deletingPathExtension + " (\(stamp)).csv"
                try fm.moveItem(atPath: path, toPath: renamed)
            }
        }
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: Data(((header ?? "") + "\n").utf8)) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try file.seekToEnd()
        handle = file
        currentPath = path
    }

    private func firstLine(of path: String) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let data = try file.read(upToCount: 64 * 1024) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        currentPath = nil
    }

    private func fileName(options: Options, now: Date) -> String {
        switch options.settings.newFileMode {
        case .never: return "FanPilot Log.csv"
        case .onStartup: return "FanPilot Log \(sessionStamp).csv"
        case .daily: return "FanPilot Log \(Self.dateString(now, iso: options.settings.useISO8601Dates, fileSafe: true)).csv"
        }
    }

    // MARK: Formatting

    static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func dateString(_ date: Date, iso: Bool, fileSafe: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = iso ? "yyyy-MM-dd" : (fileSafe ? "MM-dd-yyyy" : "MM/dd/yyyy")
        return f.string(from: date)
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }
}
