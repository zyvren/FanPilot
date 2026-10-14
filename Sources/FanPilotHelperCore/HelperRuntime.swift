import FanPilotKit
import FanPilotSensors
import Foundation

/// Command line options of `fanpilotd`.
public struct HelperOptions: Equatable, Sendable {
    public var socketPath: String?
    public var configPath = Constants.helperConfigPath
    /// Development mode: opens the SMC read-only (every write is refused before it reaches the
    /// hardware), allows running without root and trusts a config owned by the current user.
    public var readOnly = false
    public var verbose = false
    /// Hardware test of the failsafe: trip at this temperature (40...100 C) instead of the configured one.
    public var failsafeTestC: Double?
    public var showVersion = false
    public var showHelp = false

    public init() {}

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(String, String)

        public var description: String {
            switch self {
            case .unknownOption(let o): return "unknown option \(o)"
            case .missingValue(let o): return "option \(o) needs a value"
            case .invalidValue(let o, let v): return "'\(v)' is not valid for \(o)"
            }
        }
    }

    public static let usage = """
    usage: fanpilotd [--socket PATH] [--config PATH] [--read-only] [--failsafe-test C] [--verbose] [--version] [--help]

      The FanPilot root helper. Normally started by launchd (see scripts/install_helper.sh).
      --socket PATH   listen here instead of the path in helper.json
      --config PATH   read this config instead of \(Constants.helperConfigPath)
      --read-only     development mode: never write the SMC, run without root
      --failsafe-test C  hardware test: trip the thermal failsafe at C degrees (40-100) instead of the
                         configured temperature. Use in the foreground only, never in the LaunchDaemon.
      --verbose       log debug messages
    """

    public static func parse(_ arguments: [String]) throws -> HelperOptions {
        var options = HelperOptions()
        var index = 0
        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(option) }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--socket": options.socketPath = try value(for: argument)
            case "--config": options.configPath = try value(for: argument)
            case "--read-only": options.readOnly = true
            case "--failsafe-test":
                let text = try value(for: argument)
                guard let degrees = Double(text), degrees.isFinite, (40...100).contains(degrees) else {
                    throw ParseError.invalidValue(argument, text)
                }
                options.failsafeTestC = degrees
            case "--verbose", "-v": options.verbose = true
            case "--version": options.showVersion = true
            case "--help", "-h": options.showHelp = true
            default: throw ParseError.unknownOption(argument)
            }
            index += 1
        }
        return options
    }
}

/// Assembles and runs the daemon: SMC, engine, server, power events and signal handling.
public final class HelperRuntime {
    /// Kept so the `atexit` hook can reach the engine.
    nonisolated(unsafe) private static var current: HelperRuntime?

    public let options: HelperOptions
    public let server: HelperServer
    public let engine: HelperEngine
    private let power: PowerEvents
    private var signalSources: [DispatchSourceSignal] = []

    private init(options: HelperOptions, engine: HelperEngine, server: HelperServer) {
        self.options = options
        self.engine = engine
        self.server = server
        let server = server
        self.power = PowerEvents(onWillSleep: { server.onCore { $0.systemWillSleep() } },
                                 onDidWake: { server.onCore { $0.systemDidWake() } })
    }

    /// Runs the daemon. Returns only on a startup failure (the exit code); on success it parks in
    /// the dispatch main loop and ends through the signal handlers.
    public static func main(arguments: [String]) -> Int32 {
        let options: HelperOptions
        do {
            options = try HelperOptions.parse(arguments)
        } catch {
            StandardError.write("fanpilotd: \(error)\n\(HelperOptions.usage)\n")
            return 64
        }
        if options.showHelp {
            print(HelperOptions.usage)
            return 0
        }
        if options.showVersion {
            print("fanpilotd \(Constants.helperVersion)")
            return 0
        }
        HelperLog.setVerbose(options.verbose)

        if geteuid() != 0 && !options.readOnly {
            StandardError.write("fanpilotd: must run as root (use --read-only for development)\n")
            return 77
        }

        let runtime: HelperRuntime
        do {
            runtime = try build(options: options)
        } catch let error as LineSocketError {
            HelperLog.critical("cannot start: \(error)")
            return 73
        } catch {
            HelperLog.critical("cannot start: \(error)")
            return 78
        }
        runtime.run()
    }

    /// Builds everything and starts listening. Throws before any client can connect.
    public static func build(options: HelperOptions) throws -> HelperRuntime {
        let trustedUID: uid_t = options.readOnly ? geteuid() : 0
        let loaded = TrustedConfig.load(path: options.configPath, trustedUID: trustedUID)
        if let warning = loaded.warning { HelperLog.warning(warning) }
        let config = loaded.config.normalized()
        let socketPath = options.socketPath ?? config.socketPath

        signal(SIGPIPE, SIG_IGN)   // a vanished client must never kill the root daemon

        let smc = try IOKitSMC(access: options.readOnly ? .readOnly : .readWrite)
        // Two independent hot-set classifiers; the failsafe uses the hotter of the two.
        let hotSet = CompositeHotSetProvider([
            SensorsHotSetProvider(smc: smc),
            SMCHotSetReader(smc: smc, includeHID: false),
        ])
        let engine = HelperEngine(smc: smc, hotSet: hotSet, config: config, failsafeTestC: options.failsafeTestC,
                                  model: HardwareInfo.current().model)
        let server = HelperServer(engine: engine,
                                  authorizer: ConfigPeerAuthorizer(config: config),
                                  socketPath: socketPath)

        // Order matters (docs/SPEC.md 4.5 #4):
        //  1. Bind the socket without accepting. A second instance fails here, before it can touch
        //     (and "recover") the fans the first one is holding.
        //  2. Install the signal handlers, so a SIGTERM during startup releases the fans instead of
        //     killing the process with the default action.
        //  3. Run the startup release on the engine queue, where every other engine call runs.
        //  4. Only then accept clients.
        try server.bind()
        let runtime = HelperRuntime(options: options, engine: engine, server: server)
        runtime.installSignalHandlers()
        server.onCore { $0.start() }
        server.beginAccepting()
        HelperLog.info("fanpilotd \(Constants.helperVersion) ready (pid \(getpid()), mode \(options.readOnly ? "read-only" : "read-write"), auth \(config.authMode.rawValue), failsafe \(Int(config.failsafeTempC)) C, lease max \(Int(config.leaseMaxSeconds)) s)")
        return runtime
    }

    /// Installs signal handling and power events, then parks in the dispatch main loop.
    public func run() -> Never {
        installSignalHandlers()   // normally done by build(); a no-op then
        _ = power.start()

        HelperRuntime.current = self
        atexit {
            HelperRuntime.current?.emergencyRelease()
        }
        dispatchMain()
    }

    /// SIGTERM, SIGINT, SIGHUP, SIGQUIT: release every fan, then exit (docs/SPEC.md 4.5 #4).
    public func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for number in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(number, SIG_IGN)   // let the dispatch source take over
            let source = DispatchSource.makeSignalSource(signal: number, queue: DispatchQueue(label: "com.fanpilot.helper.signal.\(number)"))
            source.setEventHandler { [self] in
                HelperLog.info("received signal \(number): releasing all fans and exiting")
                power.stop()
                server.shutdown(reason: "signal \(number)")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Last-chance release from `atexit`. Waits at most a few seconds for the engine queue.
    private func emergencyRelease() {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [self] in
            server.onCore { $0.shutdown(reason: "process exit") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
}
