import FanPilotHelperCore
import FanPilotKit
import Foundation

/// Commands that talk to the root helper over its socket.
enum DaemonCommands {
    /// Removes `--socket PATH` (for development daemons) and returns the path to use.
    private static func socketPath(_ args: inout [String]) throws -> String {
        try CLISupport.takeOption("--socket", from: &args) ?? Constants.socketPath
    }

    // MARK: status

    static func status(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let path = try socketPath(&args)
        let json = CLISupport.takeFlag("--json", from: &args)
        guard args.isEmpty else { throw CLISupport.UsageError("status takes only --json and --socket") }

        let client = try DaemonClient(path: path)
        defer { client.close() }
        let reply = try client.exchange(.status)
        if json {
            if let line = try? WireCodec.encode(reply), let text = String(data: line, encoding: .utf8) { print(text) }
            return reply.ok ? ExitCode.ok : ExitCode.failure
        }
        guard reply.ok, case .status(let status) = reply.body else {
            throw CLIError(message: "\(reply.err?.rawValue ?? "error"): \(reply.msg ?? "status failed")")
        }

        let hello = client.hello
        print("FanPilot helper \(hello?.version ?? "?") (protocol \(hello?.proto ?? 0))"
              + (hello?.monitorOnly == true ? "  MONITOR ONLY: \(hello?.monitorReason ?? "")" : ""))
        let widths = [3, 12, 5, 5, 6, 6, 7, 6, 6]
        print(CLISupport.row(["#", "Name", "Min", "Max", "Now", "Target", "Mode", "Held", "Lease"], widths: widths))
        for fan in status.fans {
            let name = hello?.fans.first { $0.index == fan.index }?.name ?? "Fan \(fan.index + 1)"
            print(CLISupport.row([
                "\(fan.index)", name, CLISupport.rpmText(fan.minRPM), CLISupport.rpmText(fan.maxRPM),
                CLISupport.rpmText(fan.actualRPM), CLISupport.rpmText(fan.targetRPM), CLISupport.modeText(fan.mode),
                fan.owned ? "yes" : "no", fan.owned ? String(format: "%.0f s", fan.leaseRemainS) : "-",
            ], widths: widths))
        }
        if status.failsafe.active {
            print("\nTHERMAL FAILSAFE ACTIVE (\(status.failsafe.reason ?? "?"), \(CLISupport.tempText(status.failsafe.tempC))): fans are forced to maximum")
        } else {
            print("\nFailsafe: inactive (trips at \(Int(hello?.failsafeTempC ?? 0)) C)")
        }
        if let dict = status.dict { print("DICT flag: \(dict) \(dict == 1 ? "(the OS is ducking the fans; the helper backs off)" : "")") }
        if let lastError = status.lastError { print("Last problem: \(lastError)") }
        return ExitCode.ok
    }

    // MARK: daemon-ping

    static func ping(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let path = try socketPath(&args)
        guard args.isEmpty else { throw CLISupport.UsageError("daemon-ping takes only --socket") }
        let started = ProcessInfo.processInfo.systemUptime
        let client = try DaemonClient(path: path, clientName: "fanpilotctl ping")
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        defer { client.close() }
        guard let hello = client.hello else { throw CLIError(message: "no hello reply") }
        print(String(format: "fanpilotd %@ answered in %.1f ms (protocol %d, %d fan(s), failsafe %.0f C, lease max %.0f s)%@",
                     hello.version as NSString, elapsed, hello.proto, hello.fans.count, hello.failsafeTempC, hello.leaseMaxS,
                     (hello.monitorOnly ? " MONITOR ONLY" : "") as NSString))
        return ExitCode.ok
    }

    // MARK: set / max

    static func set(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let path = try socketPath(&args)
        let hold = try CLISupport.takeOption("--hold", from: &args).map(CLISupport.parseHold)
        guard args.count == 2 else { throw CLISupport.UsageError("usage: set <fan|all> <RPM|NN%> [--hold SECONDS]") }
        let selector = try CLISupport.parseFanSelector(args[0])
        let speed = try CLISupport.SpeedSpec.parse(args[1])
        return try holdFans(selector: selector, speed: speed, seconds: hold, path: path)
    }

    static func max(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let path = try socketPath(&args)
        let seconds = try CLISupport.takeOption("--hold", from: &args).map(CLISupport.parseHold)
        guard args.isEmpty else { throw CLISupport.UsageError("usage: max [--hold SECONDS]") }
        return try holdFans(selector: .all, speed: .percent(100), seconds: seconds, path: path)
    }

    private static func holdFans(selector: FanSelector, speed: CLISupport.SpeedSpec, seconds: TimeInterval?, path: String) throws -> Int32 {
        let client = try DaemonClient(path: path)
        defer { client.close() }
        let fans = client.hello?.fans ?? []

        let chosen: [FanInfo]
        switch selector {
        case .all:
            chosen = fans.filter { $0.backend.canControl }
        case .fan(let index):
            guard let fan = fans.first(where: { $0.index == index }) else {
                throw CLIError(message: "this Mac has no fan \(index)")
            }
            guard fan.backend.canControl else { throw CLIError(message: "fan \(index) cannot be controlled (monitor only)") }
            chosen = [fan]
        }
        guard !chosen.isEmpty else {
            throw CLIError(message: client.hello?.monitorReason.map { "fan control is not possible here: \($0)" } ?? "no controllable fans")
        }

        var targets: [Int: Double] = [:]
        for fan in chosen { targets[fan.index] = speed.rpm(min: fan.minRPM, max: fan.maxRPM) }

        let interrupt = InterruptFlag()
        let result = try HoldSession.run(client: client, targets: targets, duration: seconds,
                                         shouldStop: { interrupt.isRaised },
                                         report: { print($0); fflush(stdout) },
                                         started: {
            if let seconds {
                print("Holding for \(Int(seconds)) s, then returning the fans to automatic control.")
            } else {
                print("Holding until you press Ctrl-C, then returning the fans to automatic control.")
            }
            fflush(stdout)
        })
        switch result.ending {
        case .timeUp, .stopped:
            print("Fans returned to automatic control.")
            return ExitCode.ok
        case .lostControl(let lost):
            CLI.fail("lost control of fan(s) \(lost): another client took them, the system overrode them, or the failsafe tripped")
            return ExitCode.failure
        case .connectionLost:
            CLI.fail("lost the connection to the helper; it returns the fans to automatic control by itself")
            return ExitCode.failure
        }
    }

    // MARK: auto

    static func auto(_ arguments: [String]) throws -> Int32 {
        var args = arguments
        let path = try socketPath(&args)
        let direct = CLISupport.takeFlag("--direct", from: &args)
        guard args.count <= 1 else { throw CLISupport.UsageError("usage: auto [fan|all] [--direct]") }
        let selector = try args.first.map(CLISupport.parseFanSelector) ?? .all

        if !direct {
            do {
                let client = try DaemonClient(path: path)
                defer { client.close() }
                let reply = try client.exchange(.auto(selector))
                guard reply.ok, case .auto(let released) = reply.body else {
                    throw CLIError(message: "\(reply.err?.rawValue ?? "error"): \(reply.msg ?? "auto failed")")
                }
                print(released.isEmpty ? "Nothing to release: all fans were already under system control."
                                       : "Returned fan(s) \(released.map(String.init).joined(separator: ", ")) to automatic control.")
                if let note = reply.msg { print(note) }
                return ExitCode.ok
            } catch DaemonClientError.unreachable(let path, let reason) {
                guard geteuid() == 0 else {
                    throw CLIError(message: "cannot reach the helper at \(path) (\(reason)). Run 'sudo fanpilotctl auto all' to release the fans directly.",
                                   code: ExitCode.unreachable)
                }
                print("The helper is not running; releasing the fans directly.")
            } catch let error as DaemonClientError where geteuid() == 0 && error.isUnresponsive {
                // The helper is there but not answering (full, hung, shutting down). Recovery is the
                // whole point of this command, so root does not depend on it.
                print("The helper did not answer (\(error)); releasing the fans directly.")
            }
        }
        return try HardwareCommands.releaseDirectly(selector)
    }
}
