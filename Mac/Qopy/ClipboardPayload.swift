import AppKit
import UniformTypeIdentifiers

/// One image on its way to the phone, carrying the name the phone should save it
/// as. A stable, meaningful name is what stops the phone's download manager from
/// treating every send as a repeat of the last one.
struct OutgoingImage {
    let filename: String
    let contentType: String
    let data: Data

    static let fallbackContentType = "image/png"

    /// Bytes straight off disk, so a JPEG stays a JPEG and keeps its real name.
    static func read(contentsOf url: URL) -> OutgoingImage? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              NSImage(data: data) != nil else { return nil }
        return OutgoingImage(
            filename: url.lastPathComponent,
            contentType: type.preferredMIMEType ?? fallbackContentType,
            data: data
        )
    }

    /// A pasteboard bitmap has no name of its own, so mint a unique one the way
    /// macOS names screenshots. Two clipboard sends never collide.
    static func clipboard(_ data: Data, date: Date = Date()) -> OutgoingImage {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return OutgoingImage(
            filename: "Clipboard \(formatter.string(from: date)).png",
            contentType: fallbackContentType,
            data: data
        )
    }
}

/// Read a fresh snapshot at invocation. Image representations take precedence over
/// their accompanying URL/text (browsers commonly put both on the pasteboard).
enum ClipboardPayload {
    case text(String)
    case image(OutgoingImage)

    @MainActor
    static func read(from pasteboard: NSPasteboard = .general) -> ClipboardPayload? {
        // A copied file is checked first only because NSImage(pasteboard:) would also
        // resolve it, losing the one thing a bitmap cannot supply: its real name.
        // Browsers pair an image with an http URL rather than a file URL, so they
        // still take the bitmap branch below.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.count == 1, let url = urls.first, url.isFileURL,
           let image = OutgoingImage.read(contentsOf: url) {
            return .image(image)
        }
        if let image = NSImage(pasteboard: pasteboard), let data = pngData(image) {
            return .image(OutgoingImage.clipboard(data))
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

/// One image inside a transfer. `slug` keeps the URL unique even when two sends
/// reuse a filename; `filename` is what the phone actually saves.
struct TransferImage {
    let slug: String
    let filename: String
    let contentType: String
    let data: Data
    let fileURL: URL
}

struct ImageTransfer {
    let id: String
    let directory: URL
    let images: [TransferImage]

    var first: TransferImage? { images.first }

    /// Retain the exact images sent across clipboard changes and app restarts.
    static func save(_ outgoing: [OutgoingImage]) throws -> ImageTransfer {
        let id = UUID().uuidString.lowercased()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Qopy/Transfers/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var used = Set<String>()
        var images: [TransferImage] = []
        for (index, item) in outgoing.enumerated() {
            let filename = Self.uniqueName(sanitized(item.filename), taken: &used)
            let url = directory.appendingPathComponent(filename)
            try item.data.write(to: url, options: .atomic)
            images.append(TransferImage(
                slug: String(index),
                filename: filename,
                contentType: item.contentType,
                data: item.data,
                fileURL: url
            ))
        }
        return ImageTransfer(id: id, directory: directory, images: images)
    }

    /// Keeps a name from escaping the transfer directory or naming a directory.
    static func sanitized(_ filename: String) -> String {
        let base = (filename as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { return "image.png" }
        return String(base.prefix(200))
    }

    /// Two files picked from different folders can share a name; the phone would
    /// see one download and skip the other, so separate them before sending.
    private static func uniqueName(_ filename: String, taken: inout Set<String>) -> String {
        let name = filename as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        var candidate = filename
        var index = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            index += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}
