import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ReceivePhase: Equatable {
    case openSite
    case copied
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var sendText: String = ""
    @Published var sendImage: NSImage?
    @Published var sendImageURL: String?
    @Published var sendImageError: String?
    @Published var sendSource = "Clipboard"
    let sendServer = LocalWebServer()
    private var sendCloseObserver: NSObjectProtocol?
    private var sendReadyTask: Task<Void, Never>?
    @Published var sendWarning: String?
    @Published var isSendPresented = false

    @Published var isReceivePresented = false
    @Published var receivePhase: ReceivePhase = .openSite
    @Published var lastReceived: String?
    @Published var lastReceivedFiles: [URL] = []
    @Published var didCopyImage = false
    @Published var phonePageURL: String?
    @Published var phoneServerError: String?

    private var sendWindow: NSWindow?
    private var receiveWindow: NSWindow?
    private var receiveCloseObserver: NSObjectProtocol?
    private var serverURLObserver: NSObjectProtocol?
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

    func sendClipboardToPhone(from pasteboard: NSPasteboard = .general) {
        guard let payload = ClipboardPayload.read(from: pasteboard) else {
            closeSend()
            presentAlert(title: "Nothing to send", message: "Copy text or an image, then try again.")
            return
        }
        switch payload {
        case .text(let text): presentSend(text: text, source: "Clipboard")
        case .image(let data): presentSendImage(data, source: "Clipboard image")
        }
    }

    func sendImageFileToPhone() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.prompt = "Send to Phone"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard let image = NSImage(contentsOf: url), let data = ClipboardPayload.pngData(image) else {
            presentAlert(title: "Couldn’t read image", message: "Choose an image that Preview can open.")
            return
        }
        presentSendImage(data, source: url.lastPathComponent)
    }

    func presentSendImage(_ data: Data, source: String) {
        closeSend()
        sendText = ""
        sendWarning = nil
        sendSource = source
        sendImage = NSImage(data: data)
        do {
            let transfer = try ImageTransfer.save(data)
            sendServer.start(outgoingImage: transfer)
            sendReadyTask = Task { @MainActor in
                while !Task.isCancelled {
                    if let error = sendServer.lastError {
                        sendImageError = error
                        return
                    }
                    if let url = sendServer.baseURL {
                        sendImageURL = url.appendingPathComponent("transfer/\(transfer.id)").absoluteString
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        } catch {
            sendImageError = "Couldn’t save the image: \(error.localizedDescription)"
        }
        isSendPresented = true
        openSendWindow()
    }

    func presentSend(text: String, source: String = "Selection") {
        closeSend()
        sendSource = source
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
        lastReceived = nil
        lastReceivedFiles = []
        didCopyImage = false
        phonePageURL = nil
        phoneServerError = nil
        isReceivePresented = true
        phoneServer.start()
        phoneServer.onTextReceived = { [weak self] text in
            self?.handlePhoneText(text)
        }
        phoneServer.onFilesReceived = { [weak self] urls in
            self?.handlePhoneFiles(urls)
        }
        phonePageURL = phoneServer.baseURL?.absoluteString
        phoneServerError = phoneServer.lastError
        // URL may arrive asynchronously when the listener becomes ready.
        observePhoneServer()
        openReceiveWindow()
    }

    func handlePhoneText(_ text: String) {
        SelectionCapture.writeToClipboard(text)
        lastReceived = text
        lastReceivedFiles = []
        didCopyImage = false
        receivePhase = .copied
        NSSound.beep()
    }

    func handlePhoneFiles(_ urls: [URL]) {
        lastReceived = nil
        lastReceivedFiles = urls
        // A single image also lands on the clipboard, so ⌘V pastes it straight away.
        didCopyImage = urls.count == 1 && Self.copyImageToClipboard(urls[0])
        receivePhase = .copied
        NSSound.beep()
    }

    func revealReceivedFiles() {
        guard !lastReceivedFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastReceivedFiles)
    }

    private static func copyImageToClipboard(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let image = NSImage(contentsOf: url) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
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
        let window = GlassChrome.makeWindow(
            rootView: SendQRView().environmentObject(self),
            size: GlassChrome.sendWindowSize
        ) {
            self.sendWindow = nil
            self.isSendPresented = false
        }
        sendWindow = window
        sendCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.sendWindow === window else { return }
                self.closeSend()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeSend() {
        if let observer = sendCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            sendCloseObserver = nil
        }
        sendReadyTask?.cancel()
        sendReadyTask = nil
        sendServer.stop()
        sendWindow?.close()
        sendWindow = nil
        isSendPresented = false
        sendImage = nil
        sendImageURL = nil
        sendImageError = nil
    }

    private func openReceiveWindow() {
        tearDownReceiveWindow(stopServer: false)
        let window = GlassChrome.makeWindow(
            rootView: ReceiveView().environmentObject(self),
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
