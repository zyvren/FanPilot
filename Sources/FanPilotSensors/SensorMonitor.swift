import FanPilotKit
import Foundation

/// Polls sensors and fans on a background queue and publishes `SensorSnapshot`s (docs/SPEC.md 3.5).
///
/// One SMC pass and one HID pass per tick, all on a private serial queue; results are delivered on
/// `callbackQueue` (main by default) so UI code can assign them directly.
///
/// Lifecycle:
/// - `start()` prepares (a one second key walk) and then ticks every `interval` seconds, the first
///   tick immediately after preparation.
/// - `noteDidWake()` pauses sensor reads for `wakePause` seconds (the SMC is unreliable right after
///   wake, SPEC 3.5), then re-enumerates before the next tick.
/// - Every `revalidateInterval` seconds (10 min) the candidate keys are re-read and sensors that
///   have become valid are added.
public final class SensorMonitor: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Seconds between polls. Clamped to 1...60 (the user setting is 1 to 60, default 2).
        public var interval: TimeInterval
        public var revalidateInterval: TimeInterval
        /// Seconds to leave the sensors alone after wake.
        public var wakePause: TimeInterval
        /// Where `onSnapshot` runs. Nil delivers on the monitor's own queue.
        public var callbackQueue: DispatchQueue?

        public init(interval: TimeInterval = 2, revalidateInterval: TimeInterval = 600,
                    wakePause: TimeInterval = 5, callbackQueue: DispatchQueue? = .main) {
            self.interval = interval
            self.revalidateInterval = revalidateInterval
            self.wakePause = wakePause
            self.callbackQueue = callbackQueue
        }
    }

    public static let intervalRange: ClosedRange<TimeInterval> = 1...60

    public let engine: SensorEngine
    public let configuration: Configuration

    /// Called with every snapshot. Set before `start()`.
    public var onSnapshot: (@Sendable (SensorSnapshot) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); handler = newValue; lock.unlock() }
    }

    private let queue = DispatchQueue(label: "com.fanpilot.sensors", qos: .utility)
    private let lock = NSLock()
    private var handler: (@Sendable (SensorSnapshot) -> Void)?
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval
    private var latestSnapshot: SensorSnapshot?
    private var pausedUntil: Date?
    private var needsReenumeration = false
    private var lastRevalidation = Date()

    public init(engine: SensorEngine, configuration: Configuration = Configuration()) {
        self.engine = engine
        self.configuration = configuration
        self.interval = Self.intervalRange.clamp(configuration.interval)
    }

    /// Monitor on the real SMC (read-only connection).
    public convenience init(configuration: Configuration = Configuration()) throws {
        self.init(engine: try SensorEngine(), configuration: configuration)
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Control

    /// The most recent snapshot, nil before the first poll finishes.
    public var latest: SensorSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return latestSnapshot
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil
    }

    public var currentInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return interval
    }

    public func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        lock.unlock()
        queue.async { [self] in
            installTimer()
        }
    }

    /// Stops polling. Safe to call from `onSnapshot` (even when it runs on the monitor's own queue):
    /// it never waits for the queue. A poll that is already running still finishes and delivers.
    public func stop() {
        cancelTimer()
    }

    /// Changes the poll interval (clamped to 1...60 s) and restarts the timer if running.
    public func setInterval(_ seconds: TimeInterval) {
        lock.lock()
        interval = Self.intervalRange.clamp(seconds)
        let running = timer != nil
        lock.unlock()
        if running {
            queue.async { [self] in
                cancelTimer()
                // Not `.now()`: a slider dragged through twenty values would otherwise cause twenty
                // immediate full polls, and a setting meant to reduce load would increase it.
                installTimer(firstFireAfter: Self.intervalRange.clamp(seconds))
            }
        }
    }

    /// Sensors to read on every poll even if their group is normally sampled less often.
    public func setPriorityIDs(_ ids: Set<String>) {
        queue.async { [self] in engine.setPriorityIDs(ids) }
    }

    /// Polls right now, off schedule (for example when the menu opens). `full` reads every sensor
    /// instead of following the engine's `PollingPolicy` (use it when the "show all" list opens).
    public func refreshNow(full: Bool = false) {
        queue.async { [self] in tick(full: full) }
    }

    public func resetSessionMax() {
        queue.async { [self] in engine.resetSessionMax() }
    }

    /// Call on `NSWorkspace.didWakeNotification`.
    public func noteDidWake() {
        lock.lock()
        pausedUntil = Date().addingTimeInterval(configuration.wakePause)
        needsReenumeration = true
        lock.unlock()
    }

    // MARK: Diagnostics

    /// Fan, sensor and battery diagnostics for the latest snapshot. Reads the battery registry
    /// entry (cheap) on the calling thread.
    public func diagnostics(manualCommandAge: [Int: TimeInterval] = [:]) -> DiagnosticsReport {
        let snapshot = latest ?? SensorSnapshot()
        return DiagnosticsReport(
            fans: FanDiagnostics.evaluate(infos: snapshot.fanInfos, readings: snapshot.fans,
                                          hardware: engine.hardware, badFanMask: engine.badFanMask(),
                                          manualCommandAge: manualCommandAge),
            sensors: SensorDiagnostics.evaluate(readings: snapshot.readings),
            battery: BatteryDiagnostics.evaluate(BatteryReader.read()))
    }

    // MARK: Queue-confined work

    private func installTimer(firstFireAfter delay: TimeInterval = 0) {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let period = interval
        lock.unlock()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, repeating: period, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    private func cancelTimer() {
        lock.lock()
        let running = timer
        timer = nil
        lock.unlock()
        running?.cancel()
    }

    private func tick(full: Bool = false) {
        lock.lock()
        let pause = pausedUntil
        let reenumerate = needsReenumeration
        lock.unlock()

        let now = Date()
        if let pause, now < pause { return }
        if pause != nil || reenumerate {
            lock.lock()
            pausedUntil = nil
            needsReenumeration = false
            lock.unlock()
            if reenumerate { try? engine.reenumerate() }
        }

        if now.timeIntervalSince(lastRevalidation) >= configuration.revalidateInterval {
            lastRevalidation = now
            engine.revalidate()
        }

        let snapshot = engine.refresh(now: now, full: full)
        lock.lock()
        latestSnapshot = snapshot
        let callback = handler
        lock.unlock()

        guard let callback else { return }
        if let target = configuration.callbackQueue {
            target.async { callback(snapshot) }
        } else {
            callback(snapshot)
        }
    }
}

private extension ClosedRange where Bound == TimeInterval {
    func clamp(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
