import FanPilotControl
import FanPilotKit
import Foundation

/// Where the connection to the root helper stands, in terms the UI can explain.
enum HelperAvailability: Equatable {
    case connecting
    /// No helper files and no socket: the user has not installed it.
    case notInstalled
    /// Installed (files exist) but the socket does not answer.
    case notRunning(String)
    /// The helper answered but refused this user.
    case unauthorized(String)
    case incompatible(String)
    case connected

    var isConnected: Bool { self == .connected }
}

/// Things the client reports to the model. Always delivered on the main queue.
enum HelperUpdate {
    case availability(HelperAvailability, hello: HelloReply?)
    case status(StatusReply)
    /// The helper no longer owns these fans for us (sleep, failsafe, OS override, restart).
    case lostOwnership([Int])
    case commandFailed(fan: Int?, code: WireErrorCode, message: String, forcedRPM: Double?)
    /// The helper described itself again on the existing connection (after a refused command that
    /// suggests its fan list changed, for example after wake). Not a new session: the controller keeps
    /// its state.
    case helloRefreshed(HelloReply)
}

/// Asynchronous client for the root helper's NDJSON socket (docs/SPEC.md 4.4, 4.6).
///
/// All socket traffic happens on one private serial queue with blocking reads that carry a timeout;
/// results come back on the main queue through `onUpdate`. The client
/// - connects with the backoff 1, 2, 4, 8, 30 s and says `hello` first,
/// - sends a heartbeat (renewing the leases) plus a `status` request every 5 s,
/// - tells the model when a fan it believes it owns is missing from a heartbeat reply, and
/// - on quit sends `auto all` and waits up to two seconds for the reply (fire and forget could be lost).
final class HelperClient: @unchecked Sendable {
    static let backoffSteps: [TimeInterval] = [1, 2, 4, 8, 30]

    private let queue = DispatchQueue(label: "com.fanpilot.helper-client", qos: .userInitiated)
    private let socketPath: String
    private let clientName: String

    private let stateLock = NSLock()
    private var running = false

    // Queue-confined state.
    private var connection: LineSocketConnection?
    private var hello: HelloReply?
    private var nextID = 1
    private var ownedExpected: Set<Int> = []
    private var backoffIndex = 0
    private var reconnectWork: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastPublished: HelperAvailability?

    /// Called on the main queue.
    var onUpdate: (@Sendable (HelperUpdate) -> Void)?

    init(socketPath: String = Constants.socketPath, clientName: String = "FanPilot") {
        self.socketPath = socketPath
        self.clientName = clientName
    }

    // MARK: Lifecycle

    func start() {
        setRunning(true)
        queue.async { [self] in connectNow() }
    }

    /// Stops reconnecting and drops the connection WITHOUT telling the helper anything; the helper
    /// releases our fans on disconnect. Use `releaseAllAndStop` on quit.
    func stop() {
        setRunning(false)
        queue.async { [self] in dropConnection(publish: false) }
    }

    /// Connect now instead of waiting for the backoff timer (after an install, or from a button).
    func retryNow() {
        queue.async { [self] in
            backoffIndex = 0
            reconnectWork?.cancel()
            reconnectWork = nil
            if connection == nil { connectNow() }
        }
    }

    /// Quit and sleep path: returns every fan to the system, waiting at most `timeout` seconds for the
    /// helper's answer, then says goodbye and closes. Reconnecting stops when `stopAfterwards`.
    func releaseAllAndStop(timeout: TimeInterval = 2, stopAfterwards: Bool = true) {
        if stopAfterwards { setRunning(false) }
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            if let conn = connection {
                _ = try? exchange(conn, .auto(.all), timeout: timeout)
                if stopAfterwards {
                    _ = try? exchange(conn, .bye, timeout: 0.5)
                }
            }
            ownedExpected.removeAll()
            if stopAfterwards { dropConnection(publish: false) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout + 0.25)
    }

    /// Asynchronous `auto all` that keeps the connection (system sleep).
    func releaseAll() {
        queue.async { [self] in
            guard let conn = connection else { return }
            _ = try? exchange(conn, .auto(.all), timeout: 2)
            ownedExpected.removeAll()
        }
    }

    // MARK: Commands

    /// Sends what the controller decided: `.rpm` becomes `set` (taking over the fan if needed, and
    /// renewing its lease), `.auto` becomes `auto <fan>`.
    func apply(_ commands: [(fan: Int, command: FanCommand)]) {
        guard !commands.isEmpty else { return }
        queue.async { [self] in
            guard let conn = connection else { return }
            let ttl = leaseTTL()
            for (fan, command) in commands {
                do {
                    switch command {
                    case .rpm(let rpm):
                        let reply = try exchange(conn, .set(fan: fan, rpm: rpm, ttl: ttl))
                        if reply.ok {
                            ownedExpected.insert(fan)
                        } else {
                            ownedExpected.remove(fan)
                            publish(.commandFailed(fan: fan, code: reply.err ?? .unknown,
                                                   message: reply.msg ?? "The helper refused the command.",
                                                   forcedRPM: reply.forcedRPM))
                        }
                    case .auto:
                        let reply = try exchange(conn, .auto(.fan(fan)))
                        ownedExpected.remove(fan)
                        if !reply.ok {
                            publish(.commandFailed(fan: fan, code: reply.err ?? .unknown,
                                                   message: reply.msg ?? "The helper refused the command.",
                                                   forcedRPM: nil))
                        }
                    }
                } catch {
                    dropConnection(publish: true, reason: "\(error)")
                    return
                }
            }
        }
    }

    /// Asks the helper to describe itself again. The helper re-discovers its fans after wake and may
    /// know about fans we cached as controllable (or not); without this the cached list only changes
    /// on reconnect, and commands for a fan the helper has given up on would be retried forever.
    func refreshHello() {
        queue.async { [self] in
            guard let conn = connection else { return }
            do {
                let reply = try exchange(conn, .hello(proto: Constants.protocolVersion, client: clientName))
                if reply.ok, case .hello(let info) = reply.body, info.proto == Constants.protocolVersion {
                    hello = info
                    publish(.helloRefreshed(info))
                }
            } catch {
                dropConnection(publish: true, reason: "\(error)")
            }
        }
    }

    /// Asks for a status reply right away (the Helper pane's "Refresh").
    func pollStatus() {
        queue.async { [self] in heartbeat() }
    }

    // MARK: Connection (queue-confined)

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock(); running = value; stateLock.unlock()
    }

    private func leaseTTL() -> Double {
        min(Constants.defaultLeaseSeconds, hello?.leaseMaxS ?? Constants.defaultLeaseSeconds)
    }

    /// Seconds between heartbeats. The default is 5 s, but it must stay well below the lease the
    /// helper will grant (`helper.json` allows a cap as low as 5 s), or the lease would run out between
    /// two beats and the fans would flap between manual and auto.
    static func heartbeatInterval(leaseMax: Double?) -> TimeInterval {
        guard let leaseMax, leaseMax.isFinite else { return Constants.heartbeatIntervalSeconds }
        return min(Constants.heartbeatIntervalSeconds, max(1, leaseMax / 3))
    }

    private func connectNow() {
        guard isRunning, connection == nil else { return }
        if lastPublished == nil { publishAvailability(.connecting, hello: nil) }

        let conn: LineSocketConnection
        do {
            conn = try LineSocketConnection.connect(path: socketPath)
        } catch {
            publishAvailability(unreachableState(for: error), hello: nil)
            scheduleReconnect()
            return
        }

        do {
            let reply = try exchange(conn, .hello(proto: Constants.protocolVersion, client: clientName), timeout: 3)
            guard reply.ok, case .hello(let info) = reply.body else {
                conn.close()
                let message = reply.msg ?? "The helper refused the connection."
                if reply.err == .unauthorized {
                    publishAvailability(.unauthorized(message), hello: nil)
                } else {
                    publishAvailability(.incompatible(message), hello: nil)
                }
                scheduleReconnect(minimum: 30)
                return
            }
            guard info.proto == Constants.protocolVersion else {
                conn.close()
                publishAvailability(.incompatible("The helper speaks protocol \(info.proto); this app needs \(Constants.protocolVersion). Reinstall the helper."),
                                    hello: nil)
                scheduleReconnect(minimum: 30)
                return
            }
            connection = conn
            hello = info
            ownedExpected.removeAll()
            backoffIndex = 0
            publishAvailability(.connected, hello: info)
            startHeartbeat()
            heartbeat()
        } catch {
            conn.close()
            publishAvailability(.notRunning("The helper accepted the connection but did not answer (\(error))."), hello: nil)
            scheduleReconnect()
        }
    }

    private func unreachableState(for error: Error) -> HelperAvailability {
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: Constants.helperInstallPath)
            || fm.fileExists(atPath: Constants.launchDaemonPlistPath)
        if installed {
            return .notRunning("The helper is installed but its socket \(socketPath) does not answer.")
        }
        return .notInstalled
    }

    private func scheduleReconnect(minimum: TimeInterval = 0) {
        guard isRunning else { return }
        let step = Self.backoffSteps[min(backoffIndex, Self.backoffSteps.count - 1)]
        backoffIndex = min(backoffIndex + 1, Self.backoffSteps.count - 1)
        let delay = max(step, minimum)
        let work = DispatchWorkItem { [weak self] in self?.connectNow() }
        reconnectWork?.cancel()
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dropConnection(publish shouldPublish: Bool, reason: String? = nil) {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.close()
        connection = nil
        hello = nil
        ownedExpected.removeAll()
        if shouldPublish {
            publishAvailability(.notRunning(reason.map { "Connection lost: \($0)" } ?? "Connection lost."), hello: nil)
            scheduleReconnect()
        } else {
            reconnectWork?.cancel()
            reconnectWork = nil
        }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period = Self.heartbeatInterval(leaseMax: hello?.leaseMaxS)
        timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func heartbeat() {
        guard let conn = connection else { return }
        do {
            let beat = try exchange(conn, .heartbeat(ttl: leaseTTL()))
            if beat.ok, case .heartbeat(let owned) = beat.body {
                let lost = ownedExpected.subtracting(owned)
                if !lost.isEmpty {
                    ownedExpected.subtract(lost)
                    publish(.lostOwnership(lost.sorted()))
                }
            }
            let status = try exchange(conn, .status)
            if status.ok, case .status(let reply) = status.body {
                publish(.status(reply))
            }
        } catch {
            dropConnection(publish: true, reason: "\(error)")
        }
    }

    // MARK: Wire

    private func exchange(_ conn: LineSocketConnection, _ command: WireCommand, timeout: TimeInterval = 3) throws -> WireReply {
        let id = nextID
        nextID += 1
        try conn.sendRequest(WireRequest(id: id, command: command))
        // The first line of a refused connection is an unsolicited `unauthorized` error (id 0).
        while true {
            guard let reply = try conn.readReply(timeout: timeout) else { throw LineSocketError.closed }
            if reply.id == id || (reply.id == 0 && !reply.ok) { return reply }
        }
    }

    // MARK: Publishing

    private func publish(_ update: HelperUpdate) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
    }

    private func publishAvailability(_ availability: HelperAvailability, hello: HelloReply?) {
        // Retries every few seconds would otherwise redraw the UI with identical state.
        if lastPublished == availability, hello == nil || availability != .connected { return }
        lastPublished = availability
        publish(.availability(availability, hello: hello))
    }
}
