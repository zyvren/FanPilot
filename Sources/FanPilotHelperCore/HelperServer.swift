import FanPilotKit
import Foundation

/// The socket front end of the helper (docs/SPEC.md 4.3, 4.4): accepts connections, authorizes the
/// peer, enforces the hello timeout and the connection cap, decodes requests and feeds them to the
/// `HelperEngine`, and drives the engine's maintenance timer.
///
/// Threads: one blocking reader thread per connection (at most `maxConnections` plus a few that are
/// being refused). All engine access is serialized on `core`; a reply is written from the
/// connection's own thread, outside the engine queue, so a slow client can never stall the helper.
public final class HelperServer {
    public let engine: HelperEngine
    public let socketPath: String

    private let authorizer: PeerAuthorizer
    private let socket: LineSocketServer
    private let core = DispatchQueue(label: "com.fanpilot.helper.core")
    private let acceptQueue = DispatchQueue(label: "com.fanpilot.helper.accept")
    private let helloTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let maxConnections: Int
    private let throttle = LogThrottle()

    /// Refused peers get one reply and a very short fuse, and have their own small cap so that a
    /// flood from a user who is not allowed to connect cannot crowd out the one who is.
    private static let maxRefusedConnections = 8
    private static let refusedPeerTimeout: TimeInterval = 0.5
    /// Extra connections only root may use, so `sudo fanpilotctl auto all` still gets through when
    /// ordinary clients have filled the cap.
    private static let rootReservedConnections = 2
    /// Every client heartbeats at least every few seconds (the app every 5 s, the CLI hold loop at
    /// least every lease/3), and a lease never outlives `leaseMaxSeconds`. A connection silent for
    /// longer than this holds a slot for nothing.
    public static let defaultIdleTimeout: TimeInterval = 60

    private let lock = NSLock()
    private var live: [Int: LineSocketConnection] = [:]
    private var refusedLive = 0
    private var nextConnectionID = 1
    private var stopped = false

    // Touched only on `core`.
    private var timer: DispatchSourceTimer?
    private var timerInterval: TimeInterval?

    public init(engine: HelperEngine,
                authorizer: PeerAuthorizer,
                socketPath: String,
                fileMode: mode_t = 0o666,
                helloTimeout: TimeInterval = Constants.helloTimeoutSeconds,
                idleTimeout: TimeInterval = HelperServer.defaultIdleTimeout,
                maxConnections: Int = Constants.maxConnections) {
        self.engine = engine
        self.authorizer = authorizer
        self.socketPath = socketPath
        self.helloTimeout = helloTimeout
        self.idleTimeout = max(idleTimeout, helloTimeout)
        self.maxConnections = maxConnections
        self.socket = LineSocketServer(path: socketPath, fileMode: fileMode)
    }

    // MARK: Lifecycle

    /// Binds the socket and starts accepting.
    public func start() throws {
        try bind()
        beginAccepting()
    }

    /// Binds and listens without accepting: clients queue in the backlog. Lets the daemon find out
    /// that another instance owns the socket BEFORE it touches any fan, and install its signal
    /// handlers before the startup release runs.
    public func bind() throws {
        try socket.start()
    }

    /// Starts accepting connections on a bound socket.
    public func beginAccepting() {
        socket.startAccepting(on: acceptQueue) { [weak self] connection in
            self?.accepted(connection)
        }
        HelperLog.info("listening on \(socketPath)")
    }

    /// Stops listening and closes every connection. Fans are NOT touched here; the engine releases
    /// them when the connections close, and `shutdown(reason:)` does it explicitly first.
    public func stop() {
        lock.lock()
        stopped = true
        let connections = Array(live.values)
        lock.unlock()

        socket.stop()
        connections.forEach { $0.shutdown() }
        core.sync {
            timer?.cancel()
            timer = nil
            timerInterval = nil
        }
    }

    /// Orderly exit path (signals): refuse new connections, release every fan, then drop the clients.
    public func shutdown(reason: String) {
        lock.lock()
        stopped = true
        lock.unlock()
        socket.stop()                       // no new takeovers can arrive after this
        onCore { $0.shutdown(reason: reason) }
        stop()
    }

    /// Authorized connections currently open (refused peers are not counted).
    public var activeConnections: Int {
        lock.lock(); defer { lock.unlock() }
        return live.count
    }

    /// Interval of the maintenance timer; nil while idle (no connections, no fans), when no timer exists.
    public var maintenanceInterval: TimeInterval? {
        core.sync { timerInterval }
    }

    /// Runs `body` on the engine queue and re-evaluates the maintenance timer afterwards. Power
    /// events and signal handlers use this to reach the engine.
    @discardableResult
    public func onCore<T>(_ body: (HelperEngine) -> T) -> T {
        core.sync {
            let result = body(engine)
            rearmTimer()
            return result
        }
    }

    // MARK: Timer (core queue)

    private func rearmTimer() {
        let wanted = engine.desiredTickInterval
        if wanted == timerInterval { return }
        timer?.cancel()
        timer = nil
        timerInterval = wanted
        guard let interval = wanted else { return }   // idle: no timer at all (SPEC 4.5 #8)

        let source = DispatchSource.makeTimerSource(queue: core)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.engine.tick()
            self.rearmTimer()
        }
        source.resume()
        timer = source
    }

    // MARK: Connections

    private func accepted(_ connection: LineSocketConnection) {
        // Peer credentials come from the kernel and are cheap, so authorize before spending a thread.
        let decision = authorizer.authorize(connection)
        logConnection(decision)

        lock.lock()
        if stopped {
            lock.unlock()
            connection.close()
            return
        }
        let id = nextConnectionID
        nextConnectionID += 1
        if decision.allowed {
            let limit = maxConnections + (decision.uid == 0 ? Self.rootReservedConnections : 0)
            let current = live.count
            if current >= limit {
                lock.unlock()
                if let skipped = throttle.admit("cap", every: 5) {
                    HelperLog.warning("refusing connection: \(current) clients are already connected" + Self.suppressedNote(skipped))
                }
                connection.close()
                return
            }
            live[id] = connection
        } else {
            if refusedLive >= Self.maxRefusedConnections {
                lock.unlock()
                connection.close()
                return
            }
            refusedLive += 1
        }
        lock.unlock()

        Thread.detachNewThread { [self] in
            if decision.allowed {
                serve(connection, id: id)
            } else {
                refuse(connection, decision: decision)
            }
        }
    }

    /// One line per peer verdict, rate limited per uid: any local user can open connections as fast
    /// as they like, and an unthrottled line per connect fills the disk (and the log) in hours.
    /// The process path is looked up only when the line is actually written.
    private func logConnection(_ decision: PeerDecision) {
        let key = (decision.allowed ? "ok:" : "refused:") + (decision.uid.map(String.init) ?? "?")
        guard let skipped = throttle.admit(key, every: decision.allowed ? 1 : 5) else { return }
        var shown = decision
        if shown.processPath == nil, let pid = decision.pid { shown.processPath = ConfigPeerAuthorizer.processPath(pid: pid) }
        HelperLog.info("connection: \(shown.summary)" + Self.suppressedNote(skipped))
    }

    private static func suppressedNote(_ skipped: Int) -> String {
        skipped > 0 ? " (\(skipped) similar events not logged)" : ""
    }

    /// A peer that is not allowed gets one `unauthorized` reply to its first message and is dropped.
    private func refuse(_ connection: LineSocketConnection, decision: PeerDecision) {
        defer {
            lock.lock()
            refusedLive -= 1
            lock.unlock()
            connection.close()
        }
        guard let line = try? connection.readLine(timeout: min(helloTimeout, Self.refusedPeerTimeout)) else { return }
        send(.failure(id: WireCodec.peekID(line) ?? 0, op: nil, code: .unauthorized,
                      message: "this user is not authorized to control the fans (\(decision.reason))"),
             on: connection)
    }

    private func serve(_ connection: LineSocketConnection, id: Int) {
        core.sync {
            engine.connectionOpened(id)
            rearmTimer()
        }
        defer {
            core.sync {
                engine.connectionClosed(id)
                rearmTimer()
            }
            lock.lock()
            live[id] = nil
            lock.unlock()
            connection.close()
        }

        var awaitingFirstMessage = true
        while true {
            let line: Data?
            do {
                // The first message must arrive quickly. Afterwards a client that sends nothing for
                // `idleTimeout` is dropped: its heartbeats stopped, so it is hung or gone, and a
                // handful of such connections would otherwise lock everyone (even root) out.
                line = try connection.readLine(timeout: awaitingFirstMessage ? helloTimeout : idleTimeout)
            } catch LineSocketError.timeout {
                if awaitingFirstMessage {
                    HelperLog.info("connection \(id): no hello within \(Int(helloTimeout)) s, closing")
                } else {
                    HelperLog.info("connection \(id): silent for \(Int(idleTimeout)) s, closing")
                }
                return
            } catch LineSocketError.lineTooLong {
                send(.failure(id: 0, op: nil, code: .badRequest, message: "line too long"), on: connection)
                HelperLog.warning("connection \(id): over-long line, closing")
                return
            } catch {
                HelperLog.debug("connection \(id): read error \(error)")
                return
            }
            guard let line else { return }   // EOF

            let request: WireRequest
            do {
                request = try WireCodec.decodeRequest(line)
            } catch {
                send(.failure(id: WireCodec.peekID(line) ?? 0, op: nil, code: .badRequest, message: "\(error)"),
                     on: connection)
                if awaitingFirstMessage { return }
                continue
            }
            awaitingFirstMessage = false

            let outcome = core.sync { () -> HelperEngine.Outcome in
                let outcome = engine.handle(request, from: id)
                rearmTimer()
                return outcome
            }
            guard send(outcome.reply, on: connection) else { return }
            if outcome.closeConnection { return }
        }
    }

    @discardableResult
    private func send(_ reply: WireReply, on connection: LineSocketConnection) -> Bool {
        do {
            try connection.sendReply(reply)
            return true
        } catch {
            HelperLog.debug("could not send reply: \(error)")
            return false
        }
    }
}


/// Allows one log line per key per interval and counts what it swallowed in between.
final class LogThrottle: @unchecked Sendable {
    private struct Entry {
        var lastLogged: TimeInterval
        var skipped: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Returns nil if the line should be suppressed, else how many were suppressed since the last one.
    func admit(_ key: String, every interval: TimeInterval) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        if entries.count > 64 { entries.removeAll() }   // keys come from peers; keep the table bounded
        guard var entry = entries[key] else {
            entries[key] = Entry(lastLogged: time, skipped: 0)
            return 0
        }
        guard time - entry.lastLogged >= interval else {
            entry.skipped += 1
            entries[key] = entry
            return nil
        }
        let skipped = entry.skipped
        entries[key] = Entry(lastLogged: time, skipped: 0)
        return skipped
    }
}
