import AppKit
import Foundation
import Vision

@main
struct TransferTests {
    @MainActor
    static func main() async throws {
        let fixtures = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("--") }
            .map { URL(fileURLWithPath: $0) }
        precondition(fixtures.count >= 3, "Needs three image fixtures")

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

        let fixture = fixtures[0]
        let fixtureBytes = try Data(contentsOf: fixture)
        let png = ClipboardPayload.pngData(NSImage(contentsOf: fixture)!)!
        board.clearContents()
        board.setString("http://192.168.1.23/image.png", forType: .string)
        board.setData(png, forType: .png)
        let count = board.changeCount
        guard case .image(let fromBitmap) = ClipboardPayload.read(from: board) else { fatalError("Image must beat URL") }
        precondition(board.changeCount == count, "Sending must not mutate the clipboard")
        precondition(NSImage(data: fromBitmap.data) != nil)
        precondition(fromBitmap.filename.hasPrefix("Clipboard ") && fromBitmap.filename.hasSuffix(".png"))
        board.clearContents()
        board.setData(NSImage(data: png)!.tiffRepresentation!, forType: .tiff)
        guard case .image = ClipboardPayload.read(from: board) else { fatalError("TIFF screenshot missing") }
        board.clearContents()
        board.writeObjects([fixture as NSURL])
        guard case .image(let fromFile) = ClipboardPayload.read(from: board) else { fatalError("Finder image missing") }
        precondition(fromFile.filename == fixture.lastPathComponent, "A picked file keeps its real name")
        precondition(fromFile.data == fixtureBytes, "A picked file goes over the wire untranscoded")
        board.clearContents()
        precondition(ClipboardPayload.read(from: board) == nil)
        print("PASS image + URL precedence, PNG, TIFF, Finder image keeps name and bytes, empty clipboard")

        // Back-to-back clipboard sends must not collide, or the phone files the
        // second one as a duplicate of the first and never saves it.
        let earlier = OutgoingImage.clipboard(png, date: Date(timeIntervalSince1970: 1_600_000_000))
        let later = OutgoingImage.clipboard(png, date: Date(timeIntervalSince1970: 1_600_000_061))
        precondition(earlier.filename != later.filename, "Clipboard sends must not reuse a filename")

        let named = "App Icon.png"
        let transfer = try ImageTransfer.save([
            OutgoingImage(filename: named, contentType: "image/png", data: png)
        ])
        let persisted = try Data(contentsOf: transfer.first!.fileURL)
        precondition(persisted == png)
        let server = LocalWebServer()
        server.start(outgoing: transfer)
        let base = try await ready(server)
        let url = base.appendingPathComponent("transfer/\(transfer.id)")
        let (page, pageResponse) = try await URLSession.shared.data(from: url)
        precondition((pageResponse as! HTTPURLResponse).statusCode == 200)
        precondition(String(decoding: page, as: UTF8.self).contains("Download all"))

        let (manifest, manifestResponse) = try await URLSession.shared.data(from: url.appendingPathComponent("items.json"))
        precondition((manifestResponse as! HTTPURLResponse).statusCode == 200)
        let items = try JSONSerialization.jsonObject(with: manifest) as! [[String: Any]]
        precondition(items.count == 1)
        precondition(items[0]["name"] as? String == named, "Manifest must carry the real filename")
        let imageURL = URL(string: items[0]["url"] as! String, relativeTo: base)!
        let (download, response) = try await URLSession.shared.data(from: imageURL)
        precondition(download == png, "Downloaded image must equal the saved snapshot")
        precondition(response.mimeType == "image/png")
        precondition(response.suggestedFilename == named, "The phone must be offered the real filename")
        var head = URLRequest(url: imageURL); head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await URLSession.shared.data(for: head)
        precondition(headBody.isEmpty && headResponse.expectedContentLength == png.count)
        let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("transfer/wrong/items.json"))
        precondition((missing as! HTTPURLResponse).statusCode == 404)
        var post = URLRequest(url: base.appendingPathComponent("send")); post.httpMethod = "POST"
        post.httpBody = Data("should not receive in send mode".utf8)
        let (_, denied) = try await URLSession.shared.data(for: post)
        precondition((denied as! HTTPURLResponse).statusCode == 405)
        print("PASS real HTTP image page, byte-exact PNG, real filename offered, HEAD, unknown token, receive disabled on send server")
        server.stop()

        // Two files picked from different folders can share a name, and the phone
        // would treat the second as already downloaded.
        let unicodeName = "café 🐈.png"
        let multi = try ImageTransfer.save([
            OutgoingImage(filename: "shot.png", contentType: "image/png", data: try Data(contentsOf: fixtures[0])),
            OutgoingImage(filename: "shot.png", contentType: "image/png", data: try Data(contentsOf: fixtures[1])),
            OutgoingImage(filename: unicodeName, contentType: "image/png", data: try Data(contentsOf: fixtures[2])),
        ])
        precondition(multi.images.map(\.filename) == ["shot.png", "shot 2.png", unicodeName], "Names within one send must be unique")
        precondition(Set(multi.images.map(\.fileURL)).count == 3, "Each image needs its own file on disk")
        let multiServer = LocalWebServer()
        multiServer.start(outgoing: multi)
        let multiBase = try await ready(multiServer)
        let multiURL = multiBase.appendingPathComponent("transfer/\(multi.id)")
        let (multiManifest, _) = try await URLSession.shared.data(from: multiURL.appendingPathComponent("items.json"))
        let multiItems = try JSONSerialization.jsonObject(with: multiManifest) as! [[String: Any]]
        precondition(multiItems.count == 3)
        precondition(multiItems.map { $0["name"] as! String } == ["shot.png", "shot 2.png", unicodeName])
        precondition(Set(multiItems.map { $0["url"] as! String }).count == 3, "Each image needs its own URL")
        for (index, item) in multiItems.enumerated() {
            let itemURL = URL(string: item["url"] as! String, relativeTo: multiBase)!
            let (bytes, itemResponse) = try await URLSession.shared.data(from: itemURL)
            let expected = try Data(contentsOf: fixtures[index])
            precondition((itemResponse as! HTTPURLResponse).statusCode == 200)
            precondition(bytes == expected, "Each URL must serve its own image")
            precondition(item["size"] as? Int == bytes.count)
        }
        precondition(transfer.id != multi.id, "Separate sends must not share a transfer URL")
        print("PASS multi-image manifest, unique names within one send, per-image URLs and bytes")

        if CommandLine.arguments.contains("--serve") {
            print("BROWSER_URL=\(multiURL.absoluteString)")
            fflush(stdout)
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        multiServer.stop()

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
        precondition(model.sendImages.count == 1 && model.sendText.isEmpty && model.sendImageURL != nil)
        let firstItemsURL = URL(string: model.sendImageURL!)!.appendingPathComponent("items.json")
        board.clearContents(); board.setString(latest, forType: .string)
        model.sendClipboardToPhone(from: board)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.sendText == latest && model.sendImages.isEmpty && model.isSendPresented)
        precondition(model.sendServer.baseURL == nil)
        do {
            _ = try await URLSession.shared.data(from: firstItemsURL)
            fatalError("Changing to text must revoke the image session")
        } catch {}

        // A multi-image send has to drive the same panel the single one does.
        let picked = fixtures.compactMap(OutgoingImage.read(contentsOf:))
        precondition(picked.count == 3, "Every fixture must be readable as an outgoing image")
        precondition(AppModel.sourceLabel(for: picked) == "3 images")
        model.presentSendImages(picked, source: AppModel.sourceLabel(for: picked))
        for _ in 0..<100 where model.sendImageURL == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.sendImages.count == 3 && model.sendText.isEmpty)
        let pickedItems = try JSONSerialization.jsonObject(
            with: try await URLSession.shared.data(from: URL(string: model.sendImageURL!)!.appendingPathComponent("items.json")).0
        ) as! [[String: Any]]
        precondition(pickedItems.map { $0["name"] as! String } == fixtures.map(\.lastPathComponent),
                     "Picked files must reach the phone under their own names")

        for window in NSApplication.shared.windows where window.isVisible { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!model.isSendPresented && model.sendServer.baseURL == nil)
        print("PASS actual Mac model sends one and many images under real filenames, revokes on text, handles panel close")
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
