import AppKit
import Foundation
import Vision

@main
struct TransferTests {
    @MainActor
    static func main() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        // Reproduce a stale address followed by a newer clipboard item.
        board.setString("http://192.168.1.23:8765/", forType: .string)
        board.clearContents()
        let latest = "  Latest clipboard\nUnicode: café 🐈\n\t"
        board.setString(latest, forType: .string)
        guard case .text(let text) = ClipboardPayload.read(from: board) else { fatalError("Missing text") }
        precondition(text == latest, "Clipboard must preserve exact current content")
        for text in [latest, String(repeating: "é🐈\n", count: 35), String(repeating: "x", count: 1200)] {
            let qr = QRCodeGenerator.image(from: TextPayload.encodeForQR(text), dimension: 1200)!
            var rect = NSRect(origin: .zero, size: qr.size)
            let cg = qr.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: cg).perform([request])
            precondition(request.results?.first?.payloadStringValue == text, "QR must decode to the exact clipboard text")
        }
        print("PASS latest clipboard replaces IP; whitespace, Unicode and max-size QR round trips")

        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let png = ClipboardPayload.pngData(NSImage(contentsOf: fixture)!)!
        board.clearContents()
        board.setString("http://192.168.1.23/image.png", forType: .string)
        board.setData(png, forType: .png)
        let count = board.changeCount
        guard case .image(let data) = ClipboardPayload.read(from: board) else { fatalError("Image must beat URL") }
        precondition(board.changeCount == count, "Sending must not mutate the clipboard")
        precondition(NSImage(data: data) != nil)
        board.clearContents()
        board.setData(NSImage(data: png)!.tiffRepresentation!, forType: .tiff)
        guard case .image = ClipboardPayload.read(from: board) else { fatalError("TIFF screenshot missing") }
        board.clearContents()
        board.writeObjects([fixture as NSURL])
        guard case .image = ClipboardPayload.read(from: board) else { fatalError("Finder image missing") }
        board.clearContents()
        precondition(ClipboardPayload.read(from: board) == nil)
        print("PASS image + URL precedence, PNG, TIFF, Finder image, empty clipboard; no clipboard mutation")

        let transfer = try ImageTransfer.save(png)
        let persisted = try Data(contentsOf: transfer.fileURL)
        precondition(persisted == png)
        let server = LocalWebServer()
        server.start(outgoingImage: transfer)
        let base = try await ready(server)
        let url = base.appendingPathComponent("transfer/\(transfer.id)")
        let (page, pageResponse) = try await URLSession.shared.data(from: url)
        precondition((pageResponse as! HTTPURLResponse).statusCode == 200)
        precondition(String(decoding: page, as: UTF8.self).contains("Save image"))
        let imageURL = url.appendingPathComponent("image.png")
        let (download, response) = try await URLSession.shared.data(from: imageURL)
        precondition(download == png, "Downloaded image must equal the saved snapshot")
        precondition(response.mimeType == "image/png")
        var head = URLRequest(url: imageURL); head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await URLSession.shared.data(for: head)
        precondition(headBody.isEmpty && headResponse.expectedContentLength == png.count)
        let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("transfer/wrong/image.png"))
        precondition((missing as! HTTPURLResponse).statusCode == 404)
        var post = URLRequest(url: base.appendingPathComponent("send")); post.httpMethod = "POST"
        post.httpBody = Data("should not receive in send mode".utf8)
        let (_, denied) = try await URLSession.shared.data(for: post)
        precondition((denied as! HTTPURLResponse).statusCode == 405)
        print("PASS real HTTP image page, byte-exact PNG, HEAD, unknown token, receive disabled on send server; durable snapshot")
        if CommandLine.arguments.contains("--serve") {
            print("BROWSER_URL=\(url.absoluteString)")
            fflush(stdout)
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        server.stop()
        let receive = LocalWebServer()
        receive.start()
        let receiveBase = try await ready(receive)
        var received: String?
        receive.onTextReceived = { received = $0 }
        var send = URLRequest(url: receiveBase.appendingPathComponent("send"))
        send.httpMethod = "POST"; send.setValue("application/json", forHTTPHeaderField: "Content-Type")
        send.httpBody = try JSONSerialization.data(withJSONObject: ["text": latest])
        let (_, sent) = try await URLSession.shared.data(for: send)
        precondition((sent as! HTTPURLResponse).statusCode == 200)
        for _ in 0..<100 where received == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(received == latest, "Phone text must retain whitespace")
        var receivedFiles: [URL] = []
        receive.onFilesReceived = { receivedFiles = $0 }
        let boundary = "QopyRegressionBoundary"
        var upload = URLRequest(url: receiveBase.appendingPathComponent("upload"))
        upload.httpMethod = "POST"
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"qopy-regression-image.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)
        body.append(png); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); upload.httpBody = body
        let (_, uploaded) = try await URLSession.shared.data(for: upload)
        precondition((uploaded as! HTTPURLResponse).statusCode == 200)
        for _ in 0..<100 where receivedFiles.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(receivedFiles.count == 1)
        let receivedPNG = try Data(contentsOf: receivedFiles[0])
        precondition(receivedPNG == png)
        // Remove only this test's newly saved, uniquely allocated upload.
        try FileManager.default.removeItem(at: receivedFiles[0])
        receive.stop()
        print("PASS existing phone-to-Mac text and image upload over real HTTP")
        do {
            _ = try await URLSession.shared.data(from: imageURL)
            fatalError("Closed transfer must not remain accessible")
        } catch { print("PASS closing stops image access") }
        // Exercise the actual app model and native window close notifications.
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        board.clearContents(); board.setString("http://192.168.1.23:8765/", forType: .string)
        board.setData(png, forType: .png)
        model.sendClipboardToPhone(from: board)
        for _ in 0..<100 where model.sendImageURL == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.sendImage != nil && model.sendText.isEmpty && model.sendImageURL != nil)
        let firstImageURL = URL(string: model.sendImageURL!)!.appendingPathComponent("image.png")
        board.clearContents(); board.setString(latest, forType: .string)
        model.sendClipboardToPhone(from: board)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.sendText == latest && model.sendImage == nil && model.isSendPresented)
        precondition(model.sendServer.baseURL == nil)
        do {
            _ = try await URLSession.shared.data(from: firstImageURL)
            fatalError("Changing to text must revoke the image session")
        } catch {}
        for window in NSApplication.shared.windows where window.isVisible { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!model.isSendPresented && model.sendServer.baseURL == nil)
        print("PASS actual Mac model reads image over IP text, refreshes latest text, revokes image, handles panel close")
        print("ALL TRANSFER TESTS PASSED")
    }

    @MainActor static func ready(_ server: LocalWebServer) async throws -> URL {
        for _ in 0..<100 {
            if let url = server.baseURL { return url }
            if let error = server.lastError { fatalError(error) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        fatalError("Server did not start")
    }
}
