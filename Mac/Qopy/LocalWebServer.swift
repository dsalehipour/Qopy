import Foundation
import Network
import Darwin

/// Tiny HTTP/1.1 server: phone companion files, `POST /send` → Mac clipboard,
/// `POST /upload` → files saved to Downloads.
@MainActor
final class LocalWebServer: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var lastError: String?

    /// Called on the main actor when the phone posts text.
    var onTextReceived: ((String) -> Void)?
    /// Called on the main actor with the files saved from a phone upload.
    var onFilesReceived: (([URL]) -> Void)?

    static let maxTextBytes = 100_000
    static let maxUploadBytes = 100 * 1024 * 1024
    private static let maxHeaderBytes = 64 * 1024

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "qopy.web.server")
    private var root: URL?
    private let preferredPort: UInt16 = 8765

    func start() {
        stop()
        lastError = nil

        guard let root = Self.webRootURL() else {
            lastError = "Phone page missing from the app bundle."
            return
        }
        self.root = root

        if !startListener(on: nil) {
            lastError = lastError ?? "Couldn’t start the phone page server."
        }
    }

    @discardableResult
    private func startListener(on port: NWEndpoint.Port?) -> Bool {
        do {
            let parameters = NWParameters.tcp
            let listener: NWListener
            if let port {
                listener = try NWListener(using: parameters, on: port)
            } else {
                listener = try NWListener(using: parameters)
            }
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue ?? self.preferredPort
                        if let ip = Self.lanIPv4() {
                            self.baseURL = URL(string: "http://\(ip):\(port)/")
                        } else {
                            self.lastError = "Couldn’t find your Mac’s Wi‑Fi address."
                            self.baseURL = URL(string: "http://127.0.0.1:\(port)/")
                        }
                    case .failed(let error):
                        self.lastError = error.localizedDescription
                        self.baseURL = nil
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.handle(connection: connection)
                }
            }

            listener.start(queue: queue)
            return true
        } catch {
            lastError = error.localizedDescription
            listener = nil
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        baseURL = nil
        onTextReceived = nil
        onFilesReceived = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection: connection, buffer: Data(), searched: 0)
    }

    private func receiveHeaders(connection: NWConnection, buffer: Data, searched: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data { buffer.append(data) }

            let terminator = Data("\r\n\r\n".utf8)
            // Scan only what arrived since the last pass, minus the overlap a split
            // terminator needs. Re-scanning from the top would be quadratic.
            let scanFrom = max(0, searched - (terminator.count - 1))
            guard let headerRange = buffer.range(of: terminator, in: scanFrom..<buffer.count) else {
                if isComplete || buffer.count > Self.maxHeaderBytes {
                    connection.cancel()
                    return
                }
                self.receiveHeaders(connection: connection, buffer: buffer, searched: buffer.count)
                return
            }

            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                self.reply(connection, self.http(status: 400, contentType: "text/plain", body: Data("Bad request".utf8)))
                return
            }

            let contentLength = Self.contentLength(in: headerText) ?? 0
            if contentLength > Self.bodyLimit(forPath: Self.requestPath(in: headerText)) {
                self.reply(connection, self.json(status: 413, object: ["ok": false, "error": "too_large"]))
                return
            }

            let body = buffer.subdata(in: headerRange.upperBound..<buffer.count)
            self.receiveBody(
                connection: connection,
                headerText: headerText,
                body: body,
                contentLength: contentLength,
                isComplete: isComplete
            )
        }
    }

    private func receiveBody(
        connection: NWConnection,
        headerText: String,
        body: Data,
        contentLength: Int,
        isComplete: Bool
    ) {
        if body.count >= contentLength {
            let exact = contentLength > 0 ? body.subdata(in: 0..<contentLength) : Data()
            self.reply(connection, self.response(headerText: headerText, body: exact))
            return
        }
        if isComplete {
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var body = body
            if let data { body.append(data) }
            self.receiveBody(
                connection: connection,
                headerText: headerText,
                body: body,
                contentLength: contentLength,
                isComplete: isComplete
            )
        }
    }

    private func reply(_ connection: NWConnection, _ response: Data) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func response(headerText: String, body: Data) -> Data {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        let firstLine = lines.first.map(String.init) ?? ""
        let method = firstLine.split(separator: " ").first.map(String.init)?.uppercased() ?? "GET"
        var path = Self.requestPath(in: headerText)
        if path.contains("..") {
            return http(status: 400, contentType: "text/plain", body: Data("Bad request".utf8))
        }

        if method == "OPTIONS" {
            return http(
                status: 204,
                contentType: "text/plain",
                body: Data(),
                extraHeaders: [
                    "Access-Control-Allow-Methods: GET, HEAD, POST, OPTIONS",
                    "Access-Control-Allow-Headers: Content-Type",
                ]
            )
        }

        if path == "/send" && method == "POST" {
            return handleSend(body: body, headers: headerText)
        }

        if path == "/upload" && method == "POST" {
            return handleUpload(body: body, headers: headerText)
        }

        if path == "/" { path = "/index.html" }

        guard method == "GET" || method == "HEAD" else {
            return http(status: 405, contentType: "text/plain", body: Data("Method not allowed".utf8))
        }

        guard let root else {
            return http(status: 500, contentType: "text/plain", body: Data("No root".utf8))
        }

        let fileURL = root.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
        guard let fileBody = try? Data(contentsOf: fileURL) else {
            return http(status: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }
        if method == "HEAD" {
            return http(status: 200, contentType: mime(for: fileURL), body: Data(), contentLength: fileBody.count)
        }
        return http(status: 200, contentType: mime(for: fileURL), body: fileBody)
    }

    private func handleSend(body: Data, headers: String) -> Data {
        let contentType = Self.headerValue("Content-Type", in: headers)?.lowercased() ?? "text/plain"
        var text: String?

        if contentType.contains("application/json") {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                text = obj["text"] as? String
            }
        } else if contentType.contains("application/x-www-form-urlencoded") {
            if let raw = String(data: body, encoding: .utf8) {
                for pair in raw.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2, kv[0] == "text" {
                        text = kv[1].removingPercentEncoding?.replacingOccurrences(of: "+", with: " ")
                    }
                }
            }
        } else {
            text = String(data: body, encoding: .utf8)
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return json(status: 400, object: ["ok": false, "error": "empty"])
        }
        guard trimmed.utf8.count <= Self.maxTextBytes else {
            return json(status: 413, object: ["ok": false, "error": "too_long"])
        }

        Task { @MainActor in
            self.onTextReceived?(trimmed)
        }

        return json(status: 200, object: ["ok": true])
    }

    private func handleUpload(body: Data, headers: String) -> Data {
        let contentType = Self.headerValue("Content-Type", in: headers) ?? ""
        guard let boundary = Self.multipartBoundary(in: contentType) else {
            return json(status: 400, object: ["ok": false, "error": "bad_form"])
        }

        let files = Self.multipartFiles(body: body, boundary: boundary)
        guard !files.isEmpty else {
            return json(status: 400, object: ["ok": false, "error": "empty"])
        }

        var saved: [URL] = []
        for file in files {
            guard let url = Self.save(file) else {
                // Usually Downloads access was refused; the panel says so.
                return json(status: 500, object: ["ok": false, "error": "write_failed"])
            }
            saved.append(url)
        }

        Task { @MainActor in
            self.onFilesReceived?(saved)
        }

        return json(status: 200, object: ["ok": true, "saved": saved.map(\.lastPathComponent)])
    }

    private func http(
        status: Int,
        contentType: String,
        body: Data,
        contentLength: Int? = nil,
        extraHeaders: [String] = []
    ) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        let length = contentLength ?? body.count
        let lines = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(length)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "Cache-Control: no-cache",
        ] + extraHeaders
        // The trailing blank line is what separates headers from body; without it
        // the client keeps reading the body as more headers.
        let header = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private func json(status: Int, object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"ok":false}"#.utf8)
        return http(status: status, contentType: "application/json", body: body)
    }

    // MARK: - Uploads

    struct UploadedFile {
        let filename: String
        let data: Data
    }

    private static func multipartBoundary(in contentType: String) -> String? {
        guard contentType.lowercased().contains("multipart/form-data") else { return nil }
        for piece in contentType.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func multipartFiles(body: Data, boundary: String) -> [UploadedFile] {
        let delimiter = Data("\r\n--\(boundary)".utf8)
        // The opening delimiter has no leading CRLF; prepend one so every
        // delimiter in the stream looks the same.
        var data = Data("\r\n".utf8)
        data.append(body)

        var files: [UploadedFile] = []
        guard var current = data.range(of: delimiter) else { return [] }

        while true {
            let partStart = current.upperBound
            // "--" right after a delimiter closes the stream.
            if data.count >= partStart + 2, data[partStart] == 0x2D, data[partStart + 1] == 0x2D {
                break
            }
            guard let next = data.range(of: delimiter, in: partStart..<data.count) else { break }
            if let file = parsePart(data.subdata(in: partStart..<next.lowerBound)) {
                files.append(file)
            }
            current = next
        }

        return files
    }

    private static func parsePart(_ raw: Data) -> UploadedFile? {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: raw.subdata(in: 0..<separator.lowerBound), encoding: .utf8),
              let disposition = headerValue("Content-Disposition", in: headerText),
              let filename = filename(inDisposition: disposition) else { return nil }

        let content = raw.subdata(in: separator.upperBound..<raw.count)
        guard !content.isEmpty else { return nil }
        return UploadedFile(filename: filename, data: content)
    }

    private static func filename(inDisposition disposition: String) -> String? {
        for piece in disposition.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()

            if lowered.hasPrefix("filename*=") {
                let value = String(trimmed.dropFirst("filename*=".count))
                if let marker = value.range(of: "''"),
                   let decoded = String(value[marker.upperBound...]).removingPercentEncoding,
                   !decoded.isEmpty {
                    return sanitized(decoded)
                }
            }

            if lowered.hasPrefix("filename=") {
                var value = String(trimmed.dropFirst("filename=".count))
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { return sanitized(value) }
            }
        }
        return nil
    }

    /// Keeps an uploaded name from escaping Downloads or naming a directory.
    private static func sanitized(_ filename: String) -> String {
        let base = (filename as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { return "upload" }
        return String(base.prefix(200))
    }

    private static func save(_ file: UploadedFile) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let target = uniqueURL(in: downloads, filename: file.filename)
        do {
            try file.data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }

    private static func uniqueURL(in directory: URL, filename: String) -> URL {
        var candidate = directory.appendingPathComponent(filename)
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private static func requestPath(in headerText: String) -> String {
        let firstLine = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        var path = parts.count > 1 ? String(parts[1]) : "/"
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
        return path
    }

    private static func bodyLimit(forPath path: String) -> Int {
        // Text arrives as JSON, so allow a little headroom over the text limit.
        path == "/upload" ? maxUploadBytes : maxTextBytes + 16 * 1024
    }

    private func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    private static func contentLength(in headers: String) -> Int? {
        guard let raw = headerValue("Content-Length", in: headers) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    private static func headerValue(_ name: String, in headers: String) -> String? {
        let needle = name.lowercased() + ":"
        for line in headers.split(separator: "\r\n") {
            let s = String(line)
            if s.lowercased().hasPrefix(needle) {
                return String(s.dropFirst(needle.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func webRootURL() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("PhoneWeb"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Web")
        if FileManager.default.fileExists(atPath: dev.appendingPathComponent("index.html").path) {
            return dev
        }
        return nil
    }

    static func lanIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING) else { continue }
            guard flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                address = ip
                break
            }
            address = address ?? ip
        }
        return address
    }
}
