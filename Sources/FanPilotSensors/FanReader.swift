import FanPilotKit
import Foundation

/// What fan discovery found on this machine. Read-only: nothing here needs root.
public struct FanDiscovery: Equatable, Sendable {
    public var fans: [FanInfo]
    /// `Ftst` exists (older M-series unlock key; absent on the M5).
    public var hasFtst: Bool
    /// `DICT` exists: the "fans are being ducked" flag the helper backs off on (SPEC 2.9).
    public var hasDICT: Bool
    /// `FBAD` (bad-fan bitmask) exists.
    public var hasBadFanMask: Bool
    /// `FS! ` (Intel forced-mode bitmask) exists.
    public var hasForceBits: Bool

    public init(fans: [FanInfo] = [], hasFtst: Bool = false, hasDICT: Bool = false,
                hasBadFanMask: Bool = false, hasForceBits: Bool = false) {
        self.fans = fans
        self.hasFtst = hasFtst
        self.hasDICT = hasDICT
        self.hasBadFanMask = hasBadFanMask
        self.hasForceBits = hasForceBits
    }
}

/// Display names for fans.
public enum FanNaming {
    /// Models with exactly two fans mounted left and right: the 14" and 16" MacBook Pro with a Pro
    /// or Max chip. On these the SMC fan 0 is the left fan and fan 1 the right one (so Mac17,x
    /// fans are named Left Side / Right Side).
    static let leftRightModels: Set<String> = [
        "MacBookPro15,1", "MacBookPro15,3", "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,4",
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
        "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
        "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
        "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
        "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9", "Mac17,14", "Mac17,15",
    ]

    /// `ids` optionally holds a name reported by the machine itself (`F<n>ID`, Intel); a non-empty
    /// entry wins over the generated one.
    public static func names(count: Int, model: String, ids: [String?] = []) -> [String] {
        (0..<max(0, count)).map { index in
            if index < ids.count, let id = ids[index], !id.isEmpty { return id }
            if count == 1 { return "Main Fan" }
            if count == 2, leftRightModels.contains(model) { return index == 0 ? "Left Side" : "Right Side" }
            return "Fan \(index + 1)"
        }
    }
}

/// Fan discovery and live fan readings (docs/SPEC.md 2.3, 2.6).
///
/// Everything here is a read; this type cannot change a fan. Thread-safe.
public final class FanReader: @unchecked Sendable {
    private let smc: SMCClient
    private let model: String
    private let lock = NSLock()
    private var discovery = FanDiscovery()

    public init(smc: SMCClient, model: String) {
        self.smc = smc
        self.model = model
    }

    /// The result of the last `discover()`.
    public var current: FanDiscovery {
        lock.lock(); defer { lock.unlock() }
        return discovery
    }

    public var fans: [FanInfo] { current.fans }

    // MARK: Discovery

    /// Reads `FNum` and the key set of every fan, and chooses a control backend per fan.
    ///
    /// Backend rules (SPEC 2.6): a fan is Apple Silicon style when its target `F<n>Tg` is writable
    /// and `flt ` (or `fpe2` on T2 Macs) AND a writable one-byte mode key exists, `F<n>md` first
    /// (M-series) and `F<n>Md` second (T2). Without a mode key, an `fpe2` target plus `FS! ` is the
    /// Intel forced-mode scheme. Anything else is monitor-only for that fan.
    ///
    /// Only fans 0 to 9 are addressable: the SMC key has a single digit slot.
    @discardableResult
    public func discover() throws -> FanDiscovery {
        let count: Int
        do {
            count = Int(try smc.readUInt8(SMCKeys.fanCount))
        } catch SMCError.keyNotFound {
            count = 0 // Mac without fans (Air, some minis).
        }

        let hasFtst = (try? smc.exists(SMCKeys.fanTest)) ?? false
        let hasForceBits = (try? smc.exists(SMCKeys.fanForceBits)) ?? false
        var fans: [FanInfo] = []
        var machineNames: [String?] = []

        for index in 0..<min(count, Constants.maxFanIndex + 1) {
            guard let target = SMCKeys.fan(index, .target) else { continue }
            let targetInfo = try? smc.keyInfo(target)
            let lowRPM = readLimit(index, .minimum)
            let highRPM = readLimit(index, .maximum)

            var backend = FanBackend.none
            if let targetInfo, targetInfo.isWritable, targetInfo.type == .flt || targetInfo.type == .fpe2 {
                let modeKey = [SMCKeys.FanSuffix.modeLower, .modeUpper].compactMap { suffix -> FourCC? in
                    guard let key = SMCKeys.fan(index, suffix),
                          let info = try? smc.keyInfo(key),
                          info.type == .ui8, info.size == 1, info.isWritable else { return nil }
                    return key
                }.first
                if let modeKey {
                    backend = .appleSiliconMd(modeKey: modeKey.string)
                } else if targetInfo.type == .fpe2, hasForceBits {
                    backend = .intelForced
                }
            }
            // A fan without sane limits cannot be controlled safely: clamping needs both.
            if !(lowRPM > 0 && highRPM > lowRPM) { backend = .none }

            fans.append(FanInfo(index: index, name: "", minRPM: lowRPM, maxRPM: highRPM,
                                modeKey: backend.modeKey, backend: backend, hasFtst: hasFtst))
            machineNames.append(readFanID(index))
        }

        let names = FanNaming.names(count: count, model: model, ids: machineNames)
        for position in fans.indices {
            fans[position].name = names.indices.contains(fans[position].index) ? names[fans[position].index] : "Fan \(fans[position].index + 1)"
        }

        let result = FanDiscovery(fans: fans,
                                  hasFtst: hasFtst,
                                  hasDICT: (try? smc.exists(SMCKeys.dict)) ?? false,
                                  hasBadFanMask: (try? smc.exists(SMCKeys.badFans)) ?? false,
                                  hasForceBits: hasForceBits)
        lock.lock()
        discovery = result
        lock.unlock()
        return result
    }

    // MARK: Live readings

    /// Reads every discovered fan once. A fan whose actual speed cannot be read is left out, so the
    /// caller can tell "unreadable" from "0 RPM" (0 is normal on Apple Silicon when cool).
    public func readAll() -> [FanReading] {
        let known = fans
        let forceBits = known.contains { $0.backend == .intelForced } ? readForceBits() : nil
        return known.compactMap { fan -> FanReading? in
            guard let actual = readRPM(fan.index, .actual) else { return nil }
            let target = readRPM(fan.index, .target) ?? 0
            // Limits are re-read every time: they are what the helper clamps against.
            let lowRPM = readRPM(fan.index, .minimum) ?? fan.minRPM
            let highRPM = readRPM(fan.index, .maximum) ?? fan.maxRPM

            var mode = 0
            if let modeKey = fan.modeKey.flatMap({ FourCC($0) }), let value = try? smc.readUInt8(modeKey) {
                mode = Int(value)
            } else if fan.backend == .intelForced, let forceBits {
                mode = (forceBits >> UInt16(fan.index)) & 1 == 1 ? 1 : 0
            }
            return FanReading(index: fan.index, actualRPM: actual, targetRPM: target, mode: mode,
                              minRPM: lowRPM, maxRPM: highRPM)
        }
    }

    /// `FBAD`: bit n set means the hardware flags fan n as bad. Nil if the key is missing.
    public func readBadFanMask() -> UInt32? {
        guard let value = try? smc.read(SMCKeys.badFans), !value.bytes.isEmpty, value.bytes.count <= 4 else { return nil }
        return value.bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// `DICT`: true while the OS is overriding the fans and a controller should back off.
    public func readOverrideFlag() -> Bool? {
        guard let value = try? smc.read(SMCKeys.dict), let first = value.bytes.first else { return nil }
        return first != 0
    }

    // MARK: Internals

    private func readRPM(_ index: Int, _ suffix: SMCKeys.FanSuffix) -> Double? {
        guard let key = SMCKeys.fan(index, suffix),
              let value = try? smc.read(key),
              [FourCC.flt, .fpe2, .ui16].contains(value.info.type),
              let number = value.numericValue, number.isFinite, number >= 0, number < Constants.rpmSanityCeiling
        else { return nil }
        return number
    }

    private func readLimit(_ index: Int, _ suffix: SMCKeys.FanSuffix) -> Double {
        readRPM(index, suffix) ?? 0
    }

    private func readForceBits() -> UInt16? {
        guard let value = try? smc.read(SMCKeys.fanForceBits) else { return nil }
        return SMCCodec.decodeUInt16(value.bytes)
    }

    /// Intel Macs may carry a name in `F<n>ID` (type `{fds`: 4 header bytes, then ASCII). Returns
    /// nil for everything else, which is the case on Apple Silicon (the key does not exist).
    private func readFanID(_ index: Int) -> String? {
        guard let key = FourCC("F\(index)ID"), let value = try? smc.read(key),
              value.info.type == FourCC("{fds"), value.bytes.count > 4 else { return nil }
        let text = value.bytes.dropFirst(4)
            .prefix { $0 != 0 }
            .filter { (0x20...0x7E).contains($0) }
        let name = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
