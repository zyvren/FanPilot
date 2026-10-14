import AppKit
import FanPilotKit
import Foundation
import IOKit.ps

/// Watches sleep, wake, shutdown and the power source (AC or battery).
///
/// Sleep and wake come from `NSWorkspace`; the power source from an IOKit run loop source, which
/// fires whenever the adapter is plugged in or removed (docs/SPEC.md 4.6).
@MainActor
final class PowerMonitor {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?
    var onWillPowerOff: (() -> Void)?
    var onPowerSourceChange: ((PowerSource) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var runLoopSource: CFRunLoopSource?

    /// The source in use right now. Macs without a battery always report the adapter.
    static func currentPowerSource() -> PowerSource {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .adapter }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return .adapter }
        return type == kIOPSBatteryPowerValue ? .battery : .adapter
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWillSleep?() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDidWake?() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWillPowerOff?() }
        })

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            // The run loop source is attached to the main run loop, so this is the main thread.
            MainActor.assumeIsolated { monitor.onPowerSourceChange?(PowerMonitor.currentPowerSource()) }
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
    }
}
