import AppKit

/// Handles macOS Services menu: “Send to Phone with Qopy”.
final class ServiceProvider: NSObject {
    @objc func sendSelectionToPhone(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            error.pointee = "No text selection to send." as NSString
            return
        }
        DispatchQueue.main.async {
            AppModel.shared.presentSend(text: text)
        }
    }
}
