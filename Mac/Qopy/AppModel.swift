import AppKit
import SwiftUI

enum ReceivePhase: Equatable {
    case openSite
    case scanning
    case copied
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var sendText: String = ""
    @Published var sendWarning: String?
    @Published var isSendPresented = false

    @Published var isReceivePresented = false
    @Published var receivePhase: ReceivePhase = .openSite
    @Published var receiveStatus: String = "Hold steady"
    @Published var lastReceived: String?
    @Published var phonePageURL: String?
    @Published var phoneServerError: String?

    private var sendWindow: NSWindow?
    private var receiveWindow: NSWindow?
    private var receiveCloseObserver: NSObjectProtocol?
    private var serverURLObserver: NSObjectProtocol?
    let receiveScanner = QRScannerController()
    let phoneServer = LocalWebServer()

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
        receivePhase = .openSite
        receiveStatus = "Waiting for phone…"
        lastReceived = nil
        phonePageURL = nil
        phoneServerError = nil
        isReceivePresented = true
        phoneServer.start()
        phoneServer.onTextReceived = { [weak self] text in
            self?.handlePhoneText(text)
        }
        phonePageURL = phoneServer.baseURL?.absoluteString
        phoneServerError = phoneServer.lastError
        // URL may arrive asynchronously when the listener becomes ready.
        observePhoneServer()
        openReceiveWindow()
    }

    func advanceReceiveToCamera() {
        guard receivePhase == .openSite || receivePhase == .copied else { return }
        receivePhase = .scanning
        receiveStatus = "Point at the QR on your phone"
        lastReceived = nil
    }

    func handlePhoneText(_ text: String) {
        SelectionCapture.writeToClipboard(text)
        lastReceived = text
        receiveStatus = "Copied to clipboard."
        receivePhase = .copied
        receiveScanner.stop()
        NSSound.beep()
    }

    func handleScannedPayload(_ raw: String) {
        // Ignore the site URL QR if it somehow hits the camera.
        if let site = phonePageURL, raw.trimmingCharacters(in: .whitespacesAndNewlines) == site {
            return
        }
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return
        }
        guard let text = TextPayload.decode(raw) else {
            receiveStatus = "Couldn’t read that QR. Try again."
            return
        }
        handlePhoneText(text)
    }

    private func observePhoneServer() {
        // Poll briefly for ready URL (NWListener ready is async).
        Task { @MainActor in
            for _ in 0..<40 {
                if let url = phoneServer.baseURL?.absoluteString {
                    phonePageURL = url
                    phoneServerError = nil
                    return
                }
                if let error = phoneServer.lastError {
                    phoneServerError = error
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if phonePageURL == nil {
                phoneServerError = phoneServer.lastError ?? "Couldn’t start the phone page server."
            }
        }
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
        tearDownReceiveWindow(stopServer: false)
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
        phoneServer.stop()
        isReceivePresented = false
        receivePhase = .openSite
        phonePageURL = nil
        if let receiveCloseObserver {
            NotificationCenter.default.removeObserver(receiveCloseObserver)
            self.receiveCloseObserver = nil
        }
        receiveWindow = nil
    }

    private func tearDownReceiveWindow(stopServer: Bool = true) {
        if let receiveCloseObserver {
            NotificationCenter.default.removeObserver(receiveCloseObserver)
            self.receiveCloseObserver = nil
        }
        receiveScanner.stop()
        if stopServer {
            phoneServer.stop()
        }
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
