import FanPilotKit
import FanPilotSensors
import Foundation

/// What fan control is possible on this machine, decided once at helper start (and again after
/// wake) from the live key infos of the SMC (docs/SPEC.md 2.6).
public struct FanTopology: Equatable, Sendable {
    /// Every fan reported by `FNum` (capped at ten, the single-digit key limit), in index order.
    /// Fans that cannot be driven have `backend == .none`; `unusableReasons` says why.
    public var fans: [FanInfo]
    public var unusableReasons: [Int: String]
    /// `Ftst` exists as a writable `ui8` (older M-series unlock; absent on the M5 Pro).
    public var hasFtst: Bool
    /// The `DICT` back-off flag exists (docs/SPEC.md 2.9).
    public var hasDICT: Bool
    /// `FNum` as reported by the SMC, before capping.
    public var reportedFanCount: Int
    /// Set when discovery itself failed (for example `FNum` is missing).
    public var discoveryNote: String?

    public init(fans: [FanInfo] = [], unusableReasons: [Int: String] = [:], hasFtst: Bool = false,
                hasDICT: Bool = false, reportedFanCount: Int = 0, discoveryNote: String? = nil) {
        self.fans = fans
        self.unusableReasons = unusableReasons
        self.hasFtst = hasFtst
        self.hasDICT = hasDICT
        self.reportedFanCount = reportedFanCount
        self.discoveryNote = discoveryNote
    }

    public func fan(_ index: Int) -> FanInfo? {
        fans.first { $0.index == index }
    }

    public var controllableFans: [FanInfo] {
        fans.filter { $0.backend.canControl }
    }

    /// True if no fan can be driven; the app then only monitors.
    public var isMonitorOnly: Bool { controllableFans.isEmpty }

    /// Human readable reason for monitor-only mode; nil when at least one fan is controllable.
    public var monitorReason: String? {
        guard isMonitorOnly else { return nil }
        if let discoveryNote { return discoveryNote }
        if fans.isEmpty { return "this Mac reports no fans" }
        return unusableReasons.sorted { $0.key < $1.key }
            .map { "fan \($0.key): \($0.value)" }
            .joined(separator: "; ")
    }
}

/// Fan discovery (docs/SPEC.md 2.6). Read-only: works on an unprivileged, read-only SMC connection,
/// which is how `fanpilotctl list` uses it.
///
/// The helper decides for itself what is controllable instead of reusing the app-facing discovery in
/// FanPilotSensors: this is the gate in front of root writes, so it is deliberately strict.
extension FanTopology {
    /// - Parameter model: hardware model identifier (`Mac17,8`). When given, fans get the same display
    ///   names the app shows ("Left Side" / "Right Side"); without it they are "Fan 1", "Fan 2".
    public static func discover(smc: SMCClient, model: String? = nil) -> FanTopology {
        var topology = discoverFans(smc: smc)
        if let model {
            let names = FanNaming.names(count: topology.fans.count, model: model)
            for position in topology.fans.indices { topology.fans[position].name = names[position] }
        }
        return topology
    }

    private static func discoverFans(smc: SMCClient) -> FanTopology {
        var topology = FanTopology()

        // FNum
        let reported: Int
        do {
            guard let n = try smc.readNumber(SMCKeys.fanCount), n >= 0, n <= 64 else {
                topology.discoveryNote = "FNum is missing or out of range"
                return topology
            }
            reported = Int(n)
        } catch {
            topology.discoveryNote = "cannot read FNum: \(error)"
            return topology
        }
        topology.reportedFanCount = reported
        if reported == 0 {
            topology.discoveryNote = "this Mac reports no fans"
            return topology
        }
        // One digit in `F<n>Tg`: fans above 9 would alias fan 1.
        let count = min(reported, Constants.maxFanIndex + 1)

        // Globals.
        if let info = try? smc.keyInfo(SMCKeys.fanTest), info.type == .ui8, info.size == 1, info.isWritable {
            topology.hasFtst = true
        }
        let forceBits = try? smc.keyInfo(SMCKeys.fanForceBits)
        let hasForceBits = forceBits.map { $0.size == 2 && $0.isWritable } ?? false
        topology.hasDICT = ((try? smc.keyInfo(SMCKeys.dict))?.size == 1)

        // FBAD: bit i set marks fan i as broken; never drive it.
        var badMask: UInt32 = 0
        if let bad = try? smc.read(SMCKeys.badFans), bad.bytes.count <= 4 {
            badMask = bad.bytes.reduce(0) { $0 << 8 | UInt32($1) }
        }

        for index in 0..<count {
            let (info, reason) = discoverFan(smc: smc, index: index, hasFtst: topology.hasFtst,
                                             hasForceBits: hasForceBits, bad: badMask & (1 << UInt32(index)) != 0)
            topology.fans.append(info)
            if let reason { topology.unusableReasons[index] = reason }
        }
        return topology
    }

    fileprivate static func discoverFan(smc: SMCClient, index: Int, hasFtst: Bool, hasForceBits: Bool,
                                    bad: Bool) -> (FanInfo, String?) {
        let name = "Fan \(index + 1)"

        func unusable(_ reason: String, min: Double = 0, max: Double = 0) -> (FanInfo, String?) {
            (FanInfo(index: index, name: name, minRPM: min, maxRPM: max, backend: .none, hasFtst: false), reason)
        }

        guard let tgKey = SMCKeys.fan(index, .target) else {
            return unusable("fan number out of range")
        }

        let limits: (min: Double, max: Double)
        do {
            limits = try FanKeyReader.limits(smc: smc, fan: index)
        } catch {
            return unusable("\(error)")
        }
        if bad { return unusable("marked as faulty by the SMC (FBAD)", min: limits.min, max: limits.max) }

        guard let tg = try? smc.keyInfo(tgKey) else {
            return unusable("\(tgKey) does not exist", min: limits.min, max: limits.max)
        }

        func modeKey(_ suffix: SMCKeys.FanSuffix) -> FourCC? {
            guard let key = SMCKeys.fan(index, suffix),
                  let info = try? smc.keyInfo(key),
                  info.type == .ui8, info.size == 1, info.isWritable else { return nil }
            return key
        }

        func controllable(_ backend: FanBackend) -> (FanInfo, String?) {
            (FanInfo(index: index, name: name, minRPM: limits.min, maxRPM: limits.max, backend: backend,
                     hasFtst: hasFtst && backend.modeKey != nil), nil)
        }

        guard tg.isWritable else {
            return unusable("\(tgKey) is not writable", min: limits.min, max: limits.max)
        }

        // Backend A: float target (Apple Silicon) with a writable ui8 mode byte; lowercase `md` is
        // the key on M-series (measured on an M5 Pro MacBook Pro), uppercase `Md` on T2.
        if tg.type == .flt, tg.size == 4 {
            if let key = modeKey(.modeLower) ?? modeKey(.modeUpper) {
                return controllable(.appleSiliconMd(modeKey: key.string))
            }
            return unusable("no writable mode key (F\(index)md / F\(index)Md)", min: limits.min, max: limits.max)
        }

        // T2 Intel: Backend A semantics with an fpe2 target. Plain Intel: Backend B (FS! bitmask).
        if tg.type == .fpe2, tg.size == 2 {
            if let key = modeKey(.modeUpper) ?? modeKey(.modeLower) {
                return controllable(.appleSiliconMd(modeKey: key.string))
            }
            if hasForceBits { return controllable(.intelForced) }
            return unusable("fpe2 target without a mode key or FS!", min: limits.min, max: limits.max)
        }

        return unusable("unsupported target type \(tg.type) size \(tg.size)", min: limits.min, max: limits.max)
    }
}

/// Live reads of fan keys.
public enum FanKeyReader {
    /// An RPM value stored as `flt ` (Apple Silicon) or `fpe2` (Intel); nil for any other type, whose
    /// byte order and scaling are not verified.
    ///
    /// Values outside `0...rpmSanityCeiling` are rejected too: firmware garbage must never reach
    /// arithmetic or formatting that assumes a plausible fan speed.
    public static func rpm(from value: SMCValue) -> Double? {
        guard let v = rawRPM(from: value), v >= 0, v <= Constants.rpmSanityCeiling else { return nil }
        return v
    }

    /// Like `rpm(from:)` but without the range check (NaN and infinities are still dropped to nil by
    /// callers that need it). The reassertion loop uses this so that a nonsense target left behind
    /// by the OS is seen as a mismatch to correct instead of an unreadable key to ignore.
    public static func rawRPM(from value: SMCValue) -> Double? {
        switch value.info.type {
        case .flt, .fpe2: return value.numericValue
        default: return nil
        }
    }

    /// An RPM for log text: never traps, whatever the value (`Int(Double)` crashes beyond Int.max).
    public static func rpmText(_ value: Double) -> String {
        value.isFinite ? String(format: "%.0f", value) : "invalid"
    }

    public static func readRPM(smc: SMCClient, fan: Int, suffix: SMCKeys.FanSuffix) throws -> Double {
        guard let key = SMCKeys.fan(fan, suffix) else { throw FanWriterError.noSuchFan(fan) }
        guard let value = rpm(from: try smc.read(key)) else {
            throw FanWriterError.limitsUnavailable(fan: fan, detail: "\(key) has no usable RPM value")
        }
        return value
    }

    /// The fan's live `[F<n>Mn, F<n>Mx]`. Limits come from the SMC every time and never from a client.
    public static func limits(smc: SMCClient, fan: Int) throws -> (min: Double, max: Double) {
        let lower: Double
        let upper: Double
        do {
            lower = try readRPM(smc: smc, fan: fan, suffix: .minimum)
            upper = try readRPM(smc: smc, fan: fan, suffix: .maximum)
        } catch let error as FanWriterError {
            throw error
        } catch {
            throw FanWriterError.limitsUnavailable(fan: fan, detail: "\(error)")
        }
        guard lower > 0, upper > lower, upper <= Constants.rpmSanityCeiling else {
            throw FanWriterError.limitsUnavailable(fan: fan, detail: "implausible limits \(lower)...\(upper) RPM")
        }
        return (lower, upper)
    }

    /// A full reading. `mode` is the mode byte (0 auto, 1 manual) or, on Intel, the fan's `FS! ` bit.
    public static func reading(smc: SMCClient, fan: FanInfo) throws -> FanReading {
        let actual = try readRPM(smc: smc, fan: fan.index, suffix: .actual)
        let target = try readRPM(smc: smc, fan: fan.index, suffix: .target)
        let (lower, upper) = try limits(smc: smc, fan: fan.index)
        return FanReading(index: fan.index, actualRPM: actual, targetRPM: target,
                          mode: Int(mode(smc: smc, fan: fan) ?? 0), minRPM: lower, maxRPM: upper)
    }

    /// The fan's current mode: the mode byte, or 0/1 from the `FS! ` bit. Nil if unreadable.
    public static func mode(smc: SMCClient, fan: FanInfo) -> UInt8? {
        switch fan.backend {
        case .appleSiliconMd(let key):
            guard let fourCC = FourCC(key), let value = try? smc.read(fourCC),
                  value.info.type == .ui8 else { return nil }
            return SMCCodec.decodeUInt8(value.bytes)
        case .intelForced:
            guard let value = try? smc.read(SMCKeys.fanForceBits),
                  let bits = SMCCodec.decodeUInt16(value.bytes) else { return nil }
            return bits & (1 << UInt16(fan.index)) != 0 ? 1 : 0
        case .none:
            return nil
        }
    }

    /// The `DICT` flag: true if the OS is ducking the fans (back off), nil if the key is absent or
    /// unreadable.
    public static func dictFlag(smc: SMCClient) -> Bool? {
        guard let value = try? smc.read(SMCKeys.dict), value.bytes.count == 1 else { return nil }
        return value.bytes[0] != 0
    }
}
