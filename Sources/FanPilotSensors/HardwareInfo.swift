import Foundation

/// One CPU performance level as reported by `sysctl hw.perflevelN.*`.
///
/// Apple names the clusters differently per generation: M1 to M4 report "Performance" and
/// "Efficiency"; the M5 Pro/Max report "Super" and "Performance" (measured on an M5 Pro MacBook Pro).
public struct PerfLevel: Hashable, Sendable {
    public var name: String
    public var physicalCPUs: Int

    public init(name: String, physicalCPUs: Int) {
        self.name = name
        self.physicalCPUs = physicalCPUs
    }
}

/// The machine facts sensor classification depends on. Everything is injectable so classification
/// can be tested for Macs we do not own.
public struct HardwareInfo: Hashable, Sendable {
    /// `hw.model`, for example `Mac17,8`.
    public var model: String
    public var isAppleSilicon: Bool
    /// Performance levels, fastest first (level 0 first), exactly as the kernel lists them.
    public var perfLevels: [PerfLevel]
    /// Installed memory in bytes (0 if unknown).
    public var memoryBytes: UInt64

    public init(model: String, isAppleSilicon: Bool, perfLevels: [PerfLevel] = [], memoryBytes: UInt64 = 0) {
        self.model = model
        self.isAppleSilicon = isAppleSilicon
        self.perfLevels = perfLevels
        self.memoryBytes = memoryBytes
    }

    /// True if a CPU level is called "Super". This is the one reliable marker of the M5 generation
    /// naming, where the `Tm` key family flips from memory sensors to performance-core sensors
    /// (measured on an M5 Pro MacBook Pro).
    public var hasSuperCores: Bool {
        perfLevels.contains { $0.name.caseInsensitiveCompare("Super") == .orderedSame }
    }

    public var totalPhysicalCPUs: Int {
        perfLevels.reduce(0) { $0 + $1.physicalCPUs }
    }

    /// Reads the running machine.
    public static func current() -> HardwareInfo {
        let model = sysctlString("hw.model") ?? "Unknown"
        let isARM = (sysctlInt("hw.optional.arm64") ?? 0) == 1
        let levelCount = sysctlInt("hw.nperflevels") ?? 0
        var levels: [PerfLevel] = []
        for index in 0..<max(0, min(levelCount, 8)) {
            guard let name = sysctlString("hw.perflevel\(index).name") else { continue }
            let cpus = sysctlInt("hw.perflevel\(index).physicalcpu") ?? 0
            levels.append(PerfLevel(name: name, physicalCPUs: cpus))
        }
        let memory = UInt64(max(0, sysctlInt64("hw.memsize") ?? 0))
        return HardwareInfo(model: model, isAppleSilicon: isARM, perfLevels: levels, memoryBytes: memory)
    }

    // MARK: sysctl helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        sysctlInt64(name).map(Int.init)
    }

    private static func sysctlInt64(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size == 4 || size == 8 else { return nil }
        if size == 4 {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        var value: Int64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
