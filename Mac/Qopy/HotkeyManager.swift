import AppKit
import Carbon

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var sendSelectionHotKeyRef: EventHotKeyRef?
    private var sendClipboardHotKeyRef: EventHotKeyRef?
    private var receiveHotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?

    // ⌃⌥⌘C = send selection, ⌃⌥⇧⌘C = send clipboard, ⌃⌥⌘V = receive
    private let sendSelectionID = EventHotKeyID(signature: OSType(0x514F5059), id: 1) // 'QOPY'
    private let receiveID = EventHotKeyID(signature: OSType(0x514F5059), id: 2)
    private let sendClipboardID = EventHotKeyID(signature: OSType(0x514F5059), id: 3)

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
                switch hotKeyID.id {
                case 1:
                    AppModel.shared.sendSelectionToPhone()
                case 2:
                    AppModel.shared.openReceiveFromPhone()
                case 3:
                    AppModel.shared.sendClipboardToPhone()
                default:
                    break
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handler)

        let mods = UInt32(controlKey | optionKey | cmdKey)
        let modsWithShift = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        // keyCode 8 = C, 9 = V
        RegisterEventHotKey(UInt32(8), mods, sendSelectionID, GetApplicationEventTarget(), 0, &sendSelectionHotKeyRef)
        RegisterEventHotKey(UInt32(8), modsWithShift, sendClipboardID, GetApplicationEventTarget(), 0, &sendClipboardHotKeyRef)
        RegisterEventHotKey(UInt32(9), mods, receiveID, GetApplicationEventTarget(), 0, &receiveHotKeyRef)
    }
}
