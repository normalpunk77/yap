import AppKit
import Carbon.HIToolbox
import YapCore

/// Lets the Settings UI ask the app to (re)register a recorded shortcut and learn whether it
/// took — without SettingsView holding a reference to the AppDelegate. AppDelegate wires
/// `apply` at launch; it returns false if the system rejected the combo (already in use).
@MainActor
enum HotKeyBridge {
    static var apply: (HotKeyShortcut) -> Bool = { _ in false }
}

/// Registers a single global hotkey via Carbon and calls `onTrigger` when pressed. The
/// shortcut can be changed at runtime (`register` unregisters the previous one first), so
/// the user can rebind it in Settings.
final class HotKeyManager {
    private let onTrigger: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }

    /// Register `shortcut` as the active global hotkey, replacing any previous one. Returns
    /// false if the system rejected it (e.g. the combo is already claimed by another app),
    /// leaving no hotkey registered so the caller can fall back.
    @discardableResult
    func register(_ shortcut: HotKeyShortcut) -> Bool {
        installHandlerIfNeeded()
        unregisterHotKey()

        let hotKeyID = EventHotKeyID(signature: 0x44494354, id: 1) // 'DICT'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        return status == noErr && hotKeyRef != nil
    }

    /// Install the press handler once; it stays for the app's lifetime and dispatches every
    /// future hotkey registration (the handler is keyed to the event class, not the key).
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.onTrigger()
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    /// Temporarily remove the global hotkey (keeping the handler installed) so it can't fire
    /// — used while the user records a new shortcut in Settings. Re-arm with `register`.
    func suspend() { unregisterHotKey() }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    deinit {
        unregisterHotKey()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
