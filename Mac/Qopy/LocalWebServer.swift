import Foundation
import Network
import Darwin

/// Tiny HTTP/1.1 server: phone companion files + `POST /send` → Mac clipboard.
@MainActor
final class LocalWebServer: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var lastError: String?

    /// Called on the main actor when the phone posts text.
    var onTextReceived: ((String) -> Void)?

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
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data())
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
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

            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || buffer.count > 256 * 1024 {
                    connection.cancel()
                    return
                }
                self.receiveRequest(connection: connection, buffer: buffer)
                return
            }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                self.reply(connection, self.http(status: 400, contentType: "text/plain", body: Data("Bad request".utf8)))
                return
            }

            let contentLength = Self.contentLength(in: headerText) ?? 0
            let bodyStart = headerRange.upperBound
            let have = buffer.count - bodyStart
            if have < contentLength {
                if isComplete || buffer.count > 256 * 1024 {
                    connection.cancel()
                    return
                }
                self.receiveRequest(connection: connection, buffer: buffer)
                return
            }

            let body = contentLength > 0
                ? buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                : Data()
            let response = self.response(headerText: headerText, body: body)
            self.reply(connection, response)
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
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init)?.uppercased() ?? "GET"
        var path = parts.count > 1 ? String(parts[1]) : "/"
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
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
        let maxBytes = 100_000
        guard body.count <= maxBytes else {
            return http(status: 413, contentType: "application/json", body: Data(#"{"ok":false,"error":"too_long"}"#.utf8))
        }

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
            return http(status: 400, contentType: "application/json", body: Data(#"{"ok":false,"error":"empty"}"#.utf8))
        }

        Task { @MainActor in
            self.onTextReceived?(trimmed)
        }

        return http(status: 200, contentType: "application/json", body: Data(#"{"ok":true}"#.utf8))
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
