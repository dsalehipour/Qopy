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

    /// Decode text from a scanned QR payload.
    /// Supports raw text, `qopy:` prefix, and web hash URLs containing `#qopy=...`.
    static func decode(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("qopy:") {
            let rest = String(trimmed.dropFirst(5))
            if let decoded = decodeBase64URL(rest) { return decoded }
            return rest.isEmpty ? nil : rest
        }

        if let hashRange = trimmed.range(of: "#qopy=") {
            let encoded = String(trimmed[hashRange.upperBound...])
            let token = encoded.split(separator: "&").first.map(String.init) ?? encoded
            if let decoded = decodeBase64URL(token) { return decoded }
        }

        return trimmed
    }

    static func encodeForQR(_ text: String) -> String {
        // Raw text scans cleanly on Android Camera / Lens (Copy).
        // Prefix keeps Mac↔web decoding unambiguous for future chunking.
        if text.allSatisfy({ $0.isASCII && !$0.isNewline }) || text.utf8.count < 200 {
            return text
        }
        return "qopy:" + encodeBase64URL(text)
    }

    static func encodeBase64URL(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ token: String) -> String? {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - base64.count % 4) % 4
        if pad > 0 { base64 += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }
}
