import Foundation

// Wire protocol between the app/CLI and the root helper (docs/SPEC.md 4.4).
//
// One JSON object per line (NDJSON). Every request gets exactly one reply with the same `id`.
//
//   {"id":1,"op":"hello","proto":1,"client":"FanPilot"}
//   {"id":1,"ok":true,"op":"hello","version":"1.0.0","proto":1,"fans":[...],...}
//   {"id":2,"op":"set","fan":0,"rpm":3000,"ttl":15}
//   {"id":2,"ok":false,"op":"set","err":"failsafe_active","msg":"...","forcedRPM":5349}
//
// Replies echo `op` (an addition to the SPEC) so a decoder can pick the payload without keeping
// track of outstanding requests. Decoding is tolerant of unknown keys.

// MARK: - Errors

/// Error codes of a failed reply.
public enum WireErrorCode: String, Codable, Sendable, CaseIterable {
    case badRequest = "bad_request"
    case unauthorized
    case noSuchFan = "no_such_fan"
    case monitorOnly = "monitor_only"
    case modeRejected = "mode_rejected"
    case targetRejected = "target_rejected"
    case failsafeActive = "failsafe_active"
    case ioError = "io_error"
    /// A code this version does not know (decoded from a newer peer).
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WireErrorCode(rawValue: raw) ?? .unknown
    }
}

/// Problems with the wire encoding itself (as opposed to a failed operation).
public enum WireError: Error, Equatable, Sendable, CustomStringConvertible {
    case lineTooLong(limit: Int)
    case emptyLine
    case malformed(String)
    /// A well-formed request with invalid values; maps to `bad_request`.
    case invalid(String)

    public var description: String {
        switch self {
        case .lineTooLong(let limit): return "line exceeds \(limit) bytes"
        case .emptyLine: return "empty line"
        case .malformed(let why): return "malformed message: \(why)"
        case .invalid(let why): return "invalid request: \(why)"
        }
    }
}

// MARK: - Requests

public enum WireOp: String, Codable, Sendable, CaseIterable {
    case hello, status, set, setAll, auto, heartbeat, bye
}

/// Which fans an `auto` request releases: all of them, or a single fan.
public enum FanSelector: Hashable, Sendable, Codable {
    case all
    case fan(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let index = try? c.decode(Int.self) {
            self = .fan(index)
        } else if let text = try? c.decode(String.self), text == "all" {
            self = .all
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a fan number or \"all\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .all: try c.encode("all")
        case .fan(let i): try c.encode(i)
        }
    }
}

/// A request and its parameters.
public enum WireCommand: Hashable, Sendable {
    /// First message on a connection (must arrive within 2 s).
    case hello(proto: Int, client: String)
    case status
    /// Take over (or retarget) one fan. `ttl` is the lease in seconds; nil means the helper default.
    case set(fan: Int, rpm: Double, ttl: Double?)
    /// Batch of `set`; a nil entry leaves that fan untouched.
    case setAll(rpms: [Double?], ttl: Double?)
    /// Return fans to system control.
    case auto(FanSelector)
    /// Renew all leases of this connection.
    case heartbeat(ttl: Double?)
    /// Release this connection's fans and close.
    case bye

    public var op: WireOp {
        switch self {
        case .hello: return .hello
        case .status: return .status
        case .set: return .set
        case .setAll: return .setAll
        case .auto: return .auto
        case .heartbeat: return .heartbeat
        case .bye: return .bye
        }
    }
}

public struct WireRequest: Hashable, Sendable, Codable {
    public var id: Int
    public var command: WireCommand

    public init(id: Int, command: WireCommand) {
        self.id = id
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case id, op, proto, client, fan, rpm, rpms, ttl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        let op = try c.decode(String.self, forKey: .op)
        guard let known = WireOp(rawValue: op) else {
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \"\(op)\"")
        }
        switch known {
        case .hello:
            self.command = .hello(proto: try c.decode(Int.self, forKey: .proto),
                                  client: try c.decodeIfPresent(String.self, forKey: .client) ?? "")
        case .status:
            self.command = .status
        case .set:
            self.command = .set(fan: try c.decode(Int.self, forKey: .fan),
                                rpm: try c.decode(Double.self, forKey: .rpm),
                                ttl: try c.decodeIfPresent(Double.self, forKey: .ttl))
        case .setAll:
            self.command = .setAll(rpms: try c.decode([Double?].self, forKey: .rpms),
                                   ttl: try c.decodeIfPresent(Double.self, forKey: .ttl))
        case .auto:
            self.command = .auto(try c.decodeIfPresent(FanSelector.self, forKey: .fan) ?? .all)
        case .heartbeat:
            self.command = .heartbeat(ttl: try c.decodeIfPresent(Double.self, forKey: .ttl))
        case .bye:
            self.command = .bye
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(command.op, forKey: .op)
        switch command {
        case .hello(let proto, let client):
            try c.encode(proto, forKey: .proto)
            try c.encode(client, forKey: .client)
        case .status, .bye:
            break
        case .set(let fan, let rpm, let ttl):
            try c.encode(fan, forKey: .fan)
            try c.encode(rpm, forKey: .rpm)
            try c.encodeIfPresent(ttl, forKey: .ttl)
        case .setAll(let rpms, let ttl):
            try c.encode(rpms, forKey: .rpms)
            try c.encodeIfPresent(ttl, forKey: .ttl)
        case .auto(let selector):
            try c.encode(selector, forKey: .fan)
        case .heartbeat(let ttl):
            try c.encodeIfPresent(ttl, forKey: .ttl)
        }
    }

    /// Checks every number in the request (SPEC 4.3: finite, in range). Throws `WireError.invalid`.
    /// The helper additionally clamps RPM to the live `[Mn, Mx]`; this only rejects nonsense.
    public func validate(maxFans: Int = Constants.maxFanIndex + 1,
                         maxTTL: Double = 3600) throws {
        func checkRPM(_ rpm: Double) throws {
            guard rpm.isFinite, rpm >= 0, rpm <= Constants.rpmSanityCeiling else {
                throw WireError.invalid("rpm must be finite and within 0...\(Int(Constants.rpmSanityCeiling))")
            }
        }
        func checkTTL(_ ttl: Double?) throws {
            guard let ttl else { return }
            guard ttl.isFinite, ttl > 0, ttl <= maxTTL else {
                throw WireError.invalid("ttl must be finite and within (0, \(Int(maxTTL))]")
            }
        }
        func checkFan(_ fan: Int) throws {
            guard (0..<maxFans).contains(fan) else { throw WireError.invalid("fan \(fan) out of range") }
        }

        switch command {
        case .hello(let proto, _):
            guard proto > 0 else { throw WireError.invalid("proto must be positive") }
        case .status, .bye:
            break
        case .set(let fan, let rpm, let ttl):
            try checkFan(fan)
            try checkRPM(rpm)
            try checkTTL(ttl)
        case .setAll(let rpms, let ttl):
            guard !rpms.isEmpty, rpms.count <= maxFans else {
                throw WireError.invalid("rpms must have 1...\(maxFans) entries")
            }
            for rpm in rpms.compactMap({ $0 }) { try checkRPM(rpm) }
            try checkTTL(ttl)
        case .auto(let selector):
            if case .fan(let fan) = selector { try checkFan(fan) }
        case .heartbeat(let ttl):
            try checkTTL(ttl)
        }
    }
}

// MARK: - Reply payloads

/// Payload of a `hello` reply.
public struct HelloReply: Hashable, Sendable {
    public var version: String
    public var proto: Int
    public var fans: [FanInfo]
    public var failsafeTempC: Double
    public var leaseMaxS: Double
    /// True if no fan backend was found (or fan control is disabled); the app then only monitors.
    public var monitorOnly: Bool
    /// Human readable reason for `monitorOnly`.
    public var monitorReason: String?

    public init(version: String = Constants.helperVersion, proto: Int = Constants.protocolVersion,
                fans: [FanInfo], failsafeTempC: Double, leaseMaxS: Double,
                monitorOnly: Bool, monitorReason: String? = nil) {
        self.version = version
        self.proto = proto
        self.fans = fans
        self.failsafeTempC = failsafeTempC
        self.leaseMaxS = leaseMaxS
        self.monitorOnly = monitorOnly
        self.monitorReason = monitorReason
    }
}

/// One fan in a `status` reply: a live reading plus ownership.
public struct FanStatus: Hashable, Sendable, Codable, Identifiable {
    public var index: Int
    public var actualRPM: Double
    public var targetRPM: Double
    public var mode: Int
    public var minRPM: Double
    public var maxRPM: Double
    /// True if the helper currently controls this fan.
    public var owned: Bool
    /// Seconds until the lease expires; 0 if not owned.
    public var leaseRemainS: Double

    public var id: Int { index }

    public init(index: Int, actualRPM: Double, targetRPM: Double, mode: Int, minRPM: Double,
                maxRPM: Double, owned: Bool, leaseRemainS: Double) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.mode = mode
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.owned = owned
        self.leaseRemainS = leaseRemainS
    }

    public init(reading: FanReading, owned: Bool, leaseRemainS: Double) {
        self.init(index: reading.index, actualRPM: reading.actualRPM, targetRPM: reading.targetRPM,
                  mode: reading.mode, minRPM: reading.minRPM, maxRPM: reading.maxRPM,
                  owned: owned, leaseRemainS: leaseRemainS)
    }

    public var reading: FanReading {
        FanReading(index: index, actualRPM: actualRPM, targetRPM: targetRPM, mode: mode,
                   minRPM: minRPM, maxRPM: maxRPM)
    }
}

/// State of the thermal failsafe override (SPEC 4.5 #6).
public struct FailsafeStatus: Hashable, Sendable, Codable {
    public var active: Bool
    /// Why it is active (`hot_sensor`, `blind`, ...), if it is.
    public var reason: String?
    /// The temperature that triggered it, if known.
    public var tempC: Double?

    public init(active: Bool = false, reason: String? = nil, tempC: Double? = nil) {
        self.active = active
        self.reason = reason
        self.tempC = tempC
    }

    public static let inactive = FailsafeStatus()
}

/// Payload of a `status` reply.
public struct StatusReply: Hashable, Sendable {
    public var fans: [FanStatus]
    public var failsafe: FailsafeStatus
    public var lastError: String?
    /// Value of the SMC `DICT` flag if the key exists (1 = the OS is overriding fans).
    public var dict: Int?

    public init(fans: [FanStatus], failsafe: FailsafeStatus = .inactive, lastError: String? = nil, dict: Int? = nil) {
        self.fans = fans
        self.failsafe = failsafe
        self.lastError = lastError
        self.dict = dict
    }
}

/// Result of one applied `set`.
public struct SetReply: Hashable, Sendable, Codable {
    /// The RPM actually written after clamping.
    public var applied: Double
    /// True if the helper changed the requested value to fit `[Mn, Mx]`.
    public var clamped: Bool

    public init(applied: Double, clamped: Bool) {
        self.applied = applied
        self.clamped = clamped
    }
}

/// Typed body of a successful reply.
public enum WireReplyBody: Hashable, Sendable {
    case hello(HelloReply)
    case status(StatusReply)
    case set(SetReply)
    /// One entry per requested fan; nil where the request left the fan untouched.
    case setAll([SetReply?])
    /// Fans that were released.
    case auto(released: [Int])
    /// Fans this connection still owns; a missing fan means ownership was lost.
    case heartbeat(owned: [Int])
    case bye
    case none
}

public struct WireReply: Hashable, Sendable, Codable {
    public var id: Int
    public var ok: Bool
    /// Echo of the request's op (nil only for errors where the request could not be parsed).
    public var op: WireOp?
    public var err: WireErrorCode?
    public var msg: String?
    /// With `failsafe_active`: the RPM the helper is forcing.
    public var forcedRPM: Double?
    public var body: WireReplyBody

    public init(id: Int, ok: Bool, op: WireOp?, err: WireErrorCode? = nil, msg: String? = nil,
                forcedRPM: Double? = nil, body: WireReplyBody = .none) {
        self.id = id
        self.ok = ok
        self.op = op
        self.err = err
        self.msg = msg
        self.forcedRPM = forcedRPM
        self.body = body
    }

    public static func success(id: Int, body: WireReplyBody) -> WireReply {
        WireReply(id: id, ok: true, op: body.op, body: body)
    }

    public static func failure(id: Int, op: WireOp?, code: WireErrorCode, message: String,
                               forcedRPM: Double? = nil) -> WireReply {
        WireReply(id: id, ok: false, op: op, err: code, msg: message, forcedRPM: forcedRPM)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, op, err, msg, forcedRPM
        // hello
        case version, proto, fans, failsafeTempC, leaseMaxS, monitorOnly, monitorReason
        // status
        case failsafe, lastError, dict
        // set / setAll / auto / heartbeat
        case applied, clamped, results, released, owned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        self.ok = try c.decode(Bool.self, forKey: .ok)
        self.op = (try c.decodeIfPresent(String.self, forKey: .op)).flatMap(WireOp.init(rawValue:))
        self.err = try c.decodeIfPresent(WireErrorCode.self, forKey: .err)
        self.msg = try c.decodeIfPresent(String.self, forKey: .msg)
        self.forcedRPM = try c.decodeIfPresent(Double.self, forKey: .forcedRPM)

        guard ok, let op else {
            self.body = .none
            return
        }
        switch op {
        case .hello:
            self.body = .hello(HelloReply(
                version: try c.decodeIfPresent(String.self, forKey: .version) ?? "",
                proto: try c.decodeIfPresent(Int.self, forKey: .proto) ?? 0,
                fans: try c.decodeIfPresent([FanInfo].self, forKey: .fans) ?? [],
                failsafeTempC: try c.decodeIfPresent(Double.self, forKey: .failsafeTempC) ?? Constants.defaultFailsafeTempC,
                leaseMaxS: try c.decodeIfPresent(Double.self, forKey: .leaseMaxS) ?? Constants.defaultLeaseMaxSeconds,
                monitorOnly: try c.decodeIfPresent(Bool.self, forKey: .monitorOnly) ?? false,
                monitorReason: try c.decodeIfPresent(String.self, forKey: .monitorReason)))
        case .status:
            self.body = .status(StatusReply(
                fans: try c.decodeIfPresent([FanStatus].self, forKey: .fans) ?? [],
                failsafe: try c.decodeIfPresent(FailsafeStatus.self, forKey: .failsafe) ?? .inactive,
                lastError: try c.decodeIfPresent(String.self, forKey: .lastError),
                dict: try c.decodeIfPresent(Int.self, forKey: .dict)))
        case .set:
            self.body = .set(SetReply(applied: try c.decode(Double.self, forKey: .applied),
                                      clamped: try c.decodeIfPresent(Bool.self, forKey: .clamped) ?? false))
        case .setAll:
            self.body = .setAll(try c.decodeIfPresent([SetReply?].self, forKey: .results) ?? [])
        case .auto:
            self.body = .auto(released: try c.decodeIfPresent([Int].self, forKey: .released) ?? [])
        case .heartbeat:
            self.body = .heartbeat(owned: try c.decodeIfPresent([Int].self, forKey: .owned) ?? [])
        case .bye:
            self.body = .bye
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(op, forKey: .op)
        try c.encodeIfPresent(err, forKey: .err)
        try c.encodeIfPresent(msg, forKey: .msg)
        try c.encodeIfPresent(forcedRPM, forKey: .forcedRPM)

        switch body {
        case .hello(let h):
            try c.encode(h.version, forKey: .version)
            try c.encode(h.proto, forKey: .proto)
            try c.encode(h.fans, forKey: .fans)
            try c.encode(h.failsafeTempC, forKey: .failsafeTempC)
            try c.encode(h.leaseMaxS, forKey: .leaseMaxS)
            try c.encode(h.monitorOnly, forKey: .monitorOnly)
            try c.encodeIfPresent(h.monitorReason, forKey: .monitorReason)
        case .status(let s):
            try c.encode(s.fans, forKey: .fans)
            try c.encode(s.failsafe, forKey: .failsafe)
            try c.encodeIfPresent(s.lastError, forKey: .lastError)
            try c.encodeIfPresent(s.dict, forKey: .dict)
        case .set(let s):
            try c.encode(s.applied, forKey: .applied)
            try c.encode(s.clamped, forKey: .clamped)
        case .setAll(let results):
            try c.encode(results, forKey: .results)
        case .auto(let released):
            try c.encode(released, forKey: .released)
        case .heartbeat(let owned):
            try c.encode(owned, forKey: .owned)
        case .bye, .none:
            break
        }
    }
}

extension WireReplyBody {
    /// The op this body answers; nil for `.none`.
    public var op: WireOp? {
        switch self {
        case .hello: return .hello
        case .status: return .status
        case .set: return .set
        case .setAll: return .setAll
        case .auto: return .auto
        case .heartbeat: return .heartbeat
        case .bye: return .bye
        case .none: return nil
        }
    }
}

// MARK: - NDJSON encoding

/// Encoding and decoding of single protocol lines, with the 64 KiB cap.
public enum WireCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Encodes `value` as one line WITHOUT the trailing newline. Throws `lineTooLong` over the cap.
    /// JSON never contains a raw newline, so the result is always exactly one line.
    public static func encode<T: Encodable>(_ value: T, maxLineBytes: Int = Constants.maxLineBytes) throws -> Data {
        let data = try encoder.encode(value)
        guard data.count <= maxLineBytes else { throw WireError.lineTooLong(limit: maxLineBytes) }
        return data
    }

    /// Encodes `value` as a complete NDJSON line including the trailing newline.
    public static func encodeLine<T: Encodable>(_ value: T, maxLineBytes: Int = Constants.maxLineBytes) throws -> Data {
        var data = try encode(value, maxLineBytes: maxLineBytes)
        data.append(0x0A)
        return data
    }

    /// Decodes one line (with or without trailing newline).
    public static func decode<T: Decodable>(_ type: T.Type, from line: Data,
                                            maxLineBytes: Int = Constants.maxLineBytes) throws -> T {
        let trimmed = trim(line)
        guard !trimmed.isEmpty else { throw WireError.emptyLine }
        guard trimmed.count <= maxLineBytes else { throw WireError.lineTooLong(limit: maxLineBytes) }
        do {
            return try JSONDecoder().decode(T.self, from: trimmed)
        } catch {
            throw WireError.malformed(String(describing: error))
        }
    }

    public static func decodeRequest(_ line: Data) throws -> WireRequest {
        try decode(WireRequest.self, from: line)
    }

    public static func decodeReply(_ line: Data) throws -> WireReply {
        try decode(WireReply.self, from: line)
    }

    /// Best-effort extraction of the `id` of a request that failed to decode, so the helper can
    /// still answer `bad_request` with the right id. Returns nil if there is no integer `id`.
    public static func peekID(_ line: Data) -> Int? {
        struct IDOnly: Decodable { let id: Int }
        return try? JSONDecoder().decode(IDOnly.self, from: trim(line)).id
    }

    private static func trim(_ data: Data) -> Data {
        var start = data.startIndex
        var end = data.endIndex
        while start < end, [0x0A, 0x0D, 0x20, 0x09].contains(data[start]) { start += 1 }
        while end > start, [0x0A, 0x0D, 0x20, 0x09].contains(data[end - 1]) { end -= 1 }
        return data.subdata(in: start..<end)
    }
}

// MARK: - Line framing

/// Splits a byte stream into newline-terminated lines and enforces the line length cap.
///
/// Feed it whatever `read` returned; it hands back every complete line (without the newline,
/// without a trailing CR, empty lines dropped). If a line grows past the cap before its newline
/// arrives, `append` throws and the connection must be closed: there is no safe way to resync.
public struct LineFramer: Sendable {
    public let maxLineBytes: Int
    private var buffer = Data()

    public init(maxLineBytes: Int = Constants.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Number of buffered bytes belonging to an unfinished line.
    public var pendingBytes: Int { buffer.count }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            var line = buffer[lineStart..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            guard line.count <= maxLineBytes else { throw WireError.lineTooLong(limit: maxLineBytes) }
            if !line.isEmpty { lines.append(Data(line)) }
            lineStart = buffer.index(after: newline)
        }
        buffer = Data(buffer[lineStart...])
        guard buffer.count <= maxLineBytes else {
            buffer.removeAll()
            throw WireError.lineTooLong(limit: maxLineBytes)
        }
        return lines
    }
}
