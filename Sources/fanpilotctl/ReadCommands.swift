import FanPilotHelperCore
import FanPilotKit
import FanPilotSensors
import Foundation

/// Commands that only read; they work without privileges and without the helper.
enum ReadCommands {
    // MARK: list

    static func list(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let json = CLISupport.takeFlag("--json", from: &args)
        guard args.isEmpty else { throw CLISupport.UsageError("list takes no arguments") }

        let smc = try openReadOnly()
        let topology = FanTopology.discover(smc: smc)
        let names = FanNaming.names(count: topology.fans.count, model: HardwareInfo.current().model)

        var rows: [[String: Any]] = []
        for (position, fan) in topology.fans.enumerated() {
            let reading = try? FanKeyReader.reading(smc: smc, fan: fan)
            rows.append([
                "index": fan.index,
                "name": names.indices.contains(position) ? names[position] : fan.name,
                "backend": fan.backend.kind,
                "modeKey": fan.modeKey ?? NSNull(),
                "minRPM": fan.minRPM,
                "maxRPM": fan.maxRPM,
                "actualRPM": reading?.actualRPM ?? NSNull(),
                "targetRPM": reading?.targetRPM ?? NSNull(),
                "mode": reading?.mode ?? NSNull(),
                "controllable": fan.backend.canControl,
                "reason": topology.unusableReasons[fan.index] ?? NSNull(),
            ])
        }

        if json {
            printJSON(["fans": rows, "monitorOnly": topology.isMonitorOnly,
                       "hasFtst": topology.hasFtst, "hasDICT": topology.hasDICT])
            return ExitCode.ok
        }

        if topology.fans.isEmpty {
            print("No fans reported by this Mac (\(topology.monitorReason ?? "FNum = 0")).")
            return ExitCode.ok
        }
        let widths = [3, 12, 16, 5, 5, 6, 6, 7]
        print(CLISupport.row(["#", "Name", "Backend", "Min", "Max", "Now", "Target", "Mode"], widths: widths))
        for row in rows {
            print(CLISupport.row([
                "\(row["index"] ?? "")",
                "\(row["name"] ?? "")",
                (row["controllable"] as? Bool == true) ? "\(row["backend"] ?? "") \(row["modeKey"] as? String ?? "")" : "monitor only",
                CLISupport.rpmText(row["minRPM"] as? Double ?? 0),
                CLISupport.rpmText(row["maxRPM"] as? Double ?? 0),
                (row["actualRPM"] as? Double).map(CLISupport.rpmText) ?? "?",
                (row["targetRPM"] as? Double).map(CLISupport.rpmText) ?? "?",
                (row["mode"] as? Int).map(CLISupport.modeText) ?? "?",
            ], widths: widths))
        }
        if let reason = topology.monitorReason {
            print("\nFan control is not possible on this Mac: \(reason)")
        }
        if topology.hasFtst { print("\nNote: Ftst (legacy unlock) is present.") }
        return ExitCode.ok
    }

    // MARK: sensors

    static func sensors(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let json = CLISupport.takeFlag("--json", from: &args)
        let all = CLISupport.takeFlag("--all", from: &args)
        guard args.isEmpty else { throw CLISupport.UsageError("sensors takes only --all and --json") }

        let smc = try openReadOnly()
        let engine = SensorEngine(smc: smc)
        let snapshot = engine.refresh()
        let failsafe = failsafeReading(smc)
        if let problem = engine.lastErrorDescription, snapshot.readings.isEmpty {
            throw CLIError(message: "no sensors could be read: \(problem)")
        }
        let readings = snapshot.readings.filter { all || $0.sensor.area != .other }

        if json {
            printJSON([
                "model": engine.hardware.model,
                "catalog": snapshot.catalogModel ?? NSNull(),
                "aggregates": aggregatesJSON(snapshot.aggregates, failsafe: failsafe),
                "sensors": readings.map { reading -> [String: Any] in
                    ["id": reading.sensor.id, "key": reading.sensor.key, "name": reading.sensor.name,
                     "area": reading.sensor.area.rawValue, "source": reading.sensor.source.rawValue,
                     "celsius": reading.valid ? reading.value : NSNull(), "valid": reading.valid]
                },
            ])
            return ExitCode.ok
        }

        print("Model \(engine.hardware.model)" + (snapshot.catalogModel == nil ? " (heuristic classification)" : ""))
        print("Highest \(CLISupport.tempText(snapshot.aggregates.highest))   Average \(CLISupport.tempText(snapshot.aggregates.computerAverage))   CPU highest \(CLISupport.tempText(snapshot.aggregates.highestCPU))   CPU average \(CLISupport.tempText(snapshot.aggregates.averageCPU))")
        print("Failsafe hot set (what the helper watches): \(CLISupport.tempText(failsafe.maxTempC)), hottest \(failsafe.hottest ?? "-")\n")
        let widths = [22, 6, 5]
        for group in snapshot.groups where all || group.area != .other {
            print(group.area.displayName)
            for reading in group.readings {
                let value = reading.valid ? CLISupport.tempText(reading.value) : "N/A"
                print("  " + CLISupport.row([reading.sensor.name, reading.sensor.key, reading.sensor.source.rawValue.uppercased(), value],
                                            widths: widths))
            }
        }
        return ExitCode.ok
    }

    private static func aggregatesJSON(_ a: SensorAggregates, failsafe: HotSetReading) -> [String: Any] {
        func v(_ x: Double?) -> Any { x ?? NSNull() }
        return ["computerAverage": v(a.computerAverage), "highest": v(a.highest), "averageCPU": v(a.averageCPU),
                "highestCPU": v(a.highestCPU), "failsafeHotSet": v(failsafe.maxTempC)]
    }

    /// The temperature the helper's failsafe would see right now: the same two providers it uses.
    static func failsafeReading(_ smc: SMCClient) -> HotSetReading {
        let provider = failsafeProvider(smc)
        provider.refresh()
        return provider.read()
    }

    static func failsafeProvider(_ smc: SMCClient) -> HotSetProvider {
        CompositeHotSetProvider([SensorsHotSetProvider(smc: smc), SMCHotSetReader(smc: smc, includeHID: false)])
    }

    // MARK: watch

    static func watch(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let interval = try CLISupport.takeOption("--interval", from: &args).map { text -> TimeInterval in
            guard let seconds = Double(text), seconds.isFinite, (0.2...60).contains(seconds) else {
                throw CLISupport.UsageError("--interval must be between 0.2 and 60 seconds")
            }
            return seconds
        } ?? 1
        let limit = try CLISupport.takeOption("--count", from: &args).map { text -> Int in
            guard let n = Int(text), n > 0 else { throw CLISupport.UsageError("--count must be a positive number") }
            return n
        }
        guard args.isEmpty else { throw CLISupport.UsageError("watch takes only --interval and --count") }

        let smc = try openReadOnly()
        let engine = SensorEngine(smc: smc)
        let failsafe = failsafeProvider(smc)
        failsafe.refresh()
        let interrupt = InterruptFlag()
        let isTTY = isatty(STDOUT_FILENO) != 0
        var printed = 0
        while !interrupt.isRaised {
            let snapshot = engine.refresh()
            if isTTY && limit == nil { print("\u{1B}[H\u{1B}[2J", terminator: "") }
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            print("\(stamp)   Highest \(CLISupport.tempText(snapshot.aggregates.highest))   CPU \(CLISupport.tempText(snapshot.aggregates.highestCPU)) (avg \(CLISupport.tempText(snapshot.aggregates.averageCPU)))   failsafe hot set \(CLISupport.tempText(failsafe.read().maxTempC))")
            let names = FanNaming.names(count: snapshot.fanInfos.count, model: engine.hardware.model)
            for fan in snapshot.fans {
                let name = names.indices.contains(fan.index) ? names[fan.index] : "Fan \(fan.index + 1)"
                print(String(format: "  %-12@ %5.0f RPM  target %5.0f  %@  [%.0f-%.0f]",
                             name as NSString, fan.actualRPM, fan.targetRPM, CLISupport.modeText(fan.mode) as NSString,
                             fan.minRPM, fan.maxRPM))
            }
            if snapshot.fans.isEmpty { print("  (no fan readings)") }
            fflush(stdout)
            printed += 1
            if let limit, printed >= limit { break }
            Thread.sleep(forTimeInterval: interval)
        }
        return ExitCode.ok
    }

    // MARK: smc-read

    static func smcRead(_ arguments: [String]) throws -> Int32 {
        guard !arguments.isEmpty else { throw CLISupport.UsageError("smc-read needs at least one KEY") }
        let smc = try openReadOnly()
        var failed = false
        for text in arguments {
            guard let key = FourCC(text) else {
                CLI.fail("'\(text)' is not a four character SMC key")
                failed = true
                continue
            }
            do {
                print(CLISupport.describe(try smc.read(key)))
            } catch {
                CLI.fail("\(error)")
                failed = true
            }
        }
        return failed ? ExitCode.failure : ExitCode.ok
    }

    // MARK: Shared

    /// A read-only SMC connection: the C layer cannot send a write through it.
    static func openReadOnly() throws -> IOKitSMC {
        do {
            return try IOKitSMC(access: .readOnly)
        } catch {
            throw CLIError(message: "cannot open the SMC: \(error)")
        }
    }
}
