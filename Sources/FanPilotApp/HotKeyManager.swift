import AppKit
import Carbon.HIToolbox

/// Two optional global shortcuts: show the main window and open the menu panel.
///
/// FanPilot ships fixed combinations (there is no shortcut recorder) that are rarely
/// taken: Control-Option-Command-F for the window and Control-Option-Command-M for the menu.
/// Registered with Carbon's `RegisterEventHotKey`, which needs no accessibility permission.
@MainActor
final class HotKeyManager {
    static let showWindowDescription = "\u{2303}\u{2325}\u{2318}F"
    static let toggleMenuDescription = "\u{2303}\u{2325}\u{2318}M"

    private enum Slot: UInt32 {
        case showWindow = 1
        case toggleMenu = 2
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    private static let signature: OSType = 0x4650_4B59   // 'FPKY'

    /// Registers or removes the shortcuts. A nil closure unregisters that shortcut.
    func configure(showWindow: (() -> Void)?, toggleMenu: (() -> Void)?) {
        set(.showWindow, keyCode: UInt32(kVK_ANSI_F), action: showWindow)
        set(.toggleMenu, keyCode: UInt32(kVK_ANSI_M), action: toggleMenu)
    }

    private func set(_ slot: Slot, keyCode: UInt32, action: (() -> Void)?) {
        if let ref = refs.removeValue(forKey: slot.rawValue) { UnregisterEventHotKey(ref) }
        handlers[slot.rawValue] = nil
        guard let action else { return }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[slot.rawValue] = ref
            handlers[slot.rawValue] = action
        }
        // Registration fails if another app owns the combination; the shortcut is then simply absent.
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr, hotKeyID.signature == HotKeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let slot = hotKeyID.id
            // Carbon delivers application events on the main thread.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppModel.shared.hotKeys.fire(slot) }
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (status == noErr)
    }

    fileprivate func fire(_ slot: UInt32) {
        handlers[slot]?()
    }
}
