import FanPilotKit
import FanPilotSensors
import Foundation

/// Hot-set provider backed by the shared sensor stack (`SensorEngine`): the catalog and
/// classification the app shows, restricted to the areas that matter for the failsafe: CPU cores,
/// GPU regions and SoC die temperatures (docs/SPEC.md 3.4).
///
/// The sensor stack's own `hotSetMax` aggregate is deliberately not used. It also includes
/// prefix-matched keys from the "Other" group, and on the M5 Pro those include limit-like constants
/// (`TVMX`, `TVms`, `ftRf` all read exactly 61.0), which would trip the failsafe on a Mac whose
/// constant happens to be 95 or more. The remaining rails (`TVD*`, `TCMb`, `TPD*`, ...) are covered
/// by `SMCHotSetReader`, whose key list is explicit.
public final class SensorsHotSetProvider: HotSetProvider {
    public static let failsafeAreas: Set<SensorArea> = [.cpu, .gpu, .soc]

    private let engine: SensorEngine
    private var prepared = false

    public init(smc: SMCClient, hardware: HardwareInfo = .current()) {
        self.engine = SensorEngine(smc: smc, hardware: hardware)
    }

    public func refresh() {
        do {
            if prepared {
                try engine.reenumerate()
            } else {
                try engine.prepare()
                prepared = true
            }
            HelperLog.info("sensor stack: \(engine.sensors.count) sensors (catalog \(engine.currentPlan.catalogModel ?? "heuristic"))")
        } catch {
            HelperLog.error("sensor discovery failed: \(error)")
        }
    }

    public func read() -> HotSetReading {
        var best: Double?
        var bestID: String?
        var count = 0
        for reading in engine.refresh().readings where Self.failsafeAreas.contains(reading.sensor.area) {
            // A reading above the display range is N/A for the UI but is exactly what the failsafe
            // must not ignore. Non-finite values and sentinels are not usable.
            let usable = reading.valid || (reading.value.isFinite && reading.value >= Constants.maxValidTempC
                                           && reading.value < SMCHotSetReader.garbageCeilingC)
            guard usable else { continue }
            count += 1
            if best == nil || reading.value > best! {
                best = reading.value
                bestID = reading.sensor.id
            }
        }
        return HotSetReading(maxTempC: best, hottest: bestID, sensorCount: count)
    }
}
