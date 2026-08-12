import AppKit
import Carbon

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var sendHotKeyRef: EventHotKeyRef?
    private var receiveHotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?

    // ⌃⌥⌘C = send selection, ⌃⌥⌘V = receive
    private let sendID = EventHotKeyID(signature: OSType(0x514F5059), id: 1) // 'QOPY'
    private let receiveID = EventHotKeyID(signature: OSType(0x514F5059), id: 2)

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            DispatchQueue.main.async {
                if hotKeyID.id == 1 {
                    AppModel.shared.sendSelectionToPhone()
                } else if hotKeyID.id == 2 {
                    AppModel.shared.openReceiveFromPhone()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handler)

        let mods = UInt32(controlKey | optionKey | cmdKey)
        // keyCode 8 = C, 9 = V
        RegisterEventHotKey(UInt32(8), mods, sendID, GetApplicationEventTarget(), 0, &sendHotKeyRef)
        RegisterEventHotKey(UInt32(9), mods, receiveID, GetApplicationEventTarget(), 0, &receiveHotKeyRef)
    }
}
