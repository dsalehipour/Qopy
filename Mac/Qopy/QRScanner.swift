import AVFoundation
import SwiftUI
import Vision

@MainActor
final class QRScannerController: NSObject, ObservableObject {
    @Published var permissionDenied = false
    @Published var cameraUnavailable = false

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "qopy.qr.scanner")
    private var isConfigured = false
    private var lastPayload: String?
    private var lastScanAt: Date = .distantPast
    private var startToken = UUID()

    var onCode: ((String) -> Void)?

    func start() {
        let token = UUID()
        startToken = token
        Task {
            let granted = await requestAccess()
            guard startToken == token else { return }
            guard granted else {
                permissionDenied = true
                return
            }
            configureIfNeeded()
            guard isConfigured else {
                cameraUnavailable = true
                return
            }
            guard startToken == token else { return }
            queue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
    }

    func stop() {
        // Invalidate any in-flight start() so it won't restart after close.
        startToken = UUID()
        onCode = nil
        lastPayload = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else {
            // Re-attach delegate after a previous stop().
            output.setSampleBufferDelegate(self, queue: queue)
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()
        isConfigured = true
    }
}

extension QRScannerController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let payload = request.results?
            .compactMap({ $0.payloadStringValue })
            .first(where: { !$0.isEmpty }) else { return }

        Task { @MainActor in
            let now = Date()
            if payload == lastPayload, now.timeIntervalSince(lastScanAt) < 2.0 {
                return
            }
            lastPayload = payload
            lastScanAt = now
            onCode?(payload)
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.applyMirroring(mirrored)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PreviewView else { return }
        view.previewLayer.session = session
        view.applyMirroring(mirrored)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? PreviewView)?.previewLayer.session = nil
    }

    final class PreviewView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.frame = bounds
            layer?.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        let previewLayer = AVCaptureVideoPreviewLayer()

        func applyMirroring(_ mirrored: Bool) {
            // Prefer connection mirroring when available; fall back to a layer flip.
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
                previewLayer.setAffineTransform(.identity)
            } else {
                previewLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            }
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
