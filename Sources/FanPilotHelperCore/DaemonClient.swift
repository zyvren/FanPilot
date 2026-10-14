import FanPilotKit
import Foundation

public enum DaemonClientError: Error, CustomStringConvertible {
    /// The socket cannot be reached (helper not installed or not running).
    case unreachable(path: String, reason: String)
    /// The helper answered with an error reply.
    case refused(code: WireErrorCode, message: String, forcedRPM: Double?)
    case closed
    case timedOut
    case protocolViolation(String)

    /// The helper is reachable but gave no usable answer: it closed the connection (connection cap,
    /// shutting down) or did not reply in time.
    public var isUnresponsive: Bool {
        switch self {
        case .closed, .timedOut: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .unreachable(let path, let reason):
            return "cannot reach the FanPilot helper at \(path): \(reason). Is it installed and running? (scripts/install_helper.sh)"
        case .refused(let code, let message, _):
            return "\(code.rawValue): \(message)"
        case .closed:
            return "the helper closed the connection"
        case .timedOut:
            return "the helper did not answer in time"
        case .protocolViolation(let why):
            return "unexpected reply from the helper: \(why)"
        }
    }
}

/// A small synchronous client for the helper protocol, used by `fanpilotctl`. (The app has its own
/// asynchronous client; this one favors simplicity: one request in flight, replies matched by id.)
public final class DaemonClient {
    public let path: String
    public private(set) var hello: HelloReply?

    private let connection: LineSocketConnection
    private var nextID = 1

    /// Connects and performs the `hello` handshake.
    public init(path: String = Constants.socketPath, clientName: String = "fanpilotctl",
                timeout: TimeInterval = 5) throws {
        self.path = path
        do {
            connection = try LineSocketConnection.connect(path: path)
        } catch let error as LineSocketError {
            throw DaemonClientError.unreachable(path: path, reason: error.description)
        }
        let body = try request(.hello(proto: Constants.protocolVersion, client: clientName), timeout: timeout)
        guard case .hello(let info) = body else { throw DaemonClientError.protocolViolation("hello reply has no fan list") }
        hello = info
    }

    deinit { connection.close() }

    /// Sends one command and returns the success body. Throws `refused` for an error reply.
    @discardableResult
    public func request(_ command: WireCommand, timeout: TimeInterval = 5) throws -> WireReplyBody {
        let reply = try exchange(command, timeout: timeout)
        guard reply.ok else {
            throw DaemonClientError.refused(code: reply.err ?? .unknown, message: reply.msg ?? "", forcedRPM: reply.forcedRPM)
        }
        return reply.body
    }

    /// Like `request` but returns the whole reply, including the optional note (`msg`) of a success.
    public func exchange(_ command: WireCommand, timeout: TimeInterval = 5) throws -> WireReply {
        let id = nextID
        nextID += 1
        do {
            try connection.sendRequest(WireRequest(id: id, command: command))
            while true {
                guard let reply = try connection.readReply(timeout: timeout) else { throw DaemonClientError.closed }
                if reply.id == id { return reply }
                // Anything else is a stale or unsolicited line; the protocol has none, skip it.
            }
        } catch let error as DaemonClientError {
            throw error
        } catch LineSocketError.timeout {
            throw DaemonClientError.timedOut
        } catch let error as LineSocketError {
            if error == .closed { throw DaemonClientError.closed }
            throw DaemonClientError.protocolViolation(error.description)
        } catch let error as WireError {
            throw DaemonClientError.protocolViolation(error.description)
        }
    }

    public func status() throws -> StatusReply {
        guard case .status(let status) = try request(.status) else {
            throw DaemonClientError.protocolViolation("status reply has the wrong shape")
        }
        return status
    }

    /// Releases this connection's fans and closes politely.
    public func sayGoodbye() {
        _ = try? exchange(.bye, timeout: 2)
        connection.close()
    }

    public func close() { connection.close() }
}

/// Holds fans at fixed speeds for a while: sets them, then heartbeats until time is up or `shouldStop`,
/// then returns them to auto. This is the loop behind `fanpilotctl set ... --hold`.
public enum HoldSession {
    public struct Result: Equatable {
        public enum Ending: Equatable { case timeUp, stopped, lostControl([Int]), connectionLost }
        public var ending: Ending
        public var applied: [Int: SetReply]
    }

    /// - Parameters:
    ///   - targets: fan index to RPM.
    ///   - duration: seconds to hold; nil holds until `shouldStop` returns true.
    ///   - heartbeat: seconds between heartbeats (the lease is three times as long). Shortened if the
    ///     helper's lease cap is small, so a lease can never run out between two heartbeats.
    public static func run(client: DaemonClient,
                           targets: [Int: Double],
                           duration: TimeInterval?,
                           heartbeat: TimeInterval = Constants.heartbeatIntervalSeconds,
                           sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                           now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                           shouldStop: () -> Bool,
                           report: (String) -> Void,
                           started: () -> Void = {}) throws -> Result {
        let leaseCap = client.hello?.leaseMaxS ?? Constants.defaultLeaseMaxSeconds
        let heartbeat = min(heartbeat, max(1, leaseCap / 3))
        let ttl = min(heartbeat * 3, leaseCap)
        var applied: [Int: SetReply] = [:]
        do {
            for (fan, rpm) in targets.sorted(by: { $0.key < $1.key }) {
                guard case .set(let reply) = try client.request(.set(fan: fan, rpm: rpm, ttl: ttl)) else {
                    throw DaemonClientError.protocolViolation("set reply has the wrong shape")
                }
                applied[fan] = reply
                report("fan \(fan): \(FanKeyReader.rpmText(reply.applied)) RPM" + (reply.clamped ? " (clamped to the fan's limits)" : ""))
            }
        } catch {
            _ = try? client.exchange(.bye, timeout: 2)
            throw error
        }

        started()
        let began = now()
        var lastBeat = began
        var ending = Result.Ending.timeUp
        while true {
            if shouldStop() { ending = .stopped; break }
            if let duration, now() - began >= duration { ending = .timeUp; break }
            sleep(0.25)
            guard now() - lastBeat >= heartbeat else { continue }
            lastBeat = now()
            do {
                guard case .heartbeat(let owned) = try client.request(.heartbeat(ttl: ttl)) else { continue }
                let lost = targets.keys.filter { !owned.contains($0) }.sorted()
                if !lost.isEmpty {
                    ending = .lostControl(lost)
                    break
                }
            } catch {
                ending = .connectionLost
                break
            }
        }

        if ending != .connectionLost {
            // `bye` releases exactly the fans this connection holds, so fans that moved to another
            // client (or the failsafe) are not disturbed.
            _ = try? client.exchange(.bye, timeout: 2)
        }
        return Result(ending: ending, applied: applied)
    }
}
