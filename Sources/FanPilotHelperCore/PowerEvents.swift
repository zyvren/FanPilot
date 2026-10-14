import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep and wake notifications (docs/SPEC.md 4.5 #5).
///
/// Before the machine sleeps every fan must be back in auto, and the sleep must not be held up:
/// the will-sleep handler runs synchronously (the release takes well under a second) and only then
/// is `IOAllowPowerChange` called. Delaying that call beyond the OS timeout (30 s) would stall sleep.
public final class PowerEvents {
    // The kIOMessage* constants are function-like macros (`iokit_common_msg(0x...)`) that Swift
    // cannot import. Values from IOKit/IOMessage.h: sys_iokit | sub_iokit_common | message.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemWillNotSleep: UInt32 = 0xE000_0290
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let queue: DispatchQueue
    private let onWillSleep: () -> Void
    private let onDidWake: () -> Void

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// - Parameters:
    ///   - queue: serial queue the callbacks run on. Must NOT be the engine queue (the handlers
    ///     synchronize onto it).
    public init(queue: DispatchQueue = DispatchQueue(label: "com.fanpilot.helper.power"),
                onWillSleep: @escaping () -> Void,
                onDidWake: @escaping () -> Void) {
        self.queue = queue
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
    }

    deinit {
        stop()
    }

    /// Registers for power notifications. Returns false if the registration failed.
    @discardableResult
    public func start() -> Bool {
        guard rootPort == 0 else { return true }
        var port: IONotificationPortRef?
        var object: io_object_t = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let connection = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<PowerEvents>.fromOpaque(refcon).takeUnretainedValue()
                .handle(message: UInt32(messageType), argument: messageArgument)
        }, &object)
        guard connection != 0, let port else {
            HelperLog.error("IORegisterForSystemPower failed; fans will not be released before sleep")
            return false
        }
        rootPort = connection
        notificationPort = port
        notifier = object
        IONotificationPortSetDispatchQueue(port, queue)
        return true
    }

    public func stop() {
        guard rootPort != 0 else { return }
        if let port = notificationPort {
            IONotificationPortSetDispatchQueue(port, nil)
        }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let port = notificationPort { IONotificationPortDestroy(port) }
        rootPort = 0
        notificationPort = nil
        notifier = 0
    }

    private func handle(message: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch message {
        case Self.canSystemSleep:
            // We never veto sleep.
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            onWillSleep()
            IOAllowPowerChange(rootPort, token)
        case Self.systemHasPoweredOn:
            onDidWake()
        default:
            break
        }
    }
}
