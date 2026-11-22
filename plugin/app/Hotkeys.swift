// Spyglass: global keyboard shortcuts (⌃⌥S show / hide, ⌃⌥J jump to the session waiting on you longest).
// Carbon's hot keys need no Accessibility permission. Control-Option combinations are rarely taken by apps.
import AppKit
import Carbon

final class Hotkeys {
    enum Action: UInt32 { case toggle = 1, jump = 2 }
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let onPress: (Action) -> Void
    static var current: Hotkeys?

    init(onPress: @escaping (Action) -> Void) { self.onPress = onPress }

    func enable() {
        guard refs.isEmpty else { return }
        Hotkeys.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let a = Hotkeys.Action(rawValue: id.id) { DispatchQueue.main.async { Hotkeys.current?.onPress(a) } }
            return noErr
        }, 1, &spec, nil, &handler)
        let mods = UInt32(controlKey | optionKey)
        for (key, action) in [(UInt32(kVK_ANSI_S), Action.toggle), (UInt32(kVK_ANSI_J), Action.jump)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(key, mods, EventHotKeyID(signature: OSType(0x5350_4747), id: action.rawValue),  // 'SPGG'
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    func disable() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs.removeAll()
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }
}
