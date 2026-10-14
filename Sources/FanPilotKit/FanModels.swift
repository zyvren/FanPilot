import Foundation

/// How the helper takes control of a fan (docs/SPEC.md 2.6).
public enum FanBackend: Hashable, Sendable, Codable {
    /// Apple Silicon: write the mode byte (`F<n>md` or `F<n>Md`) to 1, then a `flt` target.
    case appleSiliconMd(modeKey: String)
    /// Intel: set the fan's bit in `FS! `, then write an `fpe2` target. UNTESTED (no hardware).
    case intelForced
    /// No usable backend: monitor-only.
    case none

    /// Stable name used on the wire: `appleSiliconMd`, `intelForced`, `none`.
    public var kind: String {
        switch self {
        case .appleSiliconMd: return "appleSiliconMd"
        case .intelForced: return "intelForced"
        case .none: return "none"
        }
    }

    /// The mode key for `.appleSiliconMd`.
    public var modeKey: String? {
        if case .appleSiliconMd(let key) = self { return key }
        return nil
    }

    /// True if this backend can actually drive a fan.
    public var canControl: Bool {
        self != .none
    }

    private enum CodingKeys: String, CodingKey { case kind, modeKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "appleSiliconMd":
            guard let key = try c.decodeIfPresent(String.self, forKey: .modeKey), !key.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .modeKey, in: c,
                                                       debugDescription: "appleSiliconMd needs a modeKey")
            }
            self = .appleSiliconMd(modeKey: key)
        case "intelForced": self = .intelForced
        default: self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(modeKey, forKey: .modeKey)
    }
}

/// Static facts about one fan, from discovery.
///
/// On the wire the backend is flattened into `backend` (its kind) plus `modeKey`, as in the
/// `hello` reply of docs/SPEC.md 4.4.
public struct FanInfo: Hashable, Sendable, Codable, Identifiable {
    /// 0-based fan number (the digit in `F<n>Tg`).
    public var index: Int
    /// Display name (`Left Side`, `Fan 1`).
    public var name: String
    /// Live `F<n>Mn` / `F<n>Mx`, in RPM.
    public var minRPM: Double
    public var maxRPM: Double
    /// The mode key for Apple Silicon fans (`F0md`); nil for other backends.
    public var modeKey: String?
    public var backend: FanBackend
    /// True if the legacy `Ftst` unlock key exists (older M-series; absent on M5).
    public var hasFtst: Bool

    public var id: Int { index }

    public init(index: Int, name: String, minRPM: Double, maxRPM: Double,
                modeKey: String? = nil, backend: FanBackend, hasFtst: Bool = false) {
        self.index = index
        self.name = name
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.modeKey = modeKey ?? backend.modeKey
        self.backend = backend
        self.hasFtst = hasFtst
    }

    private enum CodingKeys: String, CodingKey {
        case index, name, minRPM, maxRPM, modeKey, backend, hasFtst
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let index = try c.decode(Int.self, forKey: .index)
        let modeKey = try c.decodeIfPresent(String.self, forKey: .modeKey)
        let kind = try c.decodeIfPresent(String.self, forKey: .backend) ?? "none"
        let backend: FanBackend
        switch kind {
        case "appleSiliconMd": backend = .appleSiliconMd(modeKey: modeKey ?? "F\(index)md")
        case "intelForced": backend = .intelForced
        default: backend = .none
        }
        self.init(index: index,
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Fan \(index + 1)",
                  minRPM: try c.decode(Double.self, forKey: .minRPM),
                  maxRPM: try c.decode(Double.self, forKey: .maxRPM),
                  modeKey: modeKey,
                  backend: backend,
                  hasFtst: try c.decodeIfPresent(Bool.self, forKey: .hasFtst) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(name, forKey: .name)
        try c.encode(minRPM, forKey: .minRPM)
        try c.encode(maxRPM, forKey: .maxRPM)
        try c.encodeIfPresent(modeKey, forKey: .modeKey)
        try c.encode(backend.kind, forKey: .backend)
        try c.encode(hasFtst, forKey: .hasFtst)
    }
}

/// A live reading of one fan.
public struct FanReading: Hashable, Sendable, Codable, Identifiable {
    public var index: Int
    /// Current speed (`F<n>Ac`). 0 is legitimate on Apple Silicon: the OS keeps fans off when cool.
    public var actualRPM: Double
    /// Requested speed (`F<n>Tg`).
    public var targetRPM: Double
    /// Hardware mode byte: 0 = system controlled (auto), 1 = manual. Other values are possible.
    public var mode: Int
    public var minRPM: Double
    public var maxRPM: Double

    public var id: Int { index }

    public init(index: Int, actualRPM: Double, targetRPM: Double, mode: Int, minRPM: Double, maxRPM: Double) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.mode = mode
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    public var isManual: Bool { mode == 1 }

    /// Actual speed as a 0...1 fraction of the fan's range (clamped).
    public var normalizedSpeed: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((actualRPM - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}
