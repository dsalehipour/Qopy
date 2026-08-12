import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var sendText: String = ""
    @Published var sendWarning: String?
    @Published var isSendPresented = false

    @Published var isReceivePresented = false
    @Published var receiveStatus: String = "Hold steady"
    @Published var lastReceived: String?

    private var sendWindow: NSWindow?
    private var receiveWindow: NSWindow?
    private var receiveCloseObserver: NSObjectProtocol?
    let receiveScanner = QRScannerController()

    func sendSelectionToPhone() {
        if let text = SelectionCapture.selectedText() {
            presentSend(text: text)
            return
        }
        let trusted = SelectionCapture.ensureAccessibility(prompt: false)
        presentAlert(
            title: "No selection found",
            message: trusted
                ? "Select some text in another app first, or use “Send Clipboard to Phone”."
                : "Enable Qopy in System Settings → Privacy & Security → Accessibility, then try again. Or use “Send Clipboard to Phone”."
        )
    }

    func sendClipboardToPhone() {
        guard let text = SelectionCapture.clipboardText() else {
            presentAlert(title: "Clipboard is empty", message: "Copy some text, then try again.")
            return
        }
        presentSend(text: text)
    }

    func presentSend(text: String) {
        sendText = text
        if TextPayload.isWithinLimit(text) {
            sendWarning = nil
        } else {
            let bytes = TextPayload.utf8ByteCount(text)
            sendWarning = "Text is \(bytes) bytes (over the \(TextPayload.maxUTF8Bytes)-byte QR limit). Shorten it for now (chunking comes later)."
        }
        isSendPresented = true
        openSendWindow()
    }

    func openReceiveFromPhone() {
        receiveStatus = "Hold steady"
        lastReceived = nil
        isReceivePresented = true
        openReceiveWindow()
    }

    func handleScannedPayload(_ raw: String) {
        guard let text = TextPayload.decode(raw) else {
            receiveStatus = "Couldn’t read that QR. Try again."
            return
        }
        SelectionCapture.writeToClipboard(text)
        lastReceived = text
        receiveStatus = "Copied to clipboard."
        NSSound.beep()
    }

    private func openSendWindow() {
        sendWindow?.close()
        let window = GlassChrome.makeWindow(
            rootView: SendQRView().environmentObject(self),
            size: GlassChrome.sendWindowSize
        ) {
            self.sendWindow = nil
            self.isSendPresented = false
        }
        sendWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openReceiveWindow() {
        tearDownReceiveWindow()
        let window = GlassChrome.makeWindow(
            rootView: ReceiveScannerView(scanner: receiveScanner).environmentObject(self),
            size: GlassChrome.receiveWindowSize
        ) {
            self.handleReceiveWindowClosing()
        }
        receiveWindow = window
        receiveCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleReceiveWindowClosing()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleReceiveWindowClosing() {
        receiveScanner.stop()
        isReceivePresented = false
        if let receiveCloseObserver {
            NotificationCenter.default.removeObserver(receiveCloseObserver)
            self.receiveCloseObserver = nil
        }
        receiveWindow = nil
    }

    private func tearDownReceiveWindow() {
        if let receiveCloseObserver {
            NotificationCenter.default.removeObserver(receiveCloseObserver)
            self.receiveCloseObserver = nil
        }
        receiveScanner.stop()
        receiveWindow?.close()
        receiveWindow = nil
        isReceivePresented = false
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
