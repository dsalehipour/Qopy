import Foundation

enum TextPayload {
    /// Practical QR byte budget for reliable phone-camera scans.
    /// Chunking can raise this later; for now we warn and refuse.
    static let maxUTF8Bytes = 1200

    static func utf8ByteCount(_ text: String) -> Int {
        text.utf8.count
    }

    static func isWithinLimit(_ text: String) -> Bool {
        utf8ByteCount(text) <= maxUTF8Bytes
    }

    static func encodeForQR(_ text: String) -> String {
        // Android Camera / Lens can copy the exact text without a custom decoder.
        text
    }

    static func encodeBase64URL(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
