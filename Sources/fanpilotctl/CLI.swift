import FanPilotHelperCore
import FanPilotKit
import Foundation

/// Exit codes. Anything non-zero means the requested action did not fully happen.
enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let unreachable: Int32 = 3
    static let notRoot: Int32 = 4
}

/// A failure with a message for the user and an exit code.
struct CLIError: Error {
    var message: String
    var code: Int32 = ExitCode.failure
}

enum CLI {
    static let usage = """
    usage: fanpilotctl <command> [options]

    Reading (no privileges needed):
      list [--json]                      fans, limits and live speeds
      sensors [--all] [--json]           temperature sensors (--all includes the 'Other' group)
      watch [--interval S] [--count N]   live fans and temperatures
      smc-read KEY...                    raw SMC key (debugging)

    Talking to the helper:
      status [--json]                    what the helper is doing right now
      daemon-ping                        check that the helper answers
      set <fan|all> <RPM|NN%> [--hold SECONDS]
                                         hold fans at a speed (until Ctrl-C, or SECONDS), then auto
      max [--hold SECONDS]               all fans to maximum
      auto [fan|all] [--direct]          return fans to automatic control. As root this also works
                                         when the helper is not running ('sudo fanpilotctl auto all')

    Hardware tests (root, supervised):
      selftest [--fan N] [--yes]         Phase 0: does this Mac honor manual fan control?
      smc-write KEY HEX [--yes]          write a fan key by hand (F<n>Tg, F<n>md, F<n>Md, Ftst, FS! only)

    Exit status: 0 ok, 1 failed, 2 usage, 3 helper not reachable, 4 needs root.
    """

    static func run(_ arguments: [String]) -> Int32 {
        // The shared library logs like the daemon does; in a terminal only problems are interesting.
        HelperLog.setSink { level, text in
            guard level == .warning || level == .error || level == .critical else { return }
            StandardError.write("fanpilotctl: \(level.rawValue): \(text)\n")
        }
        var args = Array(arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            return ExitCode.usage
        }
        args.removeFirst()
        if command == "help" || command == "--help" || command == "-h" {
            print(usage)
            return ExitCode.ok
        }

        do {
            switch command {
            case "list": return try ReadCommands.list(args)
            case "sensors": return try ReadCommands.sensors(args)
            case "watch": return try ReadCommands.watch(args)
            case "smc-read": return try ReadCommands.smcRead(args)
            case "status": return try DaemonCommands.status(args)
            case "daemon-ping": return try DaemonCommands.ping(args)
            case "set": return try DaemonCommands.set(args)
            case "max": return try DaemonCommands.max(args)
            case "auto": return try DaemonCommands.auto(args)
            case "selftest": return try HardwareCommands.selftest(args)
            case "smc-write": return try HardwareCommands.smcWrite(args)
            default:
                throw CLISupport.UsageError("unknown command '\(command)'")
            }
        } catch let error as CLISupport.UsageError {
            fail("\(error)")
            StandardError.write("\n\(usage)\n")
            return ExitCode.usage
        } catch let error as DaemonClientError {
            fail("\(error)")
            if case .unreachable = error { return ExitCode.unreachable }
            return ExitCode.failure
        } catch let error as CLIError {
            fail(error.message)
            return error.code
        } catch {
            fail("\(error)")
            return ExitCode.failure
        }
    }

    static func fail(_ message: String) {
        StandardError.write("fanpilotctl: \(message)\n")
    }

    /// Prompts for confirmation unless `assumeYes`. Anything but "yes" cancels.
    static func confirm(_ question: String, assumeYes: Bool) -> Bool {
        if assumeYes { return true }
        print("\(question) Type 'yes' to continue: ", terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
    }

    static func requireRoot(_ what: String) throws {
        guard geteuid() == 0 else {
            throw CLIError(message: "\(what) needs root. Run it with sudo.", code: ExitCode.notRoot)
        }
    }
}

/// Raised by SIGINT, SIGTERM and SIGHUP, so loops can wind down and return the fans to auto instead
/// of dying with them held.
final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                self?.lock.lock(); self?.raised = true; self?.lock.unlock()
            }
            source.resume()
            sources.append(source)
        }
    }

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }
        return raised
    }
}

func printJSON(_ object: Any) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}
