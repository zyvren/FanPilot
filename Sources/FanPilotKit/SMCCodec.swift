import Foundation

/// Encoding and decoding of SMC payloads.
///
/// Byte order is not uniform in the SMC (docs/SPEC.md 2.2): `flt ` payloads are little-endian,
/// while `sp78`, `fpe2` and the integer types are big-endian by SMC convention. On the M5 Pro some
/// integer keys (`rCPU`, `D4BI`, `F0CR`) only make sense little-endian, so treat integers other
/// than `#KEY`, `FNum` and the fan mode bytes as opaque unless you have verified the key.
///
/// All decoders require the exact payload length and return nil otherwise, so a size mismatch can
/// never be misread as a value. Encoders return nil for values that cannot be represented, so a
/// caller can never silently write a wrapped or saturated number.
public enum SMCCodec {
    // MARK: flt (float32, little-endian)

    public static func decodeFloat(_ bytes: [UInt8]) -> Float? {
        guard bytes.count == 4 else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Float(bitPattern: bits)
    }

    public static func encodeFloat(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
    }

    // MARK: Unsigned integers (big-endian)

    public static func decodeUInt8(_ bytes: [UInt8]) -> UInt8? {
        bytes.count == 1 ? bytes[0] : nil
    }

    public static func decodeUInt16(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count == 2 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    public static func decodeUInt32(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count == 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    public static func encodeUInt16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    public static func encodeUInt32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    // MARK: Signed integers (big-endian)

    public static func decodeInt8(_ bytes: [UInt8]) -> Int8? {
        bytes.count == 1 ? Int8(bitPattern: bytes[0]) : nil
    }

    public static func decodeInt16(_ bytes: [UInt8]) -> Int16? {
        decodeUInt16(bytes).map { Int16(bitPattern: $0) }
    }

    // MARK: fpe2 (unsigned 14.2 fixed point, big-endian; Intel fan RPM)

    /// Decodes to a value in RPM: the big-endian 16-bit integer divided by 4.
    public static func decodeFPE2(_ bytes: [UInt8]) -> Double? {
        decodeUInt16(bytes).map { Double($0) / 4.0 }
    }

    /// Encodes `value` as `(value * 4)` big-endian. A plain `(rpm << 2) & 0xffff`
    /// would wrap above 16383 RPM; we return nil instead.
    public static func encodeFPE2(_ value: Double) -> [UInt8]? {
        guard value.isFinite, value >= 0, value <= Double(UInt16.max) / 4.0 else { return nil }
        let raw = (value * 4.0).rounded()
        guard raw <= Double(UInt16.max) else { return nil }
        return encodeUInt16(UInt16(raw))
    }

    // MARK: sp78 (signed 8.8 fixed point, big-endian; Intel temperatures)

    /// The big-endian signed 16-bit integer divided by 256.
    public static func decodeSP78(_ bytes: [UInt8]) -> Double? {
        decodeInt16(bytes).map { Double($0) / 256.0 }
    }

    public static func encodeSP78(_ value: Double) -> [UInt8]? {
        guard value.isFinite else { return nil }
        let raw = (value * 256.0).rounded()
        guard raw >= Double(Int16.min), raw <= Double(Int16.max) else { return nil }
        return encodeUInt16(UInt16(bitPattern: Int16(raw)))
    }

    // MARK: Generic numeric view

    /// Best-effort numeric reading of a payload by SMC type. Returns nil for types that have no
    /// trustworthy numeric meaning (`ioft`, `hex_`, `ch8*`, `flag`, ...).
    ///
    /// `ui16`/`ui32` are decoded big-endian; see the type documentation for the caveat.
    public static func decodeNumeric(type: FourCC, bytes: [UInt8]) -> Double? {
        switch type {
        case .flt: return decodeFloat(bytes).map(Double.init)
        case .ui8: return decodeUInt8(bytes).map(Double.init)
        case .ui16: return decodeUInt16(bytes).map(Double.init)
        case .ui32: return decodeUInt32(bytes).map(Double.init)
        case .si8: return decodeInt8(bytes).map(Double.init)
        case .si16: return decodeInt16(bytes).map(Double.init)
        case .sp78: return decodeSP78(bytes)
        case .fpe2: return decodeFPE2(bytes)
        default: return nil
        }
    }

    /// Encodes `value` for a key of the given type, or nil if the type is unsupported or the value
    /// cannot be represented exactly in that type's range. Used by the fan writer.
    public static func encodeNumeric(_ value: Double, type: FourCC) -> [UInt8]? {
        guard value.isFinite else { return nil }
        switch type {
        case .flt:
            let f = Float(value)
            return f.isFinite ? encodeFloat(f) : nil
        case .fpe2:
            return encodeFPE2(value)
        case .sp78:
            return encodeSP78(value)
        case .ui8:
            guard value >= 0, value <= 255 else { return nil }
            return [UInt8(value.rounded())]
        case .ui16:
            guard value >= 0, value <= Double(UInt16.max) else { return nil }
            return encodeUInt16(UInt16(value.rounded()))
        default:
            return nil
        }
    }
}
