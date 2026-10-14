import FanPilotKit
import Foundation

/// The helper's brain: protocol handling, per-connection ownership, leases, the 1 Hz maintenance
/// tick, the thermal failsafe and the release-on-everything rules (docs/SPEC.md 4.4 and 4.5).
///
/// The engine owns no sockets and no timers. The server feeds it requests and calls `tick()` at
/// `desiredTickInterval`; tests drive it with a manual clock and a mock SMC, no root needed.
///
/// NOT thread-safe: every call must come from one serial queue.
public final class HelperEngine {
    /// Result of handling one request.
    public struct Outcome: Sendable {
        public var reply: WireReply
        /// The server should close the connection after sending the reply.
        public var closeConnection: Bool
    }

    /// Public view of who holds a fan, for tests and diagnostics.
    public struct HoldInfo: Equatable, Sendable {
        public var fan: Int
        public var owner: Int?
        public var clientRPM: Double?
        public var leaseExpiry: TimeInterval?
    }

    /// Seconds between samples while clients are connected but no fan is held.
    public static let idleTickSeconds: TimeInterval = 5
    public static let activeTickSeconds: TimeInterval = 1
    /// After the OS beat us on a fan, new takeovers of that fan are refused for this long.
    public static let overrideCooldownSeconds: TimeInterval = 60

    /// The SMC is unreliable for a few seconds after wake (docs/SPEC.md 3.5 / 4.6), so fan discovery
    /// is repeated this long after `HasPoweredOn` instead of immediately.
    public static let wakeRediscoveryDelaySeconds: TimeInterval = 5
    private static let maxRediscoveryAttempts = 3

    private struct Hold {
        /// Connection id of the client that controls the fan; nil if only the failsafe holds it.
        var owner: Int?
        /// The client's last accepted (clamped) target; restored when the failsafe clears.
        var clientRPM: Double?
        var leaseExpiry: TimeInterval?
        var since: TimeInterval
    }

    private struct ConnectionState {
        var helloDone = false
        var client = ""
    }

    private struct HandlerError: Error {
        var code: WireErrorCode
        var message: String
        var forcedRPM: Double?

        init(_ code: WireErrorCode, _ message: String, forcedRPM: Double? = nil) {
            self.code = code
            self.message = message
            self.forcedRPM = forcedRPM
        }
    }

    public let config: HelperConfig
    public private(set) var topology = FanTopology()
    public private(set) var lastError: String?

    private let smc: SMCClient
    private let hotSet: HotSetProvider
    private let writer: FanWriter
    private let clock: () -> TimeInterval
    /// Hardware model used for fan display names; nil keeps the generic "Fan N" (tests).
    private let modelIdentifier: String?

    private var holds: [Int: Hold] = [:]
    private var connections: [Int: ConnectionState] = [:]
    private var failsafe: FailsafeMonitor
    private var lastHotReading: HotSetReading?
    private var lastHotSampleAt: TimeInterval?
    private var cooldownUntil: [Int: TimeInterval] = [:]
    private var shuttingDown = false
    private var rediscoveryDue: TimeInterval?
    private var rediscoveryAttempts = 0

    /// - Parameters:
    ///   - failsafeTestC: lowers the failsafe trigger below the usual 85 C floor (never above the
    ///     configured value) to test the failsafe on real hardware. Nil in normal operation.
    ///   - clock: monotonic seconds; defaults to the system uptime.
    ///   - sleep: used by the writer's retry back-off; tests pass a no-op.
    public init(smc: SMCClient,
                hotSet: HotSetProvider,
                config: HelperConfig,
                retry: RetryPolicy = .standard,
                failsafeTestC: Double? = nil,
                model: String? = nil,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        let config = config.normalized()
        self.smc = smc
        self.hotSet = hotSet
        self.config = config
        self.clock = clock
        self.modelIdentifier = model
        if let test = failsafeTestC, test.isFinite, test >= 40, test < config.failsafeTempC {
            self.failsafe = FailsafeMonitor(triggerC: test, floorC: 40)
            HelperLog.warning("FAILSAFE TEST MODE: the failsafe trips at \(Int(test)) C instead of \(Int(config.failsafeTempC)) C")
        } else {
            self.failsafe = FailsafeMonitor(triggerC: config.failsafeTempC)
        }
        self.writer = FanWriter(smc: smc, topology: FanTopology(), retry: retry, sleep: sleep)
    }

    // MARK: - Lifecycle

    /// Discovers fans and sensors, then returns every fan to auto: whatever a previous run (or a
    /// crash) left behind is undone before the first client can connect (docs/SPEC.md 4.5 #4).
    public func start() {
        topology = FanTopology.discover(smc: smc, model: modelIdentifier)
        writer.updateTopology(topology)
        // Release FIRST. Everything after this (sensor enumeration walks thousands of SMC keys and
        // opens HID services) may stall or crash, and a launchd restart loop must still free the fans.
        let touched = writer.releaseStaleState(reason: "startup")
        if !touched.isEmpty { HelperLog.warning("startup: returned fans \(touched) to auto") }

        if topology.isMonitorOnly {
            HelperLog.warning("monitor only: \(topology.monitorReason ?? "no controllable fan")")
        }
        for fan in topology.fans {
            HelperLog.info("fan \(fan.index): \(fan.backend.kind) \(fan.modeKey ?? "-") limits \(Int(fan.minRPM))...\(Int(fan.maxRPM)) RPM\(fan.hasFtst ? " Ftst" : "")")
        }
        hotSet.refresh()
    }

    /// Releases everything and refuses all further control. Called on SIGTERM and friends.
    public func shutdown(reason: String) {
        shuttingDown = true
        releaseEverything(reason: reason)
    }

    public var isShuttingDown: Bool { shuttingDown }

    /// `kIOMessageSystemWillSleep`: fans go back to auto before the machine sleeps (SPEC 4.5 #5).
    public func systemWillSleep() {
        HelperLog.info("system will sleep")
        releaseEverything(reason: "system sleep")
        failsafe.reset()
    }

    /// `kIOMessageSystemHasPoweredOn`: undo anything the firmware left in manual mode right away
    /// (a mode-byte read plus, only if needed, a write of 0), and schedule the fan re-discovery a few
    /// seconds later. The client re-takes control itself.
    public func systemDidWake() {
        HelperLog.info("system did wake")
        failsafe.reset()
        lastHotReading = nil
        lastHotSampleAt = nil
        let touched = writer.releaseStaleState(reason: "wake")
        if !touched.isEmpty { HelperLog.warning("wake: returned fans \(touched) to auto") }
        hotSet.refresh()
        rediscoveryAttempts = 0
        rediscoveryDue = clock() + Self.wakeRediscoveryDelaySeconds
    }

    /// Re-runs fan discovery after wake. A fan that was controllable before and looks unusable now is
    /// kept as it was: the hardware did not change during sleep, so a failed read is far more likely
    /// than a broken fan, and replacing the topology would silently end manual control until the next
    /// sleep or restart. After a few retries the fresh result is accepted (a fan that stays broken).
    private func rediscoverAfterWake(now: TimeInterval) {
        let fresh = FanTopology.discover(smc: smc, model: modelIdentifier)
        var accepted = fresh
        var regressed: [Int] = []
        if rediscoveryAttempts < Self.maxRediscoveryAttempts {
            for old in topology.fans where old.backend.canControl {
                if fresh.fan(old.index)?.backend.canControl != true { regressed.append(old.index) }
            }
            if !regressed.isEmpty { accepted = Self.keeping(regressed, from: topology, in: fresh) }
        }
        topology = accepted
        writer.updateTopology(accepted)

        if regressed.isEmpty || rediscoveryAttempts >= Self.maxRediscoveryAttempts {
            if rediscoveryAttempts >= Self.maxRediscoveryAttempts, fresh != accepted || fresh.isMonitorOnly {
                HelperLog.warning("wake: fan discovery still disagrees with the earlier result; using the new one")
            }
            rediscoveryDue = nil
        } else {
            rediscoveryAttempts += 1
            HelperLog.warning("wake: fans \(regressed) looked unusable after wake; keeping them and retrying discovery (\(rediscoveryAttempts)/\(Self.maxRediscoveryAttempts))")
            rediscoveryDue = now + Self.wakeRediscoveryDelaySeconds * Double(rediscoveryAttempts)
        }
    }

    private static func keeping(_ indices: [Int], from old: FanTopology, in fresh: FanTopology) -> FanTopology {
        var merged = fresh
        for index in indices {
            guard let fan = old.fan(index) else { continue }
            if let position = merged.fans.firstIndex(where: { $0.index == index }) {
                merged.fans[position] = fan
            } else {
                merged.fans.append(fan)
            }
            merged.unusableReasons[index] = nil
        }
        merged.fans.sort { $0.index < $1.index }
        merged.hasFtst = old.hasFtst || fresh.hasFtst
        merged.hasDICT = old.hasDICT || fresh.hasDICT
        merged.reportedFanCount = max(old.reportedFanCount, fresh.reportedFanCount)
        merged.discoveryNote = nil
        return merged
    }

    // MARK: - Introspection

    public var connectionCount: Int { connections.count }
    public var failsafeStatus: FailsafeStatus { failsafe.status }
    public var fanWriter: FanWriter { writer }

    public var holdList: [HoldInfo] {
        holds.keys.sorted().map { fan in
            let hold = holds[fan]!
            return HoldInfo(fan: fan, owner: hold.owner, clientRPM: hold.clientRPM, leaseExpiry: hold.leaseExpiry)
        }
    }

    /// How often `tick()` should run: nil means no timer at all (idle).
    public var desiredTickInterval: TimeInterval? {
        if shuttingDown { return nil }
        // A pending hot sample is confirmed (or refuted) at the fast rate, even with no fan held.
        if !holds.isEmpty || failsafe.isHot || failsafe.isConfirming
            || !writer.pendingReleases.isEmpty || rediscoveryDue != nil {
            return Self.activeTickSeconds
        }
        return connections.isEmpty ? nil : Self.idleTickSeconds
    }

    // MARK: - Connections

    public func connectionOpened(_ id: Int) {
        connections[id] = ConnectionState()
    }

    /// The socket closed (EOF or error): everything this connection controlled goes back to auto.
    public func connectionClosed(_ id: Int) {
        connections[id] = nil
        releaseHolds(ownedBy: id, reason: "client disconnected")
        // With nobody left to protect or to answer, a half-confirmed hot sample is just history: the
        // next client's first sample must not be paired with it, however long the pause.
        if connections.isEmpty, holds.isEmpty { failsafe.forgetPendingConfirmation() }
    }

    // MARK: - Requests

    public func handle(_ request: WireRequest, from connection: Int) -> Outcome {
        let op = request.command.op
        func fail(_ error: HandlerError, close: Bool = false) -> Outcome {
            Outcome(reply: .failure(id: request.id, op: op, code: error.code, message: error.message,
                                    forcedRPM: error.forcedRPM),
                    closeConnection: close)
        }

        guard var state = connections[connection] else {
            return fail(HandlerError(.badRequest, "unknown connection"), close: true)
        }

        if case .hello(let proto, let client) = request.command {
            guard proto == Constants.protocolVersion else {
                return fail(HandlerError(.badRequest,
                                         "unsupported protocol version \(proto); this helper speaks \(Constants.protocolVersion)"),
                            close: true)
            }
            state.helloDone = true
            state.client = client
            connections[connection] = state
            HelperLog.debug("connection \(connection) hello from \"\(client)\"")
            return Outcome(reply: .success(id: request.id, body: .hello(helloReply())), closeConnection: false)
        }
        guard state.helloDone else {
            return fail(HandlerError(.badRequest, "hello must be the first message"), close: true)
        }

        do {
            try request.validate()
            let body = try perform(request.command, from: connection)
            var reply = WireReply.success(id: request.id, body: body.body)
            reply.msg = body.note
            return Outcome(reply: reply, closeConnection: body.close)
        } catch let error as HandlerError {
            return fail(error)
        } catch let error as FanWriterError {
            recordError("\(op.rawValue): \(error)")
            return fail(HandlerError(error.wireCode, error.description))
        } catch let error as WireError {
            return fail(HandlerError(.badRequest, error.description))
        } catch {
            recordError("\(op.rawValue): \(error)")
            return fail(HandlerError(.ioError, "\(error)"))
        }
    }

    private struct Performed {
        var body: WireReplyBody
        var note: String?
        var close = false
    }

    private func perform(_ command: WireCommand, from connection: Int) throws -> Performed {
        let now = clock()
        switch command {
        case .hello:
            return Performed(body: .hello(helloReply()))   // handled earlier; unreachable in practice

        case .status:
            return Performed(body: .status(statusReply(now: now)))

        case .set(let fan, let rpm, let ttl):
            let result = try applySet(fan: fan, rpm: rpm, ttl: ttl, connection: connection, now: now)
            return Performed(body: .set(result))

        case .setAll(let rpms, let ttl):
            return Performed(body: .setAll(try applySetAll(rpms, ttl: ttl, connection: connection, now: now)))

        case .auto(let selector):
            return try applyAuto(selector, now: now)

        case .heartbeat(let ttl):
            let expiry = now + effectiveTTL(ttl)
            var owned: [Int] = []
            for fan in holds.keys.sorted() where holds[fan]?.owner == connection {
                holds[fan]?.leaseExpiry = expiry
                owned.append(fan)
            }
            return Performed(body: .heartbeat(owned: owned))

        case .bye:
            releaseHolds(ownedBy: connection, reason: "client said bye")
            return Performed(body: .bye, close: true)
        }
    }

    // MARK: set / setAll / auto

    private func effectiveTTL(_ requested: Double?) -> TimeInterval {
        min(requested ?? Constants.defaultLeaseSeconds, config.leaseMaxSeconds)
    }

    private func requireControllable(_ fan: Int) throws -> FanInfo {
        guard let info = topology.fan(fan) else {
            throw HandlerError(.noSuchFan, "this Mac has no fan \(fan)")
        }
        guard info.backend.canControl else {
            throw HandlerError(.monitorOnly, "fan \(fan) cannot be controlled: \(topology.unusableReasons[fan] ?? "no backend")")
        }
        return info
    }

    /// Everything that can forbid new control, checked before any hardware is touched.
    /// - Parameter sample: take a fresh hot-set sample when this would start a control session.
    ///   `setAll` passes true once per request: its later gates would only re-read the same instant.
    private func gateControl(for info: FanInfo, now: TimeInterval, sample: Bool = true) throws {
        if shuttingDown { throw HandlerError(.ioError, "the helper is shutting down") }
        if let until = cooldownUntil[info.index], now < until {
            throw HandlerError(.modeRejected,
                               "os_override: the system keeps reverting fan \(info.index); try again in \(Int(until - now)) s")
        }
        if holds.isEmpty {
            // First fan of a new control session: look at the hot set before touching anything, so we
            // never start holding fans blind or while the machine is already past the failsafe.
            if sample { sampleHotSet(now: now) }
            if lastHotReading?.maxTempC == nil, !failsafe.isHot {
                throw HandlerError(.failsafeActive, "refusing to control fans: no hot-set temperature is readable")
            }
        }
        switch failsafe.state {
        case .hot:
            throw HandlerError(.failsafeActive,
                               "thermal failsafe active at \(String(format: "%.1f", failsafe.lastTempC ?? 0)) C; fans are forced to maximum",
                               forcedRPM: info.maxRPM)
        case .blind:
            throw HandlerError(.failsafeActive, "refusing to control fans: no hot-set temperature is readable")
        case .normal:
            break
        }
    }

    /// - Parameter gated: the caller already ran `gateControl` for this request (`setAll`).
    private func applySet(fan: Int, rpm: Double, ttl: Double?, connection: Int, now: TimeInterval,
                          gated: Bool = false) throws -> SetReply {
        let info = try requireControllable(fan)
        if !gated { try gateControl(for: info, now: now) }

        let write = try writer.takeover(fan: fan, rpm: rpm)
        let previous = holds[fan]
        if let previous, let oldOwner = previous.owner, oldOwner != connection {
            HelperLog.info("fan \(fan): control moves from connection \(oldOwner) to \(connection)")
        }
        holds[fan] = Hold(owner: connection,
                          clientRPM: write.applied,
                          leaseExpiry: now + effectiveTTL(ttl),
                          since: previous?.since ?? now)
        return SetReply(applied: write.applied, clamped: write.clamped)
    }

    private func applySetAll(_ rpms: [Double?], ttl: Double?, connection: Int, now: TimeInterval) throws -> [SetReply?] {
        // Check every entry before touching hardware so the common mistakes are all-or-nothing.
        var sampled = false
        for (fan, rpm) in rpms.enumerated() where rpm != nil {
            let info = try requireControllable(fan)
            try gateControl(for: info, now: now, sample: !sampled)
            sampled = true
        }
        var results: [SetReply?] = []
        for (fan, rpm) in rpms.enumerated() {
            guard let rpm else {
                results.append(nil)
                continue
            }
            do {
                results.append(try applySet(fan: fan, rpm: rpm, ttl: ttl, connection: connection, now: now, gated: true))
            } catch let error as HandlerError {
                throw HandlerError(error.code, "fan \(fan): \(error.message) (earlier fans in this request stay applied)",
                                   forcedRPM: error.forcedRPM)
            } catch let error as FanWriterError {
                throw HandlerError(error.wireCode, "fan \(fan): \(error) (earlier fans in this request stay applied)")
            }
        }
        return results
    }

    private func applyAuto(_ selector: FanSelector, now: TimeInterval) throws -> Performed {
        let fans: [Int]
        switch selector {
        case .all:
            // Recovery must not depend on discovery's verdict: include fans that only have a mode key.
            fans = writer.recoveryIndices()
        case .fan(let fan):
            if !writer.canRecover(fan: fan) { _ = try requireControllable(fan) }
            fans = [fan]
        }

        var released: [Int] = []
        var stuck: [String] = []
        var heldByFailsafe = false
        for fan in fans {
            if failsafe.isHot, let hold = holds[fan] {
                // The client lets go, but the failsafe keeps the fan at maximum until it clears.
                if hold.owner != nil { released.append(fan) }
                holds[fan]?.owner = nil
                holds[fan]?.clientRPM = nil
                holds[fan]?.leaseExpiry = nil
                heldByFailsafe = true
                continue
            }
            holds[fan] = nil
            // `auto` is also the recovery command: a fan we have no record of but whose mode is not
            // auto (left over from a crash, or set by hand) is returned to auto too.
            let outcome = writer.isOwned(fan)
                ? writer.release(fan: fan, reason: "auto requested")
                : writer.forceRelease(fan: fan, reason: "auto requested (recovery)")
            switch outcome {
            case .released?: released.append(fan)
            case .pending(let detail)?: stuck.append("fan \(fan): \(detail)")
            case .notOwned?, nil: break
            }
        }
        if !stuck.isEmpty {
            let message = "could not return to auto, retrying every second: " + stuck.joined(separator: "; ")
            recordError(message)
            throw HandlerError(.ioError, message)
        }
        let note = heldByFailsafe ? "thermal failsafe is active: fans stay at maximum until the temperature drops" : nil
        return Performed(body: .auto(released: released), note: note)
    }

    // MARK: Replies

    private func helloReply() -> HelloReply {
        HelloReply(fans: topology.fans,
                   failsafeTempC: failsafe.triggerC,
                   leaseMaxS: config.leaseMaxSeconds,
                   monitorOnly: topology.isMonitorOnly,
                   monitorReason: topology.monitorReason)
    }

    private func statusReply(now: TimeInterval) -> StatusReply {
        var fans: [FanStatus] = []
        for info in topology.fans {
            let hold = holds[info.index]
            let remain = max(0, (hold?.leaseExpiry ?? now) - now)
            let owned = writer.isOwned(info.index)
            do {
                let reading = try FanKeyReader.reading(smc: smc, fan: info)
                fans.append(FanStatus(reading: reading, owned: owned, leaseRemainS: remain))
            } catch {
                recordError("status: fan \(info.index): \(error)")
                fans.append(FanStatus(index: info.index, actualRPM: 0, targetRPM: 0, mode: 0,
                                      minRPM: info.minRPM, maxRPM: info.maxRPM, owned: owned, leaseRemainS: remain))
            }
        }
        var dict: Int?
        if topology.hasDICT, let flag = FanKeyReader.dictFlag(smc: smc) { dict = flag ? 1 : 0 }
        return StatusReply(fans: fans, failsafe: failsafe.status, lastError: lastError, dict: dict)
    }

    // MARK: - Maintenance tick

    /// The 1 Hz (or 5 s) maintenance pass: failsafe, leases, reassertion, pending releases.
    public func tick() {
        guard !shuttingDown else { return }
        let now = clock()

        if let due = rediscoveryDue, now >= due { rediscoverAfterWake(now: now) }

        // 1. Failsafe first: it overrides everything else.
        let sampleDue = lastHotSampleAt.map { now - $0 >= Self.idleTickSeconds - 0.5 } ?? true
        let watching = !holds.isEmpty || failsafe.isHot || failsafe.isConfirming || (!connections.isEmpty && sampleDue)
        if watching { sampleHotSet(now: now) }
        if failsafe.isHot { forceMissingFansToMaximum(now: now) }

        // 2. Leases: a client that stopped talking loses its fans.
        for fan in holds.keys.sorted() {
            guard let hold = holds[fan], let expiry = hold.leaseExpiry, now >= expiry else { continue }
            if failsafe.isHot {
                HelperLog.info("fan \(fan): client lease expired during failsafe; failsafe keeps the fan")
                holds[fan]?.owner = nil
                holds[fan]?.clientRPM = nil
                holds[fan]?.leaseExpiry = nil
            } else {
                HelperLog.warning("fan \(fan): lease expired, returning to auto")
                holds[fan] = nil
                writer.release(fan: fan, reason: "lease expired")
            }
        }

        // 3. Reassertion with anti-fight. In failsafe the point is to hold maximum, so never give up.
        let outcomes = writer.reassertAll(now: now, allowOverrideRelease: !failsafe.isHot)
        for (fan, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
            switch outcome {
            case .overrideDetected(let corrections):
                holds[fan] = nil
                cooldownUntil[fan] = now + Self.overrideCooldownSeconds
                recordError("os_override: the system reverted fan \(fan) \(corrections) times in \(Int(FanWriter.fightWindow)) s; released to auto")
            case .correctionFailed(let detail), .readFailed(let detail):
                recordError("fan \(fan): \(detail)")
            case .ok, .notOwned, .skippedDICT, .corrected:
                break
            }
        }

        // 4. Releases that did not stick are retried until they do.
        writer.retryPendingReleases()

        // A hold without hardware ownership is a lie; drop it so heartbeats tell the truth.
        for fan in Array(holds.keys) where !writer.isOwned(fan) { holds[fan] = nil }
    }

    // MARK: - Failsafe plumbing

    private func sampleHotSet(now: TimeInterval) {
        let reading = hotSet.read()
        lastHotReading = reading
        lastHotSampleAt = now
        let transition = failsafe.update(now: now, hotMax: reading.maxTempC, controlling: !holds.isEmpty)
        guard let transition else { return }

        switch transition {
        case .enteredHot(let temp):
            HelperLog.critical("FAILSAFE: \(reading.hottest ?? "hot set") at \(String(format: "%.1f", temp)) C >= \(Int(failsafe.triggerC)) C, forcing all fans to maximum")
            recordError("failsafe: \(String(format: "%.1f", temp)) C, fans forced to maximum")
            forceMissingFansToMaximum(now: now)
        case .cleared:
            HelperLog.warning("failsafe cleared (hot set below \(Int(failsafe.clearBelowC)) C for \(Int(FailsafeMonitor.clearHoldSeconds)) s)")
            restoreAfterFailsafe(now: now)
        case .enteredBlind:
            HelperLog.error("no hot-set temperature readable for \(Int(FailsafeMonitor.blindSeconds)) s: returning all fans to auto")
            recordError("blind: no hot-set temperature readable, fans returned to auto")
            releaseEverything(reason: "blind (no temperature readable)")
        case .recoveredFromBlind:
            HelperLog.info("hot-set temperature readable again")
        }
    }

    /// Makes sure every controllable fan is held at its live maximum.
    private func forceMissingFansToMaximum(now: TimeInterval) {
        guard !shuttingDown else { return }
        for info in topology.controllableFans {
            if isHeldAtMaximum(info) { continue }
            do {
                try writer.takeover(fan: info.index, rpm: info.maxRPM)
                if holds[info.index] == nil {
                    holds[info.index] = Hold(owner: nil, clientRPM: nil, leaseExpiry: nil, since: now)
                }
            } catch {
                recordError("failsafe could not force fan \(info.index) to maximum: \(error)")
                // Keeping a client's stale, possibly low, manual target while the machine is past the
                // failsafe temperature is the one outcome this code must not allow. The OS fan curve
                // is the better fallback; the next tick tries for maximum again.
                holds[info.index] = nil
                if writer.isOwned(info.index) {
                    writer.release(fan: info.index, reason: "failsafe could not reach maximum: \(error)")
                }
            }
        }
    }

    private func isHeldAtMaximum(_ info: FanInfo) -> Bool {
        guard let ownership = writer.ownership(of: info.index), !ownership.releasePending,
              let applied = ownership.appliedRPM,
              let limits = try? FanKeyReader.limits(smc: smc, fan: info.index) else { return false }
        return applied >= limits.max
    }

    /// The failsafe cleared: failsafe-only holds go back to auto, client holds go back to the
    /// client's target.
    private func restoreAfterFailsafe(now: TimeInterval) {
        for fan in holds.keys.sorted() {
            guard let hold = holds[fan] else { continue }
            if hold.owner != nil, let rpm = hold.clientRPM {
                do {
                    try writer.takeover(fan: fan, rpm: rpm)
                } catch {
                    recordError("fan \(fan): could not restore the client target after the failsafe: \(error)")
                }
            } else {
                holds[fan] = nil
                writer.release(fan: fan, reason: "failsafe cleared")
            }
        }
    }

    // MARK: - Release helpers

    private func releaseHolds(ownedBy connection: Int, reason: String) {
        for fan in holds.keys.sorted() where holds[fan]?.owner == connection {
            if failsafe.isHot {
                holds[fan]?.owner = nil
                holds[fan]?.clientRPM = nil
                holds[fan]?.leaseExpiry = nil
            } else {
                holds[fan] = nil
                writer.release(fan: fan, reason: reason)
            }
        }
    }

    private func releaseEverything(reason: String) {
        holds.removeAll()
        writer.releaseAll(reason: reason)
    }

    private func recordError(_ message: String) {
        lastError = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        HelperLog.debug("lastError: \(message)")
    }
}
