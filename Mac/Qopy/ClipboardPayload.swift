import AppKit
import UniformTypeIdentifiers

/// Read a fresh snapshot at invocation. Image representations take precedence over
/// their accompanying URL/text (browsers commonly put both on the pasteboard).
enum ClipboardPayload {
    case text(String)
    case image(Data)

    @MainActor
    static func read(from pasteboard: NSPasteboard = .general) -> ClipboardPayload? {
        if let image = NSImage(pasteboard: pasteboard), let data = pngData(image) {
            return .image(data)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.count == 1, let url = urls.first, url.isFileURL,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: url), let data = pngData(image) {
            return .image(data)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return .text(text)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct ImageTransfer {
    let id: String
    let fileURL: URL
    let data: Data

    /// Retain the exact image sent across clipboard changes and app restarts.
    static func save(_ data: Data) throws -> ImageTransfer {
        let id = UUID().uuidString.lowercased()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Qopy/Transfers/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("image.png")
        try data.write(to: url, options: .atomic)
        return ImageTransfer(id: id, fileURL: url, data: data)
    }
}
