import FanPilotKit
import Foundation

// The only code in FanPilot that writes fan keys (docs/SPEC.md 2.7 - 2.9).
//
// Safety properties, all enforced here and covered by tests against a mock SMC:
//  - Every write goes through `writeKey`, which only accepts the keys this fan's backend needs
//    (target, mode byte, `Ftst`, `FS! `). `F<n>Mn` / `F<n>Mx` can never be written.
//  - Every target is clamped to the fan's LIVE `[F<n>Mn, F<n>Mx]`; callers cannot supply limits.
//  - Every write is read back. The SMC can accept a write of the wrong size and silently do
//    nothing; here a mismatch throws and a value that does not stick is an error.
//  - Release writes the mode byte (back to auto) FIRST and verifies it; nothing else matters if that
//    fails, so a failed release stays "pending" and is retried until it works.
//  - A fan that was switched to manual mode but never received its target is switched back to auto
//    immediately: manual mode with a zero target would stop the fan.
//
// A `FanWriter` is NOT thread-safe. The helper drives it from one serial queue.

// MARK: - Errors

public enum FanWriterError: Error, Equatable, Sendable, CustomStringConvertible {
    case noSuchFan(Int)
    /// The fan has no usable backend (monitor-only).
    case notControllable(fan: Int, reason: String)
    case invalidRPM(Double)
    /// `F<n>Mn` / `F<n>Mx` could not be read or look implausible; without limits nothing is written.
    case limitsUnavailable(fan: Int, detail: String)
    /// The mode byte (or `FS! ` bit) would not stick. `detail` includes the SMC result byte if any.
    case modeRejected(fan: Int, detail: String)
    /// The target would not stick (or cannot be encoded).
    case targetRejected(fan: Int, detail: String)
    case notOwned(fan: Int)
    /// Internal guard: an attempt to write a key the fan's backend does not use.
    case forbiddenKey(FourCC)

    public var description: String {
        switch self {
        case .noSuchFan(let i): return "no fan \(i)"
        case .notControllable(let i, let why): return "fan \(i) cannot be controlled: \(why)"
        case .invalidRPM(let v): return "invalid RPM value \(v)"
        case .limitsUnavailable(let i, let why): return "fan \(i) limits unavailable: \(why)"
        case .modeRejected(let i, let why): return "fan \(i) rejected manual mode: \(why)"
        case .targetRejected(let i, let why): return "fan \(i) rejected the target: \(why)"
        case .notOwned(let i): return "fan \(i) is not under FanPilot control"
        case .forbiddenKey(let k): return "refusing to write \(k): not a key this backend uses"
        }
    }

    /// The protocol error code a client sees for this failure.
    public var wireCode: WireErrorCode {
        switch self {
        case .noSuchFan: return .noSuchFan
        case .notControllable: return .monitorOnly
        case .invalidRPM: return .badRequest
        case .limitsUnavailable: return .ioError
        case .modeRejected: return .modeRejected
        case .targetRejected: return .targetRejected
        case .notOwned: return .ioError
        case .forbiddenKey: return .ioError
        }
    }
}

// MARK: - Policy and results

/// How hard the writer tries before giving up (docs/SPEC.md 2.7 / 2.8). Tests inject a no-op
/// sleeper; the production values are the specified ones.
public struct RetryPolicy: Equatable, Sendable {
    public var modeAttempts = 8
    public var modeBackoff: TimeInterval = 0.25
    public var targetAttempts = 3
    public var targetBackoff: TimeInterval = 0.1
    public var releaseAttempts = 5
    public var releaseBackoff: TimeInterval = 0.2
    /// Attempts for re-asserting a mode the OS reverted; short, because this runs every second.
    public var reassertAttempts = 3
    public var reassertBackoff: TimeInterval = 0.1

    public init() {}
    public static let standard = RetryPolicy()
}

/// Result of a successful takeover or retarget.
public struct FanWrite: Equatable, Sendable {
    public var requested: Double
    public var applied: Double
    public var clamped: Bool
    public var minRPM: Double
    public var maxRPM: Double

    public init(requested: Double, applied: Double, clamped: Bool, minRPM: Double, maxRPM: Double) {
        self.requested = requested
        self.applied = applied
        self.clamped = clamped
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

public enum ReleaseOutcome: Equatable, Sendable {
    case released
    /// Nothing to release (the fan was not owned).
    case notOwned
    /// The mode byte would not go back to auto; it is retried by `retryPendingReleases`.
    case pending(detail: String)
}

public enum ReassertOutcome: Equatable, Sendable {
    case ok
    case notOwned
    /// `DICT` says the OS is ducking the fans; we do not fight it.
    case skippedDICT
    case readFailed(String)
    /// The OS had changed mode or target; we wrote them back.
    case corrected(String)
    case correctionFailed(String)
    /// The OS keeps reverting us (10 corrections within 60 s); the fan was released to auto.
    case overrideDetected(corrections: Int)
}

/// What the writer remembers about a fan it controls.
public struct HardwareOwnership: Equatable, Sendable {
    public let fan: Int
    /// Mode byte before our first write (informational; release always goes to auto).
    public var originalMode: UInt8?
    /// Raw bytes of `F<n>Tg` before our first write; written back best-effort after release.
    public var originalTarget: [UInt8]?
    /// We attempted to write `F<n>Tg` (so release has something to put back).
    public var targetWritten = false
    /// The target we last wrote and verified; the reassertion loop compares against it.
    public var appliedRPM: Double?
    /// Times of recent corrections (anti-fight, docs/SPEC.md 2.9).
    public var correctionTimes: [TimeInterval] = []
    /// The release to auto did not stick yet.
    public var releasePending = false
}

// MARK: - Writer

public final class FanWriter {
    /// Corrections within `fightWindow` that count as the OS fighting us.
    public static let fightLimit = 10
    public static let fightWindow: TimeInterval = 60
    /// Reassertion tolerance in RPM (docs/SPEC.md 2.9).
    public static let reassertToleranceRPM = 2.0
    /// A written target must read back within this many RPM (docs/SPEC.md 2.7 step 4).
    public static let readbackToleranceRPM = 1.0

    public let smc: SMCClient
    public private(set) var topology: FanTopology
    public var retry: RetryPolicy

    private let sleeper: (TimeInterval) -> Void
    private var owned: [Int: HardwareOwnership] = [:]
    /// We wrote `Ftst = 1` and have not reset it yet.
    private var ftstActive = false
    private var dictSkipLogged = false

    public init(smc: SMCClient, topology: FanTopology, retry: RetryPolicy = .standard,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.smc = smc
        self.topology = topology
        self.retry = retry
        self.sleeper = sleep
    }

    /// Replaces the topology after re-discovery (wake). Ownership records are kept.
    public func updateTopology(_ topology: FanTopology) {
        self.topology = topology
    }

    // MARK: Inspection

    public var ownedFans: [Int] { owned.keys.sorted() }

    public func isOwned(_ fan: Int) -> Bool { owned[fan] != nil }

    public func ownership(of fan: Int) -> HardwareOwnership? { owned[fan] }

    public var pendingReleases: [Int] {
        owned.filter { $0.value.releasePending }.keys.sorted()
    }

    // MARK: Limits

    /// Clamps `rpm` to the fan's live limits. `clamped` is true only if the (integer-rounded) request
    /// had to move; rounding alone is not clamping.
    public func clamp(fan index: Int, rpm: Double) throws -> FanWrite {
        _ = try controllableFan(index)
        guard rpm.isFinite, rpm >= 0 else { throw FanWriterError.invalidRPM(rpm) }
        let limits = try FanKeyReader.limits(smc: smc, fan: index)
        let rounded = rpm.rounded()
        let applied = min(max(rounded, limits.min), limits.max)
        return FanWrite(requested: rpm, applied: applied, clamped: applied != rounded,
                        minRPM: limits.min, maxRPM: limits.max)
    }

    // MARK: Takeover (docs/SPEC.md 2.7)

    /// Puts the fan in manual mode (steps 0, 2 and 3) without setting a target. Used by `takeover`
    /// and by the Phase 0 self-test, which needs the mode flip on its own.
    ///
    /// On failure a fan that was not owned before is released again before the error is thrown.
    public func engageManualMode(fan index: Int) throws {
        let info = try controllableFan(index)
        try finishPendingRelease(info)
        try engage(info, attempts: retry.modeAttempts, backoff: retry.modeBackoff)
    }

    /// Takes over (or retargets) a fan: clamp, manual mode, target, read back. Idempotent: if the
    /// fan is already ours and still in manual mode the mode write is skipped.
    @discardableResult
    public func takeover(fan index: Int, rpm: Double) throws -> FanWrite {
        let info = try controllableFan(index)
        let plan = try clamp(fan: index, rpm: rpm)
        try finishPendingRelease(info)
        let wasOwned = owned[index] != nil

        // The app re-sends its target every heartbeat to renew the lease. When the hardware already
        // holds exactly that target there is nothing to write: rewriting would only add SMC traffic
        // and a log line every 5 s for as long as a fixed speed is held.
        if wasOwned, owned[index]?.appliedRPM == plan.applied, isHolding(info, rpm: plan.applied) {
            HelperLog.debug("fan \(index): target \(Int(plan.applied)) RPM already in place")
            return plan
        }

        try engage(info, attempts: retry.modeAttempts, backoff: retry.modeBackoff)
        do {
            try writeTarget(info, rpm: plan.applied)
        } catch {
            // Manual mode with the wrong (probably zero) target could stop the fan: back to auto now.
            if !wasOwned {
                _ = release(fan: index, reason: "takeover failed after mode switch: \(error)")
            }
            throw error
        }
        owned[index]?.appliedRPM = plan.applied
        HelperLog.info("fan \(index): target \(Int(plan.applied)) RPM (requested \(rpm), limits \(Int(plan.minRPM))...\(Int(plan.maxRPM)))")
        return plan
    }

    /// Retargets a fan that is already ours.
    @discardableResult
    public func setTarget(fan index: Int, rpm: Double) throws -> FanWrite {
        guard owned[index] != nil else { throw FanWriterError.notOwned(fan: index) }
        return try takeover(fan: index, rpm: rpm)
    }

    // MARK: Release (docs/SPEC.md 2.8)

    /// Returns a fan to system control. Writes the mode byte to auto FIRST and verifies it; never throws.
    /// - Parameter attempts: overrides the retry count (the periodic retry uses one).
    @discardableResult
    public func release(fan index: Int, reason: String, attempts: Int? = nil) -> ReleaseOutcome {
        guard var record = owned[index] else { return .notOwned }
        // Releasing never depends on discovery's verdict: a fan that was downgraded to monitor-only
        // after we took it (a failed limit read after wake, FBAD) still has to go back to auto.
        guard let info = recoveryInfo(for: index) else {
            HelperLog.warning("fan \(index): no mode key left to release; dropping the ownership record")
            owned[index] = nil
            return .notOwned
        }
        if record.releasePending {
            HelperLog.debug("fan \(index): releasing to auto (\(reason))")   // a retry: keep the log quiet
        } else {
            HelperLog.info("fan \(index): releasing to auto (\(reason))")
        }

        // 1. Mode back to auto, verified. Nothing is more important than this write. If the fan
        // already reads as auto (a takeover whose mode write never stuck) there is nothing to undo,
        // and hammering a key that refuses writes would only leave a release "pending" forever.
        let result: String?
        if FanKeyReader.mode(smc: smc, fan: info) == 0 {
            result = nil
        } else {
            result = retrying(attempts ?? retry.releaseAttempts, backoff: retry.releaseBackoff) { _ in
                try self.writeMode(info, manual: false)
                let mode = FanKeyReader.mode(smc: self.smc, fan: info)
                return mode == 0 ? nil : "mode reads \(mode.map(String.init) ?? "unreadable") after writing auto"
            }
        }
        if let failure = result {
            let firstFailure = !record.releasePending
            record.releasePending = true
            owned[index] = record
            // Logged loudly once; the 1 Hz retries stay quiet so a stuck key cannot flood the log.
            if firstFailure {
                HelperLog.critical("fan \(index): cannot return to auto (\(failure)); will keep retrying")
            } else {
                HelperLog.debug("fan \(index): release still pending (\(failure))")
            }
            return .pending(detail: failure)
        }

        // 2. Best effort: put the pre-takeover target back. The firmware ignores it in auto mode.
        // Only if we wrote one: a failed takeover that never got that far leaves the key alone.
        if record.targetWritten, let original = record.originalTarget, let tgKey = SMCKeys.fan(index, .target) {
            do { try writeKey(tgKey, original, fan: info) } catch {
                HelperLog.debug("fan \(index): could not restore original target: \(error)")
            }
        }
        owned[index] = nil

        // 3. Last fan out: undo the Ftst unlock we set.
        if ftstActive, owned.isEmpty, info.hasFtst {
            do {
                try writeKey(SMCKeys.fanTest, [0], fan: info)
                ftstActive = false
            } catch {
                HelperLog.warning("could not reset Ftst: \(error)")
            }
        }
        return .released
    }

    @discardableResult
    public func releaseAll(reason: String) -> [Int: ReleaseOutcome] {
        var outcomes: [Int: ReleaseOutcome] = [:]
        for index in ownedFans {
            outcomes[index] = release(fan: index, reason: reason)
        }
        return outcomes
    }

    /// Releases a fan we have no record of if its hardware mode is not auto (or cannot be read).
    /// This is the startup / `auto all` recovery path after a crash that left a fan in manual mode.
    /// - Returns: nil if the fan was already in auto and nothing was written.
    @discardableResult
    public func forceRelease(fan index: Int, reason: String) -> ReleaseOutcome? {
        if owned[index] != nil { return release(fan: index, reason: reason) }
        guard let info = recoveryInfo(for: index) else { return nil }
        if FanKeyReader.mode(smc: smc, fan: info) == 0 { return nil }
        owned[index] = HardwareOwnership(fan: index)
        return release(fan: index, reason: reason)
    }

    /// Startup and recovery: every fan that has a mode key and is not in auto goes back to auto, and a
    /// leftover `Ftst = 1` is cleared. Returns the fans that needed it.
    ///
    /// This deliberately does not look at `topology.controllableFans`. Writing mode 0 is always safe,
    /// and the fans that discovery distrusts (an unreadable limit, FBAD, a missing target key) are
    /// exactly the ones that may be stuck in manual mode.
    @discardableResult
    public func releaseStaleState(reason: String) -> [Int] {
        var touched: [Int] = []
        for index in recoveryIndices() where forceRelease(fan: index, reason: reason) != nil {
            touched.append(index)
        }
        if owned.isEmpty,
           let value = try? smc.read(SMCKeys.fanTest), value.bytes == [1],
           let key = try? smc.keyInfo(SMCKeys.fanTest), key.type == .ui8, key.size == 1, key.isWritable {
            // Only we ever set Ftst (as part of a takeover), so a stale 1 is ours to clear.
            do {
                try smc.write(SMCKeys.fanTest, bytes: [0])
                HelperLog.info("cleared leftover Ftst")
            } catch {
                HelperLog.warning("could not clear leftover Ftst: \(error)")
            }
        }
        return touched
    }

    /// Fan indices worth checking for a stuck mode byte: `FNum` (at most ten), or all ten single-digit
    /// slots if `FNum` cannot be read. Never relies on discovery.
    public func recoveryIndices() -> [Int] {
        var count = Constants.maxFanIndex + 1
        if let n = try? smc.readNumber(SMCKeys.fanCount), n.isFinite, n >= 1, n <= 64 {
            count = min(Int(n), Constants.maxFanIndex + 1)
        }
        let known = topology.fans.map(\.index)
        return Array(Set(Array(0..<count) + known + owned.keys)).filter { $0 >= 0 && $0 <= Constants.maxFanIndex }.sorted()
    }

    /// True if a mode key exists for this fan, so that `forceRelease` can put it back to auto.
    public func canRecover(fan index: Int) -> Bool { recoveryInfo(for: index) != nil }

    /// What is needed to write "auto" for a fan: the discovered backend if it is usable, else a
    /// backend derived directly from the live key infos (writable one-byte `md` / `Md`, or `FS! `).
    private func recoveryInfo(for index: Int) -> FanInfo? {
        let known = topology.fan(index)
        if let known, known.backend.canControl { return known }
        guard (0...Constants.maxFanIndex).contains(index) else { return nil }
        func make(_ backend: FanBackend) -> FanInfo {
            FanInfo(index: index, name: known?.name ?? "Fan \(index + 1)", minRPM: known?.minRPM ?? 0,
                    maxRPM: known?.maxRPM ?? 0, backend: backend, hasFtst: false)
        }
        for suffix in [SMCKeys.FanSuffix.modeLower, .modeUpper] {
            if let key = SMCKeys.fan(index, suffix), let info = try? smc.keyInfo(key),
               info.type == .ui8, info.size == 1, info.isWritable {
                return make(.appleSiliconMd(modeKey: key.string))
            }
        }
        // Plain Intel: the shared bitmask, but only for a fan discovery saw (it would be touched for nothing otherwise).
        if known != nil, let bits = try? smc.keyInfo(SMCKeys.fanForceBits), bits.size == 2, bits.isWritable {
            return make(.intelForced)
        }
        return nil
    }

    /// Retries releases that have not stuck yet (called every tick; one attempt each).
    @discardableResult
    public func retryPendingReleases() -> [Int: ReleaseOutcome] {
        var outcomes: [Int: ReleaseOutcome] = [:]
        for index in pendingReleases {
            outcomes[index] = release(fan: index, reason: "retrying pending release", attempts: 1)
        }
        return outcomes
    }

    // MARK: Reassertion (docs/SPEC.md 2.9)

    /// Checks every owned fan once. `DICT == 1` (the OS is ducking the fans) suspends all checks.
    @discardableResult
    public func reassertAll(now: TimeInterval, allowOverrideRelease: Bool = true) -> [Int: ReassertOutcome] {
        var outcomes: [Int: ReassertOutcome] = [:]
        let indices = ownedFans.filter { owned[$0]?.releasePending == false }
        guard !indices.isEmpty else { return outcomes }

        if topology.hasDICT, FanKeyReader.dictFlag(smc: smc) == true {
            if !dictSkipLogged {
                HelperLog.info("DICT is set: the OS is ducking the fans, not reasserting")
                dictSkipLogged = true
            }
            for index in indices { outcomes[index] = .skippedDICT }
            return outcomes
        }
        dictSkipLogged = false

        for index in indices {
            outcomes[index] = reassert(fan: index, now: now, allowOverrideRelease: allowOverrideRelease)
        }
        return outcomes
    }

    /// Compares mode and target with what we wrote; writes them back if the OS changed them.
    public func reassert(fan index: Int, now: TimeInterval, allowOverrideRelease: Bool = true) -> ReassertOutcome {
        guard let info = topology.fan(index), info.backend.canControl,
              var record = owned[index], !record.releasePending else { return .notOwned }
        guard let applied = record.appliedRPM else { return .ok }   // mode only, no target yet

        guard let mode = FanKeyReader.mode(smc: smc, fan: info) else {
            return .readFailed("cannot read the mode of fan \(index)")
        }
        // Raw read: a nonsense target (firmware garbage, another tool) must count as a mismatch we
        // correct, not as an unreadable key we ignore, and it must never reach an `Int(...)` conversion.
        let target: Double
        do {
            guard let tgKey = SMCKeys.fan(index, .target) else { return .readFailed("no target key for fan \(index)") }
            guard let raw = FanKeyReader.rawRPM(from: try smc.read(tgKey)) else {
                return .readFailed("fan \(index) target has no usable RPM value")
            }
            target = raw
        } catch {
            return .readFailed("\(error)")
        }

        let modeOK = mode == 1
        let targetOK = target.isFinite && abs(target - applied) <= Self.reassertToleranceRPM
        if modeOK && targetOK {
            return .ok
        }

        // The OS (or another tool) changed our settings. Count it; too many in a row means we lose.
        record.correctionTimes = record.correctionTimes.filter { now - $0 <= Self.fightWindow } + [now]
        owned[index] = record
        let corrections = record.correctionTimes.count
        let what = "mode \(mode) (want 1), target \(FanKeyReader.rpmText(target)) (want \(FanKeyReader.rpmText(applied)))"

        if allowOverrideRelease, corrections >= Self.fightLimit {
            HelperLog.error("fan \(index): the system keeps overriding us (\(corrections) corrections in \(Int(Self.fightWindow)) s, \(what)); giving up")
            _ = release(fan: index, reason: "os_override")
            return .overrideDetected(corrections: corrections)
        }

        HelperLog.warning("fan \(index): reasserting (\(what)), correction \(corrections)")
        do {
            if !modeOK { try engage(info, attempts: retry.reassertAttempts, backoff: retry.reassertBackoff) }
            try writeTarget(info, rpm: applied)
            return .corrected(what)
        } catch {
            return .correctionFailed("\(error)")
        }
    }

    // MARK: Internals

    /// A fan whose last release did not stick must get back to auto before it can be taken again.
    private func finishPendingRelease(_ info: FanInfo) throws {
        guard owned[info.index]?.releasePending == true else { return }
        if case .pending(let detail) = release(fan: info.index, reason: "finishing pending release before takeover") {
            throw FanWriterError.modeRejected(fan: info.index, detail: "previous release is still pending: \(detail)")
        }
    }

    private func controllableFan(_ index: Int) throws -> FanInfo {
        guard let info = topology.fan(index) else { throw FanWriterError.noSuchFan(index) }
        guard info.backend.canControl else {
            throw FanWriterError.notControllable(fan: index, reason: topology.unusableReasons[index] ?? "no backend")
        }
        return info
    }

    /// Steps 0, 2, 3 of the takeover sequence. Creates the ownership record (capturing the original
    /// values) before the first write. Releases the fan again if it was new and the mode would not stick.
    private func engage(_ info: FanInfo, attempts: Int, backoff: TimeInterval) throws {
        let index = info.index
        let isNew = owned[index] == nil
        if isNew {
            // 0. Capture the originals once per ownership, before anything is written.
            var record = HardwareOwnership(fan: index)
            record.originalMode = FanKeyReader.mode(smc: smc, fan: info)
            if let tg = SMCKeys.fan(index, .target) {
                record.originalTarget = try? smc.read(tg).bytes
            }
            if let mode = record.originalMode, mode != 0 {
                HelperLog.warning("fan \(index) was already in mode \(mode) before takeover (another tool?)")
            }
            owned[index] = record
        } else if FanKeyReader.mode(smc: smc, fan: info) == 1 {
            return   // already ours and still manual: skip the mode write
        }

        // 2. Older M-series: unlock test mode first (best effort; the mode write is what decides).
        if info.hasFtst { setFtst(info) }

        // 3. Manual mode, verified, with retries (thermalmonitord may reclaim it).
        let failure = retrying(attempts, backoff: backoff) { attempt in
            if attempt > 0, info.hasFtst { self.setFtst(info) }
            try self.writeMode(info, manual: true)
            let mode = FanKeyReader.mode(smc: self.smc, fan: info)
            return mode == 1 ? nil : "mode reads \(mode.map(String.init) ?? "unreadable") after writing manual"
        }
        if let failure {
            if isNew { _ = release(fan: index, reason: "mode_rejected") }
            throw FanWriterError.modeRejected(fan: index, detail: failure)
        }
    }

    private func setFtst(_ info: FanInfo) {
        do {
            try writeKey(SMCKeys.fanTest, [1], fan: info)
            ftstActive = true
        } catch {
            HelperLog.warning("could not write Ftst=1: \(error)")
        }
    }

    /// Writes the mode byte (Backend A) or flips this fan's bit in `FS! ` (Backend B).
    private func writeMode(_ info: FanInfo, manual: Bool) throws {
        switch info.backend {
        case .appleSiliconMd(let name):
            guard let key = FourCC(name) else { throw FanWriterError.forbiddenKey(SMCKeys.dict) }
            try writeKey(key, [manual ? 1 : 0], fan: info)
        case .intelForced:
            let value = try smc.read(SMCKeys.fanForceBits)
            guard let bits = SMCCodec.decodeUInt16(value.bytes) else {
                throw SMCError.invalidValue(key: SMCKeys.fanForceBits, reason: "expected two bytes")
            }
            let mask = UInt16(1) << UInt16(info.index)
            let updated = manual ? bits | mask : bits & ~mask
            if updated != bits {
                try writeKey(SMCKeys.fanForceBits, SMCCodec.encodeUInt16(updated), fan: info)
            }
        case .none:
            throw FanWriterError.notControllable(fan: info.index, reason: "no backend")
        }
    }

    /// True when the fan reads as manual with `rpm` as its target (within the readback tolerance).
    private func isHolding(_ info: FanInfo, rpm: Double) -> Bool {
        guard FanKeyReader.mode(smc: smc, fan: info) == 1,
              let key = SMCKeys.fan(info.index, .target),
              let value = try? smc.read(key),
              let now = FanKeyReader.rpm(from: value) else { return false }
        return abs(now - rpm) <= Self.readbackToleranceRPM
    }

    /// Writes the target and checks it reads back within 1 RPM (docs/SPEC.md 2.7 step 4).
    private func writeTarget(_ info: FanInfo, rpm: Double) throws {
        guard let key = SMCKeys.fan(info.index, .target) else { throw FanWriterError.noSuchFan(info.index) }
        let live: SMCKeyInfo
        do { live = try smc.keyInfo(key) } catch {
            throw FanWriterError.targetRejected(fan: info.index, detail: "\(error)")
        }
        guard live.type == .flt || live.type == .fpe2,
              let bytes = SMCCodec.encodeNumeric(rpm, type: live.type) else {
            throw FanWriterError.targetRejected(fan: info.index, detail: "cannot encode \(rpm) RPM as \(live.type)")
        }
        owned[info.index]?.targetWritten = true
        let failure = retrying(retry.targetAttempts, backoff: retry.targetBackoff) { _ in
            try self.writeKey(key, bytes, fan: info)
            guard let value = try? self.smc.read(key), let now = FanKeyReader.rpm(from: value) else {
                return "target is unreadable after writing"
            }
            return abs(now - rpm) <= Self.readbackToleranceRPM ? nil : "target reads \(now), expected \(rpm)"
        }
        if let failure { throw FanWriterError.targetRejected(fan: info.index, detail: failure) }
    }

    /// The single choke point for hardware writes: only keys this fan's backend uses are allowed.
    private func writeKey(_ key: FourCC, _ bytes: [UInt8], fan info: FanInfo) throws {
        var allowed: Set<FourCC> = []
        if let tg = SMCKeys.fan(info.index, .target) { allowed.insert(tg) }
        switch info.backend {
        case .appleSiliconMd(let name):
            if let mode = FourCC(name) { allowed.insert(mode) }
            if info.hasFtst { allowed.insert(SMCKeys.fanTest) }
        case .intelForced:
            allowed.insert(SMCKeys.fanForceBits)
        case .none:
            break
        }
        guard allowed.contains(key) else { throw FanWriterError.forbiddenKey(key) }
        try smc.write(key, bytes: bytes)
    }

    /// Runs `body` up to `attempts` times, sleeping `backoff` between tries. `body` returns nil on
    /// success or a description of what went wrong. Permanent errors (wrong size, not writable,
    /// read-only connection) are not retried. Returns nil on success, else the last failure.
    private func retrying(_ attempts: Int, backoff: TimeInterval, _ body: (Int) throws -> String?) -> String? {
        var failure = "no attempt was made"
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { sleeper(backoff) }
            do {
                guard let problem = try body(attempt) else { return nil }
                failure = problem
            } catch {
                failure = "\(error)"
                if Self.isPermanent(error) { return failure }
            }
        }
        return failure
    }

    private static func isPermanent(_ error: Error) -> Bool {
        switch error as? SMCError {
        case .sizeMismatch, .notWritable, .writeNotPermitted, .keyNotFound, .payloadTooLarge, .closed: return true
        default: return false
        }
    }
}
